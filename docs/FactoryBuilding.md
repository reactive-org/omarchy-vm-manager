# Build a lean factory in Dev

The **Factory images** sidebar page builds a reusable lean Omarchy foundation.
**New VM → Build lean factory…** opens the same flow without discarding the fields
already entered. After independent verification/import, **Use for new VM** selects
the resulting factory. Building never creates a VM, changes an existing disk or
launches a guest. Official and previously imported factories remain available.

Choose a name and, under **Advanced**, a capacity from 20–128 GiB. The reviewed
recipe supplies the desktop, Mac integration, Git, Python and build tools inside
the image. Additional profiles, apps, themes and layouts are selected per VM.
Arbitrary build scripts, package editors and source repositories are outside this
first native flow.

## Readiness and the build action

Factory building is compiled into the Dev channel. Stable can continue importing
compatible bundles but cannot start a build. There is no environment or command
flag to override that gate.

The Mac needs Apple Silicon and an already installed Docker CLI with a running
ARM64 Linux engine exposed through a local Unix socket. Readiness checks install
nothing and reject remote engines. They verify the pinned embedded runtime,
reviewed recipe, CLI identity, engine identity and available artifact storage.
The initial floor is image capacity + 4 GiB on the artifact volume; Docker needs
at least 3 GiB scratch capacity separately. Package caches and live repository
contents may require more. Before preparation/import, the manager checks space
again against twice the actual compressed image size plus 64 MiB. Failure retains
the finished output and does not publish an import.

**Build factory** authorizes downloading the reviewed sources/packages and running
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
`codex/swift-factory-builder` revision `5d0abc3`. These follow the previously tested
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
omarchy-vm factory-build plan --name 'Lean development' --size-gib 20
omarchy-vm factory-build start REVIEW_UUID
omarchy-vm factory-build status JOB_UUID
omarchy-vm factory-build logs JOB_UUID --follow
omarchy-vm factory-build cancel JOB_UUID
omarchy-vm factory-build cleanup JOB_UUID
```

`plan` checks readiness and returns a preview UUID. `start` is the deliberate build
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
