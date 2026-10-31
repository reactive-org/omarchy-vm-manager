#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
export PATH="/opt/homebrew/bin:$PATH"
python3 "$root/Scripts/build_patched_kit.py"
