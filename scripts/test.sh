#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
stage=$(mktemp -d "${TMPDIR:-/tmp}/cliproxy-tests.XXXXXX")
trap 'rm -rf "$stage"' EXIT
sdk=${MACOS_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}
for test in Tests/*Regression.swift; do
  name=$(basename "$test" .swift)
  # Exclude the app's @main and UI; regressions use synthetic network responses.
  xcrun swiftc -sdk "$sdk" Shared/*.swift App/QuotaPrintPolicy.swift \
    App/ThermalPrinterService.swift "$test" -o "$stage/$name"
  "$stage/$name"
done
python3 -m unittest discover -s Tests -p 'test_*.py'
