#!/bin/bash
# Builds a deterministic two-speaker meeting fixture using macOS text-to-speech.
#
# The audio is generated rather than committed: regenerating costs a couple of
# seconds and keeps binaries out of the repo.
#
#   ./make_two_speakers.sh [output.m4a]
#
# Output defaults to Tests/Fixtures/two-speakers.m4a
set -euo pipefail
cd "$(dirname "$0")"

VOICE_A="${VOICE_A:-Samantha}"   # en_US
VOICE_B="${VOICE_B:-Daniel}"     # en_GB — a clearly different voice, so
                                 # diarization has something to separate.
OUT="${1:-two-speakers.m4a}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Alternating turns: a correct merge yields Speaker 1 / Speaker 2 / Speaker 1 …
lines=(
  "A|Thanks for joining. Let's review where we are on the mobile release."
  "B|Sure. The build is stable, but we still have two crash reports from Android."
  "A|How serious are they? Do we need to hold the release for them?"
  "B|One is a rare race condition in the sync layer. The other is a null check I can fix today."
  "A|Let's fix the null check now and ship on Thursday. We can patch the race next sprint."
  "B|Agreed. I will open a ticket for the race condition and assign it to myself."
  "A|Great. I will update the release notes and let support know about the Thursday date."
  "B|One more thing. We should ask design for the new empty state before Thursday."
  "A|Good catch. I will email design this afternoon and ask for it by Wednesday morning."
  "B|Perfect. Then I think we are done."
)

index=0
for line in "${lines[@]}"; do
  speaker="${line%%|*}"
  text="${line#*|}"
  if [ "$speaker" = "A" ]; then voice="$VOICE_A"; else voice="$VOICE_B"; fi
  say -v "$voice" -o "$work/$(printf '%03d' "$index").aiff" "$text"
  index=$((index + 1))
done

# Normalize every turn to the same PCM format, concatenate, then encode to m4a
# so the fixture exercises the AAC/mp4 decode path the app cares about.
python3 - "$work" <<'PY'
import glob, os, subprocess, sys, wave

work = sys.argv[1]
parts = sorted(glob.glob(os.path.join(work, "*.aiff")))
wavs = []
for i, part in enumerate(parts):
    dst = os.path.join(work, f"norm{i:03d}.wav")
    subprocess.run(
        ["afconvert", "-f", "WAVE", "-d", "LEI16@22050", "-c", "1", part, dst],
        check=True,
    )
    wavs.append(dst)

joined = os.path.join(work, "joined.wav")
with wave.open(joined, "wb") as dst:
    with wave.open(wavs[0], "rb") as first:
        dst.setparams(first.getparams())
        dst.writeframes(first.readframes(first.getnframes()))
    for path in wavs[1:]:
        with wave.open(path, "rb") as src:
            dst.writeframes(src.readframes(src.getnframes()))
PY

afconvert -f m4af -d aac -b 64000 "$work/joined.wav" "$OUT"
echo "Wrote $(pwd)/$OUT"
afinfo "$OUT" | sed -n '2,5p'
