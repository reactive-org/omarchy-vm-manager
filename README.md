# Omarchy VM Manager

[Omarchy VM Manager](https://www.reactive.org/omarchy-vm) is a high-fidelity, security-focused sandbox for AI-assisted development on Apple Silicon Macs. Give your coding agents a complete Omarchy Linux environment in a dedicated virtual machine, with its own filesystem, resources and lifecycle.

This project is based heavily on the work of the [Try Omarchy team](https://github.com/omacom/try-omarchy). Their kit provides the VM runtime, official guest image and native Mac integrations; Omarchy VM Manager adds a native macOS app and orchestration for multiple independent guests.

## Why use it?

- **Multiple concurrent Omarchy guests.** Run one guest per project, one per client, or separate environments for experiments and AI agents. Each guest has independent storage and configuration.
- **Official, verified factory image.** New guests use the official **Try Omarchy v1.3.0 ARM64 edge factory image**. Downloaded parts and the complete image are verified against the pinned SHA-256 checksums, and cached images are verified again before reuse.
- **Automatic setup, ready in minutes.** Save your owner and system defaults once, then create guests that set themselves up with a usable desktop and SSH access. The shared image cache speeds up subsequent guests; first-download and setup time depend on your connection and Mac.
- **Your developer environment, configured your way.** Pair with [reactive.org/dev-vm](https://reactive.org/dev-vm) for a declarative, fully configured developer environment inside the guest. Get each environment set up just the way you like it.
- **A CLI for automation.** Create guests with custom resources, start, pause, resume and stop them individually, wait for authenticated SSH, inspect connection details, and update stopped guests through concise JSON responses.

The native SwiftUI app requires macOS 15 or later. The current private debug build provides a persistent guest library, configuration and safe deletion through macOS Trash. Guests start when you choose **Launch** or issue a CLI start command. The two retained POC profiles are protected from edits and deletion.

**[Read the illustrated user guide](docs/README.md)** · [Getting started](docs/getting-started.md) · [CLI quick start](docs/cli-quickstart.md) · [44-second MP4 tour](docs/media/quick-tour.mp4)

## Build and check

Use Swift 6 and Python 3.10+ on Apple Silicon. Run `make prepare-source` before opening `Package.swift` in Xcode so the client SDK resolves to the reviewed runtime source:

```sh
git submodule update --init
make fetch-kit
make patched-kit
make test
make app
make verify-app
make run
```

`fetch-kit` downloads only the pinned 14 MB stock kit, its checksum and manifest. `patched-kit` reconstructs the exact clipboard/guest-identity/managed-SSH/owner-setup/download-cache/manual-execution runtime patch commit, compiles the helper, derives and ad-hoc signs a complete kit using upstream `macos/build-kit.sh`, then runs upstream `make test-kit`. It never runs `make guest`, downloads a factory image, launches a VM or registers a privileged networking service. The stock kit's QEMU, firmware and image download metadata are reused byte-for-byte. The helper and versioned guest integration package are source-built; Docker is required for the upstream ARM guest-package builder. No factory image is rebuilt. The complete resulting kit is signed through upstream's pipeline, not shipped with an unsigned helper replacement.

`make test-upstream` runs the broader upstream no-VM suite on the exact patched source. The upstream Makefile cannot handle spaces in its checkout path, so scripts use a deterministic private build checkout under `/private/tmp/omarchy-vm-manager-source-<commit>`. The checked-in vendor submodule stays at stock `v1.3.0`. `Patches/0001-focus-aware-clipboard.patch` and `Config/TryOmarchyClipboardPatch.json` reconstruct the reviewed local patch commit even on a fresh clone.

The Python scripts refuse optimized execution (`PYTHONOPTIMIZE` or `python -O`) so validation assertions cannot be disabled.

## Provenance

- `Config/TryOmarchyUpstream.lock.json`: exact stock tag, source commit, zip digest and unsafe stock clipboard capability.
- `Config/TryOmarchyRuntime.lock.json`: actual private patch commit, patch digest, generated kit digest, build date and full signed file inventory.
- `Sources/OmarchyVMManagerCore/RuntimePin.swift`: compiled SHA-256 of that runtime lock.

The app verifies the compiled lock pin, manifest, helper, protocol and every embedded file. Missing, changed, extra or symlinked files fail closed. Private debug builds accept only the exact locked development kit. Release builds refuse it. A rebuild after deleting `VendorArtifacts` creates a new archive/build date, updates the runtime lock and compiled pin, and requires review of those changes. Existing mismatched artifacts are refused, not silently replaced.

`make app` produces `dist/Omarchy VM Manager.app` with the verified kit under `Contents/Helpers/TryOmarchyKit.bundle`. It reuses upstream's signing order and leaves the three networking binaries pinned by the daemon untouched. Only ad-hoc signing is implemented. No signing identity, keychain credential, notarization or permission grant is used. The app registers no networking daemon and enables no camera/authentication bridge.

## Use the manager

Open `dist/Omarchy VM Manager.app` and choose **New VM**. The native sidebar lists independent guests; each has Home, Virtual Machine, Network, Startup, SSH and Spaces pages. Configure name, CPU, memory, grow-only disk capacity, clipboard and immersive mode while stopped. New guests default to a 64 GiB sparse disk. Creation saves only profile metadata; the official factory image downloads on the first launch when it is not already cached. Each app or CLI launch selects the guest’s Home card and scrolls it to the top so preparation progress is visible.

**Guest Defaults** saves owner setup for future guests: username, password, optional name/Git email, keyboard, timezone, hostname prefix and optional public key. Enable and save it once, then leave **Use saved owner setup defaults** checked in New VM. Passwords stay in the login Keychain; profiles hold immutable snapshots and credential references. Each hostname gets a unique suffix. Existing guests are unchanged. The prepared image uses a reviewed adapter to Omarchy's owner setup, rather than the ISO disk/encryption installer. See [unattended defaults and validation](docs/UnattendedDefaults.md). A fresh unattended guest passed owner/settings, pinned SSH and restart checks; the known intermittent graphics issue remains open.

The schema-versioned private registry lives at `~/Library/Application Support/Omarchy VM Manager/registry.json`. UUID roots derive beneath the sibling `VMs` directory. Reopening restores profiles as stopped. The existing POC roots are validated and registered without modifying their files. Their profiles cannot be reconfigured, renamed or deleted.

The actor reserves aggregate memory/CPUs, serializes cold starts, retains clients through terminal exit and prevents start/delete races. Every launch checks exact kit provenance/signatures, host preflight, free space and the restricted v1 settings contract. Networking remains NAT. New SSH-enabled profiles have one managed localhost SSH forward; shared folders, USB, authentication and camera bridges stay unavailable. The fullscreen adapter applies explicit configuration saves without silently overwriting conflicting external edits. Full effective-settings and port policies remain Phase 3.

Deletion confirms the selected root/disk identity and uses a separate helper holding the runtime-compatible POSIX lock throughout the move to macOS Trash. A pending-deletion journal prevents a crash between the move and registry update from recreating a missing disk. Corrupt/newer/externally changed registry data is preserved. Session progress, notices, errors, shutdown, confirmed Force Stop and coordinated Quit are visible in the app.

For Spaces, launch a windowed guest and use its Dock icon: **Options → Assign To → This Desktop**. The runtime stamps each explicitly rooted guest app with a stable identity independent of its name. The Spaces page contains the steps. Real Dock assignment persistence across restarts remains to be verified with the updated runtime; no private macOS APIs are used.

See [Phase 2 behaviour and validation](docs/Phase2.md). The earlier `--poc-approved`/`--poc-start-a` command-line workflow is superseded by the registry and manual Launch controls.

With the VMs stopped, **Enable Super shortcuts…** runs the full Try Omarchy launcher's permission-repair flow for `dev.omarchy.vm-manager` only, then opens macOS Accessibility settings. The user invokes this action and enables the grant themselves. It never resets the installed Try Omarchy app's entry. The manager reports its own permission status; that alone does not prove QEMU installed its keyboard event tap. Start a guest after granting access and verify Command+Space is kept in the guest. Ad-hoc rebuilds can require a fresh grant.

New profiles enable host SSH by default, with an optional existing-public-key chooser. After normal owner setup, the SSH page verifies a pinned, authenticated connection and offers **Copy SSH Command**. Existing profiles remain unchanged. See [managed SSH design, checks and remaining real-VM validation](docs/ManagedSSH.md). Run `make test-ssh` for isolated OpenSSH container checks; no real VM is launched by that target.

The real two-VM run passed focused clipboard transfers, background clipboard suppression for both guests, user-initiated sleep/wake, independent Force Stop, cancelled/normal Quit and manager crash cleanup. Phase 1 is complete by user acceptance on 31 October 2026, with the intermittent graphics startup failure carried forward for further investigation. Both test guests are stopped, and both disks are kept at the user’s request. The graphics issue and documented unverified checks remain open. See [the run report](docs/Phase1-POC.md) and [reduced graphics observation](docs/Phase1-Graphics-Repro.md).

See `docs/POC.md` for the approval gate and real test matrix, `docs/ClipboardPatch.md` for the upstream-ready change explanation, and `docs/Validation.md` for exact results and remaining evidence gaps.

The manager icon is editable vector artwork in `App/Assets/OmarchyVMManager.svg`, with a 1024-pixel PNG and a complete macOS ICNS family. `make icon` regenerates it using the pinned upstream AppKit renderer and validated icon packer. `make app` includes it in the bundle and the native UI. When the main manager is hosting a guest, `make app-preview verify-preview` prepares a signed sibling bundle without replacing the live app; close the live manager after shutting down its guests before installing the normal build.

Guest artwork uses the official Omarchy mark in monochrome, with pending-trademark attribution to the [Omacom Foundation](https://omarchy.org/foundation/). The sidebar credits this manager as a project of [reactive.org enterprises](https://www.reactive.org/). Launch cards reserve progress/message space and draw busy spinners over the artwork so preparation does not move their controls. `make layout-preview verify-layout-preview` builds a separate debug gallery for the lifecycle presentations without accessing the registry, Keychain or real guests.


## JSON CLI

`make app verify-app` also packages `omarchy-vm`. Use `./bin/omarchy-vm` or add this repository's `bin` directory to `PATH`:

```sh
./bin/omarchy-vm create dev --memory 4GiB --cpus 4 --disk 64GiB --start --wait ssh --timeout 1800
./bin/omarchy-vm get dev
./bin/omarchy-vm pause dev
./bin/omarchy-vm resume dev
./bin/omarchy-vm stop dev --wait
./bin/omarchy-vm update dev --memory 5GiB --cpus 6 --disk 128GiB
./bin/omarchy-vm start dev --wait ssh
./bin/omarchy-vm stop dev --wait
./bin/omarchy-vm delete dev
```

The CLI opens the manager in the background when needed and shares its existing lifecycle owner. Replies are concise JSON, including state/config and an authenticated SSH endpoint plus guest IPs when ready. NAT guests can share a private IP; use the returned localhost SSH port and generated `ssh.command`. Configuration updates refuse running guests and apply next start; delete uses guarded recoverable Trash. Saved Guest Defaults apply to new guests unless disabled. See [the full CLI contract and validation](docs/CLI.md).

## Pause and resume

The development build below pauses execution while retaining RAM. The clarified requirement is suspend-to-disk to release RAM; the current accelerated runtime blocks full VM state saving, and a fresh POC confirmed the official guest kernel has hibernation disabled. See [the suspend investigation](docs/Suspend.md). The development UI now detects the running guest’s kernel capability and basic hibernation prerequisites, with an explicitly opt-in experimental suspend/restore workflow. It remains disabled for the stock kernel; reliable restoration is unproven.

Use a running guest’s ellipsis menu → **Pause**. Its main button becomes **Resume**. The CLI supports `pause ID`, `resume ID` and `wait ID --for paused`. Both commands wait for a helper acknowledgement before reporting success.

Pause keeps the live process, memory allocation, disk lock and SSH port reserved. It does not save state to disk or free RAM. A manually paused guest stays paused across Mac sleep/wake. **Shut Down**, restart and manager Quit resume an owned pause before asking Linux to shut down; **Force Stop…** remains available. Resume before using SSH or editing work inside the guest. Configuration and deletion still require a stopped guest. See [Pause/Resume behavior and validation](docs/PauseResume.md).

## Factory image cache

New guests share a verified download in `~/Downloads/Omarchy VM Manager/Factory Images/`, including guests created through the CLI. The current pinned image stays cached; obsolete image downloads are pruned after seven days without use. Interrupted downloads resume and cached images are checksum-verified before reuse. Guest disks remain independent. See [factory cache](docs/FactoryCache.md).
