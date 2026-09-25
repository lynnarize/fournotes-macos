#!/bin/bash
# Runs the test suite and prints only what matters.
set -euo pipefail

cd "$(dirname "$0")/.."
# Pick up any newly added source files.
xcodegen generate --quiet
xcodebuild test -project FourNotes.xcodeproj -scheme FourNotes \
  -destination 'platform=macOS' -derivedDataPath build/dd 2>&1 \
| grep -E "error:|✘|✔ Suite|Test run with|recorded an issue|Fatal error" \
| grep -v "linkd.autoShortcut"
