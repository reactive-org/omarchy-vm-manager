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
    subprocess.run([str(args.binary), '--accept-setup-screens', str(output)], check=True, timeout=180)
    report = json.loads((output / 'report.json').read_text())
    assert report['schema'] == 1 and len(report['checks']) == 204
    assert len(set(report['checks'])) == len(report['checks'])
    for appearance in ('dark', 'light'):
        for case in ('bundled-direct-create-ready', 'all-draft-edits-have-no-backend-effects',
                     'create-freezes-exact-pressed-selections', 'manager-resources-factory-captured-before-await',
                     'duplicate-in-flight-create-refused', 'identical-retry-reuses-frozen-inputs-and-uuid',
                     'preparation-failure-shown-without-saving', 'local-create-captures-selected-folder',
                     'create-grants-no-execution-or-task-trust', 'saved-inputs-default-on-despite-legacy-off',
                     'custom-factory-keeps-account-defaults', 'create-forwards-saved-account-defaults',
                     'manual-choice-forwarded-without-changing-defaults', 'layout-pane-before-customise',
                     'layout-pane-starts-without-setup', 'layout-card-turns-setup-on', 'omarchy-default-keeps-setup-on'):
            assert f'{appearance}-{case}' in report['checks']
    for case in ('only-for-setup-guests', 'stopped-waits-for-explicit-launch', 'approval-routes-to-setup-review',
                 'hidden-after-success', 'unordered-history-not-guessed', 'terminal-waits-for-admitted-job',
                 'completion-observed-transition-only', 'old-success-not-announced',
                 'failure-names-recorded-category', 'failed-keeps-ended-terminal', 'restart-required-is-not-installing'):
        assert f'first-run-{case}' in report['checks']
    for case in ('armed-has-no-approve-step', 'refuses-wider-permissions', 'blocked-falls-back-to-review',
                 'submits-admin-only-consent', 'single-use', 'bound-to-first-session', 'needs-setup-and-ssh',
                 'restart-shown-as-progress', 'restarts-once', 'checks-once', 'never-recovers',
                 'follows-through-install-cleanup', 'check-waits-for-new-session-ssh'):
        assert f'auto-setup-{case}' in report['checks']
    for case in ('none-and-configured', 'running-shows-progress', 'manual-restart-needs-review', 'approved-restart-is-progress',
                 'cleanup-needs-recovery', 'failed-and-succeeded'):
        assert f'setup-card-{case}' in report['checks']
    for case in ('card-and-first-run-agree', 'timeout-names-the-step', 'sidebar-badge-only-for-waiting-guest',
                 'badge-opens-output-at-sudo-prompt', 'visible-guest-reported', 'notification-click-opens-review',
                 'stale-click-opens-home-only', 'blocked-guest-notifies-bounces-and-marks-dock', 'no-repeat-notifications',
                 'handled-clears-notification-and-marker', 'saved-review-no-notification-or-dock', 'on-screen-guest-not-notified'):
        assert f'attention-{case}' in report['checks']
    for case in ('release-offered-only-when-stopped', 'release-confirmation-says-unverified',
                 'stopped-card-explains-release', 'released-history-says-unverified'):
        assert f'cleanup-{case}' in report['checks']
    for case in ('setup-tab-shows-saved-log', 'setup-tab-saved-log-does-not-reattach-ended-job'):
        assert case in report['checks']
    assert report['runtimeStarts'] == 0 and report['visibleWindows'] == 0
    assert report['onscreenWindows'] == 0 and report['activation'] is False
    assert report['realExecution'] is False and report['physicalInputTested'] is False
    for appearance in ('dark', 'light'):
        for case in ('change-opens-on-saved-plan', 'stopped-guest-offers-start-and-set-up', 'product-surface-gate-disabled',
                     'disabled-prepare-never-delegates', 'edited-choices-still-gated'):
            assert f'{appearance}-{case}' in report['checks']
    # Change setup: one approval for the whole run, and a pending run is never stranded.
    for case in ('change-finished-offers-run-setup-again', 'apply-changes-label-tracks-diff', 'unchanged-choices-run-setup-again',
                 'apply-without-grants-refused', 'docker-consent-independent', 'custom-tasks-stop-for-separate-consent',
                 'uninspected-task-cannot-submit', 'complete-chunked-task-inspection', 'task-trust-independent',
                 'approval-sends-each-consent', 'approval-follows-its-own-run', 'submission-attempt-not-replayed',
                 'approval-covers-restart-and-check', 'pending-run-survives-reopen', 'pending-run-discard-unblocks',
                 'interrupted-after-restart-wording', 'start-and-set-up-binds-first-session',
                 'dont-set-up-stops-a-preparing-run', 'change-needs-ssh-explained',
                 'check-only-offered-after-restart', 'check-only-runs-no-apply'):
        assert case in report['checks']
    # One Change setup approval, one Start & set up approval and one
    # approve-at-creation automatic submission.
    assert report['gate'] == 'unchanged-disabled' and report['fakeSubmissions'] == 3
    assert len(report['images']) == 50
    for name in report['images']:
        assert pathlib.Path(name).name == name and name.endswith('.png')
        data = (output / name).read_bytes()
        assert data[:8] == b'\x89PNG\r\n\x1a\n'
        width, height = struct.unpack('>II', data[16:24])
        assert width >= 600 and height >= 760
    assert not (output / 'unused-support').exists()
    print(f'Setup screen acceptance: {len(report["checks"])} checks, 50 PNGs; no runtime starts or on-display windows.')
    print(f'Artifacts retained for inspection: {output}')


if __name__ == '__main__':
    main()
