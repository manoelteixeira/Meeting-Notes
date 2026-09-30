import Foundation

/// Builds one audio track per diarized speaker: the speaker's own spans kept,
/// everything else silenced, the timeline untouched.
///
/// Transcribing a full-length track means the recognizer's timestamps already
/// sit on the meeting's timeline, so nothing has to be offset afterwards, and
/// every word it hears belongs to one known speaker. Spans are padded a little
/// so a speaker change localized slightly late never clips a first word, and
/// each edge is faded to keep a hard cut from reading as a click.
public enum SpeakerTrackBuilder {

    public struct Options: Sendable, Equatable {
        /// Added before and after each span, since diarization boundaries land
        /// within a few hundred milliseconds of the real change.
        public var padding: TimeInterval
        /// Length of the linear ramp inside each span edge.
        public var fadeDuration: TimeInterval

        public init(padding: TimeInterval = 0.25, fadeDuration: TimeInterval = 0.01) {
            self.padding = padding
            self.fadeDuration = fadeDuration
        }

        public static let `default` = Options()
    }

    /// A speaker's masked audio, described rather than materialized: the
    /// spans that are kept and how their edges fade. `fillMasked` renders it
    /// from the meeting's samples a chunk at a time, so an hour-long track
    /// never needs a second full-length buffer.
    public struct Track: Sendable, Equatable {
        public var speakerID: String
        /// Padded, merged spans in seconds; audio outside them is silent.
        public var spans: [ClosedRange<TimeInterval>]
        /// Length of the linear ramp inside each span edge.
        public var fadeDuration: TimeInterval

        public init(
            speakerID: String,
            spans: [ClosedRange<TimeInterval>],
            fadeDuration: TimeInterval = Options.default.fadeDuration
        ) {
            self.speakerID = speakerID
            self.spans = spans
            self.fadeDuration = fadeDuration
        }
    }

    /// Speaker ids in order of first appearance.
    public static func speakerOrder(_ segments: [DiarizedSegment]) -> [String] {
        var seen: Set<String> = []
        return segments
            .sorted { $0.start < $1.start }
            .compactMap { seen.insert($0.speakerID).inserted ? $0.speakerID : nil }
    }

    /// The speaker's spans padded by `options.padding`, never before zero,
    /// with overlapping or touching spans merged. The end is not clamped:
    /// `track` clips to the audio it has, and a run can only ever be
    /// recognized inside that audio anyway.
    public static func paddedSpans(
        for speakerID: String,
        in segments: [DiarizedSegment],
        options: Options = .default
    ) -> [ClosedRange<TimeInterval>] {
        merging(
            segments
                .filter { $0.speakerID == speakerID && $0.duration > 0 }
                .map { segment in
                    let start = max(segment.start - options.padding, 0)
                    return start...max(segment.end + options.padding, start)
                }
        )
    }

    /// The masked track for `speakerID`.
    ///
    /// Overlapping speech is kept in every track it belongs to, because each
    /// track only looks at its own speaker's spans.
    public static func track(
        for speakerID: String,
        segments: [DiarizedSegment],
        options: Options = .default
    ) -> Track {
        Track(
            speakerID: speakerID,
            spans: paddedSpans(for: speakerID, in: segments, options: options),
            fadeDuration: options.fadeDuration
        )
    }

    /// The audio no speaker's padded span covers, as a track of its own, or
    /// `nil` when that audio holds under `minimumSpeech` seconds of anything
    /// audible.
    ///
    /// A diarizer can miss speech outright, and once a span is muted nothing
    /// will ever transcribe it. Rather than pay a full recognition pass on
    /// every meeting's silences, the leftover audio is measured against the
    /// loudness of the speech that was found, and only a real amount of
    /// comparable sound earns the pass. Its words are attributed afterwards to
    /// the nearest speaker, or to "Unknown speaker".
    public static func leftoverTrack(
        segments: [DiarizedSegment],
        samples: [Float],
        sampleRate: Double,
        options: Options = .default,
        minimumSpeech: TimeInterval = 1.0
    ) -> Track? {
        guard sampleRate > 0, !samples.isEmpty else { return nil }
        let duration = Double(samples.count) / sampleRate
        let covered = merging(
            Set(segments.map(\.speakerID)).flatMap { paddedSpans(for: $0, in: segments, options: options) }
        )

        var gaps: [ClosedRange<TimeInterval>] = []
        var cursor = 0.0
        for span in covered {
            if span.lowerBound > cursor { gaps.append(cursor...span.lowerBound) }
            cursor = max(cursor, span.upperBound)
        }
        if cursor < duration { gaps.append(cursor...duration) }
        guard !gaps.isEmpty else { return nil }

        guard audibleSeconds(in: gaps, comparedTo: covered, samples: samples, sampleRate: sampleRate) >= minimumSpeech
        else { return nil }
        return Track(speakerID: Speaker.unknownID, spans: gaps, fadeDuration: options.fadeDuration)
    }

