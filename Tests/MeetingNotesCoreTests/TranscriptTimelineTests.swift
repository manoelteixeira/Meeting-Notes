import Foundation
import Testing

@testable import MeetingNotesCore

@Suite("Transcript timeline")
struct TranscriptTimelineTests {

    /// 0–2, 2–5, then a gap, 8–10.
    private let segments = [
        TranscriptSegment(start: 0, end: 2, text: "One", speakerID: "A"),
        TranscriptSegment(start: 2, end: 5, text: "Two", speakerID: "B"),
        TranscriptSegment(start: 8, end: 10, text: "Three", speakerID: "A"),
    ]

    @Test("A time inside a segment finds that segment")
    func insideSegments() {
        #expect(segments.segmentIndex(at: 1) == 0)
        #expect(segments.segmentIndex(at: 3.5) == 1)
        #expect(segments.segmentIndex(at: 9) == 2)
    }

    @Test("A segment owns its exact start time")
    func startBoundaries() {
        #expect(segments.segmentIndex(at: 0) == 0)
        #expect(segments.segmentIndex(at: 2) == 1)
        #expect(segments.segmentIndex(at: 8) == 2)
    }

    @Test("A time in a gap keeps the segment that started last")
    func gapBetweenSegments() {
        #expect(segments.segmentIndex(at: 6) == 1)
    }

    @Test("A time past the last segment's end keeps the last segment")
    func pastTheEnd() {
        #expect(segments.segmentIndex(at: 10) == 2)
        #expect(segments.segmentIndex(at: 100) == 2)
    }

    @Test("A time before the first segment finds nothing")
    func beforeFirstSegment() {
        let late = [TranscriptSegment(start: 3, end: 5, text: "Hi", speakerID: "A")]
        #expect(late.segmentIndex(at: 0) == nil)
        #expect(late.segmentIndex(at: 2.9) == nil)
    }

    @Test("An empty transcript finds nothing")
    func emptyTranscript() {
        #expect([TranscriptSegment]().segmentIndex(at: 0) == nil)
    }

    @Test("A single segment covers everything from its start onward")
    func singleSegment() {
        let single = [TranscriptSegment(start: 1, end: 4, text: "Solo", speakerID: "A")]
        #expect(single.segmentIndex(at: 0.5) == nil)
        #expect(single.segmentIndex(at: 1) == 0)
        #expect(single.segmentIndex(at: 4) == 0)
        #expect(single.segmentIndex(at: 9) == 0)
    }

    @Test("A zero-duration segment does not break the search")
    func zeroDurationSegment() {
        let odd = [
            TranscriptSegment(start: 0, end: 2, text: "One", speakerID: "A"),
            TranscriptSegment(start: 2, end: 2, text: "Blip", speakerID: "B"),
            TranscriptSegment(start: 4, end: 6, text: "Two", speakerID: "A"),
        ]
        #expect(odd.segmentIndex(at: 2) == 1)
        #expect(odd.segmentIndex(at: 3) == 1)
        #expect(odd.segmentIndex(at: 4) == 2)
    }
}
