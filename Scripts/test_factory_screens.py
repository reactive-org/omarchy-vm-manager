#!/usr/bin/env python3
"""Isolated native UI acceptance with synthetic services and no Docker/runtime."""
import argparse
import json
from pathlib import Path
import struct
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    parent = Path(tempfile.mkdtemp(prefix='factory-screen-acceptance-', dir='/private/tmp'))
    output = parent / 'result'
    subprocess.run([str(args.binary), '--accept-factory-screens', str(output)], check=True, timeout=60)
    report = json.loads((output / 'result.json').read_text())
    assert report['runtimeStarts'] == 0 and report['dockerCommands'] == 0
    assert report['screenshots'] == 12
    for appearance in ['dark', 'light']:
        for case in ['library', 'missing-docker-blocks', 'readiness-does-not-build', 'one-explicit-build', 'follow-default', 'actual-terminal-render', 'newvm-factory-handoff', 'newvm-save-selection', 'newvm-never-launches', 'cleanup-does-not-rebuild']:
            assert appearance + '-' + case in report['checks']
    pngs = list(output.glob('*.png'))
    assert len(pngs) == report['screenshots']
    for path in pngs:
        data = path.read_bytes()
        assert data[:8] == b'\x89PNG\r\n\x1a\n'
        width, height = struct.unpack('>II', data[16:24])
        assert width >= 600 and height >= 800
    print(f'Factory screen acceptance: {len(report["checks"])} checks, {len(pngs)} PNGs; fake services only.')
    print(f'Artifacts retained for inspection: {output}')


if __name__ == '__main__':
    main()
