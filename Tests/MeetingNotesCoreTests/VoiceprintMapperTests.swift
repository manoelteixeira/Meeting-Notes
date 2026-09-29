import Foundation
import Testing

@testable import MeetingNotesCore

@Suite("Voiceprint mapping")
struct VoiceprintMapperTests {

    private let voiceX: [Float] = [1, 0]
    private let voiceY: [Float] = [0, 1]

    @Test("Each speaker takes the voiceprint of the cluster covering its speech")
    func oneToOne() {
        let primary = [
            DiarizedSegment(speakerID: "S1", start: 0, end: 10),
            DiarizedSegment(speakerID: "S2", start: 10, end: 20),
        ]
        // The reference disagrees slightly about the boundary; that is fine.
        let reference = [
            DiarizedSegment(speakerID: "X", start: 0, end: 10.5),
            DiarizedSegment(speakerID: "Y", start: 10.5, end: 20),
        ]
        let mapped = VoiceprintMapper.map(
            primary: primary, reference: reference, embeddings: ["X": voiceX, "Y": voiceY]
        )
        #expect(mapped == ["S1": voiceX, "S2": voiceY])
    }

    @Test("A cluster that absorbed a brief interjection still belongs to the main voice")
    func absorbedInterjection() {
        // What pyannote does to Example.m4a: one cluster over both voices, but
        // the second voice is 1.5 s of 47.
        let primary = [
            DiarizedSegment(speakerID: "S1", start: 0, end: 8),
            DiarizedSegment(speakerID: "S2", start: 8, end: 9.5),
            DiarizedSegment(speakerID: "S1", start: 9.5, end: 47),
        ]
        let reference = [DiarizedSegment(speakerID: "X", start: 0, end: 47)]
        let mapped = VoiceprintMapper.map(
            primary: primary, reference: reference, embeddings: ["X": voiceX]
        )
        #expect(mapped == ["S1": voiceX])
    }

    @Test("A cluster that is a real mix of two voices is given to neither")
    func blendedClusterDropped() {
        let primary = [
            DiarizedSegment(speakerID: "S1", start: 0, end: 20),
            DiarizedSegment(speakerID: "S2", start: 20, end: 47),
        ]
        let reference = [DiarizedSegment(speakerID: "X", start: 0, end: 47)]
        let mapped = VoiceprintMapper.map(
            primary: primary, reference: reference, embeddings: ["X": voiceX]
        )
        #expect(mapped.isEmpty)
    }

    @Test("A weak overlap is not a match")
    func belowShare() {
        let primary = [DiarizedSegment(speakerID: "S1", start: 0, end: 10)]
        let reference = [DiarizedSegment(speakerID: "X", start: 8, end: 10)]
        let mapped = VoiceprintMapper.map(
            primary: primary, reference: reference, embeddings: ["X": voiceX]
        )
        #expect(mapped.isEmpty)
        #expect(
            VoiceprintMapper.map(
                primary: primary, reference: reference, embeddings: ["X": voiceX], minimumShare: 0.1
            ) == ["S1": voiceX]
        )
    }

    @Test("Missing or empty embeddings and empty inputs yield nothing")
    func missingEmbeddings() {
        let primary = [DiarizedSegment(speakerID: "S1", start: 0, end: 10)]
        let reference = [DiarizedSegment(speakerID: "X", start: 0, end: 10)]
        #expect(VoiceprintMapper.map(primary: primary, reference: reference, embeddings: [:]).isEmpty)
        #expect(VoiceprintMapper.map(primary: primary, reference: reference, embeddings: ["X": []]).isEmpty)
        #expect(VoiceprintMapper.map(primary: [], reference: reference, embeddings: ["X": voiceX]).isEmpty)
        #expect(VoiceprintMapper.map(primary: primary, reference: [], embeddings: ["X": voiceX]).isEmpty)
    }
}
