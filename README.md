# Omarchy VM Manager

[Omarchy VM Manager](https://www.reactive.org/omarchy-vm) is a high-fidelity, security-focused sandbox for AI-assisted development on Apple Silicon Macs. Give your coding agents a complete Omarchy Linux environment in a dedicated virtual machine, with its own filesystem, resources and lifecycle.

This project is based heavily on the work of the [Try Omarchy team](https://github.com/omacom/try-omarchy). Their kit provides the VM runtime, official guest image and native Mac integrations; Omarchy VM Manager adds a native macOS app and orchestration for multiple independent guests.

## Why use it?

- **Multiple concurrent Omarchy guests.** Run one guest per project, one per client, or separate environments for experiments and AI agents. Each guest has independent storage and configuration.
- **Official or custom factory images.** Use the official **Try Omarchy v1.3.0 ARM64 edge factory image**, or import a compatible custom factory and select it when creating a guest. Official downloads are checked against pinned SHA-256 checksums; custom bundles are checked against their recorded image, provisioning and runtime hashes. See [Factory images](#factory-images) and the [preparation and customisation guide](docs/preparing-factory-images.md).
- **Automatic setup, ready in minutes.** Save your owner and system defaults once, then create guests that set themselves up with a usable desktop and SSH access. The shared image cache speeds up subsequent guests; first-download and setup time depend on your connection and Mac.
- **Your developer environment, configured your way.** Pair with [reactive.org/dev-vm](https://reactive.org/dev-vm) for a declarative, fully configured developer environment inside the guest. Get each environment set up just the way you like it.
- **A CLI for automation.** Import and select factory images, create guests with custom resources and per-VM owner overrides, start, pause, resume and stop them individually, wait for authenticated SSH, inspect connection details, and update stopped guests through concise JSON responses.

The native SwiftUI app requires macOS 15 or later. The current private debug build provides a persistent guest library, configuration and safe deletion through macOS Trash. Guests start when you choose **Launch** or issue a CLI start command. The two retained POC profiles keep their original configuration and can be moved to Trash through the normal confirmed deletion flow.

**[Read the illustrated user guide](docs/README.md)** · [Getting started](docs/getting-started.md) · [CLI quick start](docs/cli-quickstart.md) · [48-second MP4 tour](docs/media/quick-tour.mp4)

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

### GitHub CI

The [build and no-VM workflow](.github/workflows/test.yml) runs on pushes and pull requests. On the `macos-15` runner it runs `make test`, explicitly compiles the SwiftUI app, CLI and storage helper with `make build`, regenerates the native icons, and runs `make test-upstream`. An `ubuntu-24.04` job runs the isolated container-based SSH checks with `make test-ssh`. OS labels are explicit to avoid automatic major-version migrations; checkout uses the Node 24 runtime.

`make test` runs Swift test cases serially because several fixtures deliberately block synchronous runtime/progress callbacks. Running those cases together can exhaust a small runner's cooperative thread pool. Lifecycle and race tests still run concurrent tasks and independent sessions within each case. Resource-policy fixtures supply synthetic host budgets rather than relying on the runner's CPU/RAM.

Tags matching `vVERSION-dev.N` publish a development-fork `.app` and SHA-256 checksum on [GitHub Releases](https://github.com/reactive-org/omarchy-vm-manager/releases), after both test jobs pass. New tagged jobs use the authorized Developer ID credentials to sign, notarize and staple both the runtime kit and app, then verify Gatekeeper acceptance and the extracted ZIP. The original ad-hoc runtime and development pin are preserved; signed builds use separate exact provenance. Earlier `v0.9.3-dev.3` downloads remain ad-hoc signed. See [development prereleases](docs/Prereleases.md) for setup, compatibility and validation limits.

CI downloads no factory image and starts no guest. Real guest, focus, sleep/wake and crash validation remain separate observed checks on a real Mac; GitHub's ARM macOS runners do not support nested virtualization. Standard GitHub-hosted macOS runners are [free for public repositories](https://docs.github.com/en/actions/reference/runners/github-hosted-runners); larger runners have separate billing.

Signing/notarization secrets are available only to the tagged package step, in a temporary CI keychain that is removed afterward. The signed-prerelease compiler mode accepts only its exact compiled signed-fork provenance and source/team pins. Ordinary production release builds still reject the private development kit; a signed prerelease is not an official upstream release or proof of real-VM acceptance.

## Provenance

- `Config/TryOmarchyUpstream.lock.json`: exact stock tag, source commit, zip digest and unsafe stock clipboard capability.
- `Config/TryOmarchyRuntime.lock.json`: actual private patch commit, patch digest, generated kit digest, build date and full signed file inventory.
- `Sources/OmarchyVMManagerCore/RuntimePin.swift`: compiled SHA-256 of that runtime lock.

The app verifies the compiled lock pin, manifest, helper, protocol and every embedded file. Missing, changed, extra or symlinked files fail closed. Private debug builds accept only the exact locked development kit. Ordinary release builds refuse it; explicitly signed prereleases enforce their separate signed runtime pin. Once reviewed, `Config/TryOmarchySignedRuntime.lock.json` pins the reusable signed variant so later app releases retain its exact bytes. A development-kit rebuild after deleting `VendorArtifacts` creates a new archive/build date, updates the development runtime lock and compiled pin, and requires review. Existing mismatched artifacts are refused, not silently replaced.

`make app` produces an ad-hoc local `dist/Omarchy VM Manager.app` with the verified kit under `Contents/Helpers/TryOmarchyKit.bundle`. It uses no real signing identity or notarization credential. Authorized CI signing reuses upstream's kit pipeline, signing the three networking payloads before rebuilding the daemon that pins them, and signs the app last. The app registers no networking daemon and enables no camera/authentication bridge.

## Use the manager

Open `dist/Omarchy VM Manager.app` and choose **New VM**. The native sidebar lists independent guests; each has Home, Virtual Machine, Network, Startup, SSH and Spaces pages. Configure name, CPU, memory, grow-only disk capacity, clipboard and immersive mode while stopped. New guests default to a 64 GiB sparse disk. Choose the official factory or an imported custom image in **New VM → Factory image**. Creation saves only profile metadata; the official image downloads on the first launch when it is not already cached, while a custom selection uses its imported bundle. Each app or CLI launch selects the guest’s Home card and scrolls it to the top so preparation progress is visible.

Preparing measures unpacking, reaching 100% when decompression and the disk-size check finish. Finishing then covers disk verification and compaction before startup. Sparse images may pause at one unpacking percentage while trailing empty space is processed. See [preparation progress](docs/PreparationProgress.md) for validation and the runtime compatibility change.

**Guest Defaults** saves owner setup for future guests: username, password, optional name/Git email, keyboard, timezone, hostname prefix and optional public key. Enable and save it once, then leave **Use saved owner setup defaults** checked in New VM. Passwords stay in the manager's scoped macOS Keychain storage; profiles hold immutable snapshots and credential references. Credential access follows the build’s [Keychain policy](docs/TouchID.md#development-compatibility--2-november-2026): development builds can reuse saved login-Keychain passwords, while provisioned releases use protected storage. Each hostname gets a unique suffix. The CLI can override non-secret owner fields for one new VM without changing Guest Defaults. Existing guests are unchanged. The prepared image uses a reviewed adapter to Omarchy's owner setup, rather than the ISO disk/encryption installer. See [unattended defaults and validation](docs/UnattendedDefaults.md). A fresh unattended guest passed owner/settings, pinned SSH and restart checks under the historical credential policy; the known intermittent graphics issue remains open.

The schema-versioned private registry lives at `~/Library/Application Support/Omarchy VM Manager/registry.json`. UUID roots derive beneath the sibling `VMs` directory. Reopening restores profiles as stopped. The existing POC roots are validated and registered without modifying their files. Their profiles cannot be reconfigured or renamed, but stopped guests can be deleted through the normal confirmed Move to Trash flow.

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
./bin/omarchy-vm factories
./bin/omarchy-vm list
./bin/omarchy-vm create dev --factory official --memory 4GiB --cpus 4 --disk 64GiB --start --wait ssh --timeout 1800
./bin/omarchy-vm get dev
./bin/omarchy-vm pause dev
./bin/omarchy-vm resume dev
./bin/omarchy-vm stop dev --wait
./bin/omarchy-vm update dev --memory 5GiB --cpus 6 --disk 128GiB
./bin/omarchy-vm start dev --wait ssh
./bin/omarchy-vm restart dev --wait ssh
./bin/omarchy-vm stop dev --wait
./bin/omarchy-vm delete dev
```

For a VM with different owner settings, keep Guest Defaults enabled and saved,
then override only the fields that differ. This example creates a stopped
profile when executed; it does not launch the guest or prepare its disk:

```sh
./bin/omarchy-vm create work --username developer --hostname-prefix work \
  --full-name "Dev User" --email "dev@example.com" \
  --timezone Australia/Melbourne --keyboard "English (US)" \
  --inherit-default-public-key off
```

Omitted settings and the saved password are inherited. Use `--full-name ""` or
`--email ""` to clear those optional fields. `--inherit-default-public-key off`
omits the saved personal SSH key while keeping the manager's per-VM SSH access.
An explicitly supplied `--public-key` still applies. Owner overrides are creation-only;
they cannot be combined with `--owner-defaults off` or applied by `update`.
Flags and the equivalent `ownerOverrides` JSON are covered in the
[CLI quick start](docs/cli-quickstart.md#override-owner-settings-for-one-vm).
These overrides require a manager and CLI built from the updated source;
they are not installed by editing or building the source alone.

Import a prepared custom factory, then copy its exact manifest SHA-256 from the
`factories` response into the creation command:

```sh
./bin/omarchy-vm factory-import /absolute/path/Prepared.factory
./bin/omarchy-vm factories
./bin/omarchy-vm create custom-dev --factory MANIFEST_SHA256 --memory 4GiB --cpus 4 --disk 64GiB
```

This custom example creates metadata only. Start it when ready with
`./bin/omarchy-vm start custom-dev --wait ssh --timeout 1800`. Factory selection
is fixed at creation; `update` cannot change it. Omitting `--factory` selects
`official`. The JSON configuration equivalent is `"factory":"official"` or
`"factory":"MANIFEST_SHA256"` in a file passed with `--config FILE.json`.
Remove an unused imported image with
`./bin/omarchy-vm factory-delete MANIFEST_SHA256`; any guest profile referencing
it blocks removal, even while stopped. Removal moves the imported bundle and
receipt to recoverable Trash. The official factory is protected.

The CLI opens the manager in the background when needed and shares its existing lifecycle owner. Replies are concise JSON, including state/config and an authenticated SSH endpoint plus guest IPs when ready. NAT guests can share a private IP; use the returned localhost SSH port and generated `ssh.command`. Configuration updates refuse running guests and apply next start; delete uses guarded recoverable Trash. Saved Guest Defaults apply to new guests unless disabled. See [the full CLI contract and validation](docs/CLI.md).

## Pause and resume

The development build below pauses execution while retaining RAM. The clarified requirement is suspend-to-disk to release RAM; the current accelerated runtime blocks full VM state saving, and a fresh POC confirmed the official guest kernel has hibernation disabled. See [the suspend investigation](docs/Suspend.md). The development UI now detects the running guest’s kernel capability and basic hibernation prerequisites, with an explicitly opt-in experimental suspend/restore workflow. It remains disabled for the stock kernel; reliable restoration is unproven.

Use a running guest’s ellipsis menu → **Pause**. Its main button becomes **Resume**. The CLI supports `pause ID`, `resume ID` and `wait ID --for paused`. Both commands wait for a helper acknowledgement before reporting success.

Pause keeps the live process, memory allocation, disk lock and SSH port reserved. It does not save state to disk or free RAM. A manually paused guest stays paused across Mac sleep/wake. **Shut Down**, restart and manager Quit resume an owned pause before asking Linux to shut down; **Force Stop…** remains available. Resume before using SSH or editing work inside the guest. Configuration and deletion still require a stopped guest. See [Pause/Resume behavior and validation](docs/PauseResume.md).

## Factory images

### Official factory

The default is the pinned **Try Omarchy v1.3.0 ARM64 edge factory image**.
Downloaded parts and the assembled compressed image are verified against pinned
SHA-256 checksums. Every guest receives an independent writable disk.

### Custom factories

Use **Import Factory** in the toolbar or **New VM** to select a prepared custom
factory bundle. The manager verifies the bundle, copies it into its private
library and records the import. Imported images remain selectable after reopening
the app; no catalog JSON edit or app rebuild is needed. Select an image in
**New VM → Factory image**, or use the [JSON CLI](#json-cli).

A custom factory must be an ARM64 Omarchy UEFI/Limine image compatible with the
manager's exact pinned runtime, integration package and supported owner-setup
contract. Verification establishes integrity and declared compatibility; a
successful boot, owner setup and hardware rendering still need live validation.
Selection is fixed when a guest is created and never replaces an existing disk.

Follow [Preparing and customising a factory image](docs/preparing-factory-images.md)
to build a lean foundation, choose packages and preferences, prepare a bundle,
import it and validate a new guest. See [Custom factories](docs/CustomFactories.md)
for the bundle contract, verification and removal details.

### Cache

Official downloads are shared at
`~/Downloads/Omarchy VM Manager/Factory Images/`, including guests created through
the CLI. Interrupted downloads resume, and cached images are checksum-verified
before reuse. The current pinned image stays cached; obsolete downloads are
pruned after seven days without use. See [factory cache](docs/FactoryCache.md).

Custom imports live separately at
`~/Library/Application Support/Omarchy VM Manager/Factories/<manifest SHA-256>/`.
They have verified local receipts and are not automatically pruned. The original
prepared bundle stays independent of the imported copy. Delete an unused import
with `factory-delete`; deleting a guest leaves its factory available for reuse.
