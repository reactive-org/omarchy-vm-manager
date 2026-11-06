#!/usr/bin/env python3
"""Isolated native UI acceptance with synthetic services and no Docker/runtime."""
import argparse
import json
from pathlib import Path
import struct
import subprocess
import tempfile


def validate_dimensions(name, width, height, frame):
    """Compare pixels with actual logical bounds, independent of backing scale."""
    points_width, points_height = frame['widthPoints'], frame['heightPoints']
    assert type(points_width) in (int, float) and type(points_height) in (int, float), name
    sheet = name.startswith(('factory-build-sheet-', 'factory-missing-docker-'))
    minimum = (570, 420) if sheet else (1000, 800)
    assert minimum[0] <= points_width <= 2000 and minimum[1] <= points_height <= 1400, (name, frame)
    assert any(abs(width - points_width * scale) <= 1 and abs(height - points_height * scale) <= 1 for scale in (1, 2)), (name, width, height, frame)


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
    expected = {f'factory-{case}-{appearance}.png' for case in ['library', 'missing-docker', 'build-sheet', 'build-running', 'ready', 'cleanup'] for appearance in ['dark', 'light']}
    assert {p.name for p in pngs} == set(report['captures']) == expected
    for path in pngs:
        data = path.read_bytes()
        assert data[:8] == b'\x89PNG\r\n\x1a\n' and data[12:16] == b'IHDR', path.name
        width, height = struct.unpack('>II', data[16:24])
        validate_dimensions(path.name, width, height, report['captures'][path.name])
    print(f'Factory screen acceptance: {len(report["checks"])} checks, {len(pngs)} PNGs; fake services only.')
    print(f'Artifacts retained for inspection: {output}')


if __name__ == '__main__':
    main()
