#!/usr/bin/env python3
"""Developer-only private candidate signing: prepare, check, then interactive run.

Plan files describe inputs, never permission. No password, import, unlock,
notarization, publishing, host installs or VM operations are implemented here.
This wrapper has its own binding so adding it does not change engine digests of
an already-running reviewed attempt.
"""
import argparse
from dataclasses import asdict
import os
from pathlib import Path
import signal
import stat
import sys
import threading
import time

import private_provisioning_package as p
from private_provisioning_inputs import ReviewedSourceInputs, SourceInputAdmission
from private_provisioning_offline import OfflineReview, IMPLEMENTATION_FILES, implementation_digest
from private_provisioning_signer import Material
from receipt_bound_signing import SigningReview, SigningAuthorization, NativeTasks, CandidateVerifier, ReceiptBoundCaller
from bounded_signing_process import CommandFactory, SigningRunner, EFFECTS

VERSION = 1
SELECTION_KEYS = {'format', 'kind', 'sourceInputPacket', 'sourceReview', 'historicalOfflineReview', 'stagedMaterial'}
PLAN_KEYS = {'format', 'kind', 'selectionSHA256', 'implementation', 'signingReview', 'requestSHA256', 'effects'}
CREDENTIAL_SUFFIXES = ('.p12', '.p8', '.key', '.keychain', '.keychain-db')
DIAGNOSTICS = frozenset({
    'operator-path',
    'operator-vm-path',
    'operator-credential-content-forbidden',
    'operator-private-file-required',
    'operator-review-import',
    'operator-selection-schema',
    'operator-selector',
    'operator-selection-binding',
    'operator-historical-receipt',
    'operator-incomplete-inspection',
    'operator-historical-cleanup',
    'operator-public-input-changed',
    'operator-protected-output-overlap',
    'operator-plan-schema',
    'operator-implementation-changed',
    'operator-selection-changed',
    'operator-review-changed',
    'operator-existing-output',
    'operator-fixture-cannot-sign',
    'operator-plan-consumed',
    'operator-consent-required',
    'operator-plan-changed-after-consent',
    'operator-consumed-input-changed',
    'operator-result-contract',
    'operator-terminal-required',
    'operator-invalid-command',
    'operator-cancelled',
})


def _path(value):
    p.require(type(value) is str and 0 < len(value) <= 4096 and not any(ord(c) < 32 for c in value), 'operator-path')
    path = Path(value)
    p.require(path.is_absolute() and str(path) == value and '..' not in path.parts, 'operator-path')
    parts = tuple(s.casefold() for s in path.parts)
    p.require(not any(parts[i:i+2] == ('omarchy vm manager', 'vms') for i in range(len(parts)-1)), 'operator-vm-path')
    return path


def _read(path, maximum=2*1024*1024):
    p.require(not str(path).casefold().endswith(CREDENTIAL_SUFFIXES), 'operator-credential-content-forbidden')
    return p.read(path, maximum)


