"""Isolated guest reporter driven by host storage tests; no VM or system actions."""
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import sys
from types import SimpleNamespace
from unittest.mock import patch
from contextlib import ExitStack
import uuid

mode, root, source = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
program = source / 'guest/package/try-omarchy/files/usr/lib/try-omarchy/managed-owner-setup'
loader = importlib.machinery.SourceFileLoader('isolated_owner_report', str(program))
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
guest = root / '.isolated-report-fixture'
run = guest / 'run'; identity = guest / 'identity'; provisioning = guest / 'provisioning'
for directory in (run, identity, provisioning): directory.mkdir(mode=0o700, parents=True, exist_ok=True)
share = root / '.manager-setup/bootstrap'
resources = source / 'guest/package/try-omarchy/files/usr/share/try-omarchy'
contracts = {m.OFFICIAL: (resources / 'owner-setup-contract.json', 'official'), m.LEAN: (resources / 'lean-owner-setup-contract.json', 'lean-e4fffc6')}
with ExitStack() as stack:
    for name, value in dict(RUN=run, IDENTITY=identity/'identity.json', PENDING=provisioning/'pending', SHARE=share, CMDLINE=guest/'cmdline', BOOT_ID=guest/'boot-id', CONTRACTS=contracts).items(): stack.enter_context(patch.object(m, name, value))
    stack.enter_context(patch.object(m, 'directory', side_effect=lambda path: path.mkdir(mode=0o700, parents=True, exist_ok=True)))
    stack.enter_context(patch.object(m, 'mount_share'))
    stack.enter_context(patch.object(m, 'reviewed_bytes', side_effect=lambda path, **kwargs: Path(path).read_bytes()))
    stack.enter_context(patch.object(m.pwd, 'getpwnam', return_value=SimpleNamespace(pw_uid=1000)))
    if mode == 'complete':
        manifest = json.loads((share/'manifest.json').read_bytes())
        m.CMDLINE.write_text('tryomarchy.managed_setup=1 tryomarchy.managed_setup_report=' + m.binding_digest(m.report_binding(manifest)))
        m.BOOT_ID.write_text(str(uuid.uuid4()))
        m.PENDING.touch(); m.commit_identity(); m.PENDING.unlink()
    elif mode != 'report': raise ValueError('fixture mode')
    m.acknowledge()
    sys.stdout.buffer.write((run/'status.json').read_bytes())
