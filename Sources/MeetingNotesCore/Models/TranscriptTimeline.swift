import Foundation

extension RandomAccessCollection where Element == TranscriptSegment, Index == Int {
    /// Index of the last segment whose `start` is at or before `time`, or `nil`
    /// when `time` precedes the first segment or there are no segments.
    ///
    /// A time in the gap between two segments, or past the end of the last one,
    /// resolves to the most recently started segment — which is what a listener
    /// following along expects to stay highlighted. Assumes the collection is
    /// sorted by `start`, which the merger guarantees.
    public func segmentIndex(at time: TimeInterval) -> Int? {
        var low = startIndex
        var high = endIndex
        while low < high {
            let mid = (low + high) / 2
            if self[mid].start <= time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        // `low` is now the first index whose start is after `time`.
        return low > startIndex ? low - 1 : nil
    }
}
