# Omarchy VM Manager user guide

Create independent Omarchy guests, configure their resources, and connect from your Mac over SSH. This guide describes the current private macOS build, **0.9.3 (16)**.

![The current manager library with two stopped guests, Import Factory and New VM controls](media/library.webp)

## Start here

- [Getting started](getting-started.md): open the app, set up reusable defaults, create a guest and launch it.
- [Manage your guests](managing-guests.md): change resources, use SSH, assign a Space, shut down and delete guests.
- [Prepare a factory image](preparing-factory-images.md): customise a lean build, prepare a compatible bundle and select it for a new guest.
- [Use the CLI](cli-quickstart.md): create with per-VM owner overrides, wait for SSH, inspect, stop and reconfigure from a terminal.
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

- [Native host-folder sharing](SharedFolders.md): opt-in configuration, runtime limitations, factory prerequisites and approval-gated existing-VM validation.

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
