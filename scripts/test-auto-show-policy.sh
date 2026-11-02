#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -module-cache-path "$test_dir/module-cache" \
  "$project_root/FolderBeacon-Mac/Core/FilePanelDetector/AutoShowPolicy.swift" \
  "$project_root/tests/AutoShowPolicyTests.swift" -o "$test_dir/tests"
"$test_dir/tests"
