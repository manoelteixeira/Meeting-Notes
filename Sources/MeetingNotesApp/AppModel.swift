import Foundation
import MeetingNotesCore
import Observation
import SwiftUI

/// Live state of one meeting's in-flight processing. Not persisted: the meeting
/// document records the last completed stage, this records the moving parts.
struct MeetingProgress: Equatable {
    var stages: [ProcessingStage: PipelineProgress] = [:]
    /// Notes text as it streams in, shown before the meeting is saved.
    var streamedNotes: String = ""

    func stage(_ stage: ProcessingStage) -> PipelineProgress? { stages[stage] }

    var isRunning: Bool { !stages.isEmpty }
}

/// A message that needs the user's attention, surfaced as a sheet-free alert.
struct AppAlert: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
}

/// A proposal to fold one known voice into another, awaiting confirmation.
struct MergeSuggestion: Identifiable, Equatable {
    /// Which window asked, so only that one shows the confirmation.
    enum Origin { case main, settings }

    let id = UUID()
    /// The record that goes away; its voiceprints move to `targetID`.
    var sourceID: UUID
    var targetID: UUID
    /// The target's name, or "Unnamed speaker", for the dialog text.
    var targetName: String
    /// True when a rename gave the source the target's name, rather than the
    /// user picking "Merge into…".
    var fromRename: Bool
    /// Both were heard as separate speakers in one meeting — likely two people.
    var heardTogether: Bool
    var origin: Origin
}

/// A proposal to fold one speaker of a meeting into another after a rename
/// gave both the same name, awaiting confirmation.
struct SpeakerMergeSuggestion: Identifiable, Equatable {
    let id = UUID()
    var meetingID: UUID
    /// The speaker that goes away; its utterances move to `targetID`.
    var sourceID: String
    var targetID: String
    var targetName: String
}

/// A screen the window can navigate to from Home.
enum Route: Hashable {
    case meetings
    case record
    case importRecording
    case meeting(Meeting.ID)
}

/// Single source of truth for the UI.
///
/// Everything the views read lives here on the main actor; the store and the
/// pipeline are the only things that touch disk, network, or the ANE.
@MainActor
@Observable
final class AppModel {

    // MARK: - Published state

    private(set) var meetings: [Meeting] = []
    /// The navigation stack above Home; empty means Home is showing.
    var path: [Route] = []
    private(set) var progress: [UUID: MeetingProgress] = [:]
    var alert: AppAlert?
    /// A merge waiting on the user's confirmation, if any.
    var mergeSuggestion: MergeSuggestion?
    /// A same-meeting speaker merge waiting on the user's confirmation, if any.
    var speakerMergeSuggestion: SpeakerMergeSuggestion?

    private(set) var supportedLocales: [Locale] = []
    private(set) var speechModelStatus: SpeechModelAvailability = .supported
    private(set) var diarizationModelsReady = false
    private(set) var isPreparingModels = false

    /// Install state of every model in the catalog, keyed by `NotesModel.id`.
    private(set) var notesModelStatus: [String: NotesModelAvailability] = [:]
    /// Download fraction of the notes model currently being fetched, if any.
    private(set) var notesModelDownload: Double?

    /// Model used to write notes. New runs pick it up immediately.
    var notesModelID: String {
        didSet {
            guard notesModelID != oldValue else { return }
            UserDefaults.standard.set(notesModelID, forKey: Self.notesModelDefaultsKey)
            rebuildNotesService()
            Task { await refreshNotesModelStatus() }
        }
    }

    var notesModel: NotesModel { NotesModelCatalog.model(id: notesModelID) }

    /// The user's notes format — sections plus extra instructions. Edited live
    /// by Settings, so the didSet must stay cheap: persist and swap the
    /// pipeline value, never touch the loaded model.
    var notesTemplate: NotesTemplate {
        didSet {
            guard notesTemplate != oldValue else { return }
            UserDefaults.standard.set(
                notesTemplate.encoded(), forKey: Self.notesTemplateDefaultsKey
            )
            rebuildPipeline()
        }
    }

