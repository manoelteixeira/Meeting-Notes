import Foundation

/// The user-editable shape of the generated notes: which sections to write,
/// what belongs in each, and any free-form guidance for the model.
///
/// The template holds only the pieces a user may safely change. The rigid
/// scaffolding around them — the exact-headings mandate and the
/// anti-hallucination rules — is composed by `NotesPrompt` and stays fixed,
/// which is what keeps small local models on-format.
public struct NotesTemplate: Sendable, Equatable, Codable {

    /// One `##` section of the notes, with the rule the model follows when
    /// writing it. The guidance belongs to the section, not to its title, so
    /// renaming "Summary" keeps its two-to-four-sentence rule.
    public struct Section: Sendable, Equatable, Codable, Identifiable {
        /// UI identity only — not persisted and not part of equality, so a
        /// decoded template still compares equal to the one that was saved.
        public var id: UUID
        public var title: String
        /// Body of the section's rule bullet; empty means no rule.
        public var guidance: String

        public init(id: UUID = UUID(), title: String, guidance: String = "") {
            self.id = id
            self.title = title
            self.guidance = guidance
        }

        private enum CodingKeys: String, CodingKey {
            case title
            case guidance
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = UUID()
            self.title = try container.decode(String.self, forKey: .title)
            self.guidance = try container.decode(String.self, forKey: .guidance)
        }

        public static func == (lhs: Section, rhs: Section) -> Bool {
            lhs.title == rhs.title && lhs.guidance == rhs.guidance
        }
    }

    public var sections: [Section]
    /// Free-form extra guidance — tone, language, level of detail — appended
    /// to the prompt after the rules. Empty appends nothing.
    public var additionalInstructions: String

    public init(sections: [Section], additionalInstructions: String = "") {
        self.sections = sections
        self.additionalInstructions = additionalInstructions
    }

    /// The four sections the app has always written, with their original
    /// rule text verbatim.
    public static let `default` = NotesTemplate(sections: [
        Section(
            title: "Summary",
            guidance: "two to four sentences on what the meeting was about and where "
                + "it landed."
        ),
        Section(
            title: "Key Discussion Points",
            guidance: "bullets. Group related discussion together rather than "
                + "replaying the transcript chronologically."
        ),
        Section(
            title: "Decisions",
            guidance: "bullets, each stating what was decided. Write \"No explicit "
                + "decisions were recorded.\" if there were none."
        ),
        Section(
            title: "Action Items",
            guidance: "GitHub-style task list items, `- [ ] `. Where the owner "
                + "can be inferred, prefix the task with the speaker's name and an em dash, "
                + "e.g. `- [ ] Priya — send the revised budget by Friday`. Write "
                + "\"- [ ] No action items were recorded.\" if there were none."
        ),
    ])

    /// A template that is always safe to build a prompt from: titles and
    /// guidance trimmed, untitled sections dropped, and an empty section list
    /// replaced with the defaults (the instructions survive). The UI binds to
    /// the raw value so this never fights the user mid-keystroke.
    public func sanitized() -> NotesTemplate {
        let cleaned = sections.compactMap { section -> Section? in
            let title = section.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return Section(
                id: section.id,
                title: title,
                guidance: section.guidance.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return NotesTemplate(
            sections: cleaned.isEmpty ? Self.default.sections : cleaned,
            additionalInstructions: additionalInstructions
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Decodes a stored template, falling back to the default when the data
    /// is missing or unreadable.
    public static func load(from data: Data?) -> NotesTemplate {
        guard
            let data,
            let template = try? JSONDecoder().decode(NotesTemplate.self, from: data)
        else { return .default }
        return template
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}
