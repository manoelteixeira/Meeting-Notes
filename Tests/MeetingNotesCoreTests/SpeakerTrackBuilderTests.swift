import Foundation
import Testing

@testable import MeetingNotesCore

@Suite("Speaker track building")
struct SpeakerTrackBuilderTests {

    private let rate = 1_000.0

    /// A 4 s ramp so any sample identifies its own position.
    private var samples: [Float] { (0..<4_000).map { Float($0) / 4_000 + 0.1 } }

    private let segments = [
        DiarizedSegment(speakerID: "A", start: 0.5, end: 1.5),
        DiarizedSegment(speakerID: "B", start: 1.5, end: 2.5),
        DiarizedSegment(speakerID: "A", start: 2.6, end: 3.0),
    ]

    @Test("Speakers are ordered by first appearance")
    func speakerOrder() {
        let shuffled = [
            DiarizedSegment(speakerID: "B", start: 5, end: 6),
            DiarizedSegment(speakerID: "C", start: 0, end: 1),
            DiarizedSegment(speakerID: "B", start: 2, end: 3),
            DiarizedSegment(speakerID: "A", start: 1, end: 2),
        ]
        #expect(SpeakerTrackBuilder.speakerOrder(shuffled) == ["C", "A", "B"])
    }

    @Test("Spans are padded, floored at zero, and merged when they touch")
    func paddedSpans() {
        let options = SpeakerTrackBuilder.Options(padding: 0.25)
        let spans = SpeakerTrackBuilder.paddedSpans(for: "A", in: segments, options: options)
        // 0.5–1.5 becomes 0.25–1.75; 2.6–3.0 becomes 2.35–3.25: no overlap.
        #expect(spans == [0.25...1.75, 2.35...3.25])

        let early = [DiarizedSegment(speakerID: "A", start: 0.1, end: 0.3)]
        #expect(SpeakerTrackBuilder.paddedSpans(for: "A", in: early, options: options) == [0...0.55])

        let touching = [
            DiarizedSegment(speakerID: "A", start: 1, end: 2),
            DiarizedSegment(speakerID: "A", start: 2.3, end: 3),
        ]
        #expect(SpeakerTrackBuilder.paddedSpans(for: "A", in: touching, options: options) == [0.75...3.25])
    }

    @Test("A track keeps its own spans and silences everything else")
    func masking() {
        let options = SpeakerTrackBuilder.Options(padding: 0.25, fadeDuration: 0.01)
        let track = SpeakerTrackBuilder.track(
            for: "B", segments: segments, samples: samples, sampleRate: rate, options: options
        )

        #expect(track.speakerID == "B")
        #expect(track.spans == [1.25...2.75])
        #expect(track.samples.count == samples.count)
        // Well inside the span the audio is untouched...
        #expect(track.samples[2_000] == samples[2_000])
        #expect(track.samples[1_300] == samples[1_300])
        // ...and outside it is silent.
        #expect(track.samples[0] == 0)
        #expect(track.samples[1_000] == 0)
        #expect(track.samples[3_000] == 0)
        #expect(track.samples[3_999] == 0)
    }

    @Test("Edges fade in and out inside the span")
    func fades() {
        let options = SpeakerTrackBuilder.Options(padding: 0, fadeDuration: 0.01)
        let single = [DiarizedSegment(speakerID: "A", start: 1.0, end: 2.0)]
        let track = SpeakerTrackBuilder.track(
            for: "A", segments: single, samples: samples, sampleRate: rate, options: options
        )

        // Ten samples of ramp at each edge, strictly rising then strictly falling.
        let head = Array(track.samples[1_000..<1_010])
        #expect(head.first! < samples[1_000])
        #expect(zip(head, head.dropFirst()).allSatisfy { $0 < $1 })
        #expect(track.samples[1_010] == samples[1_010])

        let tail = Array(track.samples[1_990..<2_000])
        #expect(zip(tail, tail.dropFirst()).allSatisfy { $0 > $1 })
        #expect(track.samples[1_989] == samples[1_989])
        #expect(track.samples[2_000] == 0)
    }

