#!/usr/bin/env python3
"""CI-only branch release planning and publication. Never opens an app or VM."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

from kit_artifacts import ROOT, digest
from keychain_profile import profile_pin
from release_metadata import channel_spec, tag_version, validate_tag

REPOSITORY = 'reactive-org/omarchy-vm-manager'
BRANCHES = {'refs/heads/main': 'stable', 'refs/heads/next': 'development'}
MARKER = 'Omarchy branch release v1\n'
PLAN = ROOT / '.build/branch-release.json'


def command(*args, optional=False):
    result = subprocess.run([str(arg) for arg in args], cwd=ROOT, capture_output=True, text=True)
    if result.returncode:
        if optional and '(HTTP 404)' in result.stderr:
            return None
        raise RuntimeError(f'{args[0]} failed: {result.stderr[-2000:]}')
    return result.stdout.strip()


def api(path, optional=False):
    value = command('gh', 'api', f'repos/{REPOSITORY}/{path}', optional=optional)
    return json.loads(value) if value is not None else None


def context(environment=None):
    env = os.environ if environment is None else environment
    if env.get('GITHUB_ACTIONS') != 'true' or env.get('GITHUB_EVENT_NAME') != 'push' or env.get('GITHUB_REPOSITORY') != REPOSITORY:
        raise ValueError('Branch publication is restricted to this repository’s CI push jobs')
    if env.get('GITHUB_REF') not in BRANCHES or not re.fullmatch('[0-9a-f]{40}', env.get('GITHUB_SHA', '')):
        raise ValueError('Only exact main/next push revisions may release')
    if not re.fullmatch('[1-9][0-9]{0,8}', env.get('GITHUB_RUN_NUMBER', '')):
        raise ValueError('A positive CI build number is required')
    return BRANCHES[env['GITHUB_REF']], env['GITHUB_SHA']


def version_tuple(version):
    return tuple(int(value) for value in tag_version('v' + version).split('.'))


def next_tag(channel, floor, tags):
    channel_spec(channel)
    baseline = version_tuple(floor)
    stable = [version_tuple(tag[1:]) for tag in tags if re.fullmatch(r'v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)', tag)]
    latest = max(stable, default=baseline)
    if stable and baseline[:2] > latest[:2]:
        upcoming = baseline
    else:
        base = max(baseline, latest)
        upcoming = (base[0], base[1], base[2] + 1)
    version = '.'.join(map(str, upcoming))
    if channel == 'stable':
        return 'v' + version
    pattern = re.compile(re.escape('v' + version) + r'-dev\.([1-9][0-9]*)')
    numbers = [int(match[1]) for tag in tags if (match := pattern.fullmatch(tag))]
    return f'v{version}-dev.{max(numbers, default=0) + 1}'


def reservation(message):
    if not message.startswith(MARKER):
        return None
    value = json.loads(message[len(MARKER):])
    assert set(value) == {'format', 'channel', 'commit', 'tag', 'version', 'build'} and value['format'] == 1
    validate_tag(value['tag'], value['version'], value['channel'])
    assert re.fullmatch('[0-9a-f]{40}', value['commit'])
    assert re.fullmatch('[1-9][0-9]{0,8}', value['build'])
    return value


def load_plan():
    channel, sha = context()
    value = json.loads(PLAN.read_text())
    assert value['channel'] == channel and value['commit'] == sha
    assert command('git', 'rev-parse', 'HEAD') == sha
    if not value.get('skip'):
        validate_tag(value['tag'], value['version'], channel)
        assert command('git', 'rev-parse', value['tag'] + '^{}') == sha
        reserved = reservation(command('git', 'for-each-ref', '--format=%(contents)', 'refs/tags/' + value['tag']))
        assert reserved == value, 'plan differs from the immutable version reservation'
    return value


def is_ancestor(older, newer):
    result = subprocess.run(['git', 'merge-base', '--is-ancestor', older, newer], cwd=ROOT, capture_output=True)
    assert result.returncode in (0, 1), 'could not establish release commit ancestry'
    return result.returncode == 0


def plan():
    channel, sha = context()
    assert command('git', 'rev-parse', 'HEAD') == sha, 'checkout differs from tested push'
    profile_pin(channel_spec(channel)[0])
    command('git', 'fetch', 'origin', '--tags')
    tags = command('git', 'for-each-ref', '--format=%(refname:short)', 'refs/tags').splitlines()
    records = []
    for tag in tags:
        if not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+(?:-dev\.[1-9][0-9]*)?', tag):
            continue
        value = reservation(command('git', 'for-each-ref', '--format=%(contents)', 'refs/tags/' + tag))
        if value:
            assert value['tag'] == tag and command('git', 'rev-parse', tag + '^{}') == value['commit']
            records.append(value)
    existing = [value for value in records if value['channel'] == channel and value['commit'] == sha]
    assert len(existing) <= 1, 'ambiguous reservations for this channel/commit'
    if existing:
        value = existing[0]
    else:
        # A slower old push must never allocate a higher version after a newer
        # descendant has already reserved one. No branch pointer is checked out.
        superseded = any(value['channel'] == channel and value['commit'] != sha and is_ancestor(sha, value['commit'])
                         for value in records)
        if superseded:
            value = {'channel': channel, 'commit': sha, 'skip': True, 'reason': 'superseded by a newer reserved commit'}
        else:
            floor = plistlib.loads((ROOT / 'App/Info.plist').read_bytes())['CFBundleShortVersionString']
            tag = next_tag(channel, floor, tags)
            value = {'format': 1, 'channel': channel, 'commit': sha, 'tag': tag,
                     'version': tag_version(tag), 'build': os.environ['GITHUB_RUN_NUMBER']}
            with tempfile.NamedTemporaryFile(mode='w', prefix='release-tag-', delete=True) as note:
                note.write(MARKER + json.dumps(value, sort_keys=True)); note.flush()
                env = dict(os.environ, GIT_COMMITTER_NAME='github-actions[bot]',
                           GIT_COMMITTER_EMAIL='41898282+github-actions[bot]@users.noreply.github.com')
                subprocess.run(['git', '-c', 'tag.gpgsign=false', 'tag', '-a', tag, sha, '-F', note.name], cwd=ROOT, env=env, check=True)
            command('git', 'push', 'origin', 'refs/tags/' + tag)
    if not value.get('skip'):
        release = api('releases/tags/' + value['tag'], optional=True)
        if release and not release['draft']:
            expected = f"{channel_spec(channel)[3]}-{value['tag']}-macOS-arm64-notarized.zip"
            assert release['prerelease'] == (channel == 'development')
            assert expected in {asset['name'] for asset in release['assets']}
            value = dict(value, skip=True, reason='this exact channel/commit is already published')
    PLAN.parent.mkdir(parents=True, exist_ok=True)
    PLAN.write_text(json.dumps(value, indent=2) + '\n')
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write('skip=' + str(bool(value.get('skip'))).lower() + '\n')
        output.write('channel=' + channel + '\n')
    print(json.dumps(value, sort_keys=True))


def asset_files(folder):
    files = sorted(path for path in folder.iterdir() if path.is_file() and path.suffix in {'.zip', '.sha256', '.json'})
    assert files and all(not path.is_symlink() for path in files)
    return {path.name: digest(path) for path in files}


def upload_missing(tag, release, folder, expected):
    existing = {asset['name']: asset for asset in release['assets']}
    assert not (set(existing) - set(expected)), 'unexpected existing release assets preserved'
    for name, sha in expected.items():
        if name in existing:
            recorded = existing[name].get('digest')
            if recorded:
                assert recorded == 'sha256:' + sha, 'existing asset differs; use retained original artifacts, never overwrite'
            else:
                with tempfile.TemporaryDirectory(prefix='release-asset-check-') as scratch:
                    command('gh', 'release', 'download', tag, '--repo', REPOSITORY, '--pattern', name, '--dir', scratch)
                    assert digest(Path(scratch) / name) == sha, 'existing asset differs; original preserved'
        else:
            command('gh', 'release', 'upload', tag, folder / name, '--repo', REPOSITORY)


def publish_files(tag, folder, notes, prerelease, latest=False, target=None):
    context()
    expected = asset_files(folder)
    release = api('releases/tags/' + tag, optional=True)
    if release is None:
        command('gh', 'release', 'create', tag, '--repo', REPOSITORY, '--draft', '--latest=false',
                '--prerelease' if prerelease else '--prerelease=false', '--title', tag,
                '--notes-file', notes, *(['--target', target] if target else ['--verify-tag']))
        release = api('releases/tags/' + tag)
    assert release['tag_name'] == tag and release['prerelease'] == prerelease
    if not release['draft']:
        assert {asset['name'] for asset in release['assets']} == set(expected), 'published release is incomplete'
        for asset in release['assets']:
            assert asset.get('digest') == 'sha256:' + expected[asset['name']], 'published bytes differ; immutable release preserved'
        return
    upload_missing(tag, release, folder, expected)
    completed = api('releases/tags/' + tag)
    assert {asset['name'] for asset in completed['assets']} == set(expected)
    for asset in completed['assets']:
        assert asset.get('digest') == 'sha256:' + expected[asset['name']], 'uploaded asset digest differs'
    command('gh', 'release', 'edit', tag, '--repo', REPOSITORY, '--draft=false',
            '--prerelease' if prerelease else '--prerelease=false', '--latest' if latest else '--latest=false')


def publish_runtime(lock, lock_path, folder, source_bytes):
    _, sha = context()
    source_sha = hashlib.sha256(source_bytes).hexdigest()
    assert lock['artifactTag'] == 'signed-runtime-' + source_sha
    destination = lock_path.parent / 'runtime-publication'
    destination.mkdir()
    import shutil
    shutil.copy2(folder / 'TryOmarchyKit.zip', destination / 'TryOmarchySignedKit.zip')
    shutil.copy2(lock_path, destination / 'TryOmarchySignedRuntime.lock.json')
    (destination / 'SourceRuntime.lock.json').write_bytes(source_bytes)
    archive = destination / 'TryOmarchySignedKit.zip'
    assert digest(archive) == lock['kitSHA256']
    (destination / 'TryOmarchySignedKit.zip.sha256').write_text(lock['kitSHA256'] + '  TryOmarchySignedKit.zip\n')
    notes = destination / 'notes.md'
    notes.write_text(f'Verified signed runtime dependency for source lock `{source_sha}`. No app or factory image.\n')
    publish_files(lock['artifactTag'], destination, notes, prerelease=True, target=sha)


def build():
    value = load_plan()
    assert not value.get('skip')
    os.environ.update(RELEASE_CHANNEL=value['channel'], RELEASE_TAG=value['tag'],
                      RELEASE_VERSION=value['version'], RELEASE_BUILD=value['build'])
    existing = api('releases/tags/' + value['tag'], optional=True)
    if existing and existing['assets']:
        raise RuntimeError('A draft already has signed assets. Recover its retained verified dist/prerelease artifacts and run release-publish; do not rebuild or overwrite them.')
    import signed_prerelease
    signed_prerelease.release()


def publish():
    value = load_plan()
    assert not value.get('skip')
    folder = ROOT / 'dist/prerelease'
    source = json.loads((folder / 'ReleaseSource.json').read_text())
    assert source['applicationSourceCommit'] == value['commit'] and source['releaseTag'] == value['tag']
    assert source['appChannel'] == value['channel']
    source_bytes = (ROOT / 'Config/TryOmarchyRuntime.lock.json').read_bytes()
    assert source['sourceLockSHA256'] == hashlib.sha256(source_bytes).hexdigest()
    assert (folder / 'SourceRuntime.lock.json').read_bytes() == source_bytes
    name = f"{channel_spec(value['channel'])[3]}-{value['tag']}-macOS-arm64-notarized.zip"
    assert digest(folder / name) == (folder / (name + '.sha256')).read_text().split()[0]
    # Re-verify restored candidates as well as freshly built archives, before any
    # GitHub publication. No credential import or VM launch is involved.
    with tempfile.TemporaryDirectory(prefix='release-final-') as scratch:
        command('ditto', '-x', '-k', folder / name, scratch)
        app = Path(scratch) / (channel_spec(value['channel'])[1] + '.app')
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        from release_metadata import verify_release_info
        verify_release_info(info, value['tag'], value['version'], value['channel'])
        assert info['CFBundleVersion'] == value['build']
        lock_path = app / 'Contents/Resources/TryOmarchyRuntime.lock.json'
        lock = json.loads(lock_path.read_bytes())
        from signed_prerelease import validate_signed_lock
        validate_signed_lock(lock, json.loads(source_bytes), source['sourceLockSHA256'], lock['signingTeamID'])
        assert source['sourceKitSHA256'] == lock['sourceKitSHA256']
        assert (folder / 'TryOmarchySignedRuntime.lock.json').read_bytes() == lock_path.read_bytes()
        assert digest(folder / 'TryOmarchySignedKit.zip') == lock['kitSHA256']
        command(ROOT / 'Scripts/verify-app.sh', '--bundle-only', app, lock_path)
        command('python3', ROOT / 'Scripts/verify_signed_app.py', app)
    latest = value['channel'] == 'stable'
    if latest:
        pages = json.loads(command('gh', 'api', f'repos/{REPOSITORY}/releases?per_page=100', '--paginate', '--slurp'))
        versions = [version_tuple(release['tag_name'][1:]) for page in pages for release in page
                    if not release['draft'] and not release['prerelease'] and re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', release['tag_name'])]
        latest = not versions or version_tuple(value['version']) >= max(versions)
    publish_files(value['tag'], folder, folder / 'release-notes.md', value['channel'] == 'development', latest)


if __name__ == '__main__':
    if sys.flags.optimize:
        raise RuntimeError('Optimized Python execution is refused')
    operations = {'plan': plan, 'build': build, 'publish': publish}
    if len(sys.argv) != 2 or sys.argv[1] not in operations:
        sys.exit('Use branch_release.py plan|build|publish')
    operations[sys.argv[1]]()
