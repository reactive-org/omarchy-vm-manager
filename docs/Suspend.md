# Suspend-to-disk investigation

The requested behavior is: preserve guest applications/session, save memory to disk, terminate the VM process so host RAM is released, and restore the session later. A paused process keeps its memory and does not satisfy this requirement. The in-memory [Pause/Resume implementation](PauseResume.md) remains separate from disk suspension.

**Latest result:** a separate hibernation-enabled kernel builds and boots, and original-kernel recovery is verified. Both full hibernation attempts stalled and cold-booted on relaunch. The retained POC is stopped with the original kernel selected by default. Reliable suspend-to-disk remains unproven; see the kernel experiment and opt-in development workflow below.

## Confirmed blocker in the current runtime

The stock v1.3.0 launcher uses `virtio-gpu-gl-pci` and `cocoa,gl=on` (`Vendor/try-omarchy/macos/run-qemu-gpu.sh`, lines 726–727). Its QEMU source pin is `c3d48b7d1e89604920e5b81b91140c2ad39a1943` (`macos/build-qemu-gpu-runtime.sh`, line 95).

That exact [QEMU source](https://github.com/qemu/qemu/blob/c3d48b7d1e89604920e5b81b91140c2ad39a1943/hw/display/virtio-gpu-base.c#L213-L217) registers a migration blocker whenever VirGL is enabled. Read-only `strings` inspection of the SHA-pinned stock `Contents/Resources/runtime/bin/Try Omarchy` binary confirms the same diagnostic. The local upstream graphics patches do not add GPU state serialization. Generic QEMU save-state APIs do not overcome this device limitation. Disabling the blocker would omit live renderer state and is not a safe implementation.

The current writable disks are raw. [QEMU's internal `savevm` snapshots](https://www.qemu.org/docs/master/system/images.html#vm-snapshots) require compatible snapshot storage; simply adding that command would also be insufficient. External state saving could avoid changing disk format, but still requires all devices/CPU state to be saveable, safe disk/config pairing, and a validated restore lifecycle. No current guest or disk was opened or changed to reach these findings.

## Approved POC: Linux guest hibernation

**DESIGN HYPOTHESIS:** Linux hibernation could avoid serializing the host renderer by saving its own memory image and powering off. The approved POC below found that the official image’s current kernel cannot hibernate, so this route is blocked before swap or desktop restoration testing.

Use exactly one fresh manager-owned guest named **Omarchy Suspend POC**, 4 GiB RAM, 4 CPUs and a 64 GiB sparse disk, using the cached official image and saved owner defaults. Host SSH remains the managed, pinned connection. All existing guest profiles, disks and running processes remain untouched. A new real-guest launch requires explicit approval under AGENTS.md.

1. Inspect only that new guest: kernel hibernation support, firmware/kernel command line, swap, systemd sleep policy, guest filesystem, boot identity and desktop readiness.
2. Prepare persistent swap/resume configuration only inside that guest, using an appropriate guest integration path. Verify sufficient host/guest disk space and never expose a password in CLI, logs or test output. Do not weaken SSH, sudo or host permission policy for the test.
3. Run a synthetic workload with an in-memory counter and open guest application. Request hibernation, observe matching terminal exit, and verify the test process and disk handles are closed before considering its host allocation released.
4. Relaunch the same test disk. Verify that the original in-memory workload and session were restored, rather than cold booted. Verify desktop/wallpaper, guest menu, input, focused clipboard and SSH with a fresh authenticated session report.
5. Repeat suspend/resume; test failure to hibernate, host sleep/wake around each transition, normal shutdown after resume, cancelled/failed restore, and safe handling of missing/corrupt state. Never silently cold boot a disk whose saved memory state must be retained.
6. Shut down the POC, confirm exit and closed handles, then review its disposition. A retained disk may be used only after separate explicit authorization; the later kernel experiment below has that authorization.

If guest hibernation fails, record the exact blocker. A software-rendered guest or upstream saveable accelerated graphics would require a separate runtime decision and proof; neither is advertised as a working fallback.

## POC result — 31 October 2026

**VERIFIED — fresh disposable guest:** the user approved one new POC using the cached official image and saved defaults. Created **Omarchy Suspend POC**, UUID `C1FFB37D-49E6-4C55-899B-BAB105C895A4`, with 4 GiB RAM, 4 CPUs and a 64 GiB sparse disk. Automatic setup completed, Hyprland was running and managed SSH authenticated against the expected VM/session and pinned host key, through localhost port 2226. The installed main manager remained 0.6.1 (10); the Pause development candidate was not installed.

Read-only inspection inside this guest found:

| Check | Observed result |
| --- | --- |
| Kernel | `7.2.8-23-omarchy`, `aarch64`, 4096-byte pages |
| Architecture capability | `CONFIG_ARCH_HIBERNATION_POSSIBLE=y` |
| Actual kernel build | `# CONFIG_HIBERNATION is not set` |
| Other kernel features | `CONFIG_SUSPEND=y`, `CONFIG_PM_SLEEP=y`, `CONFIG_SWAP=y` |
| `/sys/power/state` | `freeze mem`; no `disk` state |
| `/sys/power/disk`, `/sys/power/resume`, `/sys/power/resume_offset` | Absent |
| login1 `CanHibernate` | `no` |
| Existing swap | About 3.8 GiB of zram; no persistent disk swap |

**Conclusion:** adding a swapfile or resume boot parameter cannot supply a kernel feature that was compiled out. No hibernation request, swap creation, bootloader/initramfs edit, package replacement or privilege-policy change was attempted. A hibernation-enabled kernel would be a prerequisite for further guest-side experiments; accelerated graphics restoration would still need proof. This POC does not implement or prove suspend-to-disk.

The POC was gracefully shut down with CLI `stop --wait`, which observed matching terminal exit. It is **Stopped**, has no active session, and has no open file/disk handles beneath its root. All six pre-existing guest configurations/activity states/session IDs match the saved baseline; the two existing running guests stayed in their original sessions. No command was sent into a pre-existing guest and no existing disk was changed by this work. The POC disk is retained pending the user’s disposition choice.

**TO PROVE — requires a different supported kernel or runtime:** memory/session restoration, GPU/desktop survival, repeated cycles, guest shutdown after resume, host sleep/wake around suspend/restore and damaged-state recovery. There was no reason to ask the user to sleep the Mac when kernel capability failed at the first gate.

## Eventual manager contract

A production `suspend`/`resume` feature requires a proven mechanism. The explicitly authorized experimental UI below is an opt-in exception and makes no production-restoration claim. Persist a versioned suspended-state record tied to VM, disk identity, runtime version and configuration. A suspended disk must stay protected from config edits, ordinary cold start and deletion until safely resumed or explicitly discarded. Preserve all reservations until matching terminal exit; release RAM only then. Restore must reacquire resource/port admission. Shutdown/quit behavior must explicitly distinguish retaining a suspended session from discarding it. Existing pause commands, if retained, must be labeled as retaining RAM.

No production-ready Suspend implementation or successful real-guest acceptance is claimed. The running main app has not been replaced.


## Authorized kernel rebuild experiment

The user authorized a separate hibernation-enabled kernel and tests in the same retained POC, with the original kernel preserved for recovery. No other guest is a test target. The exact official recipe is `omacom/omarchy-pkgs` commit `9db7ac36d410aca6d571975be1a5a77677918569`, directory `pkgbuilds/linux-omarchy-aarch64`, version 7.2.8-23. The [experimental recipe patch](../Patches/experiments/hibernation-kernel.patch) names the package `linux-omarchy-suspend-poc` and kernel release `7.2.8-23.1-omarchy-suspend-poc`, enables `CONFIG_HIBERNATION`, omits the unused headers/bpftool package, and uses moderate module compression. It preserves the full upstream architecture/device configuration and patch set.

Source checksums passed against both the official SHA-256 and BLAKE2 manifests. All 150 provided detached patch signatures verified against the recipe's pinned public key. The uncompressed kernel tarball signature verified against Greg Kroah-Hartman's pinned fingerprint, retrieved through kernel.org's WKD. The build uses a disposable ARM container and an owned sparse ext4 image. The same power-management patch series that failed on the host-shared filesystem applied cleanly on Linux; no upstream patch was dropped or edited. Build workers were increased from four to eight after checking memory use. No personal signing identity or credentials were used.

A copy-on-write backup of only the stopped POC disk was made before installation. Offline inspection/installation is UUID-restricted and holds the runtime-compatible POSIX lock. Mounts are placed in a separate container namespace and marked for deferred loop-device detach so interruption cannot leave a live disk mount after the container exits. The intended recovery is the original installed kernel plus an unchanged copy of its EFI boot image and a separate visible recovery menu entry. No sudo or SSH access policy is weakened.

**VERIFIED — build, installation and recovery boot:** built `linux-omarchy-suspend-poc-7.2.8-23.1-aarch64.pkg.tar.xz` (120,833,928 bytes), SHA-256 `ccc71050d1b8f2b575145c1f7b31ba6114ba0a707fa366db409dbd312f9df0fc`. Compared with the original running kernel configuration, only hibernation and its automatically selected dependencies changed. Installed the distinct package alongside `linux-omarchy 7.2.8-23`. The experimental kernel booted, authenticated over managed SSH and exposed `freeze mem disk`; Hyprland and Quickshell processes were present. The original kernel image and saved original EFI image retained their checksums. The explicit original-kernel recovery entry was then booted and authenticated over SSH, reporting `7.2.8-23-omarchy`.

The test configuration adds a 6 GiB Btrfs-compatible swapfile, its mapped resume offset, a resume initramfs hook and `HibernateMode=shutdown`. A fixed root-owned one-shot service invokes hibernation; an unprivileged synthetic workload holds 256 MiB of memory. A valid restore requires the same boot identity, PID, random workload nonce and memory hash, plus a counter increment in response to a host challenge sent only after relaunch. The test does not add a general privileged command channel or relax managed SSH identity checks.

**VERIFIED — first full hibernation attempt failed:** the workload armed and the fixed service requested `hibernate.target`. SSH stopped responding, while QEMU remained alive at approximately two host CPU cores of use. It did not power off within the 240-second exit wait. A subsequent 20-second graceful stop also timed out, so only this POC was force-stopped. QEMU exit was verified before releasing its host allocation. The guest disk was not mounted or modified between this stop and the next start.

The unchanged-disk relaunch reported an unavailable resume image and continued with a cold boot. The synthetic process and `/run` proof were absent, and the boot identity changed. Managed SSH authenticated with the new host launch nonce, and Hyprland/Quickshell processes returned, but no preserved session or memory was demonstrated. The fixed test arm had been removed before hibernation, so the cold boot could not rerun the workload and falsely count as a restore. The guest then shut down cleanly.

**VERIFIED — diagnostic retry also failed:** the second full attempt added `no_console_suspend`, `ignore_loglevel` and verbose kernel console output. At about 151 seconds after boot, the log recorded hibernation entry, filesystem sync, successful userspace freezing, preallocation of 417,760 snapshot pages (1,671,040 KiB), and successful freezing of the remaining freezable tasks. Output stopped there. No completed image or power-off was observed within the second 150-second exit wait, and graceful shutdown again timed out. Only the POC was force-stopped. Its unchanged-disk relaunch again cold-booted: the boot identity changed, the synthetic memory proof was absent, and managed SSH authenticated with a fresh launch nonce. It then shut down cleanly.

**Conclusion:** the kernel can be rebuilt and booted with hibernation enabled, but neither test demonstrated suspend-to-disk, automatic host RAM release or memory/session restoration. The failure is after task freezing and before any observed image completion. A specific device driver, console or runtime cause has **not** been isolated. The next investigation should use staged freezer/device power tests and driver callback tracing, following the [kernel power-debugging procedure](https://docs.kernel.org/power/basic-pm-debugging.html), before changing drivers or claiming a workaround. Accelerated desktop restoration, repeated successful cycles and host sleep/wake remain **TO PROVE**. Host sleep was not requested because the basic guest hibernation gate failed.

**Final recovery:** removed the automatic test arm and disabled its timer. Selected the preserved original-kernel EFI entry as the default, booted it again, authenticated over managed SSH and verified `7.2.8-23-omarchy`, its original kernel checksum and the disabled test. Hyprland was present. Both kernel packages remain installed, and the separate experimental boot entry remains available. The final original-kernel boot shut down cleanly; the retained POC is stopped, without an active session or QEMU disk handle. The original-kernel raw recovery files also retain their saved checksums, but that separate raw entry was not boot-tested.

All test commands targeted only this POC. Non-target settings hashes and available disk device/inode/size metadata match the saved inventory; no other disk contents were read or changed. Other registry entries changed during the long run, so continuity of every original profile/session is not asserted. The running main app remains 0.6.1 (10); no app build was installed for this experiment.

The four stopped experimental build containers were removed, and no experimental container remains. Package, recipe, source/build scratch, private reports and the pre-install copy-on-write disk backup are retained under ignored `.build/suspend-poc/`; they are not distribution artifacts. Docker's pre-existing Virtualization file server still caches descriptors for the stopped POC and temporary build files. There is no QEMU handle or active container mount. A normal detach of the owned temporary APFS build volume reported busy, so that scratch volume remains mounted; Docker was not shut down and no forced unmount was attempted. This cache limitation must not be described as zero host file descriptors.

No working Suspend feature is shipped by this experiment.

## Kernel-aware UI and opt-in workflow — 1 November 2026

**DESIGN DECISION:** the user requested capability-based UI controls and explicitly chose an opt-in experimental workflow despite the failed POC. This development candidate adds that workflow; it does not change the negative hibernation results above or claim reliable restoration. Build 0.7.0 (11) is now installed separately at `~/Applications/Omarchy VM Manager.app`; the older project bundle remains running while it supervises a live guest.

The guest Home page reserves a fixed-height **Suspend to Disk · Experimental** panel. After authenticated managed SSH becomes ready, the manager reads the running kernel release, `/proc/config.gz` when available, hibernation sysfs state, active persistent swap, resume device/boot parameters and logind's `CanHibernate` response. Reports are bounded and tied to the expected VM, launch session and owner. Unknown or unreachable capability stays disabled. The stock kernel reports that hibernation is unavailable; a kernel compiled with hibernation can still be blocked by guest security policy or missing prerequisites.

**Suspend…** is enabled only when these basic checks pass: kernel support, a live `disk` sleep state, enough free persistent swap for the kernel's current image-size target, a resume device with boot parameters (including an offset when swapfiles are present), and non-interactive guest authorization. These are prerequisites, not proof that initramfs, swap selection, drivers or graphics restore correctly. An administrator must prepare the guest's kernel, persistent swap, resume initramfs/boot configuration and narrowly scoped logind authorization. The app installs none of these, requests no sudo password and grants no new privileges. The [logind API](https://www.freedesktop.org/software/systemd/man/latest/org.freedesktop.login1.html) distinguishes immediately allowed hibernation from authorization requiring a challenge; only the former enables this action.

Each attempt requires an explicit risk confirmation. The manager then:

1. Rechecks capability and the active VM/session, and creates a private marker on the guest's RAM-backed runtime filesystem. It records a random marker token and the original boot identity internally, without exposing either in CLI JSON or activity logs.
2. Durably writes a versioned `.manager-suspension.json` guard before requesting the fixed `systemctl hibernate --no-ask-password` operation over pinned SSH. There is no arbitrary remote-command interface or automatic privilege escalation.
3. Retains the runtime handle, disk lock, SSH port and RAM admission until the matching terminal exit. An error, lost SSH connection or timeout does not free them. A stalled attempt requires an explicit user shutdown/force-stop; the manager sends no automatic force-stop. Quit is refused while an active experimental transition remains unresolved. Host sleep/wake remains owned by the runtime and never triggers a disk restore automatically.
4. Keeps stopped disks protected from ordinary Launch, CLI start/restart, configuration and deletion. **Restore / Recover…** uses ordinary resource/port admission and checks the original profile, runtime pin, disk identity, settings and the final disk/firmware stamp. Damaged metadata or mismatches fail closed. If the manager was interrupted before recording terminal exit, recovery remains explicitly unverified and checks the stable disk/configuration identity before attempting it.
5. On relaunch, checks the pinned guest identity, original boot identity and RAM marker. A restored old launch nonce is accepted only inside this dedicated memory-verification operation, with the matching boot identity and token; it never promotes normal managed SSH readiness. Normal SSH still requires the new launch nonce.
6. Reports a verified fresh boot with an absent marker as **Cold boot detected**, not a successful restore. Before **Accept Cold Boot…**, a guest administrator must invalidate any stale hibernation image in the configured resume area. The app cannot perform or verify that administrative cleanup: the confirmation button explicitly attests **Confirm Guest Image Cleared**. Only that operator confirmation together with the observed running cold boot releases protection. Complete this recovery before shutting down the cold-booted guest. A verified memory restore clears the guard automatically, but desktop, devices, clipboard and fresh SSH readiness still need checks.
7. Never automatically repeats an unresolved restore boot: it may already have cold-booted and changed the filesystem. **Recheck Recovery** can retry read-only proof verification while that guest remains running. If an unverified/cold-booted restore has stopped, another launch remains blocked and manual recovery is required. The app provides no automated stale-image erasure or unsafe retry shortcut.

The manager never mounts or edits a suspended guest filesystem. This follows the [kernel's requirement to leave its filesystems unchanged between saving and restoring](https://docs.kernel.org/power/swsusp.html). Keep using the same manager/runtime while a guard exists; older builds and external launchers do not understand this experimental marker. There is deliberately no “delete the marker and cold start” shortcut: a still-valid kernel image must not be silently discarded or resumed against an edited disk.

The JSON CLI adds `hibernation`, `experimentalSuspendAvailable`, `experimentalRestoreAvailable`, `suspension` and `suspensionMetadataUnsafe` status fields. Capability reports contain only the kernel release, support status and prerequisite booleans. Experimental power actions currently use the UI; the CLI's existing `resume` command still means in-memory Pause/Resume.

**VERIFIED — automated checks:** core and app build; the current no-VM suite passes 115 Swift tests and nine artifact script tests. These tests exercise opt-in/prerequisite refusal, resource retention, durable guards across reopening, protected edits/ordinary starts, simulated successful restore, cold-boot acknowledgement with explicit administrator-cleanup attestation, timeout/quit/host-sleep event behavior, changed disk/settings/runtime/firmware rejection, malformed/newly appeared metadata and stale asynchronous replies. Disposable localhost-only OpenSSH containers exercise the actual production inspection and marker transport with synthetic keys, plus host-key and cross-guest credential rejection. No power operation is sent to these containers. Those checks do not constitute successful real-guest hibernation, graphics acceptance or real transition sleep/wake coverage. No existing guest or disk was modified to implement this workflow.

The isolated lifecycle layout gallery includes synthetic stock-kernel, missing-setup, ready and unknown capability presentations. `make layout-preview` builds it separately; it accesses no VM registry or network and its experimental buttons perform no guest action. Current UI code compiles; a real macOS visual acceptance run of this new panel has not been performed.
