# Phase 1 two-VM POC

Run date: 31 October 2026 (Australia/Melbourne). This file records observations; pending checks are not acceptance claims.

## Scope and provenance

The user approved factory-image downloads and two disposable manager-owned VMs. They separately approved controlling only those guest windows and using synthetic clipboard contents. They will initiate whole-Mac sleep/wake when prompted. Their existing Try Omarchy VM and storage are excluded from all operations.

The kit and clipboard patch are unchanged from Docs/Validation.md: patch commit `a135f003c2ffd2ce820900b5896b7ad9e2b84a96`, kit SHA-256 `24d569ea2ee06e4f8fd435ea215483db4b968720e509f194ad8d2913a8f44d6e`, manifest `development`, protocol 1. Each profile uses 4096 MiB, four CPUs, NAT and explicit clipboard/battery/timezone bridges. No forwards, shared folders, USB, authentication or camera.

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
| Host/guest clipboard and background suppression | Initial real Mac-to-guest check failed for both guests. The headless-loop repair is built and verified; real revalidation and background suppression remain pending. |
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

Repaired patch commit: `53093243ea809c0ff75f619a184a3a8a952cc1af`. Repaired kit SHA-256: `2cc5692339aecaf3f6dbc37653b18d27fbca78be9ea2ec7ecd1d663b585a486e`. Build date: `2026-10-31T01:14:11Z`. The original artifact and diagnostics remain preserved for audit. App assembly, exact inventory, signatures, compatibility and host preflight pass. Real clipboard revalidation is pending.
