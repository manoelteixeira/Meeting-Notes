import Foundation
import Testing

@testable import MeetingNotesCore

@Suite("Transcript merging")
struct TranscriptMergerTests {

    /// Deterministic ids keep expectations readable.
    private func sequentialIDs() -> () -> UUID {
        nonisolated(unsafe) var counter = 0
        return {
            counter += 1
            return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", counter))!
        }
    }

    // MARK: - Assembling pre-attributed runs

    @Test("Runs already labelled by speaker interleave by time and coalesce per turn")
    func assembleInterleaves() {
        let result = TranscriptMerger.assemble(
            runsBySpeaker: [
                ("B", [
                    TimedTextRun(start: 5, end: 7, text: "Happy to be here."),
                ]),
                ("A", [
                    TimedTextRun(start: 0, end: 2, text: "Hello everyone."),
                    TimedTextRun(start: 2, end: 4, text: "Thanks for joining."),
                    TimedTextRun(start: 10, end: 12, text: "Let's begin."),
                ]),
            ],
            idGenerator: sequentialIDs()
        )

        #expect(result.segments.map(\.speakerID) == ["A", "B", "A"])
        #expect(result.segments[0].text == "Hello everyone. Thanks for joining.")
        #expect(result.segments[0].start == 0)
        #expect(result.segments[0].end == 4)
        #expect(result.segments[1].text == "Happy to be here.")
        #expect(result.segments[2].text == "Let's begin.")
        // Numbered by first appearance in time, not by input order.
        #expect(result.speakers.map(\.id) == ["A", "B"])
        #expect(result.speakers.map(\.displayName) == ["Speaker 1", "Speaker 2"])
    }

    @Test("Assembling honours the utterance break gap and drops blank runs")
    func assembleBreaksAndBlanks() {
        let result = TranscriptMerger.assemble(
            runsBySpeaker: [
                ("A", [
                    TimedTextRun(start: 0, end: 1, text: "One."),
                    TimedTextRun(start: 1.2, end: 2, text: "   "),
                    TimedTextRun(start: 5, end: 6, text: "Two."),
                ]),
            ],
            options: .init(utteranceBreakGap: 2),
            idGenerator: sequentialIDs()
        )
        #expect(result.segments.map(\.text) == ["One.", "Two."])
        #expect(result.speakers.count == 1)
    }

    @Test("Simultaneous runs keep the order the speakers were given in")
    func assembleTieOrder() {
        let result = TranscriptMerger.assemble(
            runsBySpeaker: [
                ("B", [TimedTextRun(start: 1, end: 2, text: "Yes.")]),
                ("A", [TimedTextRun(start: 1, end: 2, text: "No.")]),
            ],
            idGenerator: sequentialIDs()
        )
        #expect(result.segments.map(\.speakerID) == ["B", "A"])
    }

    @Test("Assembling nothing yields nothing")
    func assembleEmpty() {
        let result = TranscriptMerger.assemble(runsBySpeaker: [("A", [])])
        #expect(result.segments.isEmpty)
        #expect(result.speakers.isEmpty)
    }

    // MARK: - Merging by overlap

    @Test("Alternating speakers produce one utterance per turn")
    func alternatingSpeakers() {
        let runs = [
            TimedTextRun(start: 0, end: 2, text: "Hello everyone."),
            TimedTextRun(start: 2, end: 4, text: "Thanks for joining."),
            TimedTextRun(start: 5, end: 7, text: "Happy to be here."),
            TimedTextRun(start: 10, end: 12, text: "Let's begin."),
        ]
        let diarization = [
            DiarizedSegment(speakerID: "A", start: 0, end: 4.5),
            DiarizedSegment(speakerID: "B", start: 4.5, end: 8),
            DiarizedSegment(speakerID: "A", start: 9.5, end: 13),
        ]

        let result = TranscriptMerger.merge(runs: runs, diarization: diarization)

        #expect(result.segments.count == 3)
        #expect(result.segments[0].speakerID == "A")
        #expect(result.segments[0].text == "Hello everyone. Thanks for joining.")
        #expect(result.segments[1].speakerID == "B")
        #expect(result.segments[1].text == "Happy to be here.")
        #expect(result.segments[2].speakerID == "A")
        #expect(result.segments[2].text == "Let's begin.")
    }

