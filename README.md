# Omarchy VM Manager

A native macOS 15+ SwiftUI manager around Try Omarchy's official kit architecture. Phase 2 provides a persistent VM library, per-guest configuration and safe Trash deletion in a private debug build. Guests start only when you choose Launch. The two retained POC profiles are protected from edits and deletion.

## Build and check

Open `Package.swift` in Xcode, or use Swift 6 and Python 3.10+ on Apple Silicon:

```sh
git submodule update --init
make fetch-kit
make patched-kit
make test
make app
make verify-app
make run
```

`fetch-kit` downloads only the pinned 14 MB stock kit, its checksum and manifest. `patched-kit` reconstructs the exact clipboard/guest-identity/managed-SSH/owner-setup runtime patch commit, compiles the helper, derives and ad-hoc signs a complete kit using upstream `macos/build-kit.sh`, then runs upstream `make test-kit`. It never runs `make guest`, downloads a factory image, launches a VM or registers a privileged networking service. The stock kit's QEMU, firmware and image download metadata are reused byte-for-byte. The helper and versioned guest integration package are source-built; Docker is required for the upstream ARM guest-package builder. No factory image is rebuilt. The complete resulting kit is signed through upstream's pipeline, not shipped with an unsigned helper replacement.

`make test-upstream` runs the broader upstream no-VM suite on the exact patched source. The upstream Makefile cannot handle spaces in its checkout path, so scripts use a deterministic private build checkout under `/private/tmp/omarchy-vm-manager-source-<commit>`. The checked-in vendor submodule stays at stock `v1.3.0`. `Patches/0001-focus-aware-clipboard.patch` and `Config/TryOmarchyClipboardPatch.json` reconstruct the reviewed local patch commit even on a fresh clone.

The Python scripts refuse optimized execution (`PYTHONOPTIMIZE` or `python -O`) so validation assertions cannot be disabled.

## Provenance

- `Config/TryOmarchyUpstream.lock.json`: exact stock tag, source commit, zip digest and unsafe stock clipboard capability.
- `Config/TryOmarchyRuntime.lock.json`: actual private patch commit, patch digest, generated kit digest, build date and full signed file inventory.
- `Sources/OmarchyVMManagerCore/RuntimePin.swift`: compiled SHA-256 of that runtime lock.

The app verifies the compiled lock pin, manifest, helper, protocol and every embedded file. Missing, changed, extra or symlinked files fail closed. Private debug builds accept only the exact locked development kit. Release builds refuse it. A rebuild after deleting `VendorArtifacts` creates a new archive/build date, updates the runtime lock and compiled pin, and requires review of those changes. Existing mismatched artifacts are refused, not silently replaced.

`make app` produces `dist/Omarchy VM Manager.app` with the verified kit under `Contents/Helpers/TryOmarchyKit.bundle`. It reuses upstream's signing order and leaves the three networking binaries pinned by the daemon untouched. Only ad-hoc signing is implemented. No signing identity, keychain credential, notarization or permission grant is used. The app registers no networking daemon and enables no camera/authentication bridge.

## Use the manager

Open `dist/Omarchy VM Manager.app` and choose **New VM**. The native sidebar lists independent guests; each has Home, Virtual Machine, Network, Startup, SSH and Spaces pages. Configure name, CPU, memory, clipboard and immersive mode while stopped. Creation saves only profile metadata; the official factory image downloads on the first launch.

**Guest Defaults** saves owner setup for future guests: username, password, optional name/Git email, keyboard, timezone, hostname prefix and optional public key. Enable and save it once, then leave **Use saved owner setup defaults** checked in New VM. Passwords stay in the login Keychain; profiles hold immutable snapshots and credential references. Each hostname gets a unique suffix. Existing guests are unchanged. The prepared image uses a reviewed adapter to Omarchy's owner setup, rather than the ISO disk/encryption installer. See [unattended defaults and validation](Docs/UnattendedDefaults.md). A fresh unattended guest passed owner/settings, pinned SSH and restart checks; the known intermittent graphics issue remains open.

