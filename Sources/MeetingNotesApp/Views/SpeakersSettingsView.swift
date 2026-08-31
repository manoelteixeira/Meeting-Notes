import MeetingNotesCore
import SwiftUI

/// Settings › Speakers: the voice-recognition toggle and the people known by
/// voice, with rename and forget. Voiceprints are sensitive enough that the
/// user should always be able to see and erase what is stored.
struct SpeakersSettingsView: View {
    @Bindable var model: AppModel
    @State private var confirmingDeleteAll = false

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Recognize speakers across meetings",
                    isOn: $model.voiceRecognitionEnabled
                )
            } header: {
                Text("Voice recognition")
            } footer: {
                Text(
                    "When a new meeting contains a voice heard before, the "
                        + "speaker gets the same name automatically. Voiceprints "
                        + "are derived on this Mac from your recordings and "
                        + "never leave the machine."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                if model.people.isEmpty {
                    Text("No voices yet. Import a meeting with recognition on.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(
                        model.people.sorted { $0.lastHeardAt > $1.lastHeardAt }
                    ) { person in
                        PersonRow(model: model, person: person)
                    }

                    Button("Delete All Voices", role: .destructive) {
                        confirmingDeleteAll = true
                    }
                    .confirmationDialog(
                        "Delete all voices?",
                        isPresented: $confirmingDeleteAll
                    ) {
                        Button("Delete All Voices", role: .destructive) {
                            model.deleteAllPeople()
                        }
                    } message: {
                        Text(
                            "Every stored voiceprint is erased. Meetings keep "
                                + "the speaker names they show."
                        )
                    }
                }
            } header: {
                Text("Known voices")
            } footer: {
                Text(
                    "Renaming here renames the person in every meeting their "
                        + "voice was recognized in. Deleting a voice keeps the "
                        + "names meetings already show."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
        .task { await model.refreshPeople() }
    }
}

/// One known voice: an editable name, where it was last heard, and a forget
/// button — macOS has no swipe-to-delete, so removal needs a visible affordance.
private struct PersonRow: View {
    @Bindable var model: AppModel
    let person: Person
    @State private var draft: String

    init(model: AppModel, person: Person) {
        self.model = model
        self.person = person
        _draft = State(initialValue: person.name ?? "")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                TextField(
                    "Name",
                    text: $draft,
                    prompt: Text("Unnamed speaker")
                )
                .textFieldStyle(.plain)
                .onSubmit { model.renamePerson(person.id, to: draft) }

                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                model.deletePerson(person.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete voice")
        }
    }

    private var caption: String {
        let count = model.meetingsCount(for: person.id)
        let meetings = count == 1 ? "1 meeting" : "\(count) meetings"
        let heard = person.lastHeardAt.formatted(
            .relative(presentation: .named, unitsStyle: .wide)
        )
        return "\(meetings) · last heard \(heard)"
    }
}
