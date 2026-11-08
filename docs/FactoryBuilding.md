# Build a lean factory in Dev

The **Factory images** sidebar page builds a reusable lean Omarchy foundation.
**New VM → Build lean factory…** opens the same flow without discarding the fields
already entered. After independent verification/import, **Use for new VM** selects
the resulting factory. Building never creates a VM, changes an existing disk or
launches a guest. Official and previously imported factories remain available.

Choose a name, an **Omarchy channel** and, under **Advanced**, a capacity from
20–128 GiB. **Stable** (the default) installs the latest Omarchy release;
**Edge** installs Omarchy's development builds. Either way the build uses the
channel's current signed packages, so a new Omarchy release needs no new app.
If a release changes setup programs this app hasn't reviewed, the build stops
before creating a disk and says so; update Omarchy VM Manager or try the other
channel. The reviewed
recipe supplies the desktop, Mac integration, Git, Python and build tools inside
the image. Additional profiles, apps, themes and layouts are selected per VM.
Arbitrary build scripts, package editors and source repositories are outside this
first native flow.

## Removing factories and old builds

On **Factory images**, each custom factory card has a trash button. **Move to
Trash** moves the factory and its import record to the macOS Trash together, so
it can be restored. A factory used by a VM can't be moved; its card lists those
VMs. The official factory can't be removed.

Each build keeps its output (about 3 GB for a 20 GiB factory) after its factory
is added to the library. Under **Build history**, **Remove** moves one finished,
failed or cancelled build's files to Trash and drops it from history; **Remove
finished builds** does this for all of them. Running builds and builds that still
need cleanup are kept. Removing a build never removes its factory. The shared
download and package caches are kept to speed up later builds.

## Readiness and the build action

Factory building is compiled into the Dev channel. Stable can continue importing
compatible bundles but cannot start a build. There is no environment or command
flag to override that gate.

The Mac needs Apple Silicon and an already installed Docker CLI with a running
ARM64 Linux engine exposed through a local Unix socket. Readiness checks install
nothing and reject remote engines. They verify the pinned embedded runtime,
reviewed recipe, CLI identity, engine identity and available artifact storage.
Factory host tools admit executables up to 128 MiB, including Docker Desktop's
larger CLI. SHA-256 verification reads 1 MiB chunks and still rechecks symlinks,
file metadata and permissions around execution. SSH/Ansible retain their 32 MiB
limit. Readiness inspects only context metadata and local engine information;
passing it authorizes no Docker build or resource mutation.
The initial floor is image capacity + 4 GiB on the artifact volume; Docker needs
at least 3 GiB scratch capacity separately. Package caches and live repository
contents may require more. Before preparation/import, the manager checks space
again against twice the actual compressed image size plus 64 MiB. Failure retains
the finished output and does not publish an import.

**Build factory** authorizes downloading the pinned Node payload and the
selected channel's signed Omarchy and Arch Linux ARM packages, and running
an owned privileged Linux build container. Readiness or editing fields never
starts a build. There is no additional review button or approval checkbox.
Downloads have HTTPS host/redirect, size, time and checksum limits. Mac Python,
Git and Ansible are not required for this host-controller path; the existing
Linux recipe continues using its own Bash/Python/package tools inside Docker.
Arch repositories remain live: this is source/provenance binding, not a promise
of byte-identical rebuilds.

The build continues while navigating elsewhere in Dev. Its native 120 × 30
terminal follows output by default and displays bounded live process output.
It is noninteractive: this fixed image recipe takes no account passwords or
terminal input. Job history stores typed metadata, not terminal output. History
survives app restart; terminal scrollback does not. History is bounded to 128
jobs; this first version does not automatically prune retained build artifacts. Quit offers cancellation and
waits for process/resource cleanup before continuing.

## Ownership, interruption and library admission

On `codex/factory-image-builder`, the active package is pinned to companion
`codex/swift-factory-builder` revision `5d0abc3`, with the checksum-pinned
`dev-vm-factory-executable-size.patch` integration fix. These follow the previously tested
provisioning branches. Draft publication runs only the bounded test paths below.

