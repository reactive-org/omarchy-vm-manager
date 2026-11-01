# Guest display activation on interactive launch

**DESIGN DECISION:** Start and confirmed experimental Restore in the manager UI request foreground intent. The manager's public start request and the kit configuration default to background. CLI `create --start`, `start`, `restart` and unattended provisioning explicitly retain background intent. The CLI still opens its lifecycle owner with `open -g -j`.

**PRIVATE COUPLING:** the reproducibly patched kit adds `launchIntent` to its existing configuration and a `display-ready` event to its existing ordered event stream. A missing intent means background; unknown intent values fail validation. The manager requires the exact runtime inventory, compiled lock pin and launch-intent capability version 1. Run protocol 1 alone proves none of this behavior.

After normal QMP readiness, a foreground helper connects to that launch's private, same-user monitor socket and asks the kernel for its peer PID. This extra probe is nonblocking: a busy or unavailable endpoint produces a notice without delaying lifecycle control. It reports the captured PID and kernel process birth time. The manager targets only that process and rechecks its birth time immediately before activation. It never searches by executable name, app name or bundle identifier, enumerates VM processes, or activates the manager/helper as a proxy for the guest.

The launch-scoped request waits up to 15 seconds after the display-process event for the exact app to finish launching and own a normal display window. Window metadata includes other Spaces and uses no window titles, screenshots or Accessibility API. On the manager's main actor, it yields activation to that exact running app and requests activation of its main/key window using the macOS cooperative API. It makes one activation attempt. A rejected request, vanished/reused PID or timeout produces a notice; the guest lifecycle remains owned until `.exited`. macOS can decline activation even after accepting a request.

An error, stopping event, terminal exit, synchronous launch failure, explicit shutdown, forced stop, manual Pause or a non-running execution report cancels pending activation. Duplicate display-ready events cannot restart the request. Ordinary ready, Pause/Resume and host wake do not create activation requests. A new session has a new request, so an earlier failure cannot foreground a later guest. Clipboard routing, keyboard capture, native guest app identity and Spaces placement remain the kit's existing implementations.

## Packaging and compatibility

The vendor submodule stays at stock v1.3.0. The accumulated patch, reproducible source metadata, complete upstream-pipeline ad-hoc kit, runtime inventory and compiled pin change together. QEMU and guest integration source are unchanged. No host-window controller is added to dev-vm.

A changed runtime lock/source provenance makes earlier custom-factory imports incompatible. Preserve their bundles, receipts, profiles and writable disks; do not migrate or relabel them. The candidate is staged separately from installed/running manager apps. This work authorizes no installation, image download, guest launch, permissions or real signing identity.

