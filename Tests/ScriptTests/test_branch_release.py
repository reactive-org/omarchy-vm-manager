"""Release policy fixtures: no network, credentials, app launch or VM storage."""
import json
import hashlib
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Scripts'))
import branch_release as release


class BranchReleaseTests(unittest.TestCase):
    def environment(self, branch='main'):
        return dict(GITHUB_ACTIONS='true', GITHUB_EVENT_NAME='push', GITHUB_REPOSITORY=release.REPOSITORY,
                    GITHUB_REF='refs/heads/' + branch, GITHUB_SHA='a' * 40, GITHUB_RUN_NUMBER='101')

    def record(self, channel='stable', commit='a' * 40, tag='v0.11.1'):
        return dict(format=1, channel=channel, commit=commit, tag=tag, version='0.11.1', build='100')

    def test_only_this_repositories_exact_main_and_next_pushes_can_release(self):
        self.assertEqual(release.context(self.environment()), ('stable', 'a' * 40))
        self.assertEqual(release.context(self.environment('next')), ('development', 'a' * 40))
        for key, value in [('GITHUB_ACTIONS', 'false'), ('GITHUB_EVENT_NAME', 'pull_request'),
                           ('GITHUB_EVENT_NAME', 'workflow_dispatch'), ('GITHUB_REPOSITORY', 'fork/repo'),
                           ('GITHUB_REF', 'refs/tags/v0.11.1'), ('GITHUB_REF', 'refs/heads/topic'),
                           ('GITHUB_SHA', 'main'), ('GITHUB_RUN_NUMBER', '0')]:
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                release.context(dict(self.environment(), **{key: value}))

    def test_patch_versions_and_upcoming_dev_sequence_share_a_base(self):
        tags = ['v0.10.0-dev.4', 'runtime-kit-abc']
        self.assertEqual(release.next_tag('stable', '0.11.0', tags), 'v0.11.1')
        self.assertEqual(release.next_tag('development', '0.11.0', tags), 'v0.11.1-dev.1')
        tags += ['v0.11.1-dev.1', 'v0.11.1-dev.10']
        self.assertEqual(release.next_tag('development', '0.11.0', tags), 'v0.11.1-dev.11')
        self.assertEqual(release.next_tag('stable', '0.11.0', tags), 'v0.11.1')
        tags += ['v0.11.1']  # Reservations count even when publication failed.
        self.assertEqual(release.next_tag('stable', '0.11.0', tags), 'v0.11.2')
        self.assertEqual(release.next_tag('development', '0.11.0', tags), 'v0.11.2-dev.1')
        self.assertEqual(release.next_tag('stable', '0.12.0', tags), 'v0.12.0')
        self.assertEqual(release.next_tag('stable', '0.11.0', tags + ['v0.11.9']), 'v0.11.10')

    def test_annotated_reservations_cannot_switch_channel_or_commit_shape(self):
        record = self.record()
        self.assertEqual(release.reservation(release.MARKER + json.dumps(record)), record)
        self.assertIsNone(release.reservation('Historical manual tag'))
        for changes in [dict(channel='development'), dict(commit='main'), dict(build='0'), dict(extra='untrusted')]:
            with self.subTest(changes=changes), self.assertRaises((AssertionError, ValueError)):
                release.reservation(release.MARKER + json.dumps(dict(record, **changes)))

    def exercise_plan(self, record, ancestor=False, published=False):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'App').mkdir()
            (root / 'App/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleShortVersionString='0.11.0')))
            env = dict(self.environment(), GITHUB_OUTPUT=str(root / 'output'))
            def command(*args, **kwargs):
                if args[:2] == ('git', 'rev-parse'):
                    return env['GITHUB_SHA'] if args[2] == 'HEAD' else record['commit']
                if args[:3] == ('git', 'for-each-ref', '--format=%(refname:short)'):
                    return record['tag']
                if args[:3] == ('git', 'for-each-ref', '--format=%(contents)'):
                    return release.MARKER + json.dumps(record)
                if args == ('git', 'fetch', 'origin', '--tags'):
                    return ''
                self.fail('Unexpected mutation/command: ' + repr(args))
            published_release = dict(draft=False, prerelease=False, assets=[dict(name='Omarchy-VM-Manager-v0.11.1-macOS-arm64-notarized.zip')])
            with patch.dict(os.environ, env, clear=True), patch.object(release, 'ROOT', root), \
                 patch.object(release, 'PLAN', root / 'plan.json'), patch.object(release, 'profile_pin'), \
                 patch.object(release, 'command', side_effect=command), patch.object(release, 'is_ancestor', return_value=ancestor), \
                 patch.object(release, 'api', return_value=published_release if published else None):
                release.plan()
            return json.loads((root / 'plan.json').read_text()), (root / 'output').read_text()

    def test_retry_reuses_original_version_and_build_without_creating_another_tag(self):
        record = self.record()
        planned, output = self.exercise_plan(record)
        self.assertEqual(planned, record)
        self.assertIn('skip=false', output)
        planned, output = self.exercise_plan(record, published=True)
        self.assertTrue(planned['skip'])
        self.assertIn('skip=true', output)

    def test_out_of_order_old_push_skips_instead_of_creating_a_newer_version(self):
        planned, output = self.exercise_plan(self.record(commit='b' * 40), ancestor=True)
        self.assertTrue(planned['skip'])
        self.assertIn('superseded', planned['reason'])
        self.assertIn('skip=true', output)

    def test_missing_dev_profile_fails_before_reserving_or_pushing_a_tag(self):
        with patch.dict(os.environ, self.environment('next'), clear=True), \
             patch.object(release, 'command', return_value='a' * 40) as command, \
             patch.object(release, 'profile_pin', side_effect=ValueError('Provisioning is not configured')):
            with self.assertRaisesRegex(ValueError, 'Provisioning'):
                release.plan()
            self.assertEqual(command.call_count, 1)

    def test_ancestry_errors_do_not_silently_allocate_versions(self):
        with patch.object(release.subprocess, 'run', return_value=SimpleNamespace(returncode=128)):
            with self.assertRaises(AssertionError):
                release.is_ancestor('a' * 40, 'b' * 40)

    def test_modified_restored_plan_is_refused_even_when_tag_commit_matches(self):
        record = self.record()
        with tempfile.TemporaryDirectory() as temp:
            plan = Path(temp) / 'plan.json'
            plan.write_text(json.dumps(dict(record, build='999')))
            def command(*args):
                return release.MARKER + json.dumps(record) if 'for-each-ref' in args else 'a' * 40
            with patch.dict(os.environ, self.environment(), clear=True), patch.object(release, 'PLAN', plan), \
                 patch.object(release, 'command', side_effect=command), self.assertRaisesRegex(AssertionError, 'reservation'):
                release.load_plan()

    def test_existing_assets_are_compared_and_missing_assets_uploaded_without_clobber(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            (folder / 'app.zip').write_bytes(b'fixture')
            expected = release.asset_files(folder)
            with patch.object(release, 'command') as command:
                release.upload_missing('v0.11.1', dict(assets=[]), folder, expected)
                self.assertNotIn('--clobber', command.call_args.args)
                command.reset_mock()
                same = dict(assets=[dict(name='app.zip', digest='sha256:' + expected['app.zip'])])
                release.upload_missing('v0.11.1', same, folder, expected)
                command.assert_not_called()
                for assets in [[dict(name='app.zip', digest='sha256:wrong')], [dict(name='other.zip')]]:
                    with self.assertRaises(AssertionError):
                        release.upload_missing('v0.11.1', dict(assets=assets), folder, expected)
                    command.assert_not_called()

    def test_incomplete_or_different_uploads_never_finalize_a_draft(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            (folder / 'app.zip').write_bytes(b'fixture')
            for assets in [[], [dict(name='app.zip', digest='sha256:wrong')]]:
                with patch.dict(os.environ, self.environment(), clear=True), \
                     patch.object(release, 'api', return_value=dict(tag_name='v0.11.1', draft=True, prerelease=False, assets=assets)), \
                     patch.object(release, 'upload_missing'), patch.object(release, 'command') as command:
                    with self.assertRaises(AssertionError):
                        release.publish_files('v0.11.1', folder, folder / 'notes.md', False)
                    command.assert_not_called()

    def test_successful_uploads_finalize_only_after_verification_and_never_mark_dev_latest(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            (folder / 'app.zip').write_bytes(b'fixture')
            expected = release.asset_files(folder)
            complete = dict(tag_name='v0.11.1-dev.1', draft=True, prerelease=True,
                            assets=[dict(name='app.zip', digest='sha256:' + expected['app.zip'])])
            with patch.dict(os.environ, self.environment('next'), clear=True), patch.object(release, 'api', return_value=complete), \
                 patch.object(release, 'command') as command:
                release.publish_files('v0.11.1-dev.1', folder, folder / 'notes.md', True)
                self.assertEqual(command.call_args.args[:3], ('gh', 'release', 'edit'))
                self.assertIn('--latest=false', command.call_args.args)

    def test_build_refuses_to_regenerate_already_uploaded_signed_assets(self):
        with patch.object(release, 'load_plan', return_value=self.record()), \
             patch.object(release, 'api', return_value=dict(assets=[dict(name='original.zip')])), \
             patch.dict(os.environ, {}, clear=True), self.assertRaisesRegex(RuntimeError, 'do not rebuild'):
            release.build()

    def test_publication_cannot_proceed_after_an_extracted_app_verification_failure(self):
        for failure in ('wrong-channel', 'inventory', 'notarization'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                output = root / 'dist/prerelease'; output.mkdir(parents=True)
                (root / 'Config').mkdir()
                source = dict(format=1, kitSHA256='a' * 64, files={}, buildDate='fixture', composition='fixture')
                raw = json.dumps(source).encode()
                (root / 'Config/TryOmarchyRuntime.lock.json').write_bytes(raw)
                (output / 'SourceRuntime.lock.json').write_bytes(raw)
                source_sha = hashlib.sha256(raw).hexdigest()
                kit = output / 'TryOmarchySignedKit.zip'; kit.write_bytes(b'signed-runtime-fixture')
                lock = dict(source, sourceLockSHA256=source_sha, sourceKitSHA256=source['kitSHA256'],
                            kitSHA256=release.digest(kit), signingTeamID='ABC1234567', artifactTag='v0.11.1')
                signed_lock = json.dumps(lock).encode()
                (output / 'TryOmarchySignedRuntime.lock.json').write_bytes(signed_lock)
                (output / 'ReleaseSource.json').write_text(json.dumps(dict(applicationSourceCommit='a' * 40,
                    releaseTag='v0.11.1', appChannel='stable', sourceLockSHA256=source_sha, sourceKitSHA256=source['kitSHA256'])))
                archive = output / 'Omarchy-VM-Manager-v0.11.1-macOS-arm64-notarized.zip'
                archive.write_bytes(b'app-fixture')
                (output / (archive.name + '.sha256')).write_text(release.digest(archive) + '  ' + archive.name)
                def command(*args):
                    if args[0] == 'ditto':
                        contents = Path(args[-1]) / 'Omarchy VM Manager.app/Contents'
                        (contents / 'Resources').mkdir(parents=True)
                        info = dict(CFBundleShortVersionString='0.11.1', CFBundleVersion='100',
                            OmarchyReleaseTag='v0.11.1', CFBundleIdentifier='dev.omarchy.vm-manager',
                            CFBundleDisplayName='Omarchy VM Manager', OmarchyAppChannel='stable')
                        if failure == 'wrong-channel':
                            info['CFBundleIdentifier'] += '.dev'
                        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
                        (contents / 'Resources/TryOmarchyRuntime.lock.json').write_bytes(signed_lock)
                        return ''
                    if str(args[0]).endswith('/Scripts/verify-app.sh'):
                        self.assertEqual(args[1], '--bundle-only')
                        if failure == 'inventory':
                            raise RuntimeError('inventory verification failed')
                        return ''
                    if str(args[1]).endswith('/Scripts/verify_signed_app.py'):
                        raise RuntimeError('notarization verification failed')
                    self.fail('Unexpected publication command: ' + repr(args))
                with patch.object(release, 'ROOT', root), patch.object(release, 'load_plan', return_value=self.record()), \
                     patch.object(release, 'command', side_effect=command), patch.object(release, 'publish_files') as publish:
                    with self.assertRaises((RuntimeError, ValueError)):
                        release.publish()
                    publish.assert_not_called()


if __name__ == '__main__':
    unittest.main()
