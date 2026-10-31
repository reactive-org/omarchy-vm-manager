# Phase 1 two-VM POC

Run date: 31 October 2026 (Australia/Melbourne). This file records observations; pending checks are not acceptance claims.

## Scope and provenance

The user approved factory-image downloads and two disposable manager-owned VMs. They separately approved controlling only those guest windows and using synthetic clipboard contents. They will initiate whole-Mac sleep/wake when prompted. Their existing Try Omarchy VM and storage are excluded from all operations.

The initial run used the kit from Docs/Validation.md: patch commit `a135f003c2ffd2ce820900b5896b7ad9e2b84a96`, kit SHA-256 `24d569ea2ee06e4f8fd435ea215483db4b968720e509f194ad8d2913a8f44d6e`, manifest `development`, protocol 1. Later clipboard repairs and their exact provenance are recorded below. Each profile uses 4096 MiB, four CPUs, NAT and explicit clipboard/battery/timezone bridges. No forwards, shared folders, USB, authentication or camera.

- A: `C7C2B381-E43C-4A5A-8246-4314596B4C0A`, Omarchy POC A.
- B: `89F88CC2-BD11-44B5-9C1B-31EDB2DE6B0B`, Omarchy POC B.
- Roots are derived beneath `~/Library/Application Support/Omarchy VM Manager/VMs/`.
- Private live evidence: `~/Library/Application Support/Omarchy VM Manager/Logs/POC-status.json`.

## Implementation checks

`make test` passes 35 Swift tests (including the new storage/admission suite) and 9 Python artifact tests. `make app` and `make verify-app` pass, including exact kit inventory, nested signatures, 24 Mach-O compatibility checks and host preflight. The app remains disabled by default; `--poc-approved` enables the fixed disposable profiles.

## Observations

| Check | Observed result |
| --- | --- |
| Initial host/storage | 128 GB Apple M5 Max, 18 cores, macOS 27.0.1, approximately 1.1 TiB free; both manager UUID roots absent |
| Existing Try Omarchy | Its application process was present in the baseline; no QEMU guest process was present. It was not controlled or modified. |
| A initial start | Started at approximately 11:42:31 AEDT; factory download proceeded in A's private cache |
| Storage permissions | A root 0700; both ownership markers and settings 0600 |
| Overlapping cold start | Clicking B Start during A's download was refused with the explicit wait-for-ready message; B remained stopped and its root remained absent |
| First startup refusal | The factory download verified, then the shell rejected the two-CPU fallback before QEMU launch. The public protocol accepts two but the v1.3 runtime requires at least four. Profiles were corrected to four, with a pinned-source regression test. The original failure is preserved under `.build/poc/first-attempt-cpu-refusal.json`; no guest/data reset was performed. |
| A runtime ready | A reached `.ready` at approximately 11:48:36 AEDT after the CPU correction. Its QEMU arguments point to A’s manager-owned disk, 4096 MiB and four CPUs. The user subsequently confirmed a usable desktop. |
| A desktop | PASS, user-reported: installation/setup completed and a usable desktop was confirmed before B was started. |
| Both runtimes ready | B reached `.ready` at approximately 11:52:02 AEDT while A stayed running; manager reported two active sessions and 8 GiB allocated. Host-side process evidence is saved under `.build/poc/both-live-process-check.json`. |
| B desktop while A usable | User-reported: both warm guests are usable and render normally after the isolated A restart and warm B reintroduction. The earlier A visual corruption remains an open finding, so this is not an unconditional gate pass. |
| Independent disks/settings/window identities | PASS, host-observed: two QEMU PIDs, distinct disk and settings inodes, separate UUID roots and uniquely named temporary app bundles. Both actual commands select the correct disk, four CPUs and 4096 MiB, without port forwards. Guest file isolation and visible window checks remain pending. |
| Same-root lock/duplicate refusal | Unit duplicate guard passes. Live nonblocking POSIX lock probes failed with the expected busy condition for both running roots, proving each runtime held its own `shell/lock`. |
| Host/guest clipboard and background suppression | Initial real Mac-to-guest check failed for both guests. The first headless-loop repair restored Mac↔A, including while B ran, but B still failed both directions after isolation and restart. A second main-thread lookup repair is built and verified; real clipboard and background-suppression checks remain pending. |
| Independent graceful shutdown/restart/persistence | B was gracefully shut down for isolation at approximately 11:57:37 AEDT and emitted `.exited(0)` at 11:57:38; A remained running. Restart/persistence checks remain pending. |
| Confirmed force stop | Pending |
| Cancelled/normal app quit | Pending |
| Manager force quit / no orphan guest | Pending |
| User-initiated sleep/wake | Pending |
| Final shutdown and process cleanup | Pending |