The schema-versioned private registry lives at `~/Library/Application Support/Omarchy VM Manager/registry.json`. UUID roots derive beneath the sibling `VMs` directory. Reopening restores profiles as stopped. The existing POC roots are validated and registered without modifying their files. Their profiles cannot be reconfigured, renamed or deleted.

The actor reserves aggregate memory/CPUs, serializes cold starts, retains clients through terminal exit and prevents start/delete races. Every launch checks exact kit provenance/signatures, host preflight, free space and the restricted v1 settings contract. Networking remains NAT. New SSH-enabled profiles have one managed localhost SSH forward; shared folders, USB, authentication and camera bridges stay unavailable. The fullscreen adapter applies explicit configuration saves without silently overwriting conflicting external edits. Full effective-settings and port policies remain Phase 3.

Deletion confirms the selected root/disk identity and uses a separate helper holding the runtime-compatible POSIX lock throughout the move to macOS Trash. A pending-deletion journal prevents a crash between the move and registry update from recreating a missing disk. Corrupt/newer/externally changed registry data is preserved. Session progress, notices, errors, shutdown, confirmed Force Stop and coordinated Quit are visible in the app.

For Spaces, launch a windowed guest and use its Dock icon: **Options → Assign To → This Desktop**. The runtime stamps each explicitly rooted guest app with a stable identity independent of its name. The Spaces page contains the steps. Real Dock assignment persistence across restarts remains to be verified with the updated runtime; no private macOS APIs are used.

See [Phase 2 behaviour and validation](Docs/Phase2.md). The earlier `--poc-approved`/`--poc-start-a` command-line workflow is superseded by the registry and manual Launch controls.

With the VMs stopped, **Enable Super shortcuts…** runs the full Try Omarchy launcher's permission-repair flow for `dev.omarchy.vm-manager` only, then opens macOS Accessibility settings. The user invokes this action and enables the grant themselves. It never resets the installed Try Omarchy app's entry. The manager reports its own permission status; that alone does not prove QEMU installed its keyboard event tap. Start a guest after granting access and verify Command+Space is kept in the guest. Ad-hoc rebuilds can require a fresh grant.

New profiles enable host SSH by default, with an optional existing-public-key chooser. After normal owner setup, the SSH page verifies a pinned, authenticated connection and offers **Copy SSH Command**. Existing profiles remain unchanged. See [managed SSH design, checks and remaining real-VM validation](Docs/ManagedSSH.md). Run `make test-ssh` for isolated OpenSSH container checks; no real VM is launched by that target.

The real two-VM run passed focused clipboard transfers, background clipboard suppression for both guests, user-initiated sleep/wake, independent Force Stop, cancelled/normal Quit and manager crash cleanup. Phase 1 is complete by user acceptance on 31 October 2026, with the intermittent graphics startup failure carried forward for further investigation. Both test guests are stopped, and both disks are kept at the user’s request. The graphics issue and documented unverified checks remain open. See [the run report](Docs/Phase1-POC.md) and [reduced graphics observation](Docs/Phase1-Graphics-Repro.md).

See `Docs/POC.md` for the approval gate and real test matrix, `Docs/ClipboardPatch.md` for the upstream-ready change explanation, and `Docs/Validation.md` for exact results and remaining evidence gaps.

The manager icon is editable vector artwork in `App/Assets/OmarchyVMManager.svg`, with a 1024-pixel PNG and a complete macOS ICNS family. `make icon` regenerates it using the pinned upstream AppKit renderer and validated icon packer. `make app` includes it in the bundle and the native UI. When the main manager is hosting a guest, `make app-preview verify-preview` prepares a signed sibling bundle without replacing the live app; close the live manager after shutting down its guests before installing the normal build.
