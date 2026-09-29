# Meeting Notes

A native macOS app that turns a meeting recording into structured notes.

Record a meeting or drop in an audio file and it transcribes the speech, works out who said what,
and writes up a summary with decisions and action items.

**Where your data goes.** Nowhere. Transcription, speaker identification and
the notes all run on your Mac. The only thing that ever touches the network is
the one-time download of the models themselves; after that the app works
offline, and neither the audio nor the transcript leaves the machine.

## Features

- **Record a meeting in the app** — the microphone plus, optionally, what
  other apps are playing, so both sides of a Zoom, Meet or Teams call land in
  one recording. Stop, and it processes like any import. The toolbar's record
  button or File › New Recording (⇧⌘R) starts it; live meters show both
  sources. Quitting mid-recording saves it first, and a recording cut short by
  a crash is recovered at next launch. Settings › Recording turns system audio
  off for in-room meetings.
- **Import a recording** by dragging it into the window or with the file
  picker. Anything AVFoundation can decode works — m4a, mp3, wav, and the rest.
- **On-device transcription** with Apple's `SpeechAnalyzer`, with word-level
  timestamps. The transcription language is selectable in Settings.
- **Speaker identification first, then transcription per speaker.** FluidAudio's
  Sortformer model works out who spoke when; each speaker's own audio is then
  transcribed on its own, so every word arrives already attributed and a
  one-word reply is never swallowed by the person talking around it. Speakers
  arrive numbered by first appearance and can be renamed inline in the
  transcript — the name applies everywhere at once. Settings › Transcription
  can switch to the pyannote pipeline instead.
- **Voices recognized across meetings.** Name a speaker once and the next
  recording of the same voice gets that name automatically; renaming them
  anywhere renames them in every meeting. Voiceprints are derived on-device and
  managed — or switched off entirely — in Settings › Speakers.
- **Meeting notes written locally** by a quantized Qwen3 running on the GPU via
  MLX: a summary plus decisions and action items, in a consistent sectioned
  format. Regenerate on demand, e.g. after renaming speakers or switching to a
  bigger model.
- **Customizable notes.** Settings › Notes edits the section list —
  add, remove, rename or reorder sections, each with optional guidance on what
  it should contain — plus free-form instructions such as a language or level
  of detail. The setting applies to every meeting; regenerate to apply it to
  notes written earlier.
- **A meeting library** in the sidebar, with per-meeting status at a glance and
  rename, reprocess and delete a right-click away. Each meeting keeps its own
  copy of the audio, so the original file can move or vanish.
- **Resumable processing.** Progress is shown per stage and can be cancelled;
  finished stages are saved as they complete, so a retry picks up where things
  stopped rather than starting over.
- **Markdown export** of the notes and transcript to a file, ready to paste
  into a wiki or ticket.
- **A command-line companion**, `meeting-notes-cli`, that drives the same
  pipeline headlessly and prints Markdown to stdout.

## Requirements

**To run it:**

- macOS 26 (Tahoe) or later — the app uses Apple's on-device `SpeechAnalyzer`
- Apple silicon — MLX runs the notes model on the GPU
- 1–4.5 GB of disk for a notes model, and roughly as much again in RAM while it
  runs. 16 GB is comfortable; on 8 GB choose the smallest model

**To build it:**

- Full Xcode 26, plus the Metal toolchain, which is a separate download:
  `xcodebuild -downloadComponent MetalToolchain`
- The Command Line Tools alone are enough for `swift build` and `swift test`,
  which never execute a Metal kernel — only the app and `--notes` need Xcode

## Building and running

```bash
./Scripts/make_app.sh          # assembles build/MeetingNotes.app
./Scripts/run_app.sh           # builds and launches it
./Scripts/test.sh              # runs the test suite
```

There is still no `.xcodeproj` — this is a plain SwiftPM package — but
`make_app.sh` drives `xcodebuild` rather than `swift build`. MLX's compute
kernels are Metal shaders, and SwiftPM on the command line cannot compile them:
a `swift build` binary links and launches fine, then dies at the first
generation with *"Failed to load the default metallib"*. Only `xcodebuild` runs
the Metal compiler.

