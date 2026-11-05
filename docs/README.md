# Omarchy VM Manager user guide

Create independent Omarchy guests, configure their resources, and connect from your Mac over SSH. This guide describes the current private macOS build, **0.9.3 (16)**.

![The current manager library with two stopped guests, Import Factory and New VM controls](media/library.webp)

## Start here

- [Getting started](getting-started.md): open the app, set up reusable defaults, create a guest and launch it.
- [Manage your guests](managing-guests.md): change resources, use SSH, assign a Space, shut down and delete guests.
- [Prepare a factory image](preparing-factory-images.md): customise a lean build, prepare a compatible bundle and select it for a new guest.
- [Use the CLI](cli-quickstart.md): create with per-VM owner overrides, wait for SSH, inspect, stop and reconfigure from a terminal.
- [Stable and Dev](DevelopmentChannels.md): build and run an isolated development app while the existing app keeps its work VMs running.
- [Troubleshooting](troubleshooting.md): Super shortcuts, clipboard, startup and SSH readiness.

## A quick look

[Watch or download the 48-second MP4 tour](media/quick-tour.mp4) · approximately **748 KB**.

The silent tour is assembled from real screenshots of the running manager. It shows stopped-guest settings, experimental suspend readiness and the factory import form; it is not a continuous recording of installation or guest startup. The twelve screenshots and video together are approximately **1.2 MB**. [Captions and a text transcript](media/README.md) are included.

Screenshots were captured on 1 November 2026. Guest names and the illustrated SSH port belong to this installation; yours will differ. The New VM, configuration and factory import forms were cancelled. No guest was launched, changed, shut down or deleted for these captures. Both existing guests remained stopped. The SSH and configuration images are cropped to omit a personal public-key fingerprint and generated guest hostname.

## Current capabilities

| Task | Current behavior |
| --- | --- |
| Create guests | Independent disks; optional saved owner setup; SSH on by default |
| Configure | Name, CPU, memory, grow-only disk capacity, clipboard and immersive mode while stopped |
| Connect | NAT networking and a separate localhost SSH port for each enabled guest |
| Organize windows | Native Dock assignment to Mission Control Spaces |
| Remove a guest | Move its stopped guest folder to macOS Trash |
| Choose a factory | Official image or a verified compatible custom bundle, selected when creating a guest |
| Reuse downloads | Shared verified factory-image cache in Downloads |