def _private_json(path):
    path = _path(str(path))
    info = path.lstat()
    p.require(stat.S_ISREG(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o600
              and info.st_uid == os.getuid(), 'operator-private-file-required')
    return p.decode(_read(path))


def implementation():
    folder = Path(__file__).resolve().parent
    return {'engineSHA256': implementation_digest(),
            'engineFiles': {n: p.digest(p.read(folder/n, 1024*1024)) for n in IMPLEMENTATION_FILES},
            'operatorFiles': {'private_signing.py': p.digest(p.read(Path(__file__).resolve(), 1024*1024))}}


def _selection(value):
    # Import historical review *data* only. Its approval/status/output fields are
    # deliberately excluded. Future prepares can reuse the emitted selection.json.
    if type(value) is dict and value.get('kind') == 'RECEIPT_BOUND_SIGNED_CANDIDATE_REVIEW':
        p.require(type(value.get('format')) is int and value['format'] == 1 and value.get('reviewOnly') is True,
                  'operator-review-import')
        value = {k: value[k] for k in SELECTION_KEYS - {'format', 'kind'}}
        value.update(format=VERSION, kind='PRIVATE_SIGNING_SELECTION')
    p.require(type(value) is dict and set(value) == SELECTION_KEYS and type(value['format']) is int
              and value['format'] == VERSION and value['kind'] == 'PRIVATE_SIGNING_SELECTION', 'operator-selection-schema')
    source = ReviewedSourceInputs(**value['sourceReview'])
    h = dict(value['historicalOfflineReview']); h['output'] = _path(h['output'])
    historical = OfflineReview(**h)
    m = {k: (v if k in ('team', 'identity') else _path(v)) for k, v in value['stagedMaterial'].items()}
    material = Material(**m)
    p.require(type(material.team) is str and type(material.identity) is str
              and material.team == source.signingTeamID and material.identity.startswith('Developer ID Application: ')
              and material.identity.endswith('(' + material.team + ')')
              and not any(ord(c) < 32 for c in material.identity), 'operator-selector')
    packet = _path(value['sourceInputPacket'])
    p.require(material.signed_runtime == packet/'runtime' and material.profile == historical.output/'manager.provisionprofile'
              and historical.sourceRequestSHA256 == source.request_digest(), 'operator-selection-binding')
    return value, source, historical, material, packet


def _public_check(selection):
    value, source, historical, material, packet = _selection(selection)
    request = SourceInputAdmission.open(packet, source).revalidate()
    receipt_path = historical.output/'offline-inspection.json'
    certificate = historical.output/'public-certificate.der'
    receipt_raw = _read(receipt_path); receipt = p.decode(receipt_raw)
    p.require(receipt['status'] == ('FAKE_OFFLINE_INSPECTION_ONLY' if source.fixture else 'OFFLINE_STATIC_INSPECTION_ONLY')
              and receipt['nativeValidationObserved'] is (not source.fixture)
              and receipt['requestSHA256'] == historical.request_digest()
              and receipt['implementationSHA256'] == historical.implementationSHA256
              and receipt['sourceRequestSHA256'] == source.request_digest()
              and receipt['scopeSHA256'] == source.scopeSHA256
              and receipt['stagedMaterialSHA256'] == material.binding()
              and receipt['selectionSHA256'] == historical.selectionSHA256
              and receipt['profileSHA256'] == request['profileSHA256']
              and receipt['publicCertificateSHA256'] == historical.publicCertificateSHA256
              and receipt['cleanupConfirmed'] is True and receipt['unresolvedHandles'] == 0
              and receipt['signingAuthorized'] is False and receipt['guestRunAuthorized'] is False
              and receipt['publication'] == 'forbidden', 'operator-historical-receipt')
    p.require(receipt['keychainLocked'] is True and receipt['daemonCheck'] == 'NOT_RUN'
              and type(receipt['staticCodeChecks']) is int and receipt['staticCodeChecks'] > 0
              and type(receipt['workerEvidence']) is list
              and len(receipt['workerEvidence']) == receipt['staticCodeChecks'] + 8, 'operator-incomplete-inspection')
    for row in receipt['workerEvidence']:
        handle = row['handle']
        p.require(row['status'] == 'COMPLETED' and type(row['exitStatus']) is int and row['exitStatus'] == 0
                  and row['diagnostic'] is None and row['cleanupConfirmed'] is True
                  and handle['rootReaped'] is True and handle['groupQuietBeforeReap'] is True
                  and handle['descriptorsClosed'] is True, 'operator-historical-cleanup')
    p.require(p.digest(_read(material.profile)) == request['profileSHA256']
              and p.digest(_read(certificate)) == historical.publicCertificateSHA256, 'operator-public-input-changed')
    # The engine repeats full receipt/worker/code/material admission after consent.
    # This check never stats/opens the selected keychain, calls native APIs or Git.
    return source, historical, material, packet, receipt_path, certificate, p.digest(receipt_raw)


def _disjoint(plan, selection):
    _, _, historical, material, packet = _selection(selection)
    for protected in (packet, historical.output, material.upstream, material.parser_checkout, material.keychain.parent):
        p.require(plan != protected and plan not in protected.parents and protected not in plan.parents,
                  'operator-protected-output-overlap')


def _fields(review):
    value = asdict(review)
    for name in ('receipt', 'publicCertificate', 'output'): value[name] = str(value[name])
    return value


def prepare(selection_file, plan):
    p.private_context()
    selection, *_ = _selection(_private_json(selection_file))
    source, historical, material, packet, receipt, cert, receipt_sha = _public_check(selection)
    plan = _path(str(plan)); _disjoint(plan, selection)
    review = SigningReview(source.request_digest(), source.scopeSHA256, historical.request_digest(),
        historical.implementationSHA256, receipt_sha, material.binding(), historical.publicCertificateSHA256,
        implementation_digest(), receipt, cert, plan/'candidate', source.fixture)
    record = {'format': VERSION, 'kind': 'PRIVATE_SIGNING_OPERATOR_PLAN',
              'selectionSHA256': p.digest(p.canonical(selection)), 'implementation': implementation(),
              'signingReview': _fields(review), 'requestSHA256': review.request_digest(), 'effects': sorted(EFFECTS)}
    p.new_directory(plan, packet)
    # Private plans may live beneath an ignored repo directory. Also fence normal
    # accidental git-add of every plan/candidate file, including this ignore file.
    p.write(plan/'.gitignore', b'*\n')
    p.write_json(plan/'selection.json', selection)
    p.write_json(plan/'plan.json', record)
    p.write(plan/'README.txt', b'PRIVATE SIGNING PLAN DATA ONLY. No execution permission is saved here.\n'
        b'Review selection.json and plan.json for exact identity, paths, source and disposable scope.\n'
        b'check is public-input validation, not native readiness or key availability.\n'
        b'run requires a real controlling terminal and fresh exact-plan confirmation.\n'
        b'No unlock/import, automatic retry, notarization, install or VM action.\n')
    return check(plan)


def check(plan):
    p.private_context(); plan = p.private_directory(_path(str(plan)))
    record = _private_json(plan/'plan.json')
    p.require(type(record) is dict and set(record) == PLAN_KEYS and type(record['format']) is int
              and record['format'] == VERSION and record['kind'] == 'PRIVATE_SIGNING_OPERATOR_PLAN'
              and record['effects'] == sorted(EFFECTS), 'operator-plan-schema')
    p.require(record['implementation'] == implementation(), 'operator-implementation-changed')
    selection = _private_json(plan/'selection.json')
    p.require(p.digest(p.canonical(selection)) == record['selectionSHA256'], 'operator-selection-changed')
    source, historical, material, packet, receipt, cert, receipt_sha = _public_check(selection)
    _disjoint(plan, selection)
    fields = dict(record['signingReview'])
    for name in ('receipt', 'publicCertificate', 'output'): fields[name] = _path(fields[name])
    review = SigningReview(**fields)
    expected = SigningReview(source.request_digest(), source.scopeSHA256, historical.request_digest(),
        historical.implementationSHA256, receipt_sha, material.binding(), historical.publicCertificateSHA256,
        implementation_digest(), receipt, cert, plan/'candidate', source.fixture)
    p.require(review == expected and record['requestSHA256'] == review.request_digest(), 'operator-review-changed')
    consumed = os.path.lexists(plan/'consumed.json')
    p.require(consumed or not os.path.lexists(review.output), 'operator-existing-output')
    return {'format': VERSION, 'status': 'CONSUMED_NO_RETRY' if consumed else 'CHECKED_PUBLIC_INPUTS_ONLY',
            'planSHA256': p.digest(p.canonical(record)), 'requestSHA256': review.request_digest(),
            'sourceCommit': source.sourceCommit, 'scopeSHA256': source.scopeSHA256,
            'fixture': source.fixture, 'executionAuthorized': False, 'keyAvailability': 'NOT_QUERIED',
            'nativeReadiness': 'NOT_CHECKED', 'automaticRetry': False}


class NativeBackend:
    """Constructed only after fresh terminal consent and durable consumption."""
    def __init__(self, source, historical, material, review, authorization):
        p.require(review.fixture is False, 'operator-fixture-cannot-sign')
        self.factory = CommandFactory(review, material)
        self.runner = SigningRunner(review, material, self.factory, authorization)
        self.tasks = NativeTasks(review, historical)
        self.caller = ReceiptBoundCaller(source, historical, material, review, self.runner, CandidateVerifier(self.tasks))

    def run(self, packet, cancel): return self.caller.run(packet, cancel=cancel)

    def evidence(self):
        native = self.tasks.factory
        return {'commandEvidence': self.runner.worker_records, 'nativeEvidence': self.tasks.records,
                'commandFactoryCleanup': self.factory.cleanup_records,
                'nativeFactoryCleanup': native.cleanup_records if native else [],
                'commandCleanupConfirmed': self.runner.cleanup_confirmed,
                'nativeCleanupConfirmed': self.tasks.cleanup_ok() if native else True,
                'unresolvedHandles': len(self.factory.pending_cleanup) + len(native.pending_cleanup if native else [])}

    def retain(self):
        # Never discard original unresolved handles by returning to a short-lived
        # CLI. Ctrl-C/TERM request cancellation, not an unsafe parent exit.
        while self.factory.pending_cleanup or (self.tasks.factory and self.tasks.factory.pending_cleanup):
            time.sleep(1)


def execute(plan, confirm, *, backend=NativeBackend, cancel=None):
    summary = check(plan)
    p.require(summary['status'] == 'CHECKED_PUBLIC_INPUTS_ONLY', 'operator-plan-consumed')
    p.require(summary['fixture'] is False or backend is not NativeBackend, 'operator-fixture-cannot-sign')
    p.require(confirm(summary) is True, 'operator-consent-required')
    fresh = check(plan)
    p.require(fresh == summary, 'operator-plan-changed-after-consent')
    p.require(not cancel or not cancel(), 'operator-cancelled')
    plan = Path(plan)
    # O_EXCL/fsync fences concurrent CLI processes and all failures, even before
    # a worker starts. No saved grant or secret is created.
    p.write_json(plan/'consumed.json', {'format': VERSION, 'status': 'CONSUMED_NO_RETRY',
        'planSHA256': summary['planSHA256'], 'requestSHA256': summary['requestSHA256'], 'automaticRetry': False})
    instance = None; result = None; status = 'STOPPED_NO_RETRY'
    try:
        selection = _private_json(plan/'selection.json')
        _, source, historical, material, packet = _selection(selection)
        fields = dict(_private_json(plan/'plan.json')['signingReview'])
        for name in ('receipt', 'publicCertificate', 'output'): fields[name] = Path(fields[name])
        review = SigningReview(**fields)
        p.require(review.request_digest() == summary['requestSHA256'] and implementation() == _private_json(plan/'plan.json')['implementation'],
                  'operator-consumed-input-changed')
        auth = SigningAuthorization(review.request_digest(), EFFECTS)
        instance = backend(source, historical, material, review, auth)
        result = instance.run(packet, cancel)
        p.require(result['status'] == ('FAKE_RECEIPT_BOUND_SIGNER_ONLY' if review.fixture else 'SIGNED_OFFLINE_STATIC_CHECKS_ONLY')
                  and result['cleanupConfirmed'] is True and result['guestRunAuthorized'] is False, 'operator-result-contract')
        status = result['status']
        return result
    finally:
        try:
            evidence = instance.evidence() if instance else {'unresolvedHandles': 0, 'backendConstructed': False}
            if evidence.get('unresolvedHandles'):
                print('STOP: original unresolved handles retained; no retry or process adoption.', file=sys.stderr)
            p.write_json(plan/'attempt.json', {'format': VERSION, 'status': status,
                'planSHA256': summary['planSHA256'], 'requestSHA256': summary['requestSHA256'],
                'evidence': evidence, 'automaticRetry': False, 'publication': 'forbidden', 'guestRunAuthorized': False})
        finally:
            if instance is not None: instance.retain()


def terminal_confirmation(summary):
    # /dev/tty prevents piped stdin, env, JSON fields or --yes from supplying a
    # grant. The exact outer plan digest binds both engine and wrapper bytes.
    p.require(sys.stdin.isatty() and sys.stdout.isatty(), 'operator-terminal-required')
    with open('/dev/tty', 'r', encoding='utf-8') as reader, open('/dev/tty', 'w', encoding='utf-8') as terminal:
        terminal.write('Review the private plan.json and selection.json before proceeding.\n'
            'This run permits local build and offline inspection, SELECTED PRIVATE-KEY USE,\n'
            'existing macOS secure key UI and APPLE SECURE TIMESTAMP REQUESTS.\n'
            'No automatic unlock/import, notarization, SSH/Ansible, installs or VM actions.\n'
            'Key availability and Touch ID support are not established by check.\n'
            'Plan: ' + summary['planSHA256'] + '\n'
            'Source commit: ' + summary['sourceCommit'] + '\n'
            'Disposable scope: ' + summary['scopeSHA256'] + '\n'
            'Type SIGN ' + summary['planSHA256'] + ' to run once: ')
        terminal.flush()
        answer = reader.readline(128)
        return answer == 'SIGN ' + summary['planSHA256'] + '\n'


class Parser(argparse.ArgumentParser):
    def error(self, message): raise p.Refused('operator-invalid-command')


def main(argv=None):
    parser = Parser(description=__doc__)
    commands = parser.add_subparsers(dest='operation', required=True, parser_class=Parser)
    prep = commands.add_parser('prepare', help='Create new private plan; public files only')
    prep.add_argument('--selection', required=True, type=Path, help='Private selection.json or previous review.json (data only)')
    prep.add_argument('--plan', required=True, type=Path, help='New directory beneath an existing mode-0700 parent')
    for name in ('check', 'run'):
        command = commands.add_parser(name)
        command.add_argument('--plan', required=True, type=Path)
    previous = {}; cancelled = threading.Event()
    try:
        args = parser.parse_args(argv)
        if args.operation == 'prepare': result = prepare(args.selection, args.plan)
        elif args.operation == 'check': result = check(args.plan)
        else:
            def confirm(summary):
                if not terminal_confirmation(summary): return False
                for sig in (signal.SIGINT, signal.SIGTERM):
                    previous[sig] = signal.signal(sig, lambda *_: cancelled.set())
                return True
            result = execute(args.plan, confirm, cancel=cancelled.is_set)
        # Never echo selectors, paths, certificates, child output or exception text.
        print(p.canonical({k: result[k] for k in ('status', 'planSHA256', 'requestSHA256', 'sourceCommit', 'scopeSHA256', 'fixture', 'executionAuthorized', 'keyAvailability', 'nativeReadiness') if k in result}).decode())
        return 0
    except (Exception, KeyboardInterrupt) as error:
        code = str(error) if isinstance(error, p.Refused) and str(error) in DIAGNOSTICS else (
            'operator-existing-private-path' if isinstance(error, FileExistsError) else
            'operator-cancelled' if isinstance(error, KeyboardInterrupt) else 'operator-stopped')
        print('Private signing stopped (' + code + '); private inputs/output preserved. No automatic retry.', file=sys.stderr)
        return 1
    finally:
        for sig, handler in previous.items(): signal.signal(sig, handler)


if __name__ == '__main__': raise SystemExit(main())
