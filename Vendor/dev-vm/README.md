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
([image details](docs/omarchy-image.md)). Lean factory admission targets manager
0.11.0 and reuses its reviewed integration archive; see
[what was validated on 0.11](docs/omarchy-lean-011-validation.md).

```bash
make build-omarchy-image
make bootstrap-omarchy-vm VM_NAME="Dev Omarchy" \
  OMARCHY_VM_MANAGER_APP="/Applications/Omarchy VM Manager.app" \
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
- [VS Code, four terminals and Claude across three workspaces](docs/omarchy-layout-multi-workspace.md)
- [Claude and browser, VS Code, and four terminals across three workspaces](docs/omarchy-layout-claude-browser-code-terminals.md)
- [Small screen: Claude, Chromium, VS Code, and two terminals across four workspaces](docs/omarchy-layout-small-screen.md)

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


## Manager package integration — 3 November 2026

Manager integration is committed as `6dbda68111005b657fc358609d058dee676789f4`
on `codex/dev-vm-provisioning-plan`. This worktree adds documentation only; the
manager deliberately keeps its engine/source pin at `bb3fae2`.

Omarchy VM Manager's `codex/dev-vm-provisioning-plan` worktree now consumes an
unmodified 79-file source export from `bb3fae22be45b38035fac52aefa0eb270a9d0fea`.
The manager's `Config/DevVMProvisioning.lock.json` records exact source/resource
hashes, and its make preparation verifies the export before generating a compiled
pin. Root `Package.resolved` exactly resolves the same TOMLDecoder revision. The
engine source, parsers, resources, standalone CLI and engine identity in this
worktree are unchanged; this note records the consumer handoff only.

Manager core and an offline-only `OmarchyVMProvisioningHelper` link the library.
The helper admits embedded resources and supports package verification, manifest
validation and offline plans. Apply/check/recover/exec are refused; it never
creates a runner, reads a registry/Keychain, probes tools or reaches a VM. Its
product UI/CLI setup gates remain disabled. Distribution includes this library's
resource bundle/licenses, helper, exact-source PTY launcher, source lock and a
manifest of final signed child hashes sealed by the outer app signature.

The launcher is built unchanged in a generated standalone SwiftPM package,
without needing this checkout or a new host Python runtime. A fresh developer
build may still need ordinary source/cache access for exactly pinned TOMLDecoder;
runtime planning needs neither a checkout/toolchain nor Homebrew/Ansible.

**VERIFIED — manager local fixtures:** build, 227 manager Swift tests/38 suites,
48 script tests and relocated/read-only offline-helper checks pass. A private
ad-hoc sealed fixture app contains no VM runtime; its actual helper plans with
empty PATH and private empty HOME/TMPDIR, rejects execution/overrides/tampering,
and omits synthetic variable values. Deep strict signature verification passes
before resource damage and rejects it afterward. Manager code is sealed but never
opened/executed by that fixture. Existing socket/mock-authentication fixtures
required running outside the workspace sandbox; no actual Keychain or auth UI was
used. An initial network update was unavailable, so validation reused existing
exact Git objects and private caches with update checks disabled. No real SSH/
SCP/SFTP/Ansible, host installs, UI action or VM operation occurred.

**TO PROVE:** complete runtime-kit app assembly, Developer ID/notarization,
other-Mac relocation, authenticated helper IPC, job/session/journal integration,
terminal rendering/attachment, operational CLI/app setup and all real guest/
authorization/echo/quiescence behavior. Existing 64 package-test and oracle
results above remain evidence for the pinned engine, not new remote acceptance.


## Manager coordinator/journal foundation — 3 November 2026

The manager foundation is committed as `f752331b4158f464b4fcef71d8a8c289df1d2e61`
on `codex/dev-vm-provisioning-plan`. This companion change is documentation only;
the manager keeps its shared engine/source pin at `bb3fae2`.

The manager's `codex/dev-vm-provisioning-plan` worktree now has an internal
`ProvisioningCoordinator` over this package's pinned `ProvisioningSequencer`,
plus a private versioned job journal and VMManager lifecycle leases. It retains
the unchanged `bb3fae2` source/resource pin. No engine API, parser, resource or
standalone command changes are required in this worktree; these docs record the
consumer's next step.

The coordinator deduplicates accepted job/review identities, reserves one active
job, revalidates package/source/session/dependencies, journals before adapter work
and separates viewer lifetime from explicit job cancellation. The private bounded
journal stores digests/manager-owned IDs and structured status, not credentials,
source contents/paths, terminal data or helper PIDs. Bad/changed journals fail
closed. Disk failure stops body work while known-target cleanup remains possible.

Manager leases defer ordinary shutdown for cleanup, block incompatible lifecycle
or storage edits and preserve `.exited` ownership. Force stop and unexpected
session/execution/readiness changes retain cleanup uncertainty. A cleanup deadline
records risk while retaining the worker; pending Quit then uses normal VM shutdown
policy. Restart-required remains metadata. No VM lifecycle is added to this library.

Explicit same-process recovery uses the original opaque engine ticket, without
sources or input. After restart, interrupted/cleanup-required records never resume
apply or reconstruct a ticket from a PID. The pinned ticket API is intentionally
in-memory: authenticated helper reattachment, persistent recovery, frozen-input
capsules and reviewed session rebinding remain future integration work.

**VERIFIED — manager fakes/local fixtures:** 248 Swift test functions/40 suites
(21 new coordinator/journal functions), 48 script tests and existing relocated
package checks pass. Coverage includes deduplication/stale admission, private
write-ahead/corrupt storage, cancellation/viewer detach, shutdown/force stop,
sleep/exit/SSH loss, unresponsive-worker deadlines, disk failure with attempted
revoke, live cleanup after source removal and conservative reopen. New coordinator
paths execute no subprocess. Existing socket/mock-context fixtures require the
workspace sandbox exception, without actual Keychain or authentication UI.
No real SSH/SCP/SFTP/Ansible, host installs, manager UI or VM operations occur.

**TO PROVE:** production coordinator construction/helper IPC, durable source and
recovery formats, SSH waits/restart rebinding, job/terminal UI and CLI, retention/
migration and real guest/helper crash/authorization/echo/quiescence behavior. The
manager execution surfaces remain disabled. This is the start of milestone 3,
not full job integration or real-guest acceptance.


## Durable frozen inputs and cleanup checkpoints — 3 November 2026

This continuation adds shared-engine APIs required by the manager's next
milestone-3 slice. The historical manager handoffs above describe the earlier
unchanged `bb3fae2` consumer; they do not describe this extension. Python
operational commands and disabled Swift execution entry points are unchanged.

`SourceSnapshot.privateArchive()` emits the private `DVMSNAP1` binary format:
versioned strict JSON metadata followed by selected raw file bytes. The reader
checks exact schema, duplicate keys, safe paths, hashes, lengths, tree references,
snapshot identity and EOF. It preserves binary bytes, modes and empty directories,
without host absolute paths/root inode identities. Bounds are 8 MiB metadata,
32 MiB file bytes, 4096 files/directories, 8192 directory children, 150000 JSON
values and path depth 64. `FrozenInputsArchive` exposes inert data with redacted
descriptions; it cannot become a SourceSnapshot/SetupPlan, extract into a user
tree or resume apply. Selected config may be sensitive: never put archive bytes
in plan/status/events/terminal output. File privacy/quota belong to the manager.

`CleanupRecoveryIdentity` takes an independently authenticated original
job/payload/guest/dependency/engine/mode expectation. Its private version-1
checkpoint includes original guest identity metadata, without credentials,
private keys, source data or terminal bytes. Restore compares the exact document
and conservatively re-proves work/payload risk and apply-only grant/cache
inactivity; disk flags cannot assert cleanliness. It authorizes no transport
by itself. The sequencer accepts a preallocated payload UUID, and retains its
control payload until grant/cache inactivity and work quiescence are proved.

The manager now fsyncs UUID-named 0600 input/checkpoint files in a 0700 directory
before its schema-2 index and worker. It binds hashes/token/payload to the original
review/session/dependencies, uses a bounded quota counting orphan files, and never
automatically imports/replays/deletes artifacts. Reopened cleanup requires a fresh
challenge proof from an injected authority that the previous worker is stopped
AND fenced from further launch. The authority is fake-only in this slice; no PID
or disk observation is sufficient. Cleanup needs neither original sources nor an
input archive, and never stages/grants/applies/prompts/restarts/rebinds. The fixture
boundary is coordinator/helper reopen with the original surviving VMManager
session, not full manager/VM restart adoption. Legacy journal risk remains held
when no genuine ticket/checkpoint exists.

**PRIVATE COUPLING — manager export:** manager `codex/dev-vm-provisioning-plan`
uses the immutable `bb3fae22be45b38035fac52aefa0eb270a9d0fea` base plus
`Patches/dev-vm-durable-state.patch`. Its lock binds base and resulting 82-file
inventories, patch hash, resulting snapshot digest and updated engine identity;
preparation verifies the result and reverse patch against the base inventory.
This is not an unchanged-base engine claim or a mutable external path dependency.
Parser, guest resource and C launcher bytes are unchanged. This worktree contains
the matching shared source/tests; the manager export retains baseline README bytes
and documents current integration in its own plan/vendor notice.

**VERIFIED — shared fake/local fixtures:**
`make build-provisioning test-provisioning test-provisioning-oracle test-provisioning-planning-oracle ORACLE_PYTHON=/opt/homebrew/opt/ansible/libexec/bin/python`
passes 68 Swift test functions, 18 strict-parser oracle fixtures and 66 complete
planning/error oracle fixtures. The Python path uses an already available runtime
only for development-time comparisons, never Ansible or a runtime fallback.
Four new test functions cover binary/mode/empty-directory archive round trips,
source removal, malformed/traversal/hash/version damage, conservative apply/check
cleanup restore, wrong original identity, preallocated payloads and helper retention
when inactive proof fails. Existing PTY tests need the workspace sandbox exception
for `/dev/tty`; all process fixtures are disposable local programs. No real
SSH/SCP/SFTP/Ansible, installs, UI actions or VM operations occurred.

**VERIFIED — manager fake/local fixtures:** `make test` passes 260 Swift test
functions/40 suites, 49 script tests and relocated/read-only offline-helper
packaging. Twelve new coordinator/journal functions exercise close/reopen and
interrupted markers, fresh original-worker fencing, wrong-session/dependency and
proof rejection, source/input removal, damaged/unsafe/swapped checkpoints,
quota/orphans, private inert archives and schema-1 risk preservation. A graceful
shutdown race now classifies body cancellation separately from original guest
identity so cleanup is not suppressed. Production entry points stay disabled.

**TO PROVE:** production authenticated helper IPC/fencing and manager construction,
full manager/VM restart with reviewed session rebinding, SSH waits, real missing
control-helper reconciliation/crash/quiescence, power-loss durability, artifact
retention/removal, live terminal/job UI and CLI, and all real guest authorization/
echo/transport acceptance. A helper that cannot prove absence leaves cleanup
required. This slice does not enable Swift operational execution.


## Manager authenticated helper ownership — 3 November 2026

The manager's milestone-3 continuation implements capability-authenticated
inherited helper IPC and original-worker fencing. This section supersedes the
older pending-IPC statements above; this worktree's shared engine, resources,
Python commands and immutable manager source pin are unchanged.

The manager/helper control channel uses an inherited same-user Unix stream and
per-launch 256-bit capability passed only through an anonymous bootstrap pipe.
HMAC-SHA256 frames bind helper instance/executable/package identity, direction,
channel, sequence and payload. Strict bounded schema/request/challenge checks
reject replay, reflection, wrong pins/keys, truncation and unexpected commands.
Capabilities never enter arguments, environment, disk, journal or diagnostics.
Only one request may be outstanding and a failed channel is never auto-retried.
This authenticates the private launch capability, not a distribution signing
identity; production launch admission remains a distinct required step.

A helper-local registry retains immutable original job/VM/session/payload/worker,
review, engine/dependency/binding/checkpoint scope. Registration is a trusted local
owner operation, never an IPC/disk-import command. Missing state and a new/empty
helper return unknown. The manager wrapper over this package's process-runner
protocol closes an original worker's launch gate permanently, interrupts only its
owned invocation, and waits for matching local exit/not-started or exact retained
cleanup. Uncertain or mismatched receipts retain ownership. Local proof never
claims guest work/grants are clean: the shared sequencer still quiesces/revokes/
verifies/removes against the original revalidated guest. Disconnect fences local
work without inventing remote proof or reading a PID from disk.

The coordinator now has a concrete authenticated recovery authority, tested with
fake runtimes/process runners and local sockets after coordinator reopen. The
actual relocated/ad-hoc sealed helper also supports an inherited ownership-only
mode. Its empty registry authenticates unknown responses but creates no runner,
tool probes, journal, Keychain access or VM. Existing operational setup gates and
apply/check/recover/exec entry points remain disabled. Shared code/resources and
the manager's base-plus-durable-patch source inventory do not change in this slice.

The user-supplied Setup-tab screenshot is the reference for the future large dark
live terminal/stage strip, follow/expand, cancellation and job details. Raw terminal
and input bytes are deliberately absent from the structured ownership protocol;
rendering, stream/input-lease transport and UI/CLI attachment remain later work.
No screenshot with personal sidebar identifiers is copied into this repository.

**VERIFIED — manager local fixtures:** `make test` passes 275 manager Swift test
functions/41 suites (15 new IPC/coordinator functions), 49 script tests and the
expanded relocated/read-only helper fixture. New Swift IPC tests use only fake
process runners. A separate actual ad-hoc sealed helper is tested through private
inherited socket/pipe descriptors, empty PATH and private empty HOME/TMPDIR; its
empty registry returns authenticated unknown, rejects replay/wrong MAC/bad binary
pins, and produces no secrets or host state. Existing package signature/tamper
checks still pass. Full regression uses the existing exception for local sockets/
synthetic LAContext, with no actual Keychain or auth UI. No real SSH/SCP/SFTP/
Ansible, installs, manager UI or VM operations occur. Shared code is unchanged;
prior 68 package tests/oracles remain historical evidence, not a new run here.

**TO PROVE:** automatic admitted manager/helper launch and exclusive backend/job
registration, operational sequencer/IPC delegation, full manager-process restart
and reviewed session rebinding, signer/audit policy as required by release,
real helper/guest crashes, remote cleanup and hard kernel-stall behavior, plus
terminal/CLI integration and real guest acceptance. A private capability/live
registry supports coordinator reopen, not adoption of a VM after manager restart.
The missing-helper case remains cleanup-required rather than assumed safe.


## Manager admitted helper launch and registration — 3 November 2026

The next manager milestone-3 slice adds an admitted helper launch factory and
inert worker registration. This supersedes the earlier pending launch/registration
status. This worktree has a documentation-only handoff: shared code/resources,
Python commands and the manager's base-plus-durable-patch source pin are unchanged.

The manager admits its exact package/helper, strict outer/nested signatures and
retained executable identity. Default policy requires non-ad-hoc matching app/
helper Team IDs; an explicit internal ad-hoc fixture policy is separate. Before
handing over the private launch capability, Security.framework verifies the owned
running child's admitted cdhash. Transient PID lookup is never saved/adopted or a
substitute for the authenticated inherited connection. Spawn uses fixed argv,
private cwd/HOME/TMPDIR, empty tool PATH, null diagnostics, bootstrap pipe and one
control fd with CLOEXEC-default handling. A waitable owned child is retained until
matching exit; there is no arbitrary PID kill or automatic helper replacement.

Bootstrap 2 reserves one metadata-only worker and sends an authenticated receipt
for the exact registration digest before reconciliation. The reservation contains
plan/input/mode and original job/VM/session/payload/worker/review/engine/dependency/
binding/checkpoint/helper identities, never source contents, guest credentials,
process invocations or terminal bytes. It has no operational runner/activation
API. Fencing permanently retires the not-started reservation. Bootstrap 1 still
has an empty registry and reports unknown for lost workers.

The coordinator now persists schema-3 owner pins and a pending registration marker
before launch, checks fresh admission around the receipt, and leaves a queued job
with no engine task and a conservative cleanup hold. Duplicate submissions cannot
automatically dispatch it. Schemas 1/2 preserve risk without inventing owners;
unknown/partial owner fields fail closed. Errors after owner publication retain
that exact owner, close only its channel and keep cleanup required. Recovery
requires the same surviving service/channel plus fresh original-scope proof.
Confirmed shared-engine remote cleanup releases that helper channel while its
owned child observer waits for exit. Matching VM `.exited` still controls guest
resources; no VM storage or lifecycle is added to this package.

The manager adds a debug-only Swift launch-fixture product, excluded from app
staging and disabled in release. It exercises the real factory with an ad-hoc
sealed/read-only disposable app. Fake-runtime tests cover ordering and failure;
no host software is installed and no real SSH/Ansible or guest is executed.
The Setup-tab screenshot remains the later terminal UI reference.

**VERIFIED — manager local fixtures:** `make test` passes 284 manager Swift test
functions/42 suites (9 new registration/coordinator/journal functions), 49 script
tests and expanded relocated/read-only signed package fixtures. Fakes cover
journal-before-spawn and owner retention, receipt/admission/session failures,
duplicates, schema migration and same-service recovery after coordinator reopen.
The real factory's debug-only fixture rejects ad-hoc code under production policy,
rejects resource tampering and same-byte executable replacement, then admits an
explicit ad-hoc fixture, verifies its owned child's loaded code, registers/fences
its inert worker and observes matching reaped exit. Control directories stay empty;
capabilities never enter output/files. Existing protocol/signature/tamper checks
pass. Local sockets/mock-auth fixtures use the existing sandbox exception, without
real signing credentials, auth UI, host installs, SSH/Ansible or VM operations.
Shared code/pins are unchanged and were not retested by this docs-only handoff.

**TO PROVE:** product wiring, operational engine/job/backend dispatch, positive
release signer/Team policy, full manager restart/reconnect and reviewed session
rebinding, real helper/guest crashes and remote grant cleanup, hard kernel stalls,
retention, SSH waits, terminal streams/input leases and UI/CLI. Existing setup
execution gates stay disabled; this slice does not start an operational Swift
provisioning job or complete milestone 3.


## Manager helper-side engine dispatch — 3 November 2026

The manager continuation activates a registered helper worker and invokes this
package's shared sequencer with injected fake adapters. This supersedes the earlier
no-dispatch status. This worktree changes documentation only: shared code/resources,
Python commands and the manager's immutable engine/source pin remain unchanged.

Authenticated activate/status/cancel messages name an exact original registration,
activation ID/digest and owner/review/plan/input/engine/dependency/session scope.
They carry acknowledgement booleans, never executable plans, arbitrary paths,
credentials or terminal bytes. The helper ANDs acknowledgements with its locally
prepared approval. One activation owns one task/sequencer, and duplicates return
status without preparing or running again. Changed activation conflicts; fencing
never reopens. A local context factory must prepare without guest/process work and
provide the matching reviewed request/approval, authority, exclusive runner and
adapter. The product helper has no such factory and refuses activation.

The helper task survives viewer/RPC detach. It revalidates command/binding/mode,
package/body and session/dependency authority, stops body on known disconnect or
cancellation, and permits original-target shared-sequencer cleanup without input.
Typed bounded status contains operation/result/failure metadata, not terminal,
source values or raw errors. Final local runner uncertainty overrides a clean guest
result. Disconnect retains owned tasks/cleanup instead of treating EOF as exit or
grant revocation. No guest authorization or Ansible rules are reimplemented.

Manager schema 4 persists activation identity and cleanup risk before dispatch,
checks authenticated monotonic results and retains lifecycle holds on lost replies,
disk/status failure or VM/session/dependency change. Accepted activations are never
automatically replayed after coordinator reopen. Explicit original-owner cleanup
still requires fresh authority; helper-child exit and matching VM `.exited` remain
separate. Ordinary shutdown preserves cancellation/cleanup ordering.

A separate temporary ad-hoc-signed fixture app replaces only its helper slot with
the excluded debug fixture binary. That binary hosts the synthetic factory and
fixed local manifest, so actual admitted helper-process dispatch/cancellation can
be tested without putting a fake backend in the normal helper. No runtime flag,
environment override or RPC can enable a product backend. No real SSH/SCP/SFTP/
Ansible, host install, manager UI or VM operation is performed. The Setup screenshot
stays the future terminal UI reference; raw streams/input remain later work.

**VERIFIED — manager fake/local fixtures:** `make test` passes 297 manager Swift
functions/43 suites (13 new engine/coordinator/journal functions), 49 script tests
and expanded signed package checks. Tests cover one-shot apply/check, activation
consent/context/source checks, cancellation/fencing/disconnect, physical uncertainty,
journal-before-RPC, viewer detach, shutdown, malformed/lost replies, no replay after
reopen, runtime/dependency invalidation and strict schema preservation. The regular
helper refuses activation without a factory. A distinct temporary ad-hoc-signed
helper fixture runs the actual shared sequencer with synthetic adapters, completes
and cancels/cleans correctly, and exits through the admitted owned launcher.
Existing identity/protocol/signature/tamper checks pass. No fake backend is put in
the normal helper/app, and no real signing credential, authentication UI, transport,
installation or VM is used. Existing socket/mock-auth sandbox exceptions apply.
Shared sources/pins are unchanged; their prior tests/oracles are not rerun here.

**TO PROVE:** production frozen-context/consent delivery, exclusive real backend
construction and manager-aware per-command session authority, product wiring,
full manager/helper restart/reconnect and reviewed rebinding, release signatures,
real guest/auth/echo/remote cleanup/crash/kernel behavior, terminal/PTY/input/UI/CLI.
Current fixture acceptance does not establish guest behavior or enable operational
setup. No shared package/oracle rerun is claimed for this docs-only handoff.

## Manager frozen-input delivery and context validation — 3 November 2026

The manager's next milestone-3 continuation delivers selected frozen inputs and
reviewed request metadata to its admitted helper. This supersedes the pending
context transfer above. This worktree exposes `SetupPlan.manifestPath` as public
read-only metadata so a consumer can preserve the reviewed relative manifest path;
engine inventory is regenerated. No planner/parser/guest/C-launcher behavior or
Python operational command changes. The manager's immutable base-plus-patch export
is updated with that exact API/inventory change; it is not an unchanged engine pin.

The manager fsyncs a private immutable `DVMCNTX1` blob (strict request JSON plus
`DVMSNAP1` selected archive). Registration/schema-5 journal bind its exact length
and total/metadata/archive hashes to the original owner/review. A retained private
read-only source descriptor is checked before transfer. The child inherits an
empty separate socket at fd 4; only after owned-live-child image admission receive
bootstrap 3 and the frozen bytes. Capability/source data do not enter arguments,
environment, status or terminal. Data is chunked/bounded and requires exact size,
hash and EOF; no arbitrary host source path is sent to the helper.

The helper verifies metadata/target/session/dependencies, writes only into a new
private UUID tree using descriptor-relative no-follow/exclusive traversal, and
preserves modes, binary bytes and empty directories. Existing archive bounds plus
implicit-directory/depth bounds apply. It independently replans with this package
inside that tree, compares plan/input/engine hashes, reconstructs the full request
and compares review identity before acknowledging delivery. `FrozenInputsArchive`
remains inert data; it does not deserialize an executable plan or grant apply.

A backend receives the validated context only; delivered, backend and explicit
activation acknowledgements combine by AND. The product helper has no backend,
rejects activation and keeps execution gates disabled. Only an excluded Debug
fixture constructs synthetic adapters. Once an accepted frozen job exists, its
selected private copy defines the reviewed inputs; original-checkout edits/removal
cannot replace them. Source checks still precede publication, activation validates
persisted/private copies, cleanup remains independent of inputs, and reopen never
replays apply. Schemas 1–4 preserve risk/ownership without invented receipts.
Partial private artifacts are retained; automatic import/removal is not introduced.

**VERIFIED — shared fake/local checks:**
`make build-provisioning test-provisioning test-provisioning-oracle test-provisioning-planning-oracle ORACLE_PYTHON=/opt/homebrew/opt/ansible/libexec/bin/python`
passes 68 Swift functions, 18 parser oracle fixtures and 66 complete planning/error
fixtures. The already available Python runtime is used solely for development
oracle comparisons; no Ansible or product Python fallback runs. Existing PTY
fixtures need the local `/dev/tty` sandbox exception.

**VERIFIED — manager fake/local checks:** `make test` passes 308 Swift functions/
44 suites, 49 script tests and expanded relocated/read-only signed-helper fixtures.
Coverage includes independent replan after source deletion, custom manifest/
catalogue/tasks, binary/mode/empty-directory preservation, metadata/hash/scope/
framing damage, unsafe/changed private descriptors, root substitution and directory
bounds, strict bootstrap/receipt/journal handling and consent constraints. The
actual product helper validates but denies activation. A separate ad-hoc-signed
fixture helper receives/validates a multi-frame payload, then completes/cancels
using fake adapters after the parent's source is removed. Changed delivery is
refused and the owned child reaped. No real SSH/SCP/SFTP/Ansible, credentials,
auth UI, host installs, installed-app changes or VM operations occur.

**TO PROVE:** exclusive real backend construction and trusted manager-aware session/
dependency authority, product wiring, full restart/reconnect/rebinding, real release
signatures, power-loss durability/retention UX and terminal/PTY/input/UI/CLI work.
Real guest authorization, echo, cleanup/quiescence and crash/kernel behavior remain
unproved. This is a foundation continuation, not completion of milestone 3.

## Manager helper backend and session authority — 3 November 2026

The next manager milestone-3 continuation constructs this package's concrete
`SSHAnsibleGuestAdapter` with an original-worker fenced runner and a manager-backed
session authority. This supersedes the pending construction/authority foundation
above. The product helper has no transport-resource provider, rejects activation
and leaves setup execution gates disabled. All exercised providers supply inert
fixture files and fake process runners; no SSH/Ansible command is executed.

Shared changes are narrow: `ProvisioningSSHConnection.verify()` exposes stat-only
identity reference revalidation without reading key bytes;
`ProvisioningTransportTools.verify()` is public; `ProvisioningProcessPurpose` gains
Codable for fixed private metadata. Inventory and the manager's exact immutable
base-plus-patch export/engine pin are updated together (82 resulting files). Guest
resources, parser dependencies and C launcher remain unchanged. No Python
operational workflow or runtime fallback changes.

A single-use helper-local builder checks the frozen request/package and fresh
manager permission before asking a trusted provider for the explicit connection,
tools, dependency digest and idle process-runner factory. Recheck exact bindings
and pins around awaits, then construct the shared adapter and fenced runner with
the same authority. There is no manifest/RPC-selected executable, host path or
credential-discovery default. Production managed-SSH/Homebrew admission and private
resource handoff remain consumer wiring, not an implicit capability of the builder.

Bootstrap 4 binds a separate inherited fd-5 reverse authority channel. A derived
HMAC key domain and separate counters prevent control frames from granting session
permission. The manager binds one original registration/activation after durable
activation/lease publication. Fresh challenge-correlated checks cover preparation,
commands, invocations and completion; responses are never cached. A dedicated
reverse loop keeps control/status/cancel available while the coordinator awaits
VMManager/dependency checks. Typed bounded metadata contains no owner names,
credentials, paths/argv, source or terminal bytes. Wrong/replayed/lost frames fail
closed. Schema 6 preserves the authority version without inventing it for legacy
rows or resuming apply after restart.

VM/session/readiness/lifecycle ownership remains with the manager. It checks the
current lease/generation/activation and original target/dependencies around awaits.
The fenced runner records ownership before permission and rechecks cancellation
before backend launch. Original-target cleanup remains possible after ordinary
cancellation or package/source loss. Failed journal writes stop body work while
retaining the live lease for cleanup and an unresolved hold. Lost or invalid
authority cannot assert remote cleanliness; uncertain local ownership retains the
original runner until explicit matching proof. No VM implementation is duplicated.

**VERIFIED — shared fake/local checks:**
`make build-provisioning test-provisioning test-provisioning-oracle test-provisioning-planning-oracle ORACLE_PYTHON=/opt/homebrew/opt/ansible/libexec/bin/python`
passes 68 Swift functions, 18 parser oracle fixtures and 66 complete planning/error
fixtures. The existing Python runtime is development-only; PTY fixtures use the
existing local `/dev/tty` sandbox exception. No real Ansible or guest runs.

**VERIFIED — manager fake/local checks:** `make test` passes 319 Swift functions/
45 suites, 49 script tests and expanded relocated/read-only signed-helper fixtures.
New coverage includes concrete adapter apply/check without execution, construction
ordering/resource changes, fresh manager permission before every fake invocation,
cancel/shutdown/session/readiness/dependency/package/channel changes, cancellation
during dependency validation, failed-journal cleanup, strict MAC/challenge/schema
and binding handling, local-authority bypass refusal and uncertainty recovery
without constructing another backend. A separately sealed/ad-hoc-signed Debug
helper exercises actual backend construction and inherited session RPC with fake
process replies, completion and deterministic interruption/cleanup. The normal
helper refuses activation without a provider and matching child exit is reaped.
No real credentials/auth UI, host installs, SSH/SCP/SFTP/Ansible, installed-app
change or VM operation occurs.

**TO PROVE:** consumer resource admission/handoff and product construction, real
runner/terminal/input leases, UI/CLI, full restart/reconnect/rebinding, release
signatures, power-loss/retention UX and all real guest/auth/echo/transport/remote
cleanup/quiescence/crash/kernel behavior. Fresh manager RPC is not atomic remote
execution or proof of guest liveness after its reply. Milestone 3 remains incomplete.

## Manager transport-resource admission and private handoff — 3 November 2026

The next milestone-3 continuation admits the manager's original transport resources
and hands them privately to its helper. This supersedes the pending admission/
handoff foundation above. Product setup gates stay disabled; the normal helper
has no process-runner factory and still refuses activation. No VM implementation
or Python operational workflow is changed.

The shared package adds `ProvisioningTransportReference`, an explicitly private
metadata format for original connection/executable proofs. It contains the public
host key and identity-file path/stat proof, never private-key bytes. Import checks
strict schemas, expected binding/identity/tool paths and original inode/mode/link/
time/hash/target proofs rather than blessing replacement files. Identity references
now require one link. Descriptions are redacted; default report/event encoding is
not added. Export/import do not run a process or authorize execution by themselves.
The manager's exact base-plus-patch export/engine pin is updated with 83 resulting
files. Guest resources, parser dependencies and C launcher remain unchanged.

The manager admits only its current running/ready session/profile/root and managed
SSH port. It verifies public managed manifests/known-hosts metadata, root identity
and stat-only key reference without calling credential generation or key-reading
storage validation. It consumes an already checked dependency report, validates
fixed system entries, Homebrew Ansible pair/version/installation and fingerprints,
and captures original full tool pins. Dependency identity is derived from that
selection and must match the reviewed request. Report fingerprints are change
detectors, not new binary-signing or complete runtime provenance claims.

An ephemeral bounded descriptor binds resources to the original job/VM/session/
worker/payload/review/checkpoint/plan/engine/mode. Bootstrap 5 binds its SHA/size/
dependency receipt and inherited fd 6. Only after owned-child admission transfer
it on the private one-shot channel, with exact framing/hash/EOF. No descriptor file
is written; no private paths/data enter arguments, environment, control/status/
terminal frames or the journal. The helper independently checks its host policy
and original references before acknowledging the resource digest. Fixture policy
is injected only by excluded test code, never selected by the document or a flag.

Manager and helper recheck current resources before publication/activation and
command/invocation boundaries. Changed keys/tools/wrappers/installation/public
metadata require new review, not automatic recapture or cleanup retargeting.
Schema 7 stores receipts only; legacy risk/pins survive without invented resources.
Live admission/launch state remains separate, and coordinator reopen never imports
credentials or replays apply. Product resource acquisition/coordinator wiring,
operational runner and terminal/input leases remain later consumer work.

**VERIFIED — shared fake/local checks:**
`make build-provisioning test-provisioning test-provisioning-oracle test-provisioning-planning-oracle ORACLE_PYTHON=/opt/homebrew/opt/ansible/libexec/bin/python`
passes 70 Swift functions, 18 parser fixtures and 66 complete planning/error oracle
fixtures. New shared tests round-trip original proofs with an unreadable synthetic
identity file and reject changed/retargeted/unknown proofs. Python is used only for
development comparisons; existing PTY tests use the local `/dev/tty` exception.

**VERIFIED — manager fake/local checks:** `make test` passes 328 Swift functions/
46 suites, 49 script tests and expanded relocated/read-only signed-helper fixtures.
New coverage includes manager-owned metadata/report admission, private round trip,
key/tool/alias/installation/metadata/root changes, cross-job/mode/review/format/hash
damage, acknowledgement refusal, independent policy, migration and no replay.
Concrete apply/check use fake process runners. A separate sealed/ad-hoc-signed
Debug helper imports the actual inherited descriptor and uses original resources
with fake process replies for completion/cancellation; matching exit is reaped.
The normal helper rejects fixture paths under host policy and gets no fake runner.
No real credentials/auth UI, host installs, SSH/SCP/SFTP/Ansible, installed-app
changes or VM operations occur.

**TO PROVE:** genuine resource admission across supported installations, product
acquisition/coordinator wiring and report provenance/lifetime, operational runner/
terminal/input/UI/CLI, full restart/reconnect/rebinding, release signing, retention/
power-loss UX and real guest identity/auth/echo/transport/remote cleanup/quiescence/
crash/kernel behavior. Stat/hash/RPC checks do not make remote execution atomic or
prove guest liveness after a reply. Milestone 3 remains incomplete.

## Manager milestone 3 completion — 3 November 2026

**DESIGN DECISION:** manager milestone 3 is complete for fake/local acceptance. Its
new manager-owned service installs once with product execution disabled; opening it
admits the pinned package and seeds persisted lifecycle risk before exposing work,
without probing tools, starting helpers or operating VMs. A strict private workflow
index complements schema-7 child journals and receipt-bound frozen inputs. Owned
preparation waits for the exact SSH session, requires review, persists acceptance
before suspending and deduplicates concurrent/duplicate requests. Original-helper
exit observation is required even after a clean engine result.

Planned restart requires separate approval and the matching old `.exited` before
the manager may create the replacement session. Fresh resources, the same VM/owner/
UID/expected key and a distinct explicit rebind review authorize a new check-only
job over frozen inputs, excluding custom tasks and password input. Cancellation,
timeout and `.error` never substitute for exit or silently reapply.

Reopen never resumes activation or imports sources/credentials. Cleanup requires
current manager-session authority, original resource admission and independent
stopped-and-fenced proof from the original authenticated helper. A surviving
launcher can support service/coordinator reopen; a genuinely fresh manager process
cannot recreate that capability from disk. It retains cleanup-required holds and
refuses worker/VM adoption and replay. The separate-process debug fixture exercises
owner exit during fake work, EOF fencing and fresh-process refusal; its marker is
only a test diagnostic, never a production ownership proof.

Retention preserves private inputs/checkpoints/deliveries and orphan/partial files.
Count/byte-only reports reveal no private contents or paths. Quotas refuse work
instead of evicting recovery data; retained rebind trees also have count/entry/byte
bounds. Manual recovery/retention UX remains later acceptance work.

**VERIFIED — consumer no-VM checks:** `make test` passes 347 Swift test functions in 48 suites, 49 script tests, and relocated/read-only ad-hoc-signed helper fixtures. The final `make test-provisioning-tools` run passes 141 functions in 13 suites after the last cancellation/recovery guard changes. Package/export validation and companion/vendor source/engine matching pass.
No shared source or export-pin changes were needed for this completion above the
transport-resource handoff slice. The previously recorded 70 shared Swift, 18 parser
and 66 planning/error oracle checks remain its evidence. New manager checks cover
service composition, local runner construction/output with no input grant, SSH and
restart/rebind lifecycle, concurrency, failures/corruption, retention, surviving-
capability recovery and full-process lost-capability refusal. No actual SSH/SCP/
SFTP/Ansible, credential/auth UI, host install, installed-app change or VM operation
is performed.

**TO PROVE / NEXT:** milestone 4 live terminal/stream/input/resize delivery and
rendering; milestone 5 Setup UI/CLI; milestone 6 approved real guest authentication,
restart/check, revocation, remote cleanup/quiescence and crash/sleep/wake behavior;
milestone 7 release signing/distribution. Product helper execution remains disabled
without an operational runner factory. Positive remote recovery/adoption after
full process loss is not established by the safe refusal tests. The Setup screenshot
remains a later UI target.

### Manager milestone 4 terminal transport — 3 November 2026

The manager consumer now connects the shared memory-only terminal to a dedicated
inherited, separately authenticated helper stream. Viewers start read-only; one
explicit owner generation controls input and PTY size. Detach/expiry/channel loss,
completion/cancel/fence and observed output gaps revoke input. Queued keystrokes
are discarded on suspension; a new live attachment must deliberately reclaim the
reviewed scope. Output stays bounded, in memory and separate from structured
status/results and journals. Eviction requires a visible decoder/emulator reset,
an explicit jump to the live tail and a fresh claim, never invented old screen
state. The scoped local TTY helper restores settings after success/error/cooperative
cancellation; hard process termination is not covered.

The shared package adds reserved-versus-enabled input scope, atomic suspension and
explicit resumption, plus a read-only tail sequence for the consumer's reset
contract. Permanent revocation remains final. Transport workspaces normalize their
own generated paths before local runner admission. Sources, engine inventory,
manager export and reviewed patch are synchronized; the immutable base revision
remains unchanged. No guest resources/playbooks or third-party dependencies change.

**VERIFIED:** `make build-provisioning test-provisioning test-provisioning-oracle
test-provisioning-planning-oracle
ORACLE_PYTHON=/opt/homebrew/opt/ansible/libexec/bin/python` passes 72 Swift test
functions, 18 parser oracle fixtures and 66 complete planning/error oracle fixtures.
Python is an existing development oracle only. The manager's final `make test` passes 362 Swift functions in 49 suites,
49 script tests and the relocated/read-only/ad-hoc-signed helper fixtures. Package
export verification, exact comparison of all seven changed source/engine/test
files and both worktree diff checks pass.
Local fixtures prove ANSI/carriage-return/split-UTF-8 byte delivery, real local PTY
prompts/hidden input/resize, view detach/reclaim, expiry, stale capability refusal,
bounded floods, cancellation, gap/reset handling and TTY restoration. An excluded
ad-hoc-signed debug helper runs a fixed local printf/sleep feature fixture through
the admitted frozen/resource/session/engine/terminal path; it never executes the
original SSH/Ansible command. The shipped helper still has no operational runner
factory and product execution remains disabled.

**TO PROVE / NEXT:** native emulator/rendering and host-action escape policy,
Setup UI and external CLI stream endpoint are manager milestone 5. Real nested
SSH/native guest authentication/echo, resize, revocation, restart/check, remote
cleanup and crash/sleep/wake acceptance remain approval-gated milestone 6; release
distribution/signatures remain 7. Full-process loss cannot recreate terminal or
worker capabilities from disk. No real transports, host installs/downloads, VM or
user UI operation occurred. The Setup screenshot remains the milestone-5 target.

### Manager milestone 5 terminal/observation slice — 3 November 2026

The manager consumer now has a native Setup terminal and separate same-user
streaming CLI endpoint backed by the existing job service. Both use the shared
terminal/input contract; no shared engine/resource source changes are required.
The manager pins SwiftTerm 1.99.0 as a renderer-only dependency (Swift 6.2+), filters
host-action escapes, validates split UTF-8, bounds scrollback/input, displays gaps,
and requires explicit ownership. Offline manager presets select the existing
`developer`, `web`, `python` and `project-managed` profiles through the same planner.
UI/CLI default to view-only; detach is distinct from cleanup-aware cancellation.

The manager's `make test-provisioning-ui-cli` covers renderer, strict protocol,
same-user sockets, cross-view ownership and disposable CLI TTY restoration.
`make test` passed 376 manager Swift test functions in 50 suites, 52 script tests, and the relocated/read-only/ad-hoc-signed helper fixtures (including original owner-loss/reopen and terminal streaming). The focused UI/CLI coverage contains 13 functions plus the four-case bundled-preset test: split Unicode/ANSI, cursor/colour/CR rendering, blocked host actions, oversized/malformed streams, storage bounds across cursor/style changes, native viewer ownership/search/reset, strict correlated protocol refusal, cross-view input ownership, EOF/gap/reclaim, distinct cancellation and disposable PTY termios/signal/open-file-flag restoration on detach, connection loss and task cancellation. Vendor inventory, the reviewed two-line source patch, exact upstream export comparison, unchanged shared-package export checks and `git diff --check` passed. No user window was opened or real transport executed.
These are fake/local checks. Product execution, New VM setup coupling,
frozen preview-to-apply/custom-task trust and reviewed restart/check/recovery
surfaces remain gated follow-up work. No real SSH/Ansible, host installs or VM
operations occurred. Shared package sources/resources remain at committed
`3d616f0`; its previous 72 tests and oracle checks remain the unchanged baseline.

### Manager milestone 5 frozen review and task-trust slice — 3 November 2026

The manager now exposes frozen preview capture/lookup, explicit bounded task-source
inspection and prepare/apply consent through the same native/CLI service. It uses
this package's existing SetupPlanner, immutable source archives and request review
identity; no shared library/resource/pin changes are needed. Capture replans inside
a retained private UUID tree and compares plan/input/engine hashes. Later edits to
the original folder cannot change the approved inputs. A separate task-trust digest
binds the exact request, complete frozen snapshot and task selection. General Apply,
persistent sudo and Docker root-access acknowledgements do not imply task trust.

Final submission rechecks frozen sources, package, original resources/session and
fresh dependencies before the existing helper path. One preparation/submission is
owned per UUID; duplicate consent retrieves its acceptance, while failed operations
are not automatically replayed. Explicit source reads use 4096-byte chunks and never
enter background status/terminal output. Memory-only previews/consent cannot be
reconstructed from retained files after manager restart. Product execution and its
real owner/UID/key resolver stay disabled; fake tests supply synthetic bindings.
`make test` passed 390 manager Swift test functions in 52 suites, 52 script tests and the relocated/read-only/ad-hoc-signed helper fixture suite (including original-owner loss/reopen and terminal streaming). `make test-provisioning-review` passed 28 functions in three suites: frozen previews, original-source edits, explicit task-source chunking, preview quotas, no authority after reopen, separate task/sudo/Docker consent, exact duplicate submission, changed source/tool/session admission, cancellation during a gated final recheck, stale task trust, strict nested protocol cases and CLI/native service interoperability. Tests call the native service API and actual private CLI socket, without opening the form or claiming visual acceptance. Package/export and both diff checks pass; shared package sources/resources/pins are unchanged.
Native feature editing/New VM handoff and reviewed restart/check/recovery surfaces
remain follow-up work. No actual SSH/Ansible, host installs, factory images, VM
operations or user UI takeover occurred. Shared sources/resources remain unchanged
at `3d616f0`; the docs-only terminal consumer commit is `f5d495c`. The manager's
preceding terminal/UI/CLI slice is committed at `18feed5`.

### Manager milestone 5 reviewed workflow actions — 3 November 2026

The manager now exposes reviewed restart, post-restart check and cleanup recovery
through the same native/CLI service. Exact action UUID/digest and acknowledgement
bind workflow, VM/session/job, sequence and frozen-input/dependency hashes. It
reuses the established manager coordinator and this package’s sequencing contracts.
Restart waits for matching VM exit before replacement; check requires fresh-session
admission, excludes custom tasks and grants no authorization input. Recovery uses
only original identity/quiescence/revocation/cache/inactive/payload cleanup, with a
lazy adapter factory behind authenticated original-worker and checkpoint admission.
Saved metadata/PID cannot recover lost capabilities; failed revocation retains risk.
No Apply/task trust is reused as action consent and no failed operation is replayed.
`make test` passed 403 manager Swift test functions in 54 suites, 52 script tests and the relocated/read-only/ad-hoc-signed helper fixtures, including original-owner loss/reopen and terminal streaming. `make test-provisioning-actions` passed 13 functions in two suites (including ten malformed-wire variants and three final-check admission/cancellation variants). Fake fixtures cover explicit consent, shared CLI/native action lookup, duplicate restart/check, diagnostic-vs-exit boundaries, fresh-session frozen checks with custom tasks excluded and no authorization input, active-risk recovery refusal, lazy factory ordering, missing original capability after reopen, source-free cleanup, failed revocation/retained holds, stale sibling recovery reviews, failed-operation non-replay and lost in-memory consent. Product endpoint tests prove disabled refusal before probes/factories. UI controls compile; complete interactive/visual acceptance was not performed. Package/export checks and both diff checks pass. Shared package sources/resources/pins are unchanged.
Product execution, real target resolution and recovery factories stay disabled.
Native feature editing/New VM setup handoff and all real guest/visual/distribution
acceptance remain separate. No actual SSH/Ansible, installs, factory images, VM or
user UI operations occurred. Shared library/resources/pins remain unchanged; the
manager’s preceding frozen-review slice is `d6d9c64` (companion docs `09a099c`).

### Manager milestone 5 native features and New VM handoff — 3 November 2026

The manager now presents common built-ins as Use source/Enable/Disable choices in
Setup and New VM. Advanced profiles/catalogues/options remain source-owned; this
package's existing planner still resolves dependencies, ordering and conflicts.
Native edits derive a private generated manifest from frozen source bytes. The
original manifest/mode remains an asset, and generated bytes enter the exact
plan/input hashes. No-edit plans retain their identity. New file references must
already be selected or declared as assets; no live source reread fills a gap.

New VM reviews and saves that frozen selection, separately from executing it.
The manager's explicit resources/factory/SSH/owner/sharing arguments determine the
new profile. Saving grants no task trust, sudo or Apply authority and launches
nothing. A creation review is reserved for one UUID/configuration hash; exact
repeats look up the original profile, changed settings fail, and uncertain saves
retain their reservation. Registry schema 6 stores only a validated non-secret
receipt. Preview binding requires its matching saved profile; after restart,
metadata can deduplicate lookup but cannot restore frozen review/apply authority.

Strict setup protocol 1 adds creation prepare/lookup and typed feature lists.
CLI uses `setup prepare-create REVIEW_UUID --preset NAME [--enable FEATURE]
[--disable FEATURE]`, then `create NAME --setup-review-id REVIEW_UUID
--setup-review DIGEST --ack-setup-selection`. Start/wait require a separate
command. Existing-guest preview capture accepts the same feature flags. Independent
Apply/custom-task/persistent-grant and workflow-action reviews remain required.
Homebrew readiness cannot enable product execution.

**VERIFIED — fake/local:** `make test-provisioning-selection` passes 16 manager
Swift test functions in one suite. Tests cover preserved bytes/modes/no-edit
identity, all native choices, shared catalogue dependency refusal, advanced fields,
manager resource/factory precedence, strict protocol/CLI consent, duplicate and
uncertain saves, concurrent SSH-port admission, quota and inert reopen. Fixtures
assert zero VM starts, dependency probes, helper launches and VM storage roots.
`make test` also passed 419 manager Swift functions in 55 suites, 52 script tests
and relocated/read-only/ad-hoc-signed helper fixtures. Package/export verification
and both diff checks pass. The manager plan records the exact scope and limitations.

**TO PROVE:** complete native visual/interaction acceptance, operational guest
identity/key evidence and runner/recovery factories, milestone-6 real guest/echo/
cleanup/restart/check/crash/sleep/wake and milestone-7 signed distribution. Product
execution and target/recovery factories stay disabled. No actual SSH/Ansible,
host installs, factory images, VM or user UI operations occurred. This is a
manager-consumer/docs change; shared package sources/resources remain at `3d616f0`
and the immutable manager export remains `bb3fae22be45b38035fac52aefa0eb270a9d0fea`
plus `Patches/dev-vm-durable-state.patch`. Engine/resource pins are unchanged.
The preceding workflow-action commits are manager `c92c7ed`, companion `7e0bc4c`.

### Manager authenticated identity and dormant backends — 3 November 2026

The manager now retains owner UID evidence from its existing authenticated managed
SSH monitor, with strict four-field JSON parsing and before/after endpoint/key
checks. Evidence binds the exact VM/session, manager-owned root inode/device, port,
host key, public metadata hashes and stat-pinned client identity; it expires after
45 monotonic seconds. Display-only readiness, manifests and saved receipts cannot
create it. Same-binding authenticated refreshes preserve readiness; failed or
changed authentication and retry/pause/shutdown/exit invalidate authority and
fence late callbacks. Host transport admission/revalidation requires that evidence.
This implements the consumer's responsibility for this package's `GuestBinding`;
real guest identity/key authenticity remains unproven.

Dormant composition reuses the admitted package/engine/resources and pinned process
host through the existing local runner. Worker construction still requires original
inherited ownership, validated frozen input and transport, manager session authority
and per-invocation fencing. Recovery construction remains behind authenticated
original-worker fencing and cleanup-only scope, with manager-aware transport checks.
The manager now supplies inert resolver/recovery closures. A shared fixed-false
build-time gate prevents product execution and helper runner selection; no CLI,
manifest, readiness or environment variable enables it. Constructing a new runner
never proves an original worker has stopped.

The focused fake/local suite passes 43 manager Swift functions in nine suites.
Tests include strict fake replies, pin/UID/session changes, expired evidence, stale
probe callbacks, actual monitor refresh with fake execution/sleeps, inert worker
construction, lazy recovery using fake runners and retained cleanup boundaries.
`make test` passed 428 manager Swift functions in 56 suites, 52 script tests
and relocated/read-only/ad-hoc-signed helper fixtures. Build, package/export and
both diff checks pass. Component-render evidence is recorded in the manager plan.
No real SSH/Ansible, host installs, factory downloads, VM or user desktop operations
occurred. Real guest/TTY/cleanup/restart/check/crash/sleep/wake, whole-screen native
interaction and signed distribution retain their separate acceptance gates. This
prepares guest acceptance; it does not record a milestone-6 real-guest pass.
Shared sources/resources/export base/patch and engine pins are unchanged.

The manager also rendered and inspected its actual feature controls and terminal
offscreen, with labelled synthetic Unicode/ANSI output. Its debug-only renderer
runs before AppModel/registry/service creation, prohibits activation and shows no
window. The image is a component fixture; whole-screen interaction and actual
prompt/echo behavior remain unproven. Shared package code/pins were not changed.

The native selection/New VM handoff, authenticated identity and dormant backend
consumer changes are committed in manager `e92dcf7`. This companion change is
documentation only; shared library/resources and the manager export pin are unchanged.

### Manager full-screen fake acceptance and guest runbook — 3 November 2026

**VERIFIED — manager consumer only:** the actual New VM/selection/manager Setup
views now pass 56 isolated fake-service view/action checks, with eight inspected
full-screen light/dark/scrolled captures. These cover review acknowledgment,
source/feature edits and late replies, manager resource/factory precedence,
metadata-only frozen handoff and duplicate creation, chunked task inspection,
independent apply consent and terminal search/expand/cancel. Fixtures use only
in-memory synthetic data and a never-started FakeRuntime; no personal registry,
real transport or guest backend is supplied. Offscreen backing windows cannot
become key/main or activate and never appear on an attached display.

The manager's `make test` passed 428 Swift functions in 56 suites, 52 script tests,
relocated/read-only/ad-hoc-signed helper fixtures and the 56 screen checks. Final
screen validation, package/export verification and release compilation pass; the
release binary omits the DEBUG acceptance entry point/fixture markers. No real
signing identity was used. The manager's `docs/DevVMUIAcceptance.md` owns the matrix,
images, reports and limitations; `docs/DevVMMilestone6Runbook.md` owns the prepared,
not-executed disposable-guest approval worksheet, operational candidate prerequisites,
real evidence matrix and cleanup procedure.

**TO PROVE:** physical input, focus/VoiceOver, native dialogs/file importers,
real identity/SSH/Ansible/nested TTY echo and end-to-end guest cleanup/restart/check/
crash/sleep/wake. A separately reviewed candidate restricted to explicitly approved
disposable UUID roots must precede real execution; ordinary product execution stays
disabled. No host installs, factory downloads or VM launches occurred. This
companion update is documentation only. Shared package sources/resources remain
at `3d616f0`; the manager export is still `bb3fae22be45b38035fac52aefa0eb270a9d0fea`
plus `Patches/dev-vm-durable-state.patch`, with unchanged engine/resource pins.

The manager acceptance harness, screenshots and milestone-6 runbook are committed
in manager `c51c004`. This companion commit records the consumer evidence only;
shared library/resources and the manager export pin remain unchanged.

### Manager milestone-6 disposable admission — 3 November 2026

**DESIGN DECISION — consumer only:** the manager now derives product execution
from an optional reviewed disposable-root approval, currently nil. A future private
candidate must embed original UUID/root/device/inode/ownership-marker identity
pins independently in manager and helper. No Boolean, CLI/environment, manifest,
registry, journal, tool report or wire field can grant this approval. A directory
marker alone does not prove an existing VM is disposable; trusted explicit approval
must identify newly prepared disposable roots.

The manager checks its profile/session namespace, preparation, transport, leases,
cleanup and both sides of restart; a compiled candidate retains restrictions before
service installation and after coordinator close. Helper backend construction and
preparation/command/invocation RPC boundaries independently recheck its local scope.
Input claim/send/resize also recheck approval and release ownership on failure;
read-only output remains available. Recovery constructs no adapter outside scope
and cannot bypass original-worker/session/quiescence or cleanup proofs. Root
replacement, changed markers, unsafe ownership/mode, symlinks, retained POC IDs and
unlisted/foreign roots are refused. Directory descriptors prevent inode reuse.

**VERIFIED — fake/local:** 12 manager admission test functions include invalid and
changed-root matrices, admitted fake work, independent manager/helper refusal,
post-RPC change, same-UUID foreign root, restart/replacement, recovery and terminal
input revocation. No real SSH/Ansible, host installs, images or VM launches occur.
The manager plan and `docs/DevVMMilestone6Runbook.md` own the precise evidence and
operational prerequisites. Ordinary product execution remains disabled and no real
approval values have been installed. A concrete signed candidate, real guest/TTY/
cleanup/restart/check/crash/sleep/wake and distribution remain TO PROVE. This
companion change is docs only; shared sources/resources and manager export/engine
pins are unchanged.

The full manager regression run passed 440 Swift functions in 57 suites, 52 script
tests, relocated/read-only/ad-hoc-signed helper fixtures and 56 isolated screen
checks. The final focused admission suite passed after cross-viewer input
revocation coverage. Release compilation (without real signing credentials),
package/export verification and both diff checks pass. No actual guest acceptance
or signed-distribution result is claimed.

### Manager Source and multiple profile cards — 3 November 2026

The consumer now separates configuration Source (bundled or local folder) from
multi-select Developer/Web/Python/Project managed cards. Native badges and readable
summaries are derived from this package's resolver: inherited Developer features,
additional features, language tools and database clients. Individual native feature
overrides are hidden for now. Local manifest profiles/options/tasks remain included;
cards add bounded builtin profiles and deduplicate aliases through a generated
private manifest. The source folder stays unchanged. Profile edits require a new
frozen review/acknowledgment, with proposal identifiers and raw data under Details.

The shared resolver still owns combination/dependency/option conflict semantics.
Sibling conflicts are refused, not resolved by card order; an explicit local option
can resolve a conflict. Legacy preset CLI requests remain compatible; the native
source DTO adds strict optional bundled/profile fields on the existing protocol.
Local custom catalogue profiles remain manifest-defined; native cards cover the
four bundled profiles. No task/sudo/Docker or execution authority comes from cards.

Manager validation passed 24 focused selection functions, 448 Swift functions in
58 suites, 52 script tests, local signed helper fixtures and 62 isolated screen
checks. Eight light/dark/scrolled captures were inspected; release compilation
without real signing credentials, package/export and both diff checks pass. The
manager UI acceptance/implementation records own images, hashes and limitations.
Product approval remains nil and execution disabled. No real SSH/Ansible, host
install, image download or VM launch occurred. This companion change is docs only;
shared package/library/resources and the immutable manager export/engine pins are
unchanged. Physical UI and real guest/distribution acceptance remain TO PROVE.

### Manager optional-app trim integration — 3 November 2026

The shared Swift planner/adapter now honor the existing `vm.lean_developer`
selection. Offline proposals list allowlisted candidates, excluding explicit
manifest packages and resolved feature packages. Installed state is unobserved.
The upstream guest trim helper and allowlist are packaged as hashed resources;
apply runs them through the authenticated job supervisor and terminal stream,
after manifest packages and before features. Check never trims. Native Omarchy
owns removals, with the existing recursive-transaction protection and cleanup.
This guest-side Python helper adds no host Python/PyYAML prerequisite.

The manager conditionally exposes **Trim optional apps** only for its official
Try Omarchy identity, off by default, freezes the choice and refuses unsupported
factory handoff/preparation. The reusable factory image is unchanged. Its export
adds `Patches/dev-vm-optional-app-trim.patch` over the existing immutable base and
durable-state patch, with updated engine/resource/snapshot pins. Real guest
trimming remains TO PROVE; product execution stays disabled.

Verification: 77 shared Swift test functions pass using fake process runners and
disposable local fixtures; twelve legacy trim tests pass with mocked subprocess
results. Resource sync/helper Python syntax parsing passes. Manager selection,
package and 74 offscreen UI checks pass; retained scrolled light/dark screenshots
show the controls. Guest trim/reapply/terminal behavior remains TO PROVE.

Verification exception: the broad `make test-omarchy` target invoked installed
Ansible against temporary local inventories/synthetic helpers before its complete
scope was inspected, exceeding the requested no-real-Ansible restriction. It
finished with 10 failures, 44 errors and one skip among 235 tests, including missing
Python TOML support. This is not passing acceptance evidence. No guest was
contacted, host tool installed or VM/factory operation performed. Subsequent trim
verification uses mocked helpers/fake runners only; the exception is recorded in
the manager implementation plan.

Final manager release compilation passes without signing credentials; both
worktree diff checks and immutable reverse-patch/export verification pass.
Changes remain uncommitted. The final export engine is
`83061c59cd7f1c4f87f0762183eaa6a4b61bc85592366874cd86e1654a9d8ff7`.

### Manager Theme & layout integration — 3 November 2026

The shared Swift package now supplies `ThemeSelection`/`ThemeResolver` for strict
GitHub roots, `random` and `most-starred`, catalogue figures, minimum stars and
stable ranking ties, behind injected HTTP and star providers. The manager resolves
once during review and GET-checks the concrete repository, then freezes that URL
in the existing workstation options. A GET checks accessibility, not theme content,
compatibility or a fixed Git commit. Direct URLs and random with zero minimum stars
need no gh; star-based selection uses an existing authenticated GitHub CLI, with no
installation/sign-in flow and no logged credentials or raw responses.

The collapsed native Theme & layout section also supports a selected Lua layout or
managed-layout removal. A bounded UTF-8 file is copied into private reviewed inputs,
so later original-file edits cannot change apply. Existing shared snapshot/planning,
Ansible variable/staging and native Omarchy helpers continue to own application;
no separate executor, host Python dependency or YAML workflow is introduced.
Explicit workstation disable is refused; other source settings remain included.
CLI review commands expose --theme/--theme-min-stars/--layout-file/--remove-layout.
The manager export adds `Patches/dev-vm-theme-selection.patch`, with updated
source/engine/lock/snapshot pins and fake tests.

Verification for this slice uses fake HTTP/star/process providers, URLProtocol
responses without sockets, local files and disposable shell fixtures with stub
Omarchy/git commands. The broad `make test-omarchy` target is not run because it
invokes real Ansible; the user's fixture-only restriction takes precedence over
that repository target. Shell/Python syntax checks are used without guest execution.
No real HTTP/gh/SSH/Ansible, tool install, factory change/download or VM launch is
performed in these checks. Actual catalogue/authentication/theme/layout behavior
remains TO PROVE under explicit disposable acceptance; product execution stays off.

Verification results: shared make test-provisioning passes 84 Swift functions,
including selector/GET/ranking and fake apply/check transport coverage. Nine selected
controller tests pass under guards against real network/subprocess/manager access;
nine guest theme-helper tests use disposable HOME and stub Omarchy/git commands.
Shell syntax/Python AST checks pass. Manager make test passes 463 Swift functions,
52 scripts, signed local helper fixtures and 82 offscreen UI checks; eleven focused
appearance functions and release compilation also pass. Four new light/dark
appearance screenshots were inspected. Reverse integration-patch/export and both
worktree diff checks pass. Final exported engine is
`f51a1b3d9f0432b613b67b014ca6abd5d18794f2edae11b5b5eacbc9508b00a0`.
Changes remain uncommitted in both worktrees.

Manager presentation follow-up (3 November 2026): responsive theme/layout panels
and explicit Keep/GitHub/Random/Most starred choices map to the unchanged source
DTO/resolver. Trim help is adjacent to its toggle; reviewed inclusion is a short
separate status. Ninety-two offscreen fake-service checks pass, including choice
forwarding and wide/narrow layouts. Shared code/resources/pins and disabled product
execution are unchanged; no actual network, host installation or guest operation.

### Bundled layout examples in the manager — 3 November 2026

The four original Lua examples and a maintained catalogue of wireframes, titles,
app prerequisites and source hashes are copied into the shared resources. The new
`LayoutExamples` API admits fixed IDs and verifies catalogue/source hashes before
offering bytes. The manager displays single-select cards under Desktop layout →
Examples, retains Custom file/Keep/Remove and freezes the selected original Lua in
its existing private input path. The CLI review option is --layout-example. Native
previews recognize the selected example by the actual frozen input hash.

Cards show intended relative placement, not live guest state. All examples use
floating placement rules, including the overlapping browser in the Claude layout.
App names are prerequisites, not implicit package installation selections. Card
selection/review never executes Lua, launches apps/VMs or authorizes provisioning.
The original Lua files are unchanged. The manager export adds
Patches/dev-vm-layout-examples.patch with new engine/resource/snapshot/lock pins.

Verification uses Swift fake/local fixtures, offscreen synthetic services and
byte-for-byte comparisons of all four original files/catalogue to the bundled
copies. No real Lua, HTTP/gh/SSH/Ansible, host install, factory change/download or
VM launch is used. The broad test-omarchy target is skipped because it invokes
real Ansible, contrary to the user's current constraint. Physical UI and actual
guest app availability/startup/geometry/login behavior remain TO PROVE under
explicit disposable approval. Product execution remains disabled.

Verification results: 86 shared Swift functions pass. Full manager tests pass 468
Swift functions in 62 suites, 52 scripts, signed local helper fixtures and 100
isolated screen checks. Five new manager functions cover exact frozen example bytes,
no implicit app installs, old-review stability, exclusivity, legacy compatibility
and CLI/socket paths. All four original Lua files/catalogue compare byte-for-byte
to bundled copies; resource-sync Python syntax and reverse export/diff checks pass.
Four current light/dark gallery captures were inspected. The exported engine is
`818e5ba3267d14f0d08453118fb3b962d25afef2a90a9810dda043e07d9cb369`.
Changes remain uncommitted in both worktrees; real guest acceptance remains open.
Final manager release compilation passes without signing credentials or notarization.

### Manager milestone 6 offline preflight — 3 November 2026

The manager now provides `make provisioning-preflight` to verify its immutable
export/reconstructed base/generated pin and existing resource inventory, and record
local build hashes without running candidates or guest/dependency/signing tools.
This is manager development tooling, not a shipped Python controller or a shared
package API change. Offline PASS is separate from readiness: executionAuthorized
stays false and guestAcceptance stays NOT_RUN. Source/candidate correspondence,
approved new disposable roots, operational composition, signing/loaded code and
real factory/dependency/guest evidence remain explicit prerequisites. Product
approval remains nil; no real scope has been chosen or prepared.

Ten offline checks and all 61 manager script tests pass, including nine new
preflight/read-only export regressions. Existing Swift/shared/UI acceptance remains
the evidence for the unchanged package sources. No real HTTP/gh/SSH/Ansible,
signing credentials, host install, factory/VM operation or desktop control occurs.
The broad real-Ansible targets remain skipped under the user's constraint. The
manager runbook's Offline candidate preflight section records use and limitations.
This checkpoint collects the previous pending admission/UI/trim/theme/layout work
and related docs in both worktrees; the earlier uncommitted notices are historical.

### Private scoped manager candidate — 3 November 2026

After explicit stopped-profile/root preparation approval, a separate private manager
candidate is built from manager commit `1cb2bdd` plus a six-file recorded overlay.
Its Core embeds the original UUID/root/device/inode/marker constants in both manager
and helper, fails closed if the original scope is unavailable, and adds no external
approval loader. Actual identifiers, source overlay and artifact evidence remain
private/ignored. The ordinary manager stays disabled; shared package source/pins
are unchanged. No standalone controller or virtualization fork is introduced.

Thirteen offline artifact checks, both packaged component inspections before/after
relocation, scope probes against the candidate Core with zero fake runtime starts,
and twelve ordinary manager admission tests pass. Existing pinned kit content and
signatures are preserved. Only ad-hoc signing is used; the unchanged production
same-team helper policy correctly refuses this candidate. No real SSH/Ansible, host
install, credentials, VM launch, normal UI or operational worker body is used, and
the real root/metadata/registry remain unchanged. Signed loaded-child acceptance,
approved SSH/owner configuration, actual factory/tools, exact inputs/consents and
all real guest rows remain TO PROVE/NOT_RUN. The broad real-Ansible targets remain
skipped. The manager runbook's Private scoped candidate preparation section records
the current boundary; milestone 6 is not complete and no real run is authorized.

### Offline candidate signing/readiness audit — 3 November 2026

The manager audit records nineteen passing static checks and seven remaining
signing/readiness gates. Candidate/package/kit/source/scope and original root/registry
are unchanged. Static Core 2.21.5 metadata and common Homebrew formula paths are
observations only: no Ansible, brew, SSH or gh command is executed. Factory-cache
metadata is present, but OS file access refuses checksum verification; no permission
is granted and no image/disk is downloaded, copied or decompressed.

Source review confirms the supported signed-prerelease runtime/profile/pin rebuild
is required. The existing tag workflow checks out ordinary source and publishes
archives, so a separate reviewed nonpublishing handoff must retain the original
private scope. No identity enumeration, credentials, Keychain access, signing,
notarization, network, workflow/publication or guest operation is used. No shared
or product source changes; detailed reports/pins remain private/ignored. Ordinary
execution stays disabled and all real guest rows stay NOT_RUN. The manager runbook's
Offline signing and readiness audit section records exact boundaries and the next
safe fake/local handoff work. Broad real-Ansible targets remain skipped.

### Private signing/packaging handoff — fake/local, 3 November 2026

The manager now prepares a private immutable signing request from explicitly
reviewed candidate/scope digests. Source/receipt/original scope, runtime/resources,
locks and profile pin are frozen together; no target root is visited or recaptured.
The actual candidate produces a private 101-file handoff. CLI exposes preparation
only, with no real signer/credentials/publisher. Shared Swift sources and package
pins remain unchanged, as do product execution and production signing policy.

Eighteen new manager test functions, including 22 rejection variants, and all 79
script tests pass. The injected fake signer exercises profile/runtime/rebuild/
child-sign/post-sign-seal/outer-sign/verification/private archive and extraction.
Scope and immutable inputs survive callbacks and roundtrip; tampering, unsafe
archives, nonprivate/source/VM/release outputs and failed requests are refused.
Partial outputs remain private without replay or raw signer errors. The actual
request is refused by the synthetic runner; fake non-Mach-O outputs are explicitly
SIMULATION_ONLY and cannot establish genuine signing or launch readiness.

Detailed inputs/results remain ignored/private. No actual signing, credentials,
installed-tool command, host install, network/workflow/publication or VM operation
occurs. Real signer/private build integration, cryptographic/loaded-child and
original-Mac scope validation, existing factory/tool/SSH/owner gates and all real
guest acceptance remain TO PROVE/NOT_RUN. The manager runbook's Private signing
and packaging handoff section records the boundary; the broad Ansible targets
remain skipped under the user's constraint.

### Private signer adapter — fake processes, 4 November 2026

The manager now connects its frozen private handoff to signed-prerelease build,
SDK signing and private archive verification through an injected command runner.
It requires a local signed runtime with the original development-kit origin and
clean pinned client/parser sources; runtime signing stays upstream. The recorded
source/overlay is reconstructed with original scope and operational composition
preserved. Only signed pins and the signed inspection branch are projected.
Child signing precedes the provisioning seal and outer signing, followed by strict
signature/team/authority/hardened/timestamp/profile/entitlement/certificate checks,
bundle-only diagnostics and exact extraction/verification again.

The system runner denies by default before reading signing material and needs
explicit trusted in-memory request/scope/material/effect authorization. No signing
CLI, credential importer, keychain unlock/search change, runtime fetch, notarization
or publication interface is added. Signing timestamps would contact Apple and
remain separately approval-gated. Ordinary product execution stays disabled and
the actual candidate/pins remain private and unchanged. Shared Swift source and
package pins are unchanged.

Twelve new manager tests, including 33 command/signature failure cases and four
runtime cases, and all 91 script tests pass with fake processes/local fixtures.
Mocked system dispatch checks explicit environment and timeout group cleanup;
no real process or group is touched. Fixture results explicitly report no genuine
cryptography, original-Mac validation, loaded-child or guest execution. Real
compiler/SwiftPM/SDK signing, authorized material availability, notarization,
original-Mac scope and loaded-child checks remain TO PROVE, as do prior factory/
tool/SSH/owner gates and every real guest row. No real signing, credentials, Apple
requests, host installs, SSH/Ansible, VM launch, disk operation or UI takeover
occurred. The manager runbook's Private signer adapter section records this
boundary; broad real-Ansible targets remain skipped.

### Real signed-candidate gate preparation — 4 November 2026

The manager prepared a private review-only gate with exact retained candidate/
request/original-scope and source/adapter bindings, required runtime-origin and
profile pins, canonical clean client/parser observations and unresolved material
selectors. The candidate and frozen request re-admit; both local dependencies match
their archived revisions. No target root/registry is visited or identity recaptured.
Pins and the packet remain private; every approval remains NOT_GRANTED and ordinary
execution stays disabled. The adapter and shared sources/pins are unchanged.

The required runtime is a real Developer ID signed variant of the frozen patched
development kit, retaining its origin, capabilities and immutable payload, with
the same selected team as app/children. No eligible real runtime is selected; the
team/identity, isolated keychain and exact pinned profile path remain unselected
and uninspected. No credential areas are searched. If a runtime must be produced,
its upstream signing-only route and isolated-keychain handling need a separate
review: upstream's builder has no explicit keychain selector, while ordinary
release orchestration imports credentials, notarizes and publishes artifacts.

The manager gate runbook separates named material inspection/preparation, optional
runtime production, private app build/key use/Apple secure timestamps, original-Mac
scope/non-activating loaded-child validation, optional notarization and later
disposable-guest approval. A trusted one-shot caller and material binding can only
be reviewed after concrete selections; the review packet is never authorization.
Preparation runs read-only local Git only: no SDK, real signing, credentials,
Apple/network requests, SSH/Ansible, installs, UI, disk operation or VM launch.
Existing 91-test evidence remains applicable; no new executable behavior is added.
All real compiler/profile/cryptographic/notary/original-Mac/loaded-child and guest
outcomes remain TO PROVE/NOT_RUN; broad real-Ansible targets stay skipped.

### Matching local signed-runtime discovery — 4 November 2026

The primary manager checkout retains an existing published `v0.9.4-dev.1` signed
runtime matching the frozen candidate's source-lock/kit/patch and payload. Its ZIP
digest/inventory and three extracted bundle inventories match. Newer local
candidate origins differ and are ineligible. Matching bundle/ZIP/lock copies are
privately staged in the adapter layout and checked again; original artifacts,
gate/request/scope, shared source/pins and ordinary product approval are unchanged.

Nonsecret identity/team selectors derive from the helper's existing public CMS
certificate, parsed locally without a signing, Keychain, trust or network call.
This is not key-availability or fresh SDK signature proof. Profile candidates are
located/stat-ed only and remain unopened; no keychain is selected or queried.
Exact selectors/paths/digests stay private. Every approval remains NOT_GRANTED.
Next is explicit isolated-keychain selection and separately approved bounded
runtime/profile validation and private profile staging. Admitting this existing
artifact avoids new runtime signing; app build/key use/timestamps and all later
gates remain separate approvals. No credential access, signing/SDK tool, Apple
request, SSH/Ansible, install, UI, image or VM operation occurs; guest acceptance
stays NOT_RUN. The manager runbook's Local signed-runtime discovery section records
the evidence boundary; broad real-Ansible targets remain skipped.

### Integrated candidate inputs for 7e46241 — 4 November 2026

After merging latest main into the manager, a new private source-only packet
freezes the exact `7e46241` archive, six-file scoped overlay and current package/
runtime/profile requirements. Original scope JSON, historical source commit,
UUID/root/device/inode/marker pins, receipt and complete scope-definition source
are preserved verbatim. The new source commit is bound independently. Previous
artifacts, requests and gates remain unchanged; actual paths/pins stay ignored.

The retained dev.3 release artifacts reuse the exact signed runtime declared
dev.2, which matches this integrated source's origin, capabilities and immutable
payload. Development/signed archives and extracted/staged bundle inventories pass
local checks; no signature bytes are changed. The overlay reconstructs exactly on
a second fresh archive. Twenty-two input consistency/refusal checks and all twelve
manager fake signer tests pass. Original 930 private artifact entries are unchanged
and new packet permissions are private. Shared package source/pins are unchanged.

The existing app-based signer requires source/scope commit equality. This packet
preserves the historical scope and uses a distinct source-only kind, refused before
runner authorization or material IO. A reviewed source-only admission/caller update
is required before real consumption; no app receipt, legacy request or executable
authority is fabricated. App compilation, named profile/keychain validation,
cryptographic/loaded-child and real guest evidence remain TO PROVE/NOT_RUN. No app
build/signing, credentials/profile bytes, Apple/network requests, SSH/Ansible,
installs, image, UI or VM operation occurs. All later approvals remain NOT_GRANTED.
The manager runbook's Integrated candidate inputs for 7e46241 section records the
gate; broad real-Ansible targets remain skipped.

### Source-only admission and caller — 4 November 2026

The manager now admits its unchanged source-only packet through a distinct
version-2 contract. Typed in-memory review binds the new source/archive/overlay,
packet and team/fixture mode independently of original scope bytes, semantic
digest, preserved definition and prior request. Versioned request digests cannot
alias legacy or packet digests. The existing app-based admission stays separate;
gate JSON, checksum files and environments never provide execution authority.

Strict inventories, safe archive/config/package/resource checks, exact scoped
source reconstruction and runtime-origin/payload/ZIP admission feed the existing
adapter, with callback re-admission and unchanged signing/sealing/verification
policies. The typed caller consumes one use atomically before admission and
defaults to refusing before profile/keychain IO or output. No signing CLI,
credential import/unlock, retry, publication or notarization operation is added.

Eighteen new manager tests cover complete fake adapter/extraction roundtrip,
independent source/scope preservation, authority/version/runtime mutation and
concurrent one-shot refusal. The allowed full Python run passes 127 tests with
five software-signing/PKCS12 skips (132 discovered); process auditing records no
forbidden tool attempt. Actual frozen `7e46241` inputs admit as read-only data,
with process/network hooks blocked and no runner/material authorization created.
All 1,161 previous private artifact entries, pins and historical gate fields stay
unchanged; new evidence remains separate/private. Shared Swift/package source and
pins are unchanged and product provisioning stays disabled. No actual signing,
credentials/profile bytes, Apple requests, SSH/Ansible, installs, app/UI, image or
VM operation occurs. Named material validation and real compiler/signature/profile/
loaded-child/original-Mac and guest evidence remain TO PROVE/NOT_RUN. See the manager
runbook's Version 2 source-only admission and caller section; broad Ansible targets
remain skipped.

### Named material inspection and staging — 4 November 2026

The manager adds a separate typed, one-shot inspection caller for selected
profile/keychain/public-certificate/runtime inputs. Its request domain binds the
admitted source, selectors, independent public-leaf/inspector hashes and private
output. Default execution denies before material IO/output; native authorization
must be inspect-only and fixture inputs cannot execute it. Exact profile/public
certificate bytes stage privately; profile scope/expiry, leaf membership/name/dates,
local dependency identity/cleanliness, runtime inspection and callback input/file
revalidation are covered. Keychain metadata only is checked; contents, key
availability and unlocked state are never queried. Public parsing does not prove
trust. Staged material requires a distinct later signing approval; no CLI,
credential importer/unlocker or automatic signing continuation is added.

Nineteen new manager fake tests pass. The full allowed Python suite has 146 passes
and five signing/PKCS12 skips (151 discovered); auditing observes only local
Git/Python, with no forbidden-tool attempt. All 1,161 retained private artifact
entries and frozen pins stay unchanged. Actual material selection/inspection,
key availability, compiler/signatures/profile trust/loaded-child/original-Mac and
guest evidence remain TO PROVE/NOT_RUN. No actual profile/certificate parser,
SDK/CMS, keychain, signing, credential, Apple, SSH/Ansible, install, app/UI, image or
VM operation occurs. Shared Swift/package source and pins are unchanged; ordinary
provisioning remains disabled. See the manager runbook's Named material inspection
and private staging section. Broad real-Ansible targets remain skipped.

### Bounded native inspection — source review, 4 November 2026

Manager source review traces upstream verification into the bundled daemon's
exact `check` branch: helper access, local payload hashes and static client CDHash
validation return before listener/session/start operations. The client's XPC
check is a different command. No native code was executed to establish this.

A proposed separate offline adapter/request requires explicit
`kSecCSNoNetworkAccess`, CMS content decoding without signer trust evaluation,
locked keychain status only and static runtime validation with no daemon launch.
It preserves frozen runtime bytes and requires a 300-second job/120-second stage
deadline, live 2 MiB stream caps, bounded inputs and failure kill/reap. Current
capture-size checks happen after completion and do not bound live disk use.
The existing caller is not silently promoted to that contract: implementation and
fake APIs/process checks precede separate native approval. Source/SDK evidence
and the proposed contract remain private. No verifier/daemon, signature/trust API,
build/signing, Apple request, SSH/Ansible, install or VM operation occurs; shared
package source/pins are unchanged. See the manager runbook's Bounded native
inspection preparation section. Broad real-Ansible tests remain skipped.

### Offline inspection adapter — fake APIs/workers, 4 November 2026

The manager implements a distinct typed one-shot offline review/authorization
domain with default denial before IO. It binds source/scope/selection, public
certificate, implementation, entitlement sources and output. Injected API policy
guards CMS before native decoding, requires locked status, releases references
and performs static validation with explicit no-network flags and exact signing
policy. No runtime/daemon is executed and fake receipts grant no signing/guest
authority. The injected supervisor monitors 300-second whole-job/120-second
worker budgets and live 2 MiB stream caps, with group kill/reap/close and refusal
on descendants, unconfirmed cleanup, mutation or replay.

Thirty-two new manager fake tests pass; the full allowed Python suite has 178
passes/five signing skips (183 discovered). Only local Git/Python processes are
observed, with no forbidden-tool attempt. All 1,161 retained private entries and
pins remain unchanged. No real native API binding/factory/activation CLI is
supplied: concrete bindings and fake FFI/process checks precede separate native
approval. Virtual tests do not establish native process/IO behavior; parent
filesystem reads are checked at budget boundaries. No actual materials/keychain,
native inspection, signing, Apple request, SSH/Ansible, install, UI, image or VM
operation occurs. Shared package source/pins and product approval are unchanged.
See the manager runbook's Offline inspection adapter section; broad Ansible
targets remain skipped.

### Concrete offline inspection bindings — 4 November 2026

The manager now provides lazy closed-symbol macOS bindings and an explicitly
authorized bounded worker factory. Content-only CMS, public certificate/status
and no-network static checks retain CF ownership/type/size guards. Anonymous
parent/task pipes bind implementation and fake/native mode; nonblocking streams
retain live bounds. Root PID ownership remains held through group quiescence,
including a Darwin waitid binding for system Python. Missing ownership or failed
cleanup refuses and retains actionable handles. Filter-free Git metadata/raw
worktree checks avoid executing configured clean filters. Defaults remain denied;
all new modules enter the implementation digest rather than changing frozen pins.

Thirty-three fake FFI/process tests include a complete synthetic roundtrip through
the concrete code. The full allowed Python suite has 211 passes/five signing skips
(216 discovered), only Git/Python programs and no forbidden tool or inspection
library attempt. All 1,161 private entries and historical reviews remain unchanged.
No actual API/worker/material/keychain inspection, signing, Apple request,
SSH/Ansible, install, UI, image or VM operation occurs. Shared package/product code
is unchanged. Fresh implementation review and separate native approval precede
real API/ABI, group/wait, scheduling/cleanup/crash and validation evidence. See the
manager runbook's macOS bindings and bounded launcher section; real-Ansible
targets remain skipped.

### Fresh private review for ddf5451 — 4 November 2026

The manager prepares a new ignored 0700/0600 inspection review binding committed
tooling and 14-file implementation, existing source/scope/selection/runtime,
public leaf/entitlement hashes and an uncreated output. No approval, authorization,
worker/factory or native API is activated. Historical records/pins stay unchanged.
Stored fake/source evidence, dependency HEADs and entitlement hashes match;
external material/keychain state and full source cleanliness are not refreshed.
All 1,161 previous artifact entries stay in place. A credential-named retained
artifact remains unopened with prior digest/stable metadata, not a new content
validation. Exact values stay private. No tests, real inspection, signing, Apple
requests, SSH/Ansible, installs, UI, VM-root observation or VM operations occur.
Separate exact-packet approval precedes execution-time revalidation and bounded
native work. Product/shared code is unchanged and ordinary approval remains nil.
See the manager runbook's Fresh private inspection review for ddf5451 section.

### Approved inspection pre-native stop — 5 November 2026

The user approved the exact manager `ddf5451` read-only review. An additional
one-off composition audit guard incorrectly denied Python's `/dev/null` `O_RDWR`
open for disabled Git stdin, before any subprocess, worker, native authority/caller,
API or external material access. The inspection output is absent; no profile,
keychain or signature result is claimed. Review checksums and noncredential
artifact bytes/modes/links match; all 1,161 old entries remain present. Retained
credential-named content stays unopened, without a fresh content claim. Pins and
product/shared source remain unchanged. Ten fake audit-event cases validate an
unused narrow guard correction. The attempt is consumed without retry; corrected
fresh review and separate approval precede another attempt. No signing,
private-key access, Apple requests, SSH/Ansible, installs, UI or VM operations
occur. See the manager runbook's Approved inspection attempt stopped before native
work section.

### Corrected fresh private inspection review — 5 November 2026

The manager prepares a distinct private request/output binding the unchanged
`ddf5451` implementation and frozen inputs to exact corrected guard/review hashes.
Only a literal `/dev/null` `O_RDWR` open with optional `O_CLOEXEC` is newly allowed.
Twenty-two fake audit/helper cases pass. No guard, authority, caller, worker or
native API is activated. Fourteen committed files, pure input admission, dependency
HEADs and entitlement hashes match; full source cleanliness is deferred. All 1,170
existing artifact entries, original review, failure evidence and consumed marker
remain unchanged. Credential-named content stays unopened; external material and
lock observations remain historical. Both outputs are absent, all new approvals
false, and separate approval must name the fresh review and corrected guard.
No inspection, signing, private-key access, Apple requests, SSH/Ansible, installs,
UI or VM operations occur; product/shared source and ordinary approval remain
unchanged. See the manager runbook's Corrected fresh private inspection review
section.

### Corrected native inspection partial result — 5 November 2026

The approved corrected manager review runs once with exact `ddf5451` code/guard
bindings. Both dependency checks, locked keychain status, profile content/policy
and public-certificate membership pass. The fifth worker fails at public-
certificate parsing after about 12 seconds; the generic worker error does not
establish its native cause. Runtime signatures and final checks are not reached.
The runner retains cleanup=false with zero unresolved factory handles. A bounded
exact-parent/worker snapshot observes no survivors; the snapshot's initial sandbox
denial is resolved for cleanup only, without retrying inspection. That observation
does not override the failed cleanup receipt. All 1,182 old artifact entries and
frozen pins remain unchanged; retained credential content stays unopened and new
staged public files/failure evidence remain private. Five fake cases reproduce
possible type/cleanup failures only. Next, combine fixed diagnostics, per-handle
cleanup evidence and typed certificate dates in one fake-only change with fresh
review. No source/product approval changes, signing, private-key access, Apple
requests, SSH/Ansible, installs, UI or VM operations occur. See the manager
runbook's Corrected native inspection result section.

### Inspection diagnostics, cleanup evidence and typed dates — 5 November 2026

The manager implements closed mode-proven worker failure code/phase records,
private per-worker exit/categorized cleanup and held-handle evidence, and retained
macOS 15 typed certificate date getters with strict validation/releases. Cleanup
errors stay latched false despite later successful fallback; observed quiet roots
are reaped without redundant signals. Live/unproven groups retain kill/reap.
Twelve new fake FFI/process tests pass; the full allowed Python suite has 223
passes/five signing skips (228 discovered), only local Git/Python processes and no
native-library attempt. A fresh private review binds the exact uncommitted 14-file
implementation, 17-file source/test snapshot/base patch, corrected guard and new
request/output. All 1,191 old artifact entries, frozen pins and failed receipts are
unchanged; credential content stays unopened and external material/lock evidence
remains historical. Fresh output is absent, all new approvals false and no real
inspection/authority is activated. Prior native causes and actual new behavior
remain unproven. No shared/product code or approval change, signing, private-key
access, Apple request, SSH/Ansible, install, UI or VM operation occurs. See the
manager runbook's Diagnostic and date hardening section.

### Native offline inspection passed — 5 November 2026

Manager `df8b75e` / companion docs `a8a8ba4` commit the reviewed change. The approved
fresh inspection matches all 17 source/test snapshot files to committed/current
bytes and completes in 64.18 seconds: before/after source and locked-keychain
checks, profile/public-leaf policy, certificate name/dates and all 23 static code
checks pass. The offline-only receipt uses explicit no-network validation and
executes no runtime code. All 31 workers are reaped after group quietness with
closed descriptors and no diagnostics/cleanup errors or unresolved handles; a
bounded snapshot of their recorded PIDs finds no survivors. All 1,204 previous
artifact entries, pins, reviews and failed receipts stay unchanged. Credential
content remains unopened; private evidence records the new commit without
rewriting the preparation-time review. Product/shared code and approval remain
unchanged. Private-key availability, CMS signer authenticity, standalone
certificate trust, revocation/notarization, daemon/loaded-child and guest proof
remain unestablished; earlier failure causes remain unknown. No signing,
private-key access, Apple request, SSH/Ansible, install, UI or VM operation occurs.
Milestone 6 remains incomplete and signing/guest actions need separate approval.
See the manager runbook's Native offline inspection passed section.

### Signed-candidate review prepared — 5 November 2026

After native-result doc commits `740fd81` / `7d8d907`, the manager prepares a
private review binding the passed offline inspection, matching staged public
material, frozen source/scope/runtime, current tooling and absent app/ZIP output.
It is not executable: receipt/implementation/output-bound signing admission,
live-cap/shared-budget/owned-cleanup supervision and replacement or separate
review of legacy profile/daemon verification remain. Key availability is unqueried;
selected-key/secure-UI and Apple timestamp approvals are ungranted. Touch ID is
preferred only if already supported, without inferred ACL/permission changes.
Notarization, original-Mac/loaded-child and guest acceptance stay separate. All
1,239 old artifact entries and pins remain unchanged, retained credential content
stays unopened and original signing materials/keychain are not reopened or stat-
checked. No authority, caller, runner, signer or output is activated; no native
inspection, build, signing, private-key access, Apple request, SSH/Ansible,
install, UI or VM operation occurs. Next combine signing admission/runner/
inspection hardening, fake tests and fresh review. Product/shared source and
approval remain unchanged. See the manager runbook's Signed-candidate review
after offline inspection section.

### Receipt-bound candidate path — 5 November 2026

Manager tooling implements one-shot receipt/current-code/material/output admission,
bounded supervision and replacement of legacy profile/daemon/app verification.
Older real dispatch is disabled. The new route uses no-network capability workers
for exact signing identity/entitlements/timestamp/CDHash/public-leaf policy, with
original source/scope/runtime and child-sign/seal/outer-sign/roundtrip checks.
Shared 2,400-second budget, 1,200-second build / 120-second other stages and live
2 MiB streams retain owned group/reap/descriptor evidence and unresolved holds.
Exact command policy rejects original-checkout and arbitrary program/flag changes.
Parent IO remains budget-checked at callbacks. Twenty new fake tests pass; full
suite 243 passes/five signing skips (248 discovered), only Git/Python and no native
library attempt. Fresh private review binds an uncommitted sixteen-file code and
24-file source/test/Makefile snapshot. All 1,251 original artifact entries, pins
and receipts/reviews are preserved, including interim preparation evidence.
Credential content stays unopened; original signing materials/keychain are not
refreshed. Build/inspect/key-use/necessary secure-UI/Apple-timestamp effects remain
ungranted; operator keychain preparation/relock may be needed and no automatic
unlock/ACL change is added. Output absent; no real authority/inspection/signing,
private-key access, Apple request, SSH/Ansible, install, UI or VM operation occurs.
Real signing/native behavior and later original-Mac/loaded-child/notarization/
guest acceptance remain unproven; product/shared code and approval stay unchanged.
See the manager runbook's Receipt-bound signing path section.

### First reviewed candidate attempt stopped — 5 November 2026

The user approves the exact committed manager `27c672f` / companion `92593c9`
candidate run with selected-key/secure-UI/Apple-timestamp effects. Source/receipt/
material and snapshot bindings pass, as do certificate, overlay and pinned local
dependency checks. Frozen provisioning-source preparation exits 1 after 125.283
seconds, before compilation, runtime validation, app/archive assembly or signing.
No key, secure UI or timestamp request is reached. The exact cause is unknown;
only exit/stream counts are retained. Read-only source/mode/patch/syntax checks
pass without replay. All nine command roots and three validation workers reap
after group quietness with closed descriptors, no pending handles and no recorded
PID survivors in a bounded snapshot. All 1,279 old artifact entries and pins stay
unchanged; credential content is unopened and keychain state is not refreshed or
changed. The consumed request is not retried or transferred. Next combine actual
frozen-helper fake/local-fixture coverage, fixed bounded failure diagnostics and
fresh review. Real signing/candidate and later original-Mac/loaded-child/guest
proof remain unestablished. No notarization, SSH/Ansible, installs, app/runtime
execution or VM operations occur; product/shared code and approval stay unchanged.
See the manager runbook's First reviewed candidate attempt section.

### Frozen-helper fixtures and safe diagnostics — 5 November 2026

Prior failed-run docs are committed as manager `d3d70ab` / companion `09b396b`.
The manager now tests the exact retained frozen helper with unchanged public
package inputs. Local Git/Python fixtures reproduce a patch-base mismatch beneath
an ignored nested checkout; an exact private-output Git discovery ceiling fixes
that case without changing pins. The historical error's exact cause stays unknown
because its raw stderr was not retained. This is fixture evidence, not a retry.

Failed quiet command roots drain bounded pipes to EOF before fixed phase/code
classification. No raw stderr/path/exception/output hash persists; partial/capped
streams remain incomplete and cleanup retention is unchanged. Thirteen new cases;
full audited manager Python suite: 256 passes, five signing/PKCS12 skips, Git/Python
child programs only and no native-library attempts. Companion/shared Swift code
and pins are unchanged, so no Ansible-bearing companion workflow is run.

A fresh private review binds seventeen implementation files and an exact 28-file
uncommitted snapshot against manager `d3d70ab`, an independent historical offline
receipt and unchanged frozen pins. All execution effects remain NOT_GRANTED and
new output absent. All 3,987 earlier artifact entries and failed outputs remain
intact; retained credential content is unopened and external keychain unqueried.
No real inspection, build, signing, key access, Apple request, SSH/Ansible, install,
UI or VM operation occurs. Commit before considering a separately approved new
attempt; real compiler/signing/candidate and guest behavior remain unproven.
See the manager runbook's Frozen helper and safe failure diagnostics section.

### Fresh candidate compiled; resource assembly refused — 5 November 2026

The user approves the exact fresh manager `31f0bd7` / companion `3a7285b` private
candidate run with selected key, secure UI and Apple timestamps. The 28 reviewed
files and implementation digest match at preflight. Frozen-helper preparation,
23 runtime static checks, certificate/dependency validation, release compilation
and binary/scope-marker checks pass. Twelve commands and thirty native workers
succeed. Assembly stops at 447.472 seconds with `input-inventory-changed`: fresh
provisioning bundle payload equals the frozen reference, whose four inherited
signature records are absent from build output. Core resources match. Retained
files establish the mismatch; no command failed and no frozen input is rewritten.

All 42 owned roots/workers have confirmed cleanup and are absent from a bounded
recorded-PID snapshot. All 4,002 prior artifact entries/pins remain unchanged;
credential content is unopened, external keychain admission is metadata-only and
lock state is unqueried. Partial assembly and build outputs remain private. No
signing/key/UI/timestamp stage, success receipt or signed archive is reached. No
notarization, SSH/Ansible, install, app/runtime execution or VM operation occurs;
product/shared code and approval stay unchanged. Concurrent unrelated manager CLI
edits are preserved. The request is consumed without retry/approval transfer.
Next combine compiled-vs-frozen resource/signature fixtures, narrow assembly/final
seal validation and a fresh review, keeping generic inventories and pins intact.
Real signing/candidate/guest proof remains unestablished. See the manager runbook's
Fresh candidate attempt section.

### Resource payload/signature admission and fresh review — 5 November 2026

Result docs are committed as manager `12247e2` / companion `ff2c82d`. The manager
now admits exact frozen provisioning payload/wrapper bytes separately from the
complete known four-file inherited signature block (or none). Resources also match
the package lock; built signatures, partial/unknown reference blocks, changed or
extra/missing payload/wrappers and unsafe entries refuse. Generic inventories and
pins are unchanged. Payload is rechecked before outer signing and staged/roundtrip
verification; child digest seal, outer/static verification and archive equality
remain required. Old signature records are not current cryptographic authority.

Fourteen new fake/local cases; full audited manager Python suite has 291 passes,
five signing/PKCS12 skips (296 discovered), Git/Python only, no native-library
attempts. Signed-reference/unsigned-build receipt/operator fixtures and fake sealed
archive roundtrip pass. Retained bytes compare as 45 exact payload files plus four
old reference signature records; no build or native inspection is rerun.

Fresh private review binds seventeen engine files, separate operator code and a
32-file exact uncommitted snapshot against `12247e2`. Maintained prepare/check
creates a new public-input-only plan; all effects remain NOT_GRANTED, no backend
or authority is constructed, and candidate output/consumed marker are absent.
All 8,691 previous private entries/pins and failure artifacts remain unchanged.
Credential content stays unopened, originals/keychain unqueried, no scope root
observed/recaptured and product/shared code/approval unchanged. No real inspection,
signing, key access, Apple request, SSH/Ansible, install, UI or app/runtime/VM action
occurs. Commit before separately approving a new run with fresh confirmation;
real final resource/signature/candidate/guest proof remains TO PROVE. See the manager
runbook's Resource payload admission section. No Ansible-bearing companion workflow
is run for this documentation-only change.

### Maintained operator run — first signing timeout, 5 November 2026

**LATEST USER CLARIFICATION:** the operator says “I missed the prompt.” This
supports a missed secure-UI response as the explanation for the signing timeout;
it does not independently prove key use or timestamp success/failure. Keep the
earlier completed-dialog report and automated evidence as historical records;
exact dialog type/timing is not reconstructed. The plan remains consumed.

**USER-REPORTED FOLLOW-UP:** the operator reports completing a macOS secure-key/
keychain dialog. Exact dialog type and timing relative to the timeout are unknown;
key use, timestamps and timeout cause remain unproven. This separate observation
supplements unchanged automated evidence and authorizes no retry/native/key action.

The user approves the fresh manager `b3171b0` / companion `9d3b4b6` plan with
selected-key/secure-UI/Apple-timestamp effects. The 32-file snapshot and engine/
operator/plan bindings pass. Maintained CLI real-terminal exact-plan confirmation,
recheck and durable consumption precede the default backend. Frozen preparation,
23 runtime checks, public certificate/dependencies, release build, compiled scope
and corrected 45-file payload assembly pass; the 49-file reference is unchanged.

The first selected signing command reaches its 120-second limit and is killed/
reaped (-9). Total audited elapsed 715.494 seconds, CLI exit 1, plan consumed with
no retry. All 43 command/native roots have quiet groups/closed descriptors/no
pending handles and are absent from a bounded recorded-PID snapshot. All 8,713 old
artifact entries/pins/reviews/audits are preserved; failed output and new consumed/
attempt records remain private. Retained credential content stays unopened; selected
keychain admission is metadata-only, lock state unqueried. No automatic unlock/
relock/import/export/enumeration/ACL/search-list change or scope recapture occurs.

Storage-helper bytes match compiled input. Incomplete stderr (274 bytes) is not
retained raw; actual key use, secure UI display/response and timestamp outcome
are unestablished. The exact wait cause stays unknown. No later signing/final app
validation/seal/archive/success receipt, notarization, SSH/Ansible, install, app/
runtime/VM operation or product/shared approval change occurs. Next collect
operator UI observations and review key readiness versus timestamp connectivity
before a new plan and fresh explicit approval. No further native/key operation or
retry is performed here. See the manager runbook's First maintained operator run.

### Read-only readiness after missed prompt — 5 November 2026

Result/observation docs are committed as manager `f67c5e4` / companion `b260d8f`.
The operator reports missing the prompt; source confirms the 120-second signing
deadline includes secure-UI waiting. That supports the timeout explanation without
proving a timestamp-service failure. No network/timestamp diagnostic is run.

One network/file-write-denied worker with optional UI disabled checks only the
named keychain reference/status and staged public-certificate metadata. Status is
7/unlocked before/after; public selector/digest/date validity and reviewed-profile
membership/policy match. It completes in 0.218 seconds under a 15-second/4-KiB-stream
bound with references released, owned root group-quiet/reaped/closed and recorded
PID absent. All 13,565 old artifact entries/pins and failed/consumed records remain
unchanged; keychain metadata and unlocked state stay as found. No private-key/
identity/item, trust/signing/timestamp or unlock/ACL/search-list operation occurs.

Container/public readiness is established; private-key presence/association/ACL,
Touch ID and actual signing/timestamps remain unproven. No new signing, private-key
access, Apple request, SSH/Ansible, install, UI/app/runtime/VM operation, source/
product approval change or scope recapture occurs. The plan remains consumed;
a new attended attempt needs a distinct plan and fresh approval. No retry/new plan
is prepared here. See the manager runbook's Read-only signing readiness diagnosis.

### Attended private signing passed — 5 November 2026

The fresh attended plan after manager `b72eadf` / companion `90e2459` succeeds via
maintained CLI real-terminal exact-plan confirmation, durable consumption and its
default bounded backend. The 32 committed files and frozen bindings match. All
seventeen commands and 46 native workers pass in 926.436 seconds. Four child/outer
selected-key signatures with Apple timestamps pass offline staged and extracted
checks for exact public leaf, IDs/team, hardened flags, entitlements and timestamps;
all six code identities, full app tree, post-child-sign seal and 45 resource files
survive archive roundtrip. The private ZIP is 172,869,773 bytes with matching receipt
digest; all 49 frozen reference files remain unchanged.

All 63 roots/workers have quiet groups/reap/closed descriptors/no pending handles
and are absent in a bounded recorded-PID snapshot. All 13,570 old artifact entries/
pins, failed output, consumed plans and audits are preserved. No export/import/
enumeration, orchestrator unlock/relock/ACL/search-list change, scope recapture or
product/shared approval change. The plan stays consumed without retry. No new
notarization, publishing, SSH/Ansible, install or app/daemon/runtime/VM execution.
UI method/prompt count and post-run lock state are not captured. Result is signed/
offline-static only: original-Mac scope, loaded-child and guest acceptance remain
TO PROVE under separate reviewed consent. See the manager runbook's Attended
private signing passed section.

### Fresh private merged-source review — 5 November 2026

The manager's new private review binds committed `4a0f30a` and updated runtime
source `d6dd3dbe860f`, using a matching existing local signed-runtime artifact from
stable `v0.11.1`. Archive/lock/inventory and permitted-payload checks are local file
data, not fresh native signature/trust/notarization proof. The original Stable
disposable scope definition/JSON/receipt and all old pins stay verbatim; next is
the manager's merge target, not a scope/channel migration. Shared package code,
resources and pins are unchanged.

Source-only admission, independent private-overlay reconstruction, 25 packet/refusal
checks and 170 fake API/process tests pass. A committed 32-file tooling snapshot,
seventeen-file engine digest, operator, corrected guard and named public-material
copies bind a fresh bounded-inspection request. The old receipt, even with
relabeled review fields, cannot transfer to this source/runtime. Existing private
artifacts, successful/failed outputs and consumed plans remain unchanged.

The new native inspection is prepared, not run; current keychain state and key
availability are unqueried. No authority, native inspection output, signing operator
plan or candidate build is created. All execution effects remain NOT_GRANTED; a
new successful exact-input inspection receipt and separate approval are prerequisites
for a new attended signing plan. No signing, key access, Apple request, SSH/Ansible,
install, normal app/UI/runtime action or VM launch occurs. See the manager runbook's
Fresh private candidate review for 4a0f30a section. Private packets/paths/pins remain
out of both repositories.

### Fresh 4a0f30a native inspection passed — 5 November 2026

Preparation docs are committed as manager `e04f20a` / companion `f51fc47`. The user
approves the exact fresh merged-source review's bounded read-only native inspection.
Its 173 sealed files, 32 committed tooling files, seventeen-file engine and corrected
guard/composition match. The exact in-memory inspection-only authority consumes
the request once; old approvals/receipts are not replayed.

All 31 workers pass in 77.816 seconds: pinned dependency/source checks, interaction-
disabled locked-before/after named-keychain status with unchanged metadata, public
profile policy/leaf membership/certificate identity/typed dates, and 23 no-network
static checks over 22 runtime Mach-O files plus the bundle. All owned groups are
quiet, roots reaped and descriptors closed; no unresolved handles and no recorded
roots remain in a bounded PID-only snapshot. All 18,881 old private entries, sealed
review/pins, prior successful/failed outputs and consumed plans remain unchanged.
Source admission and 173 sealed review hashes independently revalidate. The original
Stable disposable scope, product approval and shared package/code/pins are unchanged.

Result is OFFLINE_STATIC_INSPECTION_ONLY. CMS signer authenticity, certificate trust,
online revocation/fresh notarization, private-key availability, original-Mac scope,
loaded-child and guest acceptance remain unproven. The request stays consumed with
no retry. A fresh attended signing plan may now be prepared from this new receipt;
actual build/sign/key/secure UI/timestamps need separate approval. No signing plan
or candidate build, signing, private-key access, Apple request, SSH/Ansible, install,
UI/app/runtime or VM action occurs. See the manager runbook's Fresh 4a0f30a native
inspection passed section. Raw evidence and pins remain private.

### Fresh 4a0f30a attended signing plan prepared — 5 November 2026

After manager `28b758c` / companion `7b8fcb2` record the successful new inspection,
the maintained private operator prepares/checks a distinct attended plan for
`4a0f30a`, the updated runtime and original Stable disposable scope. It binds the
new receipt/request/implementation and exact staged public material/selector/code
inputs; 32 committed tooling files, seventeen engine files and 173 sealed review
files remain exact. Shared package/product code and pins are unchanged.

Fourteen actual-plan data/refusal checks and 44 fake API/process tests pass without
actual child processes or native-library attempts. All 18,916 prior private entries,
old/new receipts, signed/failed outputs, consumed plans and pins remain unchanged.
Original signing-material/keychain metadata and content are unqueried. The plan is
CHECKED_PUBLIC_INPUTS_ONLY; all five proposed effects remain NOT_GRANTED. No real
authority/backend, candidate output, consumed marker or attempt record exists.

Private attendance notes specify exact-plan real-terminal confirmation, a quoted
CLI command, prompt handling with UI wait inside the 120-second signing limit,
bounded cleanup and no retry. Actual selected-key use/secure UI/Apple timestamps
require separate approval; current key availability and Touch ID method are not
established. No build, native inspection, signing, private-key access, Apple
request, SSH/Ansible, install, normal app/runtime or VM action occurs. Private data/
pins stay out of Git. Documentation is updated in both worktrees without committing
this preparation; see the manager runbook's Fresh 4a0f30a attended signing plan.

### Attended 4a0f30a run — first-signing timeout, 5 November 2026

Preparation docs commit as manager `5a902cd` / companion `292da85`. The user approves
the fresh plan with selected-key use, secure UI and Apple timestamps and says
they will watch for the prompt. Exact sealed source/plan/receipt/code bindings and 32 committed
tooling files match; maintained CLI real-terminal confirmation consumes the plan
before its bounded default backend. All twelve preparation/build/location commands
and thirty pre-sign native workers pass, including 23 runtime checks. The staged
45-file resource payload matches; shared package/code/pins remain unchanged.

The first storage-helper signature reaches its 120-second deadline and the owned
process group is killed/reaped/closed. Audited elapsed is 752.079 seconds, CLI exit 1.
Staged helper bytes equal compiled input; no later signing/final validation/archive
or success receipt is reached. Incomplete 248-byte stderr permits only fixed
sign/incomplete-output diagnostics. Key use, secure UI display/response and Apple
timestamp outcome/cause are not established; the operator's prompt observation
is pending. No native/key/network diagnosis, state change, retry or new plan occurs.

All 43 command/native roots have quiet groups, reap/closed descriptors and zero
unresolved handles, and are absent in a bounded PID-only snapshot. All 18,928 prior
private entries/reviews/plans/receipts/failed outputs and frozen pins are unchanged;
only approved new output/consumption/attempt evidence is added privately. No export/
import/enumeration, orchestrator unlock/relock/ACL/search-list change, scope
observation/recapture or ordinary approval change occurs. No notarization, SSH/
Ansible, installs, publication, normal app/UI/runtime or VM action occurs. The plan
remains consumed; actual signed completion and original-Mac/loaded-child/guest
acceptance remain unproven. See the manager runbook's Attended 4a0f30a run result.

**Operator follow-up:** the user reports completing the macOS dialog for the
4a0f30a attempt. Exact dialog type and timing relative to the 120-second limit are
unrecorded; this does not establish key/ACL/timestamp outcome or timeout cause. The
automated stopped/unchanged-helper evidence and consumed plan remain unchanged.
No retry, new plan or additional native/key/network operation follows.

### Main merged into the Swift package branch — 5 November 2026

Merge `origin/main` at `c30f213` into `codex/swift-provisioning-package`, whose
previous head is `41bbfe3` (51 branch commits ahead and three main commits behind).
The merge applies without conflicts. It brings the manager 0.11 lean-factory
compatibility/import contract, reviewed integration package and three additional
repository layout examples, with their validation records. Shared Swift sources
and the four bundled Swift layout cards are unchanged; the new Lua examples do
not automatically expand that catalogue.

Offline/local validation passes:

- All 86 Swift tests pass serially, including disposable local process/PTY fixtures
  and fake SSH/Ansible runners. Two PTY cases time out inside the filesystem sandbox,
  including on a serial retry; the serial run outside that sandbox passes without
  changing test deadlines or implementation.
- The existing `make test-omarchy` suite discovers 239 tests: 228 pass and eleven
  skip. A private runner excludes ten tests that execute actual Ansible, and one
  Lua test skips because its interpreter is unavailable. Python uses the already
  installed Homebrew Ansible environment's interpreter/PyYAML, without executing
  Ansible or installing anything. Local shell fixtures and dry-run Make checks
  use fake services; no real manager/guest operations run.
- The parser oracle passes 18 plain-data fixtures, and the planning oracle passes
  66 complete proposal/error fixtures. SwiftPM uses existing local dependencies,
  with updates and automatic dependency resolution disabled.
- All five incoming Python files parse, the incoming shell file passes `bash -n`,
  and the Git whitespace check passes. New Lua sources are read but Lua syntax/
  execution is untested. Ansible syntax checks are excluded by the user's scope;
  the merge introduces no YAML changes.

The before/after private inventory matches all 23,951 entries, and all four manager
frozen-pin files remain byte-identical. Credential/disk-image contents are not
opened by that inventory. The manager worktree, vendored package and existing
private candidate inputs/outputs/receipts/consumed plans stay unchanged; their
earlier source bindings do not transfer to this merge. A manager package refresh
or expanded Swift layout catalogue requires a separate change.

No signing, key access, native inspection, Apple request, real SSH/Ansible, install,
container/image build, normal app/runtime action or VM launch occurs. This record
establishes offline/fake validation only, not guest or signed-candidate acceptance.