No clipboard contents, guest passwords or personal host identifiers belong in this report. Preserve a minimal reproduction and stop further feature work if the real gate exposes a runtime singleton or lifecycle/focus failure.

## UI inspection limitation

The native Computer Use tool rejects both the unique `Omarchy POC A` name and its exact temporary `.app` path. Upstream deliberately leaves the guest app without a bundle identifier, and it is absent from the tool’s app inventory. The user chose to handle disposable guest UI checks themselves instead of authorizing an alternate harness. The agent controls only the manager UI and performs read-only, manager-scoped process/storage checks. No alternate guest UI automation or permission grant was performed.

## Rendering failure investigation

Further feature work and acceptance tests were paused after the visual failure report. The user clarified that B appeared fine and A was affected. Host Launch Services metadata shows two distinct foreground-app registrations/ASNs, both with the intentionally absent bundle identifier; this does not establish a registration collision as the cause.

B was shut down gracefully, with its disk retained, to compare A alone. The user reported that A remained corrupt after B exited. A was then shut down gracefully (`.exited(0)` at approximately 11:59:14 AEDT) and restarted alone from its existing disk (`.ready` at approximately 11:59:44). The user reported A was clean after that restart. B was then reintroduced from its existing disk for one controlled comparison, reaching `.ready` at approximately 12:00:38 AEDT. The user reported both guests looked normal during switching and pointer hover. The first-session failure is therefore not reproduced by this warm two-VM comparison; its root cause remains unresolved. The isolated restart and second-guest reintroduction are recorded diagnostic experiments, not an acceptance pass. No guest reset, display setting change, alternate UI harness or permission grant was used to hide the failure. The original failure snapshot and the post-B-shutdown state are preserved under `.build/poc/`.

## Clipboard failure and headless-loop repair

The user reported Mac-to-guest paste failed in both guests, including Ctrl+Shift+V in Foot. Both clipboard child processes were alive and targeted the correct QEMU PIDs; kernel executable identities matched the expected kit binary. Stack samples showed their main threads blocked in guest-channel reads, without a deadlocked state queue.

A read-only probe in the same headless execution context observed A/B active-flag transitions while the workspace's cached foreground PID stayed on another app. The SDK header documents that time-varying AppKit application properties refresh when the main run loop advances. This identified a flaw in the first focus patch, not a passed real clipboard check.

Both VMs exited gracefully (A at approximately 12:09:23 AEDT, B at 12:09:31) before their helper kit was replaced. Their disks were retained. The repair keeps the main run loop alive while a worker reads the guest socket, with completion/errors returned through the run loop. A standalone test compiles the actual runner and verifies main-queue responsiveness, completion and error propagation. The full repaired upstream suite passes 524 Swift tests plus its contract/shell suites; manager checks remain 35 Swift and 9 artifact tests. One first broad run hit a TCP teardown socket-fixture bind failure; the unchanged full-suite recheck passed.

Repaired patch commit: `53093243ea809c0ff75f619a184a3a8a952cc1af`. Repaired kit SHA-256: `2cc5692339aecaf3f6dbc37653b18d27fbca78be9ea2ec7ecd1d663b585a486e`. Build date: `2026-10-31T01:14:11Z`. The original artifact and diagnostics remain preserved for audit. App assembly, exact inventory, signatures, compatibility and host preflight pass. The user confirmed Mac→A and A→Mac work with the repaired kit while A ran alone. B then reached `.ready` with the same kit at approximately 12:19:11 AEDT while A stayed running; concurrent four-path clipboard and background-suppression checks are pending.

### Remaining B clipboard failure

With both repaired sessions running, the user reports Mac→B still fails at B's normal desktop. B's user clipboard service reports `active`. After manually typing `printf pocb | wl-copy`, the user can paste the synthetic token in B's Foot terminal but cannot paste it on the Mac. This proves a working local Wayland clipboard, while both bridge directions remain unproven in B. A running service alone is not a health check for end-to-end transport.

