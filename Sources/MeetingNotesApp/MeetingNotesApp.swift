import MeetingNotesCore
import SwiftUI

@main
struct MeetingNotesApp: App {

    @State private var model: AppModel?
    @State private var launchError: String?

    var body: some Scene {
        WindowGroup("Meeting Notes") {
            Group {
                if let model {
                    ContentView(model: model)
                } else if let launchError {
                    LaunchFailureView(message: launchError)
                } else {
                    ProgressView().task { await start() }
                }
            }
            .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            if let model {
                SettingsView(model: model)
            }
        }
    }

    @MainActor
    private func start() async {
        do {
            let model = try AppModel.makeDefault()
            await model.load()
            self.model = model
        } catch {
            launchError = error.localizedDescription
        }
    }
}

/// Shown only when the meetings folder cannot be created, which means the app
/// cannot function at all.
struct LaunchFailureView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Meeting Notes can't start", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        }
    }
}