One shared service serializes UI and CLI work with a private filesystem lock.
Readiness previews are ephemeral and consumed once. A repeated start request for
the same preview returns that job rather than repeating execution. The CLI and
local engine identities are rechecked before mutations; inherited Docker/Buildx
environment overrides are excluded.

Builds use new UUID-derived containers and volumes with an ownership label.
A container is created stopped, acknowledged and then started by immutable ID.
Cleanup finds the labeled container even if renamed, verifies ID/label and
removes only that container and the owned volume. It never prunes Docker or
removes unrelated containers, images or volumes. Builder images and package/
download caches are retained. A lost creation acknowledgement or unconfirmed
cleanup blocks new builds. **Verify and clean up owned resources** only performs
cleanup; it never resumes a build or imports retained output. A crash changes an
in-progress journal entry to cleanup-required on reload.

The Swift controller consumes the checksum-pinned export of dev-vm's maintained
Linux staging recipe. Offline release preparation compares all 162 staged files
against that oracle. Container exit success is followed by independent checks of
image size/checksum, package archive identity, owner setup evidence and runtime
compatibility, then the existing format-2 factory catalog import path. The
original reviewed guest package remains distinct from the host runtime pin.

## CLI

Use the CLI inside the matching Dev app bundle while that app is open. These
commands do not open an installed app automatically:

```sh
omarchy-vm factory-build plan --name 'Lean development' --size-gib 20 --channel stable
omarchy-vm factory-build start REVIEW_UUID
omarchy-vm factory-build status JOB_UUID
omarchy-vm factory-build logs JOB_UUID --follow
omarchy-vm factory-build cancel JOB_UUID
omarchy-vm factory-build cleanup JOB_UUID
```

`plan` checks readiness and returns a preview UUID. `--channel` is `stable`
(default) or `edge`. `start` is the deliberate build
action. Closing `logs --follow` leaves the job running. Commands cannot select a
host endpoint, private root, custom recipe or privileged command. Stable and Dev
use their existing separate same-user command sockets and storage.

## Validation and limits

**VERIFIED — fake/local:** the shared package passes 92 Swift tests and offline
staging parity. Manager service tests cover consumed previews, duplicate starts,
readiness drift, cancellation, cross-controller locking, cleanup recovery,
strict wire parsing and the compiled Stable gate. A disposable same-user command
socket exercises CLI plan/start/logs and a specific readiness error through the
same controller, with zero guest starts. Synthetic artifact tests cover
independent catalog admission and refusal of damaged images/packages, owner
mismatch, unsupported boot claims, size mismatch and runtime mismatch. Offscreen
native UI acceptance exercises both appearances, the build sheet, readiness,
explicit start, all progress stages, terminal, library handoff, New VM selection
and cleanup with zero Docker commands and zero runtime starts. Full regression
passes cover 539 Swift tests per channel and 337 script cases; the final focused
pass includes the command socket and extraction of the actual bundled recipe
(27 tests across four suites). Run `make test-factory-build`
for focused Dev contracts, `make test-factory-screens` for native offscreen
acceptance, and `make test` / `make test-dev` for full regression suites.

**TO PROVE:** real downloads, Docker disk-space behavior, privileged mounts/loop
devices, full image creation, real output admission, cancellation/recovery against
a real engine, and disposable-guest first boot/account setup/graphics. “Built and
checked” is separate from “boot tested.” No real download/build, VM operation,
install, signing identity, Apple request or installed-app interaction is part of
this implementation pass. Existing private artifacts and frozen candidate pins
are preserved; the active public dev-vm source pin advances explicitly.

### Consolidated local result — 6 November 2026

- Companion `make check-factory-resources test-provisioning`: 162 oracle-matched
  inputs and 92 Swift tests, using fake Docker and disposable local processes.
- Manager `make test`: 539 Swift tests in 72 suites, 337 script cases, relocated
  read-only bundle checks and 140 native Setup/New VM checks; all passed.