    /// Whether a recognized run falls on audio that was kept: a positive
    /// overlap with some span, or a zero-length run inside one. Runs that fail
    /// this were recognized out of silence and are discarded.
    public static func overlaps(_ run: TimedTextRun, _ spans: [ClosedRange<TimeInterval>]) -> Bool {
        spans.contains { span in
            if run.duration <= 0 { return span.contains(run.start) }
            return min(run.end, span.upperBound) - max(run.start, span.lowerBound) > 0
        }
    }

    /// Whether a run recognized on `speakerID`'s track is really theirs.
    ///
    /// It must fall on kept audio. Beyond that, a run that only touches the
    /// padding while sitting on another speaker's own segment is that
    /// speaker's word bleeding through the pad, and is left to their track.
    public static func owns(
        _ run: TimedTextRun,
        speakerID: String,
        spans: [ClosedRange<TimeInterval>],
        segments: [DiarizedSegment]
    ) -> Bool {
        guard overlaps(run, spans) else { return false }
        let own = segments.filter { $0.speakerID == speakerID }.map { $0.start...max($0.start, $0.end) }
        if overlaps(run, own) { return true }
        let others = segments.filter { $0.speakerID != speakerID }.map { $0.start...max($0.start, $0.end) }
        return !overlaps(run, others)
    }

    /// Drops words heard on two tracks at once.
    ///
    /// A word at a turn boundary sits in one speaker's padding and the other's
    /// turn, and the recognizer may report it on both tracks with timestamps
    /// that straddle the boundary, so `owns` keeps both. When two speakers'
    /// runs carry the same words within `tolerance` of each other, one is
    /// dropped. The word goes to the speaker whose own segment contains its
    /// end: diarizers mark a change late rather than early, so a word that
    /// runs on into the next turn is that turn's first word, not the previous
    /// turn's last. When both turns contain it, one turn encloses the other
    /// and the shorter, more specific one is the interjection. If that settles
    /// nothing, the speaker whose segments cover more of the word wins, and on
    /// a tie the earlier speaker in `runsBySpeaker` keeps it.
    public static func droppingBleed(
        _ runsBySpeaker: [(speakerID: String, runs: [TimedTextRun])],
        segments: [DiarizedSegment],
        tolerance: TimeInterval = 0.6
    ) -> [(speakerID: String, runs: [TimedTextRun])] {
        let ownSpans = Dictionary(grouping: segments, by: \.speakerID)
            .mapValues { $0.map { $0.start...max($0.start, $0.end) } }
        func coverage(_ run: TimedTextRun, _ speakerID: String) -> TimeInterval {
            (ownSpans[speakerID] ?? []).reduce(0) { total, span in
                total + max(0, min(run.end, span.upperBound) - max(run.start, span.lowerBound))
            }
        }
        /// Length of the shortest own span containing the run's end, if any.
        func holdingLength(_ run: TimedTextRun, _ speakerID: String) -> TimeInterval? {
            (ownSpans[speakerID] ?? [])
                .filter { $0.contains(run.end) }
                .map { $0.upperBound - $0.lowerBound }
                .min()
        }
        /// Whether `second`'s copy beats `first`'s.
        func secondWins(
            _ run: TimedTextRun, _ firstID: String,
            _ other: TimedTextRun, _ secondID: String
        ) -> Bool {
            switch (holdingLength(run, firstID), holdingLength(other, secondID)) {
            case (.some, .none): return false
            case (.none, .some): return true
            case (.some(let first), .some(let second)) where first != second: return second < first
            default: return coverage(other, secondID) > coverage(run, firstID)
            }
        }

        // Runs arrive in time order per speaker; matching only needs a
        // ±tolerance window, so walk the two lists together.
        let orders = runsBySpeaker.map { entry in
            entry.runs.indices.sorted { entry.runs[$0].start < entry.runs[$1].start }
        }
        var dropped: [Set<Int>] = runsBySpeaker.map { _ in [] }
        for (a, first) in runsBySpeaker.enumerated() {
            for (b, second) in runsBySpeaker.enumerated() where b > a {
                let orderB = orders[b]
                var lower = 0
                for i in orders[a] where !dropped[a].contains(i) {
                    let run = first.runs[i]
                    while lower < orderB.count, second.runs[orderB[lower]].start < run.start - tolerance {
                        lower += 1
                    }
                    var position = lower
                    while position < orderB.count {
                        let j = orderB[position]
                        let other = second.runs[j]
                        if other.start > run.start + tolerance { break }
                        position += 1
                        guard !dropped[b].contains(j), normalized(run.text) == normalized(other.text)
                        else { continue }
                        if secondWins(run, first.speakerID, other, second.speakerID) {
                            dropped[a].insert(i)
                        } else {
                            dropped[b].insert(j)
                        }
                        // Words pair off one to one.
                        break
                    }
                }
            }
        }
        return runsBySpeaker.enumerated().map { index, entry in
            (entry.speakerID, entry.runs.enumerated()
                .filter { !dropped[index].contains($0.offset) }
                .map(\.element))
        }
    }

