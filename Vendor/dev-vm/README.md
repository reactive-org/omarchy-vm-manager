# Omarchy developer workstation

[![CI](https://github.com/reactive-org/dev-vm/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/reactive-org/dev-vm/actions/workflows/ci.yml)

Get a ready-to-code ARM64 workstation on your Apple Silicon Mac with
[Omarchy VM Manager](https://github.com/reactive-org/omarchy-vm-manager).

## Prerequisites

Use an **Apple Silicon Mac** with the following host tools already available.
Install missing host tools separately; this repository does not install them.

| Dependency | When required |
| --- | --- |
| Git | Cloning this repository; also required for advanced image builds using an explicit source checkout. Default image builds use bundled guest sources. |
| Python 3.10+ (`python3`) and make | Running the repository's bootstrap, image-build, feature and validation targets. CI uses Python 3.14. |
| macOS Bash and OpenSSH (`ssh`, `scp`, `sftp`) | Shell scripts and guest access through VM Manager's managed SSH connection. |
| Omarchy VM Manager app and CLI | Creating, configuring and checking VMs from either factory. Save **Guest Defaults** in the app first. The CLI is discovered on `PATH`, then in `~/Applications` or `/Applications`. Lean image import also reads the installed app’s compatibility metadata. See [manager setup and CLI paths](docs/omarchy-bootstrap.md). |
| Docker CLI and a running ARM64 Linux engine | `make build-omarchy-image` and `make check-omarchy-image`. Full image builds require privileged containers. The official factory and image previews (`OMARCHY_IMAGE_PLAN=yes`) do not require host Docker. |
| Ansible (`ansible-playbook`, `ansible-inventory`) | Optional feature playbooks, external setup application/bootstrap, `make syntax-check` and the complete `make test-omarchy` suite. CI pins `ansible-core` 2.21.5. Standard bootstrap does not require Ansible. |
| PyYAML | Reading YAML setup, catalogue or variables files. The loader can reuse the existing Ansible Python runtime; JSON files do not need PyYAML. |
| Python 3.11+ | Developer-profile compact prompts or custom `starship_config` TOML; validation uses the standard-library TOML parser. |
| Authenticated GitHub CLI (`gh`) or `GH_TOKEN`/`GITHUB_TOKEN` | Optional theme selection by GitHub stars. See [theme selection](docs/omarchy-themes.md). |

Guest applications, Docker, mise and language runtimes are managed inside the VM
through Omarchy and the selected [features](docs/omarchy-features.md).
See [image build requirements](docs/omarchy-image.md) for disk-space allowances
and [repository checks](docs/development.md) for validation details.

## Quick start

For the in-progress shared Swift controller, see [Swift provisioning foundation](#swift-provisioning-foundation).
The commands below still use the existing Python controller.

Open the existing manager app and save **Guest Defaults**. Run from this
repository's root with an unused VM name.

**Official Try Omarchy:** Get running quickly with Omarchy’s standard apps already installed and no image build required.

```bash
make bootstrap-omarchy-vm VM_NAME="Dev Omarchy" OMARCHY_VM_FACTORY=official
```

**Lean, mean coding image:** Standard ARM64 Omarchy with a smaller app selection,
Git, Python and build tools, prepared for QEMU on your Mac using Try Omarchy’s
factory approach and Omarchy VM Manager’s native integration
([image details](docs/omarchy-image.md)).

```bash
make build-omarchy-image
make bootstrap-omarchy-vm VM_NAME="Dev Omarchy" \
  OMARCHY_VM_FACTORY=.artifacts/omarchy-image/latest
```

Bootstrap prepares/imports the image through VM Manager, creates the VM, then
updates it, applies preferences, restarts and checks it. Review the proposal
and confirm Omarchy's prompt, then enter the guest sudo password once near the
start. Bootstrap keeps sudo passwordless during setup and restores default sudo
authentication before restarting. Apps and layouts are selected during bootstrap.
An existing [custom image or factory bundle path](docs/omarchy-bootstrap.md#choose-a-starting-image)
works too; no manual import or manifest hash is needed.

## Pick your setup

Every runbook shows both image choices with copy-and-paste commands.

- [Standard workstation](docs/omarchy-vm-manager-runbook.md)
- [Trim optional desktop apps](docs/omarchy-official-trimmed-runbook.md)
- [Four tiled Foot terminals](docs/omarchy-layout-four-terminals.md)
- [Terminal left 40%, browser right 60%](docs/omarchy-layout-terminal-browser.md)
- [VS Code left 60%, browser right 40%](docs/omarchy-layout-vscode-browser.md)
- [Claude, two terminals and a floating browser](docs/omarchy-layout-claude-two-terminals-browser.md)

Next: [add developer tools](docs/omarchy-features.md) or [choose a theme](docs/omarchy-themes.md).

Keep a complete setup in a separate repository with
[external setup repositories](docs/omarchy-setup-repositories.md): VM resources,
features, layouts, dotfiles and explicitly trusted custom Ansible tasks. Start
from the [standalone example](omarchy/examples/setup-repo/README.md):

```bash
make plan-omarchy-setup OMARCHY_SETUP_REPO="$HOME/my-workstation"
make bootstrap-omarchy-vm VM_NAME="Dev Omarchy" \
  OMARCHY_SETUP_REPO="$HOME/my-workstation" OMARCHY_SETUP_TRUST_TASKS=yes
```

If projects own their tools through `mise.toml`, choose the
[`project-managed` profile](docs/omarchy-features.md#let-projects-manage-their-toolchains)
for the workstation, mise and native build prerequisites without selecting
global runtimes. Feature playbooks default to zsh with optional Oh My Zsh and
Starship enabled; select `bash`
or `keep` through the [workstation shell setting](docs/omarchy-features.md#login-shell).

## Swift provisioning foundation

The root SwiftPM package targets Swift 6 and macOS 15+. It exports
`DevVMProvisioningCore` and the migration-stage `dev-vm` executable. The package now provides
strict manifests, feature/profile resolution, immutable source snapshots and
offline proposals. A concrete SSH/Ansible command adapter is available behind an
injected process runner. An opt-in local runner and PTY backend now have
disposable-fixture coverage; no operational Swift setup or VM backend is enabled.
The transport continuations below describe the implemented boundaries. The legacy Python commands
above remain the operational entry points until an explicit cutover.

```sh
make build-provisioning test-provisioning
swift run --skip-build dev-vm validate-manifest omarchy/examples/setup-repo/vm.yml
swift run --skip-build dev-vm plan omarchy/examples/setup-repo
make test-provisioning-oracle  # development-only, requires existing Python/PyYAML
```

`validate-manifest` accepts one explicit `.json`, `.yml` or `.yaml` file and
returns a JSON count summary with `structure_valid: true`, `resolved: false`
and `execution_available: false`. Invalid input exits 1; invalid commands exit 2.
Diagnostics use fixed codes and optional numeric locations, never source text,
paths or variable values. Source assets, dotfiles and custom task entry points
are declarations: they are not opened, captured or executed. No host dependency
checks occur. The compiled CLI/parser works with Python and Ansible absent from
`PATH`; the Swift toolchain is needed only to build it.

The data readers enforce UTF-8, 256 KiB input, at most 30 container levels,
string-only unique keys, finite numbers and no template markers. YAML aliases,
anchors, explicit tags, version/tag directives and merge keys are rejected before composing
a tree. JSON uses a bounded grammar and Foundation string decoding; malformed
JSON never falls back to YAML. File reads reject leaf symlinks, directories,
FIFOs, oversized inputs and detectable changes during the read. This is not a
repository snapshot or protection against later path/asset replacement.

The YAML event parser is compiled from the unmodified parser subset of Yams
6.2.2's CYaml/LibYAML at `a27b21e0c81c5bf42049b897a62aaf387e80f279`, behind a
small C event bridge and Swift validation. It needs no host YAML library. See
[the SHA-256 inventory](ThirdParty/ParserInventory.json) and the bundled
[Yams](Sources/DevVMProvisioningCore/Resources/Yams-LICENSE.txt) and
[LibYAML](Sources/DevVMProvisioningCore/Resources/LibYAML-LICENSE.txt) MIT notices.
Selection schema/catalogue resources are copied from this repository's
`ed36bbec92943c10f9a0b1b2d4887a4f4a190bff` baseline; tests require exact hashes
and equality with their maintained originals. Changes require reviewed inventory
and fixture updates. SwiftPM supplies the resource bundle through the library.
Only catalogue/schema resources are packaged in this slice; playbooks, roles,
presets and guest helpers remain in their existing locations for the later port.

Manifest validation covers schema version, IDs, VM field types/ranges,
selection fields/options against the bundled schema, known builtin references,
duplicate aliases, relative source declarations, reserved/overlapping dotfile
targets, quoted modes and unique task names. `validate-manifest` checks namespaced references lexically; `plan` resolves
the explicitly declared catalogues. `SetupManifest` remains a structure-only
value, and a `SetupPlan` remains an offline proposal without execution approval.

Compatibility changes are deliberate and limited: signed 64-bit integers;
decimal finite floating point (including exponent notation); YAML 1.1 boolean
spellings retained; unquoted timestamps and legacy octal/hex/binary,
underscored or sexagesimal numbers rejected. Quote such values when they are
intended as strings. Unlike PyYAML, numeric exponent notation in YAML mappings
is consistently numeric. DEL characters in bounded names/paths, any `.git`
path segment and canonically equivalent duplicate Unicode keys are also refused.
Bare and `pkg:` selectors for the same package are treated as duplicate
declarations. These are not claims of complete Python-controller parity.

**VERIFIED — original foundation `e86550e`, 2 November 2026:** build and 12 Swift test
functions pass, including 94 parameterized cases and 18 shared plain-data
fixtures. The unchanged Python loader agrees on all 18 oracle fixtures with
subprocess fallback disabled. The Swift tests and CLI also pass with
`PATH=/nonexistent` (test runner invoked by absolute toolchain path). Existing
`make test-omarchy` passes 235 tests with one Lua fixture skipped because Lua is absent, using the
already-installed Homebrew Python and local socket access. The initial system
Python 3.9 run lacked `tomllib`; the restricted run could not start Ansible's
local RPC server. Neither required an installation or a code workaround.
`make syntax-check` passes both unchanged playbooks, with expected empty-host
inventory warnings. No real guest or VM operation was performed.

**TO PROVE at the foundation commit:** complete controller/selection/TOML parity,
planning and snapshots, full resources, immutable manager dependency pin, app/helper integration,
read-only app relocation, transport/authorization, the live terminal and all
real-guest behavior. The manager's execution gates remain disabled.

## Offline planning continuation

`FeaturePlanner.resolve` implements builtin/extension feature prerequisites,
profile inheritance, sibling conflicts, explicit overrides, empty-map/list
clearing, null tool tombstones, provider conflicts and exact effective options.
Catalogue declaration order is preserved by both JSON and YAML readers. All
feature and profile graphs are checked, including unselected definitions.
Limits are 32 catalogues, 512 features/profiles and 30 graph levels.

Selected Starship TOML uses Swift-native TOMLDecoder 0.4.5 at
`a2bbd2796fe3064e107de18cb56031052c4fa899`, pinned in `Package.swift` and
`Package.resolved`, with its MIT notice bundled. The parser supports TOML 1.1;
a compatibility preflight rejects its new escapes, optional time seconds,
multiline inline tables and inline-table trailing commas to retain the Python
oracle's TOML 1.0 contract. Text is bounded to 64 KiB and bracket/key depth to
30. Invalid unselected profile prompt text may be repaired by an override;
selected, enabled zsh/Starship configuration must validate. No external TOML
parser, Python or Ansible is invoked by the library or CLI.

`SetupPlanner.plan` captures explicit manifest/catalogue/layout/dotfile/task/asset
inputs below a selected repository descriptor. Traversal uses `openat` with
no-follow flags, refuses symlinks, `.git`, nonregular files and unsafe paths,
and detects changes during reading. The immutable in-memory `SourceSnapshot`
retains bytes and permissions, expands dotfile trees, includes empty-directory
membership and never captures unrelated files. Limits are 4,096 files, 32 MiB
total, 4,096 directories, 8,192 entries per directory and 64 path levels.
`plan.verify(in:)` rewalks the declarations to detect additions, removals,
content/mode changes, root replacement and engine/resource changes. Frozen bytes
remain available when their originals change. This is a reviewed byte snapshot;
it does not claim a filesystem transaction against an adversarial concurrent
writer. Private job-directory materialization belongs to the execution port.

The versioned JSON proposal includes effective configuration, package/mise
requirements and provenance, predicted effects, expanded dotfiles, opaque task
metadata, selected input hashes, an engine inventory and deterministic input/plan
digests. It records required application tools, task trust, expected Docker
restart policy, update ownership and pending guest conflict/factory checks.
Variable values and opaque file/task contents are excluded from serialized plans.
`execution_available` stays false. Factory references remain declarations for
manager admission; local paths are neither opened nor converted into admitted
factory images. Guest state, installed versions, actual additions/removals and
existing dotfile conflicts cannot be determined offline.

`make` regenerates the checked-in engine inventory from Swift/C sources, package
pins and bundled resources before building/testing. This uses the existing
Python development tool only; the compiled library/CLI does not use Python.
Direct SwiftPM builders must run `make provisioning-inventory` after source
changes. Tests reject stale inventories. This inventory binds build inputs; final
signed app/helper provenance and immutable manager packaging remain pending.

```sh
make build-provisioning test-provisioning test-provisioning-oracle
make test-provisioning-planning-oracle ORACLE_PYTHON=/path/to/existing/python
```

The full planning oracle needs an existing Python 3.11+ with PyYAML. It compares
all legacy proposal fields except the intentionally different engine identity,
normalizing only the bundled catalogue's path to `builtin/catalogue.json`.
It forbids Python subprocesses, manager calls and interpreter fallback. Swift
children run with `PATH=/nonexistent`. No host dependency is installed or probed.
The Python operational controllers remain unchanged.

**VERIFIED — continuation, 2 November 2026:** build, 20 Swift test functions,
18 plain-data fixtures and 66 complete proposal/error cases (41 accepted, 25
rejected) pass. Snapshot tests cover limits, edits/additions/removals/modes,
empty directories, symlink/special-file rejection, root replacement, opaque
inputs, engine hashes and equal plan digests across equivalent roots. Existing
`make test-omarchy` passes 235 tests with the existing Lua fixture skipped, and
both playbooks pass syntax checks. The complete oracle used the existing
Ansible-managed Python 3.14 as a development test interpreter only. All 20
Swift tests also pass with `PATH=/nonexistent` using the absolute toolchain
runner. An isolated CLI/bundle copy plans successfully; altering its bundled
catalogue produces only `manifest.resource` and exit 1. This is not full app
relocation acceptance. No tools were installed, guest contacted, VM launched
or app opened.

**TO PROVE:** complete TOML/parser parity outside this fixture matrix, frozen
job materialization, full resource distribution, manager dependency/helper/UI
integration, signed provenance and relocation, operational standalone cutover,
transport/authorization, live terminal and all real-guest behavior. Existing
manager execution gates remain disabled. Concrete transports and production execution remain deferred.

## Transport and authorization sequencing (fake adapters only)

**Historical boundary at `f807104`:** `ProvisioningGuestAdapter` was a typed
async port implemented only by the in-memory `FakeGuest` in tests. Concrete
command construction and payload materialization are added in the continuation
below. The later local-runner section adds pipe/PTY execution; guest discovery,
operational integration and lifecycle control remain deferred.
`ProvisioningSequencer` is a single-use actor for reviewed apply/check attempts
and cleanup-only recovery. The CLI still exposes offline validation/planning
only, and proposals still report `execution_available: false`.

A request binds a frozen plan and current source/engine identity, job ID, exact
VM/runtime-session ID, non-root owner name/UID, pinned host-key digest,
dependency digest, mode, task subset/check policy, dotfile conflict policy and
interactive input lease into a review digest. Approval separately acknowledges
custom task code, the persistent setup grant and Docker's root-equivalent opt-in.
Absent/stale approval, untrusted selected tasks or missing required input stop
before any adapter call. Check mode skips tasks unless explicitly requested and
trusted; it never resets/enables/revokes grants, clears sudo authentication,
installs manifest packages, changes Docker access or requests restart. Check mode
is not a sandbox for trusted custom tasks.

Every operation is preceded by an identity check; every reply must match command,
job, VM/session/owner/UID/host-key/dependency pins, protocol version and expected
structured proof. Future adapters must perform actual authentication and enforce
these pins at operation time. The current fake replies establish sequencing only,
not cryptographic identity or a working guest command. A mismatch stops all
further actions on that channel. No endpoint discovery or silent rebinding occurs.

Apply sequencing is: stage frozen inputs; reset any stale native grant and clear
cached authentication; request the native persistent grant interactively; verify
active policy without cached authentication; apply selected packages/features;
request any explicit native Docker consent; apply repository work; quiesce owned
work; revoke, clear cached authentication and verify inactive policy; check Docker
owner access again after revocation; quiesce that check and remove the job-owned
payload. Interactive commands receive an input lease ID, never passwords or
keystrokes. Docker success returns `appliedRestartRequired`; no restart is run.

**PRIVATE COUPLING:** `NativeAuthorizationContract` version 1 describes fixed
`bash -lc` guest argv from `scripts/omarchy_vm_manager.py` and
`scripts/omarchy_playbook.py` at `56dba82`. It includes native grant enable/reset,
cache clearing, compound revocation verification, native Docker confirmation
with `OMARCHY_DEFER_REBOOT=1` and local-socket Docker checks. It interpolates no
user values and accepts no nonterminal secret input. This code constructs argv
only; tests never execute these scripts. Native CLI meanings are private guest
couplings, not public Try Omarchy kit capabilities.

Cleanup coverage is armed before staging or grant/reset attempts, since failure
or a lost acknowledgement can leave side effects. Cancellation interrupts only
the exact active command and retains it until its async call ends; cleanup uses
an independent cancellation scope with no prompts, fresh grant or source-file
dependency. A local command ending does not prove remote work stopped: a separate
job-scoped quiescence proof is mandatory. Payload removal is withheld while work
is uncertain. An inactive-policy observation while work still runs does not
clear grant risk. A later compound inactive/cache-cleared proof can reconcile a
lost revoke/cache-clear reply once work is stopped.

Results preserve primary failure separately from cleanup failures. Unresolved
work/grant/payload state returns `cleanupRequired` and an opaque in-memory ticket
bound to the original target, dependency pin and job-owned payload ID. A fresh
driver may recover only that context, without input, grant, apply/check work or
restart—even if the original source repository has changed or disappeared.
Recovery refuses changed guests/sessions or dependencies. It reports cleanup
confirmation, never successful setup. Cross-restart rebinding and private
persistent recovery journals remain manager work.

Schema-1 result/event records contain fixed codes and command/job/VM/session IDs,
with correlated started/completed/failed events. They exclude owner/key material,
paths, frozen data, terminal input/output and arbitrary adapter diagnostics.
Bindings, requests, commands and recovery tickets have redacted descriptions.
Attempt completion is never a VM `.exited` boundary; consumers must retain VM
clients/reservations under the manager's existing lifecycle rules.

Commands carry adapter deadlines: identity checks 10 seconds; grant/cache probes
and cleanup 30 seconds; interactive commands 120 seconds; setup operations 3,600
seconds. Actual deadline enforcement/local-process exit belongs to a concrete
transport. Fake timeout replies test state transitions; they do not prove hard
wall-clock bounds, uncooperative-adapter termination or descendant cleanup.

**VERIFIED — fake-adapter slice, 2 November 2026:** build and all 38 Swift test
functions pass (18 added for sequencing/native contracts), including partial
staging/grants, body failures, cancellation during authorization/cleanup,
concurrent/replayed driver rejection, stale review/source checks, 10 reply/pin
mismatch cases, nonprivileged check mode, post-revoke Docker checks, uncertainty
and same-target recovery without original inputs, and sanitized reports. All 38
also pass with `PATH=/nonexistent`. The 18 plain-data and 66 proposal/error oracle
fixtures remain passing. Seven targeted existing Python tests with mocked guest,
Ansible and lifecycle calls preserve the grant/revoke/check ordering reference.
The full Ansible-running legacy suite was not rerun for this fake-only slice;
its prior `56dba82` evidence remains historical. No host tool was installed or
probed, SSH/Ansible script run, credential read, app opened or VM operated.

**TO PROVE:** real SSH pins/receipt authenticity, native command/TTY/password echo
behavior and SSH quoting, adapter deadlines/cancellation/process ownership,
remote quiescence, private payload materialization, persistent recovery and
explicit restart rebinding, helper/CLI/UI integration, package/signature admission,
terminal streams and every real-guest scenario. Manager execution gates stay
disabled.

[All documentation](docs/README.md) · [Prerequisites and settings](docs/omarchy-bootstrap.md) · [Repository checks](docs/development.md)


## Concrete SSH/Ansible adapters (fake process runners only)

**IMPLEMENTED — milestone 2 continuation, 2 November 2026:**
`SSHAnsibleGuestAdapter` constructs exact SSH/SCP/Ansible invocations, materializes
frozen inputs and interprets bounded results. `ProvisioningProcessRunner` is an
injected port. At `9ebaf17`, only an in-memory fake was supplied; the local
runner continuation below adds a process/PTY backend. There is still no operational
Swift apply/check command. CLI proposals still declare
execution unavailable; manager integration and execution gates are unchanged.

The connection accepts an explicit loopback endpoint, manager VM/session/owner
binding, ed25519 host key and private-key reference. Key admission reads metadata
only. A manager-owned authority revalidates session/dependency admission before
each process; private SSH config/known_hosts enforce the host key and explicit
credential, with forwarding, agent access, proxy commands and connection sharing
disabled. Executables are pinned by resolved identity/hash, revalidated on every
invocation and invoked through their original launcher path to retain Ansible
symlink dispatch. No tool discovery or version probe occurs here.

Private UUID job storage contains immutable repository bytes, bundled playbooks,
roles, catalogue and guest helpers, fixed inventory, JSON variables and isolated
Ansible config/home/temp/plugin paths. Build-time resource copies and hashes are
checked against maintained sources. Nested manifest variables use the exact
snapshot manifest path. Ansible receives the admitted launcher, fixed transport
variables and explicit tags/check mode; user variables never enter shell argv.
Native manifest packages use Omarchy commands and mise, preserving upstream
installation paths. Check mode never installs those packages or changes grants.

Interactive native grant, Docker consent and package installers receive only an
input-lease ID and request an SSH TTY/terminal stream. Ansible requests live output
with closed stdin. A future runner must enforce deadlines, output bounds, PTY
ownership/echo rules and matching local descendant exit before returning. Raw
terminal bytes never enter structured events/results. Cancellation tracks the
command even between subprocesses, prevents the next launch and never interrupts
cleanup. Fake outcomes establish these contracts, not real terminal behavior.

**PRIVATE COUPLING:** `omarchy/guest/provisioning-job.py` is a guest-only Python
helper, not a host Python runtime. It binds one exclusive non-root UUID payload
and lease to recorded systemd user scopes. Preparation requires Linux/aarch64,
Python 3, cgroup v2, a user manager/bus and `systemd-run --scope
--expand-environment=no` support, checked before granting sudo. This flag requires
systemd 254+ ([systemd-run reference](https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html)).
The Ansible shell wrapper scopes module commands. Quiescence seals new body work,
stops recorded scopes and requires inactive/empty cgroups before a structured
receipt. Pending/uncertain launch registration fails closed; payload removal
requires that proof and the exact owned lease. There is no process-name killing
or unverified removal fallback. Cleanup commands may run after sealing to revoke
authorization. This is not a sandbox for trusted custom tasks, which may escape
scopes or create independent services. Uncertain startup can require manual
recovery; persistent recovery and reboot/session rebinding remain deferred.

**VERIFIED — fake-process checks:** make build and all 50 Swift test functions
pass, including 12 new transport tests with parameterized faults, malformed or
mismatched receipts, launcher retargeting, source/workspace tampering, partial
staging, check mode and cancellation before/between/during process calls. All 50
also pass with `PATH=/nonexistent`. The 18 parser and 66 complete planning oracle
fixtures and seven existing mocked Python sequencing tests pass. Both new Python
files pass syntax compilation; 21 bundled YAML resources pass static parsing.
The full legacy suite and real Ansible syntax commands were not rerun because
this slice uses fake process runners only. No SSH/SCP/SFTP/Ansible executable,
credential contents, host installation, UI action or VM operation was used.

**TO PROVE:** actual SSH authentication/quoting, Ansible execution/parity, guest
helper/systemd/cgroup operation and privileged descendants, real deadlines and
cancellation, PTY/password echo and terminal delivery, persistent recovery,
standalone cutover, manager/helper integration and signed relocation. Earlier
fake-adapter evidence remains historical; concrete command generation and local
materialization now exist, without real-guest acceptance.


## Local process runner and PTY — 3 November 2026

**IMPLEMENTED — milestone 2 continuation:** `LocalProvisioningProcessRunner` is
an explicitly injected local backend. It executes an exact absolute program/argv,
working directory and supplied environment, with no shell expansion, tool lookup
or inherited credentials/environment. Pipe mode keeps stdout/stderr separate,
closes unused stdin, limits supplied stdin to 64 KiB and combines captured output
under 32 KiB. Overflow and I/O errors are failures even if the child exits zero.
Streaming mode publishes actual bytes and leaves structured stdout/stderr empty.
The standalone CLI remains offline only; no real SSH/Ansible transport is wired
up, and manager execution gates are unchanged.

`CDevVMProcess` is a small Darwin syscall bridge around `posix_spawn`, PTY,
wait and process-group queries. It creates a new session with inherited file
descriptors closed by default and explicit signal state. For PTYs, supply an
explicit `ProvisioningExecutablePin` for the compiled `dev-vm-process-host`
launcher. Darwin establishes the session after spawn file actions; the launcher
claims its controlling terminal then `execve`s the target, retaining the same
owned PID. It does no tool discovery, shell parsing or credential retrieval.
It needs to be admitted/packaged with the future manager helper, not installed
from Homebrew. No fork runs inside the Swift runtime. The separate C executable
under `tests/ProcessFixture` is test-only and is never an installed runtime asset.
The ordering is checked against [Apple's spawn implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_exec.c)
and exercised by the controlling-terminal fixture.

Ownership is registered before spawn. Cancellation targets only the matching
invocation; deadlines/cancellation send TERM then KILL after 150 ms. The waitable
leader reserves its PID/group until no live group members remain and output
reaches EOF; then the runner reaps that exact child. Normal parent exit with live
children is a failure requiring group cleanup. A 250 ms post-exit drain grace and
2-second cleanup window prevent an inherited pipe from silently hanging success.
Unconfirmed cleanup returns `cleanupUnconfirmed`, retains ownership/descriptors
and blocks the same VM/session across fresh runner instances in this process.
Exact-ID `reconcileLocalCleanup` can retry without launching commands. If a caller
drops an uncertain runner, a retained local reaper keeps that ownership; lost
wait ownership stays blocked rather than risking PID reuse. This registry is
in-memory, not cross-process or crash recovery.

**LOCAL TERMINAL CONTRACT:** `ProvisioningTerminal` provides pull-based raw byte
frames tagged by invocation/channel/sequence, with redacted descriptions. Storage
is bounded to a configured 8 KiB–1 MiB and at most 1,024 frames; snapshots are at
most 64 KiB and report gaps. No viewer callback can stall the drain loop. It does
not reconstruct an arbitrary terminal screen after a gap; the future renderer
must indicate/reset/resynchronize it. ANSI, carriage returns and split UTF-8 bytes
are preserved, not interpreted. There is no UI emulator or IPC attach endpoint.

Input is explicitly granted from a reviewed request (or exact job context), bound
to job/VM/session/dependencies/mode and one lease. Input/resize messages require
an active invocation, exact owner, monotonic sequence and bounds (4 KiB per input,
64 KiB queued, 1–500 rows and 1–1,000 columns). PTYs start raw/no-echo; each input
flush preserves those local settings. Writes and revocation are serialized, so
pending input cannot survive revocation. Detach/revoke does not cancel the job;
an unanswered prompt reaches its deadline. Leases cannot be reused, and a live
command does not permit silent ownership transfer. Input is never published or
persisted. Programs can deliberately print secrets; this is not automatic output
redaction. Remote SSH/sudo echo remains unverified.

**VERIFIED — disposable local fixtures only:** make build and all 64 Swift test
functions pass (14 new local runner functions), plus 18 parser and 66 complete
planning oracle fixtures. All 64 also pass with `PATH=/nonexistent` using the
absolute Swift toolchain and already-built fixtures. Tests copy compiled fixture
and launcher binaries into private UUID temp directories; they cover literal
argv/environment, stdin/EOF, separate capture, floods/gaps, split UTF-8/ANSI,
controlling terminal/foreground group, SIGWINCH sizing, synthetic no-echo input,
lease revocation/replay, descriptor inheritance, stale/early/concurrent
cancellation, TERM-resistant descendants, parent exit, missing/changed launchers
and uncertain-pipe reconciliation/admission. Tests assert no live fixture
children after cleanup (orphan zombies are reaped by launchd). PTY checks need
`/dev/tty` outside the workspace filesystem sandbox: restricted runs failed that
fixture access; the full local suite passes outside that restriction. A one-off
direct Swift invocation without the repository's module-cache environment also
failed its sandboxed cache write; make-based checks use the local cache normally.
No real SSH/SCP/SFTP/Ansible executable, host tool install, credential access, UI
or VM operation is used. Legacy tests that execute Ansible are not rerun.

**TO PROVE:** real SSH/Ansible and nested PTY/remote password behavior, guest
scope/quiescence/auth cleanup, hostile deliberate session/group escape, opaque
kernel stalls and foreign SIGCHLD reapers, cross-process/crash/persistent recovery,
helper launcher signature/admission/relocation, terminal renderer/escape policy,
IPC/viewer resynchronization and operational CLI/manager integration. Process
groups are not a sandbox: deliberately detached code can outlive its parent,
especially if it closes inherited pipes. Local exit proves only the owned group
and descriptors; it never proves guest quiescence or a VM `.exited` boundary.
