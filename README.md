# Omarchy VM Manager

A native macOS 15+ SwiftUI manager around Try Omarchy's official kit architecture. Phase 0 and Phase 0A are implemented as a private debug build. The two-VM POC is prepared but **real VM launch is disabled**. The app does not create VM storage or download the factory image.

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

## Prepared POC

Two in-memory profiles have distinct stable UUIDs, names, 4096 MiB RAM and two CPUs. Their future paths derive from `~/Library/Application Support/Omarchy VM Manager/VMs/<UUID>`. No root exists just because a profile is displayed. The intended bridge list is explicitly clipboard, battery and timezone, with shared/NAT networking.

The actor and production adapter are testable with fake runtimes and executable protocol stubs. Callbacks enter one ordered event stream; session IDs reject stale events. Errors retain handles and allocations until terminal exit. The production adapter's `start` refuses real launch in this milestone. The storage helper is a refusal-only executable until Phase 2 implements the locked Trash transaction. Registry persistence, real storage initialization, resource/port admission and user management actions are later phases.

See `Docs/POC.md` for the approval gate and real test matrix, `Docs/ClipboardPatch.md` for the upstream-ready change explanation, and `Docs/Validation.md` for exact results and remaining evidence gaps.
