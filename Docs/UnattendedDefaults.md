# Unattended guest defaults

Status: implementation in progress. New defaults models and scoped credential storage compile and pass no-VM tests. Guest integration and native UI are still being implemented; no real unattended guest has been launched.

## Evidence and scope

**VERIFIED — official documentation:** [Omarchy unattended installs](https://omarchy.org/manual/unattended-installs/) describes the ISO installer's `cidata` drive with configuration/credential files and optional SSH/Tailscale inputs. The manager uses Try Omarchy's already-installed factory image, not that ISO installer. Attaching an ISO seed alone would not skip this image's owner wizard.

**VERIFIED — current factory image:** `/usr/bin/omarchy-provision-owner` runs when `/var/lib/omarchy/provisioning/pending` exists. It uses Omarchy's own account, keyboard, hostname, timezone, user finalization and cleanup functions. Try Omarchy's existing CI seeds these functions by sourcing the program without its final `main` call. The reviewed program and two provisioning helpers are SHA-256 pinned in `OwnerSetupContract.json`; keyboard presets come from the same installed official setup-form helper.

**DESIGN DECISION:** add a Guest Defaults page for username, password, optional full name/Git email, keyboard, timezone and hostname prefix, plus an optional SSH public key. New profiles take an immutable snapshot when created. The prefix receives a stable per-VM UUID suffix. Later edits affect future profiles only. Existing guests, including all four kept test disks, remain unchanged. Each SSH-enabled guest keeps its independent managed SSH identity; the selected public key follows the existing enrollment path.

**DESIGN DECISION:** save passwords only in the manager's scoped macOS Keychain service. Metadata and registry snapshots contain references, never passwords or password hashes. The OEM provisioner requires the password as normal setup does, so a protected per-VM seed is staged only while provisioning runs: 0700 directories, 0600 files, a separate read-only 9p share, no password in arguments/environment/logs. Only new, explicitly opted-in manager roots receive it. The seed must be erased after completion and on terminal cleanup; restarts can recreate a pending seed from its immutable Keychain reference. Unknown credentials/schemas fail closed.

**PRIVATE COUPLING:** the guest integration package will supply validated answers to the reviewed official OEM functions through a conditional systemd wrapper. No Omarchy-owned program is edited or copied into the manager, and disk partition/encryption operations are not introduced. The wrapper must reject a changed contract, a wrong VM/configuration, malformed data and an already-configured owner. Manual guests retain normal setup. The public kit run protocol stays 1; the added provisioning capability and complete kit are independently pinned.

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