`swift build` and `swift test` still work headlessly for the library and the
suite, which never execute a kernel — that is the fast loop for everything
except actually generating notes. `make_app.sh` also wraps the executable in a
real `.app` bundle, which the Settings scene, the save panel, and Speech's
per-application model assets all expect, and copies `mlx-swift_Cmlx.bundle`
into `Contents/Resources`, where MLX finds the shaders at runtime.

## Notes models

Notes are written by a 4-bit quantized Qwen3 running on this Mac. Settings ›
Notes offers three sizes:

| Model | Hugging Face repo | Download |
| --- | --- | --- |
| Qwen3 1.7B | `mlx-community/Qwen3-1.7B-4bit` | ~1 GB |
| Qwen3 4B *(default)* | `mlx-community/Qwen3-4B-4bit` | ~2.3 GB |
| Qwen3 8B | `mlx-community/Qwen3-8B-4bit` | ~4.5 GB |

Bigger should write better notes and hold the sectioned format more
reliably; smaller loads faster and leaves more memory for the rest of the
pipeline. Which one is worth the disk is a judgement best made on your own
recordings.

No weights ship with the app. Until you install a model, processing stops after
the transcript and the meeting parks at "Needs a model" rather than failing —
the transcript is complete and useful on its own, and importing a recording
never kicks off a multi-gigabyte download on its own initiative.

Settings › Notes installs, updates and removes them. *Update* compares the
downloaded commit against the repository's `main` and re-pulls only when it has
actually moved, so checking costs one request and is usually a no-op.

## Command line

`meeting-notes-cli` drives the same pipeline without a UI, which is the quickest
way to check a recording or verify a change.

Anything that does not write notes runs straight from SwiftPM:

```bash
swift run meeting-notes-cli process recording.m4a      # transcript only
swift run meeting-notes-cli transcribe recording.m4a   # raw timed text runs
swift run meeting-notes-cli diarize recording.m4a      # speaker segments only
swift run meeting-notes-cli tracks recording.m4a --output tracks/   # one WAV per speaker
swift run meeting-notes-cli models                     # what is installed
swift run meeting-notes-cli models --download          # pre-fetch speech + speaker
```

`process`, `diarize`, `tracks` and `models` take `--engine sortformer|pyannote`
(default Sortformer); `diarize` also accepts `--voiceprints` to run the
recognition pass alongside Sortformer, and per-engine tuning flags listed in
`--help`.

`--notes` needs the Metal shaders, so it has to be an `xcodebuild` binary. Build
it once:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild build -scheme meeting-notes-cli -destination 'platform=OS X' \
  -derivedDataPath .build/xcode \
  -skipPackagePluginValidation -skipMacroValidation
```

then:

```bash
CLI=.build/xcode/Build/Products/Debug/meeting-notes-cli

$CLI models --download-notes-model                    # install the default model
$CLI process recording.m4a --notes                    # transcript + notes
$CLI process recording.m4a --notes --notes-model qwen3-8b-4bit
```

`--notes-model` takes a catalog id — `qwen3-1.7b-4bit`, `qwen3-4b-4bit` or
`qwen3-8b-4bit` — and an unknown one falls back to the default rather than
failing, the way `--locale` does.

`--notes-sections "Summary,Risks,Next Steps"` replaces the default section
headings with your own (a title matching a default section keeps its standard
rules), and `--notes-instructions "Write in Portuguese"` adds free-form
guidance. Both mirror the customization in the app's Settings, though the CLI
does not read the app's saved template.

Progress goes to stderr and Markdown to stdout, so `... > notes.md` gives you a
clean file.

## How it works

```
audio file
   │
   ├── AVFoundation ──────────────► 16 kHz mono PCM
   │   AVAudioFile, or AVAssetReader        │
   │   for containers it rejects            ▼
   │                                  FluidAudio ──────► speaker spans
   │                                  Sortformer (or          │
   │                                  pyannote), CoreML       ▼
   │                                              one masked track per speaker
   │                                              (everyone else silenced,
   │                                               timeline intact)
   │                                                          │
   │                                  SpeechAnalyzer ◄────────┘  once per track
   │                                  on-device, word-level
   │                                  timestamps
   │                                              │
   │                                  interleave by time
   │                                              │
   │                              speaker-attributed transcript
   │                                              │
   └───────────────────────────────► Qwen3 ───────┘  (MLX, on the GPU)
                                       │
                                  Markdown notes
