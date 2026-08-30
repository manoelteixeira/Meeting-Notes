# Meeting Notes

A native macOS app that turns a meeting recording into structured notes.

Drop in an audio file and it transcribes the speech, works out who said what,
and writes up a summary with decisions and action items.

**Where your data goes.** Nowhere. Transcription, speaker identification and
the notes all run on your Mac. The only thing that ever touches the network is
the one-time download of the models themselves; after that the app works
offline, and neither the audio nor the transcript leaves the machine.

## Features

- **Import a recording** by dragging it into the window or with the file
  picker. Anything AVFoundation can decode works — m4a, mp3, wav, and the rest.
- **On-device transcription** with Apple's `SpeechAnalyzer`, with word-level
  timestamps. The transcription language is selectable in Settings.
- **Speaker identification** with FluidAudio, merged with the transcript into a
  speaker-attributed record of who said what. Speakers arrive numbered by first
  appearance and can be renamed inline in the transcript — the name applies
  everywhere at once.
- **Meeting notes written locally** by a quantized Qwen3 running on the GPU via
  MLX: a summary plus decisions and action items, in a consistent four-section
  format. Regenerate on demand, e.g. after renaming speakers or switching to a
  bigger model.
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

Bigger should write better notes and hold the four-section format more
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
swift run meeting-notes-cli models                     # what is installed
swift run meeting-notes-cli models --download          # pre-fetch speech + speaker
```

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

Progress goes to stderr and Markdown to stdout, so `... > notes.md` gives you a
clean file.

## How it works

```
audio file
   │
   ├── AVFoundation ──────────────► 16 kHz mono PCM ──┐
   │   AVAudioFile, or AVAssetReader                  │
   │   for containers it rejects                      │
   │                                                  ▼
   ├── SpeechAnalyzer ────────────► timed text    FluidAudio ──► speaker spans
   │   on-device, word-level         runs          on-device,
   │   timestamps                                  CoreML/ANE
   │                                    │               │
   │                                    └──── merge ────┘
   │                                            │
   │                              speaker-attributed transcript
   │                                            │
   └───────────────────────────────► Qwen3 ─────┘  (MLX, on the GPU)
                                       │
                                  Markdown notes
```

Transcription and diarization read the same audio independently, so they run
concurrently.

### Merging is the interesting part

The transcriber knows *what* was said and exactly when, down to the word. The
diarizer knows *who* was speaking, but only to within a few hundred
milliseconds. `TranscriptMerger` reconciles them:

1. Each speaker-change boundary is nudged onto a nearby pause between words,
   preferring the longest pause — a turn change almost always carries more
   silence than a gap mid-sentence. Without this, the first word of a new turn
   routinely lands on the previous speaker.
2. Each word is then assigned to the speaker whose span overlaps it most.
3. A run that genuinely straddles a change is split at a word boundary, never
   mid-word.
4. A run overlapping nothing attaches to the nearest speaker within a second,
   and otherwise becomes "Unknown speaker".
5. Consecutive runs from one speaker coalesce into utterances, and speakers are
   numbered by first appearance.

It is a pure function over two arrays, which is why it carries the bulk of the
tests.

## Storage

Meetings live in `~/Library/Application Support/MeetingNotes/Meetings/<uuid>/`
as `meeting.json` plus a copy of the imported audio, so moving or deleting the
original recording does not break the library. The document is rewritten after
every completed stage, so cancelling or crashing never loses finished work and a
retry resumes rather than restarts.

Notes models live in the shared Hugging Face cache — `$HF_HUB_CACHE`, else
`$HF_HOME/hub`, else `~/.cache/huggingface/hub` — so a model already pulled by
another MLX or Python tool is reused rather than downloaded twice. They outlive
the app: deleting it leaves the weights behind for whatever else uses them.

## Layout

```
Sources/
  MeetingNotesCore/     all the logic, no UI — unit-testable
    Audio/              decode to 16 kHz mono
    Transcription/      TranscriptionService protocol + the Apple implementation
    Diarization/        DiarizationService protocol + the FluidAudio implementation
    Merge/              TranscriptMerger — pure, heavily tested
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

- Long recordings are held in memory as 16 kHz mono `Float32` (~230 MB/hour)
  while the diarizer runs. Comfortable to about three hours.
- On first use the app downloads the speech model and the diarization models,
  and Settings downloads a notes model. After that everything works offline.
- Notes are written by a 4-bit quantized Qwen3 (1.7B, 4B or 8B) with a
  4,096-token cap. If a meeting hits that cap the app says so rather than
  silently truncating.
- A local model of this size writes noticeably plainer notes than a frontier
  model would, and is likelier to drift off the four-section format on a long
  or messy transcript. If that happens, try the next size up.
- The model stays resident between runs so a second meeting does not pay the
  load again; switching models in Settings releases the old one.
