import AppKit
import MeetingNotesCore
import SwiftUI

@main
struct MeetingNotesApp: App {

    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
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
            CommandGroup(replacing: .newItem) {
                RecordingCommands(model: model)
            }
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
            appDelegate.model = model
        } catch {
            launchError = error.localizedDescription
        }
    }
}

/// File › New Recording / Stop Recording, and Import Recording….
private struct RecordingCommands: View {
    let model: AppModel?

    var body: some View {
        if let model, model.recording.isRecording {
            Button("Stop Recording") { Task { await model.stopRecording() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        } else {
            Button("New Recording") {
                // Show the Record screen so its timer and meters are in view.
                model?.path = [.record]
                Task { await model?.startRecording() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model == nil)
        }
        Button("Import Recording…") { model?.path = [.importRecording] }
            .keyboardShortcut("o")
            .disabled(model == nil)
    }
}

/// Keeps quitting from losing a recording in progress: the file is finalized
/// and saved as a meeting before the app goes.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.recording.isRecording else { return .terminateNow }
        Task {
            await model.stopRecording()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
