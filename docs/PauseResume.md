# Manual Pause/Resume

**Development build:** the user clarified that the required feature is suspend-to-disk to release RAM. This in-memory implementation does not meet that requirement. See [suspend investigation and blocker](Suspend.md).

Build 0.7.0 (11) is installed at `~/Applications/Omarchy VM Manager.app`. The project’s older `dist` bundle was left running to preserve its active guest; switch managers only after that guest is shut down. Use the updated installed app’s bundled CLI for its new commands.

Use the running guest’s ellipsis menu → **Pause**, then its **Resume** button to continue. While paused, **Shut Down** is in the ellipsis menu. CLI equivalents:

```sh
./bin/omarchy-vm pause dev
./bin/omarchy-vm get dev
./bin/omarchy-vm wait dev --for paused
./bin/omarchy-vm resume dev
./bin/omarchy-vm stop dev --wait
```

This is an in-memory execution pause. QEMU and the helper remain alive, and the manager keeps RAM/CPU budget, disk locks, port reservations and session identity until matching `.exited`. Guest apps and SSH cannot respond while paused. The manager cancels readiness checks and invalidates their callbacks; Resume starts fresh checks. Paused JSON records remain `active: true` and withhold cached IPs. Paused guests cannot be edited or deleted.

## Sleep/wake and shutdown policy

**DESIGN DECISION:** manual pause ownership is separate from the helper’s existing host-sleep pause. Mac sleep/wake preserves a manual pause; it never resumes an unrelated QEMU error stop. A running guest paused for host sleep resumes on wake through the existing bounded recovery path. Duplicate notifications cannot acquire a second pause or trigger a second resume.

Graceful Stop, restart, Dock Quit, manager Quit and stdin EOF use the helper’s existing shutdown path. It resumes an owned pause, verifies QEMU is running, releases its held monitor connection, then sends `system_powerdown`. Existing forced shutdown timeout/fallback remains in effect. An unsafe QEMU error stop is never cleared just to make shutdown graceful. Force Stop disconnects the pause controller and terminates through the existing launcher cleanup path. The manager releases nothing before terminal exit.

Commands are allowed only after runtime ready and before shutdown. The manager permits one outstanding execution command per guest, waits for acknowledgement, and retains that pending identity after a timeout so a late reply cannot be mistaken for a new request. The UI shows **Execution state unknown** and preserves all resources; wait for the late reply or shut down. Shutdown overrides late replies. Session UUID guards reject events from an older launch.

## Runtime boundary

**PRIVATE COUPLING:** the accumulated reviewed upstream patch adds `pause`/`resume` commands and an additive `execution-state` event to the existing bounded run-protocol-1 pipe. It exposes `VMRunClient.pause()`/`resume()` and reuses the upstream QMP sleep controller. There is no second manager QMP connection, signal-based suspension or QEMU change. Existing clients ignore unknown events. The manager compiles its client SDK from the same verified patched checkout as its helper; `make prepare-source` reconstructs it for SwiftPM/Xcode. The stock vendor checkout stays at v1.3.0. Runtime capability `manualPauseVersion: 1` is pinned alongside the archive and file inventory.

Pause claims ownership only after a running status and observed STOP event. Resume checks status, refuses abnormal stops, sends `cont` only for an owned ordinary pause, and verifies running afterward. A lost stop acknowledgement keeps possible ownership for safe shutdown recovery but reports an uncertain state. Manual pauses are never automatically resumed by wake.

## Validation

**VERIFIED — isolated no-VM checks:** `make test` passed 103 Swift tests in 22 suites plus 9 artifact checks. `make test-upstream` passed 549 Swift tests in 107 suites plus the upstream contract, guest-package, shell, compatibility and relocation fixtures. Automated coverage includes manager/CLI acknowledgement handling, nonfatal rejection, timeout/late replies, edit/delete guards, active allocations, shutdown races, coordinated Quit, stale SSH callbacks, hidden paused connection details, the actual SDK command pipe, QMP command/reply transcripts and manual-vs-sleep ownership. Socket fixtures emulate QEMU; no existing guest or disk is accessed by these tests.

**TO PROVE — real guest acceptance:** manual pause/resume, a manual pause held across user-initiated Mac sleep/wake, and graceful shutdown/restart from paused state still need an approved disposable real-guest run. Earlier sleep/wake/SSH acceptance predates this execution-control extension. The known intermittent graphical startup failure remains open. This change does not suspend guests to disk or preserve a paused session across manager exit/reboot.

The 0.7.0 (11) sibling Preview and isolated Layout Preview passed bundle/signature/layout verification. The gallery’s actual Pause → Resume → running controls were checked with Computer Use; library card y/height remained 183/160 points and hero y/height remained 412/200 points. The gallery was closed afterward. The running main app was not replaced or restarted.

The accumulated source pin is `3fa8fad119b2a3269f957e18eca2b6c12d06b66e`; kit SHA-256 is `f1375128dcaab918cdb61991532a2441c192552b82836401e55b1ae83fe2fffe`. QEMU, firmware and factory metadata match the earlier pin. Guest package 0.1.0-40 was rebuilt; payload bytes, permissions and link targets match the prior package, excluding build metadata. The stock vendor checkout remains clean.
