import Foundation

/// Result of attributing timed text to diarized speakers.
public struct MergeResult: Sendable, Equatable {
    /// Coalesced utterances in chronological order.
    public var segments: [TranscriptSegment]
    /// Speakers actually referenced by `segments`, numbered by first appearance.
    public var speakers: [Speaker]

    public init(segments: [TranscriptSegment], speakers: [Speaker]) {
        self.segments = segments
        self.speakers = speakers
    }
}

/// Pure, deterministic attribution of transcription runs to diarization segments.
///
/// The transcriber emits timed runs of text with no speaker information; the
/// diarizer emits speaker-labelled time spans with no text. Merging assigns each
/// run to the speaker whose span overlaps it most, splitting a run when it
/// clearly straddles a speaker change, then coalesces adjacent same-speaker runs
/// into utterances.
public enum TranscriptMerger {

    public struct Options: Sendable, Equatable {
        /// A run with no overlap at all is attached to the nearest segment within
        /// this many seconds; beyond it the run becomes `Speaker.unknownID`.
        public var nearestNeighborTolerance: TimeInterval
        /// Each of the top two overlaps must cover at least this share of the run
        /// before the run is considered to straddle a speaker change.
        public var splitShareThreshold: Double
        /// Both sides of a split must be at least this long, otherwise the run is
        /// assigned whole to the dominant speaker.
        public var minimumSplitDuration: TimeInterval
        /// How far a speaker-change boundary may be nudged to land in a pause
        /// between words. Set to zero to disable snapping.
        public var boundarySnapTolerance: TimeInterval

        public init(
            nearestNeighborTolerance: TimeInterval = 1.0,
            splitShareThreshold: Double = 0.25,
            minimumSplitDuration: TimeInterval = 0.2,
            boundarySnapTolerance: TimeInterval = 0.75
        ) {
            self.nearestNeighborTolerance = nearestNeighborTolerance
            self.splitShareThreshold = splitShareThreshold
            self.minimumSplitDuration = minimumSplitDuration
            self.boundarySnapTolerance = boundarySnapTolerance
        }

        public static let `default` = Options()
    }

    /// A run fragment after attribution but before coalescing.
    private struct Piece {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
        var speakerID: String
    }

    public static func merge(
        runs: [TimedTextRun],
        diarization: [DiarizedSegment],
        options: Options = .default,
        idGenerator: () -> UUID = UUID.init
    ) -> MergeResult {
        let orderedRuns = runs
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        let orderedSegments = diarization
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }

        guard !orderedRuns.isEmpty else { return MergeResult(segments: [], speakers: []) }

        let refinedSegments = snappingBoundariesToPauses(
            orderedSegments,
            runs: orderedRuns,
            tolerance: options.boundarySnapTolerance
        )

        var pieces: [Piece] = []
        pieces.reserveCapacity(orderedRuns.count)
        for run in orderedRuns {
            pieces.append(contentsOf: attribute(run: run, to: refinedSegments, options: options))
        }

