#!/bin/bash
# Compiles and runs the test suite. Uses swiftc directly, for the same reason
# build.sh does: `swift test` goes through SwiftPM, which spawns its own
# sandbox-exec for manifest evaluation and cannot nest inside some sandboxed
# environments.
#
# Default: hermetic tests only (no real keychain / CLI / ~/.config).
# Pass --integration to also run IntegrationTests.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

INTEGRATION=0
for arg in "$@"; do
  case "$arg" in
    --integration) INTEGRATION=1 ;;
  esac
done

mkdir -p .build/tests/tmp
SOURCES=$(find Sources/AIMeter -name '*.swift' ! -name main.swift ! -path '*/Diagnostics/*')

ARGS=()
if [[ "$INTEGRATION" -eq 1 ]]; then
  ARGS+=(--integration)
fi

TMPDIR="$PWD/.build/tests/tmp" swiftc -swift-version 5 \
  -target arm64-apple-macosx14.0 \
  -module-cache-path "$PWD/.build/tests/modcache" \
  -o .build/tests/run \
  $SOURCES tools/tests/Harness.swift \
  tools/tests/HermeticTests.swift tools/tests/IntegrationTests.swift \
  tools/tests/AIMeterTests.swift

exec .build/tests/run "${ARGS[@]}"
