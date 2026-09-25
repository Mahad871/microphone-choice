#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_binary="$(mktemp /tmp/microphone-choice-tracker.XXXXXX)"
trap 'rm -f "$test_binary"' EXIT
swiftc "$project_dir/Sources/MicrophoneChoice/ConnectionTracker.swift" \
  "$project_dir/Tests/ConnectionTrackerTests.swift" -o "$test_binary"
"$test_binary"