    /// Whether the selected model is on disk, which is what gates every
    /// notes-generating affordance in the UI.
    var hasNotesModel: Bool {
        notesModelStatus[notesModelID]?.isInstalled ?? false
    }

    /// People known by voice, mirrored from the speaker directory for the UI.
    private(set) var people: [Person] = []

    /// Whether new meetings match voices against the speaker directory. Runs
    /// already in flight keep the pipeline they started with.
    var voiceRecognitionEnabled: Bool {
        didSet {
            guard voiceRecognitionEnabled != oldValue else { return }
            UserDefaults.standard.set(
                voiceRecognitionEnabled, forKey: Self.voiceRecognitionDefaultsKey
            )
            // With Sortformer, recognition adds the pyannote models.
            if diarizationEngine == .sortformer { diarizationModelsReady = false }
            rebuildPipeline()
        }
    }

    /// Which speaker-identification model new meetings run. Runs already in
    /// flight keep the pipeline they started with.
    var diarizationEngine: DiarizationEngine {
        didSet {
            guard diarizationEngine != oldValue else { return }
            UserDefaults.standard.set(
                diarizationEngine.rawValue, forKey: Self.diarizationEngineDefaultsKey
            )
            diarizationModelsReady = false
            rebuildPipeline()
        }
    }

    /// Whether recordings capture other apps' audio — the far side of a call —
    /// alongside the microphone. Takes effect at the next recording.
    var includeSystemAudio: Bool {
        didSet {
            UserDefaults.standard.set(includeSystemAudio, forKey: Self.systemAudioDefaultsKey)
        }
    }

    /// The in-app recorder. Its own observable, so meter ticks re-render only
    /// the views that read it.
    let recording = RecordingController()

    /// BCP-47 locale used for transcription. New meetings inherit it.
    var localeIdentifier: String {
        didSet {
            UserDefaults.standard.set(localeIdentifier, forKey: Self.localeDefaultsKey)
            Task { await refreshModelStatus() }
        }
    }

    // MARK: - Dependencies

    private let store: MeetingStore
    private let directory: SpeakerDirectory
    /// Rebuilt when the selected model changes; in-flight runs keep the
    /// pipeline they started with. Not observation-tracked: the views read
    /// `notesModelStatus`, never these.
    @ObservationIgnored private var notesService: MLXNotesService
    @ObservationIgnored private var pipeline: ProcessingPipeline
    private var tasks: [UUID: Task<Void, Never>] = [:]

    private static let localeDefaultsKey = "transcriptionLocaleIdentifier"
    private static let notesModelDefaultsKey = "notesModelIdentifier"
    private static let notesTemplateDefaultsKey = "notesTemplate"
    private static let voiceRecognitionDefaultsKey = "voiceRecognitionEnabled"
    private static let systemAudioDefaultsKey = "recordSystemAudio"
    private static let diarizationEngineDefaultsKey = "diarizationEngine"

    init(store: MeetingStore, directory: SpeakerDirectory) {
        let notesModelID = UserDefaults.standard.string(forKey: Self.notesModelDefaultsKey)
        let notesModel = NotesModelCatalog.model(id: notesModelID)
        let template = NotesTemplate.load(
            from: UserDefaults.standard.data(forKey: Self.notesTemplateDefaultsKey)
        )
        // Absent key means never touched: recognition defaults to on.
        let recognitionEnabled = UserDefaults.standard
            .object(forKey: Self.voiceRecognitionDefaultsKey) as? Bool ?? true

        let engine = UserDefaults.standard.string(forKey: Self.diarizationEngineDefaultsKey)
            .flatMap(DiarizationEngine.init(rawValue:)) ?? .default

        let service = MLXNotesService(model: notesModel)
        self.store = store
        self.directory = directory
        self.notesService = service
        self.notesTemplate = template
        self.voiceRecognitionEnabled = recognitionEnabled
        self.diarizationEngine = engine
        self.includeSystemAudio = UserDefaults.standard
            .object(forKey: Self.systemAudioDefaultsKey) as? Bool ?? true
        self.pipeline = ProcessingPipeline(
            store: store,
            diarization: engine.makeService(withVoiceprints: recognitionEnabled),
            directory: recognitionEnabled ? directory : nil,
            notes: service,
            notesTemplate: template
        )
        self.localeIdentifier = UserDefaults.standard.string(forKey: Self.localeDefaultsKey)
            ?? Locale.current.identifier(.bcp47)
        self.notesModelID = notesModel.id
    }