    @Test("Speakers are numbered by first appearance")
    func speakerNumbering() {
        let runs = [
            TimedTextRun(start: 0, end: 1, text: "First."),
            TimedTextRun(start: 2, end: 3, text: "Second."),
        ]
        let diarization = [
            // Deliberately not in id order: numbering follows the transcript.
            DiarizedSegment(speakerID: "speaker_7", start: 0, end: 1.5),
            DiarizedSegment(speakerID: "speaker_2", start: 1.5, end: 4),
        ]

        let result = TranscriptMerger.merge(runs: runs, diarization: diarization)

        #expect(result.speakers.map(\.id) == ["speaker_7", "speaker_2"])
        #expect(result.speakers.map(\.displayName) == ["Speaker 1", "Speaker 2"])
        #expect(result.speakers.map(\.colorIndex) == [1, 2])
    }

    @Test("A run is attributed to the speaker it overlaps most")
    func maximumOverlapWins() {
        let runs = [TimedTextRun(start: 4, end: 6, text: "Mostly the second speaker.")]
        let diarization = [
            DiarizedSegment(speakerID: "A", start: 0, end: 4.4),
            DiarizedSegment(speakerID: "B", start: 4.4, end: 10),
        ]

        let result = TranscriptMerger.merge(runs: runs, diarization: diarization)

        #expect(result.segments.count == 1)
        #expect(result.segments[0].speakerID == "B")
    }

    @Test("A run straddling a speaker change is split at a word boundary")
    func boundarySpanningRunIsSplit() {
        // The run covers 0–4 s; the change happens at 2 s, so each speaker owns half.
        let runs = [TimedTextRun(start: 0, end: 4, text: "I think we should ship it on Friday")]
        let diarization = [
            DiarizedSegment(speakerID: "A", start: 0, end: 2),
            DiarizedSegment(speakerID: "B", start: 2, end: 6),
        ]

        let result = TranscriptMerger.merge(runs: runs, diarization: diarization)

        #expect(result.segments.count == 2)
        #expect(result.segments[0].speakerID == "A")
        #expect(result.segments[1].speakerID == "B")
        // The split never cuts a word in half.
        let rejoined = result.segments.map(\.text).joined(separator: " ")
        #expect(rejoined == "I think we should ship it on Friday")
        #expect(result.segments[0].end == 2)
        #expect(result.segments[1].start == 2)
    }

    @Test("A lopsided overlap is not split")
    func lopsidedOverlapIsNotSplit() {
        // Speaker B only covers the last 10% of the run — below the split threshold.
        let runs = [TimedTextRun(start: 0, end: 4, text: "One two three four five six")]
        let diarization = [
            DiarizedSegment(speakerID: "A", start: 0, end: 3.6),
            DiarizedSegment(speakerID: "B", start: 3.6, end: 8),
        ]

        let result = TranscriptMerger.merge(runs: runs, diarization: diarization)

        #expect(result.segments.count == 1)
        #expect(result.segments[0].speakerID == "A")
        #expect(result.segments[0].text == "One two three four five six")
    }

    @Test("A run with no overlap attaches to a nearby speaker")
    func nearestNeighborWithinTolerance() {
        let runs = [TimedTextRun(start: 5.4, end: 5.9, text: "Right.")]
        let diarization = [DiarizedSegment(speakerID: "A", start: 0, end: 5.0)]

        let result = TranscriptMerger.merge(runs: runs, diarization: diarization)

        #expect(result.segments.count == 1)
        #expect(result.segments[0].speakerID == "A")
    }

    @Test("A run far from any speaker becomes Unknown")
    func uncoveredRunBecomesUnknown() {
        let runs = [TimedTextRun(start: 30, end: 31, text: "Stray audio.")]
        let diarization = [DiarizedSegment(speakerID: "A", start: 0, end: 5)]

        let result = TranscriptMerger.merge(runs: runs, diarization: diarization)

        #expect(result.segments.count == 1)
        #expect(result.segments[0].speakerID == Speaker.unknownID)
        #expect(result.speakers.map(\.displayName) == ["Unknown speaker"])
    }

    @Test("With no diarization at all, every run is Unknown but the text survives")
    func noDiarization() {
        let runs = [
            TimedTextRun(start: 0, end: 1, text: "Hello"),
            TimedTextRun(start: 1, end: 2, text: "world"),
        ]

        let result = TranscriptMerger.merge(runs: runs, diarization: [])

        #expect(result.segments.count == 1)
        #expect(result.segments[0].text == "Hello world")
        #expect(result.segments[0].speakerID == Speaker.unknownID)
    }

