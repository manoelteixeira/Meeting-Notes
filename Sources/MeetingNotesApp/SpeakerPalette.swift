import MeetingNotesCore
import SwiftUI

/// Colours used for speaker chips. Index 0 is reserved for the unknown speaker.
enum SpeakerPalette {
    private static let colors: [Color] = [
        .secondary, .blue, .orange, .purple, .green, .pink, .teal, .indigo, .brown,
    ]

    static func color(for speaker: Speaker?) -> Color {
        guard let speaker, !speaker.isUnknown else { return colors[0] }
        // Wrap around rather than clamp, so a meeting with many speakers still
        // gets distinguishable chips.
        return colors[1 + (max(0, speaker.colorIndex - 1) % (colors.count - 1))]
    }
}

extension Meeting {
    /// A speaker's name for menus, with when they first speak added if another
    /// speaker shares the name — a split voice shows up as twin names.
    func menuLabel(for speaker: Speaker) -> String {
        let twins = speakers.contains { $0.id != speaker.id && $0.displayName == speaker.displayName }
        guard twins, let first = transcript.first(where: { $0.speakerID == speaker.id }) else {
            return speaker.displayName
        }
        return "\(speaker.displayName) (from \(MarkdownExporter.timestamp(first.start)))"
    }
}
