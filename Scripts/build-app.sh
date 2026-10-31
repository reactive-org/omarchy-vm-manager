#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
export PATH="/opt/homebrew/bin:$PATH"
exec python3 "$root/Scripts/assemble_app.py"
