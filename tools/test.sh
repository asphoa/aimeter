#!/bin/bash
# Compiles and runs the test suite. Uses swiftc directly, for the same reason
# build.sh does: `swift test` goes through SwiftPM, which spawns its own
# sandbox-exec for manifest evaluation and cannot nest inside some sandboxed
# environments.
#
# Compiles every app source file except main.swift (which has its own
# top-level executable code - a Swift module may only have one file with top-
# level statements, and here that file is AIMeterTests.swift) together with
# the test harness and test file.
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p .build/tests/tmp
SOURCES=$(find Sources/AIMeter -name '*.swift' ! -name main.swift)

TMPDIR="$PWD/.build/tests/tmp" swiftc -swift-version 5 \
  -target arm64-apple-macosx14.0 \
  -module-cache-path "$PWD/.build/tests/modcache" \
  -o .build/tests/run \
  $SOURCES tools/tests/Harness.swift tools/tests/AIMeterTests.swift

exec .build/tests/run