    /// Convenience initializer for the app itself; throws only if Application
    /// Support is unwritable, which the app surfaces at launch.
    static func makeDefault() throws -> AppModel {
        AppModel(store: try MeetingStore(), directory: try SpeakerDirectory())
    }

    func meeting(id: Meeting.ID) -> Meeting? {
        meetings.first { $0.id == id }
    }

    /// Opens a meeting with the list behind it, so Back lands on Meetings
    /// rather than wherever the meeting came from.
    func show(_ id: Meeting.ID) {
        path = [.meetings, .meeting(id)]
    }

    var locale: Locale { Locale(identifier: localeIdentifier) }

    // MARK: - Loading

    func load() async {
        do {
            meetings = try await store.loadAll()
            for index in meetings.indices {
                // A meeting left mid-run by a crash is not actually running.
                if meetings[index].status == .running {
                    meetings[index].status = .cancelled
                    try? await store.save(meetings[index])
                }
                // A meeting marked complete but carrying no notes stopped for a
                // missing model. Saying "Ready" would hide that, and would hide
                // the call to action that fixes it.
                if meetings[index].status == .completed, !meetings[index].hasNotes {
                    meetings[index].status = .needsModel
                    try? await store.save(meetings[index])
                }
            }
        } catch {
            alert = AppAlert(
                title: "Could not open your library",
                message: error.localizedDescription
            )
        }
        await refreshModelStatus()
        await refreshNotesModelStatus()
        await refreshPeople()
        await recoverRecordings()
    }

    func refreshModelStatus() async {
        if supportedLocales.isEmpty {
            supportedLocales = await SpeechModelManager.supportedLocales()
        }
        speechModelStatus = await SpeechModelManager.availability(for: locale)
    }

    /// Pre-downloads both model sets from Settings, so the first real run is fast.
    func downloadModels() async {
        guard !isPreparingModels else { return }
        isPreparingModels = true
        defer { isPreparingModels = false }
        do {
            try await SpeechModelManager.ensureModel(for: locale) { _ in }
            try await diarizationEngine
                .makeService(withVoiceprints: voiceRecognitionEnabled)
                .prepare { _ in }
            diarizationModelsReady = true
        } catch {
            alert = AppAlert(
                title: "Model download failed",
                message: error.localizedDescription
            )
        }
        await refreshModelStatus()
    }

    // MARK: - Import

    func importAudio(at urls: [URL]) async {
        var imported: [Meeting] = []
        for url in urls {
            do {
                imported.append(try await adopt(url, title: nil, transfer: .copy))
            } catch {
                alert = AppAlert(
                    title: "Could not import “\(url.lastPathComponent)”",
                    message: error.localizedDescription
                )
            }
        }
        add(imported)
    }

    /// Brings a file into the library as a new meeting in the current locale.
    private func adopt(
        _ url: URL, title: String?, transfer: MeetingStore.Transfer
    ) async throws -> Meeting {
        var meeting = try await store.importAudio(from: url, title: title, transfer: transfer)
        meeting.localeIdentifier = localeIdentifier
        try await store.save(meeting)
        return meeting
    }

    /// Shows freshly imported meetings, opens the first, and processes them.
    private func add(_ imported: [Meeting]) {
        guard !imported.isEmpty else { return }

        meetings.insert(contentsOf: imported, at: 0)
        meetings.sort { $0.createdAt > $1.createdAt }
        if let first = imported.first { show(first.id) }
        for meeting in imported { startProcessing(meeting.id) }
    }

    // MARK: - Recording