The local 0.9.4 (17) update adds [CLI owner overrides](cli-quickstart.md#override-owner-settings-for-one-vm) for a new guest without changing Guest Defaults. Its app and CLI pass installation/bundle checks; creation and real boot with overrides remain untested. The screenshots above remain from 0.9.3 (16).

Shared folders, USB, camera, authentication bridges, general port-forward editing, snapshots and importing existing VMs are unavailable in this build. The library's retained POC entries keep their original configuration; stopped entries can be moved to Trash through the normal confirmed deletion flow.

## Further reference

[CLI reference](CLI.md) · [Factory images](../README.md#factory-images) · [Factory image cache](FactoryCache.md) · [Guest Defaults details](UnattendedDefaults.md) · [Managed SSH](ManagedSSH.md) · [Validation record](Validation.md)

This is a project of [reactive.org enterprises](https://www.reactive.org/). Omarchy is a pending trademark of the [Omacom Foundation](https://omarchy.org/foundation/).

[Pause and resume](PauseResume.md) explains manual execution control, host sleep/wake and shutdown.

[Guest display activation](GuestForegrounding.md) describes interactive launch intent, background automation and the remaining native macOS checks.

[Touch ID feature preparation](TouchID.md) describes the new password-approval flow and the provisioning profile still required before it can be used.

[Suspend-to-disk investigation](Suspend.md) records the clarified RAM-release requirement, pinned graphics blocker and proposed disposable hibernation POC.

- [Reviewed custom factories](CustomFactories.md): prepared-bundle review, import, creation-time selection and validation limits.
- [Factory compatibility](FactoryCompatibility.md): reviewed guest package identities, supported protocols, migration and when an image rebuild is necessary.

- [Native host-folder sharing](SharedFolders.md): opt-in configuration, runtime limitations, factory prerequisites and approval-gated existing-VM validation.

- [Guest Touch ID for sudo](GuestTouchID.md) — default-off settings, isolation policy and separately approved native validation.

## Implementation plans

- [Shared Swift dev-vm provisioning](DevVMProvisioningPlan.md): Homebrew Ansible, shared Swift planning/transport and the UI/CLI/live terminal plan. Milestones 1A and the offline package foundation are implemented. [Milestone 3](DevVMProvisioningPlan.md#milestone-3-completion--3-november-2026) is complete for fake/local acceptance: manager service, private workflow/child journals, admitted helper IPC, SSH wait/review, matching-exit restart, explicit rebind/check, authenticated recovery and retention. Full-process capability loss retains cleanup holds and refuses replay/adoption. Product execution stays disabled. [Milestone 4](DevVMProvisioningPlan.md#milestone-4-completion--3-november-2026) now completes the separate authenticated terminal stream, explicit input ownership, resize/detach/expiry, gap/reset contract and local TTY restoration for fake/local acceptance. Native rendering and UI/CLI integration are milestone 5; approved guests are 6 and distribution is 7.
- [Provisioning tools](ProvisioningTools.md): schema 2 reports, Homebrew pair checks, feature gates and validation limits. Readiness does not enable execution.

[Milestone 5 Setup terminal and CLI](DevVMProvisioningPlan.md#milestone-5-uicli-terminal-slice--3-november-2026)
records the uninstalled native terminal, offline presets/folder preview, separate
same-user streaming endpoint, explicit input ownership and local fixture evidence (376 manager Swift tests, 52 script tests and signed-helper fixtures).
Later sections record frozen submission, reviewed workflow actions and the New VM selection handoff; product execution remains gated.

[Frozen previews, apply review and task trust](DevVMProvisioningPlan.md#milestone-5-frozen-preview-apply-submission-and-task-trust--3-november-2026)
adds the shared UI/CLI review contract, immutable private inputs, independent
hash-bound custom-task consent, final dependency checks and fake-only submissions.
Later slices add New VM selection and reviewed restart/check/recovery contracts; product execution remains gated.

[Reviewed restart/check/cleanup recovery](DevVMProvisioningPlan.md#milestone-5-reviewed-restart-check-and-cleanup-recovery--3-november-2026)
records separate action consent, matching-exit restart, fresh-session check and
original-capability cleanup recovery through the shared native/CLI service.
Product execution remains disabled; the next record adds native feature choices and New VM metadata handoff.

[Native features and New VM handoff](DevVMProvisioningPlan.md#milestone-5-native-features-and-new-vm-handoff--3-november-2026)
adds Use source/Enable/Disable controls, private generated manifests, exact frozen
selection review and metadata-only creation receipts with duplicate protection.
Manager resource/factory choices remain authoritative; execution remains disabled.

[Authenticated identity and dormant backends](DevVMProvisioningPlan.md#milestone-6-preparation-authenticated-identity-and-dormant-backends--3-november-2026)
records strict authenticated UID/session/key evidence, freshness and probe fencing,
plus lazy worker/cleanup construction. Product execution remains disabled; these
are fake/local checks preparing the separately approved guest acceptance.

[Offscreen setup components](media/setup-components-offscreen.png) show the actual
feature controls and terminal with labelled synthetic output. This validates
component rendering only, with no visible window, VM registry or live guest.

[Full Setup and New VM acceptance](DevVMUIAcceptance.md) records 56 isolated
fake-service view/action checks, light/dark full-screen captures and terminal
rendering. Physical input, focus, native dialogs and real guests remain untested.

[Milestone 6 disposable-guest runbook](DevVMMilestone6Runbook.md) is prepared,
not executed: exact scope/approval worksheet, operational candidate prerequisites,
guest/TTY/cleanup/restart/check/failure evidence matrix and stopped-root cleanup.
Product execution remains disabled; no host install or real transport is authorized
by the runbook.

The [offline candidate preflight](DevVMMilestone6Runbook.md#offline-candidate-preflight)
is available as `make provisioning-preflight`. It verifies existing local package/
resource inputs and fingerprints build artifacts without running them. Ten offline
checks and 61 script tests pass. Guest acceptance stays NOT_RUN; the report cannot
approve a scope or enable execution. A new stopped disposable profile proposal and
its explicit preparation approval precede any real candidate/guest run.

A [private scoped preparation candidate](DevVMMilestone6Runbook.md#private-scoped-candidate-preparation)
is now retained outside version control. Both compiled components verify the same
original disposable pins; thirteen offline checks and the twelve-test ordinary
admission suite pass. Fake-runtime probes start nothing. The candidate is ad-hoc
signed, and its unchanged production helper-signing policy correctly blocks it.
The ordinary build stays disabled; real guest acceptance remains NOT_RUN.

The [offline signing/readiness audit](DevVMMilestone6Runbook.md#offline-signing-and-readiness-audit)
records nineteen static checks and seven remaining gates. Promotion requires the
supported signed-prerelease rebuild and a private nonpublishing signing handoff.
Tool files/static Core metadata are present but unprobed; factory bytes remain
unverified after OS access refusal. No permission, credential, signing, installed-
tool, workflow or guest operation occurred.

The [private signing/packaging handoff](DevVMMilestone6Runbook.md#private-signing-and-packaging-handoff--fakelocal-path)
now freezes reviewed source/scope/runtime/resource inputs privately. Its CLI prepares
requests only; the fake-only packager tests profile/build/sign/seal/verify/archive
ordering, tamper refusal and private failures. Eighteen focused tests and all 79
script tests pass. The real request cannot enter the simulation path. A real signer
is not connected, ordinary execution stays disabled, and guest acceptance is NOT_RUN.

The [private signer adapter](DevVMMilestone6Runbook.md#private-signer-adapter--fake-process-runners-4-november-2026)
now connects the frozen handoff to signed-prerelease build, SDK signing and private
archive verification commands. Twelve new fake-process tests and all 91 script
tests pass. The system runner denies execution by default; no real signing,
credentials, Apple requests or guest operation has occurred. The original scope
stays pinned; real compiler/signature, notarization and original-Mac/loaded-child
checks remain TO PROVE. This supersedes the earlier unconnected-signer boundary.

The [real signed-candidate gate](DevVMMilestone6Runbook.md#real-signed-candidate-gate-preparation--4-november-2026)
is prepared as a private review packet, with exact origin/profile/source bindings
and separate approval stages. Candidate/handoff and clean pinned local sources
are re-admitted without SDK or credential access. The real runtime, team/identity,
isolated keychain and profile path remain unselected; signing is not ready or
authorized. Pins stay out of Git and no execution gate changes.

[Local signed-runtime discovery](DevVMMilestone6Runbook.md#local-signed-runtime-discovery--4-november-2026)
finds and privately stages an existing `v0.9.4-dev.1` artifact matching the frozen
origin and ZIP/bundle inventories. Public certificate selectors and unopened
profile-file candidates are recorded privately. Isolated keychain selection and
fresh bounded material validation remain pending; no credentials, signing/Apple
requests or guest operations occur and all approvals remain ungranted.

[Milestone 6 disposable admission](DevVMProvisioningPlan.md#milestone-6-disposable-admission-foundation--3-november-2026)
adds independent manager/helper approval checks for exact disposable UUID/root
identity pins, including restart, cleanup and terminal input. Twelve fake/local
admission tests pass. Product approval remains nil and execution disabled; the
[runbook](DevVMMilestone6Runbook.md) records the concrete candidate/approval steps
still required before a real run.

[Source and multi-profile cards](DevVMUIAcceptance.md#separate-source-and-multiple-profiles--3-november-2026)
separates configuration location from profile selection in New VM and Setup. Cards
support multiple selections and show resolved inclusions; local manifest profiles
stay included and native feature overrides are hidden for now. The current
fake/local record has 448 Swift tests, 52 script tests and 62 screen checks; real
provisioning stays disabled.

[Optional-app trimming](DevVMProvisioningPlan.md#optional-app-trim-selection--3-november-2026)
adds an initially-off control for the official Try Omarchy factory, frozen candidate
removals and the upstream guest trim helper in the shared Swift adapter. Guest
trimming remains unproven and product execution remains disabled.

[Theme & layout selection](DevVMProvisioningPlan.md#theme-and-layout-selection--3-november-2026)
adds collapsed native controls, review-time repository GET validation, frozen
random/most-starred selection and copied Lua layout inputs. Star lookups use an
existing authenticated gh; nothing is installed or signed in automatically. Real
theme/layout guest acceptance remains open and execution stays disabled.

[Refined theme/layout controls](DevVMUIAcceptance.md#themelayout-visual-refinement-and-adjacent-trim-help--3-november-2026)
use responsive panels and explicit theme choices. Trim help is directly beneath its
toggle. Current fake-service visual acceptance passes 92 checks; execution remains off.

[Visual dev-vm layout examples](DevVMProvisioningPlan.md#bundled-dev-vm-layout-example-cards--3-november-2026)
adds four wireframe cards backed by bundled, hash-checked Lua sources. App lists are
prerequisites; choosing a layout does not add package installs or authorize execution.

[Main integration](DevVMMilestone6Runbook.md#after-merging-main--4-november-2026)
combines latest main's loading, release and guest Touch ID work with provisioning.
Offline build, 300 selected Swift tests, 109 Python passes (five signing cases
skipped), and 100 offscreen UI checks pass, including scoped local-socket retries.
Private artifacts and frozen pins are unchanged. They still represent pre-merge
source; an integrated candidate needs fresh source/runtime review. Product
provisioning remains disabled and no signing, credential or guest action occurs.

[Integrated candidate inputs](DevVMMilestone6Runbook.md#integrated-candidate-inputs-for-7e46241--4-november-2026)
freeze `7e46241` and a matching local signed runtime in a new private source-only
packet. Original scope/source pins and prior artifacts stay unchanged. Twenty-two
input checks and 12 fake signer tests pass; no app/signing or credential operation
occurs. The gate records source-only signer admission and profile/keychain
validation as pending, with every execution/signing/guest approval ungranted.

[Version-2 source admission and caller](DevVMMilestone6Runbook.md#version-2-source-only-admission-and-caller--4-november-2026)
now consume that unchanged packet through an explicit typed API, preserving original
scope bytes and legacy admission. Default execution is denied; one-shot use,
independent review bindings and immutable source/runtime checks are tested with
fake runners. Eighteen new tests and 127 allowed Python passes succeed, with five
signing cases skipped. The actual packet admits as data only, all private artifacts
stay unchanged, and profile/keychain/real signing and guest gates remain pending.

[Named material inspection and staging](DevVMMilestone6Runbook.md#named-material-inspection-and-private-staging--4-november-2026)
adds an inspect-only, one-shot caller with private profile/public-certificate
staging, independent review bindings and callback revalidation. It never reads
keychain contents or grants signing authority. Nineteen new fake tests pass;
the full allowed Python suite has 146 passes/five signing skips. Actual material
selection/inspection remains pending, and frozen artifacts/pins stay unchanged.

[Bounded native inspection preparation](DevVMMilestone6Runbook.md#bounded-native-inspection-preparation--source-review-4-november-2026)
traces the daemon's read-only `check` branch and distinguishes the privileged
client's XPC check. A new offline contract requires explicit no-network Security
validation and live worker limits, with the daemon unexecuted. The current caller
needs that adapter and fake tests before separate native approval. This review
executes no native verifier or cryptographic operation; exact evidence stays private.

[Offline inspection adapter](DevVMMilestone6Runbook.md#offline-inspection-adapter--fake-apisworkers-4-november-2026)
implements the typed one-shot policy, no-network API calls, CMS guards and live
worker time/output/cleanup limits against injected fakes. Thirty-two new tests and
178 allowed Python passes succeed, with five signing skips. Concrete native API /
process activation remains absent and separately gated; private pins stay unchanged.

[Concrete macOS bindings and launcher](DevVMMilestone6Runbook.md#macos-bindings-and-bounded-launcher--fake-ffiprocesses-4-november-2026)
now implement lazy offline APIs, private parent-pipe task binding, nonblocking IO
and non-reaping process-group ownership. Thirty-three fake FFI/process tests and
211 allowed Python passes succeed, with five signing skips and no inspection
library attempt. Defaults remain denied; fresh private review and separate native
approval are next. Frozen artifacts/pins remain unchanged.

[Fresh private review for ddf5451](DevVMMilestone6Runbook.md#fresh-private-inspection-review-for-ddf5451--4-november-2026)
binds the committed implementation and frozen inputs in a new ignored packet.
The output remains uncreated and every approval ungranted. Only stored evidence /
source integrity is checked; signing materials and native APIs remain untouched.
Historical artifact/pin preservation and its credential-content limitation are
recorded privately. Separate approval precedes any bounded native inspection.

[Approved inspection attempt](DevVMMilestone6Runbook.md#approved-inspection-attempt-stopped-before-native-work--5-november-2026)
stopped at the one-off composition's overly restrictive `/dev/null` audit guard,
before any worker, native API or material access. The review/output and artifact
preservation are checked; a narrow guard correction has ten fake-event cases only.
The request is consumed without retry; fresh review and separate approval precede
another attempt. No native inspection result is claimed.

[Corrected fresh private review](DevVMMilestone6Runbook.md#corrected-fresh-private-inspection-review--5-november-2026)
binds a new request/output and the narrow `/dev/null` guard correction, with 22
fake audit/helper cases. The implementation, frozen pins and all 1,170 existing
artifact entries remain unchanged. The failed attempt stays consumed; both
inspection outputs are absent and separate fresh approval is required. No native
inspection or authority is activated.

[Corrected native inspection result](DevVMMilestone6Runbook.md#corrected-native-inspection-result--5-november-2026)
records a partial, unaccepted attempt: source, locked-keychain and profile checks
pass; public-certificate parsing fails before runtime validation. No survivors
match the bounded cleanup snapshot, but the runner's false cleanup flag remains.
All 1,182 existing artifact entries and pins are preserved; five fake diagnostic
cases support possible causes only. A consolidated fake-only diagnostics/date/
cleanup-evidence change and fresh review are next; this request is not retried.

[Diagnostics, cleanup evidence and typed dates](DevVMMilestone6Runbook.md#diagnostic-and-date-hardening--fake-validation-and-fresh-review-5-november-2026)
are implemented with twelve new fake tests: 223 allowed Python passes and five
signing skips, without native-library attempts. A fresh private review binds an
exact uncommitted source/test snapshot, new request/output and corrected guard.
All 1,191 old artifact entries/pins and failed receipts remain unchanged. The
output is absent; actual native behavior and prior failure causes remain unproven.

[Native offline inspection passed](DevVMMilestone6Runbook.md#native-offline-inspection-passed--5-november-2026)
after committing the exact reviewed snapshot. All 23 static checks, source/profile/
certificate checks and locked-state checks pass in 64.18 seconds. Cleanup evidence
covers all 31 workers; a targeted PID snapshot finds no survivors. All 1,204 old
artifact entries and frozen pins are preserved. This offline-only receipt grants
no signing/guest authority; milestone 6 and separate real acceptance gates remain.

[Signed-candidate review](DevVMMilestone6Runbook.md#signed-candidate-review-after-offline-inspection--5-november-2026)
binds the passed inspection, staged material and frozen inputs to a private
proposal/output. It is not executable: receipt-bound authority, bounded signer
supervision and legacy inspection replacement remain implementation work; key
use/secure UI and Apple timestamp consent are still ungranted. All 1,239 old
artifact entries/pins remain unchanged, output is absent and no signer runs.

[Receipt-bound signing path](DevVMMilestone6Runbook.md#receipt-bound-signing-path--fake-tests-and-fresh-review-5-november-2026)
implements admission, bounded supervision and legacy-verifier replacement together.
Twenty new fake cases and the full 243-pass/five-skip suite pass without native
library attempts. A fresh private review binds an exact uncommitted sixteen-file
implementation and 24-file source/test snapshot. Older real dispatch is disabled;
all key/UI/timestamp approvals remain ungranted and candidate output absent.
Original artifacts/pins and historical inspection evidence are preserved.

[First reviewed candidate attempt](DevVMMilestone6Runbook.md#first-reviewed-candidate-attempt--preparation-stop-5-november-2026)
stops in frozen provisioning-source preparation (exit 1) before compilation or
signing. All twelve supervised roots/workers clean up, and all 1,279 original
artifact entries/pins are preserved. Source data checks pass, but discarded raw
stderr leaves the exact cause unknown. No key, secure UI, timestamp or VM stage
is reached. The request is consumed; fixture/diagnostic work and fresh review are
next, without replaying this attempt.

[Frozen helper and safe failure diagnostics](DevVMMilestone6Runbook.md#frozen-helper-and-safe-failure-diagnostics--5-november-2026)
add a byte-exact local fixture, private-output Git discovery boundary and bounded
EOF/fixed-code diagnostics. The full audited suite passes 256 cases with five
signing skips. A new private exact-source review is unexecuted with all approvals
ungranted; 3,987 earlier artifact entries/pins remain unchanged. Historical error
cause and real compiler/signing/candidate/guest behavior remain unproven.

[Private local signing](PrivateLocalSigning.md) documents the maintained developer
`prepare`, `check` and interactive one-shot `run` commands, including private
selection files, fresh per-plan consent, bounded execution and cleanup evidence.

[Fresh candidate assembly stop](DevVMMilestone6Runbook.md#fresh-candidate-attempt--compiled-resource-assembly-stop-5-november-2026)
passes frozen preparation, runtime validation and release compilation, then
refuses a provisioning resource inventory mismatch: payload matches, but four
frozen signature records are absent from fresh build output. All 42 owned roots
clean up and 4,002 prior artifact entries/pins are preserved. Signing/key/UI/Apple
timestamp stages are not reached. The request is consumed; narrow resource
fixtures/admission and fresh review precede any separately approved attempt.

[Resource payload admission and fresh review](DevVMMilestone6Runbook.md#resource-payload-admission--fake-fixtures-and-fresh-review-5-november-2026)
fixes assembly with exact payload/wrapper checks and only the four known inherited
reference signatures excluded. Built/output signatures and unknown changes still
refuse; generic inventories and final seals remain enforced. Fourteen new cases;
291 audited passes/five signing skips. A fresh maintained operator plan is prepared
but unexecuted, with all approvals unset and 8,691 old artifact entries/pins intact.

[First maintained operator run](DevVMMilestone6Runbook.md#first-maintained-operator-run--signing-timeout-5-november-2026)
passes build, runtime checks and corrected resource assembly, then times out on the
first selected-key signing command. All 43 recorded roots clean up; 8,713 prior
artifact entries/pins are preserved. The operator later reports completing a macOS
secure-key/keychain dialog; its type/timing, actual key use and timestamp/wait outcome
remain unproven. No signed result/archive is established. The plan is consumed.

The operator clarifies that the signing prompt was missed. This supports a secure-UI
wait explanation; key readiness and timestamp outcomes remain separate evidence.

[Read-only signing readiness](DevVMMilestone6Runbook.md#read-only-signing-readiness-diagnosis--5-november-2026)
finds the selected keychain currently unlocked and staged public certificate/profile
metadata consistent. A missed prompt fits the elapsed signing deadline. One bounded,
network/file-write-denied worker cleans up; all 13,565 old entries/pins are intact.
Private-key/ACL usability and timestamps remain untested; no signing or retry occurs.

[Attended private signing passed](DevVMMilestone6Runbook.md#attended-private-signing-passed--5-november-2026)
records the signed, timestamped private archive: seventeen commands/46 native
workers pass, exact staged/archive-roundtrip checks succeed, all 63 owned roots
clean up and 13,570 earlier entries/pins are preserved. Not notarized or executed;
original-Mac, loaded-child and disposable-guest acceptance remain separate.

[Integration with next](DevVMProvisioningPlan.md#integration-with-next--5-november-2026) records combined channel/home/Setup behavior and the historical signed candidate boundary. A merged-source candidate needs a fresh review; private pins are preserved.