    @Test("Empty and whitespace-only runs are dropped")
    func emptyRunsAreDropped() {
        let runs = [
            TimedTextRun(start: 0, end: 1, text: "  "),
            TimedTextRun(start: 1, end: 2, text: "Real text."),
            TimedTextRun(start: 2, end: 3, text: ""),
        ]
        let diarization = [DiarizedSegment(speakerID: "A", start: 0, end: 4)]

        let result = TranscriptMerger.merge(runs: runs, diarization: diarization)

        #expect(result.segments.count == 1)
        #expect(result.segments[0].text == "Real text.")
    }

    @Test("Out-of-order runs are sorted before merging")
    func runsAreSorted() {
        let runs = [
            TimedTextRun(start: 1.5, end: 2.5, text: "Second."),
            TimedTextRun(start: 0, end: 1, text: "First."),
        ]
        let diarization = [DiarizedSegment(speakerID: "A", start: 0, end: 6)]

        let result = TranscriptMerger.merge(runs: runs, diarization: diarization)

        #expect(result.segments.count == 1)
        #expect(result.segments[0].text == "First. Second.")
        #expect(result.segments[0].start == 0)
        #expect(result.segments[0].end == 2.5)
    }

    @Test("Punctuation-leading fragments join without a stray space")
    func punctuationJoin() {
        let runs = [
            TimedTextRun(start: 0, end: 1, text: "Yes"),
            TimedTextRun(start: 1, end: 2, text: ", absolutely."),
        ]
        let diarization = [DiarizedSegment(speakerID: "A", start: 0, end: 3)]

        let result = TranscriptMerger.merge(runs: runs, diarization: diarization)

        #expect(result.segments[0].text == "Yes, absolutely.")
    }

    @Test("splitAtWordBoundary snaps to the nearest word gap")
    func wordBoundarySplitting() {
        let (head, tail) = TranscriptMerger.splitAtWordBoundary("alpha beta gamma delta", ratio: 0.5)!
        #expect(head == "alpha beta")
        #expect(tail == "gamma delta")

        // A single word offers no interior boundary, so it is never split.
        #expect(TranscriptMerger.splitAtWordBoundary("indivisible", ratio: 0.5) == nil)
    }

    @Test("A boundary falling mid-word snaps to the pause between words")
    func boundarySnapsToPause() {
        // "Sure" runs 3.8–4.2; the diarizer puts the change at 4.0, mid-word.
        let runs = [
            TimedTextRun(start: 3.0, end: 3.7, text: "release."),
            TimedTextRun(start: 3.8, end: 4.2, text: "Sure."),
            TimedTextRun(start: 4.4, end: 5.0, text: "The"),
        ]
        let diarization = [
            DiarizedSegment(speakerID: "A", start: 0, end: 4.0),
            DiarizedSegment(speakerID: "B", start: 4.0, end: 9),
        ]

        let refined = TranscriptMerger.snappingBoundariesToPauses(
            diarization,
            runs: runs,
            tolerance: 0.75
        )

        // The wider pause (3.7–3.8 is 0.1 s, 4.2–4.4 is 0.2 s) wins, so "Sure."
        // stays whole and goes to the speaker who actually said it.
        #expect(abs(refined[0].end - 4.3) < 0.0001)
        #expect(refined[0].end == refined[1].start)

        let result = TranscriptMerger.merge(runs: runs, diarization: diarization)
        #expect(result.segments.count == 2)
        #expect(result.segments[0].text == "release. Sure.")
        #expect(result.segments[1].text == "The")
    }

    @Test("Boundaries are left alone when no pause is close enough")
    func boundaryIsNotSnappedBeyondTolerance() {
        let runs = [
            TimedTextRun(start: 0, end: 1, text: "one"),
            TimedTextRun(start: 20, end: 21, text: "two"),
        ]
        let diarization = [
            DiarizedSegment(speakerID: "A", start: 0, end: 5),
            DiarizedSegment(speakerID: "B", start: 5, end: 25),
        ]

        let refined = TranscriptMerger.snappingBoundariesToPauses(
            diarization,
            runs: runs,
            tolerance: 0.75
        )

        #expect(refined == diarization)
    }

