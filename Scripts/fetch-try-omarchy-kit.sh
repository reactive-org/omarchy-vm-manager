#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
exec python3 "$root/Scripts/kit_artifacts.py" fetch