Both guests report integration package `0.1.0-36`, Omarchy `4.0.0.r7235.g967bbdd-1`, edge channel and running kernel `7.2.8-23-omarchy`. The B host-helper stack contains the repaired main run loop and a separate guest-channel reader. A separate read-only probe with that same run-loop implementation observes B as foreground on both its main and worker queues and verifies both kernel executable identities. This does not establish the live helper's internal focus state or prove clipboard socket traffic.

The user restarted only B's clipboard service; neither direction recovered. A then shut down cleanly (`.exited(0)` at approximately 12:32:24 AEDT), and its identified helper/QEMU processes exited. B still failed both directions while running alone, including a five-second focused dwell after the guest copy. The user confirmed A's clipboard had continued working before its shutdown. Simple contention between the two running bridges is therefore less likely; the root cause remains unproven. A worker-only focus probe was also run without clipboard access, but observed only B during its short sampling interval, so it did not test a focus transition.

At the user's suggestion, B was shut down cleanly (`.exited(0)` at approximately 12:33:43 AEDT) and restarted alone from its retained disk, reaching `.ready` at approximately 12:33:49. The restarted QEMU and clipboard helper have new PIDs and a new private socket directory. B's disk inode remains `79159827` and is selected by its QEMU command; A's retained disk inode remains `79158817`. The user reports neither clipboard direction nor Command/Super works after this restart. Further acceptance work remains paused.

A read-only QMP `query-chardev` on the restarted B reports `omarchy-clipboard-bridge` with `frontend-open: true`. Its QEMU command includes `full-grab=on` and `swap-opt-cmd=off`. These checks establish the configured channel and keyboard options, not delivery to the Wayland clipboard or effective keyboard permission. No QMP input injection or VM state mutation was used.

The user also reports that Command/Super does not work in the guests. They manually enabled only Omarchy VM Manager in macOS Accessibility settings. No permission was granted by the agent. B's isolated restart occurred after that grant; Command+Return still fails to open a terminal (user-reported). The cause remains unproven.

### Controlled focus comparison and second helper repair

The user performed a focus-only cycle: B, a Mac app, then B, with two-second pauses. Two independent headless probes used the current helper's actual run-loop implementation and logged only B/manager/other roles. The worker-only probe remained `other-or-nil`. The probe dispatching every foreground lookup to the main queue recorded `other-or-nil`, B, `other-or-nil`, B, `other-or-nil`. Raw role-only traces are preserved under `.build/poc/background-focus-awaiting-human.log` and `.build/poc/main-focus-awaiting-human.log`. This reproduces a stale background foreground lookup even with a live but otherwise idle main loop.

The updated helper performs every focus lookup and kernel identity check synchronously on the main thread, with a direct path for calls already on that thread. Its standalone regression compiles the actual focus adapter and verifies both calling contexts, PID match/mismatch, unavailable foreground state and stale identity rejection. Source patch: `9341b7a35f8d90eb76eae8478c0f641dfe386009`. Kit SHA-256: `f5e097993ad396b27e34a729cf080e5b364f4d1d9290d3dd1a46f950c01cae24`. Build date: `2026-10-31T01:52:26Z`. The full upstream suite passes, including 524 Swift tests; manager checks pass 35 Swift and 9 artifact tests. Kit/app assembly, exact inventories, nested signatures, compatibility and host preflight pass. Renewed real clipboard checks remain pending.

B shut down gracefully (`.exited(0)` at approximately 12:50:59 AEDT) before replacing the helper. Both disks remain intact. No manager-owned QEMU/helper remained. The focus probes were stopped after collecting the human cycle. The manager now records its own read-only `AXIsProcessTrusted()` result in its private POC report to distinguish an effective Accessibility grant from a stale ad-hoc build entry. It never requests or grants that permission. Replacing an ad-hoc signed build can invalidate its earlier grant; Super remains a separate unpassed check.

The rebuilt manager opened without launching a VM and reports `accessibilityTrusted: false`. Both profiles are stopped. The user has been asked to refresh only the current manager's existing Accessibility grant manually before the next Super test, or defer that test. This does not make clipboard depend on that grant.
