#!/bin/sh
# Runs every automated suite with Aseprite's embedded Lua 5.4 in batch mode.
# Override the binary with ASEPRITE=/path/to/aseprite.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASEPRITE="${ASEPRITE:-/Applications/Aseprite.app/Contents/MacOS/aseprite}"
run() {
  echo "== $1"
  # Crashpad prints harmless WARNING lines on macOS; hide them.
  "$ASEPRITE" -b --script "$ROOT/tests/$1" 2>&1 | grep -v "WARNING mach_o_image" | tee "${TMPDIR:-/tmp}/palette-trio-$1.log"
  grep -q " 0 failed" "${TMPDIR:-/tmp}/palette-trio-$1.log"
}
run run.lua
run integration.lua
run smoke_dialogs.lua
echo "All suites passed."