    // MARK: - Helpers

    /// Sorts spans and merges any that overlap or touch.
    static func merging(_ spans: [ClosedRange<TimeInterval>]) -> [ClosedRange<TimeInterval>] {
        var merged: [ClosedRange<TimeInterval>] = []
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, span.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    /// The whole masked track as one array. Fine for short audio and tests;
    /// the pipeline streams it through `fillMasked` instead.
    public static func maskedSamples(
        _ track: Track,
        from samples: [Float],
        sampleRate: Double
    ) -> [Float] {
        [Float](unsafeUninitializedCapacity: samples.count) { buffer, count in
            fillMasked(buffer, frames: 0..<samples.count, of: track, from: samples, sampleRate: sampleRate)
            count = samples.count
        }
    }

    /// Writes frames `frames` of `track` into `output`: `track`'s spans
    /// copied out of `samples` over silence, each edge that does not touch
    /// the file's own edge faded. Filling consecutive ranges yields exactly
    /// the whole track, whatever the chunk boundaries.
    public static func fillMasked(
        _ output: UnsafeMutableBufferPointer<Float>,
        frames: Range<Int>,
        of track: Track,
        from samples: [Float],
        sampleRate: Double
    ) {
        precondition(output.count >= frames.count && frames.upperBound <= samples.count)
        output.update(repeating: 0)
        guard sampleRate > 0, sampleRate.isFinite else { return }
        let fadeLength = max(0, Int((track.fadeDuration * sampleRate).rounded()))
        let count = Double(samples.count)
        let base = frames.lowerBound

        func index(_ seconds: TimeInterval) -> Int {
            guard seconds.isFinite else { return seconds > 0 ? samples.count : 0 }
            return Int(min(max((seconds * sampleRate).rounded(), 0), count))
        }

        samples.withUnsafeBufferPointer { source in
            for span in track.spans {
                let start = index(span.lowerBound)
                let end = max(start, index(span.upperBound))
                let lower = max(start, frames.lowerBound)
                let upper = min(end, frames.upperBound)
                guard upper > lower else { continue }
                (output.baseAddress! + (lower - base))
                    .update(from: source.baseAddress! + lower, count: upper - lower)

                // Ramps sit inside the span so they never reach beyond the pad;
                // a span that touches the file edge is left square there.
                let ramp = min(fadeLength, (end - start) / 2)
                guard ramp > 0 else { continue }
                // Only the part of each ramp inside `frames` is touched here.
                let headEnd = min(upper, start + ramp)
                if start > 0, lower < headEnd {
                    for position in lower..<headEnd {
                        output[position - base] *= Float(position - start + 1) / Float(ramp + 1)
                    }
                }
                let tailStart = max(lower, end - ramp)
                if end < samples.count, tailStart < upper {
                    for position in tailStart..<upper {
                        output[position - base] *= Float(end - position) / Float(ramp + 1)
                    }
                }
            }
        }
    }

    /// Seconds of `gaps` at least a quarter as loud as the typical found
    /// speech, measured in 100 ms frames by RMS.
    private static func audibleSeconds(
        in gaps: [ClosedRange<TimeInterval>],
        comparedTo covered: [ClosedRange<TimeInterval>],
        samples: [Float],
        sampleRate: Double
    ) -> TimeInterval {
        let frameSeconds = 0.1
        let frameLength = max(1, Int(frameSeconds * sampleRate))
        var coveredLevels: [Float] = []
        var gapLevels: [Float] = []

        var start = 0
        while start + frameLength <= samples.count {
            var energy: Float = 0
            for position in start..<(start + frameLength) { energy += samples[position] * samples[position] }
            let level = (energy / Float(frameLength)).squareRoot()
            let midpoint = (Double(start) + Double(frameLength) / 2) / sampleRate
            if covered.contains(where: { $0.contains(midpoint) }) {
                coveredLevels.append(level)
            } else if gaps.contains(where: { $0.contains(midpoint) }) {
                gapLevels.append(level)
            }
            start += frameLength
        }

        let sortedCovered = coveredLevels.filter { $0 > 0 }.sorted()
        let reference = sortedCovered.isEmpty ? 0.02 : sortedCovered[sortedCovered.count / 2]
        let threshold = max(reference * 0.25, 0.005)
        return Double(gapLevels.filter { $0 >= threshold }.count) * frameSeconds
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
            .map(String.init)
            .joined()
            .split(separator: " ")
            .joined(separator: " ")
    }
}