    @Test("Boundaries between segments of the same speaker are untouched")
    func sameSpeakerBoundariesAreUntouched() {
        let runs = [
            TimedTextRun(start: 0, end: 1, text: "one"),
            TimedTextRun(start: 1.2, end: 2, text: "two"),
        ]
        let diarization = [
            DiarizedSegment(speakerID: "A", start: 0, end: 1.05),
            DiarizedSegment(speakerID: "A", start: 1.05, end: 3),
        ]

        #expect(
            TranscriptMerger.snappingBoundariesToPauses(diarization, runs: runs, tolerance: 0.75)
                == diarization
        )
    }

    @Test("Snapping never pushes a boundary outside its own segments")
    func snappingStaysWithinSegments() {
        // The only nearby pause sits before segment B even starts.
        let runs = [
            TimedTextRun(start: 0, end: 1.0, text: "one"),
            TimedTextRun(start: 1.1, end: 1.4, text: "two"),
            TimedTextRun(start: 5.0, end: 5.5, text: "three"),
        ]
        let diarization = [
            DiarizedSegment(speakerID: "A", start: 1.3, end: 1.5),
            DiarizedSegment(speakerID: "B", start: 1.5, end: 6),
        ]

        let refined = TranscriptMerger.snappingBoundariesToPauses(
            diarization,
            runs: runs,
            tolerance: 0.75
        )

        for segment in refined {
            #expect(segment.start < segment.end)
        }
        #expect(refined[0].end == refined[1].start)
    }

    @Test("Snapping can be turned off")
    func snappingDisabled() {
        let runs = [
            TimedTextRun(start: 0, end: 1, text: "one"),
            TimedTextRun(start: 1.1, end: 2, text: "two"),
        ]
        let diarization = [
            DiarizedSegment(speakerID: "A", start: 0, end: 1.05),
            DiarizedSegment(speakerID: "B", start: 1.05, end: 3),
        ]

        #expect(
            TranscriptMerger.snappingBoundariesToPauses(diarization, runs: runs, tolerance: 0)
                == diarization
        )
    }

    @Test("A long pause splits a same-speaker turn")
    func longPauseStartsNewUtterance() {
        let runs = [
            TimedTextRun(start: 0, end: 1, text: "First thought."),
            TimedTextRun(start: 1.2, end: 2, text: "Still going."),
            TimedTextRun(start: 4, end: 5, text: "After a pause."),
        ]
        let diarization = [DiarizedSegment(speakerID: "A", start: 0, end: 5)]

        let result = TranscriptMerger.merge(runs: runs, diarization: diarization)

        #expect(result.segments.map(\.text) == ["First thought. Still going.", "After a pause."])
        #expect(result.segments.allSatisfy { $0.speakerID == "A" })
        #expect(result.speakers.count == 1)
    }

    @Test("An infinite break gap coalesces a whole turn")
    func infiniteBreakGapKeepsOneUtterance() {
        let runs = [
            TimedTextRun(start: 0, end: 1, text: "First thought."),
            TimedTextRun(start: 4, end: 5, text: "After a pause."),
        ]
        let diarization = [DiarizedSegment(speakerID: "A", start: 0, end: 5)]

        let result = TranscriptMerger.merge(
            runs: runs,
            diarization: diarization,
            options: .init(utteranceBreakGap: .infinity, maxUtteranceDuration: .infinity)
        )

        #expect(result.segments.map(\.text) == ["First thought. After a pause."])
    }

    @Test("A long utterance ends at the next sentence end")
    func longUtteranceSplitsAtSentenceEnd() {
        let runs = [
            TimedTextRun(start: 0, end: 20, text: "We shipped"),
            TimedTextRun(start: 20, end: 31, text: "the build,"),
            TimedTextRun(start: 31, end: 32, text: "on time."),
            TimedTextRun(start: 32, end: 33, text: "Next topic."),
        ]
        let diarization = [DiarizedSegment(speakerID: "A", start: 0, end: 33)]

        let result = TranscriptMerger.merge(runs: runs, diarization: diarization)

        // Past 30 s at "the build," it keeps going to the sentence end.
        #expect(result.segments.map(\.text) == ["We shipped the build, on time.", "Next topic."])
    }

    @Test("Custom speaker names survive a reprocess")
    func renamesArePreserved() {
        let fresh = [
            Speaker(id: "A", displayName: "Speaker 1", colorIndex: 1),
            Speaker(id: "B", displayName: "Speaker 2", colorIndex: 2),
        ]
        let existing = [
            Speaker(id: "A", displayName: "Priya", colorIndex: 1),
            Speaker(id: "B", displayName: "Speaker 2", colorIndex: 2),
        ]

        let merged = ProcessingPipeline.preservingRenames(fresh, from: existing)

        #expect(merged[0].displayName == "Priya")
        #expect(merged[1].displayName == "Speaker 2")
    }
}
