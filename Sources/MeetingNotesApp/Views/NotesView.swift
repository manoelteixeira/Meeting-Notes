import MeetingNotesCore
import SwiftUI

struct NotesView: View {
    @Bindable var model: AppModel
    let meeting: Meeting

    var body: some View {
        if let markdown = meeting.notesMarkdown, !markdown.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Rendering block by block keeps AttributedString's Markdown
                    // parser from collapsing the document into one paragraph.
                    ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                        block.view
                    }
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .textSelection(.enabled)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer()
                    Button {
                        model.regenerateNotes(meeting.id)
                    } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                    .disabled(!model.hasNotesModel)
                }
                .padding(12)
                .background(.bar)
            }
        } else {
            ContentUnavailableView {
                Label("No notes yet", systemImage: "doc.text")
            } description: {
                Text(
                    model.hasNotesModel
                        ? "Generate notes from the transcript."
                        : "Download a notes model in Settings, then generate notes."
                )
            } actions: {
                if model.hasNotesModel {
                    Button("Generate Notes") { model.regenerateNotes(meeting.id) }
                        .buttonStyle(.borderedProminent)
                } else {
                    SettingsLink { Text("Open Settings") }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

/// A very small Markdown block splitter, enough for the fixed sections the
/// notes prompt asks for: headings, bullets, task list items, and paragraphs.
enum MarkdownBlock {
    case heading(level: Int, text: String)
    case bullet(text: String, checked: Bool?)
    case paragraph(String)

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []

        func flushParagraph() {
            let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph.removeAll()
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
            } else if line.hasPrefix("#") {
                flushParagraph()
                let level = line.prefix { $0 == "#" }.count
                blocks.append(
                    .heading(
                        level: level,
                        text: String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                    )
                )
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                var body = String(line.dropFirst(2))
                var checked: Bool?
                if body.hasPrefix("[ ] ") {
                    checked = false
                    body = String(body.dropFirst(4))
                } else if body.lowercased().hasPrefix("[x] ") {
                    checked = true
                    body = String(body.dropFirst(4))
                }
                blocks.append(.bullet(text: body, checked: checked))
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        return blocks
    }

    @ViewBuilder
    var view: some View {
        switch self {
        case .heading(let level, let text):
            Text(text)
                .font(level <= 1 ? .title2.bold() : .headline)
                .padding(.top, 6)
        case .bullet(let text, let checked):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let checked {
                    Image(systemName: checked ? "checkmark.square" : "square")
                        .foregroundStyle(.secondary)
                } else {
                    Text("•").foregroundStyle(.secondary)
                }
                Text(inline(text)).fixedSize(horizontal: false, vertical: true)
            }
        case .paragraph(let text):
            Text(inline(text)).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Renders inline emphasis; falls back to the raw text if it will not parse.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}
