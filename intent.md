# Omarchy VM Manager — implementation intent

## Setup's passwordless sudo: timed by default, permanent opt-in — 8 November 2026

**DESIGN DECISION — issue #20, user direction:** Omarchy's full-screen prompt for
`omarchy sudo passwordless permanent` says the grant lasts forever and survives
reboots. That reads far worse than it is, because setup turns the grant off and
verifies it at cleanup. The prompt belongs to Omarchy and can't be changed. Setup
therefore asks for Omarchy's timed grant by default (`omarchy sudo passwordless 60`,
renewed before each later step that needs root). **Ask for sudo once** (Guest
defaults, New VM and Change setup; CLI `--sudo-grant permanent|timed`) restores
the single permanent grant. The choice is part of the reviewed plan
(`vm.sudo_grant`, dev-vm#17), so the review digest binds it. Cleanup, consent and
`--ack-sudo` are unchanged. The manager's notes say "Setup turns it off when it
finishes" while the prompt is up, and the review step names the grant that will
be requested. This supersedes the plan's earlier "do not describe it as a
60-minute grant", which still holds for the permanent option.

**PRIVATE COUPLING — Omarchy `bin/omarchy-sudo-passwordless`, identical at e4fffc6,
a948d8a (4.5.0) and edge 9044b7e:** a timed grant is a `NOTAFTER` sudoers rule plus
an expiry timer, and a boot-time tmpfiles rule removes it. A renewal while it is
active needs no confirmation or password. An `omarchy-settings` upgrade revokes
timed grants (but not permanent ones) before its transaction, so an update can
make the rest of `omarchy update -y` ask for the guest password and the renewal
show Omarchy's prompt again. A timed grant refuses to enable without Omarchy's boot
cleanup, so older images fail before setup changes anything.

**VERIFIED — no-VM checks only:** dev-vm and manager unit and acceptance tests
(see the PR). The manager shows **Needs you** only for the initial grant request,
not for renewals, which normally finish at once.

**TO PROVE:** on a real disposable Dev guest, for each option: how many prompts
appear, Omarchy's wording, silent renewals, revocation and the inactive check at
cleanup, the timed rule's removal at restart, and the settings-upgrade re-prompt
(which the manager doesn't flag as **Needs you**).
The `example-vm-07-needs-you` user-guide screenshot still shows the permanent
prompt and needs recapturing after such a run.

## CI toolchain moves to Xcode 27 — 7 November 2026

**USER DIRECTION / DESIGN DECISION:** CI's macOS test and branch-release jobs move
from Xcode 26.0.1 on `macos-15` to Xcode 27.0 (27A266a) on GitHub's `xcode-27`
image, matching the local development toolchain. Branch releases are therefore
built with the toolchain the tests ran with. Xcode 26.0.1 had rejected a SwiftUI
body that Xcode 27 accepted (PR #23), so CI and local builds now agree. The
`xcode-27` image is a GitHub **preview** on macOS 27 (macOS 27.0.1); the deployment
target stays macOS 15. The notarization status check keeps its own runner.

**TO PROVE:** a green hosted run and a branch release on the preview image.

## Releasing a stopped guest's cleanup hold — 7 November 2026

**DESIGN DECISION — issue #24, user direction (same PR as #16):** this supersedes
"Journal cleanup holds cannot be cleared from a stopped observation alone" for one
explicit case. A guest whose setup stopped with temporary admin-access cleanup
unconfirmed, and which then stopped, was permanently held: launch, configure,
delete and backup were refused, and Recover needs the original live session. The
hold also blocked setup preparation on every other guest. The owner can now
release it through a reviewed **Release cleanup hold** workflow action, in the
same spirit as the failed-restore attestation: an acknowledgement the app neither
performs nor claims to verify. It is offered only for a stopped guest (Recover is
offered only while the guest runs) and is refused while the guest has a session,
lease, preparation, restart, home backup or storage change, while provisioning
storage is unknown, or if a journal write fails. The confirmation says plainly
that cleanup was not verified and that the owner removes any leftover passwordless
sudo inside the guest. Every cleanup-bound job and workflow row for that VM is
marked released without verification (`cleanupRelease: unverified`) and saved
before the in-memory holds clear; other VMs' holds are untouched. History keeps
saying the hold was released unverified; nothing is erased or shown as cleaned.

**DESIGN DECISION — user direction, 7 November 2026:** workflow actions in the
app are one click. Restart, check and recover each prepare a review bound to the
guest's current state and submit exactly that review; the click is the owner's
consent, replacing the separate review, "I approve this exact … action" checkbox
and second button. Release alone adds a confirmation dialog that says cleanup
wasn't verified. A failed preparation submits nothing, and a failed submission
is never retried; the next click starts a fresh review. The CLI keeps its
two-step prepare/submit with explicit `--ack`.

**PRIVATE COUPLING:** the job journal writes schema 8 when a record carries
`timedOutOperation` or `cleanupRelease`, and the workflow journal writes schema 2
only when a row carries `cleanupRelease`; journals with neither stay readable by
earlier builds. The CLI gains `setup prepare-release` and `setup release`.

**VERIFIED — user-observed on a real Mac, 7 November 2026:** releasing a real
stopped Dev guest's hold (the stuck guest from #24) worked; the guest could then
be deleted, and setup could again be prepared and run on another guest.

## Setup attention: badges, notifications and named timeouts — 7 November 2026

**DESIGN DECISION — issue #16, user-approved plan:** one per-guest attention state
in Core (`SetupAttention`) is the only source of "needs you" for the Home card,
first-run tracker, sidebar, Dock and notifications. Reasons are the sudo prompt,
a saved setup's review, restart review, check review and cleanup; all but the
saved-setup review block a run. It is derived only from recorded workflow stage,
job state and the in-memory New VM approval, never terminal output. The card and
tracker select the current run with one Core rule. The sidebar shows **Needs you**
on each waiting guest (its click opens the output at the prompt or the review).
User correction during planning: no counts. The Dock shows a "!" marker while any
guest is blocked and bounces once (`.informationalRequest`) when one becomes
blocked while the manager isn't frontmost; neither needs permission. Notification
permission is requested at launch. A pure Core tracker sends one notification per
entry into a blocking state, only if the manager isn't frontmost or that guest
isn't on screen, never repeats it, removes it once the state ends, and treats the
first observation after launch as a baseline (badges only). Notifications carry
the guest name, fixed wording and its UUID only. Clicks route from the current
state at click time; activation alone never changes page.

**VERIFIED — source finding:** the authenticated helper path, which real setup
uses, never recorded `.awaitingAuthorization`; only the in-process path did. The
coordinator now records it from the helper's reported `requestPersistentGrant`
operation (never a cleanup step) and returns to `.running` on the next step. The
helper wire format is unchanged.

**PRIVATE COUPLING:** timeouts name the step from a new job field,
`timedOutOperation`, set from the last body step the coordinator saw (in-process
`before`, or helper session-authority command requests with `cleanup == false`),
so cleanup steps cannot overwrite it. Legacy helpers without session authority
keep the generic message. Journal schema 8 is written only when a record carries
the field, so earlier builds keep reading journals without a timeout. Limits
mirror the pinned dev-vm `bodyTimeoutSeconds` (10 s, 30 s, otherwise one hour,
including dev-vm `6b5e2e6`'s one-hour sudo prompt); a test pins them to the
vendored source. Workflow SSH and restart waits use the manager's 3-minute default.

**VERIFIED — fake/local checks:** Core unit tests cover attention for every
workflow stage × job state × approval, current-run selection, the tracker's
notify/clear/bounce/marker rules, every timeout note, schema 8 round trip and
refusal, the in-process sudo state and timed-out step through cleanup and reopen,
and the authenticated helper path (local sockets, fake process runner) reporting
the sudo prompt and naming its timeout. The offscreen setup acceptance (199
checks, 54 PNGs) checks that card, tracker and Core agree, the sidebar badge and
its routing, notification-click routing, and Dock/notification effects through a
recording fake. `make test` passes: 596 Swift tests in 79 suites, 340 script
tests, the provisioning bundle checks and 199 offscreen checks with 54 PNGs; the
screen acceptance and `git diff --check` pass again on the final code. No VM, guest,
Dock, notification or permission was touched, and `make app-dev` was not run. The
tracker starts only once setup coordination is installed, so its launch baseline
includes saved workflows; that ordering is reasoned from `AppModel.observe()`, not
exercised.

**VERIFIED — user-observed on a real Mac, Dev build `8dd129b`, 7 November 2026:**
with a real Dev guest's Omarchy passwordless-sudo prompt, the Dock bounced once
while the manager was not frontmost, one notification arrived, clicking it opened
that guest's setup output at the prompt, and answering cleared the notification.
The Dock "!" marker did **not** appear. The user confirmed the likely cause:
macOS hides an app's Dock badge unless its notification settings allow badges,
and the manager requests alert and sound authorisation only. Whether to request
badge authorisation or draw the marker on a custom Dock tile is a follow-up.

**TO PROVE:** the Dock "!" marker; foreground banners when another guest is on
screen.

## Update-before-setup CI fixture correction — 7 November 2026

**VERIFIED — hosted failure:** manager run `42295151880` on `288c82c` passes all
559 Swift and 340 script tests, then fails relocated helper dispatch because its
excluded debug fixture still expects `applied`. The helper returns the correct
`appliedRestartRequired` with confirmed cleanup and no primary failure. Companion
PR #10 run `42295108340` is green on `1c08131`.

**FIX / DESIGN DECISION:** require the exact restart-required outcome for successful
fixture dispatch; keep cancellation, terminal completion, cleanup, reconciliation,
matching exit and existing time bounds unchanged. No product code, shared export,
resource, runtime or frozen candidate pin changes. The local checks use fake
runtimes/adapters and fresh scratch storage without explicit signing commands.
Seven local fake helper-engine tests pass and the corrected excluded fixture
compiles. Relocated bundle fixtures ad-hoc sign their disposable containers, so
their full rerun is reserved for hosted CI. The user explicitly allows normal
hosted workflows after merge, including runner-only Ansible installation and the
normal next Dev signing/notarization release; this Mac remains untouched. Hosted
success on the correction remains TO PROVE; the failed run above remains a failure.

## Update before Developer setup — 7 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** restore the original dev-vm bootstrap
sequence in the shared Swift engine. Every reviewed apply updates Omarchy and
all system packages through `omarchy update -y` after verified admin access and
before manifest packages, optional-app trimming, features, dotfiles or tasks.
This is disclosed in New VM, the proposal and apply review; the existing apply
confirmation authorizes the displayed update without another checkbox. Preview,
check and cleanup recovery never update. Existing guests receive the same explicit
apply review. Never substitute a database-only refresh or direct pacman upgrade.

**PRIVATE COUPLING:** sequencing review version 2 binds update semantics; the
authenticated helper admits only the new apply-only update operation and its
matching process purpose. Use the existing owned guest scope, input lease,
3600-second process deadline, live terminal and independent cleanup. A successful
apply requests the existing separately reviewed restart/check, including when
Docker is unselected. Update failure stops feature installation and retains a
fixed typed reason through helper IPC and journal; cleanup does not roll back
package changes. Old reviews/saved engine receipts cannot authorize this engine.
Only the active public package export advances via a fourth checksummed patch;
its base, factory recipe, runtime pins and all private frozen candidates remain.

**VERIFIED — fake/local checks:** 104 shared Swift tests, 559 full manager tests
in 72 suites, 283 Dev provisioning tests, 340 manager script tests, 239 legacy
dev-vm tests (one existing Lua skip), 66 complete planning-oracle cases, 162 factory
resource inputs and 141 offscreen Setup/New VM checks/27 PNGs pass. The Dev review
render was visually inspected. Initial sandboxed PTY/socket refusals pass with
local fixture process access. No real SSH or Ansible guest run was used.
Eight source-export tests and twenty final Dev package/helper/review tests pass
after the vendored test export is aligned. Generated pin and reverse-patch
reconstruction checks pass. All 86,034 prior
private artifact entries, eight frozen/runtime pins, imported factory/receipt,
387 candidate payload files and thirteen Main metadata files remain unchanged.
Frozen configuration inputs do not freeze guest repository package versions;
the explicit native update uses the guest's configured repositories.

**TO PROVE:** real fresh-official/lean guest update, mirror recovery, native
prompts, interrupted upgrades and post-update compatibility. Validation here uses
fake runtimes/runners and disposable local fixtures; no real guest, host install,
credential, Apple request, app installation or VM launch is authorized.

## Factory channels and Omarchy 4.5 — 8 November 2026

**USER AUTHORIZATION:** implement issues #29 (Stable/Edge factory channel) and #27
(factory library layout) end to end, with Stable tracking the latest Omarchy
release without a manager release where possible, failing closed otherwise.

**DESIGN DECISION — live channel, reviewed set, fail closed:** custom factory
builds no longer compile Omarchy from one pinned commit. They install the
selected channel's current signed pair (Stable `omarchy`/`omarchy-settings`,
Edge `omarchy-dev`/`omarchy-settings-dev`) and refuse any release whose six
patched install scripts or five owner programs differ from a reviewed entry.
Stable is the default; plans written before channels decode as edge. A release
that leaves those programs unchanged builds without a manager release; one that
changes them needs a reviewed contract, guest integration package and kit.

**DESIGN DECISION — lean contract set:** lean admission accepts a reviewed set of
owner contracts instead of one digest: `lean-e4fffc6` (`1347cb16…`, image
package 0.1.0-43.1) and `lean-a948d8a` (`fb73e12e…`, Omarchy 4.5.0 and edge from
`9044b7e`, image package 0.1.0-48.1). Each factory names one by digest; its
evidence must match that contract's programs and package. The compatibility
policy is schema 2 with a `leanContracts` list. Receipt digests are computed
per pairing over the schema-1 field set, so existing e4fffc6 receipts keep
`c3cbd5eb…`. Unknown contracts and crossed pairings are refused.

**VERIFIED — source review:** 4.5.0 changes `omarchy-provision-owner` (tip
rendering without subshells), `progress-icon.sh` (VT colour and cell-size fixes),
`setup-form.sh` (French, French (Switzerland) and German console keymaps move to
latin1 maps; keyboard IDs unchanged) and `install/user/mise.sh` (offline
reshim). The functions the guest adapter drives are byte-identical, so the
existing lean fixture covers both adapters. Guest package 0.1.0-48/48.1 differs
from 47/47.1 only in the adapter, the new contract file and its version.

**PRIVATE COUPLING:** the six guarded install scripts are edited after
installation, so `pacman -Qkk` reports them modified until Omarchy updates them.

**REPORTED LIVE — user, 8 November 2026:** the user built a Stable factory
(Omarchy 4.5.0-3) in the branch's Dev app and booted a VM from it successfully.
The first attempt failed at dependency resolution because Stable's packages need
Omarchy's frozen Arch Linux ARM snapshot (`arm-stable-mirror.omarchy.org`); the
builder now pairs each channel with its own mirror and forces the index refresh.
Container-only checks pass for both channels.

**TO PROVE:** owner setup, managed SSH and hardware rendering on the 4.5 guest
were not separately reported, and Edge builds and real two-VM, focus and
sleep/wake behaviour remain unobserved.

## Factory merge-readiness repairs — 6 November 2026

**USER AUTHORIZATION:** review both factory PRs and fix remaining issues with
fake/local checks only. Preserve private artifacts, frozen pins, Main and existing
VMs; no signing, installs, factory/runtime downloads or VM launches.

**FIX / DESIGN DECISION:** refresh factory records under the matching build lock
before admission/recovery; keep already observed missing records fail-closed.
Fence factory admission throughout quit, join existing recovery, and require a
fresh preview after a cancelled quit. Use byte-based bounded output pages so the
CLI snapshot retains small fragmented writes. The active public shared export
gets a third checksummed patch over its unchanged base; historical candidates,
recipe/archive bytes, runtime pins and private pins remain unchanged.

**VERIFIED / TO PROVE:** deterministic regressions reproduce the old failures.
The corrected focused manager tests (17), shared suite (99), script suite (340), source-export tests
(8), resource tests (3) and 162-input parity pass. [Review evidence and merge
order](docs/FactoryBuilding.md#merge-readiness-review--6-november-2026) retain fresh
hosted checks and real cancellation/recovery as separate proof obligations.
No review result authorizes a merge/release or extends a prior candidate's real
boot acceptance to this new source revision.

**VERIFIED — hosted budget:** all checks on `4122a31` passed their steps, including
556 Swift tests per channel, but run `42202384549` is cancelled for exceeding the
40-minute job limit. Raise only the bounded Mac job budget to 50 minutes; retain
all individual deadlines, coverage and real-execution exclusions. Fresh hosted
success remains TO PROVE.

## Factory PR integration refresh — 6 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** publish the factory acceptance docs and
complete test-only CI, preserving private artifacts, frozen pins, Main and
existing VMs. The updated PR conflicts with `next`; integrate `a2ff8da` on the
factory feature branch and retain both documentation histories. Its inert-helper
shutdown and nested saved-selection corrections join the factory changes; no
package, runtime or candidate pin changes are needed.

**TO PROVE:** fresh hosted checks on the merged source. This integration does not
authorize signing, installs, factory/runtime downloads or VM launches, and does
not extend the preceding real-guest acceptance to this new source revision.

## Disposable lean factory boot acceptance — 6 November 2026

**USER AUTHORIZATION:** boot one new disposable Dev VM from the imported lean
factory and verify account setup and graphics. Preserve Main, existing VMs,
artifacts and frozen pins; no signing, host installs or downloads.

**VERIFIED:** one fresh manager-owned UUID booted with saved account defaults,
4 CPUs, 8 GiB RAM and a 64 GiB system disk. After the user completed secure
guest-password authorization, inspection joined the original pending launch
without creating or starting another guest. Thirteen account checks, desktop
keyboard matching, native completion and seed removal passed. Native Wayland EGL
and the active compositor reported hardware-backed VirGL; scoped Mac-window
observations showed a healthy desktop at 2688×1512, scale 2, about 120 Hz.
Graceful shutdown produced the matching `Exited (0)`, released the listener/lock
and left no new runtime processes. The stopped disk is retained. No factory
manifest or frozen pin is rewritten by this later observation. [Checks and
limits](docs/FactoryBuilding.md#disposable-dev-boot-account-and-graphics-acceptance--6-november-2026)
distinguish this factory acceptance from developer provisioning.

**TO PROVE:** repeatability of the known intermittent graphics-startup issue,
password login, application/shortcut/resize/sleep/crash acceptance and real
builder cancellation/recovery. GLX and an optional Foot-dispatch fixture were
unavailable; native Wayland EGL, compositor and visible desktop checks passed.

## Real Dev factory build and import — 6 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** execute the reviewed lean factory
recipe in Dev, allowing downloads and one owned privileged Docker container,
then independently verify/import its output. No credentials, host installs,
VM launches or Main operations are authorized. Existing artifacts and frozen
candidate pins remain preserved; a necessary integration repair advances only
the active public package export with a separate checksum-pinned source patch.

**VERIFIED:** the first attempt failed before privileged-container creation on
Docker's unavailable configured credential helper. A private anonymous build
config and local-image-only container creation repair that integration without
using a credential store. One subsequent mirror timeout failed closed; the next
job built/imported **Lean Omarchy Dev acceptance** (20 GiB disk;
1,716,254,279-byte compressed image). Format-2 admission, schema-2 receipt, catalog
readback, scoped mounts, unchanged engine identity and zero remaining owned
containers/volumes for all three jobs are observed. See [factory acceptance and
limits](docs/FactoryBuilding.md#first-authorized-real-build-and-anonymous-registry-configuration).
Local fake validation passes 97 shared, 542 Dev and 340 script tests plus final
export/helper checks. One prior unfrozen local test log was reused accidentally;
app payloads and frozen candidate pins remain unchanged, and further logs are
isolated. **TO PROVE:** hosted CI for the repair, real cancellation/recovery and
guest boot/account/graphics acceptance. No VM was created or launched here.

## Native lean factory builder — approved prototype, 6 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** implement the approved native Factory
images library, build sheet, progress terminal and New VM handoff in Dev. Reuse
upstream Linux image/package logic through the shared Swift package; do not
reimplement the guest/hypervisor. Readiness uses existing local Docker only.
The Build action authorizes downloads and one owned privileged build container;
readiness, navigation and field edits never imply execution. Stable remains gated.

**PRIVATE COUPLING:** consume a compiled checksum-pinned export of dev-vm's
maintained staging recipe; preserve the original reviewed guest integration
archive and independently import through the existing format-2 catalog. The
active public package pin advances on follow-on local feature branches. Preserved
private candidate artifacts and frozen pins retain their original identities.

**VERIFIED / TO PROVE:** [Factory builder evidence and limits](docs/FactoryBuilding.md)
records passing offline staging parity, 92 shared Swift tests, full manager
regressions, 27 final focused Dev tests, relocated bundles, 140 Setup/New VM and
32 factory UI checks, plus all three optimized policy modes. The preservation
audit matches all 86,034 old private artifact entries and five unchanged other
pins. Real Docker/download, privileged-container and disposable-guest acceptance
remain **TO PROVE**. This pass authorizes no
real build, download, signing, install, VM launch or Main operation.

## Factory CI portability and terminal input release — 6 November 2026

**VERIFIED — failures:** both factory PRs fail resource lookup under hosted
SwiftPM's resource layout. Manager CI also observes stale UI input ownership
when an already-dispatched poll finishes while release waits for idle.

**DESIGN DECISION:** use Foundation named bundle resources with unchanged
recipe/archive checksums; advance only the active public shared package pin.
After waiting for an in-flight read, input release clears local input state
again before the serialized release command. A deterministic local read barrier
reproduces the old failure and verifies the correction; no authority, command
replay, deadlines or lease limits change. **TO PROVE:** fresh hosted CI results
until recorded in [factory build validation](docs/FactoryBuilding.md).
Private artifacts and frozen candidate pins remain preserved. Main and its VMs
are untouched; real Docker, downloads, signing credentials, installs and guest
launches remain outside this repair.

## Docker executable admission repair — 6 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** repair the factory host executable
limit, test with fake adapters/local fixtures, prepare a separate ad-hoc Dev
candidate and inspect readiness without building or launching anything. Factory
host tools use a 128 MiB cap with 1 MiB hashing chunks; SSH/Ansible retain 32 MiB.
Symlink, owner, permission, file-stamp and hash checks stay mandatory. The active
package records a checksum-pinned integration patch over the unchanged upstream
base; existing private artifacts, frozen candidate pins and runtime pins remain
preserved. Main and its VMs are untouched.

**VERIFIED / TO PROVE:** 97 shared Swift tests, 542 Dev manager tests and 340
script tests pass. Read-only local ARM64 Linux engine inspection and identity
revalidation pass. Fresh candidate verification and preservation evidence are
recorded in [factory building](docs/FactoryBuilding.md). No Docker build,
download, signing credential, install or VM launch is authorized here. Engine
scratch capacity, real factory build/import and guest acceptance remain TO PROVE.
## Authorized PR #10 merge gate and terminal backport — 6 November 2026

**USER AUTHORIZATION:** merge PR #10 into `next` once its reviewed source and all
applicable hosted checks are ready. This permits the existing Dev release
workflow after merge, not a merge into `main`, local signing, installation,
permission changes, factory downloads or real-VM operations.

**VERIFIED — CI blocker:** the PR-event run `42179249963` on `98caa99` passes its
Stable checks but fails Dev's `nativeViewerClaimsRendersReleasesAndDetachesWithoutCancelling`
at the immediate ownership-release assertion. Both managed-SSH checks pass;
the separate push run is still completing its optimized policy checks. Neither
an old green result nor a missing required-check setting authorizes merging.

**FIX / PRIVATE COUPLING:** PR #11 already contains the terminal correction in
`91ec718`. Backport only its exact terminal screen and surface-test changes.
An already-dispatched read may republish owned-input state while release waits
for idle; clear input state again after that read finishes and before suspending
on the release RPC. Keep the authenticated attachment, command sequencing and
single-writer lease unchanged. Its internal read seam lets a synthetic test
hold that ownership page across explicit release, without changing the wire.
No factory-builder implementation, package/resource pin or other PR #11 change
is included.

**VERIFIED — fake/local:** the deterministic `inputReleaseFencesAnAlreadyReadOwnershipPage`
regression fails with only the four-line ownership correction withheld and passes
with the exact PR #11 implementation. `make test-provisioning-ui-cli
test-provisioning-terminal test-provisioning-screens` passes 15 surface/planning
tests, three terminal-vendor script tests, 16 terminal/UI tests and 140 offscreen
Setup/New VM checks/27 PNGs. A Dev build of the combined surface/terminal filter
passes 30 tests. Diff checks pass. Evidence is retained privately in
`.build/pr10-terminal-before.log` and `.build/pr10-terminal-validation.log`.
Fresh hosted CI on the backported source remains pending until observed; the
failed run above remains a failure.

**TO PROVE:** native input/focus and actual guest behavior retain their prior
boundaries. This pass opens no on-display window, runs no VM, accesses no real
credential, and changes no installed application, runtime or factory artifact.

## PR #10 merge-review corrections — 6 November 2026

**USER AUTHORIZATION:** inspect PR #11 before fixing both PR #10 review findings,
add regression coverage and push to PR #10 only after local checks pass. This is
source/test work, not a merge, release, installation or real-guest approval.

**VERIFIED — source comparison:** PR #11 at `62f2e22` retains PR #10's unchanged
coordinator, service, frozen-input tree and saved-selection implementation and
associated workflow/selection tests; it has not addressed either finding.

**FIX / DESIGN DECISION:** an authenticated never-activated helper may be retired
locally when shutdown revokes registration admission, including the interval
between registration and activation. Verify the original worker's exact scope,
permanent fence and matching owned exit before clearing its risk and releasing a
pending shutdown. Lost registration/fencing/exit proof, any accepted activation
or failed journal persistence keeps protection. Do not repeat an uncertain inert
retirement. No guest command or new execution authority is needed for this path.

**FIX / DESIGN DECISION:** restore saved nested manifests by their full relative
paths through a bounded descriptor-relative walk of the retained source tree.
Reject linked/special entries and retain all plan/input/engine receipt checks;
restoration supplies no session, helper, task or sudo authority. Existing frozen
source formats, private candidates, dependency/runtime pins and Stable/Dev gates
are unchanged.

**VERIFIED — fake/local checks:** `make test test-dev test-build-policies`
passes 538 Swift tests in 70 suites per channel, 337 script tests, 140 offscreen
UI checks/27 PNGs and three policy tests in each of the three optimized modes.
After the final retained-tree discovery adjustment, `make test-provisioning-tools
test-provisioning-bundle-dev` passes all 279 provisioning tests in 28 suites and
the relocated/read-only Dev helper checks. Stable's relocated helper checks also
pass. Six added test functions cover both original reproductions, the
registration/activation interval, missing registration/fencing/exit proof,
journal failure/no reconciliation replay, and nested manifest restoration plus
changed bytes/modes/links. Whitespace checks pass. Logs are retained privately as
`.build/pr10-review-fixes-validation.log` and
`.build/pr10-review-fixes-final.log`. Hosted CI on the new commit remains pending
until observed; earlier CI success applies only to its recorded source commit.

**TO PROVE:** fresh signed normal-Dev, native helper/guest cancellation and
recovery, and prior focus/sleep/wake/crash cases retain their existing evidence
boundaries. Fake/local checks do not establish these behaviors. No real VM,
factory download, installed manager, macOS permission or signing credential is
used or changed in this correction pass.

## Normal Dev provisioning — user authorization, 6 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** merge latest next and enable normal Dev
provisioning eligibility for verified manager-owned Dev UUID roots. Stable stays
disabled. This replaces the private single-VM overlay requirement for ordinary
Dev builds; it does not change the scope of any preserved private candidate.
Explicit frozen review/permissions, authenticated session/transport, same-team
helper, owned cleanup and no replay remain mandatory. Root metadata alone grants
no authority. No environment or wire switch selects the policy.

**DESIGN DECISION — user direction, 7 November 2026:** same-team helper signing
stays mandatory for stable and for signed Dev prereleases. Local Dev builds
(compiled with `DEVELOPMENT_CHANNEL` and without `SIGNED_PRERELEASE`) also admit
a matching ad-hoc app/helper pair, so setup can be tested without a signing
identity. A team-signed app still needs its same-team helper; mixed or
cross-team pairs are refused. The choice is compiled, not switched at runtime.
Ad-hoc mode keeps the pinned helper hash, private single-link executable checks,
running-child cdHash match, authenticated inherited channel, root admission,
explicit consent and owned cleanup; it gives up only the external team anchor,
which an ad-hoc build cannot have. See [Validation](docs/Validation.md#local-ad-hoc-dev-setup--7-november-2026).

**DESIGN DECISION — user direction, 7 November 2026 (approve at creation):** for a
new guest created with setup, **Create, Launch & Set Up** in New VM is the explicit
permission for one automatic first apply. The sheet states that it approves the exact
frozen plan for this VM's first launch, including temporary admin access. The frozen
review still runs: once the guest is SSH-ready, the manager prepares the normal apply
review and submits it only if it matches the creation receipt's plan and input digests,
this VM and the first session seen after launch, and needs no permission beyond
temporary admin access. Docker root access, custom-task trust, a changed session or any
mismatch stop with a reason and fall back to the Setup-tab review. The approval lives
only in the running manager's memory, is used at most once and is never persisted or
replayed. Existing guests and later runs keep the manual review (superseded for Change
setup on 9 November 2026; see "one approval per run" below).

**DESIGN DECISION — user direction, 7 November 2026 (approve at creation finishes
setup):** the same creation-time approval also covers the restart and configuration
check that finish that one workflow, so the user lands on an updated, configured
desktop without stopping for a restart approval. After its apply, the manager follows
only the workflow it submitted: when restart is required it prepares the normal
restart review and, when the replacement session is ready for check, the normal check
review; each is submitted once, and only if it names this VM and workflow and matches
the creation receipt's plan and input digests. Recovery of cleanup is never automatic;
a failure, cancellation, interruption, cleanup requirement or mismatch ends the
automatic path and leaves the reviewed Setup-tab actions. The sheet discloses the
restart and check before creation. The approval stays in memory only; a manager
restart mid-way leaves the remaining actions to manual review.

**DESIGN DECISION — user direction, 7 November 2026 (saved setup output):** to aid
diagnostics, the manager saves the output of the most recent setup run for each VM to
one private file, `<VM root>/.manager-setup/last-run.log` (0700 folder, 0600 file). A
view-only recorder owned by the coordinator attaches before the helper starts, never
claims input, and paces its reads so UI and CLI viewers keep working. An apply job
replaces the file; a check job in the same run appends to it. The file is bounded: the
head is written directly and the rest is kept as a rolling tail, with an explicit marker
for any omitted bytes or output gap. Output that arrives while the job accepts
interactive input is not saved; an "interactive section omitted" marker is written
instead. It is written only into an existing VM root, never journaled, and moves to
Trash with the VM. It is not redacted and may contain anything setup printed. The Setup
tab shows it read-only when no run is live. Raw input is still never recorded, and
terminal bytes stay out of journals, app logs and crash reports.

**DESIGN DECISION — user direction, 7 November 2026 (desktop layout and defaults):**
the desktop layout is chosen before the theme, from cards in horizontally scrolling
rows: the bundled dev-vm examples, Omarchy default, a local folder's own layout (local
sources only) and a custom file. The cards map onto the existing appearance selection
without new provisioning inputs: Omarchy default keeps the source's layout for bundled
setup (which names none) and removes a managed layout for a local folder. Guest
defaults stores a desktop default in a private manager preference
(`desktop-defaults.json`, per channel); New VM starts from it and existing guests are
never changed. The vendored dev-vm catalogue currently describes one workspace per
example; multi-workspace examples need a dev-vm update before they can appear.
Page titles, sidebar items, tabs and buttons use sentence case; proper names, the
Setup tab's name and macOS menu commands keep their capitals.

**DESIGN DECISION — user direction, 7 November 2026 (setup on Home):** the guest's
Setup tab is replaced by a setup card on Home with Change setup and View output sheets.
Consent stays exactly as reviewed before: separate acknowledgements for temporary admin
access, Docker root access and inspected task trust, each shown only when the review
requires it, and reviewed restart, check and recovery actions.

**DESIGN DECISION — issue #14, 8 November 2026 (a plan runs once; Run setup again):**
a setup plan's preview ID is also its workflow ID, so a plan can run only once.
`approve` returns a run that is still in progress, so a double-click stays harmless.
For a finished run (succeeded, checked, failed, cancelled, interrupted or cleanup
required) it throws `alreadyRun` instead of returning the old run as if it had just
started. `prepareApply` refuses any plan whose workflow has a job, and `apply` never
replays a finished submission. Change setup opens on the guest's latest plan and shows
how its run ended in place of Review this run…. **Run setup again** is offered after any
finished run, success included, but not while a cleanup hold remains (recover or
release first). It makes a fresh plan with a new ID from the same choices, re-planned
with the current pinned engine from the private input tree frozen for the last run. It
never rereads the live source folder. The review says when dev-vm has changed since the
last run and which features were added or removed, and the normal consent checkboxes
still apply. After Run setup the sheet shows the new run's live state, or names why it
didn't start.

**VERIFIED — source review, 8 November 2026:** the frozen tree holds the choices, not
the original `ProvisioningSetupSource`. `freezeSelection` bakes profiles, features,
trim and appearance into `.omarchy-manager-selection.json` (plus the layout file), so
re-planning the tree reproduces the selection. The tree's input digest covers files and
folders only, not the engine, so it stays the same across engine updates. A different
plan digest then shows the engine changed. What was missing was the link from a guest
to its latest plan and from a plan to its tree.

**DESIGN DECISION / PRIVATE COUPLING — plan history:** when a run is accepted, the
manager records its plan ID, VM, tree name (`inputs-<UUID>`, not a path), manifest, plan,
input and engine digests, and resolved feature names. The record goes in a private
`plans/plans.json` beside the job and workflow journals, bounded at 128 entries, keeping
each guest's latest. The workflow journal's schema is unchanged, so earlier builds can
still read it. A damaged history file is preserved and refuses new records, so no run
starts without the record its retry needs. Creation plans that ran before this record
existed are found through the creation receipt by their input digest. The creation
receipt in the VM profile is never rewritten.

**TO PROVE:** Run setup again on a real guest, including after a dev-vm pin update, has
been checked only with fake runtimes and local fixtures. It needs a run by hand on a
real Mac.

**DESIGN DECISION — user direction, 9 November 2026 (Change setup like New VM):**
Change setup is its own sheet in New VM's shape, replacing the Source picker, preview
lookup, Details and separate prepare and approve steps. It shows a four-step strip
(Approve · Install · Restart · Check) with one sentence for the current state. Below that
come `layout` and `customise`, started from the last recorded plan's choices, then the
separate consents, then one button whose label says what happens. **Run setup again**
uses `prepareRetry` for the exact frozen choices. **Apply changes** makes a new preview
from the edited draft; a setup from a local folder needs its folder chosen again. **Start
& set up** starts a stopped guest first. View output keeps the terminal, cancel and job
details. The old in-sheet review panel is removed.

**DESIGN DECISION — user direction, 9 November 2026 (one approval per run):** the
approve-at-creation rules above now also cover Change setup. Its main button, or
Approve & run, is the explicit permission for that one run's apply, restart and
configuration check. The approval:
- lives only in the manager's memory and is used at most once;
- binds to the guest's current session, or for Start & set up the first session seen
  after launch;
- follows only the workflow it submitted;
- prepares and submits each finishing step once, bound to the approved plan and input
  digests;
- never recovers cleanup automatically.

A mismatch, interruption or manager restart ends the automatic path and leaves the
reviewed actions. Restart & check in the sheet covers both steps for a run nobody is
following.

Earlier finished runs no longer stop an approval from applying. Another run in
progress, or a cleanup hold, still does.

**DESIGN DECISION — deliberate widening, 9 November 2026:** a Change setup approval may
carry an explicit **Allow Docker without sudo** acknowledgement through the automatic
path, because the sheet asks for it separately before the run. Creation still stops for
Docker. Custom-task trust always stops at Approve & run, after each task is inspected.

**FIX / DESIGN DECISION — pending runs, 9 November 2026:** a run prepared for approval
(a workflow row at `waitingForSSH` or `readyForReview`) had no plan record and was lost
when the sheet closed. It kept the service busy for every other plan, and Run setup
again stayed disabled. `latestSetup` now reports it as `pending`. Change setup shows it
again with Approve & run, using the same cached review from `prepareApply`, and Discard
this run, which cancels it with no hold and frees the service. A relaunch still turns it
into `interrupted`; reviews are never persisted.

**DESIGN DECISION — retrying a plan that never ran, 9 November 2026:** `prepareRetry`
also accepts a run that ended before it ran (discarded or interrupted, no apply job, no
hold) when its frozen inputs can be found. In practice that is a creation plan found
through its receipt. Other never-run plans have no plan record, so Change setup ignores
them and starts from the last recorded plan.

**DESIGN DECISION — user direction, 9 November 2026 (Run the check only):** a run that
applied and restarted, then stopped before its configuration check, can finish with that
check alone. The run must be `interrupted` with `processInterrupted`, have an apply job and
a restart, and have no cleanup hold. A restart is only ever approved from a clean
restart-required apply.

How the check runs:
- `runCheckOnly` builds a new workflow from that run's own frozen inputs.
- It refuses if the current engine would make a different plan; a full run is needed then.
- It prepares an Ansible check-mode job against the current session, with no custom
  tasks, and runs it at once. The click is the owner's consent, as for the reviewed
  restart.
- Check mode needs no admin grant. The helper channel refuses every grant and apply
  operation in check mode, so no sudo prompt appears and no new sudo model is introduced.
- It uses the existing workflow and job journals, with no schema change.
- On success the new workflow is `checked`. It becomes the guest's latest plan, so Run
  setup again repeats the same choices. The interrupted run is left as it was.
- If preparation fails, the check is cancelled rather than left waiting.

It is still not a general check of an arbitrary guest. Home and Change setup say
"Checking" for it from an in-memory list of check-only runs.

**VERIFIED — fake/local, 9 November 2026:** `ProvisioningRetryTests` and the offscreen
harness (204 checks, 50 images); see [Validation](docs/Validation.md#change-setup-rebuilt-like-new-vm--9-november-2026).
**TO PROVE:** the same flows on a real Dev guest: Run setup again and Apply changes
through restart and check, Start & set up, reopening a pending run, and Run the check only
on a guest whose run was interrupted after its restart.

The current pass permits source integration and fake/local/CI validation only.
No VM launch, real signing, host installation, Main app or Main VM operation is
authorized. **TO PROVE:** fresh signed normal-Dev and real-guest acceptance after
this change. Existing frozen artifacts/pins are preserved, not refreshed.

**VERIFIED — local integration:** 531 Swift tests per channel, 337 script tests,
140 UI checks, three optimized policy modes, fresh ad-hoc bundle/channel checks,
566 pinned-upstream Swift tests plus its no-VM contracts/shell/guest-package
checks, and isolated SSH-container tests pass. The upstream authentication-lease
assertion failed once under concurrent jobs and passed unchanged on TEST_JOBS=1;
its exact cause is unproven, and CI uses the verified serialized job setting.
All 86,034 prior private artifact entries and six pin hashes match baseline.
No Main operation, product VM launch or real signing occurs. Following an initial
automatic publication-review rejection, the user explicitly authorized both feature
branches and draft PRs: manager #10 to next and companion #8 to main. Test-only
hosted CI is in progress; branch release jobs remain skipped. CI exposed the
preinstalled Swift 6.1 / bundled SwiftTerm 6.2 minimum mismatch, then a Swift 6.2
helper C-string inference issue; the toolchain selection and explicit conversions
are corrected. Companion process fixtures run serially without changing deadlines.
Hosted results are tracked separately from the completed local checks. The
companion hosted pass is green. The next manager pass exposes terminal attach
contention and a CLI fixture delivery race; bounded pre-dispatch-busy waiting and
observed-output synchronization address them, with fifteen focused local tests
passing. The full hosted rerun is pending; process/lease limits stay unchanged.

## Dev draft publication recovery — user authorization, 5 November 2026

**USER AUTHORIZATION:** fix draft lookup in a PR targeting `next`, then recover and publish the exact retained Dev release without rebuilding it. Leave installed apps and all running work VMs untouched. No local signing identity, credential import, notarization submission, permission grant, installation or guest operation is needed.

**VERIFIED — failure:** run `41997334573`, source `3b7fbdd1c070a026cade3f3fb959757a9571c3c7`, passed both test jobs and signing/notarization/package verification for `v0.11.3-dev.1` (118). The publisher created draft `434969897`, but its immediate tag/list lookup returned no match; it stopped before uploading assets. A later authenticated read found the empty draft. Retained artifact `13401208496` has SHA-256 `987cb4fbb2fdb3bbaf9901ec15f78a1afcad874257ef93ef8c4ef783efa59023`. Delayed API visibility remains a hypothesis, not a proven root cause.

**DESIGN DECISION:** consume the release-creation response and retain its numeric ID for uploads, verification and publication. Verify ID/tag/channel and complete asset digests before finalization; preserve immutable reservations, existing bytes and Dev's non-Latest status. Explicit manual recovery validates the original retained artifact and signed package before publishing by ID; ordinary CI-only admission remains unchanged. **TO PROVE:** fixed CI publication and exact retained-release recovery until their results are recorded.

**VERIFIED — recovery and no-VM checks:** `v0.11.3-dev.1` (118) was published from that same draft at `2026-11-05T09:11:18Z`; all nine server asset hashes/sizes match the retained candidate. App ZIP SHA-256 is `e8cb3e17682bc5f5c400ee819ab30d7de068dae7e6ceeedf3dbeeaafb80d9d96`. Original Apple acceptance binds to the submitted archive; only the outer staple ticket was added afterward. Source/reservation/version/build/profile/runtime inventory, signatures, notarization, stapling and Gatekeeper pass. The unchanged layout validator uses identical previously authenticated CI artwork; cross-host Dev icon byte equality remains a cosmetic limitation. Stable `v0.11.2` stays Latest and its assets are unchanged. `make test` passes 256 Swift and 106 script cases, including 20 branch-release cases. No rebuild, local signing, resubmission, installed-app or VM operation occurred. [Recovery receipts and limitations](docs/BranchReleases.md#failures-and-retained-artifacts) distinguish manual success from **TO PROVE** future CI creation/publication and native behavior; the original run remains failed.

## Saved account defaults apply automatically — user correction, 5 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** saved Guest Defaults are the account
values to apply to new VMs. Remove the redundant global enable checkbox. A valid
saved configuration/password reference applies by default, including legacy saved
metadata with the old enable flag off. Retain an explicit per-VM manual choice.
Keep existing profiles/disks, reused-home account identity, Stable/Dev isolation,
credential authorization and provisioning execution permissions unchanged. Never
rewrite a saved defaults file merely to load it.

**VERIFIED — fake/local:** 75 focused core tests and 130 offscreen UI checks pass
with synthetic services/credentials, including legacy metadata, default/manual
creation, credential-policy mocks and channel isolation. No live credential,
manager/guest operation or host install occurs. **TO PROVE:** real first boot with
these revised defaults semantics. See [account defaults](docs/UnattendedDefaults.md#saved-values-apply-automatically--5-november-2026).

## First Dev publication — user authorization, 5 November 2026

**USER AUTHORIZATION:** create `next` from `main`, validate the supplied separate Dev provisioning profile, configure its CI secret and publish the first Dev release. Leave installed apps, all running work VMs and their data untouched. Use the existing signing/notarization credentials only in CI; no local private signing identity, permission, installation or real guest action is needed.

**VERIFIED — profile and configuration:** the supplied profile has SHA-256 `72f28fde740d74483648ce7027d45d70d325627629c7e4141f4282a40abaa83c`, exact Dev App ID/team/macOS Developer ID distribution scope, expiry `2044-10-31T04:26:29Z`, and authorizes the existing CI signing certificate (`d4964c47ed12f244ab4302d324d1e7903451c15239243d0749794f661965e1b3`). Its CMS signature verifies, its Apple profile signer exactly matches stable's, and local basic certificate trust passes. This is not an independent fresh revocation check. Pin only its digest for `dev.omarchy.vm-manager.dev`; its exact bytes were supplied through stdin to `MACOS_DEV_KEYCHAIN_PROFILE_BASE64` without printing or committing them. Stable's profile pin and CI secret are unchanged. `next` was created from main `671b50238bf497ee64b58331c75582e9567004f3`; its initial profile-less run was cancelled before signing.

**VERIFIED — prior stable baseline:** stable `v0.11.1` (112) was published as Latest by CI run `41959356022` from that exact main commit. All ten downloaded asset hashes, complete source/runtime provenance, profile/certificate/entitlement checks, signatures, notarization, stapling and Gatekeeper pass independently, with host preflight and VM launch disabled. Apple acceptance logs bind to the exact retained original runtime/app archives; only the independently validated outer staple tickets differ from publication. Public app ZIP SHA-256 is `1ebbc5be68c87adce6d49e774e6b48cae6a3d8201c7b82a3b2d4db3432679ae9`; reusable signed runtime is `ea2ec7241af45c4e31d452fb398ab31234dedf0d7e1349f2e576f3e6ba542a23`. Exact successful Actions artifact `13384963226` and evidence remain under ignored `VendorArtifacts/signed-candidates/v0.11.1/`. No installed app or running VM was changed.

**VERIFIED — no-VM configuration checks:** `make test test-dev` passes 256 Swift tests in each channel and 102 script tests. The new pin validates the exact supplied Dev bytes; stable's original profile pin remains unchanged. Diff checks pass. Only the digest and scoped documentation are committed; the raw profile is not stored in Git.

**TO PROVE:** first Dev CI publication, provisioned Dev download verification and native behavior of the distributed Dev app. The new profile and no-VM checks do not prove authentication UI, guest behavior or focus/sleep/wake/crash cases. Reuse the exact verified signed runtime; do not rebuild/re-pin or alter stable's Latest release.

## Stable branch publication — user authorization, 5 November 2026

**USER AUTHORIZATION:** upload the exact pinned source kit and publish the stable release through the existing CI-only signing/notarization path. Leave installed apps and all running work VMs untouched. Dev provisioning remains deferred. No local real signing identity, permission, installation, guest launch or existing-VM operation is authorized or needed.

**VERIFIED:** source-kit dependency `runtime-kit-5b30b9b3a82a80eac5c32e96302a8abe5d8a50c9a05853b876f0603a63839839` is published as a non-Latest prerelease. All four server digests/sizes match the reviewed originals; anonymous downloads match every byte, and the downloaded archive inventory/manifest pass. Source lock SHA-256 is `2e7fc6a4c5acf20330d4f05e30e69a7163d595133b99adffa77fbf3a7a481991`. No runtime rebuild or re-pin occurred.

**VERIFIED / FIX:** live dependency upload exposed that GitHub's by-tag endpoint omits unpublished drafts. The publisher now falls back to the authenticated paginated release listing, refuses ambiguous drafts and preserves exact-byte upload/finalization gates. Local `make test` passes 256 Swift and 102 script tests, including new draft lookup and create/upload/verify/publish regression cases. The original main run was cancelled before signing to apply this fix. **TO PROVE:** corrected CI publication and independent validation of the signed stable download.

## Branch releases — user extension, 5 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** merge PR #5 only after its checks pass, then implement branch-driven releases in a separate PR. `main` publishes stable with automatic patch versions; `next` publishes isolated Dev with `dev.N` prereleases. Publication uses the existing CI-only signing/notarization gates. The user chose to supply Dev's separate provisioning profile later; an unset digest/secret must fail clearly without using stable's profile. Leave installed apps and running work VMs untouched. No combined resource management is added.

**DESIGN DECISION:** reserve each version against the exact tested push commit, reuse reservations on retry, serialize both channels and refuse asset overwrites. Reuse exact signed runtime dependencies by source-lock digest without weakening provenance or rewriting historical locks. Update checks remain within each app channel and installation stays manual. [Branch release policy and setup](docs/BranchReleases.md) record required source-kit publication, profile setup, queue/retry semantics and recovery limitations.

**VERIFIED:** PR #5's macOS and isolated SSH checks passed and it merged as `6276e53bfa13e3eb4a9004a6caaa1649d3e909ec`. **TO PROVE:** first real branch release, Dev provisioning/signature, live publication retries and native behavior of newly distributed builds. Implementation changes and no-VM tests do not authorize a local real signing identity, installation or any existing VM operation.

**VERIFIED — no-VM release implementation:** 256 Swift tests in each channel, 99 script tests, both debug builds, three optimized policy modes and optimized signed Dev compilation pass. Isolated ad-hoc stable/Dev assemblies verify generated version/build/tag, bundle layout/inventory/signatures, channel identity and mismatched-app refusal with host preflight/VM launch disabled. Workflow YAML and diff checks pass. [Exact checks and remaining publication/setup limits](docs/BranchReleases.md#no-vm-verification--5-november-2026) distinguish these fixtures from a signed/published release. No installed app, existing VM, real credential, permission or native UI was used or changed.

## Stable and Dev channels — user extension, 5 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** implement the split in a dedicated worktree. The existing app identity and all existing VMs/configuration remain stable. Add a separate Dev build with an independent bundle identity, data directories, application/registry locks, activation notification, CLI endpoint and executable, defaults, credentials, imported factories, Downloads cache and guest Touch ID keys. Do not add combined resource management or Dev resource caps; the user manages allocation across apps. Existing per-manager admission checks remain.

**PRIVATE COUPLING:** rebuild and pin the complete kit through the existing reproducible upstream pipeline to resolve the enclosing Dev app for factory-cache and native-authentication-key paths. Preserve the original stable native prompt lease path so new Dev helpers coordinate with already installed stable helpers; only this non-secret lease is shared. Preserve guest packages, QEMU, firmware, factory contracts, existing signed runtime history and all personal data. Dev refuses a runtime without explicit channel-isolation capability. See [Stable and Dev](docs/DevelopmentChannels.md).

**TO PROVE:** real stable/Dev simultaneous guests, native permissions/credentials, focus, sleep/wake and crash behavior across channels. Implementation and no-VM validation authorize no installed-app replacement, existing-VM action, permission grant, real signing identity, credential access, image download or real guest launch.

**VERIFIED — no-VM implementation:** 255 Swift tests in each compiled channel, 82 script tests, both app/CLI/helper builds, both ad-hoc bundle/signature/layout checks, packaged mixed-channel refusal and both optimized admission/credential modes pass. The complete upstream suite passes 566 Swift tests and its no-VM shell/package/contracts. Runtime source `d6dd3dbe860f55302a66be884113e647e42b0eba` and kit `5b30b9b3a82a80eac5c32e96302a8abe5d8a50c9a05853b876f0603a63839839` are pinned; QEMU, firmware and guest-package payloads match the previous kit exactly. No installed app, existing VM, permission, real credential or native UI was used or changed. [Exact checks and limitations](docs/DevelopmentChannels.md#evidence) remain separate from real guest acceptance.

**USER AUTHORIZATION / VERIFIED — subsequent installation and opening:** at the user's explicit request, installed Dev as a new `~/Applications/Omarchy VM Manager Dev.app` and opened only its manager window alongside stable. Staged/final bundle verification and complete source/installed file-mode/hash equality pass. Both existing stable work-VM sessions and all 17 captured stable manager/runtime process identities are unchanged; stable registry/defaults and installed stable executable/metadata hashes match baseline. Dev responds with zero guests and owns one visible manager window. No existing app was replaced or restarted, no guest was launched or modified, and no permission, saved credential, real signing identity or factory download was used. [Scoped installation evidence](docs/DevelopmentChannels.md#authorized-dev-installation--5-november-2026) establishes manager coexistence, not real Dev-guest, focus, authentication, sleep/wake or crash acceptance.

**USER AUTHORIZATION / VERIFIED — disposable Dev guest coexistence:** the user explicitly requested creating and running a disposable test VM alongside the stable work VMs, without changing or stopping them. A new Dev UUID boots from the normally verified/imported local format-2 factory with 4 GiB/four CPUs, single 64 GiB system disk, NAT, manual owner setup and disabled SSH/sharing/clipboard/authentication. It reaches Ready, owns a native guest window and reports kernel `7.3.0-7-omarchy` with package `0.1.0-47.1`. Pause/Resume acknowledgements and a later guest heartbeat pass. Normal shutdown records matching `Exited (0)`; all six captured test runtime processes are gone, the disk has no open handles and its runtime-compatible lock is available. Both stable sessions, all 17 stable core process identities, stable configuration/settings hashes and VM disk identities remain unchanged throughout. No stable lifecycle/guest command, saved credential, permission, UI takeover, signing identity or factory download is used. The stopped test root/profile and imported Dev factory remain retained pending a separate Trash decision. [Exact acceptance scope and remaining TO PROVE cases](docs/DevelopmentChannels.md#authorized-disposable-dev-guest-acceptance--5-november-2026) preserve the distinction between basic coexistence and untested desktop/SSH, focus/clipboard, authentication, cache, sleep/wake, crash and workload behavior.

**USER AUTHORIZATION / VERIFIED — approved disposable Dev Trash:** the user explicitly authorized moving only that test VM to Trash. After fresh stopped/root/marker/process/disk-handle/runtime-lock checks, the installed Dev manager's guarded `delete` succeeds. The original root and test profile/session are absent; both stable sessions, captured processes, configuration/settings hashes and disk identities remain unchanged. Other Dev profiles/defaults and unrelated filesystem metadata, including the imported factory, match baseline. All six captured test runtime processes remain absent. No other VM, app or factory was targeted and Trash was not emptied. [Cleanup evidence and the macOS privacy limit on independent Trash-destination inspection](docs/DevelopmentChannels.md#approved-disposable-dev-cleanup--5-november-2026) distinguish the native helper's verified success from an unobserved destination inode.

Status: implementation-ready project brief  
Prepared: 31 October 2026 (Australia/Melbourne)  
Target: a new native macOS SwiftUI application named **Omarchy VM Manager**  
Upstream baseline: Try Omarchy `v1.3.0`, commit `13d63df8da2947f833c04025ff5ade187d39ba81`

## 1. Executive intent

Build a small, standalone macOS application that creates, lists, starts, stops and safely removes multiple independent Omarchy virtual machines. More than one VM must be able to run at the same time. The manager owns orchestration, profiles and shared-host policy; the official Try Omarchy kit continues to own QEMU, the guest image, VM boot, QMP shutdown, Mac sleep/wake handling, image download, host integrations and the guest settings window.

The central boundary is:

> Own the multi-VM management layer, not the virtual machine implementation.

The application must use the official `TryOmarchyKit.bundle` architecture and `TryOmarchyKitClient`/`VMRunClient` from Try Omarchy 1.3. It must not fork QEMU, modify the Omarchy image, invent a second VM protocol or copy the Try Omarchy launcher into this project. Because stock 1.3 does not focus-gate its global clipboard bridge, the POC requires one targeted helper patch built through the official kit pipeline; the intended end state is that patch merged upstream and consumed from a later official release.

The first decision gate is a real two-VM proof of concept on Apple Silicon. Source inspection shows that separate storage roots and separate QEMU processes are structurally supported, but upstream does not claim or test a multi-instance product. Do not invest in a polished manager until two independent guests have been run, slept/woken and stopped independently on a real Mac.

## 2. Evidence labels

This document uses four labels so implementation does not accidentally turn a hypothesis into a contract.

- **VERIFIED — v1.3.0:** confirmed in the tagged Try Omarchy source, its published release metadata or the published kit manifest.
- **DESIGN DECISION:** a choice for Omarchy VM Manager, not an upstream behaviour.
- **PRIVATE COUPLING:** confirmed v1.3.0 behaviour that is not exposed by the public `TryOmarchyKitClient` API. Keep it isolated, versioned and covered by contract tests.
- **TO PROVE:** plausible from source, but not demonstrated with two real simultaneous VMs.

## 3. Goals and non-goals

### Goals

- Create manager-owned VM profiles with stable UUIDs, human-readable names and independent storage roots.
- Run at least two QEMU-backed Omarchy VMs concurrently, with one retained `VMRunClient` per active VM.
- Give every VM an independently visible lifecycle, progress, error and exit state.
- Prevent the manager from launching the same storage root twice.
- Enforce an aggregate memory budget and warn on CPU oversubscription.
- Detect and reserve conflicting NAT host ports before launch, while treating QEMU's bind as authoritative.
- Launch new manager-owned guests with automatically provisioned, host-accessible SSH, and report SSH readiness only after a verified authenticated connection. No manual guest-console bootstrap or clipboard setup should be needed.
- Provide a working Mac clipboard in every running VM, routed only to the currently focused QEMU guest so background VMs neither receive nor publish clipboard changes.
- Shut down guests gracefully, make forced power-off explicit, and prevent deletion while any session can still touch the VM.
- Pin, verify, embed and sign a known Try Omarchy kit.
- Keep the UI intentionally small and native.

### Non-goals for v1

- General-purpose support for arbitrary operating systems.
- Snapshots, cloning, migration, import/export or moving VM storage.
- Embedded guest display, VNC, SPICE, general-purpose terminal, interactive SSH client UI or file browser. A future terminal scoped to approved developer-provisioning jobs is the exception described under the 2 November 2026 provisioning decision below; milestone 1 adds dependency checks only. Provisioning guest SSH access and exposing connection details for host tools are in scope.
- Background clipboard broadcast or a one-VM-only clipboard compromise. A focus-aware runtime fix is a required prerequisite, not a deferred feature.
- More than one bridged-network session.
- Bridged networking at all in the proof of concept or first private MVP.
- USB/camera arbitration, automatic runtime updates or in-app kit downloading.
- A Mac App Store build.
- Replacing Try Omarchy's guest settings UI.

## 4. Verified upstream baseline

All statements in this section were checked against the tagged `v1.3.0` source and release on 31 October 2026.

### Release and package facts

- **VERIFIED — v1.3.0:** `v1.3.0` is a GitHub prerelease published on 23 October 2026. GitHub still identifies `v1.2.0` as the latest stable release. The 1.3 release note says it is the prerelease app, kit and image that Omarchy Installer pins.
- **VERIFIED — v1.3.0:** the tag resolves to commit `13d63df8da2947f833c04025ff5ade187d39ba81`.
- **VERIFIED — v1.3.0:** the published kit manifest is:

  ```json
  {
    "format": 1,
    "version": "v1.3.0",
    "runProtocolVersion": 1,
    "buildDate": "2026-10-23T17:38:57Z"
  }
  ```

- **VERIFIED — v1.3.0:** release assets include `TryOmarchyKit.zip`, `TryOmarchyKit.zip.sha256`, `TryOmarchyKit.json`, `TryOmarchy.dmg` and three factory-image parts. The kit zip is 14,460,427 bytes and its published SHA-256 is `3ad65381b34ced2ebe3f5f19b95d58ec1a2c51a77a6edf7599666a939b6991a6`.
- **VERIFIED — v1.3.0:** `TryOmarchyKit.zip` contains one top-level folder, `TryOmarchyKit.bundle`. The kit carries the helper, QEMU runtime, firmware, scripts, guest integration package and image download manifest. It does not carry the approximately 3 GB factory image; a new storage root downloads the release's image parts on first start.
- **VERIFIED — v1.3.0:** the Swift package manifest is at `macos/Package.swift`, not the repository root. It uses Swift tools 6.0, targets macOS 15 or newer and exports the `TryOmarchyKitClient` library product.
- **DESIGN DECISION:** pin the whole upstream repository as a git submodule at the exact commit and add `Vendor/try-omarchy/macos` as a local Swift package. Do not depend on the repository root as a remote SwiftPM package, and do not copy the four client source files into this repository.
- **VERIFIED — current upstream:** issue [#145, Multiple instances](https://github.com/omacom/try-omarchy/issues/145), remains open with no assignee, milestone, comments or linked pull request. Multi-instance operation is not an advertised Try Omarchy feature.

### Public client surface to use

| Public symbol | Verified behaviour relevant to this project |
| --- | --- |
| `TryOmarchyKit.embedded(in:)` | Finds `Contents/Helpers/TryOmarchyKit.bundle` in an app bundle. |
| `TryOmarchyKit.unpacked(in:)` | Finds an unpacked kit in an external folder. Useful for tests, not the v1 production path. |
| `TryOmarchyKit.helperURL()` | Validates that the bundle and executable helper exist in the expected layout. |
| `TryOmarchyKit.manifest()` | Reads and validates `kit.json`. `TryOmarchyKitManifest.isSupported` requires the kit's run protocol to equal the client's protocol. |
| `TryOmarchyKitVersion` | Parses `vMAJOR.MINOR.PATCH` or `development` and supports version comparison. |
| `TryOmarchyStorage` | Exposes the default Try Omarchy root plus `hasVM`, required/free-space and allocated-space queries for a supplied root. It does not provide create, move or delete operations. |
| `VMRunClient.preflight()` | Rejects macOS older than 15, non-Apple-Silicon hosts and hosts without Hypervisor support. |
| `VMRunClient.start(_:environment:onEvent:)` | Launches `omarchy-vm-helper --run-vm`, sends one configuration line and follows ordered events on a private serial queue. One client refuses a second concurrent start of itself. |
| `VMRunClient.isRunning` | True from a successful start attempt until final cleanup. |
| `VMRunClient.recentStandardError` | Bounded tail of helper diagnostics, suitable for an error detail view and logs. |
| `VMRunClient.shutDown()` | Requests a guest shutdown. The helper waits up to 60 seconds before stopping QEMU. |
| `VMRunClient.terminate()` | Immediate power-off semantics; it sends two signals and kills a stuck helper after a five-second default grace period. Unsaved guest work can be lost. |
| `VMRunConfiguration` | Supplies product name/icon, explicit storage root, optional bridges, fallback memory/CPU and fallback shared/bridged networking. |
| `VMRunEvent` | `progress`, `notice`, `ready`, `stopping`, `error` and terminal `exited`. `exited` arrives only after the helper ends, at which point the client can be reused. |
| `VMRunErrorCode` | Stable codes include `vm-already-open`, storage failures, port/launch failures, sleep/wake failures and compatibility failures. Messages are not stable identifiers. |

Important public constraints from `VMRunConfiguration.validate()`:

- product name: 1–64 characters, no leading/trailing whitespace or control characters, and no more than 255 UTF-8 bytes;
- storage root: absolute, single-line path no longer than 1,024 characters;
- icon: existing regular `.icns` or `.png` at an absolute path;
- memory fallback: 2,048–1,048,576 MiB;
- CPU fallback: 1–1,024;
- bridge choices: `clipboard`, `authentication`, `camera`, `battery`, `timezone`;
- networking: `shared` (NAT) or `bridged`.

`VMRunConfiguration` defaults to all optional bridges. Omarchy VM Manager must always pass an explicit restricted bridge list.

### Verified runtime behaviours that make concurrency plausible

- A configuration can name an explicit `storageRoot`; that folder is the VM.
- `VMRunClient` and `VMRunSession` are instances, not global singletons. One manager can retain multiple clients.
- Persistent storage is locked at `<storageRoot>/shell/lock`. A second launch of the same root fails instead of sharing a disk.
- Each run creates a private `mktemp` work directory. QMP, audio, clipboard, authentication, camera, battery, timezone, guest-status and settings sockets are per-run.
- QEMU holds the VM lock for its full lifetime.
- QMP, download, sleep/wake, removed-volume handling and graceful shutdown are already owned by the kit.
- The run-mode helper shuts down when asked, when standard input closes or on its first termination signal. If the manager crashes or is force-quit, the child sees its input close and begins a guest shutdown.
- A product name is used for the QEMU window, Dock entry and application menu. This gives concurrent guests distinct visible identities without the manager embedding their displays.

### Verified limitations and hazards

#### Stored settings override configuration fallbacks

Memory, CPUs and networking in `VMRunConfiguration` are only fallbacks. Values in the VM's `settings.json` win. Port forwarding, shared folder, USB, immersive mode and camera-notch settings are stored-only and have no public configuration field.

Older Try Omarchy settings are also relevant. Up to Try Omarchy 1.2, settings lived in the `dev.tryomarchy.native` UserDefaults domain. In 1.3, a key in a VM's settings file wins—even when its value is `null`; an absent key can fall back to the old UserDefaults value. A newly named storage folder can therefore inherit an old global setting unless the manager deliberately initializes the per-VM file.

This invalidates a naive resource policy that only totals the manager's requested fallbacks.

#### Clipboard is not multi-session aware

Each enabled clipboard bridge polls the same global `NSPasteboard.general` every 250 ms and maintains only its own two-endpoint echo-suppression state. It does not test QEMU focus. With two unmodified 1.3 clipboard bridges, content can propagate between guests through the Mac pasteboard.

The public API chooses bridges only at process start. It exposes no QEMU PID, focus event or dynamic enable/disable command. A correct focus-aware clipboard broker cannot be implemented solely in the manager against v1.3.

**DESIGN DECISION / REQUIRED RUNTIME PREREQUISITE:** do not solve this by disabling clipboard on all but one VM. Add focus gating to Try Omarchy's existing `NativeClipboardBridge`, which already receives the target QEMU PID, and propose that small change upstream. The public `VMRunClient` protocol does not need to change. Until the change is accepted in an official release, a private POC may use a source-built, digest-pinned kit based on v1.3.0; a distributable manager must not pretend the stock v1.3.0 kit provides safe multi-VM clipboard.

#### Port forwarding has no public configuration or inspection API

NAT forwards bind to Mac loopback. The kit validates each VM's mappings and probes host availability immediately before QEMU starts; QEMU's actual bind remains authoritative. Two VMs cannot both own the same `(protocol, hostPort)`.

The mappings live under the private `portForwardingPreferences` setting. The public client cannot read them, and `VMRunConfiguration` cannot set them.

#### Bridged networking is single-session

The v1.3 networking runtime reports a specific error when another bridged session is active or finishing cleanup. Bridged networking also needs a privileged launch daemon registered by the embedding app. NAT is the only acceptable v1 default.

#### Resource validation is per VM

The launcher checks one VM at a time. Its shell-level memory rule allows the 4 GiB baseline, otherwise requiring at least 4 GiB to remain for macOS. It does not subtract memory already assigned to other QEMU processes.

#### There is no public window activation API

The manager cannot reliably implement an “Open” or “Bring to Front” action for a guest. v1 should rely on the distinct QEMU Dock entries and macOS window switching.

#### First-start work is duplicated per independent root

Each manager-owned storage root has its own `shell-factory` cache. Starting two new VMs can cause two independent image downloads and decompressions. The public configuration has no shared-factory-cache field.

## 5. Product definition

The first usable application is a development-focused VM list, not a Parallels competitor.

### Main window

Show:

- application title;
- number of running VMs and their total configured memory;
- a **New VM** button;
- one row per VM with name, state, memory/CPU summary, storage used and last error;
- **Start**, **Shut Down**, **Force Stop** and **Delete** actions as permitted by state;
- progress text and percentage while downloading or preparing;
- a clipboard-enabled badge for each profile; do not claim live bridge health because run protocol 1 exposes no bridge-specific status event.
- for SSH-enabled profiles, the host SSH endpoint and separate provisioning/readiness status, plus a **Copy SSH Command** action; never include private-key contents.

Do not add guest thumbnails, embedded consoles, settings duplication or resource graphs to v1.

### Create sheet

Collect:

- display name;
- memory fallback;
- CPU fallback;
- whether clipboard integration is enabled for that VM (on by default once the focus-aware runtime prerequisite is present).

Networking is fixed to NAT in v1. Ports are configured through the kit's existing guest settings window after the VM is first run; the manager only inspects and arbitrates them before subsequent launches.

### State presentation

Use a closed state model rather than independent booleans:

```swift
enum VMState: Equatable, Sendable {
    case stopped
    case validating
    case downloading(phase: VMRunPhase, percent: Int?)
    case starting(phase: VMRunPhase, percent: Int?)
    case running
    case stopping
    case failed(VMFailure)
}
```

`failed` is a stopped state with retained diagnostic context; it never means a client is still touching the VM. A VM remains in a transitional/running state until the matching `.exited` event.

## 6. Architecture

```text
SwiftUI application / AppDelegate
        |
        v
VMManager actor ---------------- RegistryStore
  |       |                      manager-owned metadata
  |       +-- HostResourcePolicy
  |       +-- PortReservationLedger
  |       +-- ClipboardCapabilityPolicy
  |       +-- UpstreamSettingsSnapshotReader [private v1.3 coupling]
  |       +-- StorageSafety / StorageTransactionHelper
  |
  +-- RuntimeSession(UUID) ---- VMRuntime protocol
                                  |
                                  +-- TryOmarchyRuntime
                                        one VMRunClient per active VM
                                        explicit storageRoot
                                        explicit bridges
                                        shared/NAT networking
                                                |
                                                v
                                      TryOmarchyKit.bundle
                                      with required focus-aware clipboard fix
                                      helper -> QEMU process per VM
```

### Targets

1. **OmarchyVMManagerApp** — SwiftUI app entry point, views, commands and AppDelegate termination coordination.
2. **OmarchyVMManagerCore** — models, registry, actor, policies and a runtime abstraction; no SwiftUI dependency.
3. **OmarchyVMStorageHelper** — small manager-owned executable for destructive storage transactions under a process-scoped POSIX lock.
4. **OmarchyVMManagerCoreTests** — fast unit and contract tests.
5. **OmarchyVMManagerUITests** — minimal create/start/stop state presentation tests once the shell is stable.

### Runtime abstraction

Keep the abstraction narrow and shaped around what the product needs, not around every kit type:

```swift
protocol VMRuntime: Sendable {
    func preflight() -> VMRunError?
    func start(_ request: VMStartRequest,
               onEvent: @escaping @Sendable (VMRuntimeEvent) -> Void) throws -> VMRuntimeHandle
}

protocol VMRuntimeHandle: AnyObject, Sendable {
    var isRunning: Bool { get }
    var recentStandardError: String { get }
    func shutDown()
    func terminate()
}
```

The production adapter wraps `VMRunClient`; tests use a deterministic fake. Do not attempt to make an arbitrary-hypervisor framework.

### Concurrency and ownership

- `VMManager` is an actor and the single authority for registry mutations, state transitions, launch admission, port reservations and client retention.
- UI-facing snapshots are published on `@MainActor` through a small observable view model.
- `VMRunClient` delivers events on its private serial queue. Every callback immediately enters the manager actor before changing state.
- Every start gets a fresh `sessionID`. Ignore an event whose `(vmID, sessionID)` no longer matches the active session.
- Retain the client until `.exited`, even after `.error`. `.error` is diagnostic; `.exited` is the lifecycle boundary.
- Do not reuse one client across concurrently active VMs.

## 7. Persistence and storage

### Manager data layout

```text
~/Library/Application Support/Omarchy VM Manager/
├── registry.json                         # 0600, atomic, schema-versioned
├── VMs/                                  # 0700
│   ├── <uuid>/                           # explicit storageRoot, 0700
│   │   ├── .omarchy-vm-manager.json      # manager ownership marker, 0600
│   │   ├── .omarchy-qemu-storage         # upstream v1 marker, 0600
│   │   ├── settings.json                 # upstream settings file, 0600
│   │   ├── shell/
│   │   └── shell-factory/
│   └── ...
└── Logs/                                 # bounded manager logs; no clipboard content
```

`registry.json` stores only manager metadata: schema version, UUID, display name, created date, manager resource defaults and whether clipboard integration is enabled. The storage path is derived from the UUID, not accepted from the JSON as an arbitrary absolute path.

Phase 3A adds versioned SSH metadata: enablement, allocated loopback port, intended guest username, credential reference and pinned public host identity. Private keys and passwords never belong in the registry or logs.

### Creation invariants

For v1, all roots are manager-owned and below the fixed `VMs` directory. Importing or using an arbitrary external path is deferred.

Before the first start:

1. Create the UUID directory with mode `0700` and verify owner, type and canonical parent.
2. Atomically create `.omarchy-vm-manager.json` with the UUID and schema version, mode `0600`.
3. **PRIVATE COUPLING:** create the v1 upstream marker `.omarchy-qemu-storage` containing exactly `omarchy-qemu-storage-root-v1\n`, mode `0600`.
4. **PRIVATE COUPLING:** create v1 `settings.json` with schema 1 and every known inherited setting key explicitly set to `null`. This prevents a new manager VM from inheriting old Try Omarchy 1.2 global preferences while allowing configuration fallbacks to apply.

The initialized settings object should contain these v1 keys as `null`:

```json
{
  "schemaVersion": 1,
  "settings": {
    "vmResourcePreferences": null,
    "memoryPreferences": null,
    "networkPreferences": null,
    "portForwardingPreferences": null,
    "sharedFolderPreferences": null,
    "usbDevicePreferences": null,
    "fullscreenPreferences": null
  }
}
```

This is the smallest private compatibility layer that makes new roots deterministic. Isolate marker/settings knowledge in `TryOmarchyV1StorageContract`; do not scatter keys through the application.

For future SSH-enabled profiles, Phase 3A may intentionally initialize a validated manager-owned SSH mapping after this null initialization and before first launch, using the supported kit API or a separately reviewed versioned adapter. This is an explicit creation step, not inheritance from global preferences. Existing mappings must not be silently overwritten during launch admission.

### Deletion invariants

Deletion means moving the manager-owned root to the macOS Trash, not recursively erasing it in place.

Allow deletion only when:

- the manager state is stopped/failed and there is no retained client;
- no start/stop/create transaction exists for the VM;
- the canonical target is exactly `VMs/<registered UUID>`;
- the manager marker is a private regular file and contains the same UUID;
- a dedicated helper process acquires the same style of non-blocking POSIX lock used by the runtime on `shell/lock` and holds it through the move to Trash.

The helper must refuse symlinks, a missing/invalid marker, an unknown marker schema, unexpected ownership, group/world-writable directories, a busy lock or a path outside the manager root. It returns a structured result. The manager removes the registry entry only after Trash succeeds. A failed move leaves both registry and VM intact.

## 8. Launch admission and lifecycle safeguards

### Start algorithm

All of these steps run as one manager-actor transaction until the client has been successfully started:

1. Require state `stopped` or `failed`; assign a fresh `sessionID` and move to `validating`.
2. Resolve and validate the manager-owned canonical root and markers.
3. Reject if another active session has the same canonical root or file-system resource identifier.
4. Load and validate the pinned embedded kit manifest and provenance lock. Stock/reference mode requires exactly `v1.3.0`, protocol 1 and `isSupported == true`. Clipboard POC mode permits `development` only in a non-release build whose exact patch commit and kit digest match the committed runtime lock. Release builds reject `development`.
5. Run `VMRunClient.preflight()` and `kit.helperURL()`.
6. Read a fail-closed effective settings snapshot for memory, CPU, network and port mappings.
7. Require shared/NAT networking for v1. If stored settings request bridged mode, explain that it must be changed to Shared connection before this manager can start it.
8. Calculate effective resources: stored v1 resource settings, then the configured fallback. Reject an unknown or malformed resource schema rather than guessing.
9. Apply the aggregate host resource policy and storage free-space policy.
10. Reserve every `(protocol, hostPort)` in the manager ledger; report the owning VM for manager conflicts. Probe the operating system for external conflicts.
11. Require the focus-aware clipboard capability when clipboard is enabled, then build an explicit bridge list including `.clipboard`. Refuse concurrent clipboard launch against an unmodified stock v1.3.0 kit rather than falling back to unsafe broadcast behaviour.
12. Construct `VMRunConfiguration` with a unique product name, explicit root, explicit bridges, effective fallback memory/CPU and `.shared` networking.
13. Create and retain a new client, then call `start` with its default clean environment. Do not pass any `OMARCHY_*`, `TRYOMARCHY_*` or `SDL_*` override.
14. If `start` throws synchronously, release reservations and return to `failed`. Otherwise keep reservations and the client until `.exited`.

Serialize manager-initiated starts through admission. After `start` returns, a later VM can begin admission, but for a brand-new VM wait until the previous cold start is `.ready` before starting another download. This avoids two simultaneous 3 GB downloads/decompressions while still proving simultaneous QEMU execution.

### Event handling

- `progress`: map the upstream phase and percentage into downloading/starting UI. Unknown future events are already skipped by the client.
- `notice`: retain and display it without failing the session.
- `ready`: set `running`; this is the point at which a second cold VM may start.
- `stopping`: set `stopping`.
- `error`: retain stable code, reported code, message and sanitized stderr tail, but do not release anything yet.
- `exited`: clear the client, release ports/resource allocation, finish any quit coordination and choose `stopped` or `failed` based on the preceding error and status.

### Shut down and force stop

- Normal **Shut Down** calls `VMRunClient.shutDown()` once and changes state to `stopping`.
- The kit asks Linux to power down and stops QEMU if it has not exited after 60 seconds. The manager should show elapsed shutdown time but must not send repeated shutdown commands.
- **Force Stop** calls `terminate()` only after an explicit warning that unsaved guest work can be lost.
- Starting, deleting or editing launch-time policy remains disabled until `.exited`.

### Application termination

Use `NSApplicationDelegate.applicationShouldTerminate` via `NSApplicationDelegateAdaptor`:

1. If no clients are active, return `.terminateNow`.
2. Otherwise return `.terminateLater`, call `shutDown()` for every active session and show a compact “Shutting down N VMs” panel.
3. When every matching `.exited` arrives, call `reply(toApplicationShouldTerminate: true)`.
4. If the user cancels application termination, leave the VMs running.
5. If the app itself crashes or is force-quit, rely on the verified helper stdin-close behaviour; verify this in the POC rather than treating it as a substitute for normal coordination.

## 9. Resource policy

### Memory

Use physical memory, not currently-free memory, for deterministic admission.

Default hard budget:

```text
hostReserveMiB = max(4096, floor(physicalMemoryMiB * 0.25))
guestBudgetMiB = physicalMemoryMiB - hostReserveMiB
```

Reject a launch when the sum of effective memory for running, starting and newly requested VMs exceeds `guestBudgetMiB`. Show the calculation and identify the active allocations. Do not provide a “launch anyway” override in the first MVP.

For a new profile, propose 4,096 MiB when two such VMs fit the budget. On an 8 GiB Mac, a two-VM engineering POC may explicitly use the public minimum of 2,048 MiB per guest, but label it a constrained test rather than the recommended experience.

### CPU

CPU is oversubscribable. Warn when aggregate vCPU count exceeds the host logical processor count and block only when it exceeds twice that count. Keep the policy in one testable type so experience can change it later.

### Storage

- Use `TryOmarchyStorage.hasVM`, `requiredFreeBytes(at:)`, `freeBytes(at:)` and `allocatedBytes(at:)` for display and baseline checks.
- A new root requires the upstream 15,000,000,000-byte minimum; an existing VM requires 1,073,741,824 bytes.
- Add a manager margin of 2 GiB per start for logs, temporary files and concurrent work.
- Cold starts are serialized until `.ready`; this avoids double-counting changing free space during concurrent image preparation.
- Never infer safety from the sparse disk's logical size. Display allocated size from the upstream helper.

### Effective-settings reader

**PRIVATE COUPLING:** `UpstreamSettingsSnapshotReader` is a read-only decoder for the v1.3 `settings.json` keys needed for admission. It must reproduce the upstream file safety checks before reading:

- root is manager-owned, canonical and mode `0700`;
- file is a non-symlink regular file owned by the current user, mode `0600`, no larger than 65,536 bytes;
- outer `schemaVersion` is exactly 1;
- settings object exists;
- known payload schemas and ranges are exact;
- an unknown outer/payload schema, invalid type or invalid range fails closed.

Decode only:

- `vmResourcePreferences` (`schemaVersion: 1`, resources containing CPU, memory GiB and optional disk GiB);
- legacy `memoryPreferences` if no VM resource value exists;
- `networkPreferences` (`version: 1`);
- `portForwardingPreferences` (`schemaVersion: 1`, at most 32 TCP/UDP mappings with ports 1–65535).

Never rewrite the user's settings during launch admission. Initialization of a new manager-owned root is the only direct settings write in v1. Put fixture files copied from the tagged upstream tests under `Tests/Fixtures/TryOmarchy/v1.3.0/` and add a source-pin test that fails loudly when the vendored upstream keys or schemas change.

Recommended upstream follow-up: propose public read-only effective-settings and storage-initialization APIs in `TryOmarchyKitClient`. Remove this adapter when upstream supplies them.

## 10. Port safeguards

Use a `PortReservationLedger` owned by `VMManager`.

Rules:

- Reservation key is `(tcp|udp, hostPort)`. TCP and UDP may use the same numeric port; two TCP or two UDP mappings may not.
- Only NAT mappings are active. Bridged VMs are refused in v1.
- Reserve before calling `start`; release only on synchronous start failure or terminal `.exited`.
- A conflict with another managed session names that VM and mapping.
- Probe both TCP and UDP loopback availability for conflicts with other Mac applications.
- Serialize manager starts to close the race between two manager sessions.
- Do not claim the probe is a lock. An external process can still bind after the probe; QEMU's bind is authoritative. Convert the resulting launch failure into a port-specific error and include the requested mapping when it can be identified.
- Never bind to a non-loopback address in the manager. The v1.3 NAT runtime forwards on `127.0.0.1`.
- Do not use the public `environment:` argument to inject `OMARCHY_QEMU_GPU_PORT_FORWARDS`; upstream documents those variables as development overrides and the default client deliberately cleans them.

### Managed host SSH — next implementation milestone

**DESIGN DECISION — user requirement, 31 October 2026:** new manager-owned guests should become ready for SSH from the host automatically. SSH provisioning must not depend on a working graphical shell, clipboard, Accessibility permission or a manually pasted command. The temporary SSH bootstrap used to investigate Phase 1 is a diagnostic exception, not the product implementation.

**VERIFIED — v1.3.0:** the kit can forward Mac loopback ports to the guest and start the existing guest SSH server for that boot when SSH is forwarded. Its public `VMRunConfiguration` has no authorized-key provisioning or authenticated SSH-readiness API. Port mapping remains the private settings coupling described above. These capabilities alone do not provide unattended SSH access.

Requirements:

- Enable managed host SSH by default for newly created manager profiles. The creation sheet has **Enable SSH from this Mac**, checked by default, with an explanation that access uses a guest-specific Mac loopback endpoint. Existing manager profiles need an explicit migration/enablement action; personal/default Try Omarchy VMs remain excluded.
- Offer an optional **Add my SSH public key…** chooser at creation. Validate the selected OpenSSH public key, show its fingerprint, and install only its public material for the intended non-root owner after that account exists. Never copy or request the user's private key, infer a key from a private-key filename, scan personal credentials, or replace existing authorized keys. The manager's per-VM credential remains independent so readiness checks do not depend on unlocking a personal key or agent.
- With no existing public key selected, provision the per-VM manager key automatically and supply a working **Copy SSH Command** using the matching protected host identity. Selecting a personal public key is optional convenience, not a prerequisite for passwordless manager access.
- Automatically register the guest's initial public host key only after associating it with the expected VM through the trusted per-VM provisioning channel, then pin it for later connections. Ordinary connections should not need a first-use host-key prompt. A changed key requires explicit recovery; do not disable host-key checking. Keep manager-owned known-hosts/configuration separate from the user's global SSH files unless they choose an explicit integration action.
- Provision a dedicated manager-side SSH client key pair per VM for an intended non-root guest account. Install only its public key through a supported upstream first-boot/guest-integration mechanism. Do not bake shared keys into the factory image, copy another VM's credentials, patch Omarchy-owned files or depend on an embedded terminal.
- Keep the private credential in an appropriate protected host store, with only a reference in profile metadata. Never request, store or log the guest's password as the SSH bootstrap mechanism. The private implementation uses per-VM 0700 directories and 0600 files under the owned root, with separate known-hosts/configuration; unattended client keys are not encrypted. See `docs/ManagedSSH.md`.
- Use key authentication for the manager's access, an explicitly selected identity and pinned guest SSH host keys. Disable agent forwarding and password fallback for manager-initiated connections. Generate/preserve distinct guest host identities per VM; unexpected changes fail closed and require an explicit recovery action.
- Allocate a distinct unprivileged `127.0.0.1:<hostPort>` endpoint per managed VM, coordinate it through the port ledger, and verify the actual runtime mapping. Preserve endpoint metadata across ordinary restarts; external conflicts must be actionable rather than silently redirecting to another guest. No LAN or bridged exposure is introduced by this feature.
- Keep SSH readiness separate from VM lifecycle. `.ready` still indicates the upstream runtime boundary; it does not prove that a guest account, SSH daemon or authorized key is usable. Show provisioning/waiting/ready/failure separately, retaining the client and reservations through `.exited` even when SSH fails.
- Mark SSH ready only after an authenticated, host-key-verified connection confirms the expected guest account and manager-owned VM identity. A listening TCP port alone is insufficient. Bound and cancel probes by `(vmID, sessionID)` so an old connection cannot mark a later run ready.
- Make fresh-guest provisioning, normal restarts and host-initiated diagnostics work without manual shell commands. If owner-account setup is a prerequisite, represent that explicitly until provisioning completes; do not advertise SSH readiness prematurely.
- Use or extend the upstream kit and guest integration through a reviewed, versioned API/capability. The manager continues to own orchestration. The ad hoc live QMP forward and custom debug SSH daemon used during the POC must not become the production launch path.
- Any configuration migration beyond new-root initialization needs a separately reviewed, stopped-VM transaction using the supported upstream interface. Keep the current launch-admission adapter read-only; do not silently rewrite unrelated user settings to enable SSH.

**TO PROVE:** the supported key/account provisioning path before the first authenticated connection, independent identities/endpoints with two guests, recovery after failed provisioning, and SSH continuity across guest restart and Mac sleep/wake. Implement and validate this in Phase 3A before the private MVP is accepted.

## 11. Clipboard and other host integrations

### Clipboard

Working clipboard in every VM is a v1 requirement. Stock Try Omarchy 1.3 cannot meet it safely in a multi-VM process topology, so the first runtime task is a small focus-aware change to `NativeClipboardBridge`.

Required semantics:

- every VM whose profile enables clipboard includes `.clipboard` in its bridge list;
- only the QEMU process that is currently the frontmost/focused guest may read changes from `NSPasteboard.general` or write guest changes to it;
- a background guest clipboard message is ignored and must not replace the Mac clipboard;
- a background guest does not receive host clipboard changes;
- on focus gain, the newly active guest receives the current Mac clipboard once, then receives subsequent changes while focused;
- focus loss immediately stops both directions;
- transitions fail closed: if focus cannot be established, no clipboard traffic flows;
- echo suppression remains per guest, but focus is checked in the same serialized state queue immediately before every send or host write;
- no clipboard payload is logged, persisted in the manager registry or included in diagnostics.

The global Mac clipboard intentionally remains global. If the user copies in VM A, focuses VM B and pastes, that explicit focus change permits the current Mac clipboard to reach B. The bug to prevent is automatic delivery to B while B is in the background, or a background B overwriting a copy made in A/macOS.

Smallest upstream implementation:

1. Add a `ClipboardFocusProviding` abstraction to `NativeClipboardBridge`, defaulting to `NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID`. Identify the exact QEMU PID as the existing authentication/Command bridges do; never match a process name. Clipboard must not acquire a new Accessibility-permission dependency. An AX focused-window check may refine the result only when access is already available, not disable clipboard when it is not.
2. Track focus changes alongside the existing 250 ms pasteboard poll (or with workspace activation notifications plus a small reconciliation poll).
3. Gate `pollPasteboard()`, `.sync` handling and guest `.clipboard` handling on the focus probe.
4. On a false-to-true focus transition, reset only the necessary echo state and send the current host selection once.
5. Add deterministic tests with fake pasteboards and fake focus probes for two bridges, rapid focus changes, guest/host races, focus loss during a message and unavailable focus.
6. Keep the run protocol at version 1 and leave `VMRunConfiguration` unchanged; this is internal bridge behaviour.

**Packaging consequence:** changing the bridge changes `omarchy-vm-helper`, so it cannot be layered onto the published zip as an unsigned replacement. Build a complete kit from the pinned source plus the reviewed patch, then sign and verify it through upstream's normal kit pipeline. The POC lock file records the patch commit and resulting kit digest. A public/distributable manager should move back to an official release asset after the change is merged upstream.

The manager's `ClipboardCapabilityPolicy` checks the kit provenance/capability before allowing two clipboard-enabled sessions. Stock `v1.3.0` is recorded as `focusAwareClipboard: false`; the patched POC build is `true`. Never infer capability merely from run protocol 1 because both builds speak that protocol.

### Authentication, camera, battery and timezone

- POC bridge list after the required runtime patch: `[.clipboard, .battery, .timezone]` for both VMs.
- Authentication is off by default. The guest sudo milestone below adds explicit per-VM opt-in, UUID-scoped keys and a nonblocking cross-helper prompt lease. Native simultaneous prompts and cancellation remain TO PROVE and require the separately approved disposable-guest plan before testing.
- Camera is a contended physical device. Keep it disabled until an explicit single-owner policy is implemented and tested.
- Battery and timezone are read-mostly host integrations and are the lowest-risk bridges for the POC.
- Audio and guest-status are always run by the kit and are not `VMRunBridge` choices. Test simultaneous audio rather than assuming it is isolated.

## 12. Kit acquisition, build and signing

### Source and binary pinning

Commit `Config/TryOmarchyUpstream.lock.json` for the verified stock baseline:

```json
{
  "tag": "v1.3.0",
  "commit": "13d63df8da2947f833c04025ff5ade187d39ba81",
  "runProtocolVersion": 1,
  "kitSHA256": "3ad65381b34ced2ebe3f5f19b95d58ec1a2c51a77a6edf7599666a939b6991a6",
  "focusAwareClipboard": false
}
```

The clipboard-capable POC also commits `Config/TryOmarchyRuntime.lock.json` after the patch is implemented and reviewed. It records the upstream base, exact fork/patch commit, run protocol, build date, generated kit SHA-256 and `focusAwareClipboard: true`. Do not fill in a placeholder patch commit or digest; the build produces them and verification reads them back.

`Scripts/fetch-try-omarchy-kit.sh` handles the unmodified reference kit and should:

1. download `TryOmarchyKit.zip`, its sidecar checksum and `TryOmarchyKit.json` from the exact `v1.3.0` release;
2. verify the zip against both the committed digest and the sidecar;
3. verify manifest format, exact version and protocol;
4. unpack with `ditto` into a gitignored, versioned `VendorArtifacts` folder;
5. refuse an existing mismatched artifact rather than replacing it silently.

The build must never use “latest”. Updating the tag is a reviewed dependency change with real two-VM regression testing.

`Scripts/build-patched-try-omarchy-kit.sh` builds the POC kit from the exact source commit plus the focus-aware clipboard patch using upstream's documented `make kit` and kit-verification path. The script refuses a dirty or unexpected source tree, captures the resulting digest and manifest, and emits the runtime lock data. An untagged patched kit reports version `development`; that is permitted only for a debug/private POC when both its exact source commit and digest match the runtime lock. Release builds reject `development` and require an official upstream release that declares or proves the focus-aware capability.

### Embedding

Stage the bundle at:

```text
Omarchy VM Manager.app/Contents/Helpers/TryOmarchyKit.bundle
```

Add microphone and camera usage descriptions to the manager's `Info.plist` before enabling those bridges; macOS attributes the helper's requests to the app that started it.

### Signing reality

**VERIFIED — v1.3.0:** an embedded kit is re-signed as the embedding app. The upstream kit's QEMU and helper need their specific hypervisor/audio/camera entitlements and signing order. The networking daemon pins three networking binaries, so those three must not be re-signed after the daemon was built.

Reuse the pinned upstream `scripts/kit_signature.py` from the submodule in the app assembly process:

- copy the verified kit into the staged app;
- run its normal `sign` action with the development/distribution identity; that action skips the three pinned networking binaries and applies the correct entitlements to QEMU/helper;
- verify the kit before signing the outer app;
- sign the outer app last;
- for release, notarize the complete manager application and verify nested signatures.

Do not use a generic `codesign --deep --force` command as the signing strategy. Do not ask Codex to use signing identities, notarization profiles or credentials without the user explicitly authorizing that human step.

### App construction

Prefer a SwiftPM-first project that opens cleanly in Xcode and assembles a real `.app` deterministically, similar to upstream:

- `swift build`/`swift test` for code and tests;
- a checked-in `Makefile` as the public developer interface;
- `Scripts/build-app.sh` to stage the executable, `Info.plist`, icon, storage helper and kit;
- `make app`, `make test`, `make run` and `make verify-app` targets;
- minimum macOS 15, Swift 6 strict concurrency.

This avoids a hand-maintained generated Xcode project while still producing a native SwiftUI app bundle. If the team explicitly prefers an `.xcodeproj`, generate it from a checked-in specification rather than making opaque manual project-file edits.

## 13. Phased implementation

### Phase 0 — Repository and dependency skeleton

Deliver:

- SwiftPM package and SwiftUI executable target;
- core library and test target;
- exact upstream submodule pin;
- lock file and verified kit-fetch script;
- deterministic app assembly and ad-hoc/debug signing path;
- kit manifest/preflight diagnostics in a simple window;
- no VM launch yet.

Exit criteria:

- unit tests pass;
- app launches on macOS 15+ Apple Silicon;
- UI reports embedded kit `v1.3.0`, protocol 1 and supported status;
- a mismatched or missing kit is rejected, and a development kit is accepted only under the exact locked debug/POC provenance rule;
- built app and embedded kit pass signature/layout verification appropriate to the debug identity.

### Phase 0A — Required focus-aware clipboard runtime

Deliver:

- the smallest `NativeClipboardBridge` focus-gating change described in Section 11, based on the exact v1.3.0 commit;
- deterministic upstream unit tests covering two clipboard bridges and focus transitions;
- a clean upstream test run for the affected helper/client surface;
- a complete source-built kit produced and verified by the upstream kit pipeline;
- a generated runtime lock with exact patch commit and kit digest;
- an upstream issue/PR-ready explanation that the change fixes multi-instance clipboard routing without changing run protocol 1.

Exit criteria:

- with two bridge instances backed by one fake Mac pasteboard, only the focused target sends or receives;
- focus gain synchronizes the current Mac clipboard once;
- a background guest cannot overwrite the Mac clipboard;
- focus uncertainty fails closed;
- all existing single-VM clipboard behaviour remains covered and passing;
- the patched kit passes signature/layout/runtime checks appropriate to a development build.

This phase is mandatory. Do not proceed to the two-VM product POC with two stock v1.3.0 clipboard bridges, and do not substitute a one-clipboard-session product limitation.

### Phase 1 — Two-VM proof of concept

**DESIGN DECISION — user acceptance, 31 October 2026:** Phase 1 is complete. The user accepted the recorded POC results with the intermittent graphics startup failure carried forward for further investigation. That finding remains open and is not considered fixed or a blocker to completing this phase. Preserve both stopped disposable VM disks at the user's request. See [the POC results and remaining evidence gaps](docs/Phase1-POC.md) and [the graphics investigation](docs/Phase1-Graphics-Repro.md). Unverified checks retain their evidence status; milestone acceptance does not turn them into observed passes.

Deliver:

- two hard-coded or fixture profiles with distinct UUID roots and names;
- one `VMRunClient` per profile;
- restricted bridges `[.clipboard, .battery, .timezone]` for both profiles, using the locked focus-aware kit;
- NAT, no port forwards, no shared folders, no USB and no authentication/camera;
- sequential cold start, then two simultaneous running QEMU instances;
- independent shutdown and forced-stop controls;
- event/error log visible in the app.

The original Phase 1 baseline has no permanent SSH provisioning or forwarding. User-authorized temporary loopback SSH used for diagnosis must be recorded and cleaned up. It does not satisfy the future managed-SSH requirement in Phase 3A.

Decision-gate acceptance:

- VM A reaches `.ready`; while A remains usable, VM B reaches `.ready`.
- Both guests have different disks, settings and Dock/window names.
- Shutting down A produces A's `.exited` without stopping or freezing B.
- Restarting A preserves A's files and does not show B's files.
- Attempting to start A's exact storage root through a second client is refused with `vm-already-open` or is prevented by the manager before the call.
- Mac sleep/wake with both running returns both guests to a usable state, or the failure is recorded with exact logs and the project stops for an upstream investigation.
- Force-quitting the manager causes both helpers to begin shutdown and leaves no orphan QEMU after the upstream timeout.
- Clipboard works in A whenever A is focused and in B whenever B is focused.
- Copying in the focused VM updates the Mac clipboard; a background VM cannot overwrite it.
- Host clipboard changes reach only the focused VM; switching focus gives the newly focused VM the current Mac clipboard once.
- No unexplained port, clipboard, QMP socket, factory cache or storage collision occurs.

If this gate fails because the kit/runtime assumes a singleton, document the smallest upstream change and stop. Do not hide the failure behind retries.

### Phase 2 — Minimal manager MVP

**Implementation status — 31 October 2026:** implemented as a private debug build; registry, lifecycle, safe Trash and native UI checks pass. See [validation and remaining real-guest Spaces checks](docs/Phase2.md).

**DESIGN DECISION — user request, 31 October 2026:** follow the native sidebar/grouped-settings visual style of the supplied Try Omarchy screenshots and provide stopped-guest configuration for name, CPU, memory, clipboard and immersive mode. Keep both existing POC disks intact and protect their profiles from edits and deletion. For Mission Control Spaces, the user chose native Dock assignment over an in-app picker. The private runtime may stamp a stable, canonical-root-derived bundle identifier on each explicitly rooted guest app; retain the public client protocol and stock QEMU/image. Actual Dock assignment persistence remains **TO PROVE** until observed with the updated runtime. See [Phase 2 implementation and validation](docs/Phase2.md).

Deliver:

- schema-versioned registry and atomic persistence;
- create/list/rename/start/shutdown/force-stop/delete-to-Trash;
- manager-owned root initialization and markers;
- actor-based state machine and session retention;
- progress, notices and actionable failures;
- total memory and active count in the UI;
- application-quit coordination;
- fake-runtime tests for all lifecycle transitions.

Exit criteria:

- relaunching the manager restores profiles but never invents running state;
- repeated commands cannot create duplicate sessions;
- deletion cannot race a start or stop and cannot target an unowned path;
- corrupted registry data is preserved for diagnosis and not silently replaced.

### Phase 3 — Host safety policies

Deliver:

- read-only v1.3 effective-settings adapter and contract fixtures;
- aggregate memory/CPU/storage admission;
- manager port ledger and host bind probes;
- NAT enforcement;
- clipboard capability/provenance enforcement and focus-aware two-VM regression coverage;
- clear recovery UI for unknown settings schemas and port conflicts.

Exit criteria:

- stored resource settings cannot bypass the aggregate budget;
- two VMs requesting the same TCP or UDP host port cannot both enter `start`;
- a port conflict names the owning managed VM when known;
- malformed/unknown upstream settings fail closed;
- every clipboard-enabled running VM works when focused;
- background VMs neither receive host changes nor publish guest changes;
- a stock/unproven kit cannot be used for concurrent clipboard-enabled launch.

### Phase 3A — Automatically SSH-ready guests

Required before private MVP acceptance. User authorized this as the next milestone after Phase 2. The implementation adds narrowly scoped SSH port safeguards; full Phase 3 effective-settings/general-port work remains separate. Code and no-VM checks are implemented; real guest exit criteria remain TO PROVE. See `docs/ManagedSSH.md`.

Deliver:

- a reviewed upstream-compatible public-key/account provisioning path with explicit capability/provenance checks;
- per-VM protected credentials, pinned public host identity and coordinated loopback endpoint metadata;
- automatic SSH bootstrap on first launch, a creation-time default-on SSH toggle and optional existing-public-key chooser, separate authenticated readiness reporting and a **Copy SSH Command** action;
- bounded, session-scoped probes and actionable provisioning, authentication, identity and port errors.

Exit criteria:

- a fresh manager-created guest accepts an authenticated host connection after normal owner-account setup without a pasted command, manual SSH/firewall setup or host-key acceptance prompt;
- an optionally selected personal public key also authenticates for the intended owner, private key material stays on the Mac, and existing guest authorized keys are preserved;
- two guests accept connections concurrently through their own endpoints, and each connection identifies the expected VM;
- one VM's credential does not authenticate to another VM, and host-key mismatches cannot be silently accepted;
- normal guest restart preserves the intended key/host identity and restores readiness; sleep/wake and independent shutdown are tested;
- SSH setup/probing works while the graphical shell or clipboard is unavailable;
- an SSH failure never releases a live VM's client, resource allocation or port reservation;
- credentials and diagnostic bootstrap artifacts cannot leak into registry exports, logs or source control.

### Phase 4 — Packaging and private distribution

Deliver:

- Developer ID signing/notarization workflow, performed with user-authorized credentials;
- embedded-kit re-signing in upstream's required order;
- app update policy documented (manual download is sufficient for v1);
- release checklist, licenses and third-party notices;
- permission strings and first-run explanation;
- bounded diagnostic export with no guest secrets or clipboard content.

Exit criteria:

- a clean Mac user can install and launch the notarized build;
- the embedded helper/QEMU retain required entitlements;
- two-VM acceptance passes on the distributable build;
- the distributable build uses an official upstream release containing the focus-aware clipboard behaviour, or is explicitly designated an internal/private fork build with exact source and binary provenance;
- replacing the application does not alter manager-owned VM roots.

### Phase 5 — Optional hardening/upstream work

Candidates, only after v1:

- public upstream effective-settings and storage-initialization APIs;
- public port configuration/inspection API;
- a public clipboard capability flag or dynamic bridge diagnostics/control beyond the required focus-aware behaviour;
- safe guest-window activation API;
- shared verified factory cache across manager roots;
- explicit single-owner camera/USB policy;
- bridged networking registration and at-most-one-session policy;
- supported kit update channel with signature/team verification and rollback.

## 14. Acceptance criteria for the finished private MVP

### Functional

- Create at least three profiles and run any two concurrently on a host that satisfies the budget.
- Each profile retains its own guest data and settings across restarts.
- Start/stop/failure/progress are independent per row.
- Application relaunch preserves the registry and does not lose VM data.
- One VM can fail to start without terminating another.
- New manager-created guests become authenticated SSH-ready from the host automatically, with a distinct verified endpoint per VM and no manual console bootstrap.

### Lifecycle and data safety

- No code path deletes a running, starting or stopping VM.
- Graceful shutdown is the default; forced stop always warns.
- The client and reservations remain retained until `.exited`.
- A duplicate canonical storage root is rejected before launch.
- Delete moves exactly one verified manager-owned UUID root to Trash while holding the runtime-compatible lock.
- Corrupt or newer registry/settings formats are never overwritten automatically.

### Resource and networking safety

- Aggregate effective memory stays within the configured hard budget.
- CPU warning/block thresholds are deterministic and tested.
- New/existing free-space checks use upstream storage helpers plus manager margin.
- v1 launches only NAT.
- No two active/starting VMs reserve the same protocol and host port.
- External port races surface as an actionable launch error.

### Integration safety

- Every clipboard-enabled running VM can copy and paste when focused.
- A background VM neither receives host clipboard updates nor publishes guest updates.
- Focus changes select the active clipboard route without restarting either VM.
- Concurrent clipboard-enabled launch is refused unless the exact kit provenance is known to contain the focus-aware bridge.
- Authentication and camera are off unless explicitly enabled by a later tested policy.
- Sleep/wake, manager quit and manager force-quit are tested with two guests.
- A missing/damaged/incompatible kit prevents launch without touching storage.

### Packaging

- Source and kit are pinned to the same reviewed provenance: an official release for distribution, or an exact source commit plus generated digest for the private patched POC.
- Downloaded kit digest and manifest are verified before embedding.
- The app uses a clean environment for `VMRunClient.start`.
- Embedded code signatures and entitlements are verified in CI/local release checks.
- No release claim is made until a notarized build passes the same two-VM test.

## 15. Test strategy

### Unit tests — run on every change

- Registry encode/decode, atomic replacement, permissions and unknown schema.
- VM state transition table, stale session IDs and duplicate commands.
- Reservation release only after `.exited`.
- Memory/CPU budget boundaries and stored-setting precedence.
- TCP/UDP port identity, conflicts and owner messages.
- Clipboard capability/provenance admission.
- Focus-aware bridge state with two fake bridge instances, one fake host pasteboard and rapid target focus changes.
- Canonical path, symlink, marker and UUID checks.
- Error mapping and bounded/sanitized diagnostics.
- Application quit with zero, one and several fake sessions.

### Contract tests — pinned to Try Omarchy 1.3

- Manifest parsing and exact protocol support.
- Public configuration validation boundaries.
- Fixture `settings.json` files for null precedence, resources, old memory setting, NAT/bridged mode and port mappings.
- Fail-closed behaviour for bad permissions, symlink, oversized file, malformed JSON and newer schema.
- A test reads the vendored v1.3 source constants/fixtures and alerts on schema/key drift.
- App assembly contains the expected helper path and passes the upstream kit verification script.

### Runtime-adapter integration tests — no real VM

Create a temporary fake `TryOmarchyKit.bundle` with an executable protocol stub. Exercise:

- ordered progress/ready/exited events;
- synchronous launch failure;
- malformed and unknown events;
- stderr tail;
- graceful shutdown command;
- helper crash;
- stalled helper and `terminate()`;
- two simultaneous fake clients.

Never set upstream's private `OMARCHY_VM_RUN_TEST_SKIP_PREFLIGHT` in production code.

### Real Apple Silicon POC matrix

Run on at least one macOS 15+ Apple Silicon Mac with enough storage. Prefer both a 16 GiB and a larger-memory host before distribution.

Test:

- two existing VMs;
- first start of one VM while another runs;
- independent heavy CPU/disk load;
- distinct window/Dock identities and keyboard focus;
- simultaneous audio, then one microphone owner if later enabled;
- sleep/wake;
- normal app quit, cancelled quit and force quit;
- graceful and forced guest stop;
- same-root refusal;
- same-port refusal and external-process bind race;
- working focus-routed clipboard in both directions for A and B;
- background guest copy attempts, host changes during focus transitions and rapid A/B switching;
- low disk space and missing kit;
- update/replace the app while guests are stopped, retaining storage.

Record exact Mac model, macOS version, memory, kit manifest, test steps, results and stderr. “Source says it should work” is not a POC result.

## 16. Primary risks and mitigations

| Risk | Impact | Mitigation / decision |
| --- | --- | --- |
| Multiple QEMU/GPU sessions expose an untested singleton or Cocoa limitation | Project blocker | Phase 1 decision gate before UI investment; capture minimal upstream repro. |
| v1.3.0 is a prerelease | API/packaging churn | Exact source/binary pin; no automatic update; repeat POC on any change. |
| Private settings/marker coupling | New upstream schema can bypass policy or block VMs | One isolated adapter, exact v1 fixtures, fail closed, propose upstream public APIs. |
| Stored settings override manager fallbacks | Aggregate oversubscription or unexpected bridge/network | Initialize null overrides; read effective settings before every start. |
| Stock global clipboard bridges leak between guests | Cross-project data disclosure | Required focus-aware bridge patch, two-bridge tests, exact kit capability/provenance enforcement, upstream the change before public distribution. |
| Patched kit is not an official release asset | Update/signing/support burden | Use only for the private POC with exact source/digest; release builds require an official merged release or are clearly marked internal fork builds. |
| Port preflight has a TOCTOU race | Startup failure | Manager reservation + serialized starts + QEMU authoritative bind + actionable error. |
| Two cold roots duplicate image/cache | Disk/network pressure | Serialize cold starts; free-space margin; investigate shared cache only upstream-supported. |
| Bridged networking is single-session and privileged | Conflicts/approval burden | NAT only in v1. |
| Camera, USB, microphone and Touch ID contend or prompt confusingly | Unreliable/security-sensitive UX | Disable optional high-risk bridges initially; add explicit ownership policies and tests. |
| App/kit nested signing is incorrect | Build launches locally but fails for users | Reuse upstream signing script/order; verify entitlements; notarized-build POC. |
| No public bring-to-front API | Start button cannot focus an existing guest | Distinct product names/Dock entries; omit misleading Open action. |
| Destructive path bug | VM or unrelated data loss | Derived UUID roots, ownership marker, canonical checks, separate locking helper, Trash only. |
| Trademark/licensing mistakes | Distribution risk | Preserve MIT notices, audit `THIRD_PARTY_NOTICES`, do not reuse upstream/Omarchy brand assets without permission review. |

## 17. Recommended repository structure

```text
Omarchy VM Manager/
├── intent.md
├── AGENTS.md
├── README.md
├── LICENSE
├── THIRD_PARTY_NOTICES.md
├── Makefile
├── Package.swift
├── Config/
│   ├── TryOmarchyUpstream.lock.json
│   └── TryOmarchyRuntime.lock.json
├── App/
│   ├── Info.plist
│   ├── OmarchyVMManager.entitlements
│   └── Assets.xcassets/
├── Sources/
│   ├── OmarchyVMManagerApp/
│   │   ├── OmarchyVMManagerApp.swift
│   │   ├── AppDelegate.swift
│   │   ├── AppModel.swift
│   │   └── Views/
│   ├── OmarchyVMManagerCore/
│   │   ├── Model/
│   │   ├── Registry/
│   │   ├── Runtime/
│   │   │   ├── VMRuntime.swift
│   │   │   └── TryOmarchyRuntime.swift
│   │   ├── Manager/
│   │   │   ├── VMManager.swift
│   │   │   └── VMState.swift
│   │   ├── Policy/
│   │   │   ├── HostResourcePolicy.swift
│   │   │   ├── PortReservationLedger.swift
│   │   │   └── ClipboardCapabilityPolicy.swift
│   │   └── Storage/
│   │       ├── ManagerStorage.swift
│   │       ├── TryOmarchyV1StorageContract.swift
│   │       └── UpstreamSettingsSnapshotReader.swift
│   └── OmarchyVMStorageHelper/
├── Tests/
│   ├── OmarchyVMManagerCoreTests/
│   └── Fixtures/TryOmarchy/v1.3.0/
├── Scripts/
│   ├── fetch-try-omarchy-kit.sh
│   ├── build-patched-try-omarchy-kit.sh
│   ├── build-app.sh
│   └── verify-app.sh
├── Vendor/
│   └── try-omarchy/                 # git submodule, exact commit
└── VendorArtifacts/                 # gitignored, verified kit extraction
```

`AGENTS.md` should repeat the safety rules that matter during implementation: never use a personal/default Try Omarchy VM as a test VM; never reset/delete/launch an existing VM without explicit consent; use only manager-owned disposable roots; stop and ask for macOS permissions, signing, notarization, credentials and real UI takeover; shut down and Trash all test VMs after validation.

## 18. First Codex session instructions

Use this section as the initial implementation prompt. The first session should complete Phase 0 and implement/test Phase 0A before preparing the non-launching portion of Phase 1. It should not download the 3 GB factory image or open real QEMU windows until the user explicitly approves the POC run.

### Session objective

Create a clean SwiftPM-first SwiftUI macOS application skeleton, pin and verify Try Omarchy 1.3, implement and test the required focus-aware clipboard change, implement the core actor/runtime abstractions with fakes, and produce an app that can validate and report the exact embedded kit provenance. Prepare—not silently run—the real two-VM POC.

### Required sequence

1. Read this entire `intent.md` and treat the **VERIFIED / DESIGN DECISION / PRIVATE COUPLING / TO PROVE** labels as binding distinctions.
2. Inspect the host with read-only checks: architecture, macOS version, Xcode/Swift versions, physical memory and free disk. Report blockers; do not change the machine.
3. Initialize the repository if needed. Add an `AGENTS.md` containing the safety rules above.
4. Add `omacom/try-omarchy` as `Vendor/try-omarchy`, pinned to commit `13d63df8da2947f833c04025ff5ade187d39ba81`. Confirm that `git describe --tags --exact-match` reports `v1.3.0`.
5. Read the pinned upstream `AGENTS.md`, `docs/architecture.md`, `docs/vm-kit.md`, `macos/Package.swift` and the four files under `macos/Sources/TryOmarchyKitClient/` before writing the production adapter.
6. Create the stock upstream lock with the exact tag, commit, protocol, kit digest and `focusAwareClipboard: false` in this document.
7. Implement the kit-fetch script. Download only the small kit/manifest/checksum assets after normal network approval; verify before unpacking. Do not download the factory image.
8. Implement the Phase 0A focus-aware `NativeClipboardBridge` change in a dedicated branch/fork commit, with two-bridge fake-focus tests. Run the relevant upstream tests. Build a complete development kit through the upstream pipeline and generate the runtime lock with its real patch commit and digest; do not invent these values.
9. Create the package targets and basic SwiftUI window. Use macOS 15 and Swift 6 concurrency checks.
10. Add the local `TryOmarchyKitClient` product from the vendored `macos` package.
11. Implement `VMRuntime`, fake runtime/handle, `TryOmarchyRuntime`, the `VMState` model and an actor skeleton that retains handles through `.exited`.
12. Implement kit startup diagnostics: embedded path, helper validation, manifest version/protocol/support, exact provenance/capability lock and `VMRunClient.preflight()`. No VM starts in this step.
13. Add the app assembly script that embeds the verified patched kit. Reuse the pinned upstream signing script for the staged kit; use ad-hoc/debug signing only unless the user explicitly authorizes a real identity.
14. Add tests for event ordering, stale session rejection, retain-until-exited, synchronous start failure, graceful shutdown intent, missing/incompatible kit and rejection of an unproven concurrent-clipboard runtime.
15. Add two disposable POC profiles under the manager's own Application Support root in code or a debug fixture, but do not call `start` yet.
16. Run both upstream clipboard tests and manager `make test`, build the app, run layout/signature verification and open only the manager window. Fix failures before reporting completion.
17. Summarize files changed, commands/tests and exact results. State what remains unverified. Ask for explicit approval before the real two-VM run because it downloads large assets, opens windows and exercises Hypervisor/host integrations.

### First real POC, after approval

1. Confirm there is enough memory and at least the two-new-VM storage requirement plus margin.
2. Create only UUID-named manager-owned roots. Never point at `~/Library/Application Support/Try Omarchy/VM/v1` or any existing user VM.
3. Start VM A with NAT, explicit root/name, computed memory/CPU, and bridges `[.clipboard, .battery, .timezone]` from the locked focus-aware kit.
4. Wait for A `.ready` and complete enough first-boot setup to verify the desktop.
5. Start VM B the same way while A remains running.
6. Prove clipboard in both directions for A and B, including background suppression and rapid focus switching, before claiming the POC works.
7. Execute every Phase 1 decision-gate check and record evidence.
8. Gracefully shut down both. Confirm both `.exited`, no QEMU/helper remains for those test roots, and only then offer to move test roots to Trash.
9. If any shared-resource or lifecycle failure appears, preserve logs, stop further feature work and reduce it to the smallest upstream-compatible reproduction.

### Definition of done for the first session

- Repository skeleton exists and is understandable without generated mystery files.
- Stock upstream and patched runtime source/binary inputs are exactly pinned and verified.
- Core lifecycle code is testable without launching a VM.
- The assembled manager app validates the embedded kit, its focus-aware clipboard capability/provenance and protocol, and refuses incompatible or unproven input.
- Tests/build/verification pass with exact results recorded.
- No personal VM, signing credential, permission grant, factory image or real QEMU session was touched without explicit consent.

## 19. Upstream references

- [Try Omarchy v1.3.0 release](https://github.com/omacom/try-omarchy/releases/tag/v1.3.0)
- [VM kit and run-mode documentation at v1.3.0](https://github.com/omacom/try-omarchy/blob/v1.3.0/docs/vm-kit.md)
- [Swift package manifest at v1.3.0](https://github.com/omacom/try-omarchy/blob/v1.3.0/macos/Package.swift)
- [`TryOmarchyKit` and storage public API](https://github.com/omacom/try-omarchy/blob/v1.3.0/macos/Sources/TryOmarchyKitClient/TryOmarchyKit.swift)
- [`VMRunClient` public lifecycle API](https://github.com/omacom/try-omarchy/blob/v1.3.0/macos/Sources/TryOmarchyKitClient/VMRunClient.swift)
- [`VMRunConfiguration`, events and errors](https://github.com/omacom/try-omarchy/blob/v1.3.0/macos/Sources/TryOmarchyKitClient/VMRunProtocol.swift)
- [Kit manifest/version API](https://github.com/omacom/try-omarchy/blob/v1.3.0/macos/Sources/TryOmarchyKitClient/TryOmarchyKitManifest.swift)
- [QEMU launcher storage locks, work directories and per-run sockets](https://github.com/omacom/try-omarchy/blob/v1.3.0/macos/run-qemu-gpu.sh)
- [v1.3 clipboard bridge](https://github.com/omacom/try-omarchy/blob/v1.3.0/macos/Sources/OmarchyVMHelper/NativeClipboardBridge.swift)
- [v1.3 settings precedence and run-mode resolution](https://github.com/omacom/try-omarchy/blob/v1.3.0/macos/Sources/OmarchyVMHelper/VMRunSettings.swift)
- [v1.3 port forwarding implementation](https://github.com/omacom/try-omarchy/blob/v1.3.0/macos/Sources/OmarchyVMHelper/PortForwarding.swift)
- [v1.3 resource preferences](https://github.com/omacom/try-omarchy/blob/v1.3.0/macos/Sources/OmarchyVMHelper/VMResourcePreferences.swift)
- [Upstream issue #145: Multiple instances](https://github.com/omacom/try-omarchy/issues/145)

## 20. Final implementation stance

Proceed with the standalone manager, but keep the first milestone empirical. The public 1.3 client is sufficient to launch and supervise distinct roots with separate client instances. Host-wide resource and port coordination remains manager work. Safe, fully working clipboard in every VM requires the small focus-aware bridge change because stock 1.3's public API cannot broker it from outside the helper.

The safe v1 answer is intentionally narrow: manager-owned roots, exact source/binary provenance, NAT, serialized cold starts, aggregate admission, port reservations, a focus-routed clipboard bridge in every enabled VM and strict lifecycle/deletion rules. This is still the official Try Omarchy runtime architecture, with one targeted helper fix that should be upstreamed; it is not a QEMU fork. If the two-VM and two-clipboard POC succeeds, the remaining application is a conventional native manager around that runtime.

## Interactive launch intent — user extension, 1 November 2026

**DESIGN DECISION:** UI Start and confirmed experimental Restore request one foreground activation of the launched guest's display. CLI create/start/restart and automated provisioning retain background defaults, including the CLI's `open -g -j` manager startup. This extends only launch-time behavior; it does not add a general Open/Bring to Front action for an existing guest or change the verified stock v1.3.0 API limitations above.

**PRIVATE COUPLING:** extend the same pinned kit configuration/event channel with explicit launch intent and kernel-authenticated display-process identity from the launch's private QMP socket. The manager waits for that exact process's native display and revalidates its birth time before one cooperative macOS activation. Cancel on stop/error/exit/failure or timeout. Preserve lifecycle ownership through matching `.exited`, clipboard focus routing, keyboard capture and native Spaces placement. Require the complete rebuilt kit, reproducible source, exact inventory/compiled pin and launch-intent capability version 1. Preserve all previous custom-factory artifacts, receipts and guest disks; changed runtime provenance is incompatible without a separate explicit rebuild/import. See [guest foregrounding](docs/GuestForegrounding.md).

**VERIFIED — no-VM checks:** 172 manager Swift tests, 34 Python checks, 554 upstream Swift tests and the full upstream no-VM fixtures pass. Both optimized compiled-admission checks pass. The complete ad-hoc kit rebuild and separately staged app pass exact source/archive/inventory pins, signatures, macOS 15 compatibility and diagnostic/layout verification. Source `85f5e561e5a277ccec08d7725c8714cb090c9011`; runtime-lock/compiled pin `f450c1ac80ba9d6cac3678cf72d80dd10d11f23e0af380acf516c8e11e35dc74`. No installed app, existing VM/factory data, permission or real credential was changed. No guest/app window was launched or release published. Exact commands, artifact paths and sandbox limits are in [guest foregrounding](docs/GuestForegrounding.md#verified-no-vm-checks--1-november-2026).

**TO PROVE:** actual guest foreground/window/⌘Tab behavior, delayed startup on a real Mac, background provisioning, multiple simultaneous displays, Spaces, clipboard and keyboard integration, host sleep/wake and crash behavior with the new kit. Stub tests establish only intent, identity transport, scheduling and cleanup. No real VM, image download, installed app replacement, UI takeover, permission grant or real signing credential is authorized for these implementation checks.

## Unattended defaults — user extension, 31 October 2026

**DESIGN DECISION:** the user requested reusable in-app defaults based on Omarchy's unattended-install guide. The prepared factory image's owner setup will receive an immutable new-profile snapshot, with the reusable password held in Keychain and only a temporary protected provisioning seed supplied to the guest. This explicitly permits a password for unattended owner creation; manager SSH still uses independent key authentication. Existing guests remain unchanged. See `docs/UnattendedDefaults.md` for verified ISO/OEM distinctions, the versioned private coupling and remaining checks.

## JSON guest CLI — user extension, 31 October 2026

**DESIGN DECISION:** add a concise JSON command-line interface for guest CRUD, resource configuration, start/stop/restart and bounded waits for running, stopped or authenticated SSH readiness. Use the existing GUI manager as the single lifecycle/registry owner through a private same-user local command socket; a short-lived CLI must never drop live runtime handles. Configuration edits remain stopped-only and must also respect an externally held runtime lock. New guests inherit saved owner defaults unless explicitly opted out.

Return the usable host SSH endpoint separately from authenticated guest IP information. NAT guests may have the same private guest IP; host connections use the allocated `127.0.0.1` port, managed identity and pinned host key. Do not expose passwords, private-key material or Keychain references in JSON. Reuse the supported kit launch API and existing guarded Trash helper. The CLI does not add arbitrary guest-command execution, public networking or a second VM supervisor. See `docs/CLI.md` for the command contract and validation.

### Per-VM owner overrides — user extension, 2 November 2026

**DESIGN DECISION:** CLI creation may override username, full name, email, hostname prefix, timezone and keyboard through explicit flags or a non-secret `ownerOverrides` configuration object. Merge only supplied fields into the new profile's immutable snapshot of enabled, saved Guest Defaults. Empty full name/email clears that field. Keep the saved credential reference, defaults revision and stable UUID hostname suffix. Never rewrite Guest Defaults, alter existing profiles or accept secret/credential fields. Reject invalid values, manual-setup combinations, disabled/unavailable defaults, unavailable protected credentials and updates. Existing password authentication and runtime contracts remain unchanged.

**VERIFIED — no-VM checks:** `make test build` passes 184 manager Swift tests in 33 suites, 43 Python script tests and the debug build. The compiled CLI's `--help` includes the new flags. Synthetic creation tests use disposable UUID fixtures and an in-memory credential store, proving field inheritance, optional-field clearing, immutable persistence, unchanged defaults bytes, preserved credential references and rejection without registry mutation or VM storage creation. The initial sandboxed run could not exercise local sockets/authentication-framework properties; the complete run with the required local access passes. No real Keychain secret, installed app, existing profile/disk, image download or VM was used or changed.

**TO PROVE:** packaged CLI/manager operation and real guest first boot with overrides. This implementation request explicitly leaves VM creation and launch for later; no install or live acceptance is claimed. See [CLI configuration](docs/CLI.md#configuration).

**USER AUTHORIZATION / VERIFIED — subsequent installation, 2 November 2026:** the user requested building/installing the updated app and CLI, explicitly creating/launching no VMs. `make build icon`, separate candidate assembly and full candidate/installed verification pass. Installed ad-hoc 0.9.4 (17) at `~/Applications/Omarchy VM Manager.app` and the repository `dist` path; all 64 files and bundle modes match the candidate. Preserved the original application at `~/Applications/.Omarchy VM Manager.backup-dbaf7fa4164e4de98d76190ce8bb7a14.app` and the prior project bundle at `dist/.Omarchy VM Manager.backup-0d54b8502af247089455ac1474190aa2.app`; both match their original inventories. Installed CLI and repository wrapper help/version checks pass. After a fresh check of one stopped guest and zero active sessions/runtime processes, the prior installed manager quit normally; the updated manager remains closed. Registry/defaults hashes and VM-tree metadata/settings hashes match baseline. No VM/profile/disk creation, launch, credential access, permission grant or real signing identity was involved. This supersedes only the earlier non-installation status; packaged creation/first-boot acceptance and provisioned protected-password behavior remain **TO PROVE**.

### Per-VM personal SSH key suppression — feedback correction, 2 November 2026

**DESIGN DECISION:** expose the existing creation API's `inheritDefaultPublicKey` choice through CLI `--inherit-default-public-key on|off` and a top-level optional boolean configuration field of the same camel-case name. Omission preserves prior inheritance. `off` suppresses only the personal public key inherited from Guest Defaults, preserving automatic owner setup, protected password reference, default-on managed SSH, per-VM manager keys and host pinning. An explicitly supplied public key still applies. Keep this setting creation-only; change no saved defaults, existing profile or guest key enrollment. Reuse the existing manager creation/enrollment path without runtime, storage-schema or credential-policy changes.

**VERIFIED — no-VM checks and corrected installation:** `make test build` passes 186 manager Swift tests in 33 suites, 43 Python script tests and the debug build. New fixtures cover flag/file precedence, strict boolean decoding, command/update rejection, default inheritance, explicit replacement and suppression. The suppressed disposable fixture's actual bootstrap manifest contains only its manager-generated key, with no personal-key file/fingerprint; saved defaults remain byte-identical. No QEMU guest or real credential is used. Rebuilt and reinstalled the ad-hoc 0.9.4 (17) app and CLI at both prior paths, preserving backups `~/Applications/.Omarchy VM Manager.backup-135fc7eab2134d44837ca9fa6f195497.app` and `dist/.Omarchy VM Manager.backup-dc29c912192d4548b938fb4ad7cb5938.app`. All 64 files/modes match the candidate; backups match their originals. Candidate and installed signatures, provenance, compatibility, host preflight, layout and both CLI help checks pass. Guest registry/defaults bytes and VM-tree metadata/settings hashes remain unchanged. The prior manager quit normally after zero-active admission; the updated installed manager was subsequently observed running again and left running, with one stopped guest, zero active guests and no helper/QEMU processes. No real VM/profile/disk creation or launch, permission grant, password access or real signing identity was involved.

**TO PROVE:** real guest boot/enrollment with personal-key suppression and provisioned protected-password behavior. Synthetic bootstrap content and read-only installed CLI help/list checks do not establish these outcomes.

## Shared factory download cache — user extension, 31 October 2026

**DESIGN DECISION:** manager-owned guests share the compressed factory image under `~/Downloads/Omarchy VM Manager/Factory Images/`. Keep the current pinned image and prune only obsolete owned image downloads unused for at least seven days. A successful verified reuse refreshes last use. Cleanup runs opportunistically when preparing a guest, never on a background schedule. Interrupted downloads remain resumable. The cache is independent of guest deletion and is safe to remove manually when no guest is being prepared.

**PRIVATE COUPLING:** the exact digest-pinned helper recognizes the existing protected manager UUID marker and selects this fixed cache directory internally. No development environment override is passed by the manager, and stock/default Try Omarchy roots retain their existing behavior. The kit still owns the download, directory lock, part and whole-image verification, atomic completion and decompression. Each guest's writable disk and decompressed factory remain local to its UUID root. Existing guest disks are not migrated or modified by the cache feature. See `docs/FactoryCache.md` for checks and limitations.

## Managed disk capacity — user extension, 31 October 2026

**DESIGN DECISION:** new manager profiles default to a 64 GiB sparse disk. Disk capacity is an explicit stopped-guest setting in the app and JSON CLI, constrained to 64–8192 GiB and grow-only. Legacy profiles without a manager disk policy retain their existing capacity until explicitly configured. Retained POC profiles remain unchanged.

**PRIVATE COUPLING:** the manager persists the profile's CPU, memory and disk choices in the existing schema-1 `vmResourcePreferences` setting before launch. The exact pinned Try Omarchy runtime owns sparse file extension, never shrinks an existing disk, and the guest's supported root-growth service expands the GPT partition and Btrfs filesystem at boot. The manager validates the stopped disk's current logical size and refuses reductions; it never truncates or partitions a disk itself.

## Manual Pause/Resume — user extension, 31 October 2026

**DESIGN DECISION:** expose in-memory manual Pause/Resume in the native UI and JSON CLI. A paused guest retains its runtime handle, resource/port reservations and disk lock until matching `.exited`. This does not add saved-state suspension or snapshots. Existing guests/disks must not be used or changed by implementation checks.

**PRIVATE COUPLING:** extend the reviewed kit's existing version-1 command/event channel with pause/resume and execution-state acknowledgements. Unknown events are already explicitly forward-compatible. Build the manager against the same reproducibly patched upstream SDK source as its embedded helper, using a generated local package dependency; keep the vendor checkout at stock v1.3.0. The exact compiled runtime pin must require the reviewed manual-execution capability. No separate VM protocol, process signaling control path or development environment override is introduced.

The helper owns QMP pause/resume and keeps manual ownership separate from host-sleep ownership. Wake must not resume a manually paused guest or an unrelated/error stop. Graceful shutdown resumes only a pause owned by this helper, releases its retained monitor connection, then sends ACPI shutdown; uncertain/unsafe recovery falls back to the existing termination path. Terminal exit remains the only resource-release boundary. A missing/late control acknowledgement never implies exit or frees reservations.

## Suspend-to-disk — clarified user requirement, 31 October 2026

**DESIGN DECISION:** the user clarified that the intended feature must offload guest memory to disk and release host RAM while preserving the guest session. The in-memory Pause/Resume candidate does not fulfill this requirement. It remains uncommitted and uninstalled; no existing guest/disk was used for implementation or checks.

**VERIFIED — pinned runtime limitation:** the launcher selects `virtio-gpu-gl-pci` with Cocoa OpenGL. The pinned QEMU commit `c3d48b7d1e89604920e5b81b91140c2ad39a1943` registers a migration blocker when VirGL is enabled (`hw/display/virtio-gpu-base.c`, lines 213–217). The verified stock binary also contains that blocker message. A manager save-state command cannot safely bypass it. Raw guest disks also cannot directly use QEMU's internal qcow2 `savevm` snapshots.

**TO PROVE:** guest-side Linux hibernation may offer a route that does not serialize the host GPU, but requires a separate disposable POC covering swap/resume configuration, kernel support and restoration of the accelerated desktop. Software graphics would change the current runtime/experience and is also unproven. Do not claim either route works, change existing guests, fork QEMU or expose a misleading Suspend action. See `docs/Suspend.md` for the scoped POC and acceptance criteria.


**VERIFIED — approved fresh hibernation POC:** a new 4 GiB/4 CPU/64 GiB guest booted unattended and authenticated over pinned SSH. The official image’s `7.2.8-23-omarchy` aarch64 kernel reports `# CONFIG_HIBERNATION is not set`; `/sys/power/state` contains only `freeze mem`, the hibernation/resume sysfs files are absent, and login1 reports `CanHibernate=no`. No swap or boot configuration change can enable this missing kernel feature. The POC stopped cleanly with no open disk handles; all six earlier profiles/activity/session IDs match baseline. Further Linux hibernation work requires a hibernation-enabled kernel, plus separate proof of accelerated desktop restoration. See `docs/Suspend.md`. No existing disk or guest was used for the experiment.


**DESIGN DECISION — authorized kernel experiment:** the user authorized rebuilding a hibernation-enabled kernel and testing suspend/resume only in the retained `Omarchy Suspend POC` (`C1FFB37D-49E6-4C55-899B-BAB105C895A4`). Keep the original installed kernel and a bootable original-kernel recovery image. The factory image/cache, other guest profiles/disks/sessions and the running main app remain unchanged. This is an experimental guest customization, not a replacement factory image or a product-wide kernel policy. Use the official matching 7.2.8-23 recipe at `omacom/omarchy-pkgs` commit `9db7ac36d410aca6d571975be1a5a77677918569`, with a distinct package/release and `CONFIG_HIBERNATION=y`. Guest disk changes require its stopped state and the runtime-compatible POSIX lock.


**VERIFIED — experimental kernel boot and recovery:** the distinct `7.2.8-23.1-omarchy-suspend-poc` kernel built, installed alongside the original and booted with managed SSH plus `freeze mem disk`. Only hibernation and its selected dependencies differ from the original kernel configuration. Original image checksums remained unchanged, and the original-kernel recovery entry booted and authenticated successfully. A first full hibernation trial with persistent swap stalled before VM exit and required force-stop of only this POC. Its unchanged-disk relaunch cold-booted with no synthetic memory workload restored. This is not successful suspend/resume and does not enable a product Suspend command. See `docs/Suspend.md` for exact provenance and the diagnostic follow-up.

**VERIFIED — kernel experiment result:** both full hibernation attempts stalled after task freezing; the verbose retry recorded snapshot preallocation and completed freezer stages but no completed image or power-off. Both required force-stop after graceful timeout, and both unchanged-disk relaunches cold-booted with no synthetic memory restored. The specific driver/runtime cause remains TO PROVE. The POC was returned to the preserved original kernel as its default, boot-checked over managed SSH with its original checksum, and shut down cleanly. The automatic test is disabled; both kernel packages and the POC disk are retained. Non-target disk metadata/settings hashes match inventory; independent registry changes prevent asserting continuity of all original profile sessions. No app was installed and no other guest command or disk mutation was performed. Temporary build-cache cleanup limitations are recorded in `docs/Suspend.md`.

## Kernel capability and experimental hibernation UI — 1 November 2026

**DESIGN DECISION:** the user explicitly selected an opt-in experimental suspend-to-disk workflow in addition to kernel capability detection. Preserve the earlier failed-POC findings. The guest UI must distinguish kernel support, basic guest readiness, an unverified saved session, verified memory restoration and a cold boot. Unknown capability is disabled. Require a hibernation-enabled running kernel, a live `disk` state, sufficient persistent swap, resume parameters and non-interactive logind authorization before offering an attempt. Every attempt and restore requires explicit experimental confirmation. No automatic kernel/swap/policy installation, sudo prompt or privilege grant is added.

**DESIGN DECISION — disk protection:** durably save a versioned guard before the fixed pinned-SSH power request. Retain runtime ownership/reservations until matching `.exited`, including on lost SSH or timeout. Protect a potentially suspended disk from ordinary launch, edits and deletion; restore only through resource/port admission with configuration/runtime/disk/firmware identity checks. A RAM-filesystem marker plus the original boot identity verifies restored memory. Accept an old launch nonce only inside that proof-bound recovery check, never as normal SSH readiness. A fresh boot with no marker requires explicit failed-restore acknowledgement before the guard is removed. Unknown recovery remains protected; no silent saved-state discard or automatic force-stop is permitted. Quit cannot interrupt an active transition, and host wake cannot cold-start a saved guest.

**VERIFIED / TO PROVE:** source builds and synthetic lifecycle/SSH checks cover the experimental contract. Working real-guest suspend/restore, accelerated device restoration and host sleep/wake during those transitions remain TO PROVE; both earlier kernel POC attempts failed. The installed main app and existing guests/disks remain untouched. See `docs/Suspend.md` for prerequisites, recovery and validation limits.

**DESIGN DECISION — failed-restore recovery:** once a restore has been attempted without a verified memory result, do not automatically boot that guarded disk again: a cold boot may already have modified its filesystem. Permit read-only recovery rechecks while it is running. Releasing protection after a verified cold boot additionally requires the operator’s explicit attestation that a guest administrator invalidated any stale resume image; the app neither performs nor claims to verify that cleanup. A stopped unresolved restore requires manual recovery. Preserve newly appeared or changed guard files, and bind late replies to the exact active session.

## Reviewed custom factory prerequisite — user extension, 1 November 2026

**DESIGN DECISION:** accept externally prepared custom Omarchy factory bundles through a reviewed manifest catalog packaged with the signed manager. The default/explicit official factory remains available. Import verifies a pinned review-manifest digest, every payload and provisioning-evidence hash, aarch64/UEFI image format, exact runtime inventory, integration package and owner-setup contract. Import does not approve a bundle, download an image or initialize a VM. No custom image is preapproved by this change.

**DESIGN DECISION — identity continuity:** factory selection is creation-only and recorded in the guest profile; new roots bind the same identity in protected metadata. Existing profiles with no factory field retain that absence, and all existing writable disks and recorded identities remain unchanged. Factory selection cannot be changed through configuration/update. The manager orchestrates the same cache/preparation, cloning, growth, lifecycle, NAT and SSH implementation rather than adding a VM implementation.

**PRIVATE COUPLING:** the reproducible private kit/client patch adds optional `VMFactorySelection` and explicit `customFactoryVersion: 1` provenance. Whole-kit verification and normal signing remain required. The helper verifies the selected bundle and passes its directory to the existing launcher, disabling the official download only for that selection. The launcher verifies the decompressed custom disk digest before cloning. Protocol 1 is insufficient evidence of factory support. See `docs/CustomFactories.md` for the bundle/review contract.

**TO PROVE:** real custom-image boot, unattended owner/SSH provisioning, integration health, accelerated desktop, concurrent focus, sleep/wake, hibernation and crash behavior. Synthetic checks establish validation and protocol behavior only. This prerequisite grants no new real-guest launch or image-download approval.


**DESIGN DECISION — custom-factory review corrections:** bind the packaged review list to a generated compiled digest, report rejected imports separately while keeping valid/official choices available, and move large verification/copy/preparation work outside the lifecycle actor. Admit/reserve a session before preparation, honor pending stop/force-stop/Quit when its handle arrives, and retain runtime ownership through matching `.exited`. Experimental restore uses private admission with its timeout installed before event handling; no global restore exemption is exposed while preparation is pending. Strict preparation validation rejects metadata the importer cannot accept. These changes add no image or guest approval.


## In-app factory import — user extension, 1 November 2026

**DESIGN DECISION — supersedes the build-time approval requirement for explicit imports:** the user requested an Import Factory button that selects and verifies a prepared bundle without editing JSON or rebuilding the app. A user-initiated UI or CLI import may register a new manifest digest locally after all existing image, runtime, package and provisioning checks pass. The packaged review list remains a backward-compatible path for prior entries; it is no longer required for an explicitly selected import. Whole-kit provenance and signing policy are unchanged.

**DESIGN DECISION — local record:** copy and reverify the prepared bundle, then atomically publish a private import receipt binding its exact factory identity to the current runtime-lock digest. Listing, selection and launch require a matching valid receipt or a legacy compiled pin, plus full bundle verification. Missing, damaged, unsafe or mismatched records fail closed. Preserve damaged entries; do not silently replace or migrate them. No existing profile identity or writable guest disk is changed.

**DESIGN DECISION — UI:** expose Import Factory in the toolbar and the New VM image picker. Show verification/copy progress, cancellation and validation errors; successful import from New VM selects the new factory. Import and verification start no VM and create no guest storage. Large work remains outside the lifecycle actor, cancellation before publication removes staging files, and final publication records only verified metadata. Selection expresses local user trust, not independent proof of a publisher, image contents or a successful boot. Real-image behavior retains its TO PROVE status.


**DESIGN DECISION — Import Factory review fixes:** library refresh results/errors are bound to their request and catalog revision, so an older scan cannot remove a newly imported choice. Import workers count as active manager work; Quit cancels and waits for uncommitted work, or waits for final publication to complete before exit. Recheck the exact descriptor and image-metadata bytes before deriving identity/capacity. These corrections preserve the receipt schema, runtime pin, existing guest identities and writable disks.

## CLI factory deletion — user extension, 1 November 2026

**DESIGN DECISION:** `factory-delete MANIFEST_SHA256` removes only an unused, verified imported factory. Protect the official factory and refuse any manifest digest referenced by a persisted profile, including stopped, metadata-only and saved-session guests, or by a pending creation. There is no force override. Serialize import/deletion and reserve the selected factory against creation throughout review and Trash. Check registry continuity before admission and immediately before Trash; fail closed if it changed externally.

**DESIGN DECISION — recoverability:** verify the full bundle and local receipt or legacy pin, then recheck private paths, payload stamps and identity before moving the bundle and receipt together to one recoverable Trash folder. Preserve the source bundle, registry, guest identities and disks. On failure, restore original paths without overwriting newly appeared files; preserve a recovery folder if rollback cannot finish. An admitted deletion remains manager-owned through client disconnect, and Quit waits for its outcome. Refresh the app library after CLI mutations. Damaged, unregistered or runtime-incompatible factories require manual review and cannot bypass verification through deletion.

**VERIFIED / TO PROVE:** synthetic no-VM checks cover references, mutation races, changed registry/payloads, Trash failure and rollback recovery. Native Trash interaction with a real prepared factory remains unobserved. This change grants no guest launch, image download or existing-disk modification approval.

## Reviewed lean owner contract — user extension, 1 November 2026

**DESIGN DECISION:** preserve `OwnerSetupContract.json` and its default official program set. Explicit custom-factory selection may choose the separately reviewed `lean-e4fffc6` contract; imported metadata cannot register another contract or add executable paths. Bind the digest to the verified factory descriptor, exact kit inventory and a versioned owner-contract provenance resource inside the complete signed kit. Require lean evidence to match the reviewed Omarchy program set, the kit's integration-source commit and the builder's hardware-policy package version. Unknown, mixed, damaged or incompatible sets fail closed at preparation/import and again in the guest before managed functions run.

**VERIFIED — source review / PRIVATE COUPLING:** both reviewed programs expose the same keyboard, account, finalization, cleanup and platform functions and the same 52 keyboard selections. Lean adds a top-level progress-script dependency and removes full-name/email propagation. Pin its progress script and finalizer too; the lean adapter applies the saved full name and Git name/email before upstream cleanup. Root-owned, non-writable regular programs and parents are checked with bounded non-following reads; source dependencies execute from private verified snapshots. The function adapter, rather than a replacement VM implementation, invokes the upstream provisioning sequence. A finalization warning blocks cleanup, preserving pending/setup-user for a same-account retry and withholding SSH enrollment. Opted-in failures report a bounded code and stop; unseeded interactive setup retains its normal path.

**DESIGN DECISION — identity and integration continuity:** transport the reviewed contract digest as an optional setup-seed field checked against the helper's verified factory. Omitted fields retain official semantics. Do not rewrite saved Guest Defaults, owner fingerprints, per-guest SSH identities, profiles or existing disks. The updated kit offers integration package 0.1.0-41; lean images must be rebuilt from its exact source with the builder's hardware-policy 0.1.0-41.1 variant, which the existing package installer preserves as newer. The current lean disk's 0.1.0-36.1 integration is insufficient and is not admitted for managed lean setup. Existing imports bound to an older runtime remain preserved and require newly prepared matching descriptors.

**TO PROVE:** live lean owner setup/retry, authenticated SSH, accelerated rendering, hardware integration, playbook idempotence and crash/sleep behavior. Source and disposable no-VM fixtures do not establish those results. This work must not launch any VM, replace the installed app, use personal credentials or grant macOS permissions.

**DESIGN DECISION — reviewed corrections:** bind lean finalizer execution to the canonical file whose hash was checked. Durably record the matching owner identity before upstream removes pending; retry both file and directory flushes on an existing record, and permit only the same bound identity to resume interrupted cleanup. Require all cleanup markers gone before acknowledgement. While a manager setup seed is active, SSH enrollment additionally requires a configured report matching the current VM/session. Preserve the normal manual/completed-guest SSH path and all existing profiles, defaults and disks. Guest package 42 and the builder's matching hardware-policy variant 42.1 supersede 41/41.1 for this corrected runtime.

**DESIGN DECISION — clarified installation authorization:** the user explicitly resolved the conflicting installation instructions in favor of installing the reviewed build and replacing the installed app. Installation may replace only inactive app bundles after full verification, retaining recoverable backups. Do not open the app, launch a VM, stop a running manager/helper, modify existing guests, use personal credentials or grant macOS permissions.


## Retained POC deletion — user request, 1 November 2026

**DESIGN DECISION — supersedes the Phase 2 deletion restriction:** the user requested removal of the hardcoded deletion protection for Omarchy POC A and B. These guests use the normal explicit confirmation, stopped-session admission, reviewed root/disk/settings identity, ownership/tree validation, runtime-compatible lock and whole-root Move to Trash transaction. Pending-deletion recovery accepts their registered UUIDs. Their original configuration and missing-root recreation restrictions remain unchanged. This change authorizes making deletion available; it does not delete, launch or modify either existing guest.

**TO PROVE:** native Trash of either original POC disk through the updated app. Disposable fixture tests establish the storage and lifecycle behavior without using existing VM storage.

**DESIGN DECISION — deletion review:** retain cached saved-session protection and additionally refuse any on-disk suspension guard at review/confirmation and under the runtime-compatible storage lock before Trash. A guard appearing after the manager opens cannot authorize deletion through stale cached state. This applies equally to original POC and other registered guests. See the isolated review results in [Phase2.md](docs/Phase2.md#poc-deletion-review--1-november-2026).

## Single application instance — user request, 1 November 2026

**DESIGN DECISION:** allow one manager application process per user and one main window. Acquire a private nonblocking application lock before constructing the model or opening the registry, and retain it through coordinated shutdown. All main/preview copies sharing manager data use the same lock. A duplicate launch requests activation of the existing manager and exits without creating a model. Launch Services additionally prohibits multiple instances. The synthetic layout gallery has a separate lock and activation name. Read-only `--diagnostics-json` remains available without opening a manager session.

**DESIGN DECISION — recovery:** retain the lock file permanently and let the operating system release ownership on process exit. Reject unsafe or inaccessible locks; do not remove a lock file or interrupt an existing process to recover. The registry's existing independent lock remains in place.

**VERIFIED — no-VM validation:** `make build` passes; `make test` passes all 159 Swift tests across 31 suites and all 15 Python script tests. The first sandboxed suite run could not bind local sockets; the complete rerun with local socket access passes. The new tests use disposable UUID directories and a Python lock-holder process, covering exclusive ownership, normal/process-exit release, preserved lock inode and unsafe-file rejection. No app window was opened, installed bundle replaced, image downloaded or VM launched.

**TO PROVE:** native Finder/Dock reopening, minimized-window restoration and simultaneous GUI launches with the packaged app. Disposable no-VM tests cover exclusive ownership, normal/process-exit release and unsafe-file rejection.

**VERIFIED — installation at the user's request:** `make app verify-app` passes with ad-hoc signing, exact pinned kit inventory, nested deep/strict signature checks, macOS compatibility, host preflight and no-factory-image layout checks. Installed version 0.9.3 (build 16) at `~/Applications/Omarchy VM Manager.app` after confirming the destination was inactive immediately before replacement. Both staged and installed copies pass full verification and recursive byte comparison against the verified build. The previous installed bundle is retained at `~/Applications/.Omarchy VM Manager.backup-478965ffc269438c9a6b6c972a955522.app`; the preceding project build is retained at `dist/.Omarchy VM Manager.build-backup-aab75d4609b345528b5298f3caf72329.app`. No app window was opened, guest launched, existing VM storage changed or macOS permission granted. Native GUI reopening retains its TO PROVE status.

**VERIFIED — user report, 1 November 2026:** the user confirmed that the installed single-instance update works. Individual Finder/Dock, minimized-window and simultaneous-launch cases were not separately reported; their detailed acceptance checks remain TO PROVE.

## Development prereleases — 1 November 2026

**DESIGN DECISION:** the user requested versioned GitHub prereleases from CI. Publish only explicitly tagged `vVERSION-dev.N` debug builds after both existing no-VM test jobs pass. Mark downloads as experimental ad-hoc-signed development fork builds, never as notarized or stable distribution. Developer ID signing, notarization and the production release-runtime gate remain separate work requiring authorized credentials.

**DESIGN DECISION — provenance continuity:** acquire the exact already reviewed development kit from a digest-named GitHub dependency prerelease. Verify the compiled lock pin, source patch, archive digest, manifest, full file inventory and signatures. Preserve the current runtime lock and compiled pin; do not rebuild a new kit, update factory receipts, change VM storage or weaken normal launch admission. Source and kit remain pinned to the same reviewed provenance.

**DESIGN DECISION — no-VM packaging:** assemble in a separate prerelease staging directory, preserve ZIP permissions/resource metadata, unpack and verify the result, and publish its checksum and source/runtime provenance. Bundle-only diagnostics explicitly skip host readiness and exit before constructing a manager session. Normal diagnostics and VM launches still perform host preflight. CI establishes packaging integrity; real guest, focus, sleep/wake and crash behavior retain their existing evidence status.

**VERIFIED / DESIGN DECISION — cross-builder signing:** the first tagged package run verified the original runtime on macOS 15, then correctly refused the inventory changes caused by re-signing it with that builder's `codesign`. Development prerelease assembly therefore preserves the exact existing upstream-pipeline ad-hoc kit signatures and verifies them and the full inventory before/after embedding. Sign the manager's executables and outer app normally. No provenance check is bypassed, and future Developer ID distribution still requires deliberate new signed-runtime provenance.

**VERIFIED / DESIGN DECISION — SwiftPM resource layout:** CI uses a flat core resource bundle while the local toolchain emits `Contents/Resources`. Accept exactly one of those layouts and compare all three resource files against source. Resolve packaged resources from the app before SwiftPM's test/build fallback and exercise owner-contract loading during bundle diagnostics. Both layouts, signature checks and exact runtime preservation passed local no-VM validation; this does not establish any new real-guest behavior.

## Authorized signed prereleases — 1 November 2026

**DESIGN DECISION / USER AUTHORIZATION:** after configuring the seven GitHub secrets, the user explicitly requested wiring signing/notarization into CI and running the first signed prerelease. This authorizes those credentials only in the tagged GitHub release job. It does not authorize local credential use, app installation/UI takeover, permissions, factory-image downloads or any real guest launch.

**DESIGN DECISION — signed fork policy:** add an explicit optimized `SIGNED_PRERELEASE` build mode. Admit only the compiled exact signed runtime lock plus expected signing team, original source-kit digest and original source-lock digest. Preserve the existing ad-hoc development lock/artifact and normal production-release refusal. Developer ID/notarization are verified distribution properties, not an official-upstream or real-VM acceptance claim.

**DESIGN DECISION — upstream signing boundary:** derive the signed kit through upstream's existing pipeline, including signing its three networking payloads before rebuilding the daemon that pins them. Preserve all unsigned guest/scripts/firmware/factory payloads exactly. Notarize/staple the kit before deriving its full signed inventory; sign and notarize/staple the app afterward. Verify all entitlements, Developer ID/team/hardened runtime/timestamps, exact bundle contents, Gatekeeper acceptance and the extracted ZIP before publishing. Never use deep force-signing.

**DESIGN DECISION — continuity and credentials:** keep a separately reviewed signed-runtime lock so later app builds reuse the same signed kit. Generate source pins only inside the disposable CI workspace and restore checked-in development pins on exit. Keep credentials in a temporary runner keychain, redact command failures, remove key material on exit, and expose no credentials to tests/pull requests or artifacts. Preserve existing profiles, custom factory receipts and disks; ad-hoc-bound custom factories remain incompatible until deliberately rebundled for the signed runtime. No automatic migration is authorized.

**TO PROVE:** end-to-end Apple acceptance, stapling and Gatekeeper checks on GitHub; clean-Mac installation/permissions and all real signed-build guest behavior. Local no-VM tests and optimized compilation do not establish those outcomes.

**VERIFIED / DESIGN DECISION — certificate container compatibility:** the initial signed CI attempt passed both test jobs but macOS rejected PKCS#12 import with a MAC-verification error, before any signing/notarization submission. Add verified OpenSSL decryption and same-identity rewrapping into a compatible temporary encrypted container with a random transfer password. Never skip MAC checks; remove the private temporary PEM immediately and all credentials on exit. Synthetic-certificate tests verify certificate preservation and rejection of a wrong password; the corrected-credential retry below confirms real import/signing.

**VERIFIED — initial signed CI credential gate:** `v0.9.3-dev.5` passed 160 manager Swift tests, 31 Python tests and 550 upstream tests. OpenSSL also rejected the then-configured PKCS#12 MAC. CI cleaned up credential files/keychain and published nothing; no real signing or Apple notarization submission occurred in that attempt. A credential correction was required before retrying.

**VERIFIED — corrected credentials, superseding the credential blocker above:** the user updated the export-password secret. The signing-only retry imported the Developer ID identity, validated the notarization API credentials and signed the runtime through the upstream pipeline. Apple received submission `9600b6bb-4040-473f-868b-b36ec0a55c52` and still reported `In Progress` when the run was deliberately cancelled before publication after discovering a remaining debug-only launch guard. No signed release was published, and no guest was launched.

**DESIGN DECISION — compiled admission correction:** optimized `SIGNED_PRERELEASE` builds must reach the same exact signed-provenance, host-preflight and signature validation used by managed launch. Ordinary release builds retain their private-runtime refusal; legacy fixed-root POC admission stays debug-only. Exercise the compiled admission branch in both optimized modes with an unpinned, nonexistent kit and no created storage. Preserve exact candidate archives alongside Apple diagnostics on CI failure so a pending submission's bytes remain available for review; never include credentials or publish an unaccepted candidate as a release.

**VERIFIED — admission correction checks:** local `make test-build-policies` passes the compiled admission regression in both optimized modes. `make test` passes 161 manager Swift tests and 31 Python tests. No real signing identity or notarization credentials were used locally, no app was opened or installed, and no VM/image/storage operation occurred. Apple acceptance, stapling, Gatekeeper and real signed-guest behavior remain TO PROVE.

**VERIFIED — corrected tagged CI checks:** [`v0.9.3-dev.6`, run `41274695838`](https://github.com/reactive-org/omarchy-vm-manager/actions/runs/41274695838), at manager commit `88bb8679934fdb286461f5a9a08198f54d7f159e`, passed 161 manager Swift tests, 31 Python tests, one compiled admission regression in each optimized mode, 550 exact patched upstream tests, app/icon builds and the isolated SSH job. No real guest was launched. These checks do not establish Apple acceptance or real signed-build guest behavior.

**VERIFIED — signed candidate / pending Apple gate:** the corrected job imported the real certificate, validated API credentials, signed the runtime and submitted it at `2026-11-01T04:57:16.237Z` as `78d5ad92-c756-4e67-a0f1-87dec516c5d4`. Apple still reported `In Progress` at `05:42:38Z`, after the 45-minute limit. CI cleaned up credentials, retained diagnostic/candidate artifact `13072336103` and skipped publication. The runtime archive SHA-256 is `b6dbfb08c213458b9d57486f30b699ecf9e2fccfb430276ad2fd9d7cbaccad4b`. Read-only downloaded-candidate verification with macOS trust-service access passed all 22 Mach-O Developer ID/team, hardened-runtime, secure-timestamp, entitlement, deep-signature and network-pin checks; all unsigned payloads match the original locked runtime. The development lock/pin remains `37aeca15303be1d491b9ed39109e4d0fc273093fe88dc1ac9f0b56fa05822cfb`.

**TO PROVE / external blocker:** Apple acceptance, fresh runtime/app stapling, final signed app/ZIP and Gatekeeper verification remain unobserved. No signed prerelease or accepted signed-runtime lock was published/committed. Existing real-guest acceptance limits remain unchanged. The user considered a local release and explicitly chose to keep CI running; local signing/notarization credentials and a real local signing identity remain unauthorized. No local credential use, installation, app UI or real guest launch occurred in this work.

**DESIGN DECISION — existing submission status:** the user requested checking Apple's result and finishing the prerelease if accepted. Add a manual, release-specific CI status job bound to the immutable `v0.9.3-dev.6` source commit and recorded submission ID. Use only the three authorized API secrets in a private temporary runner directory; import no signing identity, submit no new archive, and remove the key on success or failure. Retain the fresh status/rejection JSON. This extends the CI continuation path, not local credential authorization, VM approval or the publication gates.

**VERIFIED — fresh Apple status:** [CI status check `41278438740`](https://github.com/reactive-org/omarchy-vm-manager/actions/runs/41278438740) succeeded and Apple again returned `In Progress` for `78d5ad92-c756-4e67-a0f1-87dec516c5d4`. No new upload, signing, local credential use or VM operation occurred. The checker passed local `make test`: 161 manager Swift tests and 34 Python tests, including CI-only credential refusal, cleanup after API failure and mismatched-reply rejection. Apple acceptance and the remaining signed-prerelease gates remain TO PROVE.

## Factory preparation progress — 1 November 2026

**DESIGN DECISION / USER AUTHORIZATION:** fix the stale Preparing percentage in the existing runtime and rebuild/pin its complete kit. The user explicitly accepts that the changed provenance makes existing custom factories incompatible. Preserve their bundles, receipts, recorded profile identities and writable disks; no automatic migration, relabeling, installation, real signing identity, factory-image download or guest launch is authorized.

**PRIVATE COUPLING:** the upstream launcher measures decompression from sparse output size, which can remain at the last written range until close. Emit Preparing 100% only after decompression succeeds and the output has the expected size. Enter the existing Finishing phase before the custom raw-disk checksum and compaction, clearing the old unpacking percentage. Keep all verification and lifecycle boundaries intact. See [preparation progress](docs/PreparationProgress.md).

**TO PROVE:** live GUI progress timing and real custom/official guest behavior with the rebuilt kit. No-VM fixtures establish only marker ordering, parser behavior and failure handling.

**VERIFIED — no-VM validation:** `make test` passes 162 manager Swift tests and 34 Python tests; `make test-upstream` passes 551 upstream Swift tests and all remaining upstream no-VM fixtures. The complete kit rebuild, exact inventory/signatures, manager build and isolated app verification pass. The new source is `80156396a5daa795487c0f4a8308eee53f6ea68b`; the runtime-lock/compiled pin is `cac1444e48e0413f37cb0b97d196b5cad3034782b8c8245f500fc323004f77a0`. Exact commands, pins, sandbox limitations and the uninstalled candidate path are recorded in [preparation progress](docs/PreparationProgress.md). No real guest, image download, existing guest/factory data, installed app, UI takeover, personal credential or permission grant was involved.

**DESIGN DECISION / VERIFIED — subsequent user-authorized installation:** the user requested installation with a backup and explicitly no VM launch. Installed the fully verified candidate at `~/Applications/Omarchy VM Manager.app` after checking that destination was inactive; preserved the previous bundle at `~/Applications/.Omarchy VM Manager.backup-28e6f532f5a84184840df50395317f79.app`. Both bundles pass signature, compatibility, diagnostics and exact-layout verification against their own runtime locks; all 64 installed files and bundle modes match the candidate, and the backup matches the pre-install inventory. Left the separately running project manager untouched. No app window was opened, process stopped, VM launched or existing guest/factory/registry data modified. This supersedes only the installation restriction for this app replacement; live behavior remains TO PROVE.

**VERIFIED — subsequent user-authorized reopening:** the user explicitly requested quitting the running project manager and opening the installed update without launching VMs. Quit normally after observing zero active guests, confirmed process exit and no VM runtime processes, then opened only the installed manager. Its UI showed five stopped guests, zero active and zero allocated memory. Process inspection confirmed one manager at the installed path and no helper/QEMU processes. No VM launch or permission grant occurred; real preparation-progress behavior remains TO PROVE.

## Matching custom factory rebuild — 1 November 2026

**DESIGN DECISION / USER AUTHORIZATION:** the user requested rebuilding and repreparing the custom factory for the updated kit, preserving the original and launching no VMs. Use the existing dev-vm 20 GiB lean foundation builder with the exact clean integration source `80156396a5daa795487c0f4a8308eee53f6ea68b`. Preserve the original successful artifact, prepared bundles/imports and all guest profiles/disks. Publish a distinct build artifact and a separate flat prepared bundle. The existing builder may use its ARM64 Docker containers, guest-package downloads and isolated chroot/snapshot checks; it must not launch QEMU or install host software. This does not authorize boot acceptance, migration of existing guests or rewriting old factory evidence.

**VERIFIED — completed no-VM rebuild:** the existing dev-vm `make build-omarchy-image` target succeeds with explicit current-source/commit overrides and a 20 GiB disk. Published new artifact `af93b5f10d206637-7816326733d14d53` and separate `.Manager.factory` bundle; its manifest is `6b49ae727ec1865e15c90bc990bb13d46b2747012d7ac5f4ceb93b2fe245e5bf`. All 24 artifact checksums, independently streamed raw disk size/hash, exact seven-file managed integration comparison and production client validation against the installed kit pass. Package versions match the original artifact. Reverified all 24 original artifact checksums and preserved five prior prepared descriptors/timestamps; the dev-vm checkout remains clean. `latest` points to the new artifact. No import, VM launch, host-software installation or guest mutation occurred; process inspection found no helper/QEMU guest. Exact paths, hashes and limits are in [Lean owner setup](docs/LeanOwnerSetup.md#rebuilt-for-the-preparation-progress-kit--1-november-2026). Live behavior remains TO PROVE for this artifact.

**USER AUTHORIZATION / VERIFIED — subsequent import:** the user requested importing the rebuilt bundle through the updated manager, preserving the original and launching no VMs. Native `factory-import` succeeds; a fresh `factories` listing includes the new manifest and its receipt binds the exact current installed runtime lock. All 81 previous library entries and the source bundle are unchanged, and the imported payload hashes match the descriptor. Read-only before/after guest configuration/lifecycle hashes match for all five inactive guests; no helper/QEMU process is present. No old import/receipt or guest was replaced or changed. The rebuild-time non-import status is superseded only by this explicit import; actual boot/progress and other live acceptance remain TO PROVE. See [import evidence](docs/LeanOwnerSetup.md#subsequent-authorized-import--1-november-2026).

## Interactive-launch candidate installation — 1 November 2026

**USER AUTHORIZATION / VERIFIED:** the user requested installing the verified interactive-launch candidate, keeping a backup and launching/modifying no VMs. Installed 0.9.3 (16) at `~/Applications/Omarchy VM Manager.app` after confirming the destination was inactive immediately before replacement. Preserved the prior bundle at `~/Applications/.Omarchy VM Manager.backup-d11e7d2bc16944bea3526d14b188da00.app`. All 64 installed files and bundle modes match the candidate; the backup matches the prior inventory. Both bundles pass signature/compatibility/provenance/layout checks against their own runtime locks, and final installed-path diagnostics pass host preflight. No app UI, VM lifecycle/storage action, permission grant or real signing credential was involved. Installation changes no real-guest acceptance status; foreground/⌘Tab and integration behavior remain **TO PROVE**. See the [installation evidence](docs/GuestForegrounding.md#subsequent-authorized-installation--1-november-2026).

## Real launch-focus evidence — 1 November 2026

**USER AUTHORIZATION / VERIFIED — user report:** the user authorized CLI background testing on fresh disposable manager-owned guests and reported that UI launches focus the launched guest while the manager is focused. Record only that UI case as user-verified; do not infer ⌘Tab, Spaces or other focus scenarios.

**VERIFIED — real disposable CLI checks:** with the installed launch-intent kit (`85f5e561e5a277ccec08d7725c8714cb090c9011`, runtime-lock `f450c1ac80ba9d6cac3678cf72d80dd10d11f23e0af380acf516c8e11e35dc74`), CLI `create --start`, unattended owner/SSH setup, warm `start`, `restart` and a focused fresh-creation repeat kept the exact guest app and manager background while each guest owned a native window and reached authenticated SSH. Both new UUID guests stopped through normal matching terminal cleanup; no captured runtime/targeted bridge process or open test-root file remained. The original three guests' records and checked storage metadata/settings hashes match baseline. Test roots are retained pending a Trash decision. No permission, existing guest, factory import or installed app was changed.

**VERIFIED limitation / TO PROVE cause:** unattended fresh creation briefly activates macOS SecurityAgent (about 5.61 seconds in the identified repeat), before QEMU starts. Thus guest-display backgrounding passes but full host-focus preservation does not. The saved-password Keychain lookup is a possible cause, not established proof. No credential policy or permission was altered. Cold-manager CLI bootstrap, ⌘Tab, Spaces, clipboard/keyboard, concurrent guests, sleep/wake/crash and a safe SecurityAgent fix retain their TO PROVE status. See the [real background-launch evidence](docs/GuestForegrounding.md#authorized-real-background-launch-check--1-november-2026).

## Touch ID approval for new guest setup — 1 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** the user requested one Touch ID approval per new VM, with the Mac login password as fallback. They subsequently chose to prepare the feature and supply a Developer ID provisioning profile later. Implement the native biometric Keychain path and no-VM tests now. This does not authorize local signing credentials, profile creation, installation, credential access/upgrades, permission grants, UI takeover or real guest launches.

**DESIGN DECISION:** new setup passwords use the manager's versioned local data protection Keychain service, with `SecAccessControl.userPresence` and device-only, unlocked-device accessibility. Keychain itself requests authentication during one password retrieval at first launch; do not add a preliminary LocalAuthentication approval, reuse authenticated contexts between guests, use a recent Mac unlock as approval, or fall back to legacy password retrieval after failure. Cancelled/failed authorization stops launch before root preparation. Manual/completed guests skip retrieval; an interrupted setup attempt requires fresh approval on retry. New profile snapshots check protected-item metadata without requesting secret data or authentication.

**DESIGN DECISION — explicit upgrade:** Guest Defaults offers a one-time upgrade of only its saved credential. It may require the old login-Keychain authorization before copying the password to the protected service under the same UUID. Keep the original entry and metadata unchanged, preserving pending snapshots and rollback. Legacy copies retain their original access policy; this is not a claim that every historical copy becomes biometrically protected. No automatic legacy read or broad credential enumeration is permitted. Pending snapshots of a different historical credential remain preserved and fail closed until that exact credential is deliberately upgraded.

**DESIGN DECISION — signing boundary:** biometric Keychain access requires provisioned app entitlements. The app assembly accepts an explicit Developer ID profile only in authorized signed-prerelease mode, verifies its exact manager App ID/team/platform/expiry/distribution scope, and grants only the manager's own application identifier and team. The CLI, storage helper and kit gain no Keychain entitlement. Ad-hoc builds remain buildable, display the missing-capability limitation and refuse protected credential operations. The profile is still to be supplied; no fake Team ID, unprovisioned entitlement or local signing identity is used. See [Touch ID setup and validation](docs/TouchID.md).

**TO PROVE:** the final provisioned build and Apple profile/certificate admission; real Touch ID approval, Mac password fallback, cancellation and prompt count; native upgrade UI/layout; legacy upgrade after an ad-hoc binary change; and the original background-focus issue. Synthetic tests establish query policy, context isolation, error boundaries and profile-scope checks, not native authentication behavior.

**USER AUTHORIZATION / VERIFIED — subsequent profile validation:** the user supplied `Omarchy_VM_Manager_Developer_ID.provisionprofile` in their Documents signing folder and requested read-only validation. Its exact App ID, macOS Developer ID scope, current validity and requested entitlements pass project policy. The CMS signature and local Apple-signer trust pass, and its authorized public signing certificate/team exactly match the digest-verified `v0.9.3-dev.6` CI candidate. Profile SHA-256: `f5ddd1c8f3d572881bd85522ac086a4e271d351e4e0225442094987f706d2aed`; expiry: `2044-10-27T10:03:25Z`. No private key/identity was used, profile/certificate imported, CI setting changed, app signed/installed/opened, credential accessed or VM launched. This supersedes only the waiting-for-profile status. CI integration, signed-app admission, online revocation and native authentication behavior remain unobserved. See [profile validation](docs/TouchID.md#provisioning-profile).

**USER AUTHORIZATION / DESIGN DECISION — CI signed Touch ID release:** the user explicitly requested wiring the validated profile into CI and building a signed release with Touch ID support. Store its base64 bytes as `MACOS_KEYCHAIN_PROFILE_BASE64` in the existing repository's Actions secrets, pin only its exact digest/Bundle ID in source, and expose the secret only to the tagged release step. Stage and validate the profile in a private runner directory before importing signing credentials, embed it only in the main app, verify the actual signing certificate and process-level entitlement, and remove temporary copies on all exits. Signed prereleases must refuse a missing/changed profile; local builds remain ad-hoc. Prepare 0.9.4 (17), tag `v0.9.4-dev.1`, and publish only after the existing tests, Apple acceptance/stapling, provenance, signatures, profile/certificate checks, Gatekeeper and extracted-ZIP verification pass. Publishing the exact already-reviewed current runtime as its digest-named CI dependency is necessary for clean-runner packaging and authorized within this release request. Local signing credentials, installation, UI takeover, Keychain password migration, permission grants and VM launches remain unauthorized. Real biometric/guest behavior remains **TO PROVE**.

**VERIFIED — Touch ID release CI / pending Apple gate:** [`v0.9.4-dev.1`, run `41296495425`](https://github.com/reactive-org/omarchy-vm-manager/actions/runs/41296495425), at immutable manager commit `ef98347fde21cbdcb1002506c828e36e7ee9cda3`, passed 180 manager Swift tests, 43 Python tests, both optimized admission checks, 554 exact patched upstream Swift tests, app/icon builds and isolated SSH checks. The provisioned CI path validated the profile, certificate/password and API credentials, signed the runtime and submitted `c30ff885-b28d-4039-9314-1bf8f53267cf` (Apple createdDate `2026-11-01T10:19:22.100Z`). Apple still reported `In Progress` when the 45-minute wait stopped at 10:04 pm AEDT on 1 November 2026. CI cleaned up credentials/profile, retained artifact `13080912857` and skipped publication.

**VERIFIED — retained current signed candidate:** the ZIP SHA-256 is `d75f504b50ab7a690cd58bcfb7bbb6be1d40e3879ce17e07fbe4f843dd91f0d8`. Read-only downloaded-candidate verification with macOS trust services passed all 22 Mach-O Developer ID/team, hardened-runtime, timestamp, entitlement, deep-signature and networking-pin checks; every unsigned payload matches the tagged source-lock `f450c1ac80ba9d6cac3678cf72d80dd10d11f23e0af380acf516c8e11e35dc74`. Its exact bytes, manifest, original source lock and public receipt are preserved under ignored `VendorArtifacts/signed-candidates/v0.9.4-dev.1/`. No private signing/notarization credentials were used locally, app installed/opened, permission granted, password migrated or VM launched.

**DESIGN DECISION / TO PROVE — current continuation:** the status workflow and follow-up now bind the current immutable tag/commit and submission above. Preserve older evidence without publishing `v0.9.3-dev.6` or mixing its incompatible runtime into this release. Query the current ID without a new upload. Apple acceptance, fresh runtime/app stapling, final provisioned signed app/ZIP, Gatekeeper and native biometric/guest behavior remain unobserved and required before their corresponding claims.

## Development Keychain compatibility — user request, 2 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** restore the existing login-Keychain password flow for development builds while retaining Touch ID for provisioned releases. Preserve saved credentials, UUID references, defaults/registry schemas, VM profiles/disks, the exact runtime pin and the pending Apple submission. An unprovisioned `DEBUG` build without `SIGNED_PRERELEASE` selects the original `dev.omarchy.vm-manager.unattended` service before accessing credentials. Provisioned debug builds and all optimized/signed-prerelease builds retain the protected service and user-presence policy. Never retry a failed/cancelled protected lookup against the development service, or downgrade/copy protected-only items.

**DESIGN DECISION:** development snapshot creation reads only saved non-secret defaults; credential retrieval remains at first launch before storage preparation. Reuse the original service/account UUID and normal login-Keychain protection for development reads and explicitly entered new passwords. No implicit migration, credential replacement/deletion, broad enumeration, permissions, local real signing identity, app installation or VM launch is authorized by these implementation checks. The form reports the selected flow and hides unavailable biometric-upgrade controls. Diagnostics expose the compiled development mode without a credential read; signed verification requires it to be false. The pre-existing per-guest owner-override edits remain intact. See [compatibility details](docs/TouchID.md#development-compatibility--2-november-2026).

**TO PROVE:** native login-Keychain prompt count/trust after an ad-hoc binary change and the provisioned Touch ID/password flow. Synthetic checks do not establish live authentication, real guest, focus, sleep/wake or crash behavior. The Apple/notarization/installation boundaries above remain unchanged.

**USER AUTHORIZATION / VERIFIED — compatibility installation, 2 November 2026:** the user requested installing the verified compatibility build, explicitly retaining no backup of the current app and launching/modifying no VMs. A read-only query of the already-running manager reported one guest and zero active/transitional guests; process inspection found no VM runtime. Closed only the installed manager normally, then verified a staged candidate and atomically replaced `~/Applications/Omarchy VM Manager.app`. Final-path verification passes and all 64 installed files/modes match the candidate. The superseded app was removed from the transaction stage; no backup was retained and pre-existing older backups were untouched. Registry/defaults hashes and the complete guest-tree stat fingerprint (30 entries) match before installation/manager closure. No Keychain item, VM lifecycle/storage action, permission grant, real signing identity or notarization submission was involved. The installed app remains closed. See [installation evidence](docs/Validation.md#compatibility-build-installation--2-november-2026).


## Native host-folder sharing — 2 November 2026

**DESIGN DECISION — user request:** add explicit per-VM opt-in sharing, default host path `~/Shared` with native/CLI overrides. The user accepted the runtime's native `/mnt/mac` destination instead of `/mnt/shared`. Reuse the kit's existing writable virtio-9p export and packaged guest mount service; do not add a second sharing controller or guest bind mount. Read-only exports and hot-plug are unsupported. Native and CLI stopped edits persist schema-5 profile metadata and apply at the next start. Missing legacy metadata remains off.

**VERIFIED — pinned source inspection:** schema-1 `sharedFolderPreferences` stores path/isEnabled. The native guest integration mounts tag `mac` at `/mnt/mac` with `cache=readahead`; it is separate from the read-only managed SSH share. The public protocol supplies no sharing configuration or live mount-health event. Existing kit provenance and graphics/clipboard code stay unchanged.

**PRIVATE COUPLING:** ManagerStorage recognizes only the reviewed sharing payload, writes it under the matching runtime lock/revision and prevents global-preference inheritance. A separate read-only pinned SSH probe validates VM/session/owner and exact tag, destination, filesystem, read-write mode and cache policy. Its errors never release live sessions or reservations. Host paths are dedicated owned home subdirectories with bounded metadata checks, no automatic creation/chmod/TCC request. See [SharedFolders.md](docs/SharedFolders.md) for the trust boundary and native home-link behavior.

**TO PROVE:** actual file access, restart persistence, disablement, official/lean compatibility, repeated-write integrity, focus, sleep/wake and crash behavior. The source change grants no installation, runtime build, guest change or restart approval. Existing UUID `38012142-9431-437A-A042-64ECE8E9DD36` remains protected until the concrete validation proposal is approved.


**USER AUTHORIZATION / VERIFIED — sharing acceptance, 2 November 2026:** approved deployment and validation on the original Dev VM disk, with the user later confirming completion there before their own recreation. Manager 0.10.0 (23) retains the exact runtime. Lean integration 0.1.0-43.1/kernel 7.3.0-7-omarchy mounts `~/Shared` at `/mnt/mac` with read-write access and safe `cache=0x1`. Exact bidirectional/append file checks, restart persistence and clean disablement/home-link cleanup passed, followed by re-enablement. Disk identity/size, protected profile/factory and SSH-key/pin hashes remain unchanged. Accelerated VirGL and 2× native scaling are observed; the matching clipboard bridge runs without reading clipboard contents.

**DESIGN DECISION / PRIVATE COUPLING:** accept an omitted default protocol in Linux mount reporting while refusing a reported conflicting version; the pinned service still supplies 9p2000.L. Serialize optional power/sharing checks and bound transport retries to three; trust/configuration/authentication and malformed-report failures remain immediate. Fixed error categories exclude raw SSH stderr. An intermittent SSH exit-255 cause remains unproven. The storage helper now consumes the manager's shared schema-1–5 registry admission rather than a duplicate outdated range. The user's earlier Trash attempt was refused and moved no storage; helper admission tests use disposable metadata only.

**VERIFIED — final no-VM checks:** 206 Swift tests/35 suites, 43 script tests, manager build and exact packaged signature/inventory/compatibility/layout verification pass. **TO PROVE:** official and other lean artifacts, workload-wide write integrity, native form interaction, human clipboard/focus transfers, sleep/wake and crash behavior. See [the authorized live checks and limitations](docs/SharedFolders.md#authorized-live-validation--2-november-2026).


**VERIFIED — sharing final handoff:** final installed 0.10.0 (23) passes installed-path verification and 65 seconds of health observation across two monitor intervals. Dev VM remains Running / SSH ready / Mounted with `~/Shared → /mnt/mac` read-write. The two disposable test files are removed after inode/hash checks and guest confirmation; unrelated host files are preserved. No guest disk was replaced, reset or moved to Trash. Untested behaviors retain the TO PROVE distinctions above.

**VERIFIED / DESIGN DECISION — notarization status runner capacity, 3 November 2026:** status check `41454275517` failed before acquiring a hosted arm64 runner after 15 minutes; it made no Apple request. Move only the read-only `notarytool info` job to the supported explicit `macos-15-intel` pool. It neither builds nor executes the arm64 app. Preserve the exact `v0.9.4-dev.1` tag/source/submission/candidate, API-only credential scope and every publication gate. Build/signing runner architecture and application source remain unchanged; Apple acceptance and the remaining signed-release gates remain **TO PROVE**.

**VERIFIED — Intel status query:** workflow YAML parsing and `git diff --check` pass. [Check `41459343609`](https://github.com/reactive-org/omarchy-vm-manager/actions/runs/41459343609) acquired `macos-15-intel`, verified the immutable release source and successfully queried the same submission at `2026-11-02T14:10:16Z`; Apple still returned `In Progress`. The API key was cleaned up and the status JSON retained. No new upload, signing, local credential use, app installation/UI, permission or VM operation occurred. The already-queued arm64 check was left untouched.


**VERIFIED — accepted v0.9.4-dev.1 runtime, 3 November 2026:** [status check 41542574263](https://github.com/reactive-org/omarchy-vm-manager/actions/runs/41542574263) returned `Accepted` for retained submission `c30ff885-b28d-4039-9314-1bf8f53267cf`. The original Actions artifact ZIP was downloaded and its full SHA-256 `457fa325f94429f23e81f48573084eaa749f78b2e8ab344e4a82f00dc0252fbb` verified; its runtime ZIP remains `d75f504b50ab7a690cd58bcfb7bbb6be1d40e3879ce17e07fbe4f843dd91f0d8`.

**DESIGN DECISION — retained candidate continuation:** the manual release-specific workflow checks the original run, immutable tag/source, successful test jobs, artifact digest and exact candidate bytes, then obtains a fresh accepted Apple log bound to that ZIP before importing signing credentials. It checks all runtime signatures/entitlements/network pins and unsigned-payload continuity, staples through the upstream boundary and derives signed provenance without rebuilding, re-signing or resubmitting the runtime. Only reviewed continuation scripts are copied into the exact tagged app checkout. App compilation, manager-only provisioning, inside-out signing, Apple acceptance/log binding, stapling, Gatekeeper and extracted final ZIP verification remain publication gates. Candidate ZIP/digest/submission evidence is saved immediately and retained on failure; an app upload must be followed by its existing UUID rather than repeated to poll. Existing release assets are never overwritten.

**VERIFIED — continuation preflight:** `make test` passed 206 Swift tests across 35 suites and 48 script tests; workflow YAML parsing, `git diff --check` and extraction/validation of the real retained artifact passed. No local signing credentials, app/UI, permissions or VM operations were used. **PRIVATE COUPLING:** exact upstream signed-kit layout, code inventory and network pins are revalidated, not inferred from Apple acceptance. **TO PROVE:** accepted-log archive binding, CI runtime stapling, provisioned signed app, Gatekeeper/final ZIP and publication; native Touch ID and guest behavior require separate observation.


**VERIFIED — signed v0.9.4-dev.1 publication, 3 November 2026:** [continuation run 41543818602](https://github.com/reactive-org/omarchy-vm-manager/actions/runs/41543818602), tooling `aaec79359e80186b16829d57686544e66e6aabd4`, verified the accepted runtime log against the original ZIP, all runtime signatures and unsigned-payload continuity, then stapled through the upstream pipeline. It compiled immutable app source `ef98347fde21cbdcb1002506c828e36e7ee9cda3` in SIGNED_PRERELEASE mode with the exact manager-only provisioning profile. Apple accepted app submission `1a8a4bf8-7c49-49e2-a6bc-48106fd965e5` (created `2026-11-02T23:16:28.730Z`); its log was bound to the submitted archive before stapling. All app/child signatures, profile/certificate/team/entitlement and process diagnostics, Gatekeeper and extracted final-ZIP checks passed before [publication](https://github.com/reactive-org/omarchy-vm-manager/releases/tag/v0.9.4-dev.1) at `2026-11-02T23:17:29Z`. CI removed its temporary credential files, keychain and provisioning-profile file.

**VERIFIED — independent published downloads:** all 14 asset sizes/SHA-256 digests match GitHub, and both ZIP checksums match. App ZIP SHA-256 is `1fe853a59d56158d38ac7d0af7d0702373ad6a44394fd71be2f36d42a86e757e`; stapled signed-runtime ZIP SHA-256 is `37ced51031e2c032c469a606587ac70d931d33eb79408b4313194021f3491dd0`. Read-only verification of the downloaded/extracted app with its exact tagged verifier passed provisioning, all signatures, Apple notarization, ticket/Gatekeeper and no-host-preflight process diagnostics. The downloaded runtime passed all 22 Mach-O signature/team/hardened-runtime/timestamp/entitlement/network-pin checks, full locked inventory and unchanged unsigned payloads. The immutable annotated tag still resolves to the exact app source. Source-compatible provenance is retained at `Config/SignedRuntimes/v0.9.4-dev.1.lock.json`; main has advanced, so current development runtime configuration/pins are preserved. Original and accepted candidate archives/public provenance remain in ignored `VendorArtifacts/signed-candidates/v0.9.4-dev.1/` beyond Actions expiry.

**TO PROVE:** native Touch ID/password-fallback interaction, saved-password migration and real guest behavior are not established by these CI/bundle checks. No local signing credentials, installation/UI control, permission grants, factory-image download or guest/storage operation occurred. Existing custom factories tied to ad-hoc runtime provenance remain preserved and require compatible signed-runtime preparation.


## Manual application update checks — 3 November 2026

**DESIGN DECISION — user request:** add **Check for Updates…** to the manager's application menu. Only an explicit selection queries public GitHub release metadata for `reactive-org/omarchy-vm-manager`. Include stable releases and prereleases with uploaded app archives, compare full semantic versions, ignore drafts and runtime-only releases, and show a native result modal. **View Release** opens that release's GitHub page for manual download. No automatic checks, app installation, runtime update, guest/storage operation or provenance admission is introduced.

**DESIGN DECISION — release identity:** embed the exact validated `RELEASE_TAG` as `OmarchyReleaseTag` during app assembly before signing. Preserve normal bundle version/build fields. Package verification requires matching tags/versions in staged and extracted apps. A local build without a full tag reports that it cannot reliably compare prereleases rather than guessing from git or the build number. See [manual check behavior and validation](docs/Prereleases.md#manual-update-checks).

**USER-REPORTED — UI smoke check:** the user accepted the opened isolated tagged build (“looks good”); individual result branches and View Release navigation were not separately recorded. **TO PROVE:** independent live GitHub response verification and browser navigation. Fixture/no-window bundle checks establish neither of these. Real two-VM, focus, sleep/wake, crash and authentication behavior retain their existing evidence boundaries.

## Independent factory guest compatibility — 3 November 2026

**DESIGN DECISION — supersedes source equality and full-runtime binding for new lean factories:** use independently versioned guest integration contract 1 and format-2 manifests. Require supported guest status/SSH/setup/contracts/report versions, the complete reviewed lean package archive identity, unchanged lean owner-program contract, intact image/build evidence and all existing payload checksums. Preserve source commits as provenance, allowing different commits with the same supported package. Keep complete current runtime inventory/signatures/compiled pins as execution requirements rather than comparing a factory's historical host binaries with the current kit. The manager and private helper use the same compiled reviewed contract. See [the policy, review identities and limitations](docs/FactoryCompatibility.md).

**DESIGN DECISION — migration:** legacy lean manifests lack complete package evidence and fail with instructions to prepare and explicitly import a separate format-2 bundle. No disk rebuild is needed when the original archive is available and supported. Legacy official-contract custom manifests and schema-1 receipts retain exact runtime binding. New schema-2 receipts bind factory identity and reviewed guest contract, preserving the original runtime hash as provenance; selection always revalidates current compatibility. Unknown/damaged evidence is refused and preserved. No existing profile, disk, factory/cache or receipt is rewritten.

**PRIVATE COUPLING / TO PROVE:** a full verified package archive identifies every integration component, including services/install hooks and package metadata, but is not an independent measurement of the raw disk or a publisher attestation. Import retains its operator-trust boundary. Real boot, guest dependency availability, owner setup, focus, sleep/wake and crash behavior are not established by these static/synthetic changes.

**VERIFIED — synthetic/static validation:** `make test` passes 213 Swift tests in 36 suites and 46 script tests; `make test-build-policies` passes two checks in each optimized mode; `make build`, the complete upstream no-VM suite (554 Swift tests plus contract/guest-script/shell fixtures), local runtime archive verification and separate uninstalled ad-hoc bundle verification pass. Production default-policy verification accepts the real reviewed archive with a different source commit in a synthetic nonbootable-image fixture. The guest package is unchanged; only helper/provenance/seal resources were rebuilt. Exact pins, commands, retry/skip records and remaining release/live limitations are in [Factory compatibility](docs/FactoryCompatibility.md#validation--3-november-2026). No existing VM, factory/cache, receipt, installed app, credential or permission was changed.


## Signed release after PR #2 — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** the user requested a fresh signed release after PR #2 merged. Prepare unused tag `v0.10.0-dev.1` from merged main `d8a05f083b5aaddf88e09e006ae371e286799d6a` plus scoped release-tooling/evidence changes. Preserve the merged app version 0.10.0 (23), development pins, factory compatibility policy and existing data. The new runtime is `033d2460dc44796afeb6d08b6a32aaf51febf8be`, source-lock SHA-256 `da0bcbe9fada6fcee46e815007829fb0d6d1f53d8d21f510e18e9da7196a1c0a`, development ZIP SHA-256 `7f04725a26aa665e30ffc4a7ba6901a4735fd7eb621611811c8ee1a60236b801`. The older signed lock is incompatible and remains versioned historical evidence.

**DESIGN DECISION — normal release path:** fresh runtime and app submissions must validate an Accepted Apple log bound to their exact ZIP before stapling. Retain original pre-staple runtime/app candidates, immediate UUID/digest receipts, source/CI identity and public JSON evidence on success or failure. The normal tag-driven workflow still requires all no-VM tests, upstream signing boundaries, unsigned-payload continuity, exact manager-only profile/certificate/team/entitlements, process diagnostics, Gatekeeper and extracted final ZIP before publication. Do not re-upload a pending candidate to poll. No local real signing credentials, installation/UI, permissions, saved-password migration, factory-image download or guest/storage mutation is authorized. **TO PROVE:** this new tag's CI signing/publication and native Touch ID/real guest behaviors.

**VERIFIED — new-release preflight:** `make test test-build-policies` passes 213 Swift tests across 36 suites, 51 script tests and two admission/credential-policy checks in each optimized configuration. Release workflow YAML parsing and `git diff --check` pass. These checks use no real signing credentials or VM. The app/runtime/configuration source is unchanged from merged PR #2; only release orchestration, guard tests and documentation changed.


**VERIFIED — standard tagged release, 3 November 2026:** [`v0.10.0-dev.1`, run 41558678954](https://github.com/reactive-org/omarchy-vm-manager/actions/runs/41558678954), immutable app source `d72dd2b05281767dfcb472442eea37af72dcc921`, passed 213 manager tests, 51 script tests, both optimized admission modes, all 554 upstream Swift tests and isolated SSH checks. The ordinary tag-triggered signing job published the [new prerelease](https://github.com/reactive-org/omarchy-vm-manager/releases/tag/v0.10.0-dev.1) at `2026-11-03T01:27:03Z`, without the earlier one-off continuation workflow. Apple accepted runtime `50e82923-5ba7-4aa8-8ced-886eca9fd9a2` (original ZIP `d3a7f3fa43f2ce4bc57683ff0465175cccced80f298852503cbb276c0fa89523`) and app `a4d1cedd-f04e-4a73-a9a1-694b4dfaca68` (original ZIP `5de417d162014470515b10462cc9e4a46ea6789641003de89828aa441bec4789`). Both accepted logs were bound to exact archives before stapling. CI verified all signatures/profile/certificate/team/entitlements/process diagnostics, Gatekeeper and the extracted final ZIP, then cleaned up its temporary credentials/keychain/profile.

**VERIFIED — independent published artifacts:** all 10 GitHub asset sizes/digests and both ZIP checksums match. App ZIP SHA-256 is `e71e46409eddf072fd3dfcf58821659276c2bd7c5c1a501aed8eb643b02f9c21`; final signed runtime SHA-256 is `01020db4b7dcc0e766fc2d42b389f457c369d957241ce437c0913e3ef5eddcb2`. Downloaded app provisioning, child/manager signatures, notarization, stapling/Gatekeeper, process capability and no-host-preflight bundle/layout checks pass. All 22 runtime Mach-O files pass team/hardened-runtime/timestamp/entitlement/network-pin/notarization checks; full inventory and unsigned-payload continuity match the new source lock. Both exact accepted candidate archives and the complete source-bound Actions artifact `13196007297` (SHA-256 `e295e38a6d01ddb2da4052dded8bdca8892949816db0b1392435f2ff2236bf6a`) are retained with public provenance under ignored `VendorArtifacts/signed-candidates/v0.10.0-dev.1/` beyond expiry. Every accepted app payload/signature matches the final published app; only the validated staple ticket was added.

**DESIGN DECISION / VERIFIED — subsequent compatible releases:** main still consumes exactly the new source lock/kit, so retain the reviewed signed lock both at `Config/SignedRuntimes/v0.10.0-dev.1.lock.json` and `Config/TryOmarchySignedRuntime.lock.json`. The actual normal pinned-runtime path downloaded and verified the published archive successfully with no signing identity; submission was explicitly refused during this check. Future compatible releases reuse these exact signed bytes. Changed source lock/kit or damaged provenance fails closed and requires a deliberate new signed runtime. Development runtime lock/pins remain unchanged. The release-bound API-only checker now targets the accepted final app and the new immutable tag/source.

**TO PROVE:** real native Touch ID/Mac-password behavior, saved-password upgrade and new signed-runtime guest/focus/sleep/wake/crash behavior remain outside these CI/bundle/reuse checks. No local real signing/notarization credentials, installation/UI, permissions, factory download or guest/storage action occurred.


## Touch ID pre-launch error report — 3 November 2026

**VERIFIED — user report/source inspection:** the user reports that `v0.10.0-dev.1` showed no Touch ID prompt after an apparently successful explicit upgrade, then refused profile creation and a repeated upgrade with the same generic authorization error. Two supplied screenshots establish those UI failures; they contain no numeric Security status and do not establish the exact native cause. Both operations call the same metadata-only query with authentication UI disabled. The old Guest Defaults success flag belonged to the view and reset when leaving it. Upgrade/profile creation do not intentionally retrieve the protected password; actual approval is reserved for first launch.

**DESIGN DECISION — blocked metadata is not proof of missing/authorized data:** handle only `errSecInteractionNotAllowed` from the exact noninteractive probe as deferred validation. It may mean required authentication or an unavailable/locked data-protection Keychain, so do not infer that an item exists, is protected or was upgraded. Profile creation may save metadata, but first launch must still complete the original single interactive protected read before any storage preparation/helper launch. Repeated explicit upgrade returns `authenticationPending` without reading a legacy/modern secret, adding/deleting/replacing anything or claiming success; the UI explains that state and keeps retry available. Explicit missing-item/provisioning/authentication/malformed-query errors remain failures. Actual protected reads still reject this status and never fall back to legacy access. Numeric OSStatus diagnostics contain no credential/UUID/Keychain attributes.

**DESIGN DECISION — UI state:** bind an in-memory upgrade result to the currently saved credential reference in AppModel, retaining it across view recreation. Confirmed upgrade/existing-item results differ from unconfirmed deferred authentication; a changed credential reference does not inherit the old UI result. No new persistence schema, automatic migration, authentication preflight or shared approval context is introduced. Prepare signed fix candidate `v0.10.0-dev.2`, manager 0.10.0 (24), using the already verified source-compatible signed runtime unchanged.

**TO PROVE:** the user's exact underlying OSStatus, end-to-end native prompt/fallback, cancellation/prompt count and real guest setup on the fixed signed app. Synthetic tests cover the specific blocked-metadata regression and first-launch refusal but cannot prove this is the only native failure. No real Keychain query/secret access, migration, installation/UI control, permission, VM launch or existing storage change was performed by the agent.

**VERIFIED — candidate regression/build checks:** `make test test-build-policies build` passes 215 Swift tests in 36 suites, 51 script tests, both optimized admission/credential-policy configurations and the app/CLI/helper build. Injected Keychain tests cover deferred blocked metadata, no legacy/modern secret read or item/defaults mutation during that deferred upgrade, explicit missing/provisioning/authentication errors, and both blocked and cancelled actual first-launch reads stopping before any disposable VM root is prepared. This is synthetic proof of the code paths, not a native Touch ID success claim.

**VERIFIED — signed fix candidate, 3 November 2026:** [`v0.10.0-dev.2`, run 41562927412](https://github.com/reactive-org/omarchy-vm-manager/actions/runs/41562927412) passed 215 manager tests, 51 script tests, both optimized policy modes, all 554 upstream tests and isolated SSH checks. Source `e0122077401e6fec16a9cb7d4415ac0b93ca6aac` produced manager 0.10.0 (24). The normal release job reused the exact accepted runtime `01020db4b7dcc0e766fc2d42b389f457c369d957241ce437c0913e3ef5eddcb2` from `v0.10.0-dev.1`, with no runtime re-signing/submission. Apple accepted app `4bde8c3b-cb6a-4cbc-9bc6-b6b291106770`; its log binds original submitted ZIP `2f318288262ef9c346df8d9fc4eb2a65d94643c84977a96c94c46fe8f3ac4941` before stapling. Publication completed at `2026-11-03T02:05:35Z`; CI cleaned up its temporary credentials/keychain/profile.

All nine published asset sizes/digests and both ZIP checksums match. Downloaded build 24 independently passes exact runtime/layout, manager/child signatures, provisioning/certificate/team/entitlements, no-host-preflight process diagnostics, Apple notarization/stapling and Gatekeeper checks. App ZIP SHA-256: `c509c014c2f3dc1c4ccb178ea251a12188e95a5a87dac0bec55d3c8df6c68c12`. Every accepted app payload/signature matches publication; only the validated staple ticket was added. Exact submitted app and full Actions artifact `13197143422` (SHA-256 `2b695ab1787f3c90b7000d5bc8cfb40c3d4cf5c4a5e5973da9f6c5b9f3d28196`) and public source/job receipts are retained under ignored `VendorArtifacts/signed-candidates/v0.10.0-dev.2/`. Versioned runtime provenance points to the unchanged original signed runtime; development/runtime configuration is preserved.

**TO PROVE:** native resolution of the user's error and its original OSStatus, Touch ID/Mac-password prompts, prompt count/cancellation and real guest setup still require user validation. These signed bundle/CI checks never access the user's saved Keychain item or launch/install/control a guest/app. The fix is a tested candidate for the identified noninteractive pre-launch failure path, not a claim that the screenshot established its underlying numeric status.


## Native Touch ID confirmation — 3 November 2026

**VERIFIED — user clarification/report:** the user identified that the preceding failure screenshot came from the wrong installed version. Read-only inspection then found `/Applications/Omarchy VM Manager.app` at 0.10.0 (24), with the expected signing team, and its manager process running. After being directed to reopen/confirm build 24, the user reported: “Touch ID worked when I started the VM.” Record this as user-verified successful native Touch ID authorization at VM start in the current `v0.10.0-dev.2` test sequence. The agent did not read a real Keychain item, take over authentication UI or launch/change a VM.

**TO PROVE:** the original failures' exact OSStatus/cause and whether the metadata fix was necessary for those attempts remain unknown; do not retrospectively attribute them to `errSecInteractionNotAllowed`. This report does not establish Mac-password fallback, cancellation, exact prompt counts, repeated/per-VM isolation, completed guest setup, focus, sleep/wake or crash behavior. It supersedes the pending-native-authentication claim only for the successful user-reported Touch ID-at-start case.


## Guest sudo Touch ID implementation — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** implement source and no-VM checks in an isolated worktree. Add default-off “Allow Touch ID inside this VM” to stopped profile editing and creation, strict CLI/configuration (`--guest-touch-id on|off`, `guestTouchID`) and JSON status. Old profiles decode as off. Host status reports requested/next-start/unavailable/disabled, with guest pairing explicitly unknown. No setting proves guest enrollment or authentication readiness. Existing setup-password Touch ID is independent and supplies no pairing or approval secret.

**PRIVATE COUPLING / DESIGN DECISION:** extend exact source `033d2460dc44796afeb6d08b6a32aaf51febf8be` through the reproducible cumulative patch. Pass typed manager VM/run UUIDs through the host run configuration; never accept guest-selected key paths. The helper uses a dedicated manager key namespace, exact QEMU and controller PID/birth identities, a kernel-owned nonblocking lease across manager helpers, and revocable per-run epochs. Preserve protocol-3 signing, nonce/context binding, biometrics-only approval, pre/post process/focus checks and the 15-second signature lifetime. Permit the Apple-verified LocalAuthentication UI agent during a pending prompt; other focus changes cancel. Pause, sleep, shutdown and exit revoke the epoch, and a late approval cannot revive a revoked request. Crashes release the kernel lease; PID reuse cannot inherit authority. No competing broker, cryptography or guest PAM implementation is introduced.

**DESIGN DECISION — sudo milestone:** enable only enroll/disable/sudo in the managed bridge. Pair explicitly inside the guest with upstream Setup → Security → Touch ID for sudo or `try-omarchy-touch-id`. Denial, contention or unavailable authentication follows normal Linux password fallback. 1Password remains a documented subsequent opt-in milestone and its managed unlock operation is refused for now. No fingerprint passthrough, guest login/screen unlock or general authorization is offered.

**VERIFIED — static package review:** exact reviewed official `0.1.0-43` and lean `0.1.0-43.1` archives contain identical upstream authentication tools and declare Python, OpenSSL, GTK 3, polkit and Python GObject dependencies. Their complete package hashes are explicitly pinned for authentication admission independently of the generic owner contract. The package/wire protocol and guest source tree are unchanged from the prior runtime. PAM/sudo availability on an installed disk and package installation/upgrade remain TO PROVE. Changed host bytes require new development runtime provenance; historical signed locks are preserved and cannot authorize this source.

**TO PROVE:** native enrollment, Secure Enclave behavior, Linux password fallback, exact prompt/focus behavior (including supported macOS authentication UI), two-VM contention, pause/sleep/wake/shutdown/crash cancellation, re-pairing and UI layout. Implementation work grants no permission to run guests, enroll keys, change PAM, install/configure 1Password, use real signing credentials, control authentication UI or publish a release. See [the separately approved native plan and check evidence](docs/GuestTouchID.md).


**VERIFIED — no-VM implementation checks:** `make test test-build-policies app verify-bundle`, followed by `make test` for the software-key guest-verifier fixtures, passes 229 manager Swift tests across 38 suites, 59 script tests, both optimized policy modes and uninstalled ad-hoc bundle verification (`vmLaunchEnabled: false`). `make test-upstream` passes 561 Swift tests in 110 suites plus guest/script/shell/compatibility fixtures. The rebuilt ad-hoc runtime uses source `8d5015ec740aad5417b601e05d451b28ed45d573`, ZIP SHA-256 `ec002c2b241454d7430729ebf850cb6f58612db2b96b8a6c8c30f2f6d64e3ded` and source-lock SHA-256 `91223707e872d9113a5b54ddf83a2d09fc9ebb65f9e23e3a377d657bc3c0f0e6`. Exact commands, package continuity, sandbox retry limitations and the native plan are recorded in [Guest Touch ID](docs/GuestTouchID.md#no-vm-check-evidence). These checks do not prove native enrollment, guest sudo, focus, multi-VM cancellation or UI behavior.


## Guest sudo Touch ID signed verification release — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** after reviewing the implementation, the user requested a release for verification. Prepare `v0.11.0-dev.1`, manager 0.11.0 (25), from guest Touch ID implementation `ad2514038500f699cf865d211d51e0b5294ca5eb` plus release identity/evidence changes. Publish the exact reviewed development runtime as the digest-named CI dependency, then use the normal tag-driven CI path to sign and notarize the new runtime and app. Existing GitHub Actions credentials/profile are scoped to that job; no local real identity or credential use is authorized. Keep all Apple acceptance/archive binding, stapling, signature/profile/team/entitlement, Gatekeeper and final extracted-ZIP checks as publication gates.

**DESIGN DECISION — runtime transition:** retire only the active historical `Config/TryOmarchySignedRuntime.lock.json`, after confirming its bytes are preserved at `Config/SignedRuntimes/v0.10.0-dev.1.lock.json`. This deliberately selects a fresh signed runtime for changed source `8d5015ec740aad5417b601e05d451b28ed45d573`, source-lock SHA-256 `91223707e872d9113a5b54ddf83a2d09fc9ebb65f9e23e3a377d657bc3c0f0e6`, development archive SHA-256 `ec002c2b241454d7430729ebf850cb6f58612db2b96b8a6c8c30f2f6d64e3ded`. Development pins, reviewed guest package and factory compatibility contracts stay unchanged. Existing profiles, writable disks, saved credentials and installed apps are preserved.

**TO PROVE:** this new candidate's CI signing/notarization/publication and all native guest Touch ID behavior. Preparing the release does not authorize installation, guest launch, key enrollment, PAM changes, 1Password setup, permission grants or UI control. The separately approved disposable-UUID native plan remains in `docs/GuestTouchID.md`.


## v0.11.0-dev.1 accepted-runtime recovery — 3 November 2026

**VERIFIED — first tagged run:** immutable source `01631ee6ba261e85a22dd3f7959b60d678ababf8`, run `41570011640`, passed 229 manager tests, 59 script tests, both optimized policy modes, all 561 upstream Swift tests and isolated SSH checks. Apple accepted runtime `4c6a7ba6-f9ce-4740-93f3-38c276534f3f` (created `2026-11-03T03:13:10.716Z`, submitted ZIP SHA-256 `8597cfef14d02db91b1fb011e84aa2f1b433c8f837c4624fb08171694f4c7e61`). The accepted log binds that exact archive. A subsequent upstream ticket-validation request failed with `NSURLErrorDomain -1005` / stapler error 68 when the connection to Apple's ticket service was lost. The app was not built/submitted or published. CI cleaned up its temporary keychain, credential files and provisioning profile.

**VERIFIED — preserved evidence:** artifact `13201332381`, SHA-256 `cd1ee3723e4a59cfe4ff2e63fa37eeef18a54b3a848f385b1ca8a6fe1e33e2ae`, is retained locally with original CI/source/job metadata under ignored `VendorArtifacts/signed-candidates/v0.11.0-dev.1/`. The complete eight-member artifact, submitted/runtime archive equality, source/receipt hashes and accepted Apple log validate. Read-only local verification passes all 22 runtime signatures/team/hardened-runtime/timestamp/entitlement/network-pin checks and unchanged unsigned payloads. No local signing identity or Apple credential was used.

**DESIGN DECISION — scoped recovery:** continue the same immutable app tag/source using the preserved accepted runtime, without re-signing or resubmitting it. The branch-scoped manual recovery workflow validates the original failed run and successful no-VM jobs, exact complete artifact and receipt, then obtains fresh Apple acceptance bound to the same archive before importing CI signing credentials. Only reviewed release scripts are overlaid onto the tagged checkout; app/source/config/patch bytes must remain unchanged. Retry the same upstream stapler operation at most three times only for explicit transient network errors (-1005/-1001/-1009); signature/policy failures and persistent errors remain failures. App signing/notarization, ticket/Gatekeeper/profile/signature checks and extracted-ZIP verification remain publication gates.

**VERIFIED — recovery tooling checks:** `make test` passes 229 Swift tests and 63 script tests. New fixtures reject changed complete-artifact members, source, candidate or acceptance evidence, prove identical ticket commands on transient retry, and prove immediate policy-error refusal and bounded failure. Recovery workflow YAML parsing and `git diff --check` pass. **TO PROVE:** the recovery's actual ticket retrieval, signed app, notarization and publication; all native guest authentication remains outside this release work.


**VERIFIED — first recovery outcome:** run `41571555638` validated the original source/artifact, obtained fresh Apple acceptance, successfully stapled and verified the retained runtime, and compiled the optimized app executables. Assembly then encountered the same explicit `NSURLErrorDomain -1005` in its nested upstream ticket validator. App signing/submission/publication did not occur. Temporary credentials/profile were cleaned up. Recovery artifact `13201278392` (SHA-256 `0e16e24ce41ecf611ec8b68bb6b60e44a76b29a5aff45958f2247b6fd9947cbf`) preserves the stapled runtime and evidence.

**DESIGN DECISION / VERIFIED — complete ticket retry coverage:** share a bounded retry around every ticket-dependent read in runtime verification, app assembly, extracted app verification, stapler and Gatekeeper checks. Retry only the same read/staple command on explicit transient network markers, up to three attempts; no signature/policy requirement is removed, no runtime is re-signed/submitted and persistent failures remain fatal. Overlay only the reviewed release scripts/module onto immutable app source `01631ee`. `make test` passes 229 Swift tests and 66 script tests; the final script rerun, YAML parsing and `git diff --check` pass. New tests exercise the actual nested-verifier subprocess errors and ensure unchanged notarization flags, same commands, immediate pure policy refusal and bounded persistent failure. Native behavior remains **TO PROVE**.


## Published guest sudo Touch ID candidate — 3 November 2026

**VERIFIED — signed release:** [v0.11.0-dev.1](https://github.com/reactive-org/omarchy-vm-manager/releases/tag/v0.11.0-dev.1), manager **0.11.0 (25)**, immutable app source `01631ee6ba261e85a22dd3f7959b60d678ababf8`, was published at `2026-11-03T03:29:47Z` by recovery run [41572165206](https://github.com/reactive-org/omarchy-vm-manager/actions/runs/41572165206), tooling source `34936ac2bacd00daf8af4198929365423e63617f`. Original tagged no-VM jobs passed; recovery guards passed 66 script tests. Recovery reused the exact accepted runtime without re-signing or resubmitting it. Apple accepted app `7f995769-560f-46c7-afc8-4ceae90620a2`, submitted ZIP SHA-256 `66557d3dbeac90afbde54e988c76bd4ac11ea95be3e7558a966e6db79ee705fb`. Its acceptance log was bound to those bytes before stapling. All app/runtime/profile/team/entitlement, hardened-runtime/timestamp, networking-pin, Gatekeeper and extracted-ZIP gates passed. CI removed its temporary credentials, keychain and provisioning-profile file.

**VERIFIED — independent published downloads:** all 15 GitHub asset sizes/SHA-256 digests and both ZIP sidecars match. App ZIP SHA-256 is `4699690d2e984819866f22e2d6d1a6b10db43cf6c10d038d524009bf5029f51d`; stapled signed runtime SHA-256 is `703c318be33adf82812db15cf561fd17622bc356ea1cc7279b5c593b231905c4`. The downloaded app passes provisioned protected-storage process diagnostics, manager/child signatures, all 22 runtime Mach-O checks, notarization/stapling/Gatekeeper, exact inventory/layout and version/tag/build checks with host preflight and VM launch disabled. The exact accepted submitted app/runtime are retained and their Apple logs validate against their original SHA-256 values. Every submitted app payload/signature matches publication, with only the validated outer staple ticket added. Runtime unsigned payloads remain identical to the reviewed development kit.

**VERIFIED — retained evidence and compatible reuse:** the full successful Actions artifact `13201389267` (111,693,951 bytes, SHA-256 `2d1838ce479d20392f43b59eac0330fa659e4f540222e1489e341b63e09ee5fa`) and both earlier failed-run artifacts are preserved under ignored `VendorArtifacts/signed-candidates/v0.11.0-dev.1/` beyond Actions expiry. Public release/source/job/receipt metadata and original accepted archives are retained there. The immutable app tag remains unchanged. Commit the independently verified signed lock at `Config/SignedRuntimes/v0.11.0-dev.1.lock.json` and as the active `Config/TryOmarchySignedRuntime.lock.json`; historical locks remain preserved. The normal pinned-runtime path downloaded and verified the published signed kit successfully with signing/submission explicitly refused during that read-only check. Development runtime lock/pin, guest package and factory contracts remain unchanged. Remove the completed one-off recovery workflow from this branch; its exact executed source remains in Git history.

**TO PROVE / authorization boundary:** this release establishes signed artifact identity and distribution, not native guest sudo success, enrollment, Linux-password fallback, focus, prompt count, multi-VM contention, sleep/wake/cancellation or crash behavior. Guest Touch ID remains off by default and pairing remains an explicit guest action. Managed 1Password unlock stays disabled. No installed app, user VM/disk/factory/receipt, saved credential, permission or authentication UI was changed. No guest was launched. Follow the separately approved disposable-UUID plan in [Guest Touch ID](docs/GuestTouchID.md).


## Guest authentication main-loop regression — 3 November 2026

**VERIFIED — user report and read-only inspection:** enrollment in signed 0.11.0 (25), `v0.11.0-dev.1`, returns “Touch ID was not approved” without a macOS prompt. The user reproduced it with a custom kernel and the official Try Omarchy factory image. Installed app/runtime identities match the published candidate. Read-only process and gate metadata show a live authentication helper, matching live parent/target processes and a private regular per-run epoch file. The manager key namespace exists with no enrolled key files for the active guest. No key contents, credentials, personal identifiers or guest disk contents were read or logged. The generic guest denial does not establish its host cause.

**VERIFIED — source regression / DESIGN DECISION:** the authentication bridge reads its guest channel and waits synchronously for LocalAuthentication on the main thread. Unlike the previously fixed clipboard bridge, it does not service the main run loop or serialize AppKit foreground reads there. Share the existing headless clipboard run-loop implementation with authentication, move its blocking reader/prompt wait to a worker and perform foreground/active-process and trusted Apple authentication-UI checks on main. Preserve exact process birth/executable identities, pre/post QEMU focus, revocable epochs, immediate cross-guest lease refusal, biometrics-only approval, signed protocol 3 and late-result rejection. Guest package sources and wire protocol are unchanged. This corrects a demonstrated scheduling defect; native attribution and successful enrollment remain **TO PROVE**.

**DESIGN DECISION — diagnostics:** emit only a closed set of non-secret host status codes for focus, process, epoch, lease, biometric availability, pairing and signing failures. Read complete whitelisted lines from the current client's bounded stderr for a manager notice and additive JSON status; never display arbitrary guest/error text. Successful host approval clears the old denial notice without asserting guest pairing or readiness. Diagnostics do not drive lifecycle or release reservations; only the matching `.exited` does.

**VERIFIED — initial regression checks:** 562 upstream Swift tests in 111 suites pass, including a standalone executable built from the actual authentication run entry point, shared run-loop adapter and prompt wait. Synthetic providers require AppKit-facing reads on main and exercise asynchronous main-queue completion, focus loss/return, inactive/unavailable targets and stale process refusal while the reader runs on a worker. Existing clipboard main-loop regression checks remain passing. These checks invoke no native prompt, Secure Enclave enrollment or VM.

**TO PROVE / authorization boundary:** native enrollment and sudo success/fallback, prompt presentation/count, native focus transitions and cancellation still require a new signed candidate and user testing. This investigation changes source and disposable build outputs only. It does not authorize changing the installed app, restarting or modifying the running guest, granting permissions, reading saved credentials, enrolling keys or controlling authentication UI. Historical signed runtime evidence remains preserved.

**VERIFIED — rebuild finding:** the first clean runtime rebuild exposed a pre-existing parallel test race: a child between fork and exec can briefly retain a close-on-exec lease descriptor after the owner closes it. The monitor fixture now bounds eventual reacquisition after cancellation; production lease acquisition remains a single nonblocking attempt. Preserve specific monitor rejection diagnostics when cancellation increments the signer generation. The failed attempt and final build logs are retained in local temporary build logs.

**DESIGN DECISION — next verification candidate:** prepare `v0.11.0-dev.2`, manager 0.11.0 (26), with the corrected source and a newly built pinned runtime. Retain the published dev.1 artifacts and versioned signed runtime lock unchanged. Native testing requires a signed/notarized build; no local real identity, installed app or user guest is used during preparation. Publication and CI credential use will follow the session authorization boundary.


**VERIFIED — final no-VM candidate checks:** `make patched-kit REUSE_GUEST_PACKAGE_KIT=...` completes with exact source `37c635f8992a9e19cc99696542bf061baff804c0`, patch SHA-256 `b4184dfdd39de0dfa7e0796e037db675fe372e1b1349216cfb8ac5b7d866c46e`, development ZIP SHA-256 `388144ccce86a6a04c383fb7893b163580d3722580bebd447330abbc3742494d` and source-lock SHA-256 `328acd039129cd6d5dae139cd1f426e18c50cfeaf91268e63541b6186686fd9d`. Complete inventory and all 22 ad-hoc Mach-O signatures verify. The guest-package/LICENSE trees and the reviewed package archive are unchanged. `make test test-build-policies app verify-bundle` passes 231 manager Swift tests in 38 suites, 66 script tests, both optimized admission/credential-policy modes, the app/CLI/storage helper build and uninstalled bundle verification (`vmLaunchEnabled: false`). `make test-upstream` passes all 562 Swift tests in 111 suites plus package, script, shell, compatibility and relocation fixtures. An early manager run started before the new runtime lock was written and correctly failed the old-lock/new-patch contract; the complete final run uses the matching generated lock/pin and passes. The earlier monitor-fixture failure is consistent with transient fork/exec descriptor inheritance under parallel fixtures; this is an inference, not an observed production authentication cause. No production retry/queue or weakened authentication check was introduced.

**DESIGN DECISION — signed runtime transition:** after byte-for-byte equality with `Config/SignedRuntimes/v0.11.0-dev.1.lock.json`, remove only the active `Config/TryOmarchySignedRuntime.lock.json`. The changed helper requires a fresh signed runtime; historical accepted dev.1 provenance cannot authorize it. Preserve every versioned signed lock and all published releases. Candidate `v0.11.0-dev.2`, 0.11.0 (26), is locally prepared and tested. CI signing/notarization/publication and native verification remain **TO PROVE**; no local real signing identity or installed app/guest was used.


## Guest authentication fixed signed candidate published — 3 November 2026

**VERIFIED — distribution:** user-approved `v0.11.0-dev.2`, manager 0.11.0 (26), immutable source `d2505d825f8bb4531217130ee09830efb3d57561`, was published by run 41576114029. CI passed 231 manager tests, 66 script tests, both optimized policies, all 562 upstream tests and isolated SSH checks. The independently downloaded app/runtime pass complete asset/provenance, original accepted-archive binding, signature/profile/team/entitlement, stapling/Gatekeeper and no-VM process checks. Preserve the full CI artifact and exact accepted originals locally; commit the verified signed lock as active and versioned provenance. The normal reuse path passes with signing/submission/credential access refused. Exact hashes, Apple IDs and limitations are recorded in [the release evidence](docs/Prereleases.md#published-guest-authentication-run-loop-fix--3-november-2026).

**TO PROVE:** native enrollment/sudo, dialog focus, cancellation and multi-VM behavior remain user verification work. The signed release proves artifact identity and distribution, not native resolution of every reported denial. No installed app, user VM, saved credential, permission or authentication UI was changed; no guest was launched.


## User-reported guest enrollment and sudo success — 3 November 2026

**VERIFIED — user report:** in the `v0.11.0-dev.2` verification sequence, the user supplied guest console output reporting successful host-key enrollment and a successful sudo authentication test with guest-password fallback explicitly disabled. Record this as user-reported successful guest enrollment and password-free sudo on this test guest. Read-only installed-app metadata confirms 0.11.0 (26), `v0.11.0-dev.2`. Do not retain the host key identifier, guest username, password input or other personal identifiers. The agent did not access keys/credentials, control authentication UI, change the installed app/guest or perform the test.

**TO PROVE:** exact native prompt presentation/approval and prompt counts were not independently observed; the console itself makes its Touch ID interpretation conditional on user approval of the prompt. Other guests, Linux-password fallback after denied/unavailable biometrics, focus changes/cancellation, contention, pause/sleep/wake/shutdown/crash and re-pairing remain untested natively. This result supersedes pending enrollment/password-free-sudo evidence only for the user-reported happy path; it does not prove that every preceding denial had the same cause.


## User-confirmed fallback, focus cancellation and recovery — 3 November 2026

**VERIFIED — user report:** after being given three single-guest checks in the build 26 verification sequence, the user confirmed them: (1) a fresh sudo request with Touch ID cancelled permits the Linux guest password fallback; (2) switching to another app during a pending request prevents that old Touch ID request from succeeding later; (3) returning to the guest and making a fresh request permits Touch ID authentication again. Scope this confirmation to those three described checks on the current test guest. The agent did not independently observe authentication UI, perform the tests, inspect secrets or change any VM. No personal/key identifiers are recorded.

**TO PROVE:** pause/resume, Mac sleep/wake, shutdown/forced-stop/crash cancellation, rapid focus transitions and exact prompt counts, unavailable-biometry fallback, re-pairing and two-VM contention/key isolation remain pending native observation. This report supersedes the earlier pending cancel-to-password fallback, ordinary focus-loss cancellation and fresh-request recovery claims only for the user-confirmed manual cases. It does not establish lifecycle or multi-VM behavior or authorize agent-driven native interaction.


**DESIGN DECISION — native test refinement, 3 November 2026:** isolate pause cancellation from focus-loss cancellation using the existing background CLI command socket and upstream password-fallback-disabled `try-omarchy-touch-id-test`. The reviewed manual procedure is in [Guest Touch ID](docs/GuestTouchID.md#focus-preserving-pauseresume-check). The CLI/prompt behavior is verified from source and the shell snippet passes syntax checking; the lifecycle test itself remains **TO PROVE**. No agent-driven pause/resume, sleep, shutdown, guest launch, UI control or credential/key access was performed.


## Helper-reported manual pause/resume — 3 November 2026

**VERIFIED — read-only runtime report:** after the user ran the timed native procedure and questioned whether pause/resume worked, the manager's existing status report contains `Execution: paused (pause)` at `2026-11-03T04:35:48Z` followed by `Execution: running (resume)` at `2026-11-03T04:35:53Z`. Both records match the same currently active guest and launch session. Record only these state/timing tokens, without guest names, UUIDs, paths, process IDs or key identifiers. The helper reported the expected five-second pause/resume cycle; this is not an independent observation of a frozen guest display or of authentication cancellation. The agent read metadata only and sent no lifecycle command.

**DESIGN DECISION / TO PROVE:** in-memory Pause/Resume retains RAM and is separate from experimental suspend-to-disk/hibernation; it does not need a hibernation-enabled guest kernel. A paused guest display may retain its last frame. The manual snippet suppressed CLI replies, obscuring success as well as errors; show those replies in future runs and require `ok: true`, `state: paused` followed by `state: running`. Pending Touch ID cancellation, old-test failure and fresh-request recovery in this lifecycle cycle await explicit user confirmation. Other lifecycle/multi-VM tests remain **TO PROVE**.


**VERIFIED — scoped user clarification, 3 November 2026:** the user noticed the native Touch ID prompt cancel during the pause/resume test sequence, but could not confirm the other outcomes. Record observed prompt cancellation only, alongside the previously recorded helper pause/resume acknowledgements. The exact timing/cause of cancellation was not independently observed. **TO PROVE:** the old password-fallback-disabled guest test returned failure after resume without late authentication, and a fresh request subsequently succeeded. Do not mark the complete lifecycle cancellation/recovery test passed. No further pause/resume, guest action or authentication interaction was performed by the agent.


## User-confirmed pause cancellation and recovery — 3 November 2026

**VERIFIED — user report plus helper acknowledgements:** following the previously recorded five-second pause/resume cycle and observed native prompt cancellation, the user supplied both guest test outputs. The old `try-omarchy-touch-id-test` reported denial, no supplied guest password and authentication failure with password fallback disabled. A fresh invocation then reported successful sudo authentication without a guest password. Record the described manual pause/resume cancellation/recovery case as passed in the build 26 test sequence: the old request failed and a fresh request succeeded. This supersedes the immediately preceding unknown old-test/fresh-request outcomes. The agent did not operate the guest or observe exact native timing; no key, password or personal identifiers are recorded.

**TO PROVE:** Mac sleep/wake, shutdown/forced-stop/crash cancellation, rapid focus transitions/exact prompt counts, unavailable-biometry fallback, re-pairing and two-VM contention/key isolation remain pending. The passed manual case does not establish all lifecycle behavior or grant agent-driven native interaction.


**DESIGN DECISION — next native sleep/wake check, 3 November 2026:** after the user requested the sleep/wake test, prepare a focus-preserving manual `pmset sleepnow` timer with the running test guest and upstream password-fallback-disabled test. Source inspection confirms epoch revocation before host sleep and eligibility-gated renewal on wake; the local manual distinguishes host sleep from display sleep. The shell snippet passes syntax checking. Native sleep cancellation, old-request failure and fresh-request recovery remain **TO PROVE** until user observation. The agent did not sleep the Mac, operate a guest, control authentication/unlock UI or modify power settings. See [the manual procedure](docs/GuestTouchID.md#focus-preserving-mac-sleepwake-check).


## User-confirmed Mac sleep/wake cancellation and recovery — 3 November 2026

**VERIFIED — user report:** in the build 26 verification sequence, the user reported that the Mac slept and woke successfully, the old password-fallback-disabled guest test failed, and a fresh Touch ID test passed. Record this described manual host sleep/wake denial/recovery case as passed. The statement establishes these test outcomes; it does not independently measure prompt timing/count or every host sleep mode.

**VERIFIED — separate read-only helper evidence:** the manager's existing report for the same currently active guest and launch session contains `Execution: host-sleeping` at `2026-11-03T04:44:47Z` and `Execution: running` at `2026-11-03T04:45:04Z`. These are helper-reported execution transitions, not an independent measurement of hardware sleep duration. Only state/timing tokens are retained; guest names, UUIDs, paths, process IDs, credentials and key identifiers are excluded. The agent sent no sleep, wake, guest-control or authentication command and changed no power setting.

**TO PROVE:** shutdown/forced-stop/crash cancellation, rapid focus transitions and exact prompt counts, unavailable-biometry fallback, re-pairing and two-VM contention/key isolation remain pending. This user-confirmed case supersedes the prior pending sleep/wake result only for the described sequence and does not grant agent-driven native interaction.


**DESIGN DECISION — next native shutdown check, 3 November 2026:** after the user requested shutdown cancellation testing, prepare the existing CLI background `stop --wait --timeout 120` with the selected test guest and password-fallback-disabled guest authentication test. Require prompt cancellation and confirmed terminal exit; shutdown may close the guest terminal before its old test prints, so missing text is not a pass. After a user-initiated launch of the same VM, require fresh authentication without re-enrollment and no old prompt resurrection. Source wait/revocation paths and shell syntax are checked; actual shutdown/cancellation/restart recovery remain **TO PROVE**. No agent-driven lifecycle action or native interaction occurred. See [the manual procedure](docs/GuestTouchID.md#focus-preserving-graceful-shutdown-check).


## Shutdown exit confirmed; authentication outcome pending — 3 November 2026

**VERIFIED — user CLI output:** the user supplied the timed `stop --wait` reply reporting `ok: true`, `active: false` and `state: stopped`. Record only these state/result fields; exclude the supplied guest/request UUIDs, name, endpoint and other personal/profile identifiers.

**VERIFIED — separate read-only runtime report:** the latest shutdown sequence contains `Stopping` at `2026-11-03T04:48:21Z` and matching `Exited (0)` at `2026-11-03T04:48:22Z` for the same VM and old launch session. At inspection, that guest's current row was already active and running again. These reports support successful shutdown and matching terminal cleanup, rather than a wait timeout; they do not independently prove native prompt cancellation or post-restart guest authentication. No agent-driven stop/start or authentication action occurred.

**TO PROVE:** whether the pending native prompt cancelled during this shutdown, whether any old prompt resurfaced, and whether a fresh post-restart `try-omarchy-touch-id-test` passes without re-enrollment. Do not mark the complete shutdown cancellation/recovery case passed from the stopped JSON alone. Other crash/forced-stop and two-VM checks remain pending.


## User-confirmed shutdown cancellation and restart recovery — 3 November 2026

**VERIFIED — user report plus terminal-exit evidence:** the user confirmed that the pending Touch ID prompt cancelled during shutdown and that a fresh `try-omarchy-touch-id-test` passed after restarting the same guest without re-enrollment. Together with the supplied `stop --wait` reply (`ok: true`, stopped, inactive) and matching old-session `Exited (0)` report recorded above, mark this described manual shutdown cancellation/restart recovery case passed in the build 26 sequence. This confirmation supersedes the preceding pending prompt/fresh-test outcomes. The agent did not stop/start the guest, operate native authentication, read keys/credentials or independently observe prompt timing. No personal/key identifiers are retained.

**TO PROVE:** forced-stop/crash cancellation and extended late-prompt/replay scenarios, exact prompt counts/rapid focus transitions, unavailable-biometry fallback, re-pairing and two-VM contention/key isolation remain pending native observation. The passed single-guest shutdown case does not establish every lifecycle failure path or authorize agent-driven VM, factory, storage or UI operations.


**DESIGN DECISION — two-VM guided test preparation, 3 November 2026:** following the request to continue, prepare two fresh disposable 4 GiB/4 CPU/64 GiB sparse official-factory profiles with guest Touch ID enabled, NAT, no shared folder/clipboard or personal SSH-key inheritance, and user-approved saved setup defaults. Read-only host and current-allocation checks show capacity; creation/launch/pairing remain user-driven steps and were not executed by the agent. Shell syntax and CLI/source contracts are reviewed. First establish A paired and B initially unpaired; distinguish focus rejection from native lease contention, and independent guest IDs from the stronger cloned-ID isolation case. See [the concrete setup and scope](docs/GuestTouchID.md#two-vm-manual-setup-and-observation-scope). Native multi-VM results remain **TO PROVE**. No existing guest, registry, factory, disk, key, credential, permission or UI was modified during preparation.


## User-confirmed independent two-guest enrollment — 3 November 2026

**VERIFIED — user reports:** the user completed A's enrollment/test, then reported B's password-fallback-disabled test failed without a Mac prompt while B was unpaired. After explicit enrollment of B, the user confirmed B's built-in test passed and A's subsequent fresh test still passed. Record independent guest enrollment and no observed interference from B's enrollment with A. The unpaired failure alone is not proof of host UUID-key isolation: the fresh guests have distinct guest IDs and their PAM setup differs before enrollment.

**VERIFIED — read-only manager report:** both proposed disposable test profiles are active/running, with distinct UUIDs and distinct storage roots. Only these booleans and anonymized A/B labels are retained; no profile/root/process/key identifiers or credentials are recorded. The agent did not create, boot, enroll, alter or control either guest.

**TO PROVE:** overlapping focus routing, actual native `lease-busy` contention, cross-guest disable/re-enrollment effects and cloned-identical-guest-ID isolation remain untested. Existing synthetic cross-process lease and cloned-ID namespace fixtures remain separate evidence.


## User-confirmed two-guest routing and disable independence — 3 November 2026

**VERIFIED — user reports:** after independently enrolling A and B, the user confirmed the overlapping procedure's three outcomes: A's pending test passed, B's delayed request failed, and a fresh focused B request passed. The user then confirmed B's disable operation reported enrollment removed from the guest and Mac (not local-only cleanup), B's password-fallback-disabled test failed without a Mac prompt, and A still passed afterward. Record these described manual two-guest routing and disable-independence cases as passed for build 26. No exact prompt count or native diagnostic code was supplied; do not promote the background failure into proof of the `lease-busy` branch.

**VERIFIED — read-only cleanup preflight:** both disposable profiles remain running. The actual running manager's bundle metadata confirms 0.11.0 (26), `v0.11.0-dev.2`. A read-only probe built from the pinned `KernelProcessIdentity` implementation captured eight current processes for each guest, including its QEMU executable and distinct owning `--run-vm` helper. Each association is bound to the exact open disposable disk and validated manager UUID root. PID, executable and kernel birth (seconds/microseconds), session and root inode/device identities are held only in a private ignored cleanup ledger; none are published. No key/credential or disk contents were read, and no guest/UI/lifecycle operation was performed by the agent. Early static-executable assumptions did not identify the QEMU wrapper; the successful capture handles upstream naming variants and verifies exact disk ownership and helper ancestry rather than guessing a PID.

**TO PROVE / cleanup pending:** native identical-guest-ID isolation under a new manager UUID, actual `lease-busy` contention, exact prompt counts/rapid focus transitions, unavailable-biometry fallback, re-pairing and forced-stop/crash paths remain separate from these results. The existing synthetic cloned-ID and cross-process lease fixtures remain verified evidence, not native proof. The next action is user-driven shutdown of A and B, then read-only matching-exit/process verification and an offer to move the verified stopped UUID roots to Trash. No existing guest or storage is included, and no deletion is authorized by recording the test results.


## Two-VM test guests stopped and verified — 3 November 2026

**VERIFIED — user report and read-only cleanup audit:** the user reported both disposable guests stopped. Their captured launch sessions have matching `Exited (0)` records: A at `2026-11-03T05:14:42Z`, B at `2026-11-03T05:14:43Z`. Both profiles are stopped/inactive with no current session. Exact PID/executable/kernel-birth comparisons show all eight captured processes per guest have exited (16 total), including QEMU and each owning run helper. A narrow open-file audit of the two exact disks finds no remaining runtime or other open-disk processes. Both private manager UUID roots retain their captured device/inode identities, ownership and safe root type; no protected suspended-session marker exists.

**DESIGN DECISION — optional Trash cleanup:** offer moving only A/B through the manager's normal confirmed deletion workflow, which rechecks stopped admission and storage identity and uses the runtime-compatible lock before Trash. The user has not yet selected Trash versus retaining the stopped profiles. No profile/root was deleted or moved, no other guest was controlled, and no macOS permission was granted by the agent. Private operational identities remain in the ignored cleanup ledger; public evidence contains only anonymized labels, state/timing and counts. This completes shutdown/process cleanup of the manual run independently of the optional storage choice.

**TO PROVE:** native cloned-identical-guest-ID UUID isolation, actual `lease-busy` contention, exact prompt counts/rapid focus transitions, unavailable-biometry fallback, re-pairing and forced-stop/crash cases remain separate pending gates. Do not promote the successfully completed manual cases into a claim that every native branch has been observed.


## Approved disposable-guest Trash cleanup completed — 3 November 2026

**USER AUTHORIZATION / VERIFIED:** after matching successful exits, no remaining captured/runtime disk processes and unchanged stopped UUID roots were verified, the user explicitly selected moving only disposable A and B to Trash. Recheck stopped manager admission and captured root inode/device identity before each single-root operation, then invoke the installed manager's normal guarded deletion by the captured UUID. The manager's existing workflow performs its stopped/protected-state/identity/tree checks and runtime-compatible locking; no direct recursive erase is used.

**VERIFIED — post-operation checks:** both manager operations succeed, both registry profiles are absent and both original VM paths are absent. Each default-name Trash destination is independently present with the exact captured directory inode/device identity, confirming recoverable moves. A final kernel-identity check still finds none of the 16 captured runtime processes alive. Only the two approved test UUIDs were targeted; no other guest, factory, saved default, native permission or UI was changed by the agent. No guest key/credential or disk contents were read. Private operational receipts and process identities remain ignored, with no identifiers published.

**Completed scope / TO PROVE:** this closes shutdown/process/storage cleanup of the guided build 26 validation run. The user-confirmed enrollment, password fallback, focus recovery, manual pause, Mac sleep/wake, shutdown/restart, two-guest routing and cross-guest disable cases retain their exact recorded scope. Native cloned-identical-guest-ID isolation, actual `lease-busy` contention, precise prompt counts/rapid transitions, unavailable-biometry fallback, re-pairing and forced-stop/crash scenarios are not implied by these results and remain pending unless separately scoped. No additional native run or copied disk was started.


## Guest Touch ID integration decision — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** after the tested single-guest/two-guest cases and verified Trash cleanup, the user elected to proceed to integration of the current sudo milestone. Preserve the remaining native cases as explicit **TO PROVE** follow-ups, without adding more native runs or claiming those paths passed. Final review and no-VM PR checks remain integration gates. Default-off configuration, explicit guest pairing, UUID/run/process/focus/epoch controls, exact provenance admission, terminal-exit resource retention and the disabled 1Password milestone are unchanged. No new signing/notarization, release tag, VM operation, permission or credential access is part of integration. The refreshed `origin/main` is an ancestor of this branch, and review found no integration blocker in the final manager/runtime/release-tooling diff. See [current evidence and retained limits](docs/GuestTouchID.md#integration-status).


## Integrated sudo milestone release preparation — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** after merging PR #3, the user requested tagging and signing a release. Prepare the next supported signed development prerelease, `v0.11.0-dev.3`, manager 0.11.0 (27), from integrated main `653f1336be01f1fc86f2edcd6615358e701e8bd9`. Its main CI run 41584792689 passed. This release changes the build identity and records the integrated validation; application/runtime logic stays as tested in build 26. Use only the existing tag-driven CI signing/notarization path, retain all acceptance/archive, signature/profile/team/entitlement, stapling/Gatekeeper and extracted-ZIP gates, and preserve every existing tag/asset.

**DESIGN DECISION — exact signed-runtime reuse:** retain active/versioned dev.2 runtime provenance unchanged and reuse exact signed runtime `4f62b8e9494e2192895d815b7861c197a56c706205b97d6e77054406b7c5f96d`, source `37c635f8992a9e19cc99696542bf061baff804c0`, source-lock `328acd039129cd6d5dae139cd1f426e18c50cfeaf91268e63541b6186686fd9d`. No runtime rebuild/re-signing/submission is required. CI signs and submits the new app archive. Native known limits remain **TO PROVE** as documented; default-off guest authentication and disabled managed 1Password are unchanged. No local real identity, credential access, installation, permission or VM/storage operation is part of this release request.

**TO PROVE:** this tag's CI signing, app acceptance and publication; the previously recorded native follow-ups remain separate. Do not claim an unpublished candidate is a completed release.


**VERIFIED — integrated signed release published, 3 November 2026:** user-requested `v0.11.0-dev.3`, 0.11.0 (27), source `a0dc1814e1ebee71a20215510451f944467ffdb2`, was published by run 41598411099. All no-VM gates, app signing/notarization and independent downloaded ZIP/profile/signature/Gatekeeper/original-archive checks pass. The exact signed runtime and its active/versioned pins are reused from dev.2, without runtime re-signing/submission. Full receipts and accepted originals are retained; exact hashes and Apple IDs are in [the release evidence](docs/Prereleases.md#published-integrated-sudo-release--3-november-2026). Application/runtime logic is unchanged from the user-validated build 26, and remaining native cases retain their **TO PROVE** status. No installation, local signing identity/credential, native UI/permission or VM/storage operation occurred.


## Developer provisioning dependency checks — 2 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** implement milestone 1 of [the dev-vm plan](docs/DevVMProvisioningPlan.md) in its worktree: Homebrew dependency checks and feature gates, with no host tool installations or VM launches. Bundle the dev-vm engine in a later milestone and use compatible existing host dependencies initially; private bundled Python/Ansible runtimes remain a future packaging option. Keep VM implementation in Try Omarchy and lifecycle ownership in VMManager. A future live terminal is scoped to approved provisioning jobs, rather than a general SSH client; milestone 1 adds no terminal or guest execution.

The host-controller/runtime packaging choice in this initial decision is superseded by the shared Swift design below. The original milestone 1 implementation and its verification remain unchanged.

**DESIGN DECISION:** expose a native Provisioning tools page and local `omarchy-vm setup tools` report without opening the manager from the CLI. Reports distinguish tool prerequisites from implemented features; all execution gates remain disabled. Probe explicit executables with bounded output/time and a private temporary environment. Do not run install/upgrade commands, read credentials, check GitHub authentication, contact guests, query Docker or invoke Apple's potentially interactive Python launcher. See [dependency policy and checks](docs/ProvisioningTools.md).

**PRIVATE COUPLING:** host Ansible launcher resolution recognizes direct Python shebangs and the exact `/usr/bin/env python3` form. Preserve virtualenv entry paths, verify the selected interpreter's imports and matching CLI/package versions, and reject other wrappers. This adapter is separate from existing runtime/settings couplings and grants no upstream kit capability.

**VERIFIED — milestone 1 no-VM validation:** `make test build` passes 224 Swift tests/37 suites and 43 script tests, including 18 focused provisioning tests. Direct CLI checks preserve JSON/help/version behavior, reject an installation flag and leave execution disabled. Minimal-PATH read-only discovery admits the existing Homebrew 7.0.11/Python 3.14.9/PyYAML 6.0.3/Ansible Core 2.21.5 toolchain; GitHub authentication remains unverified. Probe locale is explicitly UTF-8. No host software was installed/upgraded, credential accessed, app installed/opened or guest contacted. Exact checks and limitations are in [ProvisioningTools.md](docs/ProvisioningTools.md).

**TO PROVE:** other supported Homebrew environments, native UI interaction and packaged behavior; engine integration, PTY authorization/echo, persistent sudo-grant cleanup, interrupted remote work, real guest compatibility, focus, sleep/wake, crashes and concurrent provisioning. Synthetic tool probes do not establish those behaviors or change prior real-VM evidence.

## Shared Swift provisioning design — 2 November 2026

**USER AUTHORIZATION / DESIGN DECISION — documentation only:** revise the plan to use one shared Swift provisioning package maintained with dev-vm and consumed by both the manager/helper and standalone dev-vm CLI. Port the host controller, strict manifest/feature resolution, planning, source snapshots and application coordination to the package. Bundle compiled Swift code and versioned playbooks/roles/catalogues/guest helpers. Invoke Homebrew's Ansible launchers; their Python dependencies stay Homebrew-managed. The manager will have no independently selected Python/PyYAML runtime requirement. Guest Python helpers and existing Python-based development/image-build tooling are separate and may remain. Do not start the port or change milestone 1 code in this documentation task.

**DESIGN DECISION — planned milestone 1A:** retain the dependency provider, GUI-safe discovery, bounded isolated probes, UTF-8 environment, change detection and native/CLI reports. Replace independent Python/PyYAML requirements, imports, Python overrides and shebang matching with coherent Homebrew Ansible CLI version/usability checks using fixed local fixtures without guest execution. Plan dependency-report schema 2 with explicit migration from schema 1; preserve existing guest-command protocol 1. JSON/YAML planning will use compiled Swift parsers without an external Python or Ansible requirement once that package is integrated. Keep unimplemented execution disabled and preserve all original milestone 1 validation evidence. Details are in [the revised plan](docs/DevVMProvisioningPlan.md#changes-to-milestone-1).

**PRIVATE COUPLING / TO PROVE:** the current Python-shebang adapter remains implemented until an authorized milestone 1A change retires it. Its replacement will isolate Homebrew installation identity and Ansible CLI interpretation behind contract-tested adapters. Swift package/API/resource layout, strict YAML/JSON/TOML and Python-controller parity, standalone compatibility, revised CLI probes, native terminal behavior and real guest/crash/sleep behavior remain unverified. Saving this revision changes no source code, installed app, dependency or guest.

## Homebrew Ansible CLI dependency contract — 2 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** implement milestone 1A only in this worktree, with no host tool installations, VM launches or shared Swift package port. Dependency reports now use schema 2: remove standalone Python/PyYAML rows, imports, interpreter selection and shebang parsing; reject retired overrides with migration guidance; retain existing guest-command protocol 1. Local JSON/YAML planning has no external tool blockers, but the package/parsers and every execution capability remain unimplemented and disabled. System transports, Homebrew discovery, isolated bounded probes, optional-tool deferral and ordinary VM lifecycle ownership retain their prior boundaries.

**PRIVATE COUPLING — implemented:** validate the active installation returned by `brew --prefix --installed ansible`, its directory identity and expected command targets, identical stable Core 2.21.x versions, a fixed static INI inventory listing and a fixed playbook syntax check. Do not run tasks, gather facts, evaluate user manifests, connect to a guest or select Ansible's internal Python. Support installation-provided wrappers and reject foreign/mismatched targets. Replacing Homebrew, either command or its active directory invalidates pair readiness. stdout/stderr have separate streams with a combined 32 KiB limit, five-second timeout and private process-group cleanup. Parse OpenSSH's stderr version explicitly; never log raw diagnostics. The inventory contract accepts only the fixed synthetic host and its optional empty `ansible_local` namespace.

**VERIFIED — no-VM acceptance:** `make test build` passes 224 Swift tests/37 suites and 43 script tests, including 18 focused provisioning tests. A minimal-PATH existing-host report admits Homebrew 7.0.11 and both Core 2.21.5 commands after fixed local self-checks, emits schema 2 without Python/PyYAML/interpreter rows, preserves help/version and guest-command protocol 1, rejects retired overrides and an installation flag, and leaves execution disabled. GitHub authentication is unverified. No tool installation/upgrade, real signing identity, credential access, app installation/opening, guest contact or VM operation occurred. See [exact checks and limits](docs/ProvisioningTools.md).

**TO PROVE:** other Homebrew installations/Core versions, native UI interaction and signed packaged admission; the shared Swift package, parsers and controller port; actual setup, PTY authentication, authorization cleanup and real guest/focus/crash/sleep behavior. Earlier milestone 1 and shared-design sections preserve historical decisions and evidence; this section supersedes only their pending dependency-contract implementation status.

**USER AUTHORIZATION / CONFIRMED — isolated UI review:** the user requested the UI, accepted its appearance and asked to stop the preview and proceed. A temporary ad-hoc native app used the unchanged provisioning view and current core, with live dependency checks and no manager/registry/runtime initialization or VM controls. It was closed on request. The installed manager and guests were untouched. This establishes the isolated visual review only; full manager interaction and packaged behavior remain TO PROVE. The shared Swift package port remains deferred under the earlier explicit instruction.

## Shared Swift provisioning foundation — 2 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** start milestone 2 with shared Swift package structure and strict manifest parsing, with no host tool installation or VM launch. This supersedes the earlier instruction to defer the port for this scope only. Keep the package in dev-vm on its isolated `codex/swift-provisioning-package` branch; the manager's dependency pin and helper integration remain pending. No manager execution gate changes.

**DESIGN DECISION:** expose `DevVMProvisioningCore` and a validation-only `dev-vm` executable, targeting Swift 6/macOS 15+. Swift validates bounded plain data and typed setup declarations. Compile the pinned CYaml/LibYAML parser subset from Yams 6.2.2 through an event bridge, rejecting aliases/anchors/tags/version-tag directives before composition. JSON uses a bounded separate grammar and Foundation string decoding. Bundle schema/catalogue and license notices with exact revision/hash inventory checks. There is no new host Python or YAML-library runtime dependency. Keep custom task YAML opaque; source references and factory selectors are declarations only. Exact scalar differences, source revisions and the committed dev-vm foundation (`e86550e`) handoff are recorded in [the implementation plan](docs/DevVMProvisioningPlan.md#milestone-2-foundation-handoff--2-november-2026).

**VERIFIED — local no-VM foundation:** make-based package build, 12 Swift test functions (including 94 parameterized cases), 18 unchanged-Python-loader oracle fixtures, and Swift tests/CLI with Python and Ansible absent from PATH pass. The existing dev-vm suite passes 235 tests with one Lua fixture skipped because Lua is absent, using the installed Homebrew Python and local socket access; both unchanged playbooks pass syntax checking. System Python 3.9/TOML and sandboxed Ansible local RPC failures were environmental and are recorded, not hidden. No host tool installation/upgrade, image download, credential access, app opening/install or existing-VM operation occurred.

**TO PROVE:** complete feature/profile/catalogue resolution, TOML/effective option semantics, source freezing, plan parity, full guest resources, immutable manager packaging/integration, operational CLI compatibility, read-only relocation, transport/authorization, jobs and live terminal. All manager setup features remain unimplemented/disabled. Foundation parser fixtures establish no VM or real-guest acceptance and change no existing runtime provenance or lifecycle policy.


## Shared Swift offline planning — 2 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** continue milestone 2 with feature/profile resolution, source snapshots and offline proposals against the Python oracle, without host tool installations or VM launches. Extend the existing dev-vm companion worktree; manager production dependencies and execution gates stay unchanged. The dev-vm continuation is committed at `56dba82368d13287b01e28a459a69b42da8620a1`.

**DESIGN DECISION / IMPLEMENTED:** port inheritance/conflict/override/tombstone behavior, dependency ordering, native package/mise requirements and predicted effects to the shared library. Preserve catalogue declaration order in JSON/YAML. Pin Swift-native TOMLDecoder with bounded TOML 1.0 compatibility checks. Freeze only selected inputs through no-follow descriptor-relative reads into an immutable in-memory snapshot, bound files/bytes/directories/depth, expand dotfiles and capture custom task YAML as opaque bytes. Bind proposals to source/resource/dependency inventories and input/plan digests; revalidation detects selected edits, additions/removals, permissions and root replacement. Existing Python controllers remain operational; Swift adds an offline `plan` command. Variable values and file/task contents are excluded from serialized proposals. Factory selectors remain declarations requiring manager admission; no new VM implementation or lifecycle owner is introduced.

**VERIFIED — no-VM checks:** build, 20 Swift test functions, 18 plain-data fixtures and 66 complete proposal/error cases (41 accepted/25 rejected) pass against the unchanged Python oracle. Oracle Python planning forbids subprocesses/manager access/interpreter fallback; native children use an empty tool PATH. All 20 Swift tests also pass with an empty tool PATH. An isolated CLI copy rejects a damaged bundled catalogue with a fixed error. Existing dev-vm regression tests pass 235 tests with the missing-Lua fixture skipped, and both unchanged playbooks pass syntax checking. Development-only Python is already installed; none is invoked by the compiled Swift planner. No host install/upgrade, credential access, app opening/install, guest contact or VM operation occurred. Exact pins, snapshot limits, compatibility changes and remaining evidence boundaries are in [the continuation handoff](docs/DevVMProvisioningPlan.md#milestone-2-offline-planning-continuation--2-november-2026).

**TO PROVE:** full parser/TOML parity beyond the fixture matrix, adversarial-writer filesystem transactions (not claimed), job snapshot materialization, full resource packaging, immutable manager integration, signed provenance/relocation, operational CLI cutover, transport/authorization, jobs/live terminal and real-guest behavior. In-memory snapshots and offline proposals grant no execution authorization. Earlier runtime provenance, guest/lifecycle rules and all disabled feature gates are preserved.


## Shared Swift transport and authorization contracts — 2 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** continue milestone 2 using fake guest adapters only, with no host tool installs or VM launches. Implement shared typed adapter contracts, native guest command descriptions and authorization/cleanup sequencing in dev-vm; no real transport or production manager execution path is added. This dev-vm continuation is committed at `f807104850dfd06527bcbee4ba5f0aca5a1404f4`.

**DESIGN DECISION / IMPLEMENTED:** bind explicit review to frozen source/engine, job, VM/runtime session, non-root owner/UID, host key, dependencies, mode/tasks/check policy, conflict policy and input lease. Require separate task/persistent-grant/Docker acknowledgements. A single-use actor validates every operation and correlated reply, arms cleanup before staging/grants, and separates primary failures from cleanup uncertainty. Cancellation interrupts only the matching command and retains the outstanding adapter call; cleanup survives caller cancellation. Require remote-work quiescence and compound native grant/cache revocation proof before reporting cleanup or restart readiness. Return restart-required metadata only; VMManager retains lifecycle ownership. Check mode never changes grants/cache, installs manifest packages or opts into Docker; custom tasks require explicit check selection and trust.

**PRIVATE COUPLING:** native guest command contract version 1 follows the inspected Python controller at `56dba82`, including stale-grant reset, interactive native persistent grant, cache invalidation, inactive-policy verification and native Docker consent/owner verification after revoke. The shared code describes fixed guest argv only and executes none. Reports/events carry fixed codes and job/command/VM/session IDs, exclude credentials/bindings/terminal bytes/raw errors, and use redacted descriptions for sensitive request/transport/recovery objects. Cleanup tickets are in-memory and pinned to the original target/dependencies/payload; recovery grants nothing and performs no setup or lifecycle work. Persistent recovery and explicit post-restart rebinding remain deferred. Attempt completion is not a VM `.exited` event and releases no runtime ownership/reservations.

**VERIFIED — fake-only tests:** build and 38 Swift test functions pass (18 new sequencing/native-contract functions), including partial grants, uncertain staging/cleanup, cancellation and reentrant-driver rejection, check/trust/input rules, 10 reply/pin mismatch cases, source invalidation, post-revoke checks, recovery without original sources and sanitized results. All 38 pass with an empty tool PATH. The 18 parser and 66 planning oracle cases remain passing; seven targeted existing Python tests run with mocked guest, Ansible and lifecycle calls. No actual SSH/Ansible command, host install/probe, credential access, UI action or VM operation occurred. The earlier full legacy suite was not rerun because this slice uses fake guest adapters only; prior evidence remains historical.

**TO PROVE:** actual identity/receipt authenticity, native commands and password echo/quoting, adapter deadlines and local/remote process cancellation/quiescence, concrete transports/payload staging, private persistent recovery/session rebinding, CLI/helper/UI integration, signed/pinned packaging, live terminal and real guests. Deadlines are an adapter contract, not proven wall-clock termination. Existing VM policy and manager execution gates remain unchanged. See [the transport/auth handoff](docs/DevVMProvisioningPlan.md#milestone-2-transportauthorization-slice--2-november-2026).


## Shared Swift concrete transport adapters — 2 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** implement the next milestone-2 slice
in the dev-vm companion worktree: concrete SSH/Ansible adapters, fake process
runners only, no host installations or VM launches. Manager changes are docs only;
all execution gates, lifecycle ownership, pinned-kit and personal-VM rules remain.
The dev-vm adapter slice is committed as
`9ebaf178de48e6480e248f8b20eae1f35c0d16b6` on
`codex/swift-provisioning-package` (3 November 2026).

**DESIGN DECISION / IMPLEMENTED:** pinned loopback SSH and Ansible command
construction, private immutable job materialization and bundled maintained guest
resources sit behind an injected runner and manager-owned session authority.
Revalidate dependencies/credential metadata/session before each process; never
read key contents. Preserve Ansible launcher entry paths while hashing resolved
targets. Interactive native authorization/Docker/package commands request an input
lease and terminal stream; Ansible requests live output with closed stdin. Track
cancellation between processes and require exact local exit before cleanup.
No live process runner, PTY, UI terminal or operational Swift command is shipped.

**PRIVATE COUPLING:** a guest-only Python helper binds one exclusive UUID payload
lease to recorded systemd user scopes and an Ansible shell wrapper. Preparation
requires Linux/aarch64/non-root Python 3, cgroup v2, a user manager/bus and scoped
execution with `--expand-environment=no`, before sudo grant. Quiescence seals new
body work and requires known scopes inactive/empty; uncertain registration blocks
proof/removal. Only the verified guest job temp root may be removed. This is not
a sandbox for trusted task code or independent services. Uncertain startup can
require manual recovery. The helper adds no host Python runtime or VM lifecycle
implementation; Homebrew continues to supply Ansible's dependencies.

**VERIFIED — fake-process checks:** make build and 50 Swift test functions,
including 12 new transport functions, pass; all 50 pass with an empty tool PATH.
The 18 parser/66 planning oracle fixtures and seven mocked Python sequencing tests
pass. New Python files compile and 21 bundled YAML files parse statically. No
real SSH/SCP/SFTP/Ansible executable, credential contents, host install, app/UI or
VM operation is used. Full legacy/Ansible syntax execution was not repeated for
this fake-process-only slice. Prior real-VM evidence remains unchanged.

**TO PROVE:** real authentication/SSH quoting, Ansible/native package parity,
guest systemd/cgroup registration and privileged descendants, hard deadlines,
local/remote cancellation/quiescence, PTY/password echo/live output, persistent
recovery/session rebinding, operational CLI and manager/helper integration, signed
packaging and real-guest acceptance. See [the concrete adapter handoff](docs/DevVMProvisioningPlan.md#milestone-2-concrete-command-adapters--2-november-2026).


## Shared Swift local process runner and PTY — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** continue milestone 2 with a local
process runner and PTYs, tested solely using disposable local fixtures. No real
SSH/Ansible, host installs or VM launches. Manager changes are docs only; no
production dependency, setup feature gate or lifecycle policy changes.
The dev-vm continuation is committed as `bb3fae22be45b38035fac52aefa0eb270a9d0fea` on
`codex/swift-provisioning-package` (3 November 2026).

**DESIGN DECISION / IMPLEMENTED:** exact argv/environment/cwd, bounded separate
capture or raw terminal streams, closed/bounded stdin, new local sessions and
matching-ID cancellation/deadlines. Retain a waitable leader until the owned
group is inactive and output EOF, then reap; uncertain cleanup retains ownership
and blocks new runners for that VM/session. Explicit reconciliation and a retained
local reaper never relaunch or signal a reused PID. This is in-memory ownership,
not persistent recovery or a sandbox for deliberately detached code.

A small Darwin C syscall bridge and pinned `dev-vm-process-host` exec launcher
supply controlling PTY semantics without fork in the Swift runtime. Future helper
packaging must admit/distribute that binary. No new Homebrew/Python runtime is
required. Terminal bytes remain bounded, sequenced, memory-only and separate from
structured events; slow readers get explicit gaps. One reviewed input lease
controls bounded input/resize; local PTYs are raw/no-echo, and revocation drops
pending input without cancelling the job. No renderer, IPC attach or automatic
secret redaction is supplied.

**VERIFIED — local fixtures:** make build and 64 Swift test functions pass (14
new local-runner functions), including controlling/foreground terminal, sizing,
synthetic input without echo, overflow, cancellation/TERM-resistant children,
exact capture, descriptor isolation, stale admission and uncertain-pipe cleanup.
All 64 also pass with an empty tool PATH; 18 parser and 66 planning oracle cases
remain passing. PTY `/dev/tty` access required execution outside the workspace
filesystem sandbox; restricted failures are recorded in the handoff. Tests use
private UUID roots with copied compiled binaries and confirm no live fixture
children; launchd reaps orphan zombies. No real SSH/SCP/SFTP/Ansible command,
credential, host installation, UI or VM operation occurs.

**TO PROVE:** actual remote SSH/Ansible/guest authorization and echo/quiescence,
deliberately detached code and kernel stalls, foreign reapers, cross-process/crash
recovery, launcher signature/relocation/admission, terminal renderer/escape policy,
IPC/viewer resynchronization and operational CLI/manager integration. Local process
exit is not guest quiescence or VM exit and releases no runtime resources. See
[the local runner handoff](docs/DevVMProvisioningPlan.md#milestone-2-local-runner-and-pty--3-november-2026).


## Pinned provisioning manager/helper integration — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** integrate the pinned shared package and
resources into manager/helper builds, tested with local fixtures only. No real
SSH/Ansible, installs or VM launches. Add offline admission/planning only; no setup
execution gate, job coordinator, lifecycle policy or installed app changes.

**IMPLEMENTED:** an unchanged 79-file source export at dev-vm `bb3fae22be45b38035fac52aefa0eb270a9d0fea`
is bound by a source/resource lock and generated compiled pin. Root SwiftPM links
the library into core/helper and exactly resolves TOMLDecoder. Builds verify
source drift and refuse optional parser plugins. The pinned C launcher is built
unchanged through a separate generated SwiftPM package. App assembly/signature/
layout checks now include the provisioning resources/licenses, offline helper,
launcher, source lock and final signed-child hash manifest. Bundle diagnostics
include source revision and disabled execution. No runtime-kit source is changed.

**PRIVATE COUPLING:** bounded embedded package admission supports the two known
SwiftPM layouts, refuses overrides/links/special files/extra or damaged resources
and changed child binaries, and repeats verification after offline work. The
helper accepts verify-package/validate-manifest/plan only, returns fixed errors
for execution, and never initializes registry/credentials/socket/tool probes or a
runner. Plans stay nonexecutable. Integrity manifests do not establish signing
authority; the app signature pipeline supplies that distinct check.

**VERIFIED — local checks:** build, 227 Swift tests/38 suites, 48 script tests
and actual offline helper relocation fixtures pass. A private ad-hoc sealed
fixture app, with no runtime kit, validates/plans read-only with empty tool PATH
and private empty HOME/TMPDIR; it rejects execution, resource overrides and
resource/launcher damage, and does not serialize synthetic variable values.
Strict deep signature checks pass before resource damage and reject it afterward.
The fixture manager executable is sealed but never opened/executed. No real SSH/
SCP/SFTP/Ansible, Keychain item, permission prompt, host install, UI action, image
download, installed-app change or guest operation occurs. Sandbox socket/context
failures and the initial unavailable-network update are recorded in the handoff;
full fixture regression passes outside that restriction using existing exact
source objects and private caches. The separate dev-vm code remains unchanged.

**TO PROVE:** complete runtime-kit app assembly/release signature/notarization,
other-Mac relocation, coordinator/journal/session adapters and helper IPC, terminal
UI/attach, operational CLI, persistent recovery and real guest/SSH/Ansible/echo/
quiescence behavior. Package fixture success changes no VM `.exited` ownership,
kit provenance or earlier real-guest evidence. See [the integration handoff](docs/DevVMProvisioningPlan.md#milestone-2-pinned-managerhelper-integration--3-november-2026).


## Provisioning coordinator and job journal foundation — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** start milestone 3 with coordinator and
private job-journal implementation, tested using fake runtimes/adapters and local
fixtures only. No real SSH/Ansible, installs or VM launches. Constructor/backend
injection stays internal, with no app/helper/CLI execution entry point, production
journal creation or enabled setup gate. Shared engine/resource pin remains
`bb3fae2`; the pinned sequencer still owns native guest authorization/cleanup.

**IMPLEMENTED:** one detached provisioning worker per coordinator/VMManager,
accepted-job/review deduplication, stale source/engine/session/dependency admission,
explicit cancellation and independent viewer lifetime. Journal state and command
correlation precede adapter calls. The explicit private 0700/0600 schema-1 store
uses exclusive file-description locking, atomic fsynced writes, directory/lock
identity and revision checks, bounded strict decoding and fixed result codes.
It stores digests/manager-owned IDs/status only, excluding credentials, source
paths/data, terminal bytes and helper PIDs. Bad/changed journals are preserved and
new work fails closed; write failures still permit original-target revocation.

**DESIGN DECISION / IMPLEMENTED:** VMManager leases protect active/unresolved jobs
from pause/suspend/edit/delete/start and defer ordinary shutdown for cleanup.
Confirmed force stop and unexpected session/execution/SSH changes retain cleanup
risk. Quit uses bounded cleanup attempts before normal shutdown, never releases a
VM handle before matching `.exited`, and preserves uncertain work on disk. Final
clean proof is sealed against later lifecycle races; diagnostic `.error` is not a
boundary. Restart-required is metadata only, without automatic lifecycle actions.

**PRIVATE COUPLING / LIMIT:** explicit same-process recovery uses the engine's
opaque live ticket and exact original pins, independent of sources/input. Reopen
never resumes apply or reconstructs ownership from a PID. The pinned package has
no persistent ticket API; durable frozen-input capsules, authenticated helper
recovery and explicit restart rebinding remain pending. Journal cleanup holds
cannot be cleared from a stopped observation alone. No source/credential copies
are persisted by this foundation.

**VERIFIED — local checks:** make build/test passes 248 Swift tests/40 suites
(21 new coordinator/journal functions), 48 script tests and existing relocated
package fixtures. Tests cover write-ahead/private storage, corrupt/replaced
journals, duplicate/stale admission, missing input, viewer detach, shutdown/force
stop, sleep/exit/SSH loss, cleanup deadline/late worker ownership, disk failure
with attempted revoke, live cleanup recovery without sources and conservative
reopen. New provisioning paths use no subprocess; existing socket/synthetic
LAContext fixtures run outside the workspace sandbox without Keychain calls or
authentication UI. No real SSH/SCP/SFTP/Ansible, host install, UI, image download,
installed app or VM operation occurs.

**TO PROVE:** real coordinator/helper IPC and ownership, durable inputs and
post-crash authenticated recovery, SSH-ready waiting/restart rebinding, UI/CLI and
terminal jobs, retention/migration, kernel/helper failures and actual hard cleanup
deadlines, and real guest/auth/echo/quiescence behavior. This is the milestone-3
foundation only. Existing VM lifecycle/provenance and real-guest evidence retain
their prior labels. See [the coordinator/journal handoff](docs/DevVMProvisioningPlan.md#milestone-3-coordinatorjournal-foundation--3-november-2026).


## Durable provisioning inputs and cleanup checkpoints — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** continue milestone 3 using fake runtimes
and local fixtures only. No real SSH/Ansible execution, host installs or VM launches.
Execution gates and offline-only helper entry points remain disabled.

**IMPLEMENTED:** new jobs preallocate a payload UUID and worker token, then fsync
private frozen inputs and a separate cleanup checkpoint before journaling the
running risk marker and delegating work. Schema-2 journal rows bind both artifact
hashes; schema-1 risk is preserved without inventing missing authority. Journal
size is 256 KiB to match the strict parser (superseding the earlier 1 MiB claim).
The 0700 artifact directory/0600 immutable files have exact hashes, link/mode/root
checks and a 256 MiB/512-file quota counting orphans. No automatic import, replay,
pruning or deletion occurs. Selected user configuration may be sensitive and is
kept out of reports/terminal/journal; private storage is not encryption.

The versioned bounded binary input archive retains selected bytes/modes/directory
membership and restores inert data only. It cannot reconstruct an executable plan,
resume apply or extract files into user paths. A cleanup checkpoint restores only
conservative original-scope cleanup risk. The engine retains its payload/control
helper while grant/cache inactivity is unproved.

Explicit persistent cleanup requires the exact original live VM/session/guest,
approved review, payload/worker, engine/dependency/binding/checkpoint pins, plus a
fresh challenge response proving the prior worker is stopped AND fenced from
launch. This authority is injected and fake-only in this slice; PID/disk metadata
is never sufficient. Session/dependency authority is rechecked after awaits and
before commands. Missing/corrupt input archives cannot suppress cleanup. Damaged
checkpoints without a genuine live ticket preserve uncertainty. Idle close/reopen
drops all tickets and releases the journal lock; active close is refused and VM
holds survive handoff. No body command, grant, prompt, restart or rebinding can be
issued by recovery; matching `.exited` still owns VM handle/resource release.

**PRIVATE COUPLING:** the manager consumes base `bb3fae2` plus the exact hashed
`Patches/dev-vm-durable-state.patch`, with base/result inventories and a resulting
source-snapshot digest. This supersedes the earlier unchanged-engine statement.
Source preparation verifies patch lineage locally and uses no mutable checkout;
license/parser/guest-resource and C launcher bytes remain unchanged.

**VERIFIED — fakes/local fixtures:** full `make test` passes 260 manager Swift
functions/40 suites, 49 script tests and relocated/read-only offline-helper checks.
Shared build/tests plus static oracles pass 68 Swift functions, 18 parser and 66
planning/error fixtures. Coverage includes fresh fenced worker proof, interrupted
markers, source/input removal, corrupted/cross-job/unsafe checkpoints, quota/orphan
preservation, legacy migration and no replay. A graceful-shutdown completion race
now cancels body work without misclassifying the still-valid guest or suppressing
cleanup. Existing socket/mock-context and local PTY fixtures need the sandbox
exception; no actual credentials/auth UI or real transport/VM operations occur.

**TO PROVE:** production helper IPC/fencing and coordinator construction, recovery
after full manager/VM restart, reviewed session rebinding, real helper absence/
crash and power-loss durability, retention/removal, SSH waits, live terminal/job
UI and CLI, and all real guest/transport/authentication behavior. These local
foundations do not promote any existing real-guest evidence labels. See the
[durable continuation](docs/DevVMProvisioningPlan.md#milestone-3-durable-inputs-and-cleanup-recovery--3-november-2026).


## Authenticated provisioning helper control and ownership — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** continue milestone 3 with authenticated
helper IPC/ownership reconciliation, using fake runtimes and local fixtures only.
No real SSH/Ansible, host installs or VM launches. The supplied Setup-tab screenshot
is the future stage-strip/live-terminal reference, not guest-validation evidence;
no UI takeover, permission grant or terminal rendering is performed.

**IMPLEMENTED:** an inherited same-user AF_UNIX control connection uses a private
per-launch capability delivered only through an anonymous bootstrap pipe. HMAC
frames bind direction, instance/binary/package pins, channel, sequence and exact
payload. Strict bounded messages reject unknown/duplicate fields, replay,
reflection, wrong keys/pins and uncorrelated request/challenge replies. Capability
bytes never enter argv/environment/disk/journal/status/logs. One request is allowed
in flight; timeouts/malformed replies poison the channel without automatic retry.
No listener/path discovery or stored-PID ownership inference is introduced.

The helper registry accepts worker bindings from its trusted local owner only;
wire requests cannot register or start anything. Missing/new helper state returns
unknown. A process-runner wrapper permanently fences the original worker before
waiting, owns each delegated task/ID and retains uncertain/mismatched process
receipts. Only matching local exit/not-started or exact retained local cleanup
can prove the local worker stopped and fenced. A stopped task/EOF/diagnostic never
proves guest quiescence, grant revocation or success. Disconnect fences local
workers and stops new registration. The coordinator can consume this authenticated
proof for its existing explicit cleanup-only recovery after reopen, with fresh
original-session/dependency checks. VM ownership still ends only at `.exited`.

**PRIVATE COUPLING:** helper control API 1 has only reconciliation, no shell,
apply, terminal/input, PID, arbitrary path or registration command. The packaged
helper's internal inherited-channel mode admits its distribution and bootstrap
pins, then serves an empty ownership registry without a runner/tool probe/journal/
Keychain/VM. It reports unknown; production job launch and worker registration are
not enabled. The shared package source/resource pin is unchanged. Authentication
is possession of a privately handed-off capability, not signing/notarization or
protection from a malicious same-user memory writer. Automatic production launch
must independently admit the child and preserve exclusive backend ownership.

**VERIFIED — fake/local checks:** full `make test` passes 275 Swift functions/41
suites (15 new IPC/coordinator functions), 49 script tests and expanded relocated
read-only package checks. Swift worker backends are all fake. The actual ad-hoc
sealed helper authenticates an inherited socket/pipe with empty PATH/private
HOME/TMPDIR; it reports unknown for missing ownership, rejects replay/wrong MAC/
bootstrap pins and leaks no secrets or host state. Existing strict signature/
tamper tests still pass. Full regression uses the existing local socket/mock-auth
sandbox exception, without real auth UI, tools/guests or host installs. Shared
package sources/pins remain unchanged and were not retested in this docs-only
companion handoff.

**TO PROVE:** production admitted launch/registration/executor wiring, operational
job IPC, full manager-process restart and reviewed session adoption, signing/
audit policy where needed, real helper/guest crash and remote cleanup, hard kernel
stall deadlines, live terminal streams/input leases and UI/CLI. This slice can
reconcile a surviving helper after coordinator reopen; an empty replacement helper
cannot prove lost ownership. Existing real-guest evidence labels remain unchanged.
See the [helper-control handoff](docs/DevVMProvisioningPlan.md#milestone-3-authenticated-helper-ipc-and-ownership--3-november-2026).


## Admitted provisioning helper launch and inert registration — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** continue milestone 3 using fake runtimes
and local fixtures only. No real SSH/Ansible, host installs, VM launches or UI
operations. Admit and register an inert helper worker only; engine/job dispatch,
transport activation and product setup entry points remain disabled.

**IMPLEMENTED:** an internal launcher verifies package/resource/binary pins,
strict outer/nested signatures, and the retained executable's identity. Default
admission requires non-ad-hoc matching app/helper Team IDs; only explicit internal
fixtures may choose ad-hoc/no-team admission. Before capability handoff, verify
the owned spawned child's dynamic code against the admitted cdhash requirement.
The PID is a transient lookup from this waitable child, never stored or used for
adoption/signaling/ownership proof. Spawn passes explicit cwd/private HOME/TMPDIR,
empty tool PATH, anonymous bootstrap stdin, null stdout/stderr and one inherited
control fd, with CLOEXEC-default exclusion of unrelated descriptors. Capabilities
remain volatile and never enter arguments/environment/disk/diagnostics.

Private bootstrap 2 reserves one metadata-only original worker and receives an
authenticated exact-digest receipt. Bootstrap 1 stays empty/unknown. Reserved
workers have no activation or engine API; fencing retires them permanently.
Unknown/partial registrations, receipts, owner substitution and duplicate launch
tickets fail closed. A helper instance is freshly minted per new job; a saved
owner cannot create a replacement helper claiming earlier work.

The coordinator freezes inputs and publishes schema-3 helper instance/executable/
package pins, registration digest and pending marker before spawn. It revalidates
review/package/source/session/dependencies before and after registration, then
marks the receipt accepted while keeping the job queued/no engine worker and a
conservative cleanup hold. Duplicate submissions cannot dispatch body work.
Schema 1/2 records preserve risk without invented helper authority; partial/unknown
owner fields and owner fields in legacy schemas are rejected. Existing private
file/lock/hash/size/quota/orphan rules remain. After owner publication, failures
retain its exact identity and cleanup-required status rather than quietly retrying.

Explicit cleanup after coordinator reopen requires the same retained authenticated
launch service, fresh original-owner proof and original guest/session checks.
Confirmed remote cleanup closes the exact helper channel; child handles/capabilities
remain owned until matching helper exit, independently of VM ownership. A lost
child wait retains uncertainty; there is no arbitrary PID kill or automatic
replacement. Control metadata roots are explicit/private, not VM storage. The
shared engine/resource pin and VM `.exited` lifecycle policy are unchanged.

**PRIVATE COUPLING:** schema 3, private bootstrap 2 and metadata-only receipt extend
the earlier authenticated control contract. A debug-only Swift fixture target
exercises the real factory against an ad-hoc sealed disposable app and is excluded
from app staging; its release entry point is disabled. No signing credentials or
real identity are used. The screenshot remains the terminal design reference.

**VERIFIED — fake/local checks:** `make test` passes 284 Swift functions/42 suites
(9 new registration/coordinator/journal functions), 49 script tests and expanded
read-only signed package fixtures. Fakes cover journal-before-spawn, changed
admission/session, failed/mismatched receipts, final-write failure, duplicate
submissions, persisted owner pins and original-service recovery after reopen.
The debug-only fixture runs the real factory with an explicit ad-hoc policy:
production policy rejects ad-hoc code; resource tamper and executable inode
replacement fail before admission; normal bootstrap/registration/reconciliation
passes and the matching child is reaped with no control-directory output.
Existing protocol/signature/tamper checks pass. Fixture lookup was corrected to
use either admitted SwiftPM resource layout. No real signing credentials,
authentication UI, host installs, guest transport or VM operation is used. Existing
local socket/mock-auth sandbox exceptions apply; shared code/pins are unchanged.

**TO PROVE:** product wiring and operational engine/backend dispatch, actual
release signer/Team policy, full manager restart/reconnect and reviewed VM/session
adoption, real helper/guest failures and grant cleanup, hard kernel stalls,
retention/removal, SSH waits and terminal/input/UI/CLI. Earlier real-guest evidence
keeps its labels. See [the admitted-launch handoff](docs/DevVMProvisioningPlan.md#milestone-3-admitted-helper-launch-and-worker-registration--3-november-2026).


## Helper-side shared-engine dispatch and activation — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** continue milestone 3 with helper-side
engine dispatch and worker activation, using fake runtimes and local fixtures only.
No real SSH/Ansible, installs or VM launches. Production backend/context factories,
app/CLI execution gates and terminal UI remain disabled.

**IMPLEMENTED:** a prepared worker consumes one immutable activation bound to its
original registration/owner/plan/input/review/engine/dependency/session scope.
Authenticated typed activate/status/cancel requests preserve MAC/request/sequence
correlation and contain no plan bytes, arbitrary paths, executable/credential or
terminal data. Activation's acknowledgements are ANDed with helper-local approval;
missing task/grant/Docker consent cannot be invented. Duplicate identical activation
returns status without another task; a changed activation or a prior fence cannot
reopen the worker. Preparation must run no guest/process operations.

The helper validates a local prepared context then invokes the pinned shared
sequencer with the original payload ID. Its owned task survives viewer/RPC detach.
Command bindings, package/body admission, session/dependency authority and a known
closed-channel body gate are checked around work. Cancellation/fencing stops body
work while permitting known-target sequencer cleanup. Completion retires/fences
its owned runner; local uncertainty overrides apparent guest success. Contexts,
owned local tasks and handles remain retained, and helper EOF is not an exit or
remote-cleanup proof. Status/results are bounded fixed types, not terminal/raw
errors or source values. No authorization/Ansible logic is duplicated.

Schema 4 journals activation UUID/digest and risk before the activation RPC. Manager
polling is detached from viewers and checks exact activation/correlation and
monotonic status. Lost replies, invalid status, disk failure and runtime/session/
dependency invalidation preserve cleanup-required without automatic replay. Old
schemas preserve risk without invented activation. Coordinator reopen records
interruption, not a restarted apply. Existing lifecycle interlocks, cancellation
grace and final proof sealing remain; matching VM `.exited` still releases guest
resources independently of helper-child exit.

**PRIVATE COUPLING:** control payloads extend frame 1/bootstrap 2 with activation
and sanitized results. The normal helper provides no engine context factory and
rejects execution. A separate ad-hoc-signed temporary fixture app uses the excluded
debug fixture binary as its helper, with a fixed synthetic manifest/fake backend;
no production argument/environment/RPC enables it. This preserves the admitted
image/capability/owner chain while testing actual helper-process dispatch. Shared
package sources/resources/pins are unchanged. There is no frozen-archive extraction
or arbitrary executable/source transfer added to the control channel.

**VERIFIED — fake/local checks:** `make test` passes 297 Swift functions/43 suites
(13 new engine/coordinator/journal functions), 49 script tests and expanded signed
package fixtures. Coverage includes one-shot apply/check, consent/context/source
refusal, fence/cancel/disconnect ordering, physical uncertainty, journal-before-RPC,
viewer detach, shutdown, lost/malformed replies, failed writes, no replay after
reopen, schema preservation and runtime/SSH/dependency invalidation. Diagnostics
alone are not lifecycle exit. The normal helper refuses activation without a
factory. A separately sealed/ad-hoc-signed temporary fixture helper runs the
actual sequencer with only synthetic adapters, reports clean completion and
cancellation/cleanup, and is reaped through the owned launcher. Existing protocol/
signature/tamper checks still pass. No real signing credentials, auth UI, host
installs, SSH/Ansible or VM operations occur; existing local socket/mock-auth
sandbox exceptions apply. Shared sources/pins are unchanged and not retested.

**TO PROVE:** production frozen-context/consent transfer, exclusive real backend
and manager-aware session authority, product wiring, full restart/reconnect and
reviewed rebinding, release signer acceptance, real guest/auth/echo/quiescence/
crash/kernel behavior, terminal/PTY/input/UI/CLI. The screenshot remains a reference;
no user UI or installed app is changed. Earlier real-guest evidence labels remain.
See the [helper dispatch handoff](docs/DevVMProvisioningPlan.md#milestone-3-helper-side-engine-dispatch-and-activation--3-november-2026).

## Frozen-input delivery and helper context validation — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** continue milestone 3 using fake runtimes
and disposable local fixtures only; no real SSH/Ansible, installs or VM launches.
This supersedes the pending frozen-context handoff in the preceding record.

**DESIGN DECISION / IMPLEMENTED:** persist a private immutable `DVMCNTX1` delivery
blob containing the existing selected archive and strict reviewed-request metadata.
Bind exact total/metadata/archive hashes and byte count into the authenticated
registration and schema-5 journal, before spawn. A retained read-only descriptor
checks private ownership, mode, single link, file/path identity and digest. Spawn
inherits an empty separate socket at fd 4; only after verifying package and owned
live-child code send bootstrap 3 and bounded chunks. No source path or content
enters arguments, environment, control/status/terminal frames or diagnostics.
Capabilities still exist only in memory/private pipes, never in these artifacts.

**DESIGN DECISION / IMPLEMENTED:** validate hashes, strict fields and original
job/guest/session/dependency/review bindings before materializing only into a fresh
private helper-owned UUID tree. Descriptor-relative no-follow/exclusive traversal,
file/directory/depth/byte bounds and fsync preserve selected binary bytes, modes
and empty directories. Independently replan inside that tree using the original
relative manifest; compare plan/input/engine and reconstructed review identities
before acknowledging registration. The archive remains inert data, never an
imported executable plan, cleanup proof or automatic apply/resume authority.
An injected backend receives the validated context; delivered, backend and explicit
activation consent combine by AND. Retain/recheck its private storage through work;
cleanup still uses the independently bound original checkpoint without source or
input availability. Product helper backend construction and execution gates stay
disabled. Only the excluded Debug fixture uses synthetic guest adapters.

**DESIGN DECISION:** original source verification remains required before job
publication/handoff. After a frozen registration is accepted, the selected private
copy defines the reviewed job; mutable checkout changes/removal cannot replace or
invalidate that copy. Manager activation checks persisted delivery/inputs and the
helper checks its rebuilt private context. Legacy non-delivery registrations keep
source preflight. No replay, guest rebinding, input grant or restart adoption is
added. Schemas 1–4 preserve risk and ownership without invented delivery receipts.
No artifact is automatically imported or removed; partial private trees are retained.

**PRIVATE COUPLING:** shared `SetupPlan.manifestPath` is now public read-only.
Update its engine inventory and manager's exact base-plus-integration-patch lock
and compiled pin together (82 resulting files). The base remains `bb3fae2`; the
patched result has a new engine/source identity. Guest resources, parser dependencies
and C launcher are unchanged. No mutable external checkout dependency is used.

**VERIFIED — fake/local checks:** `make test` passes 308 manager Swift functions/
44 suites, 49 script tests and expanded relocated/read-only signed-helper fixtures.
Coverage includes independent replan, custom manifest/catalogue/tasks, binary/mode/
empty-directory preservation, changed metadata/identities/framing/hashes, private
file/root/link substitution, implicit-directory bounds, strict receipt/bootstrap/
journal migration, consent constraints and frozen activation after source removal.
Actual admitted product helper validates delivery but denies activation. The
separately sealed/ad-hoc-signed Debug helper validates a multi-frame payload and
uses only fake adapters for completion/cancellation after parent source deletion.
Changed delivery is refused; matching child exits are reaped. No fake backend is
installed into the product app. Shared build/tests and development oracle checks
pass 68 Swift functions, 18 parser fixtures and 66 complete planning/error fixtures.
Only disposable local socket/mock-auth/PTY sandbox exceptions and ad-hoc fixture
signing are used; no real signing credentials, auth UI, transport, installs or
VM operation occurs. Existing real-guest evidence labels remain unchanged.

**TO PROVE:** trusted manager-aware session/dependency authority and exclusive real
backend construction, product coordinator wiring, full restart/reconnect/rebinding,
real release-signature acceptance, power-loss durability/retention UX, live terminal/
PTY/input/UI/CLI integration and real guest/auth/echo/quiescence/crash/kernel behavior.
The supplied screenshot remains a visual reference; no UI or installed app changes.
See the [frozen-input handoff](docs/DevVMProvisioningPlan.md#milestone-3-frozen-input-delivery-and-helper-context-validation--3-november-2026).

## Helper backend construction and manager session authority — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** continue milestone 3 using fake runtimes
and disposable local fixtures only. No real SSH/Ansible, installs or VM launches.
This supersedes the pending construction/authority foundation above; execution
surfaces remain disabled and no UI or installed app changes.

**DESIGN DECISION / IMPLEMENTED:** a single-use helper backend constructs the
existing shared SSH/Ansible adapter and original-worker fenced runner from an
explicit trusted helper-local transport-resource provider. Require the validated
frozen request, original bindings/digests, package admission and fresh manager
permission before resource access and runner construction. Verify connection/tool
pins around awaits without probes or reading identity-file bytes. The exact same
manager authority guards the context, adapter and runner; authority-bound workers
cannot fall back to local-only validation. Product entry points provide no resource
provider or operational runner; all tested factories return fake process runners.
Production managed-SSH/Homebrew resource admission and handoff remain product work.

**DESIGN DECISION / IMPLEMENTED:** bootstrap 4 binds the authority version and an
independent inherited fd-5 session channel. Frozen data/control remain separate.
Session HMAC keys have a distinct derivation domain and counters; control packets
cannot act as authority. One-shot registration/activation binding follows durable
activation/lease publication. A separate reverse-RPC loop awaits the coordinator
without blocking the launcher's control lock, keeping status/cancel serviceable.
Fresh challenge-bound checks cover preparation, commands, process invocations and
completion. Strict bounded metadata includes original opaque scope and typed
operation/purpose, never owner names, credentials, paths/argv or terminal bytes.
No successful decision is cached; bad/lost/replayed replies poison the channel.

The coordinator compares the live generation/journaled activation and original
scope, revalidates the actual VMManager lease plus dependency/binding authority,
and repeats its state checks after awaits. Current running session, SSH owner,
shutdown/power/execution/storage state remain manager-owned. Process ownership is
recorded before permission; fencing/cancellation is checked again before backend
launch. Body revocation returns not-started locally and typed cancellation to the
sequencer. Valid original-target cleanup can continue after cancellation or package/
source loss; failed journal writes stop body work while permitting cleanup against
the retained lease and preserving risk. Missing/expired/invalid authority cannot
invent remote cleanup proof. Physical uncertainty retains the exact local runner.

**DESIGN DECISION / IMPLEMENTED:** schema 6 persists the optional original session
version, requiring genuine delivery and helper owner. Unknown/null/legacy markers
fail closed; schemas 1–5 retain risk/pins without invented authority or replay.
Lost channels fence local work. A new helper, saved PID or disk row cannot adopt
manager/VM ownership. Matching VM/helper exit boundaries remain separately retained.

**PRIVATE COUPLING:** shared connection verification is public stat-only metadata
revalidation, tool verification is public, and fixed process purposes gain Codable.
The engine inventory and exact 82-file base-plus-patch export/compiled pin change
together. Base `bb3fae2`, guest resources, parser dependencies and C launcher remain
unchanged; the patched engine identity is new.

**VERIFIED — fake/local checks:** `make test` passes 319 manager Swift functions/
45 suites, 49 script tests and expanded relocated/read-only signed-helper fixtures.
Coverage includes concrete adapter apply/check with fake runners, construction
resource checks, fresh per-invocation permission, cancellation/shutdown/exit/SSH/
dependency/package/channel races, cancellation during dependency validation,
failed-journal cleanup, strict MAC/challenge/schema/one-shot binding, local-authority
bypass refusal and physical-uncertainty recovery without backend reconstruction.
The actual product helper refuses activation without a provider. A separate
ad-hoc-signed Debug helper constructs the adapter with inert files/fake runner and
uses the actual inherited authority channel for completion and deterministic
cancellation/cleanup; matching owned child exit is reaped. Shared checks pass 68
Swift functions, 18 parser oracle fixtures and 66 complete planning/error fixtures.
Only local socket/mock-auth/PTY sandbox exceptions and ad-hoc fixture signing are
used. No real credentials/auth UI, transport, installs or VM operation occurs.

**TO PROVE:** product transport-resource admission/handoff and construction, real
runner/terminal/input leases, UI/CLI, full restart/reconnect/rebinding, release
signatures, power-loss/retention UX and real guest/auth/echo/transport/quiescence/
cleanup/crash/kernel behavior. Fresh RPC checks are not atomic remote execution
or proof of guest liveness after a reply. Earlier real-guest evidence labels stay
unchanged; the supplied terminal screenshot remains a visual target.
See the [backend/session-authority handoff](docs/DevVMProvisioningPlan.md#milestone-3-helper-backend-and-manager-session-authority--3-november-2026).

## Transport-resource admission and private handoff — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** continue milestone 3 with fake runtimes
and local fixtures only; no real SSH/Ansible, host installs or VM launches. This
implements the admission/handoff foundation previously pending. Product execution
gates stay disabled; no UI, installed app or operational runner is enabled.

**DESIGN DECISION / IMPLEMENTED:** admit transport resources from the current
VMManager session/profile and explicit owned root. Require running/ready original
owner/session and no conflicting lifecycle/storage operation. Validate public
managed SSH manifests, exact port and known-host identity plus root identity;
derive the private identity-file reference without reading its bytes. Never call
credential generation, key-reading storage validation or a guest probe. Admission
consumes an already verified schema-2 tool report, checks fixed system entries,
coherent Homebrew Ansible version/installation/targets and current fingerprints,
and captures original executable hashes/stamps and a stat-only single-link key
reference. It does not rerun tool probes or claim new signing/runtime provenance.

Compute the dependency digest from the canonical original resource selection and
require it in the reviewed request. Bind the ephemeral private handoff to the
original job/VM/session/payload/worker/review/checkpoint/source/engine/mode. Recheck
against the actual manager root/port at publication, handoff, acceptance, activation
and command/invocation authority boundaries. Replaced resources need new review;
changed credentials/tools never become cleanup replacements by inference.

**DESIGN DECISION / IMPLEMENTED:** bootstrap 5 binds a resource receipt and separate
inherited fd-6 stream, handed over only after package/owned-child code admission.
Strict bounded parsing, SHA/size/EOF and original proof comparison precede helper
acknowledgement. Paths, public metadata and stat/hash proofs stay in memory/private
stream; no descriptor is saved and no paths/bytes enter argv/environment/control/
status/terminal/journal. Private-key contents are neither read nor transferred.
The helper's host policy is independent of the descriptor; only explicit test code
injects fixture policy. A resource-bound backend must use the validated handoff.
Product helper has no process-runner factory and still refuses activation.

**DESIGN DECISION / IMPLEMENTED:** schema 7 stores only the original resource
receipt, requiring matching dependency, frozen inputs and manager authority.
Schemas 1–6 preserve risk and old pins without invented resources or replay.
Live admission/service state is retained separately; reopening never reconstructs
credentials or replays a queued job from journal metadata. Existing explicit
cleanup/ownership protocols remain separate; no new restart adoption or automatic
resource import/removal is introduced.

**PRIVATE COUPLING:** shared `ProvisioningTransportReference` privately exports/
imports original executable and identity proofs, with exact expected binding/paths,
strict nested schemas and link-count checks. It never authorizes execution or
recaptures changed files. Base-plus-patch export now contains 83 files with updated
source/engine/compiled pins; base remains `bb3fae2`. Guest resources, parsers and C
launcher retain their bytes.

**VERIFIED — fake/local checks:** `make test` passes 328 manager Swift functions/
46 suites, 49 script tests and expanded signed-helper fixtures. Cases cover managed
endpoint/report/private round trip, original key/tool/alias/installation/metadata/
root changes, cross-job/mode/dependency/format damage, host policy, acknowledgement
refusal, schema preservation, fresh activation/invocation checks and no replay.
Concrete apply/check use only fake process runners. The separately sealed/ad-hoc
Debug helper imports the actual private stream, constructs the shared adapter from
original proofs, completes/cancels with fake replies and reaps its owned child.
The product helper rejects fixture paths under host policy; no fixture policy or
runner is installed into it. Shared checks pass 70 Swift functions, 18 parser oracle
fixtures and 66 complete planning/error fixtures, including stat-only round trip
with an unreadable synthetic identity. Only existing local IPC/mock-auth/PTY sandbox
exceptions and ad-hoc signing are used. No real credential/auth UI, host install,
guest transport, VM launch or installed-app change occurs.

**TO PROVE:** product resource acquisition/coordinator wiring and report provenance/
lifetime, genuine managed-SSH/Homebrew admission across supported installations,
operational runner/terminal/input/UI/CLI, full restart/reconnect/rebinding, release
signatures, power-loss/retention UX and real guest identity/auth/echo/transport/
remote cleanup/quiescence/crash/kernel behavior. Hash/stat/RPC checks are not atomic
remote execution or proof of guest liveness after a reply. Prior real-guest labels
remain unchanged; the terminal screenshot remains a later visual target.
See the [transport admission/handoff record](docs/DevVMProvisioningPlan.md#milestone-3-transport-resource-admission-and-private-handoff--3-november-2026).


## dev-vm milestone 3 completion — 3 November 2026

**DESIGN DECISION:** milestone 3 is complete within fake/local acceptance. One
manager-owned service coordinates strict workflow/child journals, SSH wait/review,
admitted helper activation, original exit observation, matching-exit restart and
fresh explicit rebind/check review. Duplicate/concurrent acceptance cannot replay.
Corruption or uncertain ownership preserves risk and blocks normal VM lifecycle.
App composition installs the service with execution disabled and performs no host
tool probes, helper launch or VM operation. The packaged helper still has no
operational runner factory; terminal/input transport is milestone 4 and UI/CLI is 5.

**DESIGN DECISION:** a full manager process restart loses its private helper and VM
ownership capabilities. Journal rows, saved PIDs, locks or diagnostic markers cannot
recreate them. Interrupted jobs retain cleanup-required holds; no automatic worker
adoption, execution replay, source import or restart occurs. Explicit cleanup after
service/coordinator reopen requires original authenticated stopped-and-fenced proof,
current manager-owned session authority and re-supplied original resource proofs.
Private/orphan recovery files are retained; bounded quotas refuse new work rather
than deleting them. Manual recovery/retention UX remains a later acceptance concern.

**VERIFIED:** `make test` passes 347 Swift test functions in 48 suites, 49 script tests, and relocated/read-only ad-hoc-signed helper fixtures. The final `make test-provisioning-tools` run passes 141 functions in 13 suites after the last cancellation/recovery guard changes. Package/export validation and companion/vendor source/engine matching pass. See the
[completion record](docs/DevVMProvisioningPlan.md#milestone-3-completion--3-november-2026)
for exact checks and limits. Separate processes exercise owner loss during fake work
and a fresh manager's refusal to invent ownership; surviving-capability recovery,
local runner construction/output, lifecycle, durable failure and retention use
fake runtimes/local fixtures. No real transports, authentication UI, host installs,
VMs, permission grants or installed-app changes are exercised.

**PRIVATE COUPLING:** original manager session/root/managed-SSH ownership and pinned
helper/resource inventories remain required. This is orchestration above the shared
package, not a duplicate VM implementation.

**TO PROVE:** live terminal/input/rendering, operational UI/CLI, genuine guest
identity/authentication/echo, restart/check and remote cleanup after failure,
positive recovery after full process loss, host sleep/wake/crash/power-loss/kernel
behavior and release signatures. Real guest evidence and all prior TO PROVE labels
remain unchanged. The Setup screenshot remains a later visual target.


## dev-vm milestone 4 completion — 3 November 2026

**DESIGN DECISION:** one dedicated anonymous inherited terminal socket, separately
MACed from control and manager authority, carries bounded byte frames and viewer
operations for the original admitted helper/job. Viewers start read-only; one
explicit input owner controls the reviewed scope and PTY size. Tokens bind viewer,
invocation and sequence. Detach, expiry, stream loss, completion/cancellation/fence
and observed output gaps revoke input; pending keystrokes are discarded. No raw
terminal/input is journaled or logged. Slow viewers never block process draining or
control cleanup. Missing output requires a visible reset/jump to the live tail and
fresh deliberate input claim, never invented screen reconstruction or disk replay.

**VERIFIED:** `make test` passes 362 Swift functions in 49 suites, 49 script tests
and the signed local helper fixtures. The final shared package checks pass 72 Swift
functions, 18 parser oracle fixtures and 66 planning/error oracle fixtures; package
export verification, companion/vendor matching and both diff checks pass.
See the [milestone 4 completion record](docs/DevVMProvisioningPlan.md#milestone-4-completion--3-november-2026).
Tests use synthetic inputs, fake runtimes/transports, disposable local PTYs/processes
and excluded ad-hoc-signed debug helpers. Scoped local TTY restoration covers normal,
error and cooperative-cancellation exits, allowing Darwin's transient PENDIN bit.
No real transports, installs, downloads, VM or user UI operations are performed.

**PRIVATE COUPLING:** bootstrap 6 / terminal protocol 1 / inherited fd 7 are private
manager/helper interfaces pinned to the existing admitted registration and original
session/resource authority. Shared scope reservation grants no typing permission;
an explicit live attachment is required. Public product execution stays disabled.

**TO PROVE:** native emulator/rendering/host-action escape policy, Setup UI and
external CLI attachment are milestone 5. Actual nested SSH, guest password prompts,
resize, remote cleanup/restart/check, sleep/wake/crash and real signatures retain
their separate acceptance gates. No positive recovery after full process loss or
TTY restoration after hard process termination is claimed. The Setup screenshot
remains the visual target for milestone 5.

### 3 November 2026 — provisioning milestone 5 terminal/observation slice

- **DESIGN DECISION:** Setup and the separate setup CLI share one manager-owned
  observation/cancellation/attachment service. Offline preset/folder previews use
  the pinned planner. Attachments start view-only; deliberate input ownership,
  typed invocation metadata, bounded transient input and gap/reset handling apply.
  Existing VM command JSON contracts and production execution gates remain intact.
- **PRIVATE COUPLING:** library-only SwiftTerm 1.99.0 at
  `2dad6a1e516f755bed77cf9bbd09455062f54758` requires Swift 6.2+ (tested with 6.4),
  with one reviewed grapheme-length guard, two integration files and inventory.
  The scoped display filter blocks host-action escapes before native/CLI rendering;
  protocol-1 `setup-v1.sock` uses private same-user Unix-socket admission and never
  exports helper capabilities. Terminal content/input is never journaled/logged.
- **VERIFIED:** `make test` passed 376 manager Swift test functions in 50 suites, 52 script tests, and the relocated/read-only/ad-hoc-signed helper fixtures (including original owner-loss/reopen and terminal streaming). The focused UI/CLI coverage contains 13 functions plus the four-case bundled-preset test: split Unicode/ANSI, cursor/colour/CR rendering, blocked host actions, oversized/malformed streams, storage bounds across cursor/style changes, native viewer ownership/search/reset, strict correlated protocol refusal, cross-view input ownership, EOF/gap/reclaim, distinct cancellation and disposable PTY termios/signal/open-file-flag restoration on detach, connection loss and task cancellation. Vendor inventory, the reviewed two-line source patch, exact upstream export comparison, unchanged shared-package export checks and `git diff --check` passed. No user window was opened or real transport executed.
- **TO PROVE:** full milestone-5 creation/selection, frozen preview/apply and explicit
  hash-bound task trust, restart/check/recovery execution actions, complete visual
  acceptance, nested guest/SSH authentication and cleanup, hard-kill TTY recovery,
  and distribution. This is an uninstalled worktree build. No real transports,
  host installs, factory downloads, VM operations or user UI takeover occurred.

### 3 November 2026 — milestone 5 frozen review and explicit task trust

- **DESIGN DECISION:** manager-owned Preview freezes selected inputs into a fresh
  private UUID tree, replans and verifies hashes, then binds an explicit target
  review/consent to that snapshot. Later source edits do not alter it. UI and CLI
  share capture/lookup, explicit task-source inspection, prepare/apply and status.
  Task trust has its own digest over the exact review, all frozen inputs and
  selected tasks; general Apply, sudo and Docker consent do not imply it.
  Submission repeats package, original resource/session and fresh dependency
  checks before existing helper admission, with one owned operation per UUID and
  no automatic mutation retry. Source bytes are returned only on a deliberate
  task-source read; no terminal/input/archive/credential enters normal status.
- **PRIVATE COUPLING:** additive review operations on setup protocol 1, bounded
  previews/task chunks and memory-only review/consent handles. Existing strict
  workflow/helper journals govern prepared jobs; retained private source trees
  are not executable authority after reopen. Product composition has neither an
  enabled execution gate nor an operational owner/UID/key resolver. Tests inject
  synthetic evidence; the manager never guesses a real guest UID.
- **VERIFIED:** `make test` passed 390 manager Swift test functions in 52 suites, 52 script tests and the relocated/read-only/ad-hoc-signed helper fixture suite (including original-owner loss/reopen and terminal streaming). `make test-provisioning-review` passed 28 functions in three suites: frozen previews, original-source edits, explicit task-source chunking, preview quotas, no authority after reopen, separate task/sudo/Docker consent, exact duplicate submission, changed source/tool/session admission, cancellation during a gated final recheck, stale task trust, strict nested protocol cases and CLI/native service interoperability. Tests call the native service API and actual private CLI socket, without opening the form or claiming visual acceptance. Package/export and both diff checks pass; shared package sources/resources/pins are unchanged.
- **TO PROVE:** native feature editing/New VM coupling, reviewed restart/check/
  recovery surfaces, operational guest identity/runner admission, visual and
  signed distribution acceptance, all real guest/SSH/echo/cleanup/crash/sleep/wake
  behavior. No actual transport, host install, factory download, VM or user UI
  operation occurred. The shared package source/resources/pin are unchanged.

### 3 November 2026 — milestone 5 reviewed workflow actions

- **DESIGN DECISION:** Setup and CLI share preparation/consent for existing workflow
  restart, post-restart check and cleanup recovery. Action UUID/digest binds exact
  workflow/VM/session/job, sequence and input/dependency scope. No acknowledgement
  is inferred from Apply/task trust. Duplicates share one owned operation; failed
  operations require a deliberate fresh review, and action authority is not restored
  from disk. Restart waits for matching `.exited`, check requires the admitted new
  session and excludes custom tasks, and recovery is restricted to original cleanup.
- **PRIVATE COUPLING:** additive strict setup-socket action schemas delegate to the
  existing M3 restart/rebind/recovery paths. Recovery’s lazy adapter constructor
  cannot run before original authenticated worker/checkpoint admission. A new
  process, journal or PID cannot manufacture ownership. Active provisional cleanup
  risk is not a recovery action. Product execution/resolver/recovery factory remain
  disabled; no operational runner is installed.
- **VERIFIED:** `make test` passed 403 manager Swift test functions in 54 suites, 52 script tests and the relocated/read-only/ad-hoc-signed helper fixtures, including original-owner loss/reopen and terminal streaming. `make test-provisioning-actions` passed 13 functions in two suites (including ten malformed-wire variants and three final-check admission/cancellation variants). Fake fixtures cover explicit consent, shared CLI/native action lookup, duplicate restart/check, diagnostic-vs-exit boundaries, fresh-session frozen checks with custom tasks excluded and no authorization input, active-risk recovery refusal, lazy factory ordering, missing original capability after reopen, source-free cleanup, failed revocation/retained holds, stale sibling recovery reviews, failed-operation non-replay and lost in-memory consent. Product endpoint tests prove disabled refusal before probes/factories. UI controls compile; complete interactive/visual acceptance was not performed. Package/export checks and both diff checks pass. Shared package sources/resources/pins are unchanged.
- **TO PROVE:** native feature editing/New VM handoff, operational identity/factories,
  complete visual interaction, actual guest/SSH/echo/revocation/restart/check,
  crash/sleep/wake and signed distribution. This slice uses only fake runtimes,
  fake adapters and disposable private UUID fixtures. No real transport, host
  install, factory download, VM or user UI operation occurred. Shared sources,
  resources and pins are unchanged.


## Native feature choices and New VM setup selection — 3 November 2026

- **DESIGN DECISION:** Setup and New VM expose typed Use source/Enable/Disable
  choices for common built-ins; advanced settings remain source-owned and shared
  planning resolves dependencies/conflicts. Native edits derive a private generated
  manifest from frozen bytes, preserve the original manifest/mode and bind all
  selected bytes into new hashes. No selected source file is overwritten.
- **DESIGN DECISION:** New VM saves a separately acknowledged frozen selection,
  while resource/factory/SSH/owner/sharing fields come from manager creation
  arguments. Saving is metadata only and grants no Apply, task trust or sudo
  authority. Duplicate consent plus identical creation arguments returns the
  original UUID without mutation/launch; uncertain saves retain their reservation.
- **PRIVATE COUPLING:** strict setup-socket creation prepare/lookup and guest
  creation consent share the native service. Registry schema 6 stores a validated,
  immutable non-secret receipt. Preview binding requires its matching saved VM;
  reopening retains metadata lookup only and cannot recreate execution consent.
  Older registry versions still load; older builds reject schema 6.
- **VERIFIED:** `make test` passed 419 manager Swift functions in 55 suites, 52
  script tests and relocated/read-only/ad-hoc-signed helper fixtures. Focused
  local selection tests pass 16 functions in one suite,
  including frozen bytes/modes, typed protocol refusal, shared dependency resolution,
  resource/factory precedence, duplicate and uncertain saves, port admission and
  inert reopen. Full-suite evidence is recorded in the
  [milestone-5 handoff record](docs/DevVMProvisioningPlan.md#milestone-5-native-features-and-new-vm-handoff--3-november-2026).
- **TO PROVE:** full native visual/interaction acceptance, operational guest
  owner/UID/key evidence and runner factories, real guest/SSH/echo/cleanup/restart/
  check/crash/sleep/wake and signed distribution. Execution/resolver/recovery
  construction remain disabled. No host install, real transport, factory download,
  VM or user UI operation occurred. Shared sources/resources/pins are unchanged.

## Authenticated provisioning identity and dormant runtime composition — 3 November 2026

- **DESIGN DECISION:** retain the UID/owner from the existing authenticated managed
  SSH probe, bound to its exact VM/session, UUID-root inode/device, port, host key,
  public metadata hashes and stat-pinned client identity. A strict bounded parser
  refuses malformed replies. Readiness-only state, guest status, manifests and
  saved receipts cannot supply provisioning identity. Evidence is memory-only,
  redacted and fresh for at most 45 monotonic seconds.
- **PRIVATE COUPLING:** the pinned guest `managed-ssh-identity` command supplies
  exactly VM/session/user/UID, as confirmed by source inspection. Successful
  30-second refreshes preserve readiness; failures and identity changes invalidate
  authority. Retry/pause/shutdown/exit clear evidence and fence late callbacks.
  Host transport admission/revalidation require current authenticated evidence.
- **DESIGN DECISION:** product composition now supplies inert identity/recovery
  constructors. A single fixed-false build-time gate keeps manager execution and
  helper runner selection disabled. Dormant worker construction reuses package/
  engine/resource/launcher admission and original session/invocation fencing.
  Recovery construction remains behind original-helper proof and cleanup-only
  scope; it rechecks transport and manager authority. A new runner proves no prior
  worker exit and grants no task, sudo or user-input authority.
- **VERIFIED:** `make test` passes 428 manager Swift functions in 56 suites, 52
  script tests and relocated/read-only/ad-hoc-signed helper fixtures. Focused
  fake/local identity/backend validation passes 43 functions
  across nine suites, including the normal monitor with fake SSH execution and
  fixture sleeps. Source inspection confirms the four-field guest identity format.
  The [implementation/evidence record](docs/DevVMProvisioningPlan.md#milestone-6-preparation-authenticated-identity-and-dormant-backends--3-november-2026)
  records final full-suite and offscreen component checks. Actual controls and
  correctly oriented Unicode/ANSI terminal rendering were inspected in a labelled
  synthetic PNG, without AppModel/registry access or a visible window. This does
  not establish whole-screen interaction or real prompt/echo acceptance.
- **TO PROVE:** real owner/UID/key authenticity, guest/nested SSH/TTY behavior,
  remote cleanup, end-to-end setup/reapplication/restart/check, crash/sleep/wake,
  whole-screen interactive acceptance and signed distribution. No product execution
  was enabled, real transport/VM operation performed, host tools installed,
  factory downloaded, personal credential accessed or user desktop taken over.
  Shared package sources/resources/export and engine pins remain unchanged.

## Full Setup/New VM fake acceptance and disposable-guest runbook — 3 November 2026

- **VERIFIED:** 56 isolated checks exercise actual New VM/selection/manager Setup
  views and shared actions: review/acknowledgment, edits/races/refusal, explicit
  resource/factory precedence, frozen handoff/duplicate creation, complete task
  inspection, independent apply consent, terminal search/expand and cancellation.
  Eight full-screen light/dark/scrolled PNGs were inspected. The DEBUG harness
  runs before normal model/registry construction with in-memory fake services and
  a never-started FakeRuntime. Nonactivating backing windows lie outside every
  display; no OS input or desktop capture is used. The temporary support root
  remains absent. [Evidence and limits](docs/DevVMUIAcceptance.md) are recorded.
- **VERIFIED:** `make test` passes 428 Swift functions in 56 suites, 52 script tests,
  relocated/read-only/ad-hoc-signed helper fixtures and the 56 screen checks.
  The final screen target and package/export verification pass. Release compilation
  passes without signing credentials; fixture entry point/markers are absent from
  the release binary. This is compile evidence, not signed-distribution acceptance.
- **DESIGN DECISION:** button/action guards are shared, including required-task
  inspection. Loaded frozen input is explained independently of the source picker.
  Fixture state is injected locally in DEBUG, never selected through a real
  execution override. Product execution and shared package/resource/export/engine
  pins remain unchanged.
- **TO PROVE:** physical input, focus/VoiceOver, native file/task/confirmation
  dialogs and real guest/SSH/Ansible/TTY/cleanup/restart/check/crash/sleep/wake.
  The [milestone-6 runbook](docs/DevVMMilestone6Runbook.md) is prepared, not run.
  It requires a scoped, separately reviewed operational candidate and explicit
  disposable-guest consent before execution. No real transport, host installation,
  VM launch/change, factory download, personal credential or desktop takeover
  occurred. Milestone 6 real acceptance and milestone 7 distribution remain open.

## Milestone 6 disposable admission — 3 November 2026

- **DESIGN DECISION:** ordinary product approval is `nil` and execution stays false.
  A future private candidate may embed only the original explicitly reviewed
  disposable UUID/root/device/inode/ownership-marker pins in both manager/helper.
  There is no separate Boolean bypass or approval loader from CLI, environment,
  manifest, registry, journal, readiness or IPC. Internal fixture injection remains
  trusted test composition. An ownership marker does not itself mean disposable.
- **DESIGN DECISION:** hold root descriptors; recheck private ownership/mode,
  canonical namespace, device/inode and strict markers. Reject retained POC IDs,
  replaced roots, arbitrary symlinks and unlisted UUIDs. The manager also checks
  its profile/session root at preparation, transport, leases, cleanup and both
  sides of restart. A compiled candidate's initial start and coordinator-close
  paths retain scope. The helper independently checks before runner construction
  and before/after reverse RPC for every command/invocation. Input claim/send/resize
  failure releases ownership; output remains viewable. Recovery never bypasses
  approval or original-worker quiescence/session/provenance/cleanup requirements.
- **VERIFIED:** 12 fake/local admission test functions cover admitted work,
  unlisted/foreign/same-UUID roots, invalid/stale pins, marker/mode/symlink changes,
  independent manager/helper refusals, RPC races, restart/replacement, recovery
  construction/commands and terminal ownership. See the
  [implementation record](docs/DevVMProvisioningPlan.md#milestone-6-disposable-admission-foundation--3-november-2026)
  and updated [runbook](docs/DevVMMilestone6Runbook.md). Full `make test` passes
  440 Swift functions in 57 suites, 52 script tests, signed local helper fixtures
  and 56 isolated screen checks. The final focused admission target, release
  compilation without signing credentials, package/export and diff checks pass.
- **TO PROVE:** approval of concrete newly prepared disposable roots and a real
  signed operational candidate, then guest/SSH/Ansible/TTY/apply/cleanup/restart/
  check/crash/sleep/wake and milestone-7 distribution. No actual approval values,
  host installs, VM launches/changes, factory downloads, real transport, personal
  credentials or desktop takeover occur in this slice. Shared package/resources/
  export/engine pins remain unchanged.

## Separate setup Source and multiple profile cards — 3 November 2026

- **DESIGN DECISION:** native Source selects bundled configuration or a local
  `vm.yml` folder; profile cards select one or more bundled profiles. Local declared
  profiles/settings/tasks stay included and cards add profiles. Individual feature
  overrides are hidden in the native UI. Colored native badges and summaries come
  from the shared resolver's expected inclusions, not observed guest contents.
- **PRIVATE COUPLING:** optional bundled/profile source fields use the same strict
  local protocol and generated frozen-manifest projection. Legacy CLI presets stay
  compatible. Bounded unique builtin additions preserve source bytes and deduplicate
  aliases; shared merge/dependency/conflict rules remain authoritative. Conflicts
  are refused until explicitly resolved; review acknowledgment is invalidated on
  profile edits. No package/engine/runtime source is duplicated or ported here.
- **VERIFIED:** 24 focused selection functions (eight new profile tests), 448 Swift
  functions in 58 suites, 52 script tests, local signed helper fixtures and 62
  isolated UI checks pass. Eight light/dark/scrolled PNGs were inspected. Release
  compilation without real signing credentials, package/export and diff checks
  pass. [UI evidence](docs/DevVMUIAcceptance.md#separate-source-and-multiple-profiles--3-november-2026)
  records current captures and limits.
- **TO PROVE:** physical UI/focus/VoiceOver/native dialogs and real candidate/guest/
  SSH/Ansible/TTY/cleanup/restart/check/crash/sleep/wake/distribution. Product approval
  stays nil and execution disabled; no host install, factory download, real VM or
  transport operation occurred. Shared package/resources/export/engine pins are
  unchanged. Local custom profiles stay manifest-defined, outside the bundled card
  catalogue; their task trust and all execution consent remain independent.

## Conditional optional-app trimming — 3 November 2026

- **DESIGN DECISION:** expose Trim optional apps only for the official Try Omarchy
  factory, initially off. The tooltip describes its broad bundled apps and a more
  sensible base. Guest setup changes the VM, not reusable factory bytes. Trim and
  factory edits invalidate review; unsupported provenance resets/hides the choice.
  Native on/off explicitly overrides local manifest trimming; legacy absent
  overrides preserve the existing `vm.lean_developer` setting.
- **PRIVATE COUPLING:** freeze the Boolean in the private selection manifest and
  enforce actual official identity at creation reservation/workflow preparation.
  The shared planner lists candidate removals, excluding selected software. Reuse
  the upstream guest helper/allowlist through the supervised, streamed apply path;
  check never trims. The optional-app-trim integration patch updates the pinned
  source/resources/tests and compiled admission identity. No host Python is added.
- **TO PROVE:** real guest trim/dependency closures/reapply and live terminal under
  an explicitly approved disposable candidate. Product approval remains nil and
  execution disabled. No host installation, image change/download or VM launch.
- **VERIFIED:** 28 focused manager selection functions, 452 manager Swift functions
  in 59 suites, 52 script tests, final seven package functions/six package scripts
  and signed local helper fixtures pass. Final shared tests pass 77 functions;
  twelve upstream helper tests use mocked subprocess replies. Final screen checks
  pass 74 checks with twelve synthetic PNGs; four new scrolled trim images were
  inspected. Release compilation, immutable patch verification and diff checks pass.
- **VERIFICATION EXCEPTION:** the companion broad test target invoked installed
  Ansible against temporary local inventories and fake helper files before its
  full scope was inspected. This exceeded the no-real-Ansible instruction; it
  contacted no guest and installed no host tools. The run failed (10 failures,
  44 errors, one skip/235 tests), so it is not acceptance evidence. Subsequent trim
  tests use fake runners/mocked helpers. Exact checks, limits and this exception
  are recorded in the [implementation plan](docs/DevVMProvisioningPlan.md#optional-app-trim-selection--3-november-2026).

## Theme and layout selection — 3 November 2026

- **DESIGN DECISION:** native New VM/Setup use an initially collapsed Theme & layout
  section for a GitHub repository URL, random/most-starred and keep/select/remove
  for a Lua layout. Blank preserves source/current choices. Random uses ten stars
  by default; zero skips ranking. Star-based choices require existing authenticated
  gh; no install/sign-in flow is initiated. Theme/layout edits invalidate review.
- **PRIVATE COUPLING:** shared Swift selector/resolver with injected HTTP/star
  providers owns strict roots, catalogue figures, thresholds/ranking and final GET
  acceptance. The manager uses bounded credential-free ephemeral GETs and the
  existing bounded read-only gh runner. It resolves once during review and freezes
  the concrete URL. GET accessibility establishes neither theme validity nor a Git
  content pin. Selected regular UTF-8 layout bytes (at most 256 KiB) are captured
  without following symlinks or executing Lua, copied into private reviewed inputs
  and hashed. Original files/settings remain unchanged. Existing snapshot/Ansible/
  native Omarchy paths own apply; workstation disable is refused. CLI/socket review
  APIs share strict appearance selections. No new lifecycle owner or host Python.
- **PRIVATE COUPLING:** the theme-selection export patch and lock/engine/snapshot
  pins include the shared implementation and fake tests. Product approval stays nil
  and execution disabled; creation/review never authorizes setup or custom tasks.
- **VERIFIED:** full manager make test passes 463 Swift functions in 61 suites,
  52 script tests, local signed helper fixtures and 82 offscreen checks. Eleven
  focused appearance functions, 84 shared Swift functions, eighteen selected
  upstream mocked/controller or disposable stub-shell fixtures, syntax checks,
  release compilation, reverse export and diff checks pass. Four new light/dark
  captures were inspected; [evidence and limits](docs/DevVMProvisioningPlan.md#theme-and-layout-selection--3-november-2026)
  are recorded. No real HTTP/gh/SSH/Ansible, host install, factory operation or VM
  launch occurs in this slice. The broad companion Ansible target is skipped to
  honor the user's explicit fake/local constraint.
- **TO PROVE:** live catalogue/authentication/rate limits and theme contents,
  native dialogs/hover/focus/physical input, actual guest apply/reapply/check/layout
  login behavior, cleanup and distribution under explicit disposable approval.

## Bundled dev-vm layout example cards — 3 November 2026

- **DESIGN DECISION:** Desktop layout → Examples offers the four upstream example
  layouts as single-select wireframe cards, with split proportions/browser overlap,
  descriptions and prerequisite apps. The gallery uses full width and adapts to
  four or two columns in the tested forms. Keep/Custom file/Remove remain. Choosing
  a card freezes its original Lua; it does not implicitly add app installs or
  authorize execution. Wireframes illustrate intended floating placement, not
  observed guest state. Applications must be available separately at guest login.
- **PRIVATE COUPLING:** shared catalogue/API binds four fixed IDs, metadata and
  source hashes to bundled copies of the unchanged original Lua. A strict optional
  appearance field is mutually exclusive with custom-file/removal choices. Native,
  CLI and socket paths share it; the existing frozen-input/private-manifest/shared
  planner/transport path owns application. Preview naming uses the actual frozen
  source hash. A new integration patch updates engine/resource/snapshot/lock pins;
  product approval remains nil and execution disabled.
- **VERIFIED:** full manager tests pass 468 Swift functions in 62 suites, 52 scripts,
  signed local helper fixtures and 100 isolated screen checks. Shared tests pass 86
  functions. Original and bundled sources/catalogue match byte-for-byte; resource
  sync syntax parsing and reverse export/diff checks pass. Four new light/dark
  captures were inspected; [checks and limits](docs/DevVMProvisioningPlan.md#bundled-dev-vm-layout-example-cards--3-november-2026)
  are recorded. No actual Lua/HTTP/gh/SSH/Ansible, host install, factory operation or
  VM launch occurs in these checks. The broad Ansible target remains skipped.
- **TO PROVE:** physical card interaction/VoiceOver and actual guest app availability,
  startup, placement, manual resizing, reapplication and next-login behavior under
  explicit disposable approval. Historical dev-vm captures are separate evidence.

## Offline provisioning candidate preflight — 3 November 2026

- **DESIGN DECISION:** an offline build evidence report cannot enable execution or
  approve a disposable scope. The existing product approval remains nil. Build
  hashes and source status are observations, not signed/loaded-code admission or
  proof that binaries were built from HEAD. New stopped disposable root preparation
  and an actual guest run still require their concrete explicit approvals.
- **PRIVATE COUPLING:** `make provisioning-preflight` reuses the pinned export,
  generated source pin and resource inventory, records existing binary hashes and
  optionally checks an assembled provisioning seal/runtime-lock copy. Read-only
  export validation creates only its temporary reverse-patch copy, never build
  inputs. The tool reads no user guest/registry/factory-image or credentials and
  invokes no candidate or signing/dependency/transport tools. It is repository
  development tooling, not a product Python runtime.
- **VERIFIED — offline/local:** ten static checks and all 61 script tests pass,
  including nine new tamper/replacement/read-only regression fixtures. The previous
  Swift/shared/UI results remain scoped to their recorded source. See the
  [runbook](docs/DevVMMilestone6Runbook.md#offline-candidate-preflight).
- **TO PROVE:** approved original root identities and operational candidate,
  signatures/loaded code, fresh real factory/tool admission and all guest rows.

## Private scoped provisioning candidate — 3 November 2026

- **DESIGN DECISION:** the approved stopped disposable profile/root and its original
  pins can identify a private candidate without authorizing launch or provisioning.
  Main source remains nil/disabled. Private source overlay and actual identifiers
  stay outside version control; constants cannot be supplied by a file, environment,
  CLI, manifest or IPC. Invalid original scope fails closed rather than falling
  back to ordinary composition. Production helper-signing policy is unchanged.
- **PRIVATE COUPLING:** a private six-file overlay over commit `1cb2bdd` installs the
  original scope in both manager/helper and a read-only inspection path before
  AppModel/registry/worker dispatch. Existing make/SwiftPM, exact kit resources and
  packaging are retained. No virtualization implementation or shared source changes.
- **VERIFIED — offline/local:** thirteen artifact checks, actual packaged component
  reports before/after relocation, fake-runtime refusal probes with zero starts,
  and twelve ordinary admission tests pass. Kit archive/inventory and signatures
  match; local app signatures verify. Only ad-hoc signing is used. Root, metadata
  and full registry are unchanged. Production same-team signing correctly refuses
  the candidate; no fixture policy replaces it. See the
  [runbook](docs/DevVMMilestone6Runbook.md#private-scoped-candidate-preparation).
- **TO PROVE:** authorized signing/loaded-child admission, separately approved SSH/
  owner configuration, existing factory/tool readiness, exact inputs/consents and
  all real guest acceptance. No launch, real SSH/Ansible, install, credential use,
  normal UI or worker body occurred. Real acceptance remains NOT_RUN.

## Offline candidate signing/readiness audit — 3 November 2026

- **VERIFIED — static/local:** nineteen checks confirm unchanged candidate/evidence,
  exact inventories/signatures, source archive/overlay and original root/registry.
  Static Ansible metadata is Core 2.21.5 in the expected family, with no CLI execution
  or readiness claim. Factory metadata is present but bytes are access-denied and
  checksum NOT_VERIFIED. No permission grant, image/disk creation, credential, host
  install, normal UI, workflow, signing, network or real transport/guest operation.
- **PRIVATE COUPLING / SOURCE INFERENCE:** supported promotion rebuilds signed
  runtime/profile/pin composition while retaining original scope. Existing tag CI
  checks out ordinary source and publishes archives; it is unsuitable unchanged for
  this ignored private candidate. A private nonpublishing handoff and final original-
  Mac scope validation must precede later authorized signing. No such route is run
  or implemented here; detailed artifacts and pins remain outside Git.
- **TO PROVE:** seven signing/readiness gates, including fresh CLI checks, approved
  SSH/owner/input configuration, verified factory bytes and actual loaded-child/
  guest behavior. Product approval remains nil and guest rows remain NOT_RUN. See
  the [audit record](docs/DevVMMilestone6Runbook.md#offline-signing-and-readiness-audit).

## Private signing/packaging handoff — fake/local, 3 November 2026

- **DESIGN DECISION:** private build-input bindings and a frozen signing request
  confer no guest/signing consent. CLI preparation never reads the target VM root,
  recaptures original pins, runs a signer or accesses credentials. Ordinary product
  approval stays nil. Real requests cannot enter the synthetic signing runner;
  production signature requirements and public release automation are unchanged.
- **PRIVATE COUPLING:** existing runtime-origin/payload, profile-entitlement and
  provisioning seal validators enforce fake profile/rebuild/child-sign/seal/outer-
  sign/verify/archive ordering. Both component receipts/code bodies retain the same
  scope. Private fresh outputs, immutable input digests, tag/release/VM namespace
  guards, archive checks and private failure retention prevent overwrite/replay or
  publishing. Build tooling remains separate from the shipped Swift controller.
- **VERIFIED — local fixtures:** eighteen new functions/22 rejection variants and
  all 79 script tests pass. The actual candidate yields a private 101-file request;
  synthetic ZIP roundtrip evidence records no process, network or credential call.
  Real request simulation is refused. Original candidate/root/registry are unchanged;
  detailed artifacts and pins stay ignored. See the
  [handoff](docs/DevVMMilestone6Runbook.md#private-signing-and-packaging-handoff--fakelocal-path).
- **TO PROVE:** authorized real signer/compilation, cryptographic/profile/loaded-child
  validation and original-Mac scope evidence; prior factory/tool/account and all
  guest gates remain pending. No real signing, installs, SSH/Ansible, workflow,
  credential, UI or VM operation occurs. Guest acceptance remains NOT_RUN.

## Private signer adapter — fake processes, 4 November 2026

- **DESIGN DECISION:** a developer-only adapter connects the frozen private request
  to existing signed-prerelease build/SDK commands. The system runner refuses by
  default before material IO; trusted in-memory authorization binds request, scope,
  material and allowed effects. No signing CLI, credential import/unlock/search,
  runtime download, notary submission or publication path is added. Secure
  timestamps require signing approval. Product approval remains nil.
- **PRIVATE COUPLING:** reconstruct the exact archive/overlay, preserve original
  scope/operational composition, project signed pins and inspector branch, use
  clean pinned local dependencies, and retain child-sign/seal/outer-sign order.
  Existing origin/payload/profile/seal policies plus SDK team/authority/hardened/
  timestamp/certificate checks and read-only archive roundtrip gate success.
- **VERIFIED — fake/local:** twelve new test functions, 33 command/signature failure
  cases and four runtime variants; all 91 script tests pass. Injected fake processes
  and mocked system dispatch exercise command/timeout contracts without a real
  child, tool, credential, Apple request, install, UI, disk or guest operation.
  Fixture results explicitly establish no production cryptography or launch
  readiness. Actual handoff/candidate/pins remain private and unchanged. See the
  [runbook](docs/DevVMMilestone6Runbook.md#private-signer-adapter--fake-process-runners-4-november-2026).
- **TO PROVE:** authorized local runtime/materials and actual compiler/SwiftPM,
  SDK/profile/signature behavior, notarization, final original-Mac scope and loaded
  child admission. Factory/tool/SSH/owner and all guest rows remain pending/NOT_RUN.

## Real signed-candidate gate preparation — 4 November 2026

- **DESIGN DECISION:** a private review-only packet binds the retained candidate,
  request/original scope/source and committed adapter, exact runtime/profile
  requirements and unresolved material selectors. Every approval is NOT_GRANTED;
  no file/env input becomes execution authority. Named material inspection,
  optional upstream runtime preparation, app build/key use/secure timestamps,
  original-Mac/loaded-child checks, notarization and guest acceptance are distinct.
- **VERIFIED — read-only local:** candidate inventory/reviewed digest and frozen
  request match; canonical client/parser checkouts are clean at the archived pins.
  Local Git uses no fetch/hooks/fsmonitor or optional index writes. No root/registry
  observation, pin recapture, SDK/signing command, credential access, Apple/network,
  SSH/Ansible, install, UI, disk or guest operation. Adapter/shared/product source
  and its 91-test evidence remain unchanged; actual pins and packet stay private.
- **PRIVATE COUPLING:** runtime consumption needs the signed variant of the exact
  frozen development kit, sharing the selected app team and immutable origin/
  payload. A missing runtime needs separate upstream preparation; its signer lacks
  an explicit keychain selector. The ordinary release wrapper couples credentials,
  notarization and publication and must not be used unchanged for this gate.
- **TO PROVE:** no real runtime/team/identity/keychain/profile path is selected or
  inspected. Real material binding/trusted caller, compiler/SDK/profile/signature,
  notarization/original-Mac/loaded-child and all guest rows remain unproven. See the
  [gate](docs/DevVMMilestone6Runbook.md#real-signed-candidate-gate-preparation--4-november-2026).

## Matching local signed-runtime discovery — 4 November 2026

- **VERIFIED — local data:** existing published `v0.9.4-dev.1` runtime in the primary
  checkout matches the frozen origin/payload, ZIP digest/inventory and three
  extracted bundle inventories. Newer candidate origins differ. Matching nonsecret
  bundle/ZIP/lock files are copied privately into the adapter layout and checked
  again; original artifacts/gate/request/scope and product source stay unchanged.
- **PRIVATE COUPLING:** identity/team derive from an existing helper's public CMS
  certificate, locally parsed without Keychain/signing/trust access. Profile paths
  are observed by metadata only; matching public source pins do not validate their
  unopened bytes. Exact selectors, paths and hashes remain in an ignored addendum.
- **DESIGN DECISION / TO PROVE:** no keychain is selected or queried, no key
  availability established, and all approvals remain NOT_GRANTED. Named material
  validation/private profile staging need separate approval; real app signing/
  timestamps and later gates remain separate. No credentials, SDK/signing tools,
  Apple/network, SSH/Ansible, installs, UI, image or VM operation. Product approval
  remains nil and guest rows NOT_RUN. See the
  [discovery](docs/DevVMMilestone6Runbook.md#local-signed-runtime-discovery--4-november-2026).

## Latest main merged into provisioning — 4 November 2026

- **USER AUTHORIZATION / DESIGN DECISION:** merge latest main into the provisioning
  branch and resolve integration conflicts with offline/fake validation only.
  Credential-free HTTPS confirms main `741be20`; no SSH transport or credential
  helper is used. Preserve both validation histories and their VERIFIED/DESIGN
  DECISION/PRIVATE COUPLING/TO PROVE distinctions.
- **IMPLEMENTED:** retain Setup and default-off guest Touch ID in CLI parsing,
  creation and profile coding; carry Touch ID through the reviewed New VM save
  path; retain loading/cancellation behavior and isolated fake initialization.
  Packaging preserves release metadata while staging/sealing provisioning helpers.
  Ordinary runtime/configuration pins follow main; private frozen inputs do not.
- **VERIFIED — offline/fake:** debug build passes, 300 selected Swift tests are
  covered, including the combined Touch ID/Setup creation and profile roundtrip
  regression. Eleven socket functions initially hit sandbox restrictions and pass
  when rerun with disposable local channels outside that sandbox. Python discovery
  runs 114 tests: 109 pass, five software-signing/PKCS12 cases are deliberately
  skipped. A process audit records no forbidden tool invocation. Offscreen Setup/
  New VM acceptance passes 100 checks with zero runtime starts or visible windows.
  Native SSH, ad-hoc signed-bundle and real signing/credential suites are excluded.
  Release and `SIGNED_PRERELEASE` compile-policy checks also pass (two tests per
  mode); sandbox-blocked SDK dSYM generation is retried outside the tool sandbox.
  These compile modes invoke no signing tool or identity.
- **PRIVATE COUPLING / VERIFIED:** all 930 private artifact entries retain their
  exact bytes, modes and symlink targets. The original candidate, source archive/
  overlay, request/gate, scope pins and staged runtime remain unchanged/ignored;
  no target VM root or registry is accessed. Provisioning product approval stays nil.
- **TO PROVE:** the retained candidate represents pre-merge source. Any candidate
  for this integrated tree needs a separately frozen/reviewed source and runtime
  origin; never relabel the old request or recapture scope pins implicitly. No
  signing, credentials, Apple requests, SSH/Ansible, installs, normal UI, image or
  VM operation is authorized or performed by this integration. Real provisioning
  and signing/loaded-child acceptance remain unproven.

## Integrated candidate input preparation — 4 November 2026

- **USER AUTHORIZATION / DESIGN DECISION:** prepare private source/runtime inputs
  and a signing review gate for `7e46241` using offline/fake checks. Freeze the new
  source independently while preserving original scope JSON, historical source
  commit, UUID/root/device/inode/marker pins, receipt and scope-definition source
  verbatim. No old artifact or request is rewritten and no root is recaptured.
- **VERIFIED — local data:** dev.3's retained signed runtime declares dev.2 and
  matches the integrated development origin/capabilities/immutable payload. Both
  archives and extracted/staged bundle inventories match. The six-file overlay
  reconstructs exactly against a second source archive. Twenty-two input/refusal
  checks and all twelve fake signer tests pass without external process/network
  calls in the input checks. Exact paths/pins and all new artifacts remain private.
- **PRIVATE COUPLING:** the older app-based handoff requires source commit equality
  with the historical scope commit. This source-only record binds those separately
  and is refused by that signer before authorization/material IO. It supplies no
  fabricated app inventory, legacy request or executable authority. A reviewed
  versioned source-only admission/caller update is still required.
- **TO PROVE:** actual app compilation, named profile/keychain validation, genuine
  signatures/notarization/loaded-child and all guest rows. No app, profile bytes,
  credentials, signing, Apple/network, SSH/Ansible, installs, image, UI or guest
  operation; product approval remains nil and all later approvals NOT_GRANTED.
  See the [input gate](docs/DevVMMilestone6Runbook.md#integrated-candidate-inputs-for-7e46241--4-november-2026).

## Versioned source-only admission/caller — 4 November 2026

- **DESIGN DECISION:** explicit version-2 admission consumes unchanged source-only
  packets. Typed in-memory review binds new source/archive/overlay independently
  of original scope bytes/semantic hash/definition and prior request, plus packet,
  team and fixture mode. Its request digest cannot alias legacy/packet digests.
  Gate files/env/sidecars confer no authority. Legacy admission is separate.
- **PRIVATE COUPLING:** immutable source/runtime/lineage and resource/archive
  checks, exact reconstructed source/definition, callback re-admission and selected
  runtime/team binding feed the existing adapter. The typed caller is atomically
  one-shot and default-denied before material IO/output; no signing CLI, automatic
  retry, credential import or publication path is added.
- **VERIFIED — fake/local:** eighteen new tests, including full fake adapter/ZIP
  roundtrip and concurrent replay refusal; 127 allowed Python passes/five signing
  skips (132 discovered), without a forbidden process attempt. Actual frozen
  `7e46241` inputs admit as data only with external process/network hooks blocked.
  All 1,161 retained private entries are unchanged. Evidence is separate/private;
  no real runner authorization is created for that packet.
- **TO PROVE:** named material selection/validation and authorized compiler/SDK/
  signing/profile/loaded-child/original-Mac and guest behavior. No credentials or
  profile bytes, signing, Apple requests, SSH/Ansible, installs, app/UI, image or VM
  operation. Shared/product source and pins are unchanged, provisioning approval
  stays nil and real guest rows NOT_RUN. See the
  [caller](docs/DevVMMilestone6Runbook.md#version-2-source-only-admission-and-caller--4-november-2026).

## Named material inspection and staging — 4 November 2026

- **DESIGN DECISION:** an explicit typed one-shot caller has its own inspection
  request digest, binding source review, named material selectors, public-leaf and
  trusted runtime-inspector hashes, and private staging path. Default denial and
  inspect-only native authorization precede material IO/output. Gate/env/file
  claims and signing authorization do not authorize this step; fixtures cannot
  execute native inspectors. There is no CLI or automatic signing continuation.
- **PRIVATE COUPLING:** profile/certificate staging, profile scope/expiry and
  public-leaf membership/name/dates, dependency revisions/cleanliness and admitted
  runtime inspection are checked with callback revalidation. Named keychain
  metadata is checked in memory; contents, identity searches, key availability and
  locked state are never queried. Public-certificate parsing does not prove trust.
  Returned staged material changes its binding and still needs separate signing
  authorization. Receipts grant neither signing nor guest authority.
- **VERIFIED — fake/local:** 19 new tests; 146 allowed Python passes/five deliberate
  signing/PKCS12 skips (151 discovered). Audit records only local Git/Python, with
  no forbidden-tool attempt. All 1,161 retained private entries and pins remain
  unchanged. New evidence stays separate/private; shared/product source and pins
  are unchanged and ordinary provisioning approval stays nil.
- **TO PROVE:** actual material selection and separately approved bounded real
  inspection, private-key availability, compiler/signatures/profile trust/loaded
  child, original-Mac scope and guests. No real profile/certificate parser, SDK/CMS,
  keychain, signing, credentials, Apple requests, SSH/Ansible, installs, UI, image or
  VM operation occurs. See the
  [inspection gate](docs/DevVMMilestone6Runbook.md#named-material-inspection-and-private-staging--4-november-2026).

## Bounded native inspection — source review, 4 November 2026

- **VERIFIED — source only:** the verifier's signature-only option still invokes
  the daemon with exact `check`. `locate`/payload hashes/static client requirement
  return before privileged listener/session/subprocess operations. The client's
  XPC check is different. No daemon or native validator is executed by this review.
- **PRIVATE COUPLING:** generated relative paths, signed-payload hashes and client
  CDHash bind the daemon to its bundle. Source origin/inventories do not prove
  observed signed-binary behavior. Default validation flags do not explicitly opt
  into network access, but source review is not a network-silence guarantee.
- **DESIGN DECISION — proposed:** a distinct offline inspection adapter/request
  must set `kSecCSNoNetworkAccess`, decode CMS content without signer trust
  evaluation and keep the keychain locked and runtime code unexecuted. Bound all
  inputs/output and the future implementation; require 300-second job/120-second
  stage deadlines, live 2 MiB stream caps, bounded inventories and kill/reap on
  failure. Current output checks occur after capture and are not a live disk cap.
  Preserve frozen daemon/runtime bytes; do not silently reuse existing authority.
- **TO PROVE:** offline adapter/fake API and runner checks, then separately approved
  real native inspection. No native verifier, profile/signature/trust API, build, signing,
  Apple request, SSH/Ansible, install, UI or guest operation occurs in this source
  review. Exact source/SDK evidence and proposed contract remain private; product
  approval and frozen pins stay unchanged. See the
  [prepared contract](docs/DevVMMilestone6Runbook.md#bounded-native-inspection-preparation--source-review-4-november-2026).

## Offline inspection adapter — fake APIs/workers, 4 November 2026

- **DESIGN DECISION / IMPLEMENTED:** a distinct typed one-shot review/authorization
  binds source/scope/selection, public certificate, implementation, entitlement
  sources and output, requiring only `offline-native-inspect`. Default denial
  precedes IO; file/env/legacy approvals cannot grant authority. No native binding,
  real process factory, loader or activation CLI is supplied.
- **PRIVATE COUPLING:** strict signedData/plist guards precede CMS APIs; API worker
  disables interaction, requires locked status and releases references. Every
  Mach-O/bundle uses explicit no-network static validation with exact signing
  policy; no daemon/runtime executes. The injected supervisor monitors a shared
  300-second budget, 120-second stage and live 2 MiB stream caps; group cleanup,
  callback binding checks and one-shot refusal retain private fixed failures.
  Parent filesystem reads are budget-checked at callback boundaries. Concrete
  factories must provide prompt atomic handoff/nonblocking reads/bounded waits.
- **VERIFIED — fake/local:** 32 new tests, 178 allowed Python passes/five signing
  skips (183 discovered), with only Git/Python processes and no forbidden-tool
  attempt. Native calls/processes/network are blocked in the new fixtures. All
  1,161 retained private artifact entries and frozen pins stay unchanged; shared
  package/product code and ordinary approval remain unchanged.
- **TO PROVE:** concrete API/factory composition with fake FFI and process tests,
  then separately approved native validation, OS cleanup/IO and key/signature/
  guest evidence. No real material/keychain inspection, signing, Apple request,
  SSH/Ansible, install, UI, image or VM operation occurs; fake receipts grant no
  signing/guest authority. See the
  [adapter](docs/DevVMMilestone6Runbook.md#offline-inspection-adapter--fake-apisworkers-4-november-2026).

## Concrete macOS inspection bindings — 4 November 2026

- **DESIGN DECISION / IMPLEMENTED:** concrete lazy offline API and process factory
  remain explicitly composed, default-denied and bound to typed authority/current
  implementation. Closed symbols omit SecTrust/CMS signer-status, identity/key and signing APIs.
  Anonymous capability/task pipes bind parent, task, code and fake/native mode;
  no file/env approval loader or automatic native activation is added.
- **PRIVATE COUPLING:** SDK ctypes prototypes, CF ownership/type checks, explicit
  no-network validity, certified timestamp metadata, isolated worker environment,
  nonblocking IO and unreaped root/group ownership are enforced. Darwin waitid
  supports system Python without that wrapper; bounded proc_listpids queries
  require the held root. Unconfirmed cleanup retains handles and blocks launches.
  Filter-free Git metadata plus raw index/worktree checks avoid clean-filter
  execution. New code joins the implementation digest; old reviews stay stale.
- **VERIFIED — fake FFI/process only:** 33 new tests and 211 allowed Python passes /
  five signing skips (216 discovered), only Git/Python programs and no forbidden
  tool/inspection-library attempt. A synthetic roundtrip uses concrete wrappers
  and launcher with fake primitives. All 1,161 retained private entries and prior
  reviews stay unchanged; no actual material/keychain/native inspection occurs.
- **TO PROVE:** fresh exact-implementation review and native approval; real API/ABI,
  root/group visibility, scheduling, cleanup/crash and validation results. Source
  coupling is not observed OS behavior or signer/key/notarization/guest proof.
  No signing, Apple request, SSH/Ansible, install, UI, image or VM operation occurs;
  shared/product source and ordinary approval stay unchanged. See the
  [binding contract](docs/DevVMMilestone6Runbook.md#macos-bindings-and-bounded-launcher--fake-ffiprocesses-4-november-2026).

## Fresh ddf5451 inspection review — 4 November 2026

- **DESIGN DECISION / PREPARED:** a fresh ignored 0700/0600 review binds committed
  tooling, 14-file implementation, existing source/scope/selection/runtime, public
  leaf/entitlement hashes and an uncreated output. Historical pins/records stay
  unchanged. Typed data supplies no authority; all approvals are false and no
  authorization/caller/runner/factory/capability/native API is constructed.
- **VERIFIED — stored evidence only:** source bytes match the commit and retained
  fake-test evidence; pure source admission, dependency HEADs and entitlement
  hashes match. External material/keychain state and whole source cleanliness are
  not refreshed. Original 1,161 entries stay in place; noncredential hashes and
  prior review checksums match. A credential-named artifact remains unopened,
  with stored digest/stable metadata rather than a fresh content claim.
- **PRIVATE COUPLING:** exact selectors, hashes, original scope lineage and prior
  lock/material observations remain in the private packet. VM-root identity is
  not recaptured and old gates are not promoted. Product approval remains nil.
- **TO PROVE:** separate exact-review native approval, fresh execution-time input /
  locked-state checks and all native/signing/key/guest evidence. No tests, native
  inspection, signing, Apple request, SSH/Ansible, install, UI or VM operation
  occurs in preparation. See the
  [private review](docs/DevVMMilestone6Runbook.md#fresh-private-inspection-review-for-ddf5451--4-november-2026).

## Approved inspection pre-native stop — 5 November 2026

- **USER AUTHORIZATION:** bounded read-only native inspection of the exact
  `ddf5451` review; signing, private-key access, Apple requests, SSH/Ansible,
  installs and VM launches remain excluded.
- **VERIFIED — source/data only:** the one-off extra audit guard incorrectly
  rejects Python's `/dev/null` `O_RDWR` open for disabled Git stdin. The attempt
  stops before any subprocess, worker, typed native authorization/caller, API or
  external signing-material access. Output is absent; cleanup has no pending
  handles. Review checksums match and all 1,161 old artifact entries remain
  present; noncredential bytes/modes/links match. Credential-named retained
  content remains unopened and is not freshly validated.
- **DESIGN DECISION / PRIVATE COUPLING:** consume the attempt without automatic
  retry. Private evidence retains the failed composition and source reproduction;
  ten fake audit-event cases cover an unused, narrowly scoped `/dev/null` guard
  correction. Frozen pins, source implementation and product approval stay
  unchanged. No prohibited operation occurs.
- **TO PROVE:** corrected fresh review and separate approval, then actual native
  material/signature and OS worker behavior. No real inspection result is claimed.
  See the [attempt record](docs/DevVMMilestone6Runbook.md#approved-inspection-attempt-stopped-before-native-work--5-november-2026).

## Corrected fresh inspection review — 5 November 2026

- **DESIGN DECISION / PREPARED:** a new private 0700/0600 packet binds a fresh
  request/output and corrected guard to unchanged `ddf5451` implementation and
  source/scope/material/runtime inputs. Only a literal `/dev/null` `O_RDWR` open
  with optional `O_CLOEXEC` is newly allowed. The guard defines functions only;
  exact guard/review hashes are bound separately. No prior approval is reused.
- **VERIFIED — data/fake only:** 22 audit/helper cases pass without real file or
  process effects in those cases. Fourteen source files match the commit; pure
  admission, dependency HEADs and entitlement hashes match pins. All 1,170
  preexisting private artifact entries, original review, failed attempt and old
  consumed marker are preserved. Credential-named content remains unopened;
  metadata stability is not a fresh byte claim. External material/keychain state
  and whole dependency cleanliness are not refreshed.
- **PRIVATE COUPLING / TO PROVE:** fresh exact-review/guard approval is required
  before typed authority and bounded native work. All new approvals are false,
  both outputs absent and no guard, authorization, caller, runner, factory or API
  activated. Frozen pins and product approval stay unchanged. No real inspection,
  signing, private-key access, Apple request, SSH/Ansible, install, UI or VM
  operation occurs. See the
  [corrected review](docs/DevVMMilestone6Runbook.md#corrected-fresh-private-inspection-review--5-november-2026).

## Corrected native inspection partial result — 5 November 2026

- **USER AUTHORIZATION:** execute the corrected review, analyze results, check
  cleanup and document both worktrees; exclude signing, private-key access, Apple
  requests, SSH/Ansible, installs and VM launches. No retry is authorized.
- **VERIFIED — native partial:** exact guard/review/composition and 14-file source
  bindings match. Both dependency checks, locked keychain status, profile content,
  policy/expiry and public-leaf membership pass. Five workers run; certificate
  parsing fails with a generic worker error after about 12 seconds. Its actual
  native cause is unknown. Runtime signatures and final checks are not reached.
- **VERIFIED — cleanup limits:** runner cleanup remains false, factory unresolved
  handles zero. A bounded exact-parent/worker snapshot finds no survivors, with
  its own process reaped and raw host arguments discarded. The sandbox initially
  blocks that cleanup-only command; it completes outside the sandbox. This does
  not retry inspection or repair the failed cleanup receipt.
- **PRIVATE COUPLING / VERIFIED:** all 1,182 old artifact entries and pins remain
  unchanged; retained credential content is unopened with stable metadata. Only
  planned private output/staged public files/failure evidence are added. Five
  fake cases reproduce possible certificate-type and cleanup-error shapes; SDK
  source offers typed macOS 15 certificate date getters. No actual failure cause
  is inferred from those fixtures. Source implementation/product approval stay
  unchanged and the consumed request is not reused.
- **TO PROVE / NEXT:** combine fixed worker diagnostics, per-handle cleanup
  evidence and typed dates into one fake-only change with validation/fresh review;
  separately approve any later native run. No successful certificate/runtime
  inspection, signer trust, key possession, signing or guest proof is claimed.
  No prohibited operation occurs. See the
  [result record](docs/DevVMMilestone6Runbook.md#corrected-native-inspection-result--5-november-2026).

## Inspection diagnostics, cleanup evidence and typed dates — 5 November 2026

- **USER AUTHORIZATION / IMPLEMENTED:** after committing the partial-result docs,
  implement closed mode-proven worker failure diagnostics, per-worker cleanup and
  handle evidence, and macOS 15 typed certificate dates with fake tests and fresh
  review. No native inspection is authorized for this change.
- **DESIGN DECISION:** diagnostics serialize only fixed allowlisted code/phase,
  never raw exception/stderr/subject/path data. Keep cleanup errors latched false
  while recording final reap/quiet/descriptor facts separately. Skip signalling
  only after observing held-root exit and quiet group; retain wait/group recheck
  before reap and kill/reap for live/unproven groups. Bound workers/evidence at
  4,112. Typed retained CFDate getters replace generic certificate-property values;
  enforce null/type/finite/order checks and release all partial references.
- **VERIFIED — fake/local:** twelve new tests; full suite 223 allowed passes and
  five signing/PKCS12 skips (228 discovered), only Git/Python processes and no
  forbidden process/native-library attempt. Malformed/mode-mismatched diagnostics,
  date failures, cleanup timeout/permission/fallback/retention and bounds are covered.
  All 1,191 private entries, frozen pins and historical failures remain unchanged;
  credential content stays unopened with stable metadata.
- **PRIVATE COUPLING / PREPARED:** ignored 0700/0600 review binds the new 14-file
  implementation, 17-file source/test snapshot and base patch, corrected guard,
  unchanged candidate/scope/material/runtime and new request/output. Code is
  explicitly uncommitted; all new approvals are false and output absent. No real
  selected authority/caller/factory or API is activated; external material/lock
  observations remain historical and product approval remains nil.
- **TO PROVE:** previous native failure causes and actual new API/worker/cleanup
  behavior remain unknown. Separate exact-review approval precedes another native
  attempt. No signing, private-key access, Apple requests, SSH/Ansible, installs,
  UI, VM-root observation or VM operation occurs. See the
  [hardening record](docs/DevVMMilestone6Runbook.md#diagnostic-and-date-hardening--fake-validation-and-fresh-review-5-november-2026).

## Native offline inspection passed — 5 November 2026

- **USER AUTHORIZATION / VERIFIED:** commit diagnostics/date/cleanup changes
  (`df8b75e`, companion docs `a8a8ba4`), execute the exact fresh review and update
  result docs. Seventeen source/test files match the commit/current snapshot;
  original review/guard/implementation/frozen input bindings are preserved.
- **VERIFIED — bounded native:** the one-shot attempt completes in 64.18 seconds,
  with before/after dependency and locked-keychain checks, profile content/policy/
  public-leaf membership, certificate name/dates and 23 static code checks passed.
  Explicit no-network policy is used; no runtime code or daemon check executes.
  Receipt status is OFFLINE_STATIC_INSPECTION_ONLY.
- **VERIFIED — cleanup/preservation:** all 31 workers exit/reap after group quiet,
  descriptors close, no diagnostics/errors or unresolved handles remain. A bounded
  snapshot of the recorded PIDs finds no survivors and is itself reaped. All 1,204
  old artifact entries, pins, prior reviews and failed receipts remain unchanged.
  Retained credential content stays unopened with stable metadata. Only approved
  private output/evidence are added; no root pin is recaptured and product approval
  remains nil.
- **PRIVATE COUPLING / TO PROVE:** the old uncommitted-review label remains a
  historical preparation record; execution evidence separately binds the committed
  bytes. Private-key availability, CMS signer authenticity, standalone certificate
  trust, online revocation/notarization, loaded-child and guest evidence are not
  established. Prior failure causes remain unknown. Milestone 6 remains incomplete.
  No signing, private-key access, Apple request, SSH/Ansible, install, UI or VM
  operation occurs. Separate signing/guest authority is still required. See the
  [native result](docs/DevVMMilestone6Runbook.md#native-offline-inspection-passed--5-november-2026).

## Signed-candidate review preparation — 5 November 2026

- **USER AUTHORIZATION / PREPARED:** commit native-result docs (`740fd81`,
  companion `7d8d907`), then prepare a private signed-candidate review without
  signing, private-key access, Apple requests, SSH/Ansible, installs or VM launches.
  Bind the passed receipt/audit, matching staged public files/material, frozen
  source/scope/runtime, current tooling and absent private app/ZIP output.
- **VERIFIED — local data/source:** pure admission and receipt/material/source
  bindings match; all 14 implementation files match committed bytes. All 1,239
  previous private entries, successful/failed evidence and pins remain unchanged.
  Retained credential content stays unopened with stable metadata; original
  signing materials/keychain are not reopened or stat-checked. Earlier lock/
  certificate observations remain historical and no scope root is recaptured.
- **DESIGN DECISION / READINESS GAPS:** review-domain data grants no authority.
  Before execution, bind receipt/implementation/output in signing admission,
  provide live caps/shared deadline/owned cleanup, and replace or separately
  review the legacy profile/daemon-verifier dispatch. Proposed limits are not
  current signer capabilities. Keep all new approvals NOT_GRANTED and output
  absent; no runner/caller/signer/authorization is constructed.
- **PRIVATE COUPLING / TO PROVE:** the selected keychain was locked; actual key
  availability remains unqueried. Key use/necessary secure UI and Apple timestamp
  consent remain separate. Prefer Touch ID only where existing ACLs support it;
  infer no unlock/permission/search-list changes. Notarization, original-Mac/
  loaded-child and guest acceptance remain outside scope. Next combine admission,
  runner/inspection hardening, fake tests and fresh review. No native inspection,
  compiler, signing or prohibited operation occurs; product approval remains nil.
  See the [review](docs/DevVMMilestone6Runbook.md#signed-candidate-review-after-offline-inspection--5-november-2026).

## Receipt-bound signing implementation — 5 November 2026

- **USER AUTHORIZATION / IMPLEMENTED:** commit review docs (`e8c6c1c`, companion
  `0bc6f31`), then implement receipt-bound admission, bounded supervision and
  legacy-verifier replacement using fake tests and fresh review only.
- **DESIGN DECISION:** typed one-shot authority binds exact historical inspection
  receipt/implementation, source/scope, staged public material, current code,
  output and fixture/native mode. Default denial precedes material/output IO;
  all five build/inspect/key-use/secure-key-UI/Apple-timestamp effects are required.
  Historical proof is not rewritten when tooling changes. Old real entry points
  are disabled. New verification uses guarded profile data and capability workers
  with explicit no-network flags/closed identities and public leaf/CDHash checks;
  no legacy daemon, app execution or default-network verifier is used.
- **DESIGN DECISION / PRIVATE COUPLING:** share a 2,400-second job deadline,
  1,200-second build / 120-second other stages, live 2 MiB streams and held-group
  kill/reap/descriptor evidence. Retain unresolved handles and latched cleanup
  errors. Exact command/environment policy rejects original checkout mutation,
  extra build flags, credentials and arbitrary programs. Parent IO remains
  budget-checked at callbacks. Operator keychain preparation/relock stays explicit;
  no unlock/import/ACL/search-list workflow is added.
- **VERIFIED — fake/local:** twenty new tests; full 243 allowed Python passes and
  five signing skips (248 discovered), only Git/Python and no forbidden process/
  native-library attempt. Concrete command/FFI/capability roundtrip, malformed and
  stale bindings, mode/domain/replay, mutation, resource limits and cleanup/error
  paths pass. All 1,251 original private entries/pins and historical evidence
  remain unchanged; interim preparation artifacts are retained. Credential content
  stays unopened and external original materials/keychain are not refreshed.
- **PREPARED / TO PROVE:** fresh ignored review binds sixteen implementation files
  and a 24-file source/test/Makefile archive/patch; code is explicitly uncommitted.
  All execution approvals are ungranted and output absent. No real selected
  authority/native API/signer is activated. Real compiler/signing/OS/chain behavior,
  prior failure causes, notarization/original-Mac/loaded-child and guest acceptance
  remain unproven. No real inspection, signing, private-key access, Apple request,
  SSH/Ansible, install, UI, VM-root observation/recapture or VM operation occurs;
  product approval stays nil. See the
  [implemented path](docs/DevVMMilestone6Runbook.md#receipt-bound-signing-path--fake-tests-and-fresh-review-5-november-2026).

## First private candidate attempt — 5 November 2026

- **USER AUTHORIZATION:** execute the exact reviewed build/sign/verify flow after
  commits `27c672f` / companion `92593c9`, including selected-key use, existing
  secure key UI and Apple timestamps. No notarization, SSH/Ansible, installs or
  VM launch is authorized. Snapshot/current code and frozen bindings match.
- **VERIFIED — partial:** source/receipt/material admission, public certificate,
  overlay check/apply and pinned dependency copies/checkouts pass. At 125.283
  seconds, the frozen provisioning-source helper exits 1, before Swift compilation,
  runtime static validation, app assembly or signing. No selected key, secure UI
  or timestamp request is used. There is no app/archive or success receipt.
- **VERIFIED — cleanup/preservation:** nine command roots and three validation
  workers are reaped after group quietness with closed descriptors and no pending
  handles. A bounded snapshot finds none of those PIDs remaining. All 1,279 old
  private artifact entries, pins, reviews and receipts remain unchanged; retained
  credential content stays unopened with stable metadata. Only approved partial
  output/private failure evidence is added. Keychain state is not refreshed or
  changed, no VM-root pin is recaptured and product approval stays nil.
- **PRIVATE COUPLING / DIAGNOSIS LIMIT:** fixed evidence retains exit 1 and
  0 stdout / 278 stderr bytes, not raw error text; actual cause remains unknown.
  Read-only package/source/patch/mode/syntax checks pass without replay. The old
  command double skips the actual provisioning preparation behavior.
- **TO PROVE / NEXT:** request consumed, no retry or approval transfer. Consolidate
  frozen-helper fake/local-fixture regression, bounded fixed command diagnostics
  and fresh review. No actual compiler/signing/key/UI/timestamp or later candidate/
  notarization/loaded-child/guest proof is established. No prohibited operation
  occurs. See the [attempt](docs/DevVMMilestone6Runbook.md#first-reviewed-candidate-attempt--preparation-stop-5-november-2026).

## Frozen-helper fixtures and diagnostics — 5 November 2026

- **USER AUTHORIZATION / IMPLEMENTED:** commit failure-result docs in both
  worktrees (`d3d70ab`, companion `09b396b`), then add frozen-helper coverage,
  safe diagnostics and fresh review. No real execution is authorized here.
- **VERIFIED — local fixtures:** the byte-exact helper with unchanged public pins
  reproduces nested ignored-checkout patch-base mismatch. An exact private-output
  Git discovery ceiling fixes that case while preserving cloned repositories.
  Mutation/plugin/extra-input refusals and idempotence pass. Thirteen new cases;
  full audited Python suite: 256 passes, five signing skips, only Git/Python child
  programs and no native-library attempt. Swift/shared implementation is unchanged.
- **DESIGN DECISION / PRIVATE COUPLING:** hold failed quiet roots and drain under
  existing live caps/deadlines to EOF. Record only fixed phase/code/complete facts;
  exact final allowlisted helper lines cannot leak arbitrary output. Partial/capped
  output remains incomplete. Keep original group/cleanup retention guarantees.
  Bind the diagnostic module in the current implementation digest.
- **PREPARED / TO PROVE:** new unexecuted review binds seventeen code files and an
  exact 28-file uncommitted snapshot; historical inspection is independently bound,
  all execution effects ungranted and new output absent. Preserve all 3,987 old
  artifact entries, failed output and frozen pins; credential content unopened,
  external materials/keychain unqueried, no scope-root observation/recapture and
  product approval nil. Historical exact failure cause stays unknown. No real
  inspection, build, signing, key access, Apple request, SSH/Ansible, install, UI or
  VM operation occurs. Real compiler/native/signing/candidate/guest behavior remains
  unproven. See the [fresh review](docs/DevVMMilestone6Runbook.md#frozen-helper-and-safe-failure-diagnostics--5-november-2026).

## Maintained private signing operator — 5 November 2026

- **USER AUTHORIZATION / DESIGN DECISION:** add a maintained developer CLI in this
  worktree for prepare/check/run. Plan files are nonauthorizing data; execution
  requires fresh exact-plan confirmation from a controlling terminal. No saved
  grant, environment/yes flag, automatic unlock/import or retry is supported.
- **PRIVATE COUPLING:** reuse the existing typed receipt-bound engine and its
  disposable source/scope, runtime, command, native-worker and cleanup restrictions.
  Bind this wrapper independently without changing the engine implementation-file
  list or invalidating an already-running reviewed attempt. Existing reviews,
  artifacts and pins are not rewritten or recaptured. A durable exclusive consumed
  marker precedes backend construction; uncertainty retains original handles.
- **VERIFIED — fake/local / TO PROVE — native:** use disposable public-input fixtures
  and injected command/FFI doubles, including a full fake roundtrip. No existing
  real selection, keychain, native API, signer or VM is operated for this task.
  Real terminal/key/UI/timestamp and later candidate/guest behavior remain unproven
  for this new entry point. See [operator usage](docs/PrivateLocalSigning.md).

## Fresh private candidate — resource assembly refusal, 5 November 2026

- **USER AUTHORIZATION:** execute the fresh reviewed private run after manager
  `31f0bd7` / companion `3a7285b`, including selected key, secure UI and timestamps;
  no notarization, SSH/Ansible, installs or VM launches. The 28 reviewed files and
  seventeen-file implementation match at preflight; no prior approval is reused.
- **VERIFIED — partial:** frozen-helper preparation, 23 runtime static checks,
  public certificate/dependency checks, release compilation and binary/scope-marker
  checks pass. Twelve commands and thirty native workers succeed. Assembly stops
  at 447.472 seconds with `input-inventory-changed`: compiled provisioning payload
  matches but lacks the four signature records in the frozen resource reference.
  Core resources copy exactly; no signature or frozen inventory is altered.
- **VERIFIED — cleanup/preservation:** all 42 roots/workers reap after group
  quietness with closed descriptors/no pending handles; a bounded recorded-PID
  snapshot finds none remaining. All 4,002 old artifact entries/pins are unchanged.
  Credential content stays unopened, external keychain admission is metadata-only,
  lock state is not re-queried and no scope root/pin is observed/recaptured.
  Partial output is preserved; concurrent unrelated CLI edits are left intact.
- **DESIGN DECISION / TO PROVE:** parent inventory refusal consumes the request;
  no retry or approval transfer. No signing/key/UI/timestamp stage, success receipt
  or signed archive is reached; product approval stays nil. No notarization,
  SSH/Ansible, install, app/runtime execution or VM operation occurs. Next add
  compiled-vs-frozen resource/signature fixtures, narrow assembly/final-seal
  admission and fresh review, preserving generic inventory checks and frozen pins.
  Real signing/candidate/guest evidence remains unproven. See the
  [result](docs/DevVMMilestone6Runbook.md#fresh-candidate-attempt--compiled-resource-assembly-stop-5-november-2026).

## Resource payload and inherited signature policy — 5 November 2026

- **USER AUTHORIZATION / IMPLEMENTED:** commit result docs in both worktrees
  (`12247e2`, companion `ff2c82d`), add resource/signature fixtures, fix assembly
  admission and prepare a fresh review. No real inspection or signing authorized.
- **DESIGN DECISION:** full frozen reference remains pinned. Derive a payload only
  by excluding its complete four known inherited detached signature records (or
  accept an unsigned reference); reject partial/unknown/nested blocks. Resource
  bytes independently match the package lock, remaining wrapper/resource inventory
  matches build output exactly, and built/output signatures are never filtered.
  Generic inventory/copy rules remain unchanged; revalidate around copying.
- **DESIGN DECISION:** recheck admitted payload before outer signing and during
  staged/roundtrip verification, retaining child digest seal, outer seal/static
  checks and archive equality. Inherited signature bytes are not current proof.
- **VERIFIED — fake/local:** fourteen new tests; 291 full Python passes, five
  signing/PKCS12 skips, only local Git/Python and no native-library attempt. Receipt/
  operator flows use signed references and unsigned fake resources. The retained
  build's 45 payload files compare exactly to the unchanged 49-file frozen bundle.
- **PREPARED / TO PROVE:** fresh private review binds seventeen engine files plus
  separate operator code and a 32-file exact uncommitted snapshot. Maintained
  prepare/check yields a new public-input-only plan; no authority/backend, candidate
  output or consumed marker, all five effects ungranted. All 8,691 old entries/pins,
  failed outputs/audits/markers are preserved; credential content unopened, original
  materials/keychain not opened/stat-checked, no VM-root observation or scope-pin
  recapture and product approval nil. No real inspection/signing/key/Apple/SSH/
  Ansible/install/UI/app/runtime/VM action occurs. Commit before a separately
  approved new run; real final signature/resource-chain/candidate/guest behavior
  remains unproven. See the [fresh review](docs/DevVMMilestone6Runbook.md#resource-payload-admission--fake-fixtures-and-fresh-review-5-november-2026).

## Maintained operator signing attempt — 5 November 2026

**LATEST USER CLARIFICATION:** the operator says “I missed the prompt.” This
supports a missed secure-UI response as the explanation for the signing timeout;
it does not independently prove key use or timestamp success/failure. Keep the
earlier completed-dialog report and automated evidence as historical records;
exact dialog type/timing is not reconstructed. The plan remains consumed.

- **USER-REPORTED FOLLOW-UP:** the operator reports completing a macOS secure-key/
  keychain dialog. Dialog type and timing relative to the timeout remain unknown;
  actual key use, timestamps and wait cause stay TO PROVE. The separate private
  observation supplements, rather than rewrites, automated evidence. No retry,
  native/key operation or new approval follows from this report.

- **USER AUTHORIZATION:** fresh operator-plan build/sign/verify after manager
  `b3171b0` / companion `9d3b4b6`, including selected key, secure UI and timestamps;
  no notarization, SSH/Ansible, installs or VM launch. The exact 32-file snapshot,
  engine/operator and plan bindings pass. Maintained CLI exact-plan confirmation
  uses a real terminal; durable consumption precedes the default backend.
- **VERIFIED — partial:** frozen preparation, 23 runtime static checks, public
  certificate/dependency checks, release compilation and scope/binary checks pass.
  Assembly now admits the exact 45-file payload, retaining the 49-file reference.
  First child signing hits its 120-second limit; root/group is killed and reaped
  (-9). Audited elapsed 715.494 seconds; CLI exit 1 and plan consumed/no retry.
- **VERIFIED — cleanup/preservation:** all 43 roots/workers reap after group
  quietness, descriptors closed, no pending handles and no recorded-PID survivors.
  All 8,713 previous private entries/pins/reviews/audits are unchanged. Failed
  output and consumed/attempt evidence remain private. Retained credential content
  is unopened; selected keychain admission is metadata-only and lock state unqueried.
  No orchestrator unlock/relock/import/export/enumeration/ACL/search-list changes,
  scope-root observation/recapture or product approval change occurs.
- **PRIVATE COUPLING / TO PROVE:** observed stderr 274 bytes is incomplete, raw
  output unretained. Storage-helper bytes match compiled input, but actual key use,
  secure UI display/response and timestamp outcome cannot be established. Do not
  infer secure-UI versus Apple waiting. Other signing, final validation/seal/archive
  and success receipt are not reached. No notarization/SSH/Ansible/install/app/
  runtime/VM action occurs. Next collect operator observations/review key readiness
  and timestamp connectivity before a new plan and fresh explicit approval. No
  post-failure native/key operation or retry is performed. See the
  [result](docs/DevVMMilestone6Runbook.md#first-maintained-operator-run--signing-timeout-5-november-2026).

## Read-only keychain/public readiness — 5 November 2026

- **USER AUTHORIZATION / REPORT:** commit result/observation docs (`f67c5e4`,
  companion `b260d8f`), then bounded read-only checks; the operator missed the
  prompt. No signing/private-key/Apple/SSH/Ansible/install/VM action is authorized.
- **SOURCE-BASED INFERENCE:** the signing deadline is 120 elapsed seconds and
  includes secure-UI waiting. A missed prompt is a supported, likely explanation
  for the prior timeout, not evidence of timestamp-service failure. Exact prior
  timing and actual key/timestamp outcome remain unobserved.
- **VERIFIED — bounded current state:** one network/file-write-denied worker,
  optional UI disabled, named keychain Open/GetStatus only plus staged public
  certificate metadata: status 7/unlocked before/after, selector/digest/dates and
  reviewed-profile membership/policy match. Sixteen allowed native symbols exclude
  identity/item/private-key, trust/signature and timestamp calls. It completes in
  0.218 seconds under a 15-second/4-KiB-stream bound with all references released,
  owned group quiet/reaped/descriptors closed and no recorded-PID survivor.
- **VERIFIED — preservation:** all 13,565 old artifact entries/pins/failed and
  consumed evidence remain unchanged. Keychain metadata and unlocked state stay
  as found; no unlock/relock/import/export/ACL/search-list change. No raw credential
  content, scope-root observation/recapture, production approval or source change.
- **TO PROVE:** container/public readiness does not establish private-key presence,
  association/ACL/Touch ID, signing or timestamps. No new signing/private-key/Apple/
  SSH/Ansible/install/UI/app/runtime/VM action or retry occurs. A fresh plan and
  explicit attended-run approval remain necessary. See the
  [diagnosis](docs/DevVMMilestone6Runbook.md#read-only-signing-readiness-diagnosis--5-november-2026).

## Attended private candidate signing passed — 5 November 2026

- **USER AUTHORIZATION:** fresh attended plan after `b72eadf` / companion `90e2459`,
  including selected key, existing secure UI and Apple timestamps. Maintained CLI
  real-terminal exact-plan confirmation and durable consumption precede its default
  backend; the 32 committed files and all frozen bindings match.
- **VERIFIED — signed/offline only:** seventeen commands and 46 native workers pass
  in 926.436 seconds. Four child/outer signatures and staged/roundtrip checks prove
  selected public leaf, timestamps, expected IDs/team/entitlements, hardened flags
  and six code identities. The private 172,869,773-byte ZIP matches its receipt,
  exact extracted tree/identities, child digest seal and 45-file admitted resource
  payload; the 49-file frozen reference is intact. UI type/count is not captured.
- **VERIFIED — preservation:** all 63 roots/workers group-quiet/reaped/closed, no
  pending handles and no recorded-PID survivors. All 13,570 old artifact entries/pins,
  failed output/consumed plans/audits remain unchanged. Retained credential-file
  content stays unopened; only approved selected-key signing occurs. No export/import/enumeration,
  orchestrator unlock/relock/ACL/search-list change, scope-root/pin recapture or
  product approval change. No automatic retry; the new plan stays consumed.
- **TO PROVE:** no notarization, app/daemon/runtime execution, loaded-child check,
  install, publishing, SSH/Ansible or VM launch. Original-Mac scope is pending,
  guest acceptance remains unperformed and private artifacts are not distributed.
  Further real acceptance needs separate reviewed scope and consent. See the
  [signed result](docs/DevVMMilestone6Runbook.md#attended-private-signing-passed--5-november-2026).

## Guest home backup — 4 November 2026

**USER REQUEST / DESIGN DECISION:** add an explicit Home-page backup action for the running guest owner's home to its available host share. This narrowly extends the earlier file-operation non-goal; full VM backup, snapshots, restore and account migration remain outside this feature. Require authenticated managed SSH, verified native read-write sharing and confirmation of the unencrypted export, including dotfiles and credentials. Use a unique operation directory, preserve prior files, reject unreadable/changing-file tar failures, verify gzip/tar and host output before reporting completion, and retain partial/unconfirmed output on failure. No automatic guest start, share enablement, sudo, credential retrieval, privilege installation, runtime rebuild or provenance migration. See [home backup behavior and limitations](docs/HomeBackup.md).

**DESIGN DECISION — ownership:** backup workers are bound to their VM/session and retained until completion. Cancellation, shutdown, force-stop, pause, host sleep and guest exit invalidate success; no retry or late completion can adopt another session. Quit, restart and deletion wait for retained workers. Experimental suspension is refused during backup. Runtime clients and memory/port reservations still follow matching `.exited`; neither backup completion nor `.error` releases them.

**PRIVATE COUPLING:** the fixed guest program uses the pinned managed identity executable/native 9p mount policy and existing SSH host pins, plus GNU tar/gzip, Python 3, Linux `/proc` and `renameat2(RENAME_NOREPLACE)`. The host revalidates its opted-in share and confirms a private, owned regular output file of the reported size. No cryptographic host/guest archive digest equality or snapshot consistency is claimed.

**VERIFIED — no VM:** `make test build` passes 228 Swift tests in 38 suites and 63 Python script tests. New disposable fixtures cover admission/confirmation, duplicates, cancellation and late results across shutdown/exit, retained ownership, private output/link/size/replaced-share refusal, bounded SSH output/lease/timeout behavior, hidden files/symlink handling, prior-file preservation, failed archive verification and process-group cancellation. Python archive fixtures use portable archive/publication adapters on macOS; they do not run Linux tar/9p/renameat2. An initial sandboxed full run failed existing local socket/loopback and authentication-context fixtures; the approved unsandboxed no-VM rerun passed. The final build and `git diff --check` pass. Logs remain in ignored `.build/home-backup-*` paths. Offscreen rendering of the actual panel source with synthetic state verified text/path layout; ImageRenderer does not draw its native indeterminate spinner. No live window was opened.

**TO PROVE:** real Linux/9p archive creation, ACL/xattr/sparse restoration, disk-full handling, live SSH-disconnect/process cleanup, native UI interaction and successful restoration into a fresh guest. No existing VM was contacted, launched or modified; no personal data was backed up. Installed/running apps, registry, factories, receipts, guest disks, real Keychain items, credentials and permissions were untouched. The candidate is staged separately for review, not installed or published. Real two-VM/focus/sleep/wake/crash evidence retains its previous boundaries.

**VERIFIED — separate bundle:** `.build/home-backup-review/Omarchy VM Manager.app` passes ad-hoc deep/strict signature verification, all 22 kit Mach-O signature checks, macOS 15 compatibility for 25 Mach-O images, exact pinned inventory/NAT/no-factory-image layout and bundle-only diagnostics (`hostPreflightPerformed: false`, `vmLaunchEnabled: false`). Its shipped backup program matches current source SHA-256 `0f8e94292b243fcef062cc2c4c0d432730564521f1ecfcee9fc067004509037b`. This debug candidate has no protected Touch ID Keychain entitlement; it is not a signed release or replacement for the user's running build. Evidence: `.build/home-backup-bundle.log` and `.build/home-backup-bundle-verification.log`.

## Optional persistent home disks — 4 November 2026

**USER REQUEST / DESIGN DECISION:** new VMs default to a separate sparse 64 GiB system disk and 64 GiB home disk. Both capacities and the separate-home preference are configurable through Guest Defaults, creation UI and CLI. Opting out keeps home on the single system disk; existing profiles keep their layout. Grow stopped disks independently; refuse shrink/layout conversion. The user explicitly selected creating a replacement VM with an APFS copy-on-write home clone, preserving the original VM as rollback. Copy only under the stopped source's runtime-compatible lock, never attach one writable file to both guests, retain the owner's setup snapshot and prepare fresh manager SSH identity. Protect a source from deletion until pending copies exist. See [behavior, CLI and limits](docs/HomeDisks.md).

**DESIGN DECISION — failure handling:** record the home file's device/inode and last prepared capacity; missing, replaced, unexpectedly truncated, linked or foreign files are refused without automatic repair. The guest consumes an exact blank-disk token before formatting; subsequent boots require the matching ext4 UUID and root-owned owner marker. Copy the fresh system home only on initial formatting, then mount the persistent disk after owner provisioning and before login. A failed mount blocks login. Experimental hibernation/restore is disabled for these guests until a saved-session contract verifies both disks. Runtime handle/reservation ownership and whole-root Trash rules are unchanged.

**PRIVATE COUPLING:** runtime capability `homeDiskVersion: 1`, optional typed client `homeDisk`, root-derived home path, registry schema 6 and launcher storage format 2. Extend the reviewed upstream patch and standard build-kit pipeline; do not copy the launcher into manager sources. Package 44 contains the home adapter; separately pinned 44.1 retains the lean image's native-rendering transformation. The kit supplies the same home unit and login requirements as systemd boot credentials before package upgrade (systemd 256+ required). The complete kit inventory seals these resources. Protocol 1 alone does not grant this capability. Guest/image schema-2 receipt hashes are now independent of runtime package identity; only the exact previous reviewed contract digest is accepted while its explicit guest/image subset remains identical. Unknown provenance and schema-1 exact-runtime restrictions remain refused.

**VERIFIED — source integration:** `codex/separate-home-disks` starts from already-fetched `origin/main` `741be20`, preserving integrated 0.11.0 (27) Guest Touch ID behavior and its exact remaining evidence boundaries. The older working diff remains recoverable in stash `codex-home-disks-before-latest-main`; no installed app or personal state was replaced. Combined runtime source `071c6d6c1ce164f4dd8314f69cf9498945ef8547` reconstructs from the pinned upstream base and patch. Both guest variants were built from reviewed source using the existing local Docker builder, with no factory download: standard archive SHA-256 `3d770dcb32b7e9be2065bf081b5d8d01e87354a1a2fd24302de63e25edb3ce2b`, native archive `d784fac7df8b2d7926ac467fa9a83f44613ffbe17ba0643fc1f1f35b664a88c8`. The ad-hoc debug kit passes upstream kit/signature checks and has SHA-256 `d0cde74507072682db7c4422e7c8a127125354065a087bd5d96402ca091ff022`. Prior signed runtime locks and release assets are retained; this feature has no signed release yet.

**TO PROVE:** real first boot and upgrade ordering, fail-closed login gates, owner/SSH setup, ext4 metadata/mount/growth, replacement boot with copied data, disk-full/interrupted-format recovery, concurrent guests, focus, sleep/wake and crash behavior. No real VM was launched, contacted or modified, and no factory image was downloaded. No permissions, credential access, real signing identity, installation or release publication was used. A separately authorized disposable-VM acceptance run is required; prior live evidence does not validate this new disk path.

**VERIFIED — manager and runtime fixtures:** final `make test build test-build-policies` passes 246 Swift tests in 40 suites, 78 Python script tests and both optimized launch/credential policy cases in normal release and `SIGNED_PRERELEASE` configurations. Disposable fixtures cover sparse creation, identity-bound growth/refusal, independent APFS clone writes, retained owner snapshots, pending-copy source deletion protection, defaults/schema compatibility, immutable layout, strict CLI inputs, interrupted-format tokens and early login/enrollment gates. The exact final runtime's `make patched-kit` passes 564 Swift tests in 112 suites and kit/signature checks. The full upstream no-VM suite also passed before the final managed-SSH boot-gate addition. Logs: `.build/home-disk-manager-validation.log`, `.build/home-disk-runtime-build.log`, `.build/home-disk-upstream-validation.log`. No test reads real credentials or personal guest contents.

**VERIFIED — isolated review app:** `.build/home-disk-review/Omarchy VM Manager.app` passes assembly, ad-hoc deep/strict signatures, all 22 kit Mach-O signature checks, macOS 15 compatibility for 25 Mach-O images, exact locked payload/NAT/no-factory-image layout and bundle-only diagnostics (`hostPreflightPerformed: false`, `vmLaunchEnabled: false`). Shipped runtime lock, home boot-gate resources and retained backup program match current source. Packaged CLI `--help` exposes both capacities, layout toggle and reuse UUID; `--version` returns 0.11.0. This debug review app is neither installed nor a signed release, and has no protected Touch ID Keychain entitlement. Evidence: `.build/home-disk-bundle.log`, `.build/home-disk-bundle-verification.log`, `.build/home-disk-cli-help.log`. Final tracked/staged diff checks pass; the working diff is unstaged for review.

**VERIFIED — final launcher/contracts/guest rerun:** `Scripts/upstream-make.sh test-shell test-contracts test-guest` passes on final source `071c6d6c1ce1`; log `.build/home-disk-final-launcher-validation-toolchain.log`. The optional live pinch ABI check is skipped because `QEMU_PINCH_TEST_BINARY` is unset. An initial direct `make -C` rerun bypassed the project wrapper and selected system Python 3.9, stopping on an existing test's Python 3.10 union annotation; the required-toolchain rerun passes. This was a test invocation error, not guest evidence. No further code changes followed the successful suites.

## Authorized disposable home-disk acceptance — 4 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** the user explicitly requested disposable VM testing, including replacing the system disk and proving home persistence, with existing VMs untouched. Use a new private `.build/home-disk-poc/<run UUID>/support` registry and only newly generated manager-owned VM UUIDs: a separate-home source, its replacement and a single-disk opt-out guest. Import a verified prepared factory artifact read-only into that isolated library. Test first boot, owner/SSH readiness, file/metadata fidelity, a fresh replacement root, independent home writes/rollback, both capacities and grow/reboot behavior. Use synthetic in-memory owner credentials, disabled clipboard/authentication, no host share, NAT and background launch intent. Do not change the installed manager or personal registry/defaults/disks, use a real Keychain item, grant permissions or automate the user's UI. Stop all test guests through their manager handles and confirm matching `.exited` and no remaining captured processes. Offer whole-root Trash afterward; do not remove roots automatically.

**PRIVATE COUPLING — test seam:** an internal runtime initializer accepts the existing owner-secret protocol so this opt-in test can use an in-memory synthetic vault. Production initializers keep their Keychain implementation and all launch/provenance/storage checks. `make test-home-disks` requires an explicit private approval file under a fresh run UUID; ordinary tests skip the real-VM test. Synthetic guest checks revalidate the exact VM/run SSH identity before each operation. Test evidence is private/ignored; no personal guest contents or credentials are logged.

**VERIFIED — pre-run baseline:** read-only metadata/hash receipt records three existing manager profiles and zero existing helper/QEMU processes. The isolated run has no profiles before creation. The prepared lean factory descriptor is `6b49ae727ec1865e15c90bc990bb13d46b2747012d7ac5f4ceb93b2fe245e5bf`, with raw image SHA-256 `7816326733d14d5367df810c684d1c540794240ff39d1086439a1c319c443494`; import still performs normal complete verification. No live success is claimed before observation.

**VERIFIED — defects found before replacement:** the legacy descriptor above is refused before any VM creation. A separate verified format-2 descriptor `092b66bda3e91a30a8ccd85606a4e35b0589d75d60ead52b80af3bca384297f2` for the same prepared image imports normally into a fresh test area. Its disposable source boots with package 44.1 and completes owner setup, but home mounting fails and managed SSH remains dependency-blocked. Graceful QMP power-down of that exact source records matching `Exited (0)`; all eight captured descendant process identities are absent afterward. The personal registry hash is unchanged. The failed root is preserved, without reset or Trash.

**VERIFIED — mount diagnosis / DESIGN DECISION:** read-only inspection of the stopped disposable source shows a complete ext4 home and root-owned owner marker; its journal records repeated mount-service failure and blocked managed SSH. A no-host-volume Linux container reproduces the failure of `MS_MOVE` from beneath a shared parent and verifies successful bind mounting with `nosuid,nodev` preserved. Replace the final move with a bind over `/home` followed by staging unmount; add serial-getty/console-getty requirements to both package and early boot gates. Package 45/45.1 forces an actual integration upgrade. A command failure diagnostic includes only the fixed executable basename and exit status, never arguments or data. These corrections still require a fresh live acceptance run.

**VERIFIED — corrected mount and reporting distinction:** a fresh package-45.1 disposable source completes owner setup and authenticated managed SSH. Its fixture script incorrectly treats the first `findmnt` row as the visible filesystem and fails before writing fixtures; automatic cleanup records a clean exit. A bounded, read-only diagnostic reboot of that exact completed source confirms that the active filesystem is ext4, `try-omarchy-home.service` exited successfully and the kernel mount table has the covered Btrfs mount followed by the ext4 bind. It shuts down cleanly again. No personal VM or real credential is used. Correct the test to compare the kernel-visible path device with the home block device and its verified UUID. The product's already-mounted/idempotent guard had the same `findmnt` ambiguity; package 46/46.1 uses device identity instead. A no-VM fixture verifies that an already mounted matching home performs no fsck, resize or remount. Fresh full replacement acceptance remains pending.

**VERIFIED — replacement survives; growth defect found:** package-46.1 live source checks pass on 64 GiB system/home disks. After clean shutdown, a new 80 GiB system boots with its APFS-cloned home; file hashes, hidden/nested files, symlink/hardlink structure, permissions, owner IDs, xattrs and a sparse file survive. The old system-only marker is absent, and host home-file inodes differ. Replacement-only home mutations pass. Increasing the stopped replacement to 96 GiB system/80 GiB home then exposes an ext4 resize failure, before SSH enrollment. The user observes the console failure. Graceful power-down of only that test guest records matching `Exited (0)`; both original and replacement remain preserved. No grow success is claimed for 46.1.

**VERIFIED — growth diagnosis / DESIGN DECISION:** read-only journal inspection identifies `resize2fs` status 1. A separate APFS diagnostic clone reproduces its requirement for `e2fsck -f` despite a clean quick check; forced automatic checking followed by resize grows that clone from 64 to 80 GiB. A fresh container-only ext4 fixture independently reproduces this requirement and verifies its file checksum after growth. Package 47/47.1 compares e2fsprogs filesystem capacity with the block device; only a pending increase selects `e2fsck -p -f` and then resize. Equal capacity keeps the quick check and skips resize; undersized/inconsistent device capacity is refused. No personal VM or original test disk is repaired offline. Full latest-runtime acceptance is still pending.

**VERIFIED — full latest-runtime acceptance completed:** fresh run `C38B2846-D2D3-4169-8673-52B5C9B5C033` passes `make test-home-disks` on the reviewed format-2 lean factory with native package 47.1. The default source has 64 GiB system/home disks. A replacement with a fresh 80 GiB system preserves the cloned home fixtures and lacks the source's system-only marker. Host home files have distinct inodes. Replacement-only home mutations survive normal shutdown, growth to 96 GiB system/80 GiB home and reboot; both raw device and filesystem capacities are checked. Rebooting the original proves its 64/64 GiB layout, original fixture contents and absence of replacement mutations. A separate 64 GiB single-disk guest boots without the extra block device and retains its home fixtures across reboot. Six matching clean exits are recorded. Checks cover content hashes, hidden/nested files, symlink/hardlink relationships, permissions, uid/gid, user xattrs and a sparse file. See [acceptance cases and boundaries](docs/HomeDisks.md#disposable-acceptance--4-november-2026).

**VERIFIED — host isolation and final cleanup state:** all 224 captured process identities across the attempts are absent; all seven disposable UUID roots have available runtime-compatible POSIX locks. The three roots in the successful run have no open files. The existing three-profile registry hash and recorded VM-file device/inode/size/mtime metadata match the pre-run receipt. Two older roots inspected through read-only diagnostic containers retain only read-only filesystem-sharing cache handles in an unrelated virtualization process; it is not a running test guest and was left alone. No test root is reset, erased or moved to Trash. Exact roots and this distinction are recorded in `.build/home-disk-poc/C38B2846-D2D3-4169-8673-52B5C9B5C033/final-host-audit.json`. Offer guarded whole-root Trash to the user after these checks. Installed apps, personal/default VMs and registry/defaults, real Keychain items and macOS permissions are unchanged.

**VERIFIED — final source, build and bundle:** runtime source `b5a9599ad4d67632e9957419432bfccbdb39ba39`, patch SHA-256 `7bdf4294f1705a3ac32d3fcc2fb7863bf6d02a0714a19fa283451a8ec9fe0601`, ad-hoc kit ZIP `61c501ac60c641c3bf9c717e95ea7c93f2e4870f89ac906f0a48d90e298885fd`, lock/compiled pin `fc88a028cef0e37937bb62f10331c211350d2d117e879d2045891a446875ceb1`. Standard 47 archive: `a2912a97967d315439b4ec387bb6125912dc9db0568aee2408cdb524159fd59b`; native 47.1: `8263e4db8c888da11ed490f7c09817767d723c2d78f1f63c8e8ca09661f9c740`. The 564-test upstream Swift suite and guest fixtures pass. Final normal no-VM `make test build` reports 247 tests in 41 suites with the live test disabled, plus 81 script tests. Both optimized launch/credential policy tests pass in normal release and `SIGNED_PRERELEASE`. Refreshed `.build/home-disk-review/Omarchy VM Manager.app` passes deep/strict ad-hoc signatures, all 22 kit Mach-O checks, compatibility for 25 Mach-O images, exact inventory/NAT/no-factory-image layout and bundle-only checks without host preflight or VM launch. It is staged, not installed or published, and lacks protected Touch ID Keychain entitlement. Logs are `.build/home-disk-runtime47-*` and `.build/home-disk-bundle-final*`; private live receipts remain under the run UUID. Earlier intermediate test failures and fixes are retained above, not counted as passes.

**TO PROVE — retained limits:** official/other factory images, simultaneous home-volume guests, native UI flows, focus/sleep/wake/crash cases, live disk-full/interrupted-format recovery, metadata beyond these fixtures (including ACLs), and a verified two-disk hibernation/restore contract. No such case is implied by the successful lean-factory run; hibernation stays disabled for separate-home guests. No real signing/notarization, credential access, permission grant, personal VM action or release publication occurred.

## Approved disposable home-disk Trash cleanup completed — 4 November 2026

**USER AUTHORIZATION / VERIFIED:** the user explicitly approved moving the seven audited disposable test UUID roots to Trash while leaving existing VMs untouched. Bind that authorization to the exact seven IDs and SHA-256 of the recorded final audit. A temporary opt-in runner uses only their four isolated registries, retains the registry locks, confirms all captured process identities are absent, and performs complete stopped/root/disk/ownership/tree/identity/runtime-lock preflight for all seven before the first move. For each operation, use `VMManager.delete` with its reviewed identity and the same pending-deletion profile check plus `ManagerStorage.trash`/Foundation Trash operation used by the storage helper. The production helper's personal application-support directory is never redirected or opened for writing; no alternate VM implementation or recursive storage removal is used. The one-time runner is retained privately with the receipts, not added as a production feature.

**VERIFIED — independent post-operation checks:** all seven original root paths are absent; every recorded Trash destination exists with the exact captured directory device/inode identity and expected ownership marker UUID. The four test registries have no remaining profiles or pending deletions. All 224 captured process identities remain absent. The existing three-profile personal registry hash and all recorded VM-file device/inode/size/mtime metadata still match the pre-test baseline. No unrelated virtualization process is restarted or signaled; its earlier read-only diagnostic cache handles do not cause broader cleanup. No personal/default VM, factory library, installed app, saved defaults, permissions or real credential is changed. Trash is not emptied; the moved roots remain recoverable.

**Evidence:** private approval, one-time runner, seven per-root Trash receipts, `trash-cleanup.log` and `trash-final-verification.json` are retained under `.build/home-disk-poc/C38B2846-D2D3-4169-8673-52B5C9B5C033`. Factory copies, diagnostic clones and other test evidence outside the seven VM roots are retained. Prior live-test limitations remain unchanged.

## Pre-commit review — 4 November 2026

**VERIFIED — review fixes:** source deletion remains blocked when a replacement's home copy exists but its identity/state/size/plan is invalid; disposable fixtures cover missing metadata, truncation, hardlinks and an invalid initial capacity. Clearing a reuse source restores the current owner-default preference. The backup supervisor kills remaining private process-group descendants even after its leader exits; a synthetic TERM-ignoring compressor regression passes. CLI help groups the owner-key option with creation options. These fixes do not change the reviewed runtime source, packages or kit pins.

**VERIFIED — final no-VM checks:** `make test` passes 248 Swift tests in 41 suites and 82 script tests; `make test-build-policies` passes both launch/credential cases in normal release and `SIGNED_PRERELEASE`. `make test-upstream` passes 564 Swift tests in 112 suites plus its guest/contracts/shell checks. `make test-ssh` passes its container boot ordering, owner enrollment, managed/personal login, loopback restriction, cross-VM and changed-host rejection cases. The final manager build and diff whitespace checks pass. Logs are `.build/home-review-final-validation.log`, `.build/home-review-upstream-validation.log`, `.build/home-review-managed-ssh.log` and `.build/home-review-build.log`. The opt-in live acceptance remains disabled during these checks; no further VM was launched or personal state modified.

**TO PROVE:** the existing home-disk and backup limitations above remain in force. In particular, the backup fixtures do not establish real Linux/9p backup or restoration. The seven approved test roots remain recoverable in Trash. This review authorizes a source commit and pull request, not signing/notarization, installation, a release or additional VM operations.

**VERIFIED — PR compiler compatibility fix:** PR #4's initial macOS CI runs fail while type-checking the combined `ManagerView` navigation/sheet/alert expression; SSH CI passes. Split that expression into four opaque view properties, preserving modifier order, bindings and actions. `make build` and `git diff --check` pass locally after the split. The macOS runner must pass before the user-authorized merge; the earlier local results did not establish that runner's compiler compatibility. No runtime or guest logic changes, and no VM operation occurs.

**VERIFIED — host-independent fixtures:** the next CI run compiles successfully and exposes three home-disk test failures because their managers inherit the runner's smaller CPU budget. Give every manager in that fixture suite explicit synthetic 32 GiB/8-CPU host limits, matching the existing resource-injection seam; production admission is unchanged. This corrects test portability rather than weakening resource policy. The subsequent local `make test` passes all 248 Swift and 82 script cases; CI must still pass before merge.

## Provisioning branch integration with next — 5 November 2026

**DESIGN DECISION:** `next` is the integration target. Merge fetched `origin/next`
`1258851` into the provisioning branch, retaining both histories and the home-disk,
backup, channel and release changes alongside Setup. No companion package merge
is needed. Product provisioning/guest launch admission remains disabled by default.

**PRIVATE COUPLING:** Setup journals/control sockets and disposable root namespace
follow the compiled app channel; inherited helper ownership validates its enclosing
app. The shared C launcher has no channel identity. New VM consent retry binds home
settings and guest Touch ID. Home backup and Setup exclude one another for a guest.
Both branches previously assigned registry schema 6; this reader accepts both old
payloads and writes Setup records as schema 7, preserving home metadata and making
older readers refuse the newer record. Home-only records retain schema 6.

**TO PROVE:** merged-source signing, original-Mac/loaded-child admission, real guest
Setup/home/terminal behavior and multi-app lifecycle behavior remain unobserved.
The old successful signed candidate remains bound to its historical frozen inputs,
not this merged source/runtime. No frozen approval or private artifact is replaced;
a future candidate requires a fresh exact review and separate execution approval.

**VERIFIED — offline/fake merge checks:** Stable and Dev each pass all 521 Swift
tests in 69 suites. The audited script suite passes 327 tests, explicitly skipping
five key/signature/PKCS12-generation cases. Temporary bundles pass channel
diagnostics and opposite-channel CLI/storage/provisioning-helper refusal without
manager execution. The 18,625-entry private artifact inventory is unchanged,
including all historical pins and the successful signed archive. Credential
content is unopened; no signing, key access, Apple request, install, SSH/Ansible,
manager/runtime or VM launch occurs. Signed bundle/app acceptance is not repeated.

**VERIFIED — optimized policy checks:** `make test-build-policies` passes both launch/credential policy cases in ordinary release, Stable `SIGNED_PRERELEASE` and Dev `SIGNED_PRERELEASE` modes. These are compilation/test variants; no signing identity, credential or signing operation is used. The initial sandboxed dSYM step is refused; the same tests pass outside that sandbox. Diff whitespace and changed script syntax checks pass.

## Fresh private review after next integration — 5 November 2026

**DESIGN DECISION:** prepare committed `4a0f30a` with its updated runtime and the
matching existing local signed runtime. Keep the original Stable disposable scope
definition, JSON, receipt and historical pins verbatim; next is the merge target,
not a channel/scope migration. Only ignored private overlay copies enable that
recorded scope; the ordinary product approval remains nil. No VM root is observed.

**VERIFIED — file-data/fake only:** source-only admission and independent patch
reconstruction pass. The review binds 32 committed tooling files, seventeen engine
files, operator, corrected guard, public-material copies and new source/runtime/
selection hashes. All 25 packet/refusal checks and 170 relevant fake API/process
tests pass. Old or relabeled native receipts cannot transfer. Existing private
artifacts, successful/failed candidates, consumed plans and pins are preserved.
Manager and companion edits are documentation only; package/product pins unchanged.

**TO PROVE:** fresh native inspection, trust, current keychain state/private-key
availability, merged-source build/signing and all later original-Mac/loaded-child/
guest acceptance. A bounded exact-request inspection is prepared, not executed;
its new successful receipt must precede a signing operator plan. No native output,
authority, operator plan or candidate build exists. All execution effects remain
NOT_GRANTED. No signing, key access, Apple request, SSH/Ansible, installs, normal
app/UI/runtime action or VM launch occurs. See the fresh 4a0f30a review runbook.

## Fresh merged-source native inspection result — 5 November 2026

**USER AUTHORIZATION / VERIFIED:** after manager `e04f20a` / companion `f51fc47`
commit the preparation docs, the user approves the exact fresh `4a0f30a` bounded
read-only inspection. The unchanged review/composition/guard, 173 sealed files,
32 committed tooling files and seventeen-file engine digest match. Only the exact
typed in-memory offline-inspection effect is granted; the request is consumed once.

**VERIFIED — native offline static only:** all 31 workers pass in 77.816 seconds.
Pinned source dependencies are clean before/after; interaction-disabled named
keychain status is locked before/after with metadata revalidated unchanged. Public
profile policy, leaf membership, certificate identity/typed dates and all 22 runtime
Mach-O plus enclosing-bundle no-network static checks pass. Every root is group-quiet/
reaped/closed, with zero unresolved handles and absent in a bounded recorded-PID
snapshot. All 18,881 prior private entries, review/pins and candidate/failed/consumed
artifacts remain unchanged. Source admission and all 173 sealed files revalidate.
Ordinary product approval remains nil; no scope root is observed or pin recaptured.

**TO PROVE:** CMS signer authenticity, certificate trust, online revocation/fresh
notarization/Gatekeeper, key availability, merged-source candidate build/signing,
loaded-child/original-Mac/guest acceptance. The new receipt permits preparation of
a fresh attended signing plan, not execution authority. No plan/candidate build,
signing, private-key access, Apple request, SSH/Ansible, install, UI/app/runtime or
VM action occurs; no automatic retry. See the fresh inspection result runbook.

## Fresh attended signing plan after native inspection — 5 November 2026

**DESIGN DECISION:** prepare a distinct private attended plan for `4a0f30a`, its
updated runtime and original Stable disposable scope using the new successful
inspection receipt. Preserve all prior candidates, reviews, consumed attempts and
frozen pins; no scope observation/recapture or ordinary product approval change.

**VERIFIED — data/fake only:** maintained `prepare` / `check` returns
CHECKED_PUBLIC_INPUTS_ONLY with execution unauthorized and current key availability/
native readiness unqueried. New receipt/source/runtime/material/seventeen-file
engine/operator bindings, 32 committed tooling files and 173 sealed review files
match. Fourteen plan/refusal checks and 44 fake API/process tests pass. All 18,916
prior private entries remain unchanged. No real-input authority, backend, candidate
output, consumed marker or attempt is created. The private attendance instructions
include exact terminal confirmation, quoted CLI, existing secure UI, 120-second
signing limits including UI wait, bounded cleanup and no automatic retry.

**TO PROVE / NOT GRANTED:** all five proposed execution effects remain NOT_GRANTED.
Current key state/availability/ACL/UI, compilation/signatures/Apple timestamps and
final candidate checks are not established. No original material/keychain metadata
or credential content is accessed; no native API, signing, private-key access,
Apple request, SSH/Ansible, install, app/runtime or VM launch occurs. Private data/
pins remain out of Git; both worktrees have documentation-only pending updates.

## Attended merged-source signing attempt — 5 November 2026

**USER AUTHORIZATION / ATTEMPTED:** preparation docs commit as manager `5a902cd` /
companion `292da85`. The user approves the fresh attended `4a0f30a` plan including
selected-key use, existing secure-key UI and Apple timestamps. Exact review/plan/
receipt/code bindings match; maintained CLI real-terminal confirmation and durable
consumption precede the bounded default backend. No approval-file loader is used.

**VERIFIED — build, partial signing attempt:** twelve preparation/build/location
commands and thirty pre-sign native workers pass. The 45-file resource payload
matches. The first storage-helper signing command reaches its 120-second deadline
and is killed/reaped/closed; elapsed is 752.079 seconds, CLI exit 1. Its 248-byte
incomplete stderr has only a fixed sign/incomplete-output diagnostic; staged bytes
remain equal to compiled input. No later signing/final archive or success receipt
is produced. All 43 owned roots are quiet/reaped/closed and absent in a bounded
PID-only snapshot, with zero unresolved handles. All 18,928 prior private entries
and frozen pins are preserved. Only approved new output/attempt/consumption is added.

**TO PROVE / NEXT:** actual key use, secure UI observation/response, timestamp
outcome and timeout cause are unestablished; ask for the operator's prompt
observation before any bounded diagnosis or fresh plan. The plan is consumed,
without retry or orchestrator keychain state query/change. No scope pin is observed/recaptured;
ordinary approval/shared code/pins stay unchanged. No notarization, SSH/Ansible,
install, publication, normal app/UI/runtime or VM action occurs. Signing completion
and original-Mac/loaded-child/guest acceptance remain TO PROVE.

**USER-REPORTED FOLLOW-UP — 4a0f30a attempt:** the operator answers “Completed the
dialog.” Record UI displayed/completed as user-reported; exact dialog type and
completion time relative to the 120-second signing limit remain unrecorded. This
does not establish selected-key use, keychain/ACL or timestamp outcome, or the
timeout cause. Automated failure evidence stays unchanged; the plan stays consumed
without retry, state change or additional native/key/network operation.

## Manager dev-vm source pin follows main merge — 5 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** refresh only the ordinary manager's
provisioning package to merged dev-vm `5770d0fde0355be6dade6b306d03661a5b8e616a`.
Preserve all historical private artifacts, reviews and frozen candidate pins;
this is not a new native inspection, signing plan or guest approval.

**VERIFIED — source/offline/fake:** all 95 export files match that exact commit,
which incorporates the four former integration patches. The effective code,
engine and resources are unchanged; only the exported README differs. The active
patch list is empty, the base equals the export, and generated admission pins
match the new lock. Historical patch files/frozen helper bytes remain unchanged.
Stable and Dev each pass 518 selected Swift tests in 67 suites. The guarded Python
suite passes 328 tests, skipping five signing/key-generation cases. Real SSH/home-
disk suites, `ssh -G` and signed bundle fixtures are excluded. Source preparation,
Python syntax and whitespace checks pass. All 23,951 captured private entries and
the runtime lock/generated pin remain unchanged, including historical candidate
source/package bindings. See the [package update record](docs/DevVMProvisioningPlan.md#manager-pin-follows-merged-dev-vm--5-november-2026).

**TO PROVE / NOT GRANTED:** any fresh candidate review, signed distribution and
native/guest acceptance from the updated manager source. No signing, key access,
native inspection, Apple request, real SSH/Ansible, install, normal app/runtime
action or VM launch occurs. No historical receipt or consumed plan is rebound.

## Fresh private review of 007bc66 — 5 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** prepare a new exact-source private review
for committed `007bc66`, with merged package `5770d0f` and the existing matching
runtime. Preserve all old artifacts/pins and the original Stable disposable scope;
do not execute native inspection or create signing/guest authority.

**VERIFIED — file data/fake:** source-only admission, independent six-file private
overlay reconstruction and verbatim scope JSON/receipt/definition comparisons
pass. A new 173-file sealed review binds 32 committed tooling files, seventeen
engine files, operator, corrected guard and retained public-material copies.
All 25 actual-packet positive/refusal checks and 170 fake tests pass; old or
relabeled receipts cannot transfer. All 23,951 prior private entries and four
current pin files remain unchanged. No VM root or original signing-material/
keychain metadata is queried; the keychain selector is only a path string.

**TO PROVE / NOT GRANTED:** fresh exact-review native observations, trust, key
availability, attended signing and original-Mac/loaded-child/guest acceptance.
All effects remain NOT_GRANTED; no inspection output, authority, signing plan or
candidate output exists. No real inspection, signing, key access, Apple request,
real SSH/Ansible, install, normal app/runtime action or VM launch occurs. See the
[fresh review and limits](docs/DevVMMilestone6Runbook.md#fresh-private-candidate-review-for-007bc66--5-november-2026).

## Fresh 007bc66 native inspection result — 5 November 2026

**USER AUTHORIZATION / VERIFIED:** preparation docs commit as manager `467f979` /
companion `8cf7f8d`, then the user approves the new exact review's bounded read-only
inspection. The 173 sealed files, corrected guard/composition, 32 committed tooling
files and seventeen-file engine match. Only the digest-bound in-memory offline-
inspection effect is granted; its request is consumed once without retry.

**VERIFIED — native offline static only:** all 31 workers pass in 76.504 seconds:
clean pinned dependencies before/after, interaction-disabled named-keychain locked
status before/after with unchanged metadata, public profile/certificate policy and
23 no-network runtime static checks. All groups are quiet before reaping, roots
are reaped and descriptors closed, with zero unresolved handles. The 31 recorded
PIDs are absent in a separate bounded snapshot. All 24,204 pre-run private entries,
173 sealed review hashes and four current pin files remain unchanged; source
admission and frozen overlay reconstruction pass again. The disposable scope/root
is not observed or recaptured and ordinary product approval remains nil.

**TO PROVE / NOT GRANTED:** CMS signer authenticity, certificate trust, online
revocation/fresh notarization/Gatekeeper, private-key availability and original-
Mac/loaded-child/guest acceptance. The new exact receipt permits preparation of an
attended signing plan, not execution authority. No plan/candidate build, signing,
private-key access, Apple request, real SSH/Ansible, install, normal app/runtime
action or VM launch occurs. Only the planned inspection output and separate private
execution/analysis evidence are added; historical artifacts and pins stay frozen.

## Signed private test build for 007bc66 — 5 November 2026

**USER AUTHORIZATION / VERIFIED:** the user requests a testable build and explicitly
approves selected-key use, secure-key UI and Apple timestamps for a fresh attended
plan. Inspection-result docs commit as manager `96319b0` / companion `79399ae`.
Fourteen plan checks and 44 fake tests pass; real-terminal confirmation and durable
consumption precede the bounded build/sign/verify run. All 17 commands and 46
native workers pass in 903.341 seconds, including five timestamp signatures and
complete staged/ZIP-roundtrip checks. Six signed code identities and post-sign
package seals match. All 63 roots are quiet/reaped/closed and absent in a bounded
PID-only snapshot. Historical artifacts, review/plan hashes and four current pins
remain unchanged; the original disposable scope is neither observed nor recaptured.

**TO PROVE:** normal app/UI, daemon/loaded-child/original-Mac and real-guest
acceptance, notarization/fresh online checks and CMS signer trust. The signed app
and ZIP are private user-test artifacts, not installed or published. No SSH/Ansible,
host install, normal app/runtime or VM launch, key export/import/enumeration,
orchestrator unlock/ACL change or automatic signing retry occurs.


## Disposable Dev saved-setup acceptance — 6 November 2026

**USER AUTHORIZATION / VERIFIED:** attended signing and saved Developer setup
execution were explicitly approved for one private disposable Dev UUID/root.
The corrected candidate completes the real apply, verifies inactive admin grant
and removed payload, and demonstrates the selected four-terminal layout after
normal restart. The test guest is then stopped with no runtime children or open
disk handles; Main's persistent processes/configuration hashes match baseline.

**DESIGN DECISION / PRIVATE COUPLING:** ordinary execution stays disabled and
same-team helper authentication is preserved. Only the private candidate embeds
the approved root. Ansible multiplexing is disabled in both config and overriding
connection variables; a changed engine receives a fresh explicit review of the
same saved input bytes. Historical receipts and private frozen pins stay intact.

**VERIFIED — fake/local:** 86 shared Swift tests, 239 Python tests (one skip),
74 focused manager tests and 130 UI checks pass. **TO PROVE:** unrestricted/fresh
creation and factory-matrix acceptance, other options and prior native lifecycle
limits. See the [bounded acceptance record](docs/DevVMMilestone6Runbook.md#disposable-dev-saved-setup-acceptance--6-november-2026).

**VERIFIED — final UI:** setup history no longer implies chronological order
from UUIDs; active cleanup retains priority and completed jobs use finished-state
copy. Pipe-LF and split-CRLF rendering pass regression checks. The final 136-check
UI suite passes; the signed UI-only Dev replacement shows the persisted successful
result without another guest launch. Private scope, engine and frozen inputs
remain unchanged.


## Direct live terminal interaction — 6 November 2026

**USER REQUEST / DESIGN DECISION:** use a 120 × 30 starting grid, smaller 11-point
responsive type, click-to-type and Follow output on by default; remove expansion.
Clicking claims the existing single-writer lease; it does not bypass guest
confirmation or credentials. Layout/output callbacks preserve Follow intent.

**VERIFIED — fake/local:** 86 shared Swift, 239 Python/local (one skip), fifteen
manager terminal tests and 140 offscreen UI checks pass, including synthetic
click-to-PTY input and ownership refusal. **TO PROVE:** actual future live guest
prompt interaction after these changes. Existing private target restriction,
ordinary disabled gate, Main isolation and frozen artifact/pin policy remain.


## Layouts install the apps they arrange — 7 November 2026

**USER REQUEST / DESIGN DECISION (issue #18):** choosing a bundled layout example
now installs the apps that layout puts on screen. This supersedes the 3 November
decision that choosing a card “does not implicitly add app installs”. Owners still
choose profiles, not packages; the manager adds no package picker. dev-vm owns the
merge: each catalogue example lists its needs as builtin features and list items,
and the shared `SetupPlanner` recognises the frozen layout bytes by SHA-256 (no new
provisioning input, keeping the 7 November card mapping) and adds what the selected
profiles lack. Lists from combined profiles now add up instead of conflicting
(Web + Python, Python + Project-managed); single settings that disagree still fail.
A feature the setup disables stays disabled. Claude Desktop has no setup feature
yet, so Claude layouts report it as not installed. The manager only displays the
plan's `layout` report: the setup review and guest card say “Layout adds …” and
name any app setup doesn't install. All seven bundled examples appear as cards,
grouped by workspace count; multi-workspace cards draw workspace 1 and say how many
workspaces they use.

**PRIVATE COUPLING:** the active package pin moves to the merged dev-vm commit
recorded in `Config/DevVMProvisioning.lock.json`, with an empty integration-patch
list (all four former patches are in that commit). Historical patch files, frozen
candidate pins, receipts and consumed plans are unchanged and keep their own
bindings. Every plan digest and the engine identity change, so setups saved under
the previous pin need a fresh review.

**TO PROVE:** real installation of the added apps on a lean guest through manager
setup, window placement at the next login (including multi-workspace on this
path), the official factory treating the additions as already installed, and how
the review reads natively. No VM, factory, signing or guest operation was used.

**DESIGN DECISION — New VM order (issue #18):** New VM shows a **layout** pane
holding only the layout cards, then a **customise** pane (renamed from software)
with the source, profiles, trim and the optional theme. Both edit one shared draft.
Choosing a layout example or custom file while setup is off turns setup on with
the Developer profile, since a layout only applies when setup runs; choosing
Omarchy default never turns it off. A saved desktop default doesn't turn setup on;
it applies when setup is turned on (a chosen layout keeps priority, the default
theme still applies). With setup unavailable, the layout pane explains that instead
of offering cards. Guest Defaults and Change setup keep the combined layout and theme
view. **VERIFIED — offscreen/fake:** 187 screen checks including pane order, layout
turn-on and Omarchy default keeping setup on. **TO PROVE:** physical interaction.

## Suspend-to-disk Dev-only feature flag — 8 November 2026

**DESIGN DECISION:** the user asked for a UI feature flag that hides experimental suspend-to-disk in stable and keeps it in Dev, and also for the guest capability check to be skipped when the flag is off. `FeatureFlags` is compiled from `AppChannel`, never a preference, environment override or wire field: stable off, Dev on. The app reads it from the SwiftUI environment; `VMManager.open` passes the compiled value. Stable hides the Home-page panel and the ellipsis-menu item, sends no capability check over SSH (the shared-folder check starts without waiting for it), and refuses `experimentalSuspend` with `experimental-suspend-disabled` before any guest command or saved-session record. Recovery is never hidden: a saved session or damaged saved-session metadata keeps the panel with Restore / Recover, Recheck recovery or Accept cold boot, and the main Restore action. Disk protection, restore proof, cold-boot acknowledgement, runtime handle/reservation ownership through matching `.exited`, and CLI refusals are unchanged in both channels. The stable-built layout preview turns the flag on to keep showing every synthetic state.

**VERIFIED — no-VM checks:** `make test` passes 619 Swift tests in 82 suites, 340 script tests, the provisioning bundle check and 212 setup-screen checks (56 PNGs, synthetic services only); `make test-dev` passes the same 619 Swift tests under `DEVELOPMENT_CHANNEL`. Both runs build the app target first. New tests prove each channel's default, that the compiled flags follow the compiled channel, the recovery visibility rule, that a disabled manager makes no capability check, preparation or hibernate request and writes no saved-session record, and that a saved session written with the flag on still restores and releases protection after reopening with it off, with no new capability check. `git diff --check` passes. No app bundle was rebuilt or installed, and no VM, guest, disk, credential or permission was used or changed.

**TO PROVE:** native appearance of the stable and Dev guest Home pages and menus; real-guest behaviour is unchanged from the earlier TO PROVE entries.