        let utterances = coalesce(pieces, idGenerator: idGenerator)
        return MergeResult(segments: utterances, speakers: numberSpeakers(in: utterances))
    }

    // MARK: - Boundary refinement

    /// Nudges each speaker-change boundary onto a pause between words.
    ///
    /// Diarization localizes a speaker change to within a few hundred
    /// milliseconds, which is often enough to land in the middle of a word: the
    /// first word of a new turn then gets attributed to the previous speaker.
    /// The transcriber, by contrast, knows exactly where each word starts and
    /// ends. Snapping the boundary to the nearby pause — preferring the longest
    /// one, since a turn change usually carries a longer silence than a gap
    /// between words — fixes that class of error, and never splits a word.
    static func snappingBoundariesToPauses(
        _ segments: [DiarizedSegment],
        runs: [TimedTextRun],
        tolerance: TimeInterval
    ) -> [DiarizedSegment] {
        guard tolerance > 0, segments.count > 1, runs.count > 1 else { return segments }

        // Candidate pauses: the space between the end of one word and the start
        // of the next, plus the leading and trailing edges of the transcript.
        var pauses: [(midpoint: TimeInterval, width: TimeInterval)] = []
        for index in 0..<(runs.count - 1) {
            let gapStart = runs[index].end
            let gapEnd = runs[index + 1].start
            guard gapEnd >= gapStart else { continue }
            pauses.append(((gapStart + gapEnd) / 2, gapEnd - gapStart))
        }
        guard !pauses.isEmpty else { return segments }

        var refined = segments
        for index in 0..<(refined.count - 1) where refined[index].speakerID != refined[index + 1].speakerID {
            let current = refined[index]
            let next = refined[index + 1]
            let boundary = (current.end + next.start) / 2

            let candidates = pauses.filter { abs($0.midpoint - boundary) <= tolerance }
            // Stay strictly inside both segments so boundaries never cross.
            let admissible = candidates.filter {
                $0.midpoint > current.start && $0.midpoint < next.end
            }
            guard let best = admissible.max(by: { lhs, rhs in
                lhs.width == rhs.width
                    ? abs(lhs.midpoint - boundary) > abs(rhs.midpoint - boundary)
                    : lhs.width < rhs.width
            }) else { continue }

            refined[index].end = best.midpoint
            refined[index + 1].start = best.midpoint
        }
        return refined
    }

    // MARK: - Attribution

    private static func attribute(
        run: TimedTextRun,
        to segments: [DiarizedSegment],
        options: Options
    ) -> [Piece] {
        let whole = [Piece(start: run.start, end: run.end, text: run.text, speakerID: Speaker.unknownID)]
        guard !segments.isEmpty else { return whole }

        let overlaps = segments
            .map { (segment: $0, overlap: overlapDuration(run.start, run.end, $0.start, $0.end)) }
            .filter { $0.overlap > 0 }
            .sorted { $0.overlap > $1.overlap }

        guard let best = overlaps.first else {
            // No overlap anywhere: attach to the nearest segment if it is close enough.
            guard let nearest = nearestSegment(to: run, in: segments, within: options.nearestNeighborTolerance)
            else { return whole }
            return [Piece(start: run.start, end: run.end, text: run.text, speakerID: nearest.speakerID)]
        }

        let runDuration = run.duration
        // A zero-length run cannot be split; give it the dominant speaker.
        guard runDuration > 0 else {
            return [Piece(start: run.start, end: run.end, text: run.text, speakerID: best.segment.speakerID)]
        }

        // Only consider a split when the two strongest overlaps belong to
        // different speakers and each covers a meaningful share of the run.
        let runner = overlaps.dropFirst().first { $0.segment.speakerID != best.segment.speakerID }
        guard let second = runner,
              best.overlap / runDuration >= options.splitShareThreshold,
              second.overlap / runDuration >= options.splitShareThreshold
        else {
            return [Piece(start: run.start, end: run.end, text: run.text, speakerID: best.segment.speakerID)]
        }

        let (first, last) = best.segment.start <= second.segment.start
            ? (best.segment, second.segment)
            : (second.segment, best.segment)

        // Speaker change happens somewhere between the end of the earlier span and
        // the start of the later one; use the midpoint of that gap (or overlap).
        let rawBoundary = (min(first.end, last.end) + max(first.start, last.start)) / 2
        let boundary = min(max(rawBoundary, run.start), run.end)

        guard boundary - run.start >= options.minimumSplitDuration,
              run.end - boundary >= options.minimumSplitDuration
        else {
            return [Piece(start: run.start, end: run.end, text: run.text, speakerID: best.segment.speakerID)]
        }

        let ratio = (boundary - run.start) / runDuration
        guard let (head, tail) = splitAtWordBoundary(run.text, ratio: ratio) else {
            return [Piece(start: run.start, end: run.end, text: run.text, speakerID: best.segment.speakerID)]
        }

        return [
            Piece(start: run.start, end: boundary, text: head, speakerID: first.speakerID),
            Piece(start: boundary, end: run.end, text: tail, speakerID: last.speakerID),
        ]
    }

    private static func overlapDuration(
        _ aStart: TimeInterval, _ aEnd: TimeInterval,
        _ bStart: TimeInterval, _ bEnd: TimeInterval
    ) -> TimeInterval {
        max(0, min(aEnd, bEnd) - max(aStart, bStart))
    }

    private static func nearestSegment(
        to run: TimedTextRun,
        in segments: [DiarizedSegment],
        within tolerance: TimeInterval
    ) -> DiarizedSegment? {
        var best: (segment: DiarizedSegment, gap: TimeInterval)?
        for segment in segments {
            // Distance from the run interval to the segment interval.
            let gap = max(0, max(segment.start - run.end, run.start - segment.end))
            if gap <= tolerance, best == nil || gap < best!.gap {
                best = (segment, gap)
            }
        }
        return best?.segment
    }

    /// Splits `text` near `ratio` of its length, snapping to the closest word
    /// boundary so words are never cut in half. Returns `nil` when the text has
    /// no interior word boundary to split on.
    static func splitAtWordBoundary(_ text: String, ratio: Double) -> (String, String)? {
        let characters = Array(text)
        guard characters.count > 1 else { return nil }

        // Candidate split points: the index just after each run of whitespace.
        var boundaries: [Int] = []
        var index = 0
        while index < characters.count {
            if characters[index].isWhitespace {
                var next = index
                while next < characters.count, characters[next].isWhitespace { next += 1 }
                if next > 0, next < characters.count { boundaries.append(next) }
                index = next
            } else {
                index += 1
            }
        }
        guard !boundaries.isEmpty else { return nil }

        let target = Double(characters.count) * min(max(ratio, 0), 1)
        let chosen = boundaries.min { abs(Double($0) - target) < abs(Double($1) - target) }!

        let head = String(characters[0..<chosen]).trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = String(characters[chosen...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty, !tail.isEmpty else { return nil }
        return (head, tail)
    }

    // MARK: - Coalescing

    private static func coalesce(_ pieces: [Piece], idGenerator: () -> UUID) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        for piece in pieces {
            let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            if var last = segments.last, last.speakerID == piece.speakerID {
                last.text = join(last.text, text)
                last.end = max(last.end, piece.end)
                segments[segments.count - 1] = last
            } else {
                segments.append(
                    TranscriptSegment(
                        id: idGenerator(),
                        start: piece.start,
                        end: piece.end,
                        text: text,
                        speakerID: piece.speakerID
                    )
                )
            }
        }
        return segments
    }

    /// Joins two text fragments with a single space, unless the left side already
    /// ends in whitespace or the right side opens with closing punctuation.
    private static func join(_ left: String, _ right: String) -> String {
        guard let first = right.first else { return left }
        if left.hasSuffix(" ") { return left + right }
        if ",.!?;:".contains(first) { return left + right }
        return left + " " + right
    }

    // MARK: - Speaker numbering

    private static func numberSpeakers(in segments: [TranscriptSegment]) -> [Speaker] {
        var speakers: [Speaker] = []
        var seen: Set<String> = []
        var number = 0

        for segment in segments where !seen.contains(segment.speakerID) {
            seen.insert(segment.speakerID)
            if segment.speakerID == Speaker.unknownID {
                speakers.append(
                    Speaker(id: Speaker.unknownID, displayName: "Unknown speaker", colorIndex: 0)
                )
            } else {
                number += 1
                speakers.append(
                    Speaker(
                        id: segment.speakerID,
                        displayName: "Speaker \(number)",
                        colorIndex: number
                    )
                )
            }
        }
        return speakers
    }
}
