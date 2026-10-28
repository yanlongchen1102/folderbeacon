#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/folderbeacon-detector-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -module-cache-path "$test_dir/module-cache" \
  "$project_root/FolderBeacon-Mac/Core/FilePanelDetector/AXWindowInspector.swift" \
  "$project_root/tests/FilePanelDetectionTests.swift" \
  -o "$test_dir/file-panel-tests"
"$test_dir/file-panel-tests"
