# Phase 2 — persistent native manager

**Status: implemented and validated as a private debug build, 31 October 2026.**

The manager persists UUID profiles, names, creation dates, CPU/memory defaults, clipboard choice and display preferences in a private schema-1 registry. Reopening restores stopped profiles, never saved running state. A process-held manager lock prevents a second manager from writing the same registry. Atomic replacement, version checks and revision comparisons preserve damaged, newer or externally changed data rather than replacing it. Launch also checks the loaded registry revision before touching storage or starting a runtime.

The sidebar, coloured settings icons, grouped panels and launch controls follow the supplied Try Omarchy screenshots. Each guest has Home, Virtual Machine, Network, Startup and Spaces pages. Create and configure sheets edit name, CPU, memory, clipboard and immersive mode while stopped. Storage usage comes from the kit. Progress, notices, failures, bounded session activity, independent shutdown, confirmed Force Stop and coordinated Quit remain visible.

New profiles allocate no disk until first launch. Before starting, admission verifies exact kit provenance, signatures, host compatibility, resource limits and free space. Root initialization creates the UUID directory, ownership markers and all seven null inheritance keys. Memory/CPU are explicit public configuration fallbacks. The versioned fullscreen adapter supports only the reviewed schema. A settings revision captured by an explicit configuration save permits applying that display choice on next start; a conflicting outside edit is preserved and refused. No official factory image is downloaded and no real guest is launched during this implementation’s tests.

Networking remains NAT; port forwarding, shared folders, USB, authentication and camera are disabled. Unknown settings or non-null unsupported overrides fail closed. Full effective-settings/port arbitration belongs to Phase 3, and automatic SSH provisioning belongs to Phase 3A. Advanced upstream settings are not duplicated in the manager.

## Retained POC disks

Both existing POC roots are adopted into the registry by validating their metadata without changing their contents. Their UUIDs are protected in both the actor and storage helper: configure, rename and delete are refused. Missing POC roots are never recreated. The implementation and UI checks do not boot either guest. The Phase 1 intermittent graphical startup issue remains an open follow-up.

## Trash transactions

Deletion requires a stopped profile, explicit confirmation and a review identity binding the root inode, disk inode/size/timestamps and settings revision. The actor marks a storage transaction before awaiting the helper, blocking a concurrent start, edit or second deletion for that profile. It writes a pending-deletion record before moving storage.

The separately signed storage helper accepts a registered UUID and the reviewed identity, derives the root from the fixed manager directory, verifies the pending record and ownership markers, rejects unsafe paths/files and takes the same nonblocking POSIX lock used by the runtime. It holds the lock through the whole-root Mac Trash operation. The registry entry is removed only after the root is confirmed absent. There is no recursive erase operation.

If Trash fails, the registry entry remains. If the manager stops after the move but before committing registry removal, the pending record survives relaunch and prevents a missing disk from being recreated. Reviewing Delete again can finish removing that profile; files already in Trash remain recoverable. Restoring a moved VM to service requires deliberate recovery, not automatic import.

## Mission Control Spaces

The user chose macOS's native Dock assignment workflow. The private runtime adds a stable bundle identifier derived from the canonical explicit storage root to its generated guest app. Identity does not depend on the guest's display name, temporary runtime directory or the root's initial existence. The public `VMRunClient` protocol, QEMU binary and guest image remain unchanged. Default-root launches receive no new identity override.

For a windowed guest, move its window to the desired desktop, Control-click that guest's Dock icon, then choose **Options → Assign To → This Desktop**. Choose **None** to release it. The Spaces page explains this per guest and links to [Apple's guide](https://support.apple.com/guide/mac-help/mh14112/mac). No private window-management API, Dock preference edit or simulated Mission Control input is used.

**TO PROVE:** actual Dock assignment and persistence across guest restarts with the updated runtime. The implementation tests identity generation, first-root creation, aliases, separate roots, generated app metadata and real helper propagation using protocol stubs. Those tests do not establish WindowServer/Dock behaviour with a real guest. The retained POC disks will not be booted for this check without a new request.

## Validation

- `make test`: 53 Swift tests in 8 suites and 9 Python artifact tests pass. Coverage includes registry recovery/permissions/revisions, duplicate managers, all existing lifecycle tests, pending-deletion recovery, unsafe roots/markers/files, external runtime lock contention, lock retention through the Trash callback, start/edit/delete races and bounded UUID-bound helper results.
- Exact patched upstream `make test`: 526 Swift tests in 101 suites plus contract, package and shell suites pass. Real run-mode protocol stubs confirm explicit-root identity reaches the launcher and default-root identity is unchanged. No QEMU guest runs in these suites.
- `make patched-kit`, `make app`, `make verify-app`: pass, including exact payload inventory, nested ad-hoc signatures, 24 Mach-O images compatible with macOS 15 and host preflight.
- Source: `449cc3fad78ffc2b3b60a20c8d6e0aff396f41c1`. Kit SHA-256: `7e030ab17a441e9a5032980b29fd0cd7f5c37d30bf8570bd09bd32dc0e799af5`. Build date: `2026-10-31T03:32:45Z`. The stock vendor checkout remains at v1.3.0.
- Native UI: library, configuration sheet, startup preference, Spaces guide and retained-guest resources were inspected in the real app for clipping/spacing. Create, rename, CPU/memory/clipboard/immersive saves and stopped-profile restoration after Quit/relaunch pass.
- Actual Trash: a tiny synthetic fixture under the UI-created test profile was preserved by Cancel, then moved by the real helper after confirmation; its registry entry was removed afterward and its pending journal cleared. This fixture contained no bootable image. Only the two protected POC profiles remain.
- Retained-disk comparison: both complete trees retain identical entry sets, device/inode identities, permissions, sizes, modification/change timestamps and ownership/settings metadata hashes. No retained guest was launched or opened for writing. No owned QEMU, runtime helper or storage helper remains. The completed manager is open with both profiles stopped.

Private ignored evidence is under `.build/phase2/`; test/build logs are `/private/tmp/omarchy-phase2-*.log`. The final combined check is `/private/tmp/omarchy-phase2-final-checks.log`. No private guest frames/logs or screenshots are committed. No real signing identity, notarization credential or permission grant was used.

The first upstream invocation encountered macOS Python 3.9; using the project’s configured modern Python path resolved it. An intermediate upstream run hit the previously observed TCP teardown fixture bind race; the final unchanged socket suite passes. Identity integration checks exposed Foundation path normalization differences and a non-progressing URL parent traversal; POSIX canonicalization with bounded component traversal and creation/alias tests fixed both before the final kit was built. Manager provenance checks also rejected the transient mismatch while runtime metadata was being regenerated; final source, patch, lock and compiled pin agree.

Real-guest verification of the changed app identity, Dock assignment persistence, keyboard capture and clipboard with this exact Phase 2 kit remains outstanding. The Phase 1 real passes belong to its recorded kit, not this new artifact. The intermittent graphical startup finding remains open.
