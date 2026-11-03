#!/usr/bin/env python3
"""Own-process offscreen UI acceptance. No UI automation or real guest backend."""
import argparse
import json
import pathlib
import struct
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=pathlib.Path, required=True)
    args = parser.parse_args()
    parent = pathlib.Path(tempfile.mkdtemp(prefix='omarchy-screen-acceptance-', dir='/private/tmp'))
    output = parent / 'result'
    subprocess.run([str(args.binary), '--accept-setup-screens', str(output)], check=True, timeout=45)
    report = json.loads((output / 'report.json').read_text())
    assert report['schema'] == 1 and len(report['checks']) == 56
    assert len(set(report['checks'])) == len(report['checks'])
    assert report['runtimeStarts'] == 0 and report['visibleWindows'] == 0
    assert report['onscreenWindows'] == 0 and report['activation'] is False
    assert report['realExecution'] is False and report['physicalInputTested'] is False
    assert report['gate'] == 'unchanged-disabled' and report['fakeSubmissions'] == 1
    assert len(report['images']) == 8
    for name in report['images']:
        assert pathlib.Path(name).name == name and name.endswith('.png')
        data = (output / name).read_bytes()
        assert data[:8] == b'\x89PNG\r\n\x1a\n'
        width, height = struct.unpack('>II', data[16:24])
        assert width >= 600 and height >= 760
    assert not (output / 'unused-support').exists()
    print(f'Setup screen acceptance: {len(report["checks"])} checks, 8 PNGs; no runtime starts or on-display windows.')
    print(f'Artifacts retained for inspection: {output}')


if __name__ == '__main__':
    main()
