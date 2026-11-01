#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
export PATH="/opt/homebrew/bin:$PATH"
diagnostics=--diagnostics-json
if [[ "${1:-}" == --bundle-only ]]; then
  diagnostics=--verify-bundle-json
  shift
fi
app="${1:-$root/dist/Omarchy VM Manager.app}"
kit="$app/Contents/Helpers/TryOmarchyKit.bundle"
codesign --verify --deep --strict "$app"
python3 "$root/Vendor/try-omarchy/scripts/kit_signature.py" verify --signature-only "$kit"
"$root/Vendor/try-omarchy/macos/verify-macos-compatibility.sh" "$app"
"$app/Contents/MacOS/OmarchyVMManager" "$diagnostics"
python3 "$root/Scripts/verify_layout.py" "$app"
