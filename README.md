# Omarchy VM Manager

A native macOS 15+ SwiftUI manager around Try Omarchy's official kit architecture. Phases 0, 0A and the Phase 1 POC launcher are implemented as a private debug build. Real VM launch remains disabled by default. After explicit POC approval, `--poc-approved` enables only the two fixed disposable manager-owned profiles.

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

`fetch-kit` downloads only the pinned 14 MB stock kit, its checksum and manifest. `patched-kit` reconstructs the exact clipboard patch commit, compiles the helper, derives and ad-hoc signs a complete kit using upstream `macos/build-kit.sh`, then runs upstream `make test-kit`. It never runs `make guest`, downloads a factory image, launches a VM or registers a privileged networking service. The stock kit's QEMU, firmware, guest package and image download metadata are reused byte-for-byte as build inputs; this is not a fresh source build of QEMU or the guest package. The complete resulting kit is signed through upstream's pipeline, not shipped with an unsigned helper replacement.

`make test-upstream` runs the broader upstream no-VM suite on the exact patched source. The upstream Makefile cannot handle spaces in its checkout path, so scripts use a deterministic private build checkout under `/private/tmp/omarchy-vm-manager-source-<commit>`. The checked-in vendor submodule stays at stock `v1.3.0`. `Patches/0001-focus-aware-clipboard.patch` and `Config/TryOmarchyClipboardPatch.json` reconstruct the reviewed local patch commit even on a fresh clone.

The Python scripts refuse optimized execution (`PYTHONOPTIMIZE` or `python -O`) so validation assertions cannot be disabled.

## Provenance

- `Config/TryOmarchyUpstream.lock.json`: exact stock tag, source commit, zip digest and unsafe stock clipboard capability.
- `Config/TryOmarchyRuntime.lock.json`: actual private patch commit, patch digest, generated kit digest, build date and full signed file inventory.
- `Sources/OmarchyVMManagerCore/RuntimePin.swift`: compiled SHA-256 of that runtime lock.

The app verifies the compiled lock pin, manifest, helper, protocol and every embedded file. Missing, changed, extra or symlinked files fail closed. Debug POC builds accept only the exact locked development kit. Release builds refuse it. A rebuild after deleting `VendorArtifacts` creates a new archive/build date, updates the runtime lock and compiled pin, and requires review of those changes. Existing mismatched artifacts are refused, not silently replaced.

`make app` produces `dist/Omarchy VM Manager.app` with the verified kit under `Contents/Helpers/TryOmarchyKit.bundle`. It reuses upstream's signing order and leaves the three networking binaries pinned by the daemon untouched. Only ad-hoc signing is implemented. No signing identity, keychain credential, notarization or permission grant is used. The app registers no networking daemon and enables no camera/authentication bridge.

## Private POC

Two in-memory profiles have distinct stable UUIDs, names, 4096 MiB RAM and four CPUs. Their paths derive from `~/Library/Application Support/Omarchy VM Manager/VMs/<UUID>`. Roots are created only on an approved start, and an existing root must pass ownership and settings checks. The intended bridge list is explicitly clipboard, battery and timezone, with shared/NAT networking.

After approval, start the private app with:

```sh
open -n "dist/Omarchy VM Manager.app" --args --poc-approved
```

Add `--poc-start-a` to start A automatically. Start B after A is ready and its first-boot desktop is usable. The manager refuses overlapping cold starts, reserves the configured aggregate memory/CPUs through exit, checks free space and exact kit provenance/signatures at every start, and initializes private UUID roots with both ownership markers and explicit null inherited settings. The POC refuses changed or unknown settings instead of decoding arbitrary user configurations: this enforces NAT, no forwards, no shared folder, no USB, 4 GiB and four CPUs. Full effective-settings/resource/port policies belong to Phase 3.

The actor and production adapter are testable with fake runtimes and executable protocol stubs. Callbacks enter one ordered event stream; session IDs reject stale events. Errors retain handles and allocations until terminal exit. The production adapter requires explicit debug POC admission to launch. The app offers independent shutdown, confirmed force stop, a bounded event log, live state/progress and quit coordination with a pre-shutdown Cancel action. POC evidence is written privately to the manager’s `Logs/POC-status.json`. The storage helper is a refusal-only executable until Phase 2 implements the locked Trash transaction. Registry persistence, general settings/resource/port admission and user management actions are later phases.

With the VMs stopped, **Enable Super shortcuts…** runs the full Try Omarchy launcher's permission-repair flow for `dev.omarchy.vm-manager` only, then opens macOS Accessibility settings. The user invokes this action and enables the grant themselves. It never resets the installed Try Omarchy app's entry. The manager reports its own permission status; that alone does not prove QEMU installed its keyboard event tap. Start a guest after granting access and verify Command+Space is kept in the guest. Ad-hoc rebuilds can require a fresh grant.

Future MVP requirement: new manager-created guests should automatically accept authenticated SSH connections from the host, using per-VM credentials and verified loopback endpoints, with readiness reported separately from QEMU startup. This is planned as Phase 3A in `intent.md`; it is not implemented by the current POC's temporary debug SSH bootstrap.

The real two-VM run passed focused clipboard transfers, background clipboard suppression for both guests, user-initiated sleep/wake, independent Force Stop, cancelled/normal Quit and manager crash cleanup. Both test guests are stopped, with disks retained. The full Phase 1 gate remains open because of intermittent graphical startup failure; further product phases are paused. See [the run report](Docs/Phase1-POC.md) and [reduced graphics observation](Docs/Phase1-Graphics-Repro.md).

See `Docs/POC.md` for the approval gate and real test matrix, `Docs/ClipboardPatch.md` for the upstream-ready change explanation, and `Docs/Validation.md` for exact results and remaining evidence gaps.
