import MeetingNotesCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            NotesSettings(model: model)
                .tabItem { Label("Notes", systemImage: "sparkles") }
            TranscriptionSettings(model: model)
                .tabItem { Label("Transcription", systemImage: "waveform") }
        }
        .frame(width: 520, height: 320)
    }
}

private struct NotesSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Model", selection: $model.notesModelID) {
                    ForEach(NotesModelCatalog.all) { entry in
                        Text(entry.displayName).tag(entry.id)
                    }
                }

                ForEach(NotesModelCatalog.all) { entry in
                    ModelRow(model: model, entry: entry)
                }
            } header: {
                Text("On-device notes")
            } footer: {
                Text(
                    "Notes are written on this Mac by the model you choose. Nothing "
                        + "leaves the machine. Models are downloaded once, then work "
                        + "offline; larger ones write better notes but need more memory."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
        .task {
            await model.refreshNotesModelStatus()
            await model.checkForNotesModelUpdates()
        }
    }
}

/// One catalog entry: size, install state, and whatever action it currently
/// affords.
private struct ModelRow: View {
    @Bindable var model: AppModel
    let entry: NotesModel

    private var status: NotesModelAvailability {
        model.notesModelStatus[entry.id] ?? .notDownloaded
    }

    /// Once installed, the real on-disk size beats the catalog's estimate.
    private var size: String {
        guard status.isInstalled else { return entry.formattedSize }
        let actual = model.installedSize(of: entry)
        guard actual > 0 else { return entry.formattedSize }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: actual)
    }

    var body: some View {
        LabeledContent(entry.displayName) {
            HStack(spacing: 8) {
                Text(size)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()

                Text(status.label)
                    .foregroundStyle(status == .installed ? .green : .secondary)

                if status == .downloading, let fraction = model.notesModelDownload {
                    ProgressView(value: fraction, total: 1)
                        .progressViewStyle(.linear)
                        .frame(width: 70)
                } else {
                    actions
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch status {
        case .notDownloaded:
            Button("Download") { Task { await model.downloadNotesModel(entry) } }
                .disabled(model.notesModelDownload != nil)
        case .updateAvailable:
            Button("Update") { Task { await model.downloadNotesModel(entry) } }
                .disabled(model.notesModelDownload != nil)
            removeButton
        case .installed:
            removeButton
        case .downloading:
            EmptyView()
        }
    }

    private var removeButton: some View {
        Button("Remove", role: .destructive) {
            Task { await model.removeNotesModel(entry) }
        }
        .disabled(model.notesModelDownload != nil)
    }
}

private struct TranscriptionSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $model.localeIdentifier) {
                    ForEach(localeChoices, id: \.identifier) { locale in
                        Text(SpeechModelManager.displayName(locale))
                            .tag(locale.identifier(.bcp47))
                    }
                }

                LabeledContent("Speech model") {
                    HStack(spacing: 8) {
                        Text(model.speechModelStatus.label)
                            .foregroundStyle(
                                model.speechModelStatus == .installed ? .green : .secondary
                            )
                        if model.speechModelStatus != .installed,
                           model.speechModelStatus != .unsupported {
                            Button("Download") { Task { await model.downloadModels() } }
                                .disabled(model.isPreparingModels)
                        }
                        if model.isPreparingModels { ProgressView().controlSize(.small) }
                    }
                }

                LabeledContent("Speaker models") {
                    Text(model.diarizationModelsReady ? "Ready" : "Downloaded on first use")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("On-device transcription")
            } footer: {
                Text(
                    "Transcription and speaker identification run entirely on this Mac. "
                        + "Models are downloaded once, then work offline."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
        .task { await model.refreshModelStatus() }
    }
}

/// Supported locales, plus the current selection so the picker always has a
/// matching tag even if the list has not loaded yet.
private extension TranscriptionSettings {
    var localeChoices: [Locale] {
        var locales = model.supportedLocales
        if !locales.contains(where: { $0.identifier(.bcp47) == model.localeIdentifier }) {
            locales.insert(Locale(identifier: model.localeIdentifier), at: 0)
        }
        return locales.sorted {
            SpeechModelManager.displayName($0) < SpeechModelManager.displayName($1)
        }
    }
}
