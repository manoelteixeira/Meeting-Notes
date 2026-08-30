#!/bin/bash
# Runs the test suite.
#
# Swift Testing ships with the Command Line Tools rather than the macOS SDK, so
# swiftpm needs to be pointed at its framework and dylib explicitly. With a full
# Xcode install these flags are harmless.
set -euo pipefail
cd "$(dirname "$0")/.."

FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"
TESTING_LIB="$(xcode-select -p)/Library/Developer/usr/lib"

exec swift test \
  -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
  -Xlinker -F -Xlinker "$FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$TESTING_LIB" \
  "$@"