```

### Why speakers come first

A clustering diarizer works on ten-second windows, and a voice that only ever
says "yes" for half a second inside someone else's window never gets a slot of
its own — it is simply absorbed. Sortformer is end-to-end and does give such a
reply its own span, and once the spans are known the cleanest way to attribute
words is not to reconcile two timelines after the fact but to let the
recognizer hear one speaker at a time:

1. `SpeakerTrackBuilder` cuts one full-length track per speaker: that
   speaker's spans, padded a quarter second each side so a change localized
   slightly late never clips a first word, with everyone else muted and the
   edges faded. Overlapping speech lands in every track it belongs to.
2. Each track goes through `SpeechAnalyzer` on its own. Because the track is
   full length, word timestamps already sit on the meeting's timeline.
3. Words the recognizer finds in the muted stretches are hallucinations and
   are dropped; a word caught in the padding that sits on another speaker's
   turn is theirs, and the same word heard on two tracks at once goes to the
   speaker whose turn contains its end (diarizers mark a change late, not
   early).
4. Audio no speaker covers is measured against the loudness of the speech
   that was found; if at least a second of comparable sound is sitting there,
   the diarizer missed it, and that leftover audio gets one more pass whose
   words go to the nearest speaker within a second or to "Unknown speaker".
5. `TranscriptMerger.assemble` interleaves the speakers' runs by time,
   coalesces consecutive runs from one speaker into utterances, and numbers
   speakers by first appearance.

The cost is one recognition pass per speaker rather than one per meeting.
`TranscriptMerger.merge`, the earlier overlap-based reconciliation, remains as a
pure, heavily tested function.

## Speaker recognition

The diarizer labels speakers per recording — the same person is "S1" today and
"S3" tomorrow. To connect them, the app keeps a small directory of people known
by voice. The pyannote pipeline yields a compact numeric voiceprint per speaker
(a 256-dimension embedding); Sortformer does not, so while recognition is on
the app runs the pyannote pass alongside it and carries each voiceprint over to
the Sortformer speaker whose speech it covers — only when the match is
one-to-one, since a pyannote cluster that spans two Sortformer speakers is a
blend of both voices. Every speaker who talked long enough is then compared
against the directory by cosine distance. A confident
match links the speaker to that person and applies their name; an unfamiliar
voice is enrolled as a new, unnamed person whose record improves as more
meetings are heard.

Naming works in both directions. Renaming a recognized speaker in a transcript
renames that person in every meeting their voice was linked in, and stores the
name for future recordings. Settings › Speakers lists everyone, shows how many
meetings each voice appeared in, and offers rename and delete — deleting a
voice keeps the names meetings already show but severs the link, and "Delete
All Voices" erases every voiceprint. A toggle turns recognition off entirely,
in which case new meetings behave exactly as before.

The privacy story is unchanged: voiceprints are derived on this Mac from your
own recordings, stored in a single local JSON file, and never leave the
machine. They are also disposable — deleting them loses no transcript or note,
only the automatic naming.

Matching is deliberately conservative. A borderline voice becomes a duplicate
unnamed entry rather than risk fusing two people into one record; give it a
name (or delete it) and carry on. Speakers heard for only a few seconds are
ignored — that little audio does not make a reliable voiceprint.

## Storage

Meetings live in `~/Library/Application Support/MeetingNotes/Meetings/<uuid>/`
as `meeting.json` plus a copy of the imported audio, so moving or deleting the
original recording does not break the library. The document is rewritten after
every completed stage, so cancelling or crashing never loses finished work and a
retry resumes rather than restarts.

A recording in progress is written to `Meetings/.recordings/<uuid>.caf` —
16-bit PCM at up to 24 kHz, about 170 MB an hour, uncompressed so that a file
whose writer never closed is still readable — and moved into its meeting's
directory when it stops. Anything left there at launch is imported as a
recovered recording.

The voice directory is a sibling file,
`~/Library/Application Support/MeetingNotes/people.json` — one record per known
voice. The CLI neither reads nor writes it: `meeting-notes-cli` processes each
file hermetically in a throwaway store, so scripted runs never touch the app's
library or its voiceprints.

Notes models live in the shared Hugging Face cache — `$HF_HUB_CACHE`, else
`$HF_HOME/hub`, else `~/.cache/huggingface/hub` — so a model already pulled by
another MLX or Python tool is reused rather than downloaded twice. They outlive
the app: deleting it leaves the weights behind for whatever else uses them.

## Layout

```
Sources/
  MeetingNotesCore/     all the logic, no UI — unit-testable
    Audio/              decode to 16 kHz mono, cut per-speaker tracks, write WAV
    Transcription/      TranscriptionService protocol + the Apple implementation
    Diarization/        DiarizationService protocol, Sortformer and pyannote
                        implementations, voiceprint carry-over between them
    Merge/              TranscriptMerger — pure, heavily tested
    Recognition/        SpeakerRecognizer — matches voiceprints across meetings
    Notes/              NotesService protocol, MLX implementation, model catalog
    Pipeline/           stage orchestration and progress
    Persistence/        MeetingStore actor
    Export/             Markdown
  MeetingNotesApp/      SwiftUI app
  meeting-notes-cli/    headless driver