CI packaging also needs the exact new kit ZIP published as its digest-named runtime dependency, following [prereleases](Prereleases.md#exact-runtime-dependency). Local implementation/verification does not authorize publishing that dependency or a release. Fresh CI acquisition remains unavailable until that separate publication; local builds use the verified artifact produced here.

## Verified no-VM checks — 1 November 2026

Checked on arm64 macOS 27.0.1 with Apple Swift 6.4 and Xcode 27.0 (27A266a), retaining the Swift 6 language mode and macOS 15 deployment target.

- `make test build icon`: 172 manager Swift tests in 32 suites and 34 Python checks pass, followed by the debug app/CLI/storage-helper and icon builds. Focused cases cover UI/CLI entry points, per-session propagation, real SDK configuration transport, background suppression, delayed display readiness, exact identity, duplicate events, timeout, rejected activation, stale PID, synchronous failure, error/stopping/exit/shutdown/force-stop, Pause and host sleep cancellation.
- `make test-upstream`: all 554 Swift tests in 109 suites and the complete upstream contract, guest-package, shell, networking, compatibility and relocation fixtures pass. The real helper with a no-VM monitor stub reports its exact peer only for foreground intent. The native socket regression captures its own kernel identity and fills the listener backlog to verify immediate failure and cleanup; it activates no app.
- `GUEST_BUILDER_IMAGE=try-omarchy-guest-builder make patched-kit`: the complete upstream kit build/test pipeline passes using the existing local builder, with all 22 kit Mach-O signatures verified ad hoc. No factory image or host software is downloaded. Guest package 0.1.0-43 is rebuilt from unchanged guest source.
- `make test-build-policies`: the compiled admission regression passes in ordinary optimized release and optimized `SIGNED_PRERELEASE`, using an unpinned nonexistent kit and no credentials or guest storage.
- `Scripts/build-app.sh --output-directory "$PWD/dist/foreground-validation-85f5e561e5a2" --preserve-runtime-signatures` and `Scripts/verify-app.sh "$PWD/dist/foreground-validation-85f5e561e5a2/Omarchy VM Manager.app"`: isolated assembly, deep/strict signatures, all 25 Mach-O macOS 15 compatibility checks, host preflight, exact resources/runtime inventory, NAT policy and no-factory-image layout pass. Bundle-only assembly diagnostics skip host readiness and open no manager session; the separate full verification performs host preflight without launching a guest.
- `git diff --check` passes. The vendor submodule stays clean at stock v1.3.0. Byte comparison against the preceding runtime lock confirms all QEMU/runtime, firmware and launcher-script payloads are unchanged. Clipboard and keyboard code are unchanged.

The initial sandboxed upstream run lacked local socket/notification access, and an optimized build could not run Apple's dSYM generator. Complete reruns with the required developer-service access pass. New fixture path and Swift 6 actor-isolation errors were corrected before these final checks; no macOS permission was granted.

Final source: `85f5e561e5a277ccec08d7725c8714cb090c9011`. Kit ZIP SHA-256: `e92968e89addb319267e31310ae19ae390a061b4ef842ad0396b4fd4356f5721`. Runtime-lock/compiled-pin SHA-256: `f450c1ac80ba9d6cac3678cf72d80dd10d11f23e0af380acf516c8e11e35dc74`. The ZIP is under `VendorArtifacts/patched-85f5e561e5a2/`; the unopened, uninstalled app is under `dist/foreground-validation-85f5e561e5a2/`.

No existing guest, factory import, receipt, registry, installed app, real signing credential or macOS permission was changed. No real guest or app window was launched. No dependency or app release was published.

## Real macOS acceptance still TO PROVE

Synthetic probes and protocol stubs prove propagation, identity transport, bounded scheduling and cleanup. They do **not** prove actual foreground activation or ⌘Tab behavior.

After separate real-guest approval, use only manager-owned disposable UUID roots and record the app/runtime pins and macOS version. Check:

- Start A from the UI with the manager foreground: A's display app and guest window become active once, including delayed display startup.
- Start B from the UI while A remains running: only B is activated; A is undisturbed.
- Run CLI create/start/restart and unattended provisioning with another host app active: the manager and guest remain background.
- Switch away after activation, then exercise guest readiness, Pause/Resume, host sleep/wake and duplicate notifications: no further activation occurs.
- Stop or fail a launch before the display appears: no delayed activation or activation of another process occurs.
- Check native Dock/⌘Tab identity, assigned Spaces, keyboard capture/release, and both clipboard directions in A/B with background suppression.

Stop all approved test guests, confirm matching `.exited` and no remaining guest processes, then offer to Trash their roots. Native acceptance stays TO PROVE until these observations are recorded.

## Subsequent authorized installation — 1 November 2026

The user explicitly requested installing this verified candidate with a backup and no VM launch or modification. Installed version 0.9.3 (build 16) at `~/Applications/Omarchy VM Manager.app`; preserved the previous bundle at `~/Applications/.Omarchy VM Manager.backup-d11e7d2bc16944bea3526d14b188da00.app`. The installed runtime-lock digest is `f450c1ac80ba9d6cac3678cf72d80dd10d11f23e0af380acf516c8e11e35dc74`.

Rechecked exact executable paths and open bundle files before replacement. The installed destination was inactive. Copied the candidate to a unique sibling stage, verified it, then renamed the previous bundle to its backup and the stage into place. All 64 installed files and every recorded file/directory mode match the candidate, including the bundle root mode; the backup matches the pre-install inventory. Installed and backup bundles pass signature, compatibility, provenance and layout verification against their respective runtime locks. Full read-only diagnostics at the final installed path also pass host preflight. Evidence and rollback inventories are in `.build/foreground-install/d11e7d2bc16944bea3526d14b188da00/`.

No app window was opened, process stopped, VM launched or modified, guest/factory/registry data changed, permission granted or real signing credential used. No UI or guest runtime process was observed at the installed or backup bundle paths after replacement. This supersedes only the earlier installation restriction for this app replacement. Actual foreground/window/⌘Tab and other real-guest checks remain **TO PROVE**.


## Authorized real background-launch check — 1 November 2026

**USER AUTHORIZATION:** test CLI background launches using a new manager-owned disposable VM. The user separately reports that UI launches focus the launched guest while the manager is focused. That UI result is recorded as a user report, not an independently repeated observation here. The earlier prohibition on real guest launches is superseded only for these disposable background checks and their cleanup.

**VERIFIED — guest and manager background behavior:** tested the installed 0.9.3 (16) app with source `85f5e561e5a277ccec08d7725c8714cb090c9011`, kit `e92968e89addb319267e31310ae19ae390a061b4ef842ad0396b4fd4356f5721` and runtime-lock pin `f450c1ac80ba9d6cac3678cf72d80dd10d11f23e0af380acf516c8e11e35dc74`. All three pre-existing guests were stopped before testing. Used only new UUID roots, the compatible official factory, NAT, 4 GiB RAM, 4 CPUs, a 64 GiB sparse disk, enabled clipboard and saved unattended owner/SSH setup through the normal installed CLI. No runtime environment overrides were supplied.

| Case | Observation |
| --- | --- |
| `create NAME --factory official --memory 4GiB --cpus 4 --disk 64GiB --owner-defaults on --start` | The exact guest app finished launching and owned a normal-layer window; neither it nor the manager became active through preparation, automatic owner setup and authenticated SSH readiness. |
| `start UUID` after matching terminal shutdown | A fresh QEMU/helper session reached authenticated SSH readiness without activating the guest or manager. |
| `restart UUID --timeout 180` | The original session exited and a new session reached authenticated SSH readiness, with no guest/manager activation. |
| Repeat fresh `create --start` | A second new disposable root reproduced background guest/manager behavior through authenticated SSH readiness and identified the separate host-focus interruption below. |

A read-only native observer serviced its main run loop, sampled `NSWorkspace` foreground identity and the exact target app's active/finished-launching flags every 100 ms, listened for application activation notifications, and read PID/window metadata without titles or screenshots. It captured 3,393 records for the two runs. Guest identity was bound to each new UUID disk path, the exact installed QEMU executable inode and ancestry through its kit helper to the installed manager. All four observed QEMU sessions owned normal-layer windows; none of their PIDs or the manager PID became frontmost or appeared in activation notifications. The foreground host app was Codex during the first run; the repeat began with Claude and included subsequent host-app switches. No UI input or app activation was generated by the test.

**VERIFIED — full host-focus preservation fails during unattended creation:** the first fresh creation recorded a separate pre-QEMU foreground process. The user reported no interaction during that interval. A targeted repeat with executable-role metadata identified `com.apple.SecurityAgent` becoming frontmost for approximately **5.61 seconds**, before the QEMU process existed. The guest and manager remained background. Therefore the VM-display behavior passes, but do not claim unattended creation is entirely focus-preserving. No permission or Keychain setting was changed and no authentication dialog was answered by the agent.

**TO PROVE — cause/remediation:** this occurs on the fresh saved-owner provisioning path and is consistent with its Keychain password lookup. The exact SecurityAgent trigger and a safe fix have not been established. Warm start/restart of the already configured disposable guest did not reproduce it. This test did not change credential access, suppress system security UI or replace the installed app.

**VERIFIED — cleanup and isolation:** first disposable `437623BF-C98F-4D42-8601-E9C512413487` (`CLI Background Disposable 78f58f29`) and repeat disposable `80A76837-5F3D-444D-87C5-B4FD7A5B12D3` are both stopped, inactive and have cleared session IDs. Standard CLI `stop UUID --wait --timeout 180` completed normally; no forced stop was needed. Confirmed no remaining captured QEMU/helper PIDs, no bridge processes targeting those exact QEMU PIDs, and no open files under either test root. The three original guest records and their checked marker/settings hashes and disk device/inode/mode/size/mtime metadata match the baseline. No existing guest command, factory import/relabel, permission grant or host-software installation was performed. Both stopped disposable roots remain retained pending an explicit Trash decision; they were not recursively erased.

The test interval was 09:18:27–09:23:55 UTC on 1 November 2026. Private evidence is in `.build/background-launch-validation/65557269e2234783956f5afdaaadeb5b/`, including `combined-summary.json`, action/focus traces, process identities, baseline comparisons and the `repeat-create/` evidence. The read-only observers were terminated after the test. Production source and runtime pins are unchanged; `git diff --check` passes for the evidence update.

**Remaining TO PROVE:** manager-not-running CLI bootstrap with `open -g -j`, actual ⌘Tab behavior, assigned Spaces, clipboard/keyboard integration, multiple simultaneous guests, sleep/wake/crash behavior, and resolution of the SecurityAgent focus interruption. The user's focused-manager UI report establishes only that reported UI launch case.
