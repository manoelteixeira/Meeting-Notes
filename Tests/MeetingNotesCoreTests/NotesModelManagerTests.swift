import Foundation
import Testing

@testable import MeetingNotesCore

@Suite("Notes model catalog")
struct NotesModelCatalogTests {

    @Test("The catalog offers three sizes and defaults to the middle one")
    func catalogShape() {
        #expect(NotesModelCatalog.all.count == 3)
        #expect(NotesModelCatalog.default.id == NotesModelCatalog.qwen3_4B.id)
        // Listed smallest to largest, which is the order Settings shows.
        let sizes = NotesModelCatalog.all.map(\.approximateBytes)
        #expect(sizes == sizes.sorted())
    }

    @Test("Every catalog entry has a parseable Hugging Face repo ID")
    func repoIDsParse() {
        for model in NotesModelCatalog.all {
            #expect(NotesModelManager.repoID(model) != nil, "\(model.repoID) did not parse")
        }
    }

    @Test("An unknown or missing id falls back to the default rather than failing")
    func unknownIDFallsBack() {
        #expect(NotesModelCatalog.model(id: nil).id == NotesModelCatalog.default.id)
        #expect(NotesModelCatalog.model(id: "nope").id == NotesModelCatalog.default.id)
        #expect(NotesModelCatalog.model(id: "qwen3-8b-4bit").id == NotesModelCatalog.qwen3_8B.id)
    }

    @Test("Availability labels distinguish the four install states")
    func availabilityLabels() {
        #expect(NotesModelAvailability.notDownloaded.isInstalled == false)
        #expect(NotesModelAvailability.downloading.isInstalled == false)
        #expect(NotesModelAvailability.installed.isInstalled)
        // An update being available does not stop the model working today.
        #expect(NotesModelAvailability.updateAvailable.isInstalled)
    }
}

@Suite("Reasoning-block stripping")
struct ReasoningStrippingTests {

    @Test("Text with no reasoning block is left alone")
    func passesThroughPlainText() {
        let notes = "## Summary\n\nA short meeting."
        #expect(MLXNotesService.strippingReasoning(notes) == notes)
    }

    @Test("Everything up to the closing tag is dropped")
    func stripsReasoning() {
        let raw = "<think>\nLet me plan the sections.\n</think>\n\n## Summary\n\nDone."
        #expect(MLXNotesService.strippingReasoning(raw) == "## Summary\n\nDone.")
    }

    @Test("A model that opens mid-reasoning without the tag still gets stripped")
    func stripsUntaggedOpening() {
        // Qwen3 emits the closing tag even when the opening one is swallowed by
        // the chat template, which is the case this has to survive.
        let raw = "I should list decisions.\n</think>\n## Summary\n\nDone."
        #expect(MLXNotesService.strippingReasoning(raw) == "## Summary\n\nDone.")
    }

    @Test("The last closing tag wins, so notes quoting the tag survive")
    func usesLastClosingTag() {
        let raw = "<think>a</think>\n## Summary\n\nWe discussed </think> handling."
        #expect(MLXNotesService.strippingReasoning(raw) == "handling.")
    }

    @Test("Reasoning cut off before it closed leaves nothing rather than raw thoughts")
    func truncatedReasoningYieldsNothing() {
        #expect(MLXNotesService.strippingReasoning("<think>\nStill thinking") == "")
    }
}
