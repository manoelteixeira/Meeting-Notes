#!/bin/bash
# Assembles build/MeetingNotes.app around the executable.
#
# A real bundle is needed for two reasons: SwiftUI's Settings scene and
# NSSavePanel expect one, and Speech's on-device assets are tracked per
# application.
#
# This builds with `xcodebuild` rather than `swift build`. MLX's compute kernels
# are Metal shaders, and SwiftPM on the command line cannot compile them — a
# `swift build` binary dies at the first generation with "Failed to load the
# default metallib". Only xcodebuild runs the Metal compiler, so the app is
# built that way and `swift build` is left to the library and the tests, which
# never execute a kernel.
#
#   ./Scripts/make_app.sh [--release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="Debug"
[ "${1:-}" = "--release" ] && CONFIG="Release"

# xcodebuild needs full Xcode; the Command Line Tools alone cannot build shaders.
if [ ! -d /Applications/Xcode.app ]; then
  echo "error: full Xcode is required to compile MLX's Metal shaders." >&2
  echo "       The Command Line Tools alone cannot build them." >&2
  exit 1
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if ! xcrun -f metal >/dev/null 2>&1; then
  echo "error: the Metal toolchain is not installed. Install it with:" >&2
  echo "       xcodebuild -downloadComponent MetalToolchain" >&2
  exit 1
fi

# Kept under .build so the SwiftPM and xcodebuild caches sit together
# and a single .gitignore entry covers both.
DERIVED=".build/xcode"
# The package's plugins and macros are trusted here rather than interactively:
# a fresh clone would otherwise stop and wait for approval that never comes.
xcodebuild build \
  -scheme MeetingNotesApp \
  -configuration "$CONFIG" \
  -destination 'platform=OS X' \
  -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  > .build/xcodebuild.log 2>&1 || { tail -40 .build/xcodebuild.log >&2; exit 1; }

# The icon is generated from Scripts/make_icon.swift rather than committed.
if [ ! -f Resources/AppIcon.icns ]; then
  swift Scripts/make_icon.swift
fi

BIN="$DERIVED/Build/Products/$CONFIG"
APP="build/MeetingNotes.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/MeetingNotesApp" "$APP/Contents/MacOS/MeetingNotesApp"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Dependency resource bundles go in Contents/Resources, the only place a signed
# app may carry them: leaving them in the bundle root is unsealed content and
# codesign refuses the app outright.
#
# One of these is load-bearing. mlx-swift_Cmlx.bundle holds default.metallib,
# every MLX compute kernel the notes model runs on. MLX finds it by walking
# NS::Bundle::allBundles() and looking under each resourceURL, which is exactly
# Contents/Resources — so this placement works, and the app crashes on the first
# generation without it.
#
# The rest are inert here: FluidAudio's is text-to-speech pronunciation data
# (this app uses the diarizer alone) and swift-transformers' holds fallback
# gpt2/t5 tokenizer configs, reached only for models that ship no tokenizer
# config of their own, which none in the catalog do. Those two resolve through
# SwiftPM's generated `Bundle.module`, which looks beside the executable and so
# would *not* find them here — fine while nothing loads them, but revisit this
# if that changes.
for bundle in "$BIN"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

if [ ! -d "$APP/Contents/Resources/mlx-swift_Cmlx.bundle" ]; then
  echo "error: mlx-swift_Cmlx.bundle is missing; the app would crash when it" >&2
  echo "       tries to generate notes. Check the Metal toolchain install." >&2
  exit 1
fi

# Ad-hoc sign so Speech sees a stable identity across runs.
if ! codesign --force --sign - \
     --identifier com.meetingnotes.MeetingNotes "$APP"; then
  echo "warning: ad-hoc signing failed; Speech may re-prompt on every launch" >&2
fi

echo "Built $APP"