    @Test("A span at the very start of the file is not faded in")
    func noFadeAtFileEdge() {
        let options = SpeakerTrackBuilder.Options(padding: 0, fadeDuration: 0.01)
        let opening = [DiarizedSegment(speakerID: "A", start: 0, end: 1.0)]
        let track = SpeakerTrackBuilder.track(
            for: "A", segments: opening, samples: samples, sampleRate: rate, options: options
        )
        #expect(track.samples[0] == samples[0])
        #expect(track.samples[5] == samples[5])
    }

    @Test("Overlapping speech lands in both speakers' tracks")
    func overlapKeptInBoth() {
        let overlapping = [
            DiarizedSegment(speakerID: "A", start: 0, end: 2.0),
            DiarizedSegment(speakerID: "B", start: 1.0, end: 3.0),
        ]
        let options = SpeakerTrackBuilder.Options(padding: 0, fadeDuration: 0)
        let a = SpeakerTrackBuilder.track(
            for: "A", segments: overlapping, samples: samples, sampleRate: rate, options: options
        )
        let b = SpeakerTrackBuilder.track(
            for: "B", segments: overlapping, samples: samples, sampleRate: rate, options: options
        )
        #expect(a.samples[1_500] == samples[1_500])
        #expect(b.samples[1_500] == samples[1_500])
        #expect(a.samples[2_500] == 0)
        #expect(b.samples[500] == 0)
    }

    @Test("Spans past the end of the audio are clipped, not fatal")
    func spanBeyondAudio() {
        let long = [DiarizedSegment(speakerID: "A", start: 3.5, end: 10)]
        let track = SpeakerTrackBuilder.track(
            for: "A", segments: long, samples: samples, sampleRate: rate,
            options: .init(padding: 0, fadeDuration: 0)
        )
        #expect(track.samples.count == samples.count)
        #expect(track.samples[3_999] == samples[3_999])
        #expect(track.samples[3_499] == 0)
    }

    @Test("A run counts as kept only where it overlaps a span")
    func overlaps() {
        let spans: [ClosedRange<TimeInterval>] = [1...2, 3...4]
        #expect(SpeakerTrackBuilder.overlaps(TimedTextRun(start: 1.5, end: 1.8, text: "in"), spans))
        #expect(SpeakerTrackBuilder.overlaps(TimedTextRun(start: 0.5, end: 1.2, text: "edge"), spans))
        #expect(!SpeakerTrackBuilder.overlaps(TimedTextRun(start: 2, end: 3, text: "between"), spans))
        #expect(!SpeakerTrackBuilder.overlaps(TimedTextRun(start: 5, end: 6, text: "after"), spans))
        // Zero-length runs count when they sit inside a span.
        #expect(SpeakerTrackBuilder.overlaps(TimedTextRun(start: 3.5, end: 3.5, text: "dot"), spans))
        #expect(!SpeakerTrackBuilder.overlaps(TimedTextRun(start: 2.5, end: 2.5, text: "dot"), spans))
        #expect(!SpeakerTrackBuilder.overlaps(TimedTextRun(start: 1, end: 2, text: "x"), []))
    }

