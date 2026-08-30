import Foundation

/// Renders a meeting as a self-contained Markdown document.
public enum MarkdownExporter {

    public struct Options: Sendable, Equatable {
        public var includeNotes: Bool
        public var includeTranscript: Bool

        public init(includeNotes: Bool = true, includeTranscript: Bool = true) {
            self.includeNotes = includeNotes
            self.includeTranscript = includeTranscript
        }

        public static let `default` = Options()
    }

    public static func export(_ meeting: Meeting, options: Options = .default) -> String {
        var lines: [String] = []

        lines.append("# \(meeting.title)")
        lines.append("")
        lines.append("- **Date:** \(dateFormatter.string(from: meeting.createdAt))")
        lines.append("- **Duration:** \(timestamp(meeting.duration))")
        if !meeting.speakers.isEmpty {
            let names = meeting.speakers.map(\.displayName).joined(separator: ", ")
            lines.append("- **Speakers:** \(names)")
        }
        lines.append("")

        if options.includeNotes, let notes = meeting.notesMarkdown, !notes.isEmpty {
            lines.append(notes.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
        }

        if options.includeTranscript, !meeting.transcript.isEmpty {
            lines.append("---")
            lines.append("")
            lines.append("## Transcript")
            lines.append("")
            for segment in meeting.transcript {
                let name = meeting.displayName(forSpeaker: segment.speakerID)
                lines.append("**[\(timestamp(segment.start))] \(name):** \(segment.text)")
                lines.append("")
            }
        }

        // Collapse the trailing blank lines into exactly one terminating newline.
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The transcript rendering handed to the notes model: compact, one line per
    /// utterance, `[mm:ss] Speaker N: text`.
    public static func transcriptForPrompt(_ meeting: Meeting) -> String {
        meeting.transcript
            .map { "[\(timestamp($0.start))] \(meeting.displayName(forSpeaker: $0.speakerID)): \($0.text)" }
            .joined(separator: "\n")
    }

    /// A file name safe on macOS, derived from the meeting title.
    public static func suggestedFileName(for meeting: Meeting) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = meeting.title
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "Meeting Notes" : cleaned
        return "\(base).md"
    }

    /// `mm:ss`, widening to `h:mm:ss` past an hour.
    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down).isFinite ? max(0, seconds.rounded(.down)) : 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter
    }()
}
