import SwiftUI

extension View {
    /// Confirms a pending `MergeSuggestion` raised from `origin`'s window.
    ///
    /// The main window and Settings each attach this with their own origin,
    /// so a merge offered in one never pops up in the other.
    func mergeSuggestionDialog(
        model: AppModel,
        origin: MergeSuggestion.Origin
    ) -> some View {
        modifier(MergeSuggestionDialog(model: model, origin: origin))
    }
}

private struct MergeSuggestionDialog: ViewModifier {
    @Bindable var model: AppModel
    let origin: MergeSuggestion.Origin

    private var suggestion: MergeSuggestion? {
        model.mergeSuggestion.flatMap { $0.origin == origin ? $0 : nil }
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(
            title,
            isPresented: Binding(
                get: { suggestion != nil },
                set: { if !$0 { model.mergeSuggestion = nil } }
            ),
            presenting: suggestion
        ) { suggestion in
            Button("Merge") {
                model.mergePeople(suggestion.sourceID, into: suggestion.targetID)
            }
            Button("Keep Separate", role: .cancel) {}
        } message: { suggestion in
            Text(message(for: suggestion))
        }
    }

    private var title: String {
        guard let suggestion else { return "" }
        return suggestion.fromRename
            ? "Another voice is already named \(suggestion.targetName)"
            : "Merge into \(suggestion.targetName)?"
    }

    private func message(for suggestion: MergeSuggestion) -> String {
        var text = "Merging keeps both voiceprints under one person, so "
            + "\(suggestion.targetName) is recognized from either recording "
            + "setup, and relinks every meeting the other voice was heard in."
        if suggestion.heardTogether {
            text += "\n\nThese two voices were heard as different speakers in "
                + "the same meeting, so they may be two different people."
        }
        return text
    }
}
