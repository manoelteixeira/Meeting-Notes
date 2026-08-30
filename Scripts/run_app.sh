#!/bin/bash
# Builds the bundle and launches it, streaming its log output to this terminal.
set -euo pipefail
cd "$(dirname "$0")/.."

./Scripts/make_app.sh "$@"
open build/MeetingNotes.app
