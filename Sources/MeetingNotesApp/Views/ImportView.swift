import SwiftUI

/// A drop zone and file picker for recordings made elsewhere.
struct ImportView: View {
    let model: AppModel
    @State private var isImporting = false
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 28))
                .foregroundStyle(.green)
                .frame(width: 64, height: 64)
                .background(.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
            Text("Drop audio files here")
                .font(.title2.weight(.semibold))
            Text("M4A, MP3, WAV, AIFF, FLAC or MP4 — you can add several at once.")
                .foregroundStyle(.secondary)
            Button("Choose Files…") { isImporting = true }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            Text("Each file becomes a meeting and starts transcribing right away.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(maxWidth: 640, minHeight: 380)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
        )
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.importAudio(at: urls) }
            return true
        } isTargeted: {
            isTargeted = $0
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Import Recording")
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
    }
}
