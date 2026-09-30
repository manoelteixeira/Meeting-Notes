import MeetingNotesCore
import SwiftUI

extension CGFloat {
    /// Width of the centred column that meeting content reads in.
    static let readableWidth: CGFloat = 860
}

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack(path: $model.path) {
            HomeView(model: model)
                .navigationDestination(for: Route.self, destination: destination)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // The Record screen shows the recording itself; everywhere else a
            // bar keeps it visible and stoppable.
            if model.recording.isRecording, model.path.last != .record {
                RecordingBar(recording: model.recording) {
                    Task { await model.stopRecording() }
                } onDiscard: {
                    model.discardRecording()
                }
            }
        }
        // Dropping audio anywhere in the window imports it, not just on the
        // Import screen's drop zone.
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.importAudio(at: urls) }
            return true
        }
        .alert(
            model.alert?.title ?? "",
            isPresented: Binding(
                get: { model.alert != nil },
                set: { if !$0 { model.alert = nil } }
            ),
            presenting: model.alert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
        .mergeSuggestionDialog(model: model, origin: .main)
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .meetings:
            MeetingsView(model: model)
        case .record:
            RecordView(model: model)
        case .importRecording:
            ImportView(model: model)
        case .meeting(let id):
            if let meeting = model.meeting(id: id) {
                MeetingDetailView(model: model, meeting: meeting)
            } else {
                ContentUnavailableView("Meeting not found", systemImage: "questionmark.folder")
            }
        }
    }
}
