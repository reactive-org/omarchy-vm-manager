#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
export PATH="/opt/homebrew/bin:$PATH"
python3 -c 'import sys; assert sys.version_info >= (3, 10), "Python 3.10+ required by upstream"'
source=$(python3 "$root/Scripts/upstream_source.py")
exec make -C "$source" "$@"
