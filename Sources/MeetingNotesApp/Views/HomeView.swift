import SwiftUI

/// The launch screen: the three things the app does, one card each.
struct HomeView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 40) {
            VStack(spacing: 8) {
                Text("Meeting Notes")
                    .font(.largeTitle.bold())
                Text("Transcribe a meeting, see who spoke, and get the notes.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            HStack(spacing: 20) {
                HomeCard(
                    route: .meetings,
                    title: "Meetings",
                    systemImage: "list.bullet",
                    tint: .blue,
                    description: "Browse transcripts and notes from past meetings.",
                    footnote: model.meetings.count == 1 ? "1 meeting" : "\(model.meetings.count) meetings"
                )
                HomeCard(
                    route: .record,
                    title: "Record Meeting",
                    systemImage: "record.circle",
                    tint: .red,
                    description: "Record your microphone and, if you like, the call's audio.",
                    footnote: "⇧⌘R"
                )
                HomeCard(
                    route: .importRecording,
                    title: "Import Recording",
                    systemImage: "square.and.arrow.down",
                    tint: .green,
                    description: "Transcribe an audio file you already have.",
                    footnote: "⌘O"
                )
            }
            // Cards take their natural height (not the window's), and the
            // tallest sets the height for all three.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 900)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
        .navigationTitle("Meeting Notes")
        .toolbar(removing: .title)
    }
}

private struct HomeCard: View {
    let route: Route
    let title: String
    let systemImage: String
    let tint: Color
    let description: String
    let footnote: String

    var body: some View {
        NavigationLink(value: route) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 48, height: 48)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(description)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity, alignment: .topLeading)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}