    @Test("The same word heard on two tracks at once goes to whoever's turn covers it")
    func bleedDedupe() {
        let turns = [
            DiarizedSegment(speakerID: "A", start: 0, end: 14.16),
            DiarizedSegment(speakerID: "B", start: 14.24, end: 14.64),
        ]
        // A's track heard B's "Yeah." with timestamps straddling the boundary.
        let input: [(speakerID: String, runs: [TimedTextRun])] = [
            ("A", [
                TimedTextRun(start: 11, end: 13.5, text: "Manuel, but Manuel."),
                TimedTextRun(start: 14.0, end: 14.4, text: "Yeah."),
            ]),
            ("B", [TimedTextRun(start: 14.2, end: 14.6, text: "yeah")]),
        ]
        let cleaned = SpeakerTrackBuilder.droppingBleed(input, segments: turns)
        #expect(cleaned[0].runs.map(\.text) == ["Manuel, but Manuel."])
        #expect(cleaned[1].runs.map(\.text) == ["yeah"])

        // The diarizer marked B's onset late, so A's turn covers more of the
        // word; it still ends inside B's turn, so it is B's first word.
        let lateOnset: [(speakerID: String, runs: [TimedTextRun])] = [
            ("A", [TimedTextRun(start: 13.9, end: 14.3, text: "Yeah.")]),
            ("B", [TimedTextRun(start: 13.9, end: 14.3, text: "Yeah.")]),
        ]
        #expect(SpeakerTrackBuilder.droppingBleed(lateOnset, segments: turns).map { $0.runs.count } == [0, 1])

        // A's last word caught in B's padding stays A's: it ends in A's turn.
        let lastWord: [(speakerID: String, runs: [TimedTextRun])] = [
            ("A", [TimedTextRun(start: 13.6, end: 14.1, text: "Manuel.")]),
            ("B", [TimedTextRun(start: 13.7, end: 14.1, text: "Manuel.")]),
        ]
        #expect(SpeakerTrackBuilder.droppingBleed(lastWord, segments: turns).map { $0.runs.count } == [1, 0])

        // A reply enclosed by a long turn belongs to the short, enclosed turn.
        let enclosing = [
            DiarizedSegment(speakerID: "A", start: 0, end: 10),
            DiarizedSegment(speakerID: "B", start: 4, end: 4.5),
        ]
        let enclosed: [(speakerID: String, runs: [TimedTextRun])] = [
            ("A", [TimedTextRun(start: 4.0, end: 4.4, text: "Yes.")]),
            ("B", [TimedTextRun(start: 4.0, end: 4.4, text: "yes")]),
        ]
        #expect(SpeakerTrackBuilder.droppingBleed(enclosed, segments: enclosing).map { $0.runs.count } == [0, 1])

        // Words pair off one to one: one bled copy never removes two real ones.
        let repeated: [(speakerID: String, runs: [TimedTextRun])] = [
            ("A", [TimedTextRun(start: 14.0, end: 14.2, text: "the")]),
            ("B", [
                TimedTextRun(start: 14.2, end: 14.35, text: "the"),
                TimedTextRun(start: 14.4, end: 14.6, text: "the"),
            ]),
        ]
        #expect(SpeakerTrackBuilder.droppingBleed(repeated, segments: turns).map { $0.runs.count } == [0, 2])

        // Different words at the same moment are genuine overlap and both stay.
        let overlap: [(speakerID: String, runs: [TimedTextRun])] = [
            ("A", [TimedTextRun(start: 5, end: 6, text: "Yes.")]),
            ("B", [TimedTextRun(start: 5, end: 6, text: "No.")]),
        ]
        let kept = SpeakerTrackBuilder.droppingBleed(overlap, segments: turns)
        #expect(kept.map { $0.runs.count } == [1, 1])

        // The same word far apart in time is two separate words.
        let apart: [(speakerID: String, runs: [TimedTextRun])] = [
            ("A", [TimedTextRun(start: 1, end: 1.4, text: "Yeah.")]),
            ("B", [TimedTextRun(start: 14.3, end: 14.6, text: "Yeah.")]),
        ]
        #expect(SpeakerTrackBuilder.droppingBleed(apart, segments: turns).map { $0.runs.count } == [1, 1])

        // A tie in coverage keeps the earlier speaker's copy.
        let tie: [(speakerID: String, runs: [TimedTextRun])] = [
            ("A", [TimedTextRun(start: 20, end: 21, text: "Okay.")]),
            ("B", [TimedTextRun(start: 20, end: 21, text: "Okay.")]),
        ]
        let tied = SpeakerTrackBuilder.droppingBleed(tie, segments: turns)
        #expect(tied.map { $0.runs.count } == [1, 0])
    }