    func startRecording() async {
        guard !recording.isRecording else { return }
        do {
            let url = try await store.makeRecordingURL()
            try await recording.start(to: url, includeSystemAudio: includeSystemAudio)
        } catch {
            alert = AppAlert(
                title: "Could not start recording",
                message: error.localizedDescription
            )
        }
    }

    /// Stops the recorder and turns the file into a meeting, which then
    /// processes like any import.
    func stopRecording() async {
        guard let startedAt = recording.startedAt, let url = recording.stop() else { return }
        do {
            let meeting = try await adopt(url, title: Self.recordingTitle(startedAt), transfer: .move)
            add([meeting])
        } catch {
            // A failed move is put back, so the next launch recovers the audio.
            alert = AppAlert(
                title: "Could not save the recording",
                message: error.localizedDescription
                    + " The audio was kept and will be recovered at next launch."
            )
        }
    }

    func discardRecording() {
        recording.discard()
    }

    /// Imports recordings a crash or force quit left behind. Quiet on failure:
    /// a file too short to hold any audio would otherwise alert every launch.
    private func recoverRecordings() async {
        var recovered: [Meeting] = []
        for url in await store.orphanedRecordings() {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            let title = "Recovered " + Self.recordingTitle(created)
            if let meeting = try? await adopt(url, title: title, transfer: .move) {
                recovered.append(meeting)
            }
        }
        add(recovered)
    }