- `make test-dev`: 539 Swift tests in 72 suites. This full Dev pass preceded the
  final companion cleanup hardening/pin. After pinning `df5e2c8`,
  `make test-factory-build` passed 27 focused tests across four suites, including
  actual recipe extraction, CLI socket routing, cancellation and dependency gates.
- `make test-provisioning-bundle-dev`: relocated/read-only package, exact resource
  inventory, inherited authenticated IPC and compiled channel checks passed.
- `make test-factory-screens`: 32 checks and 12 PNGs in both appearances. All
  services were synthetic, with zero Docker commands and zero runtime starts.
- `make test-build-policies`: all four selected policy cases passed in each of
  optimized Stable, signed-prerelease Stable and signed-prerelease Dev. These are
  build configurations with fake admission tests, not real signing operations.
- Preservation audit: all 86,034 baseline private artifact entries and the other
  five configuration pins match. The active public provisioning lock advances
  explicitly; historical private candidate pins remain frozen.

These are local working-tree checks. Factory-branch hosted CI and real build/
guest acceptance have not run. Main, installed Dev and their VMs were untouched.

### Factory-branch CI boundary

For `codex/factory-image-builder`, PR events run manager, script,
offscreen UI, optimized-policy and upstream source checks. The managed-SSH job
is skipped for this branch because its synthetic fixture still builds and runs
a real Docker image. Release/signing jobs remain restricted to pushes to `next`
or `main`; no merge or release is authorized by draft publication.

The companion `codex/swift-factory-builder` branch runs Swift tests and offline
recipe parity using preinstalled Swift/Python. Its ordinary Ansible-install and
legacy validation job is skipped. Checkout and pinned source dependencies are
normal hosted test inputs; factory downloads/builds, software installation, real
signing and VM operations are outside these factory-branch runs. Initial publication kept source pin `df5e2c8`. The shared resource lookup repair
advances the active public source pin to `5d0abc3`, with shipped recipe bytes and
all private candidate pins unchanged.
Full SSH-container and legacy Ansible validation are not claimed by this CI pass.

### Hosted CI repairs — 6 November 2026

Both first complete factory runs reached their Swift suites, then failed factory
recipe lookup because CI's resourceURL already included a Resources directory.
The shared reader now uses Foundation's named-resource API, consistent with the
existing provisioning readers. Local tests cover flat/Contents bundle layouts,
missing metadata and damaged archives; all 93 shared Swift tests pass. The manager
consumes that exact source through its public pin. Recipe/archive checksums and
historical private candidate pins are unchanged.

Manager CI also exposed a terminal control race: a read dispatched before input
release could publish its older ownership state while release waited for the
read to finish. Release now clears local input state after the read becomes idle
and before sending the release command, with further polls/sends fenced. A
controlled read barrier reproduces the failure without the fix and passes with
the fix. It preserves strict immediate assertions and existing time/lease bounds;
it does not retry delivered input or cancel the setup job.

