# Unattended guest defaults

Status: implemented and verified through an approved fresh first boot, saved owner/system settings, authenticated SSH and a normal shutdown/relaunch. The native form was visually reviewed, and the user confirmed a usable guest desktop without the owner wizard. The test guest has been stopped and moved to Trash at the user’s request; shortcut permission verification is recorded below.

## Evidence and scope

**VERIFIED — official documentation:** [Omarchy unattended installs](https://omarchy.org/manual/unattended-installs/) describes the ISO installer's `cidata` drive with configuration/credential files and optional SSH/Tailscale inputs. The manager uses Try Omarchy's already-installed factory image, not that ISO installer. Attaching an ISO seed alone would not skip this image's owner wizard.

**VERIFIED — current factory image:** `/usr/bin/omarchy-provision-owner` runs when `/var/lib/omarchy/provisioning/pending` exists. It uses Omarchy's own account, keyboard, hostname, timezone, user finalization and cleanup functions. Try Omarchy's existing CI seeds these functions by sourcing the program without its final `main` call. The reviewed program and two provisioning helpers are SHA-256 pinned in `OwnerSetupContract.json`; keyboard presets come from the same installed official setup-form helper.

**DESIGN DECISION:** add a Guest Defaults page for username, password, optional full name/Git email, keyboard, timezone and hostname prefix, plus an optional SSH public key. New profiles take an immutable snapshot when created. The prefix receives a stable per-VM UUID suffix. Later edits affect future profiles only. Existing guests, including all four kept test disks, remain unchanged. Each SSH-enabled guest keeps its independent managed SSH identity; the selected public key follows the existing enrollment path.

**DESIGN DECISION:** save passwords only in the manager's scoped macOS Keychain service. Metadata and registry snapshots contain references, never passwords or password hashes. The OEM provisioner requires the password as normal setup does, so a protected per-VM seed is staged only while provisioning runs: 0700 directories, 0600 files, a separate read-only 9p share, no password in arguments/environment/logs. Only new, explicitly opted-in manager roots receive it. The seed is removed after completion and on terminal cleanup; restarts can recreate a pending seed from its immutable Keychain reference. Unknown credentials/schemas fail closed.

**PRIVATE COUPLING:** the guest integration package supplies validated answers to the reviewed official OEM functions through a conditional systemd wrapper. No Omarchy-owned program is edited or copied into the manager, and disk partition/encryption operations are not introduced. The wrapper must reject a changed contract, a wrong VM/configuration, malformed data and an already-configured owner. Manual guests retain normal setup. The public kit run protocol stays 1; the added provisioning capability and complete kit are independently pinned.

The user's request authorizes storing a password for unattended owner creation. It does not enable password-based manager SSH, capture passwords from guest prompts, or change the policy for existing disks. ISO disk selection/encryption and Tailscale enrollment remain outside this prepared-image implementation.

## Required checks

- Defaults off until saved; optional opt-out per new guest.
- No real Keychain access in unit tests; use a fake store and synthetic secrets.
- Immutable configuration/credential snapshots, unique hostnames, public-key validation and safe handling of changed/unknown metadata.
- Registry schema migration rejects older writers rather than silently discarding provisioning metadata.
- Missing credentials or an unknown runtime capability prevents launch before unsafe root mutations.
- Exact mount/tag/read-only checks, contract verification, no shell evaluation of input, no credentials in arguments/environment/logs, and one-time owner provisioning.
- Completion/progress remains separate from VM lifecycle and authenticated SSH readiness.
- Existing POC and SSH test roots stay intact; no automated setup is applied to them.
- Signed app/resource assembly, native visual review and a separately approved fresh disposable guest must prove zero-interaction first boot, expected owner/settings and authenticated SSH.

## Implementation checks

**VERIFIED — automated checks:** the manager passes 77 Swift tests in 16 suites and 9 artifact tests. These cover old registry compatibility, new immutable snapshots, creation-time opt-out, synthetic credential isolation, private one-shot seeds and current-session status identity. The helper passes 533 Swift tests in 104 suites. Guest checks pass 92 package cases, 9 managed SSH cases and 8 owner setup cases. Linux container checks run the owner tests, verify all three actual reviewed OEM script hashes, and validate the new timer/service boot graph. These checks do not launch QEMU or use a real Keychain item.

**PRIVATE COUPLING:** guest package `0.1.0-40` adds the separate setup share, a package-owned `omarchy-provision-owner.service` drop-in, fixed-code progress reports and a completion acknowledgment for a later boot after manager interruption. The helper admits only matching private UUID/session manifests and strips public environment overrides. A separate `managedSetupVersion: 1` capability is required before the manager stages or launches an opted-in profile. The public run protocol remains 1.

A matching advisory report may remove only that VM's temporary seed; it cannot release lifecycle resources or mark SSH authenticated. Completed profiles need no password read on later launches. A failed/aborted setup can recreate its seed from the original Keychain reference. Both the helper's terminal path and the next stopped-manager admission remove abandoned seeds. No claim of secure physical erasure is made.

**TO PROVE:** real interruption recovery while first-boot provisioning is incomplete; cleanup after an abruptly killed helper rather than a normal exit; changed-binary Keychain access; and visible fallback with a future unsupported factory image. Synthetic tests cover matching identities, terminal cleanup, changed contracts, encryption refusal and retry boundaries. The real run below proves the normal first-boot/restart path. All four earlier disks remain stopped and retained.

**VERIFIED — packaged native UI:** build 0.4.0 (5) opens Guest Defaults with the native grouped settings form, secure password fields, time zone/keyboard selectors, optional public-key chooser and Save Defaults. New VM shows manual setup while defaults are off and keeps SSH on by default. Canceling the sheet creates no profile or disk. The original POC trees match every recorded stat/hash field; both SSH test disks are present without setup metadata. App layout, pinned payload, ad-hoc signatures and host preflight pass.

Source pin: `15da60c9bff031445dfa1c35e4a7a06e4263d4cb`. Kit SHA-256: `19bea40187074b6997a1fcd2fb0321ca25f75dc90b70fc2b28f9c5bfc83f4ef4`.

**VERIFIED — SSH regression:** the package-40 source passes synthetic real OpenSSH tests for two independent guests, optional public-key login, current-session readiness probes, cross-VM key rejection and changed-host-key rejection. These run in disposable containers and do not replace the required fresh QEMU first-boot test.

## Fresh unattended guest — real Mac

**VERIFIED — user-authorized run:** the user entered and saved defaults in the native app, then explicitly approved one additional disposable guest. Creation inherited automatic setup and SSH. Build 0.4.0 (5) retrieved the password from the login Keychain, downloaded the official image and applied guest package 40. Owner provisioning completed without a guest-console bootstrap. The manager received the matching completion identity, removed the staging seed and marked SSH ready only after an authenticated, pinned connection.

A separate host connection using the generated SSH configuration verified the expected non-root owner and current VM/session identity. The configured hostname, full name, Git name/email, timezone, console keymap and input method match the immutable snapshot. Only boolean results and disposable session identifiers were retained in private test evidence; credentials and configured personal values were not printed.

The first shutdown reached the matching `Exited (0)` with no open disk handles. Relaunch changed the guest boot identity and runtime session; pinned SSH and all settings recovered. Original SSH key/pin file identities and the setup completion record remain unchanged. The temporary password seed was not recreated. The graphical session, compositor, shell and active monitor are healthy over SSH. Visible desktop confirmation remains separate from these process checks.

**LIMITATION — private ad-hoc build:** a changed app binary may need the user to refresh macOS Accessibility or Keychain access. Only the same installed build’s save/read flow has been exercised here; no real signing identity or automated permission grant was used. The earlier intermittent graphics startup failure remains open.

The user confirmed the new desktop is usable and did not require the owner wizard. Command+Space initially failed; the final ad-hoc app reported `accessibilityTrusted: false`. All guests were stopped cleanly before the user refreshed only the manager's grant. The manager then reported true and the same test disk was relaunched with no binary change. This keyboard check is independent of unattended owner provisioning.

**VERIFIED — final shortcut and cleanup checks:** after the user refreshed the manager's Accessibility grant, the unchanged build reported trusted access and the guest launcher opened with Command+Space. A further pinned SSH check still matched the expected owner, current session and all saved settings, without a new password seed. Final shutdown reached `Exited (0)`, no manager-owned QEMU process remained and all five disk handles were closed.

The user then requested **Move only the new test guest to Trash**. The manager's normal confirmation and guarded helper moved that complete UUID root to Trash. Its active root and registry entry are gone; the four earlier POC/SSH profiles and disks remain stopped and retained, with no unattended metadata applied. Both original POC trees still match every recorded stat/hash field. Saved Guest Defaults remain enabled. Direct inspection inside macOS Trash was permission-protected, so relocation is evidenced by the helper's successful result plus active-root/registry removal; no extra permission was requested.