    private static func recordingTitle(_ date: Date) -> String {
        "Recording " + date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Processing

    func startProcessing(_ id: UUID, forceReprocess: Bool = false) {
        guard tasks[id] == nil, let meeting = meetings.first(where: { $0.id == id }) else { return }

        progress[id] = MeetingProgress()
        update(id) { $0.status = .running }

        // Always ask for notes: the pipeline itself detects a missing model and
        // parks the meeting at `.needsModel`, which is what drives the banner
        // and the Settings call to action. Skipping the stage here instead would
        // mark the meeting complete when it is only half done.
        let options = ProcessingPipeline.Options(
            generateNotes: true,
            forceReprocess: forceReprocess,
            streamNotes: true
        )

        let (progressStream, progressContinuation) = AsyncStream<PipelineProgress>.makeStream()
        let (notesStream, notesContinuation) = AsyncStream<String>.makeStream()

        let progressConsumer = Task { @MainActor [weak self] in
            for await event in progressStream {
                self?.progress[id]?.stages[event.stage] = event
            }
        }
        let notesConsumer = Task { @MainActor [weak self] in
            for await delta in notesStream {
                self?.progress[id]?.streamedNotes += delta
            }
        }

        tasks[id] = Task { [pipeline, weak self] in
            defer {
                progressContinuation.finish()
                notesContinuation.finish()
            }
            do {
                let processed = try await pipeline.process(
                    meeting,
                    options: options,
                    onProgress: { progressContinuation.yield($0) },
                    onNotesDelta: { notesContinuation.yield($0) }
                )
                await MainActor.run { self?.finish(id, with: processed) }
            } catch is CancellationError {
                await MainActor.run { self?.finishCancelled(id) }
            } catch {
                await MainActor.run { self?.finishFailed(id, error: error) }
            }
            progressConsumer.cancel()
            notesConsumer.cancel()
        }
    }

    func cancelProcessing(_ id: UUID) {
        tasks[id]?.cancel()
    }

    /// Retries just the notes stage, leaving the transcript untouched.
    func regenerateNotes(_ id: UUID) {
        guard hasNotesModel else {
            alert = AppAlert(
                title: "No notes model installed",
                message: "Download a model in Settings to generate notes."
            )
            return
        }
        startProcessing(id)
    }

    func reprocess(_ id: UUID) {
        startProcessing(id, forceReprocess: true)
    }

    private func finish(_ id: UUID, with meeting: Meeting) {
        tasks[id] = nil
        progress[id] = nil
        replace(meeting)
        // The run may have enrolled voices it had not heard before.
        Task { await refreshPeople() }
    }

    private func finishCancelled(_ id: UUID) {
        tasks[id] = nil
        progress[id] = nil
        Task { await reload(id) }
    }

    private func finishFailed(_ id: UUID, error: Error) {
        tasks[id] = nil
        progress[id] = nil
        Task { await reload(id) }
        // The banner in the detail view carries the detail; an alert here would
        // be redundant for expected failures like a missing model download.
        if let pipelineError = error as? PipelineError, pipelineError.code == .storageFailed {
            alert = AppAlert(title: "Could not save", message: pipelineError.message)
        }
    }

    private func reload(_ id: UUID) async {
        guard let refreshed = try? await store.load(id: id) else { return }
        replace(refreshed)
    }

    // MARK: - Editing

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.title = trimmed }
    }

    func renameSpeaker(_ speakerID: String, in meetingID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let meeting = meetings.first(where: { $0.id == meetingID })
        if let namesake = meeting?.speakers.first(where: {
            $0.id != speakerID && !$0.isUnknown && Self.sameName($0.displayName, trimmed)
        }) {
            // Another voice in this very meeting already has the name: most
            // likely the diarizer split one person in two. Merging the speakers
            // also merges their people, so skip the person-level offer.
            speakerMergeSuggestion = SpeakerMergeSuggestion(
                meetingID: meetingID,
                sourceID: speakerID,
                targetID: namesake.id,
                targetName: namesake.displayName
            )
            update(meetingID) { meeting in
                guard let index = meeting.speakers.firstIndex(where: { $0.id == speakerID }) else { return }
                meeting.speakers[index].displayName = trimmed
            }
            return
        }
        if let personID = meeting?.speaker(id: speakerID)?.personID {
            // A recognized voice: the name belongs to the person, everywhere.
            renamePerson(personID, to: trimmed)
        } else {
            update(meetingID) { meeting in
                guard let index = meeting.speakers.firstIndex(where: { $0.id == speakerID }) else { return }
                meeting.speakers[index].displayName = trimmed
            }
        }
    }

    /// Folds one speaker of a meeting into another. When both voices are
    /// linked to different people, the people are merged too — the user just
    /// said they are one voice — so other meetings they were heard in follow.
    func mergeSpeaker(_ sourceID: String, into targetID: String, in meetingID: UUID) {
        guard let meeting = meetings.first(where: { $0.id == meetingID }),
              let source = meeting.speaker(id: sourceID),
              let target = meeting.speaker(id: targetID)
        else { return }
        update(meetingID) { $0.mergeSpeaker(sourceID, into: targetID) }
        if let sourcePerson = source.personID,
           let targetPerson = target.personID,
           sourcePerson != targetPerson {
            mergePeople(sourcePerson, into: targetPerson)
        }
    }

    /// Attributes one utterance to another speaker. Voiceprints are untouched.
    func reassignSegment(_ segmentID: UUID, to speakerID: String, in meetingID: UUID) {
        update(meetingID) { $0.reassignSegment(segmentID, to: speakerID) }
    }

    /// Corrects one utterance's text, e.g. after hearing the audio disagree.
    /// Timing and speaker attribution are left untouched; an empty edit is a
    /// cancel, not a deletion.
    func updateSegmentText(_ segmentID: UUID, in meetingID: UUID, to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(meetingID) { meeting in
            guard let index = meeting.transcript.firstIndex(where: { $0.id == segmentID }),
                  meeting.transcript[index].text != trimmed
            else { return }
            meeting.transcript[index].text = trimmed
        }
    }

    // MARK: - People

    func refreshPeople() async {
        people = await directory.people()
    }

    /// How many meetings in the library this voice was heard in. Computed from
    /// the loaded meetings so deleting a meeting keeps it honest.
    func meetingsCount(for personID: UUID) -> Int {
        meetings.count { meeting in
            meeting.speakers.contains { $0.personID == personID }
        }
    }

    /// Renames a person everywhere: the directory (so future meetings pick the
    /// name up) and every meeting their voice was recognized in.
    ///
    /// If another known voice already goes by that name, the user is offered
    /// a merge: renaming a duplicate after its real owner is how a voice
    /// heard through a new mic or room usually gets fixed.
    func renamePerson(
        _ personID: UUID,
        to name: String,
        from origin: MergeSuggestion.Origin = .main
    ) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let namesake = people.first(where: {
            $0.id != personID && Self.sameName($0.name, trimmed)
        }) {
            mergeSuggestion = suggestion(
                merging: personID, into: namesake, fromRename: true, origin: origin
            )
        }
        Task {
            try? await directory.rename(id: personID, to: trimmed)
            await refreshPeople()
        }
        for index in meetings.indices {
            var changed = false
            for speakerIndex in meetings[index].speakers.indices
            where meetings[index].speakers[speakerIndex].personID == personID {
                meetings[index].speakers[speakerIndex].displayName = trimmed
                changed = true
            }
            if changed {
                let snapshot = meetings[index]
                Task { try? await store.save(snapshot) }
            }
        }
    }

    /// Offers to fold `sourceID` into `targetID`; the dialog calls `mergePeople`.
    func proposeMerge(
        _ sourceID: UUID,
        into targetID: UUID,
        from origin: MergeSuggestion.Origin
    ) {
        guard let target = people.first(where: { $0.id == targetID }) else { return }
        mergeSuggestion = suggestion(
            merging: sourceID, into: target, fromRename: false, origin: origin
        )
    }

    /// Folds one voice into another: the directory keeps both voiceprints
    /// under the target, and every meeting speaker linked to the source is
    /// relinked to the target and takes its name.
    func mergePeople(_ sourceID: UUID, into targetID: UUID) {
        Task {
            let merged: Person?
            do {
                merged = try await directory.merge(sourceID: sourceID, into: targetID)
            } catch {
                alert = AppAlert(title: "Merge failed", message: error.localizedDescription)
                return
            }
            await refreshPeople()
            guard let merged else { return }
            for index in meetings.indices {
                var changed = false
                for speakerIndex in meetings[index].speakers.indices
                where meetings[index].speakers[speakerIndex].personID == sourceID {
                    meetings[index].speakers[speakerIndex].personID = merged.id
                    if let name = merged.name {
                        meetings[index].speakers[speakerIndex].displayName = name
                    }
                    changed = true
                }
                if changed {
                    // Speakers the diarizer split now share a person: show them as one.
                    meetings[index].collapseSpeakersSharingPerson()
                    let snapshot = meetings[index]
                    Task { try? await store.save(snapshot) }
                }
            }
        }
    }

    /// Whether some meeting has speakers linked to both people. The diarizer
    /// told those voices apart side by side, so they are probably not one person.
    func heardTogether(_ first: UUID, _ second: UUID) -> Bool {
        meetings.contains { meeting in
            let linked = Set(meeting.speakers.compactMap(\.personID))
            return linked.contains(first) && linked.contains(second)
        }
    }

    private func suggestion(
        merging sourceID: UUID,
        into target: Person,
        fromRename: Bool,
        origin: MergeSuggestion.Origin
    ) -> MergeSuggestion {
        MergeSuggestion(
            sourceID: sourceID,
            targetID: target.id,
            targetName: target.name ?? "Unnamed speaker",
            fromRename: fromRename,
            heardTogether: heardTogether(sourceID, target.id),
            origin: origin
        )
    }

    private static func sameName(_ name: String?, _ other: String) -> Bool {
        guard let name else { return false }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
            .compare(other, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    /// Forgets a voice. Meetings keep the name text they show, but the links
    /// are severed — a later rename in one meeting no longer touches others.
    func deletePerson(_ personID: UUID) {
        Task {
            try? await directory.delete(id: personID)
            await refreshPeople()
        }
        clearLinks { $0 == personID }
    }

    func deleteAllPeople() {
        Task {
            try? await directory.deleteAll()
            await refreshPeople()
        }
        clearLinks { _ in true }
    }

    private func clearLinks(_ matching: (UUID) -> Bool) {
        for index in meetings.indices {
            var changed = false
            for speakerIndex in meetings[index].speakers.indices {
                if let personID = meetings[index].speakers[speakerIndex].personID,
                   matching(personID) {
                    meetings[index].speakers[speakerIndex].personID = nil
                    changed = true
                }
            }
            if changed {
                let snapshot = meetings[index]
                Task { try? await store.save(snapshot) }
            }
        }
    }

    func delete(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        progress[id] = nil
        meetings.removeAll { $0.id == id }
        path.removeAll { $0 == .meeting(id) }
        Task { try? await store.delete(id: id) }
    }

    // MARK: - Export

    func audioURL(for meeting: Meeting) -> URL {
        store.audioURL(for: meeting)
    }

    func markdown(for meeting: Meeting) -> String {
        MarkdownExporter.export(meeting)
    }

    // MARK: - Notes model

    /// Local-only refresh: no network, so it is cheap enough to call whenever
    /// Settings appears or the selection changes.
    func refreshNotesModelStatus() async {
        var status: [String: NotesModelAvailability] = [:]
        for model in NotesModelCatalog.all {
            status[model.id] = NotesModelManager.availability(for: model)
        }
        notesModelStatus = status
    }

    /// Asks the Hub whether any installed model has a newer revision. Silent on
    /// failure — being offline is not worth an alert.
    func checkForNotesModelUpdates() async {
        for model in NotesModelCatalog.all where notesModelStatus[model.id]?.isInstalled == true {
            notesModelStatus[model.id] = await NotesModelManager.availabilityCheckingRemote(
                for: model
            )
        }
    }

    /// Downloads a model, or re-pulls one whose repository has moved.
    func downloadNotesModel(_ model: NotesModel) async {
        guard notesModelDownload == nil else { return }
        notesModelDownload = 0
        notesModelStatus[model.id] = .downloading
        defer { notesModelDownload = nil }

        // Downloading a model other than the selected one still has to run
        // through a service bound to it.
        let service = model.id == notesModelID ? notesService : MLXNotesService(model: model)
        do {
            try await service.prepare { fraction in
                Task { @MainActor [weak self] in self?.notesModelDownload = fraction }
            }
        } catch is CancellationError {
            // Leave the status to the refresh below.
        } catch {
            alert = AppAlert(
                title: "Could not download “\(model.displayName)”",
                message: error.localizedDescription
            )
        }
        await refreshNotesModelStatus()
    }

    /// Deletes the weights from the Hugging Face cache.
    func removeNotesModel(_ model: NotesModel) async {
        if model.id == notesModelID {
            await notesService.unload()
        }
        do {
            try NotesModelManager.remove(model)
        } catch {
            alert = AppAlert(
                title: "Could not remove “\(model.displayName)”",
                message: error.localizedDescription
            )
        }
        await refreshNotesModelStatus()
    }

    /// Bytes this model currently occupies, for the Settings row.
    func installedSize(of model: NotesModel) -> Int64 {
        NotesModelManager.installedSize(model)
    }

    private func rebuildNotesService() {
        let previous = notesService
        // Free the old model's resident memory; its download stays on disk.
        Task { await previous.unload() }
        notesService = MLXNotesService(model: notesModel)
        rebuildPipeline()
    }

    /// Cheap enough for a per-keystroke template edit: the loaded model is
    /// untouched, only the pipeline value is replaced.
    private func rebuildPipeline() {
        pipeline = ProcessingPipeline(
            store: store,
            diarization: diarizationEngine.makeService(withVoiceprints: voiceRecognitionEnabled),
            directory: voiceRecognitionEnabled ? directory : nil,
            notes: notesService,
            notesTemplate: notesTemplate
        )
    }

    func resetNotesTemplate() {
        notesTemplate = .default
    }

    // MARK: - Mutation helpers

    private func update(_ id: UUID, _ mutate: (inout Meeting) -> Void) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        mutate(&meetings[index])
        let snapshot = meetings[index]
        Task { try? await store.save(snapshot) }
    }

    private func replace(_ meeting: Meeting) {
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.insert(meeting, at: 0)
        }
    }
}