Local checks passed: 15 terminal/UI/CLI tests, 27 factory/dependency tests, and
8 package-export script tests. Hosted rerun results are tracked in the draft
[manager PR](https://github.com/reactive-org/omarchy-vm-manager/pull/11) and
[companion PR](https://github.com/reactive-org/dev-vm/pull/9). All tests use fake runtimes,
authenticated local terminal fixtures and disposable filesystem/process inputs.
The branch guards continue excluding Docker fixtures, installers and release/
signing jobs. Real factory and guest acceptance remain TO PROVE.

The next hosted run passed all 542 Swift tests in both Stable and Dev, the
relocated bundles and all 32 native factory UI checks, but its PNG wrapper still
assumed large Retina pixel dimensions for every component. Factory captures now
record their actual logical view bounds. The wrapper verifies component minimum
sizes and requires the PNG pixels to match those bounds at 1x or 2x backing
scale, including sheet layouts. Three unit tests accept both scales and reject
cropped, distorted or undersized captures. Functional checks are unchanged.

Factory-branch push events now skip the duplicate Mac test job; the PR event runs
the complete suite. Other branches, including normal `next`/`main` CI policy, are
unchanged. Hosted results for this follow-up are tracked in the PR. The active
public package pin remains `5d0abc3`; no frozen pins or recipe bytes change.

## Local executable-size repair and readiness — 6 November 2026

**VERIFIED — failure and fix:** local readiness rejected the 43,052,752-byte
Docker CLI before contacting its engine because the generic executable pin had a
32 MiB cap. The factory-specific 128 MiB policy now applies both when admitting
Docker and when the host process runner rechecks it. Hashing uses bounded chunks;
the default provisioning limit, permissions, symlinks, file stamps and repeated
hash verification remain enforced. The active export includes a checksum-pinned
source/test/engine-inventory patch over `5d0abc3`. No frozen candidate pin,
runtime pin or factory recipe/archive bytes are rewritten.

**VERIFIED — fake/local validation:** 97 shared Swift test functions, 542 Dev
manager tests and 340 script tests pass. New cases exercise 32 MiB and 128 MiB
boundaries, the observed Docker size, whole-file digest equality, changed bytes,
unsafe permissions, symlink retargeting and a large disposable shell script in
the actual host runner. All Docker build/download adapters in these tests are
fake. Initial sandbox runs could not bind fixture sockets/read volume capacity
and timed out two existing PTY fixtures; unchanged tests pass outside the sandbox
with unchanged deadlines.

**VERIFIED — bounded read-only host checks:** the installed Docker CLI is admitted;
the selected engine uses a local Unix socket, reports ARM64 Linux and passes
identity revalidation. Available artifact storage exceeds the default 24 GiB
floor. A fresh ad-hoc Dev candidate passes bundle-only verification without being
installed or opened; it reuses the exact pinned runtime and preserves its
signatures. Diagnostics perform no host preflight or VM launch. Main metadata,
the previous private candidate, all 86,034 older private artifact entries and the
other configuration pins remain unchanged. Private candidate paths, inventories
and readiness receipts stay outside Git.

**TO PROVE:** engine-internal scratch free space was not independently measured.
No real Docker build, source download, resource mutation, image import, signing
credential use, installation or VM launch was performed. Real factory and guest
acceptance still require their separately scoped run; an ad-hoc candidate does
not satisfy same-team operational provisioning-helper admission.

## First authorized real build and anonymous registry configuration

**USER AUTHORIZATION — 6 November 2026:** run the default 20 GiB lean factory in
Dev, including the reviewed downloads, an owned privileged Docker container and
verified import. No credentials, host installs, VM launch or Main operation is
authorized. Preserve old candidates, build artifacts and frozen pins.

**VERIFIED — first attempt:** the three checksum-pinned downloads passed. Docker
then failed while resolving its public Alpine base because the user's configured
`docker-credential-desktop` helper was absent from the controller's restricted
PATH. The job ended failed, without importing an image or creating the privileged
image container. Job-scoped cleanup completed. The failed workspace/downloads are
retained. No helper was installed or added to PATH, and no credential was obtained.

**DESIGN DECISION / IMPLEMENTED:** the image-builder invocation uses a new private
`docker-config` inside its job workspace. It contains only an empty Docker Hub
auth entry, with no copied user configuration, credential helpers or auth values.
The explicit `--config` selects it; its bytes are checked before and after the
build. Docker's [config loader](https://github.com/docker/cli/blob/master/cli/config/config.go)
and [ContainsAuth implementation](https://github.com/docker/cli/blob/master/cli/config/configfile/file.go)
explain why the nonempty map containing an empty entry suppresses automatic native
credential-store discovery. The owned image container additionally uses
`--pull=never` with the acknowledged local image ID. Context/engine admission and
ownership-checked cleanup remain unchanged. The original source/recipe pins and
prior app packages remain intact; only the active package gains a separately
checksummed integration patch. Fake cases verify the private configuration,
unchanged synthetic user config, local-image-only create and tamper rejection.

**VERIFIED — real acceptance:** after the anonymous-config repair, the next job
failed on the mirror's ten-second low-speed timeout while downloading a package
signature. A fresh job using the unchanged recipe succeeded. It built and
imported **Lean Omarchy Dev acceptance**, with a 20 GiB disk and a 1,716,254,279-byte
compressed image. The native service prepared and independently admitted the
format-2 bundle; a subsequent Dev catalog listing reverified its payloads and
matched its identity to the schema-2 import receipt. Sealed-image checks passed;
provenance explicitly retains `guest_boot_tested: false`.

The one privileged container had exactly six job-scoped bind mounts and one
owned work volume, no Main mounts and no restart policy. The same local engine
identity was revalidated after completion. Read-only label queries for all three
attempts found zero remaining owned containers or volumes; images, caches,
downloads, failed workspaces and successful output were retained. The recipe's
3 GiB work-volume check and real loop/mount/seal/compress path completed. Private
receipts, identities, paths and hashes stay outside Git.

The repair passes 97 shared Swift functions (including the new anonymous-config
parameter case), 542 Dev Swift tests, 340 script tests, the final 27 focused
factory/tool tests, eight export tests and relocated/read-only helper checks.
The fresh ad-hoc candidate passes bundle-only checks with the original runtime
signatures retained. Only the idle Dev app started by this run was replaced; both
Dev guests were stopped. Main and existing VM processes were left running.

**TO PROVE:** hosted CI for this follow-on anonymous-config repair, real
cancellation/recovery and disposable-guest boot/account setup/graphics. No
credentials, host install or VM launch was performed. One prior
unfrozen local test log was reused accidentally; candidate payloads and frozen
pins were not changed, and subsequent retry logs use a fresh private directory.

## Disposable Dev boot, account and graphics acceptance — 6 November 2026

**USER AUTHORIZATION:** boot one new manager-owned disposable Dev VM from
**Lean Omarchy Dev acceptance** and verify account setup and graphics, preserving
Main, all existing VMs, artifacts and frozen pins. No signing, host installs or
downloads are authorized. This is factory boot acceptance, not a provisioning
playbook or full milestone-6 execution run.

**VERIFIED — target and launch:** one fresh UUID was created with 4 CPUs,
8 GiB RAM and the manager's minimum 64 GiB system disk, without a separate home,
personal SSH-key inheritance, clipboard, sharing or guest Touch ID. Saved Dev
account settings were snapshotted. The user completed macOS's secure saved-guest-
password access prompt. The initial CLI connection timed out while waiting;
inspection of the same UUID established the pending launch had continued, so no
duplicate creation or start was issued. The new root's owner, mode 0700, marker
and session were checked; the imported factory remained unchanged.

**VERIFIED — account:** thirteen checks passed: configured username, non-root UID,
home ownership, full name, Git name/email, hostname, timezone, console keymap,
wheel membership, matching native completion identity, removed password seed and
removed launch manifest. The desktop keyboard layout also matched, and the system
locale was `en_US.UTF-8`. Managed SSH used the new disposable's key and pinned host
identity, with personal SSH-agent access and forwarding disabled. No password or
personal account values are included in committed evidence.

**VERIFIED — graphics:** native Wayland EGL and the active Hyprland renderer both
reported hardware-backed VirGL on Apple GPU hardware, with no llvmpipe/softpipe
renderer detected. One active output reported 2688×1512, scale 2 and approximately
120 Hz with DPMS on. Scoped Mac guest-window captures showed a normally rendered
wallpaper, panel, clock and notification text before and after diagnostics. The
compositor log includes GLES 3.2 context creation failures followed by a GLES 3.0
retry; the observed renderer remained VirGL. No software fallback or graphics
configuration change was applied.

**VERIFIED — cleanup:** graceful stop produced the exact session's `Exited (0)`;
the manager released its session, SSH listener closed and runtime lock was
available. No new manager/runtime processes remained, and all eighteen recorded
preexisting processes were still present. The stopped disposable disk was retained.
Private receipts bind these observations to the exact imported factory and
candidate. Frozen factory manifests, including their original unbooted build-time
provenance, are preserved rather than rewritten to record this later observation.

**LIMITS / TO PROVE:** one successful fresh boot does not close the known
intermittent graphics-startup issue. Password-based login was not separately
exercised. GLX was unavailable in the SSH environment; native Wayland EGL and
compositor evidence establish the renderer instead. An optional Foot-window
fixture did not run because its dispatch calls were incompatible with the
installed Lua dispatcher API; no app-window/shortcut, resize, sleep/wake,
clipboard or crash acceptance is claimed. Real builder cancellation/recovery and
developer provisioning remain separately scoped.


## Merge-readiness review — 6 November 2026

**USER AUTHORIZATION:** review both factory PRs and repair remaining issues with
fake runtimes and local fixtures. Preserve private artifacts, frozen candidate
pins, Main and existing VMs. No signing, installs, factory/runtime downloads or
VM launches are authorized; reviewing a PR does not authorize merging/releasing.

**VERIFIED — reproduced defects and fixes:**

- A controller with a cached journal could start past another controller's new
  cleanup hold, or replay recovery over a job its original owner had already
  completed. Readiness, start and recovery now refresh durable records under the
  build lock before deciding. A record already observed by the controller cannot
  disappear and silently clear its hold.
- Quit could observe an idle builder, then allow a CLI start while waiting for
  manager shutdown. It also failed to join an in-flight cleanup recovery. Quit
  now fences new admission, invalidates pending/in-flight previews, cancels the
  owned worker and readiness probes, and waits for recovery. Cancelling a later quit dialog reopens
  admission but requires a fresh preview; it never resumes a cancelled build.
  Unconfirmed cleanup or unreadable durable state blocks quit and directs the
  user to explicit owned-resource recovery, rather than claiming cleanup passed.
- Non-following CLI logs stopped after four pages of eight process writes, losing
  retained output when writes were small. The shared ring now uses byte cursors
  and pages at 64 KiB, so four requests cover its retained 256 KiB independently
  of write fragmentation. Gaps and future cursors explicitly reset to retained
  output; the terminal remains bounded and ephemeral.

Deterministic tests fail with the original implementations and pass with the
repairs. Final focused manager validation passes 17 test functions, the shared suite
passes 99 functions, and the eight source-export plus three resource-verification
tests pass. Offline staging parity still matches all 162 inputs. The 340 script tests and 32 fake UI checks pass. Fresh hosted results on the
repaired heads are recorded separately once observed.

**PRIVATE COUPLING:** the shared source/engine inventory advances through a third
checksum-pinned integration patch, `dev-vm-factory-output-pages.patch`, over the
same immutable `5d0abc3` base and original two patches. The active public export
and generated package pin change; recipe/archive bytes, runtime pins, private
candidate payloads and their frozen pins do not. The earlier real build/import
and disposable boot evidence remains bound to its recorded candidate, rather
than being extended to this new revision.

**MERGE ORDER / TO PROVE:** the companion factory PR #9 still includes and depends
on the open provisioning foundation PR #8; integrate that foundation first, then
#9, then manager PR #11 into `next`. The manager provisioning foundation #10 is
already merged. Both factory PRs remain drafts; no merge or release is performed
by this review. Fresh CI on the repaired heads is required before approval.
Real builder cancellation/recovery, graphics-startup repeatability and the prior
unexercised guest checks retain their stated acceptance limits.


### Hosted CI execution budget

The first repaired-head run (`4122a31`, run `42202384549`) passed every test step:
556 Swift tests per channel, 340 script tests, both relocated bundle checks,
140 Setup/New VM checks, 32 factory UI checks, four policy tests in each of three
optimized modes, app/CLI/helper/icon builds and 566 pinned-upstream Swift tests
plus shell/package contracts. Its overall result is **CANCELLED**, not green:
GitHub annotated the job as exceeding its 40-minute execution limit; the cold
ARM64 run completed its steps in approximately 43 minutes.

The bounded Mac test-job limit is now 50 minutes. Test fixture/process deadlines,
coverage, Docker/SSH exclusions and release/signing gates are unchanged. A fresh
run on that workflow head must pass before the PR is considered checked. Synthetic
signing/notary notices in unit-test output use fake adapters and fixture IDs;
no signing credential or Apple service was used by this test-only run.
