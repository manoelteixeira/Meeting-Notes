import MeetingNotesCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var isImporting = false

    var body: some View {
        NavigationSplitView {
            MeetingSidebar(model: model, isImporting: $isImporting)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            Group {
                if let meeting = model.selectedMeeting {
                    MeetingDetailView(model: model, meeting: meeting)
                } else {
                    EmptyLibraryView(isImporting: $isImporting)
                }
            }
            // Dropping onto the detail pane imports, whether or not a meeting is
            // already selected — the empty state is where people reach for it.
            .dropDestination(for: URL.self) { urls, _ in
                Task { await model.importAudio(at: urls) }
                return true
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: AudioFileTypes.all,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await model.importAudio(at: urls) }
            case .failure(let error):
                model.alert = AppAlert(title: "Import failed", message: error.localizedDescription)
            }
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
    }
}

/// Shown when nothing is selected — including the very first launch.
struct EmptyLibraryView: View {
    @Binding var isImporting: Bool

    var body: some View {
        ContentUnavailableView {
            Label("No meeting selected", systemImage: "waveform")
        } description: {
            Text("Import a recording to transcribe it, identify who spoke, and write up the notes.")
        } actions: {
            Button("Import Recording…") { isImporting = true }
                .buttonStyle(.borderedProminent)
        }
    }
}