Tests/
  MeetingNotesCoreTests/
  Fixtures/make_two_speakers.sh
```

ASR, diarization and notes all sit behind protocols, so any engine can be
swapped without touching merging, persistence, or the UI.

## Testing

```bash
./Scripts/test.sh
```

The suite is hermetic: no network, no model download, no committed audio. The
notes stage runs against a `StubNotesService` returning canned Markdown — the
real MLX-backed service is never constructed in tests — and the audio tests
synthesize their own WAV files.

For an end-to-end check, generate the two-speaker fixture and run it through:

```bash
./Tests/Fixtures/make_two_speakers.sh
.build/xcode/Build/Products/Debug/meeting-notes-cli \
  process Tests/Fixtures/two-speakers.m4a --notes
```

The fixture is built with macOS text-to-speech and is not committed. It is a
deliberately hard case — the turns are spliced with no silence between them —
so a couple of boundary words land on the wrong speaker. Real recordings, which
have pauses at turn changes, come out cleaner.

## Known limits

- Recording uses the system default input device, and captures all other
  apps' audio rather than one chosen app. macOS asks for microphone and
  system-audio permission on the first recording; there is no API to tell
  whether system audio was denied, so a denied tap simply records silence —
  watch the system meter.

- Long recordings are held in memory as 16 kHz mono `Float32` (~230 MB/hour)
  while the diarizer runs, and each speaker's track is written to a temporary
  WAV of the same length (~115 MB/hour) for its transcription pass, one at a
  time. Comfortable to about three hours.
- Transcription runs once per speaker, so a four-person meeting takes about
  four times as long to transcribe as a monologue. Sortformer follows at most
  four speakers; a fifth voice is folded into one of the four.
- On first use the app downloads the speech model and the diarization models,
  and Settings downloads a notes model. After that everything works offline.
- Notes are written by a 4-bit quantized Qwen3 (1.7B, 4B or 8B) with a
  4,096-token cap. If a meeting hits that cap the app says so rather than
  silently truncating.
- A local model of this size writes noticeably plainer notes than a frontier
  model would, and is likelier to drift off the sectioned format on a long
  or messy transcript. If that happens, try the next size up.
- The model stays resident between runs so a second meeting does not pay the
  load again; switching models in Settings releases the old one.
