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
runtime_lock="${2:-$root/Config/TryOmarchyRuntime.lock.json}"
kit_team=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("signingTeamID", ""))' "$runtime_lock")
codesign --verify --deep --strict "$app"
if [[ -n "$kit_team" ]]; then
  python3 "$root/Vendor/try-omarchy/scripts/kit_signature.py" verify --signature-only --team "$kit_team" "$kit"
else
  python3 "$root/Vendor/try-omarchy/scripts/kit_signature.py" verify --signature-only "$kit"
fi
"$root/Vendor/try-omarchy/macos/verify-macos-compatibility.sh" "$app"
"$app/Contents/MacOS/OmarchyVMManager" "$diagnostics"
python3 "$root/Scripts/verify_layout.py" "$app" --runtime-lock "$runtime_lock"