    @Test("Audio no speaker covers becomes a leftover track only when something is audible in it")
    func leftoverTrack() {
        // 4 s: speech-like tone in 0–1 and 2.5–3.6, silence elsewhere.
        let rate = 1_000.0
        var audio = [Float](repeating: 0, count: 4_000)
        for index in 0..<1_000 { audio[index] = 0.3 }
        for index in 2_500..<3_600 { audio[index] = 0.3 }
        let options = SpeakerTrackBuilder.Options(padding: 0.25, fadeDuration: 0)

        // The diarizer found the first burst only: the second is 1.1 s of
        // sound it missed, so a leftover track is made from the gap.
        let partial = [DiarizedSegment(speakerID: "A", start: 0, end: 1)]
        let leftover = SpeakerTrackBuilder.leftoverTrack(
            segments: partial, samples: audio, sampleRate: rate, options: options
        )
        #expect(leftover?.speakerID == Speaker.unknownID)
        #expect(leftover?.spans == [1.25...4.0])
        #expect(leftover?.samples[500] == 0)
        #expect(leftover?.samples[3_000] == 0.3)
        #expect(leftover?.samples[2_000] == 0)

        // Found both bursts: the gaps are silent, no leftover pass.
        let complete = [
            DiarizedSegment(speakerID: "A", start: 0, end: 1),
            DiarizedSegment(speakerID: "B", start: 2.5, end: 3.6),
        ]
        #expect(SpeakerTrackBuilder.leftoverTrack(
            segments: complete, samples: audio, sampleRate: rate, options: options
        ) == nil)

        // Missed sound shorter than the minimum is not worth a pass.
        #expect(SpeakerTrackBuilder.leftoverTrack(
            segments: partial, samples: audio, sampleRate: rate, options: options, minimumSpeech: 1.5
        ) == nil)

        // Everything covered: nothing left over at all.
        let whole = [DiarizedSegment(speakerID: "A", start: 0, end: 4)]
        #expect(SpeakerTrackBuilder.leftoverTrack(
            segments: whole, samples: audio, sampleRate: rate, options: options
        ) == nil)
    }

    @Test("A word caught in the padding belongs to whoever's turn it sits on")
    func ownership() {
        let turns = [
            DiarizedSegment(speakerID: "A", start: 0, end: 2),
            DiarizedSegment(speakerID: "B", start: 2, end: 4),
        ]
        let spansA = SpeakerTrackBuilder.paddedSpans(for: "A", in: turns, options: .init(padding: 0.25))

        // Squarely on A's own turn.
        #expect(SpeakerTrackBuilder.owns(
            TimedTextRun(start: 0.5, end: 1.5, text: "mine"), speakerID: "A", spans: spansA, segments: turns
        ))
        // Straddling the boundary still counts as A's.
        #expect(SpeakerTrackBuilder.owns(
            TimedTextRun(start: 1.8, end: 2.1, text: "edge"), speakerID: "A", spans: spansA, segments: turns
        ))
        // Only in A's padding, on B's turn: B's word bleeding through.
        #expect(!SpeakerTrackBuilder.owns(
            TimedTextRun(start: 2.05, end: 2.2, text: "bleed"), speakerID: "A", spans: spansA, segments: turns
        ))
        // Only in A's padding but on nobody's turn: keep it, someone said it.
        let gapped = [
            DiarizedSegment(speakerID: "A", start: 0, end: 2),
            DiarizedSegment(speakerID: "B", start: 3, end: 4),
        ]
        #expect(SpeakerTrackBuilder.owns(
            TimedTextRun(start: 2.05, end: 2.2, text: "trailing"), speakerID: "A", spans: spansA, segments: gapped
        ))
        // Outside the kept audio altogether.
        #expect(!SpeakerTrackBuilder.owns(
            TimedTextRun(start: 3, end: 3.5, text: "silence"), speakerID: "A", spans: spansA, segments: turns
        ))
    }
}
