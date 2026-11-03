# Omarchy VM Manager — implementation intent

Status: implementation-ready project brief  
Prepared: 31 October 2026 (Australia/Melbourne)  
Target: a new native macOS SwiftUI application named **Omarchy VM Manager**  
Upstream baseline: Try Omarchy `v1.3.0`, commit `13d63df8da2947f833c04025ff5ade187d39ba81`

## 1. Executive intent

Build a small, standalone macOS application that creates, lists, starts, stops and safely removes multiple independent Omarchy virtual machines. More than one VM must be able to run at the same time. The manager owns orchestration, profiles and shared-host policy; the official Try Omarchy kit continues to own QEMU, the guest image, VM boot, QMP shutdown, Mac sleep/wake handling, image download, host integrations and the guest settings window.

The central boundary is:

> Own the multi-VM management layer, not the virtual machine implementation.

The application must use the official `TryOmarchyKit.bundle` architecture and `TryOmarchyKitClient`/`VMRunClient` from Try Omarchy 1.3. It must not fork QEMU, modify the Omarchy image, invent a second VM protocol or copy the Try Omarchy launcher into this project. Because stock 1.3 does not focus-gate its global clipboard bridge, the POC requires one targeted helper patch built through the official kit pipeline; the intended end state is that patch merged upstream and consumed from a later official release.

The first decision gate is a real two-VM proof of concept on Apple Silicon. Source inspection shows that separate storage roots and separate QEMU processes are structurally supported, but upstream does not claim or test a multi-instance product. Do not invest in a polished manager until two independent guests have been run, slept/woken and stopped independently on a real Mac.

## 2. Evidence labels

This document uses four labels so implementation does not accidentally turn a hypothesis into a contract.

- **VERIFIED — v1.3.0:** confirmed in the tagged Try Omarchy source, its published release metadata or the published kit manifest.
- **DESIGN DECISION:** a choice for Omarchy VM Manager, not an upstream behaviour.
- **PRIVATE COUPLING:** confirmed v1.3.0 behaviour that is not exposed by the public `TryOmarchyKitClient` API. Keep it isolated, versioned and covered by contract tests.
- **TO PROVE:** plausible from source, but not demonstrated with two real simultaneous VMs.

## 3. Goals and non-goals

### Goals

- Create manager-owned VM profiles with stable UUIDs, human-readable names and independent storage roots.
- Run at least two QEMU-backed Omarchy VMs concurrently, with one retained `VMRunClient` per active VM.
- Give every VM an independently visible lifecycle, progress, error and exit state.
- Prevent the manager from launching the same storage root twice.
- Enforce an aggregate memory budget and warn on CPU oversubscription.
- Detect and reserve conflicting NAT host ports before launch, while treating QEMU's bind as authoritative.
- Launch new manager-owned guests with automatically provisioned, host-accessible SSH, and report SSH readiness only after a verified authenticated connection. No manual guest-console bootstrap or clipboard setup should be needed.
- Provide a working Mac clipboard in every running VM, routed only to the currently focused QEMU guest so background VMs neither receive nor publish clipboard changes.
- Shut down guests gracefully, make forced power-off explicit, and prevent deletion while any session can still touch the VM.
- Pin, verify, embed and sign a known Try Omarchy kit.
- Keep the UI intentionally small and native.

### Non-goals for v1

- General-purpose support for arbitrary operating systems.
- Snapshots, cloning, migration, import/export or moving VM storage.
- Embedded guest display, VNC, SPICE, general-purpose terminal, interactive SSH client UI or file browser. A future terminal scoped to approved developer-provisioning jobs is the exception described under the 2 November 2026 provisioning decision below; milestone 1 adds dependency checks only. Provisioning guest SSH access and exposing connection details for host tools are in scope.
- Background clipboard broadcast or a one-VM-only clipboard compromise. A focus-aware runtime fix is a required prerequisite, not a deferred feature.
- More than one bridged-network session.
- Bridged networking at all in the proof of concept or first private MVP.
- USB/camera arbitration, automatic runtime updates or in-app kit downloading.
- A Mac App Store build.
- Replacing Try Omarchy's guest settings UI.

## 4. Verified upstream baseline

All statements in this section were checked against the tagged `v1.3.0` source and release on 31 October 2026.

### Release and package facts

- **VERIFIED — v1.3.0:** `v1.3.0` is a GitHub prerelease published on 23 October 2026. GitHub still identifies `v1.2.0` as the latest stable release. The 1.3 release note says it is the prerelease app, kit and image that Omarchy Installer pins.
- **VERIFIED — v1.3.0:** the tag resolves to commit `13d63df8da2947f833c04025ff5ade187d39ba81`.
- **VERIFIED — v1.3.0:** the published kit manifest is:

  ```json
  {
    "format": 1,
    "version": "v1.3.0",
    "runProtocolVersion": 1,
    "buildDate": "2026-10-23T17:38:57Z"
  }
  ```

- **VERIFIED — v1.3.0:** release assets include `TryOmarchyKit.zip`, `TryOmarchyKit.zip.sha256`, `TryOmarchyKit.json`, `TryOmarchy.dmg` and three factory-image parts. The kit zip is 14,460,427 bytes and its published SHA-256 is `3ad65381b34ced2ebe3f5f19b95d58ec1a2c51a77a6edf7599666a939b6991a6`.
- **VERIFIED — v1.3.0:** `TryOmarchyKit.zip` contains one top-level folder, `TryOmarchyKit.bundle`. The kit carries the helper, QEMU runtime, firmware, scripts, guest integration package and image download manifest. It does not carry the approximately 3 GB factory image; a new storage root downloads the release's image parts on first start.
- **VERIFIED — v1.3.0:** the Swift package manifest is at `macos/Package.swift`, not the repository root. It uses Swift tools 6.0, targets macOS 15 or newer and exports the `TryOmarchyKitClient` library product.
- **DESIGN DECISION:** pin the whole upstream repository as a git submodule at the exact commit and add `Vendor/try-omarchy/macos` as a local Swift package. Do not depend on the repository root as a remote SwiftPM package, and do not copy the four client source files into this repository.
- **VERIFIED — current upstream:** issue [#145, Multiple instances](https://github.com/omacom/try-omarchy/issues/145), remains open with no assignee, milestone, comments or linked pull request. Multi-instance operation is not an advertised Try Omarchy feature.

### Public client surface to use

| Public symbol | Verified behaviour relevant to this project |
| --- | --- |
| `TryOmarchyKit.embedded(in:)` | Finds `Contents/Helpers/TryOmarchyKit.bundle` in an app bundle. |
| `TryOmarchyKit.unpacked(in:)` | Finds an unpacked kit in an external folder. Useful for tests, not the v1 production path. |
| `TryOmarchyKit.helperURL()` | Validates that the bundle and executable helper exist in the expected layout. |
| `TryOmarchyKit.manifest()` | Reads and validates `kit.json`. `TryOmarchyKitManifest.isSupported` requires the kit's run protocol to equal the client's protocol. |
| `TryOmarchyKitVersion` | Parses `vMAJOR.MINOR.PATCH` or `development` and supports version comparison. |
| `TryOmarchyStorage` | Exposes the default Try Omarchy root plus `hasVM`, required/free-space and allocated-space queries for a supplied root. It does not provide create, move or delete operations. |
| `VMRunClient.preflight()` | Rejects macOS older than 15, non-Apple-Silicon hosts and hosts without Hypervisor support. |
| `VMRunClient.start(_:environment:onEvent:)` | Launches `omarchy-vm-helper --run-vm`, sends one configuration line and follows ordered events on a private serial queue. One client refuses a second concurrent start of itself. |
| `VMRunClient.isRunning` | True from a successful start attempt until final cleanup. |
| `VMRunClient.recentStandardError` | Bounded tail of helper diagnostics, suitable for an error detail view and logs. |
| `VMRunClient.shutDown()` | Requests a guest shutdown. The helper waits up to 60 seconds before stopping QEMU. |
| `VMRunClient.terminate()` | Immediate power-off semantics; it sends two signals and kills a stuck helper after a five-second default grace period. Unsaved guest work can be lost. |
| `VMRunConfiguration` | Supplies product name/icon, explicit storage root, optional bridges, fallback memory/CPU and fallback shared/bridged networking. |
| `VMRunEvent` | `progress`, `notice`, `ready`, `stopping`, `error` and terminal `exited`. `exited` arrives only after the helper ends, at which point the client can be reused. |
| `VMRunErrorCode` | Stable codes include `vm-already-open`, storage failures, port/launch failures, sleep/wake failures and compatibility failures. Messages are not stable identifiers. |

Important public constraints from `VMRunConfiguration.validate()`:

- product name: 1–64 characters, no leading/trailing whitespace or control characters, and no more than 255 UTF-8 bytes;
- storage root: absolute, single-line path no longer than 1,024 characters;
- icon: existing regular `.icns` or `.png` at an absolute path;
- memory fallback: 2,048–1,048,576 MiB;
- CPU fallback: 1–1,024;
- bridge choices: `clipboard`, `authentication`, `camera`, `battery`, `timezone`;
- networking: `shared` (NAT) or `bridged`.

`VMRunConfiguration` defaults to all optional bridges. Omarchy VM Manager must always pass an explicit restricted bridge list.

### Verified runtime behaviours that make concurrency plausible

- A configuration can name an explicit `storageRoot`; that folder is the VM.
- `VMRunClient` and `VMRunSession` are instances, not global singletons. One manager can retain multiple clients.
- Persistent storage is locked at `<storageRoot>/shell/lock`. A second launch of the same root fails instead of sharing a disk.
- Each run creates a private `mktemp` work directory. QMP, audio, clipboard, authentication, camera, battery, timezone, guest-status and settings sockets are per-run.
- QEMU holds the VM lock for its full lifetime.
- QMP, download, sleep/wake, removed-volume handling and graceful shutdown are already owned by the kit.
- The run-mode helper shuts down when asked, when standard input closes or on its first termination signal. If the manager crashes or is force-quit, the child sees its input close and begins a guest shutdown.
- A product name is used for the QEMU window, Dock entry and application menu. This gives concurrent guests distinct visible identities without the manager embedding their displays.

### Verified limitations and hazards

#### Stored settings override configuration fallbacks

Memory, CPUs and networking in `VMRunConfiguration` are only fallbacks. Values in the VM's `settings.json` win. Port forwarding, shared folder, USB, immersive mode and camera-notch settings are stored-only and have no public configuration field.

Older Try Omarchy settings are also relevant. Up to Try Omarchy 1.2, settings lived in the `dev.tryomarchy.native` UserDefaults domain. In 1.3, a key in a VM's settings file wins—even when its value is `null`; an absent key can fall back to the old UserDefaults value. A newly named storage folder can therefore inherit an old global setting unless the manager deliberately initializes the per-VM file.

This invalidates a naive resource policy that only totals the manager's requested fallbacks.

#### Clipboard is not multi-session aware

Each enabled clipboard bridge polls the same global `NSPasteboard.general` every 250 ms and maintains only its own two-endpoint echo-suppression state. It does not test QEMU focus. With two unmodified 1.3 clipboard bridges, content can propagate between guests through the Mac pasteboard.

The public API chooses bridges only at process start. It exposes no QEMU PID, focus event or dynamic enable/disable command. A correct focus-aware clipboard broker cannot be implemented solely in the manager against v1.3.

**DESIGN DECISION / REQUIRED RUNTIME PREREQUISITE:** do not solve this by disabling clipboard on all but one VM. Add focus gating to Try Omarchy's existing `NativeClipboardBridge`, which already receives the target QEMU PID, and propose that small change upstream. The public `VMRunClient` protocol does not need to change. Until the change is accepted in an official release, a private POC may use a source-built, digest-pinned kit based on v1.3.0; a distributable manager must not pretend the stock v1.3.0 kit provides safe multi-VM clipboard.

#### Port forwarding has no public configuration or inspection API

NAT forwards bind to Mac loopback. The kit validates each VM's mappings and probes host availability immediately before QEMU starts; QEMU's actual bind remains authoritative. Two VMs cannot both own the same `(protocol, hostPort)`.

The mappings live under the private `portForwardingPreferences` setting. The public client cannot read them, and `VMRunConfiguration` cannot set them.

#### Bridged networking is single-session

The v1.3 networking runtime reports a specific error when another bridged session is active or finishing cleanup. Bridged networking also needs a privileged launch daemon registered by the embedding app. NAT is the only acceptable v1 default.

#### Resource validation is per VM

The launcher checks one VM at a time. Its shell-level memory rule allows the 4 GiB baseline, otherwise requiring at least 4 GiB to remain for macOS. It does not subtract memory already assigned to other QEMU processes.

#### There is no public window activation API

The manager cannot reliably implement an “Open” or “Bring to Front” action for a guest. v1 should rely on the distinct QEMU Dock entries and macOS window switching.

#### First-start work is duplicated per independent root

Each manager-owned storage root has its own `shell-factory` cache. Starting two new VMs can cause two independent image downloads and decompressions. The public configuration has no shared-factory-cache field.

## 5. Product definition

The first usable application is a development-focused VM list, not a Parallels competitor.

### Main window

Show:

- application title;
- number of running VMs and their total configured memory;
- a **New VM** button;
- one row per VM with name, state, memory/CPU summary, storage used and last error;
- **Start**, **Shut Down**, **Force Stop** and **Delete** actions as permitted by state;
- progress text and percentage while downloading or preparing;
- a clipboard-enabled badge for each profile; do not claim live bridge health because run protocol 1 exposes no bridge-specific status event.
- for SSH-enabled profiles, the host SSH endpoint and separate provisioning/readiness status, plus a **Copy SSH Command** action; never include private-key contents.

Do not add guest thumbnails, embedded consoles, settings duplication or resource graphs to v1.

### Create sheet

Collect:

- display name;
- memory fallback;
- CPU fallback;
- whether clipboard integration is enabled for that VM (on by default once the focus-aware runtime prerequisite is present).

Networking is fixed to NAT in v1. Ports are configured through the kit's existing guest settings window after the VM is first run; the manager only inspects and arbitrates them before subsequent launches.

### State presentation

Use a closed state model rather than independent booleans:

```swift
enum VMState: Equatable, Sendable {
    case stopped
    case validating
    case downloading(phase: VMRunPhase, percent: Int?)
    case starting(phase: VMRunPhase, percent: Int?)
    case running
    case stopping
    case failed(VMFailure)
}
```

`failed` is a stopped state with retained diagnostic context; it never means a client is still touching the VM. A VM remains in a transitional/running state until the matching `.exited` event.

## 6. Architecture

```text
SwiftUI application / AppDelegate
        |
        v
VMManager actor ---------------- RegistryStore
  |       |                      manager-owned metadata
  |       +-- HostResourcePolicy
  |       +-- PortReservationLedger
  |       +-- ClipboardCapabilityPolicy
  |       +-- UpstreamSettingsSnapshotReader [private v1.3 coupling]
  |       +-- StorageSafety / StorageTransactionHelper
  |
  +-- RuntimeSession(UUID) ---- VMRuntime protocol
                                  |
                                  +-- TryOmarchyRuntime
                                        one VMRunClient per active VM
                                        explicit storageRoot
                                        explicit bridges
                                        shared/NAT networking
                                                |
                                                v
                                      TryOmarchyKit.bundle
                                      with required focus-aware clipboard fix
                                      helper -> QEMU process per VM
```

### Targets

1. **OmarchyVMManagerApp** — SwiftUI app entry point, views, commands and AppDelegate termination coordination.
2. **OmarchyVMManagerCore** — models, registry, actor, policies and a runtime abstraction; no SwiftUI dependency.
3. **OmarchyVMStorageHelper** — small manager-owned executable for destructive storage transactions under a process-scoped POSIX lock.
4. **OmarchyVMManagerCoreTests** — fast unit and contract tests.
5. **OmarchyVMManagerUITests** — minimal create/start/stop state presentation tests once the shell is stable.

### Runtime abstraction

Keep the abstraction narrow and shaped around what the product needs, not around every kit type:

```swift
protocol VMRuntime: Sendable {
    func preflight() -> VMRunError?
    func start(_ request: VMStartRequest,
               onEvent: @escaping @Sendable (VMRuntimeEvent) -> Void) throws -> VMRuntimeHandle
}

protocol VMRuntimeHandle: AnyObject, Sendable {
    var isRunning: Bool { get }
    var recentStandardError: String { get }
    func shutDown()
    func terminate()
}
```

The production adapter wraps `VMRunClient`; tests use a deterministic fake. Do not attempt to make an arbitrary-hypervisor framework.

### Concurrency and ownership

- `VMManager` is an actor and the single authority for registry mutations, state transitions, launch admission, port reservations and client retention.
- UI-facing snapshots are published on `@MainActor` through a small observable view model.
- `VMRunClient` delivers events on its private serial queue. Every callback immediately enters the manager actor before changing state.
- Every start gets a fresh `sessionID`. Ignore an event whose `(vmID, sessionID)` no longer matches the active session.
- Retain the client until `.exited`, even after `.error`. `.error` is diagnostic; `.exited` is the lifecycle boundary.
- Do not reuse one client across concurrently active VMs.

## 7. Persistence and storage

### Manager data layout

```text
~/Library/Application Support/Omarchy VM Manager/
├── registry.json                         # 0600, atomic, schema-versioned
├── VMs/                                  # 0700
│   ├── <uuid>/                           # explicit storageRoot, 0700
│   │   ├── .omarchy-vm-manager.json      # manager ownership marker, 0600
│   │   ├── .omarchy-qemu-storage         # upstream v1 marker, 0600
│   │   ├── settings.json                 # upstream settings file, 0600
│   │   ├── shell/
│   │   └── shell-factory/
│   └── ...
└── Logs/                                 # bounded manager logs; no clipboard content
```

`registry.json` stores only manager metadata: schema version, UUID, display name, created date, manager resource defaults and whether clipboard integration is enabled. The storage path is derived from the UUID, not accepted from the JSON as an arbitrary absolute path.

Phase 3A adds versioned SSH metadata: enablement, allocated loopback port, intended guest username, credential reference and pinned public host identity. Private keys and passwords never belong in the registry or logs.

### Creation invariants

For v1, all roots are manager-owned and below the fixed `VMs` directory. Importing or using an arbitrary external path is deferred.

Before the first start:

1. Create the UUID directory with mode `0700` and verify owner, type and canonical parent.
2. Atomically create `.omarchy-vm-manager.json` with the UUID and schema version, mode `0600`.
3. **PRIVATE COUPLING:** create the v1 upstream marker `.omarchy-qemu-storage` containing exactly `omarchy-qemu-storage-root-v1\n`, mode `0600`.
4. **PRIVATE COUPLING:** create v1 `settings.json` with schema 1 and every known inherited setting key explicitly set to `null`. This prevents a new manager VM from inheriting old Try Omarchy 1.2 global preferences while allowing configuration fallbacks to apply.

The initialized settings object should contain these v1 keys as `null`:

```json
{
  "schemaVersion": 1,
  "settings": {
    "vmResourcePreferences": null,
    "memoryPreferences": null,
    "networkPreferences": null,
    "portForwardingPreferences": null,
    "sharedFolderPreferences": null,
    "usbDevicePreferences": null,
    "fullscreenPreferences": null
  }
}
```

This is the smallest private compatibility layer that makes new roots deterministic. Isolate marker/settings knowledge in `TryOmarchyV1StorageContract`; do not scatter keys through the application.

For future SSH-enabled profiles, Phase 3A may intentionally initialize a validated manager-owned SSH mapping after this null initialization and before first launch, using the supported kit API or a separately reviewed versioned adapter. This is an explicit creation step, not inheritance from global preferences. Existing mappings must not be silently overwritten during launch admission.

### Deletion invariants

Deletion means moving the manager-owned root to the macOS Trash, not recursively erasing it in place.

Allow deletion only when:

- the manager state is stopped/failed and there is no retained client;
- no start/stop/create transaction exists for the VM;
- the canonical target is exactly `VMs/<registered UUID>`;
- the manager marker is a private regular file and contains the same UUID;
- a dedicated helper process acquires the same style of non-blocking POSIX lock used by the runtime on `shell/lock` and holds it through the move to Trash.

The helper must refuse symlinks, a missing/invalid marker, an unknown marker schema, unexpected ownership, group/world-writable directories, a busy lock or a path outside the manager root. It returns a structured result. The manager removes the registry entry only after Trash succeeds. A failed move leaves both registry and VM intact.

## 8. Launch admission and lifecycle safeguards

### Start algorithm

All of these steps run as one manager-actor transaction until the client has been successfully started:

1. Require state `stopped` or `failed`; assign a fresh `sessionID` and move to `validating`.
2. Resolve and validate the manager-owned canonical root and markers.
3. Reject if another active session has the same canonical root or file-system resource identifier.
4. Load and validate the pinned embedded kit manifest and provenance lock. Stock/reference mode requires exactly `v1.3.0`, protocol 1 and `isSupported == true`. Clipboard POC mode permits `development` only in a non-release build whose exact patch commit and kit digest match the committed runtime lock. Release builds reject `development`.
5. Run `VMRunClient.preflight()` and `kit.helperURL()`.
6. Read a fail-closed effective settings snapshot for memory, CPU, network and port mappings.
7. Require shared/NAT networking for v1. If stored settings request bridged mode, explain that it must be changed to Shared connection before this manager can start it.
8. Calculate effective resources: stored v1 resource settings, then the configured fallback. Reject an unknown or malformed resource schema rather than guessing.
9. Apply the aggregate host resource policy and storage free-space policy.
10. Reserve every `(protocol, hostPort)` in the manager ledger; report the owning VM for manager conflicts. Probe the operating system for external conflicts.
11. Require the focus-aware clipboard capability when clipboard is enabled, then build an explicit bridge list including `.clipboard`. Refuse concurrent clipboard launch against an unmodified stock v1.3.0 kit rather than falling back to unsafe broadcast behaviour.
12. Construct `VMRunConfiguration` with a unique product name, explicit root, explicit bridges, effective fallback memory/CPU and `.shared` networking.
13. Create and retain a new client, then call `start` with its default clean environment. Do not pass any `OMARCHY_*`, `TRYOMARCHY_*` or `SDL_*` override.
14. If `start` throws synchronously, release reservations and return to `failed`. Otherwise keep reservations and the client until `.exited`.

Serialize manager-initiated starts through admission. After `start` returns, a later VM can begin admission, but for a brand-new VM wait until the previous cold start is `.ready` before starting another download. This avoids two simultaneous 3 GB downloads/decompressions while still proving simultaneous QEMU execution.

### Event handling

- `progress`: map the upstream phase and percentage into downloading/starting UI. Unknown future events are already skipped by the client.
- `notice`: retain and display it without failing the session.
- `ready`: set `running`; this is the point at which a second cold VM may start.
- `stopping`: set `stopping`.
- `error`: retain stable code, reported code, message and sanitized stderr tail, but do not release anything yet.
- `exited`: clear the client, release ports/resource allocation, finish any quit coordination and choose `stopped` or `failed` based on the preceding error and status.

### Shut down and force stop

- Normal **Shut Down** calls `VMRunClient.shutDown()` once and changes state to `stopping`.
- The kit asks Linux to power down and stops QEMU if it has not exited after 60 seconds. The manager should show elapsed shutdown time but must not send repeated shutdown commands.
- **Force Stop** calls `terminate()` only after an explicit warning that unsaved guest work can be lost.
- Starting, deleting or editing launch-time policy remains disabled until `.exited`.

### Application termination

Use `NSApplicationDelegate.applicationShouldTerminate` via `NSApplicationDelegateAdaptor`:

1. If no clients are active, return `.terminateNow`.
2. Otherwise return `.terminateLater`, call `shutDown()` for every active session and show a compact “Shutting down N VMs” panel.
3. When every matching `.exited` arrives, call `reply(toApplicationShouldTerminate: true)`.
4. If the user cancels application termination, leave the VMs running.
5. If the app itself crashes or is force-quit, rely on the verified helper stdin-close behaviour; verify this in the POC rather than treating it as a substitute for normal coordination.

## 9. Resource policy

### Memory

Use physical memory, not currently-free memory, for deterministic admission.

Default hard budget:

```text
hostReserveMiB = max(4096, floor(physicalMemoryMiB * 0.25))
guestBudgetMiB = physicalMemoryMiB - hostReserveMiB
```

Reject a launch when the sum of effective memory for running, starting and newly requested VMs exceeds `guestBudgetMiB`. Show the calculation and identify the active allocations. Do not provide a “launch anyway” override in the first MVP.

For a new profile, propose 4,096 MiB when two such VMs fit the budget. On an 8 GiB Mac, a two-VM engineering POC may explicitly use the public minimum of 2,048 MiB per guest, but label it a constrained test rather than the recommended experience.

### CPU

CPU is oversubscribable. Warn when aggregate vCPU count exceeds the host logical processor count and block only when it exceeds twice that count. Keep the policy in one testable type so experience can change it later.

### Storage

- Use `TryOmarchyStorage.hasVM`, `requiredFreeBytes(at:)`, `freeBytes(at:)` and `allocatedBytes(at:)` for display and baseline checks.
- A new root requires the upstream 15,000,000,000-byte minimum; an existing VM requires 1,073,741,824 bytes.
- Add a manager margin of 2 GiB per start for logs, temporary files and concurrent work.
- Cold starts are serialized until `.ready`; this avoids double-counting changing free space during concurrent image preparation.
- Never infer safety from the sparse disk's logical size. Display allocated size from the upstream helper.

### Effective-settings reader

**PRIVATE COUPLING:** `UpstreamSettingsSnapshotReader` is a read-only decoder for the v1.3 `settings.json` keys needed for admission. It must reproduce the upstream file safety checks before reading:

- root is manager-owned, canonical and mode `0700`;
- file is a non-symlink regular file owned by the current user, mode `0600`, no larger than 65,536 bytes;
- outer `schemaVersion` is exactly 1;
- settings object exists;
- known payload schemas and ranges are exact;
- an unknown outer/payload schema, invalid type or invalid range fails closed.

Decode only:

- `vmResourcePreferences` (`schemaVersion: 1`, resources containing CPU, memory GiB and optional disk GiB);
- legacy `memoryPreferences` if no VM resource value exists;
- `networkPreferences` (`version: 1`);
- `portForwardingPreferences` (`schemaVersion: 1`, at most 32 TCP/UDP mappings with ports 1–65535).

Never rewrite the user's settings during launch admission. Initialization of a new manager-owned root is the only direct settings write in v1. Put fixture files copied from the tagged upstream tests under `Tests/Fixtures/TryOmarchy/v1.3.0/` and add a source-pin test that fails loudly when the vendored upstream keys or schemas change.

Recommended upstream follow-up: propose public read-only effective-settings and storage-initialization APIs in `TryOmarchyKitClient`. Remove this adapter when upstream supplies them.

## 10. Port safeguards

Use a `PortReservationLedger` owned by `VMManager`.

Rules:

- Reservation key is `(tcp|udp, hostPort)`. TCP and UDP may use the same numeric port; two TCP or two UDP mappings may not.
- Only NAT mappings are active. Bridged VMs are refused in v1.
- Reserve before calling `start`; release only on synchronous start failure or terminal `.exited`.
- A conflict with another managed session names that VM and mapping.
- Probe both TCP and UDP loopback availability for conflicts with other Mac applications.
- Serialize manager starts to close the race between two manager sessions.
- Do not claim the probe is a lock. An external process can still bind after the probe; QEMU's bind is authoritative. Convert the resulting launch failure into a port-specific error and include the requested mapping when it can be identified.
- Never bind to a non-loopback address in the manager. The v1.3 NAT runtime forwards on `127.0.0.1`.
- Do not use the public `environment:` argument to inject `OMARCHY_QEMU_GPU_PORT_FORWARDS`; upstream documents those variables as development overrides and the default client deliberately cleans them.

### Managed host SSH — next implementation milestone

**DESIGN DECISION — user requirement, 31 October 2026:** new manager-owned guests should become ready for SSH from the host automatically. SSH provisioning must not depend on a working graphical shell, clipboard, Accessibility permission or a manually pasted command. The temporary SSH bootstrap used to investigate Phase 1 is a diagnostic exception, not the product implementation.

**VERIFIED — v1.3.0:** the kit can forward Mac loopback ports to the guest and start the existing guest SSH server for that boot when SSH is forwarded. Its public `VMRunConfiguration` has no authorized-key provisioning or authenticated SSH-readiness API. Port mapping remains the private settings coupling described above. These capabilities alone do not provide unattended SSH access.

Requirements:

- Enable managed host SSH by default for newly created manager profiles. The creation sheet has **Enable SSH from this Mac**, checked by default, with an explanation that access uses a guest-specific Mac loopback endpoint. Existing manager profiles need an explicit migration/enablement action; personal/default Try Omarchy VMs remain excluded.
- Offer an optional **Add my SSH public key…** chooser at creation. Validate the selected OpenSSH public key, show its fingerprint, and install only its public material for the intended non-root owner after that account exists. Never copy or request the user's private key, infer a key from a private-key filename, scan personal credentials, or replace existing authorized keys. The manager's per-VM credential remains independent so readiness checks do not depend on unlocking a personal key or agent.
- With no existing public key selected, provision the per-VM manager key automatically and supply a working **Copy SSH Command** using the matching protected host identity. Selecting a personal public key is optional convenience, not a prerequisite for passwordless manager access.
- Automatically register the guest's initial public host key only after associating it with the expected VM through the trusted per-VM provisioning channel, then pin it for later connections. Ordinary connections should not need a first-use host-key prompt. A changed key requires explicit recovery; do not disable host-key checking. Keep manager-owned known-hosts/configuration separate from the user's global SSH files unless they choose an explicit integration action.
- Provision a dedicated manager-side SSH client key pair per VM for an intended non-root guest account. Install only its public key through a supported upstream first-boot/guest-integration mechanism. Do not bake shared keys into the factory image, copy another VM's credentials, patch Omarchy-owned files or depend on an embedded terminal.
- Keep the private credential in an appropriate protected host store, with only a reference in profile metadata. Never request, store or log the guest's password as the SSH bootstrap mechanism. The private implementation uses per-VM 0700 directories and 0600 files under the owned root, with separate known-hosts/configuration; unattended client keys are not encrypted. See `docs/ManagedSSH.md`.
- Use key authentication for the manager's access, an explicitly selected identity and pinned guest SSH host keys. Disable agent forwarding and password fallback for manager-initiated connections. Generate/preserve distinct guest host identities per VM; unexpected changes fail closed and require an explicit recovery action.
- Allocate a distinct unprivileged `127.0.0.1:<hostPort>` endpoint per managed VM, coordinate it through the port ledger, and verify the actual runtime mapping. Preserve endpoint metadata across ordinary restarts; external conflicts must be actionable rather than silently redirecting to another guest. No LAN or bridged exposure is introduced by this feature.
- Keep SSH readiness separate from VM lifecycle. `.ready` still indicates the upstream runtime boundary; it does not prove that a guest account, SSH daemon or authorized key is usable. Show provisioning/waiting/ready/failure separately, retaining the client and reservations through `.exited` even when SSH fails.
- Mark SSH ready only after an authenticated, host-key-verified connection confirms the expected guest account and manager-owned VM identity. A listening TCP port alone is insufficient. Bound and cancel probes by `(vmID, sessionID)` so an old connection cannot mark a later run ready.
- Make fresh-guest provisioning, normal restarts and host-initiated diagnostics work without manual shell commands. If owner-account setup is a prerequisite, represent that explicitly until provisioning completes; do not advertise SSH readiness prematurely.
- Use or extend the upstream kit and guest integration through a reviewed, versioned API/capability. The manager continues to own orchestration. The ad hoc live QMP forward and custom debug SSH daemon used during the POC must not become the production launch path.
- Any configuration migration beyond new-root initialization needs a separately reviewed, stopped-VM transaction using the supported upstream interface. Keep the current launch-admission adapter read-only; do not silently rewrite unrelated user settings to enable SSH.

**TO PROVE:** the supported key/account provisioning path before the first authenticated connection, independent identities/endpoints with two guests, recovery after failed provisioning, and SSH continuity across guest restart and Mac sleep/wake. Implement and validate this in Phase 3A before the private MVP is accepted.

## 11. Clipboard and other host integrations

### Clipboard

Working clipboard in every VM is a v1 requirement. Stock Try Omarchy 1.3 cannot meet it safely in a multi-VM process topology, so the first runtime task is a small focus-aware change to `NativeClipboardBridge`.

Required semantics:

- every VM whose profile enables clipboard includes `.clipboard` in its bridge list;
- only the QEMU process that is currently the frontmost/focused guest may read changes from `NSPasteboard.general` or write guest changes to it;
- a background guest clipboard message is ignored and must not replace the Mac clipboard;
- a background guest does not receive host clipboard changes;
- on focus gain, the newly active guest receives the current Mac clipboard once, then receives subsequent changes while focused;
- focus loss immediately stops both directions;
- transitions fail closed: if focus cannot be established, no clipboard traffic flows;
- echo suppression remains per guest, but focus is checked in the same serialized state queue immediately before every send or host write;
- no clipboard payload is logged, persisted in the manager registry or included in diagnostics.

The global Mac clipboard intentionally remains global. If the user copies in VM A, focuses VM B and pastes, that explicit focus change permits the current Mac clipboard to reach B. The bug to prevent is automatic delivery to B while B is in the background, or a background B overwriting a copy made in A/macOS.

Smallest upstream implementation:

1. Add a `ClipboardFocusProviding` abstraction to `NativeClipboardBridge`, defaulting to `NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID`. Identify the exact QEMU PID as the existing authentication/Command bridges do; never match a process name. Clipboard must not acquire a new Accessibility-permission dependency. An AX focused-window check may refine the result only when access is already available, not disable clipboard when it is not.
2. Track focus changes alongside the existing 250 ms pasteboard poll (or with workspace activation notifications plus a small reconciliation poll).
3. Gate `pollPasteboard()`, `.sync` handling and guest `.clipboard` handling on the focus probe.
4. On a false-to-true focus transition, reset only the necessary echo state and send the current host selection once.
5. Add deterministic tests with fake pasteboards and fake focus probes for two bridges, rapid focus changes, guest/host races, focus loss during a message and unavailable focus.
6. Keep the run protocol at version 1 and leave `VMRunConfiguration` unchanged; this is internal bridge behaviour.

**Packaging consequence:** changing the bridge changes `omarchy-vm-helper`, so it cannot be layered onto the published zip as an unsigned replacement. Build a complete kit from the pinned source plus the reviewed patch, then sign and verify it through upstream's normal kit pipeline. The POC lock file records the patch commit and resulting kit digest. A public/distributable manager should move back to an official release asset after the change is merged upstream.

The manager's `ClipboardCapabilityPolicy` checks the kit provenance/capability before allowing two clipboard-enabled sessions. Stock `v1.3.0` is recorded as `focusAwareClipboard: false`; the patched POC build is `true`. Never infer capability merely from run protocol 1 because both builds speak that protocol.

### Authentication, camera, battery and timezone

- POC bridge list after the required runtime patch: `[.clipboard, .battery, .timezone]` for both VMs.
- Authentication is focus-checked upstream, but simultaneous prompts still require real validation. Enable it only after the POC and keep it off by default in the first manager build.
- Camera is a contended physical device. Keep it disabled until an explicit single-owner policy is implemented and tested.
- Battery and timezone are read-mostly host integrations and are the lowest-risk bridges for the POC.
- Audio and guest-status are always run by the kit and are not `VMRunBridge` choices. Test simultaneous audio rather than assuming it is isolated.

## 12. Kit acquisition, build and signing

### Source and binary pinning

Commit `Config/TryOmarchyUpstream.lock.json` for the verified stock baseline:

```json
{
  "tag": "v1.3.0",
  "commit": "13d63df8da2947f833c04025ff5ade187d39ba81",
  "runProtocolVersion": 1,
  "kitSHA256": "3ad65381b34ced2ebe3f5f19b95d58ec1a2c51a77a6edf7599666a939b6991a6",
  "focusAwareClipboard": false
}
```

The clipboard-capable POC also commits `Config/TryOmarchyRuntime.lock.json` after the patch is implemented and reviewed. It records the upstream base, exact fork/patch commit, run protocol, build date, generated kit SHA-256 and `focusAwareClipboard: true`. Do not fill in a placeholder patch commit or digest; the build produces them and verification reads them back.

`Scripts/fetch-try-omarchy-kit.sh` handles the unmodified reference kit and should:

1. download `TryOmarchyKit.zip`, its sidecar checksum and `TryOmarchyKit.json` from the exact `v1.3.0` release;
2. verify the zip against both the committed digest and the sidecar;
3. verify manifest format, exact version and protocol;
4. unpack with `ditto` into a gitignored, versioned `VendorArtifacts` folder;
5. refuse an existing mismatched artifact rather than replacing it silently.

The build must never use “latest”. Updating the tag is a reviewed dependency change with real two-VM regression testing.

`Scripts/build-patched-try-omarchy-kit.sh` builds the POC kit from the exact source commit plus the focus-aware clipboard patch using upstream's documented `make kit` and kit-verification path. The script refuses a dirty or unexpected source tree, captures the resulting digest and manifest, and emits the runtime lock data. An untagged patched kit reports version `development`; that is permitted only for a debug/private POC when both its exact source commit and digest match the runtime lock. Release builds reject `development` and require an official upstream release that declares or proves the focus-aware capability.

### Embedding

Stage the bundle at:

```text
Omarchy VM Manager.app/Contents/Helpers/TryOmarchyKit.bundle
```

Add microphone and camera usage descriptions to the manager's `Info.plist` before enabling those bridges; macOS attributes the helper's requests to the app that started it.

### Signing reality

**VERIFIED — v1.3.0:** an embedded kit is re-signed as the embedding app. The upstream kit's QEMU and helper need their specific hypervisor/audio/camera entitlements and signing order. The networking daemon pins three networking binaries, so those three must not be re-signed after the daemon was built.

Reuse the pinned upstream `scripts/kit_signature.py` from the submodule in the app assembly process:

- copy the verified kit into the staged app;
- run its normal `sign` action with the development/distribution identity; that action skips the three pinned networking binaries and applies the correct entitlements to QEMU/helper;
- verify the kit before signing the outer app;
- sign the outer app last;
- for release, notarize the complete manager application and verify nested signatures.

Do not use a generic `codesign --deep --force` command as the signing strategy. Do not ask Codex to use signing identities, notarization profiles or credentials without the user explicitly authorizing that human step.

### App construction

Prefer a SwiftPM-first project that opens cleanly in Xcode and assembles a real `.app` deterministically, similar to upstream:

- `swift build`/`swift test` for code and tests;
- a checked-in `Makefile` as the public developer interface;
- `Scripts/build-app.sh` to stage the executable, `Info.plist`, icon, storage helper and kit;
- `make app`, `make test`, `make run` and `make verify-app` targets;
- minimum macOS 15, Swift 6 strict concurrency.

This avoids a hand-maintained generated Xcode project while still producing a native SwiftUI app bundle. If the team explicitly prefers an `.xcodeproj`, generate it from a checked-in specification rather than making opaque manual project-file edits.

## 13. Phased implementation

### Phase 0 — Repository and dependency skeleton

Deliver:

- SwiftPM package and SwiftUI executable target;
- core library and test target;
- exact upstream submodule pin;
- lock file and verified kit-fetch script;
- deterministic app assembly and ad-hoc/debug signing path;
- kit manifest/preflight diagnostics in a simple window;
- no VM launch yet.

Exit criteria:

- unit tests pass;
- app launches on macOS 15+ Apple Silicon;
- UI reports embedded kit `v1.3.0`, protocol 1 and supported status;
- a mismatched or missing kit is rejected, and a development kit is accepted only under the exact locked debug/POC provenance rule;
- built app and embedded kit pass signature/layout verification appropriate to the debug identity.

### Phase 0A — Required focus-aware clipboard runtime

Deliver:

- the smallest `NativeClipboardBridge` focus-gating change described in Section 11, based on the exact v1.3.0 commit;
- deterministic upstream unit tests covering two clipboard bridges and focus transitions;
- a clean upstream test run for the affected helper/client surface;
- a complete source-built kit produced and verified by the upstream kit pipeline;
- a generated runtime lock with exact patch commit and kit digest;
- an upstream issue/PR-ready explanation that the change fixes multi-instance clipboard routing without changing run protocol 1.

Exit criteria:

- with two bridge instances backed by one fake Mac pasteboard, only the focused target sends or receives;
- focus gain synchronizes the current Mac clipboard once;
- a background guest cannot overwrite the Mac clipboard;
- focus uncertainty fails closed;
- all existing single-VM clipboard behaviour remains covered and passing;
- the patched kit passes signature/layout/runtime checks appropriate to a development build.

This phase is mandatory. Do not proceed to the two-VM product POC with two stock v1.3.0 clipboard bridges, and do not substitute a one-clipboard-session product limitation.

### Phase 1 — Two-VM proof of concept

**DESIGN DECISION — user acceptance, 31 October 2026:** Phase 1 is complete. The user accepted the recorded POC results with the intermittent graphics startup failure carried forward for further investigation. That finding remains open and is not considered fixed or a blocker to completing this phase. Preserve both stopped disposable VM disks at the user's request. See [the POC results and remaining evidence gaps](docs/Phase1-POC.md) and [the graphics investigation](docs/Phase1-Graphics-Repro.md). Unverified checks retain their evidence status; milestone acceptance does not turn them into observed passes.

Deliver:

- two hard-coded or fixture profiles with distinct UUID roots and names;
- one `VMRunClient` per profile;
- restricted bridges `[.clipboard, .battery, .timezone]` for both profiles, using the locked focus-aware kit;
- NAT, no port forwards, no shared folders, no USB and no authentication/camera;
- sequential cold start, then two simultaneous running QEMU instances;
- independent shutdown and forced-stop controls;
- event/error log visible in the app.

The original Phase 1 baseline has no permanent SSH provisioning or forwarding. User-authorized temporary loopback SSH used for diagnosis must be recorded and cleaned up. It does not satisfy the future managed-SSH requirement in Phase 3A.

Decision-gate acceptance:

- VM A reaches `.ready`; while A remains usable, VM B reaches `.ready`.
- Both guests have different disks, settings and Dock/window names.
- Shutting down A produces A's `.exited` without stopping or freezing B.
- Restarting A preserves A's files and does not show B's files.
- Attempting to start A's exact storage root through a second client is refused with `vm-already-open` or is prevented by the manager before the call.
- Mac sleep/wake with both running returns both guests to a usable state, or the failure is recorded with exact logs and the project stops for an upstream investigation.
- Force-quitting the manager causes both helpers to begin shutdown and leaves no orphan QEMU after the upstream timeout.
- Clipboard works in A whenever A is focused and in B whenever B is focused.
- Copying in the focused VM updates the Mac clipboard; a background VM cannot overwrite it.
- Host clipboard changes reach only the focused VM; switching focus gives the newly focused VM the current Mac clipboard once.
- No unexplained port, clipboard, QMP socket, factory cache or storage collision occurs.

If this gate fails because the kit/runtime assumes a singleton, document the smallest upstream change and stop. Do not hide the failure behind retries.

### Phase 2 — Minimal manager MVP

**Implementation status — 31 October 2026:** implemented as a private debug build; registry, lifecycle, safe Trash and native UI checks pass. See [validation and remaining real-guest Spaces checks](docs/Phase2.md).

**DESIGN DECISION — user request, 31 October 2026:** follow the native sidebar/grouped-settings visual style of the supplied Try Omarchy screenshots and provide stopped-guest configuration for name, CPU, memory, clipboard and immersive mode. Keep both existing POC disks intact and protect their profiles from edits and deletion. For Mission Control Spaces, the user chose native Dock assignment over an in-app picker. The private runtime may stamp a stable, canonical-root-derived bundle identifier on each explicitly rooted guest app; retain the public client protocol and stock QEMU/image. Actual Dock assignment persistence remains **TO PROVE** until observed with the updated runtime. See [Phase 2 implementation and validation](docs/Phase2.md).

Deliver:

- schema-versioned registry and atomic persistence;
- create/list/rename/start/shutdown/force-stop/delete-to-Trash;
- manager-owned root initialization and markers;
- actor-based state machine and session retention;
- progress, notices and actionable failures;
- total memory and active count in the UI;
- application-quit coordination;
- fake-runtime tests for all lifecycle transitions.

Exit criteria:

- relaunching the manager restores profiles but never invents running state;
- repeated commands cannot create duplicate sessions;
- deletion cannot race a start or stop and cannot target an unowned path;
- corrupted registry data is preserved for diagnosis and not silently replaced.

### Phase 3 — Host safety policies

Deliver:

- read-only v1.3 effective-settings adapter and contract fixtures;
- aggregate memory/CPU/storage admission;
- manager port ledger and host bind probes;
- NAT enforcement;
- clipboard capability/provenance enforcement and focus-aware two-VM regression coverage;
- clear recovery UI for unknown settings schemas and port conflicts.

Exit criteria:

- stored resource settings cannot bypass the aggregate budget;
- two VMs requesting the same TCP or UDP host port cannot both enter `start`;
- a port conflict names the owning managed VM when known;
- malformed/unknown upstream settings fail closed;
- every clipboard-enabled running VM works when focused;
- background VMs neither receive host changes nor publish guest changes;
- a stock/unproven kit cannot be used for concurrent clipboard-enabled launch.

### Phase 3A — Automatically SSH-ready guests

Required before private MVP acceptance. User authorized this as the next milestone after Phase 2. The implementation adds narrowly scoped SSH port safeguards; full Phase 3 effective-settings/general-port work remains separate. Code and no-VM checks are implemented; real guest exit criteria remain TO PROVE. See `docs/ManagedSSH.md`.

Deliver:

- a reviewed upstream-compatible public-key/account provisioning path with explicit capability/provenance checks;
- per-VM protected credentials, pinned public host identity and coordinated loopback endpoint metadata;
- automatic SSH bootstrap on first launch, a creation-time default-on SSH toggle and optional existing-public-key chooser, separate authenticated readiness reporting and a **Copy SSH Command** action;
- bounded, session-scoped probes and actionable provisioning, authentication, identity and port errors.

Exit criteria:

- a fresh manager-created guest accepts an authenticated host connection after normal owner-account setup without a pasted command, manual SSH/firewall setup or host-key acceptance prompt;
- an optionally selected personal public key also authenticates for the intended owner, private key material stays on the Mac, and existing guest authorized keys are preserved;
- two guests accept connections concurrently through their own endpoints, and each connection identifies the expected VM;
- one VM's credential does not authenticate to another VM, and host-key mismatches cannot be silently accepted;
- normal guest restart preserves the intended key/host identity and restores readiness; sleep/wake and independent shutdown are tested;
- SSH setup/probing works while the graphical shell or clipboard is unavailable;
- an SSH failure never releases a live VM's client, resource allocation or port reservation;
- credentials and diagnostic bootstrap artifacts cannot leak into registry exports, logs or source control.

### Phase 4 — Packaging and private distribution

Deliver:

- Developer ID signing/notarization workflow, performed with user-authorized credentials;
- embedded-kit re-signing in upstream's required order;
- app update policy documented (manual download is sufficient for v1);
- release checklist, licenses and third-party notices;
- permission strings and first-run explanation;
- bounded diagnostic export with no guest secrets or clipboard content.

Exit criteria:

- a clean Mac user can install and launch the notarized build;
- the embedded helper/QEMU retain required entitlements;
- two-VM acceptance passes on the distributable build;
- the distributable build uses an official upstream release containing the focus-aware clipboard behaviour, or is explicitly designated an internal/private fork build with exact source and binary provenance;
- replacing the application does not alter manager-owned VM roots.

### Phase 5 — Optional hardening/upstream work

Candidates, only after v1:

- public upstream effective-settings and storage-initialization APIs;
- public port configuration/inspection API;
- a public clipboard capability flag or dynamic bridge diagnostics/control beyond the required focus-aware behaviour;
- safe guest-window activation API;
- shared verified factory cache across manager roots;
- explicit single-owner camera/USB policy;
- bridged networking registration and at-most-one-session policy;
- supported kit update channel with signature/team verification and rollback.

## 14. Acceptance criteria for the finished private MVP

### Functional

- Create at least three profiles and run any two concurrently on a host that satisfies the budget.
- Each profile retains its own guest data and settings across restarts.
- Start/stop/failure/progress are independent per row.
- Application relaunch preserves the registry and does not lose VM data.
- One VM can fail to start without terminating another.
- New manager-created guests become authenticated SSH-ready from the host automatically, with a distinct verified endpoint per VM and no manual console bootstrap.

### Lifecycle and data safety

- No code path deletes a running, starting or stopping VM.
- Graceful shutdown is the default; forced stop always warns.
- The client and reservations remain retained until `.exited`.
- A duplicate canonical storage root is rejected before launch.
- Delete moves exactly one verified manager-owned UUID root to Trash while holding the runtime-compatible lock.
- Corrupt or newer registry/settings formats are never overwritten automatically.

### Resource and networking safety

- Aggregate effective memory stays within the configured hard budget.
- CPU warning/block thresholds are deterministic and tested.
- New/existing free-space checks use upstream storage helpers plus manager margin.
- v1 launches only NAT.
- No two active/starting VMs reserve the same protocol and host port.
- External port races surface as an actionable launch error.

### Integration safety

- Every clipboard-enabled running VM can copy and paste when focused.
- A background VM neither receives host clipboard updates nor publishes guest updates.
- Focus changes select the active clipboard route without restarting either VM.
- Concurrent clipboard-enabled launch is refused unless the exact kit provenance is known to contain the focus-aware bridge.
- Authentication and camera are off unless explicitly enabled by a later tested policy.
- Sleep/wake, manager quit and manager force-quit are tested with two guests.
- A missing/damaged/incompatible kit prevents launch without touching storage.

### Packaging

- Source and kit are pinned to the same reviewed provenance: an official release for distribution, or an exact source commit plus generated digest for the private patched POC.
- Downloaded kit digest and manifest are verified before embedding.
- The app uses a clean environment for `VMRunClient.start`.
- Embedded code signatures and entitlements are verified in CI/local release checks.
- No release claim is made until a notarized build passes the same two-VM test.

## 15. Test strategy

### Unit tests — run on every change

- Registry encode/decode, atomic replacement, permissions and unknown schema.
- VM state transition table, stale session IDs and duplicate commands.
- Reservation release only after `.exited`.
- Memory/CPU budget boundaries and stored-setting precedence.
- TCP/UDP port identity, conflicts and owner messages.
- Clipboard capability/provenance admission.
- Focus-aware bridge state with two fake bridge instances, one fake host pasteboard and rapid target focus changes.
- Canonical path, symlink, marker and UUID checks.
- Error mapping and bounded/sanitized diagnostics.
- Application quit with zero, one and several fake sessions.

### Contract tests — pinned to Try Omarchy 1.3

- Manifest parsing and exact protocol support.
- Public configuration validation boundaries.
- Fixture `settings.json` files for null precedence, resources, old memory setting, NAT/bridged mode and port mappings.
- Fail-closed behaviour for bad permissions, symlink, oversized file, malformed JSON and newer schema.
- A test reads the vendored v1.3 source constants/fixtures and alerts on schema/key drift.
- App assembly contains the expected helper path and passes the upstream kit verification script.

### Runtime-adapter integration tests — no real VM

Create a temporary fake `TryOmarchyKit.bundle` with an executable protocol stub. Exercise:

- ordered progress/ready/exited events;
- synchronous launch failure;
- malformed and unknown events;
- stderr tail;
- graceful shutdown command;
- helper crash;
- stalled helper and `terminate()`;
- two simultaneous fake clients.

Never set upstream's private `OMARCHY_VM_RUN_TEST_SKIP_PREFLIGHT` in production code.

### Real Apple Silicon POC matrix

Run on at least one macOS 15+ Apple Silicon Mac with enough storage. Prefer both a 16 GiB and a larger-memory host before distribution.

Test:

- two existing VMs;
- first start of one VM while another runs;
- independent heavy CPU/disk load;
- distinct window/Dock identities and keyboard focus;
- simultaneous audio, then one microphone owner if later enabled;
- sleep/wake;
- normal app quit, cancelled quit and force quit;
- graceful and forced guest stop;
- same-root refusal;
- same-port refusal and external-process bind race;
- working focus-routed clipboard in both directions for A and B;
- background guest copy attempts, host changes during focus transitions and rapid A/B switching;
- low disk space and missing kit;
- update/replace the app while guests are stopped, retaining storage.

Record exact Mac model, macOS version, memory, kit manifest, test steps, results and stderr. “Source says it should work” is not a POC result.

## 16. Primary risks and mitigations

| Risk | Impact | Mitigation / decision |
| --- | --- | --- |
| Multiple QEMU/GPU sessions expose an untested singleton or Cocoa limitation | Project blocker | Phase 1 decision gate before UI investment; capture minimal upstream repro. |
| v1.3.0 is a prerelease | API/packaging churn | Exact source/binary pin; no automatic update; repeat POC on any change. |
| Private settings/marker coupling | New upstream schema can bypass policy or block VMs | One isolated adapter, exact v1 fixtures, fail closed, propose upstream public APIs. |
| Stored settings override manager fallbacks | Aggregate oversubscription or unexpected bridge/network | Initialize null overrides; read effective settings before every start. |
| Stock global clipboard bridges leak between guests | Cross-project data disclosure | Required focus-aware bridge patch, two-bridge tests, exact kit capability/provenance enforcement, upstream the change before public distribution. |
| Patched kit is not an official release asset | Update/signing/support burden | Use only for the private POC with exact source/digest; release builds require an official merged release or are clearly marked internal fork builds. |
| Port preflight has a TOCTOU race | Startup failure | Manager reservation + serialized starts + QEMU authoritative bind + actionable error. |
| Two cold roots duplicate image/cache | Disk/network pressure | Serialize cold starts; free-space margin; investigate shared cache only upstream-supported. |
| Bridged networking is single-session and privileged | Conflicts/approval burden | NAT only in v1. |
| Camera, USB, microphone and Touch ID contend or prompt confusingly | Unreliable/security-sensitive UX | Disable optional high-risk bridges initially; add explicit ownership policies and tests. |
| App/kit nested signing is incorrect | Build launches locally but fails for users | Reuse upstream signing script/order; verify entitlements; notarized-build POC. |
| No public bring-to-front API | Start button cannot focus an existing guest | Distinct product names/Dock entries; omit misleading Open action. |
| Destructive path bug | VM or unrelated data loss | Derived UUID roots, ownership marker, canonical checks, separate locking helper, Trash only. |
| Trademark/licensing mistakes | Distribution risk | Preserve MIT notices, audit `THIRD_PARTY_NOTICES`, do not reuse upstream/Omarchy brand assets without permission review. |

## 17. Recommended repository structure

```text
Omarchy VM Manager/
├── intent.md
├── AGENTS.md
├── README.md
├── LICENSE
├── THIRD_PARTY_NOTICES.md
├── Makefile
├── Package.swift
├── Config/
│   ├── TryOmarchyUpstream.lock.json
│   └── TryOmarchyRuntime.lock.json
├── App/
│   ├── Info.plist
│   ├── OmarchyVMManager.entitlements
│   └── Assets.xcassets/
├── Sources/
│   ├── OmarchyVMManagerApp/
│   │   ├── OmarchyVMManagerApp.swift
│   │   ├── AppDelegate.swift
│   │   ├── AppModel.swift
│   │   └── Views/
│   ├── OmarchyVMManagerCore/
│   │   ├── Model/
│   │   ├── Registry/
│   │   ├── Runtime/
│   │   │   ├── VMRuntime.swift
│   │   │   └── TryOmarchyRuntime.swift
│   │   ├── Manager/
│   │   │   ├── VMManager.swift
│   │   │   └── VMState.swift
│   │   ├── Policy/
│   │   │   ├── HostResourcePolicy.swift
│   │   │   ├── PortReservationLedger.swift
│   │   │   └── ClipboardCapabilityPolicy.swift
│   │   └── Storage/
│   │       ├── ManagerStorage.swift
│   │       ├── TryOmarchyV1StorageContract.swift
│   │       └── UpstreamSettingsSnapshotReader.swift
│   └── OmarchyVMStorageHelper/
├── Tests/
│   ├── OmarchyVMManagerCoreTests/
│   └── Fixtures/TryOmarchy/v1.3.0/
├── Scripts/
│   ├── fetch-try-omarchy-kit.sh
│   ├── build-patched-try-omarchy-kit.sh
│   ├── build-app.sh
│   └── verify-app.sh
├── Vendor/
│   └── try-omarchy/                 # git submodule, exact commit
└── VendorArtifacts/                 # gitignored, verified kit extraction
```

`AGENTS.md` should repeat the safety rules that matter during implementation: never use a personal/default Try Omarchy VM as a test VM; never reset/delete/launch an existing VM without explicit consent; use only manager-owned disposable roots; stop and ask for macOS permissions, signing, notarization, credentials and real UI takeover; shut down and Trash all test VMs after validation.

## 18. First Codex session instructions

Use this section as the initial implementation prompt. The first session should complete Phase 0 and implement/test Phase 0A before preparing the non-launching portion of Phase 1. It should not download the 3 GB factory image or open real QEMU windows until the user explicitly approves the POC run.

### Session objective

Create a clean SwiftPM-first SwiftUI macOS application skeleton, pin and verify Try Omarchy 1.3, implement and test the required focus-aware clipboard change, implement the core actor/runtime abstractions with fakes, and produce an app that can validate and report the exact embedded kit provenance. Prepare—not silently run—the real two-VM POC.

### Required sequence

1. Read this entire `intent.md` and treat the **VERIFIED / DESIGN DECISION / PRIVATE COUPLING / TO PROVE** labels as binding distinctions.
2. Inspect the host with read-only checks: architecture, macOS version, Xcode/Swift versions, physical memory and free disk. Report blockers; do not change the machine.
3. Initialize the repository if needed. Add an `AGENTS.md` containing the safety rules above.
4. Add `omacom/try-omarchy` as `Vendor/try-omarchy`, pinned to commit `13d63df8da2947f833c04025ff5ade187d39ba81`. Confirm that `git describe --tags --exact-match` reports `v1.3.0`.
5. Read the pinned upstream `AGENTS.md`, `docs/architecture.md`, `docs/vm-kit.md`, `macos/Package.swift` and the four files under `macos/Sources/TryOmarchyKitClient/` before writing the production adapter.
6. Create the stock upstream lock with the exact tag, commit, protocol, kit digest and `focusAwareClipboard: false` in this document.
7. Implement the kit-fetch script. Download only the small kit/manifest/checksum assets after normal network approval; verify before unpacking. Do not download the factory image.
8. Implement the Phase 0A focus-aware `NativeClipboardBridge` change in a dedicated branch/fork commit, with two-bridge fake-focus tests. Run the relevant upstream tests. Build a complete development kit through the upstream pipeline and generate the runtime lock with its real patch commit and digest; do not invent these values.
9. Create the package targets and basic SwiftUI window. Use macOS 15 and Swift 6 concurrency checks.
10. Add the local `TryOmarchyKitClient` product from the vendored `macos` package.
11. Implement `VMRuntime`, fake runtime/handle, `TryOmarchyRuntime`, the `VMState` model and an actor skeleton that retains handles through `.exited`.
12. Implement kit startup diagnostics: embedded path, helper validation, manifest version/protocol/support, exact provenance/capability lock and `VMRunClient.preflight()`. No VM starts in this step.
13. Add the app assembly script that embeds the verified patched kit. Reuse the pinned upstream signing script for the staged kit; use ad-hoc/debug signing only unless the user explicitly authorizes a real identity.
14. Add tests for event ordering, stale session rejection, retain-until-exited, synchronous start failure, graceful shutdown intent, missing/incompatible kit and rejection of an unproven concurrent-clipboard runtime.
15. Add two disposable POC profiles under the manager's own Application Support root in code or a debug fixture, but do not call `start` yet.
16. Run both upstream clipboard tests and manager `make test`, build the app, run layout/signature verification and open only the manager window. Fix failures before reporting completion.
17. Summarize files changed, commands/tests and exact results. State what remains unverified. Ask for explicit approval before the real two-VM run because it downloads large assets, opens windows and exercises Hypervisor/host integrations.

### First real POC, after approval

1. Confirm there is enough memory and at least the two-new-VM storage requirement plus margin.
2. Create only UUID-named manager-owned roots. Never point at `~/Library/Application Support/Try Omarchy/VM/v1` or any existing user VM.
3. Start VM A with NAT, explicit root/name, computed memory/CPU, and bridges `[.clipboard, .battery, .timezone]` from the locked focus-aware kit.
4. Wait for A `.ready` and complete enough first-boot setup to verify the desktop.
5. Start VM B the same way while A remains running.
6. Prove clipboard in both directions for A and B, including background suppression and rapid focus switching, before claiming the POC works.
7. Execute every Phase 1 decision-gate check and record evidence.
8. Gracefully shut down both. Confirm both `.exited`, no QEMU/helper remains for those test roots, and only then offer to move test roots to Trash.
9. If any shared-resource or lifecycle failure appears, preserve logs, stop further feature work and reduce it to the smallest upstream-compatible reproduction.

### Definition of done for the first session

- Repository skeleton exists and is understandable without generated mystery files.
- Stock upstream and patched runtime source/binary inputs are exactly pinned and verified.
- Core lifecycle code is testable without launching a VM.
- The assembled manager app validates the embedded kit, its focus-aware clipboard capability/provenance and protocol, and refuses incompatible or unproven input.
- Tests/build/verification pass with exact results recorded.
- No personal VM, signing credential, permission grant, factory image or real QEMU session was touched without explicit consent.

## 19. Upstream references

- [Try Omarchy v1.3.0 release](https://github.com/omacom/try-omarchy/releases/tag/v1.3.0)
- [VM kit and run-mode documentation at v1.3.0](https://github.com/omacom/try-omarchy/blob/v1.3.0/docs/vm-kit.md)
- [Swift package manifest at v1.3.0](https://github.com/omacom/try-omarchy/blob/v1.3.0/macos/Package.swift)
- [`TryOmarchyKit` and storage public API](https://github.com/omacom/try-omarchy/blob/v1.3.0/macos/Sources/TryOmarchyKitClient/TryOmarchyKit.swift)
- [`VMRunClient` public lifecycle API](https://github.com/omacom/try-omarchy/blob/v1.3.0/macos/Sources/TryOmarchyKitClient/VMRunClient.swift)
- [`VMRunConfiguration`, events and errors](https://github.com/omacom/try-omarchy/blob/v1.3.0/macos/Sources/TryOmarchyKitClient/VMRunProtocol.swift)
- [Kit manifest/version API](https://github.com/omacom/try-omarchy/blob/v1.3.0/macos/Sources/TryOmarchyKitClient/TryOmarchyKitManifest.swift)
- [QEMU launcher storage locks, work directories and per-run sockets](https://github.com/omacom/try-omarchy/blob/v1.3.0/macos/run-qemu-gpu.sh)
- [v1.3 clipboard bridge](https://github.com/omacom/try-omarchy/blob/v1.3.0/macos/Sources/OmarchyVMHelper/NativeClipboardBridge.swift)
- [v1.3 settings precedence and run-mode resolution](https://github.com/omacom/try-omarchy/blob/v1.3.0/macos/Sources/OmarchyVMHelper/VMRunSettings.swift)
- [v1.3 port forwarding implementation](https://github.com/omacom/try-omarchy/blob/v1.3.0/macos/Sources/OmarchyVMHelper/PortForwarding.swift)
- [v1.3 resource preferences](https://github.com/omacom/try-omarchy/blob/v1.3.0/macos/Sources/OmarchyVMHelper/VMResourcePreferences.swift)
- [Upstream issue #145: Multiple instances](https://github.com/omacom/try-omarchy/issues/145)

## 20. Final implementation stance

Proceed with the standalone manager, but keep the first milestone empirical. The public 1.3 client is sufficient to launch and supervise distinct roots with separate client instances. Host-wide resource and port coordination remains manager work. Safe, fully working clipboard in every VM requires the small focus-aware bridge change because stock 1.3's public API cannot broker it from outside the helper.

The safe v1 answer is intentionally narrow: manager-owned roots, exact source/binary provenance, NAT, serialized cold starts, aggregate admission, port reservations, a focus-routed clipboard bridge in every enabled VM and strict lifecycle/deletion rules. This is still the official Try Omarchy runtime architecture, with one targeted helper fix that should be upstreamed; it is not a QEMU fork. If the two-VM and two-clipboard POC succeeds, the remaining application is a conventional native manager around that runtime.

## Interactive launch intent — user extension, 1 November 2026

**DESIGN DECISION:** UI Start and confirmed experimental Restore request one foreground activation of the launched guest's display. CLI create/start/restart and automated provisioning retain background defaults, including the CLI's `open -g -j` manager startup. This extends only launch-time behavior; it does not add a general Open/Bring to Front action for an existing guest or change the verified stock v1.3.0 API limitations above.

**PRIVATE COUPLING:** extend the same pinned kit configuration/event channel with explicit launch intent and kernel-authenticated display-process identity from the launch's private QMP socket. The manager waits for that exact process's native display and revalidates its birth time before one cooperative macOS activation. Cancel on stop/error/exit/failure or timeout. Preserve lifecycle ownership through matching `.exited`, clipboard focus routing, keyboard capture and native Spaces placement. Require the complete rebuilt kit, reproducible source, exact inventory/compiled pin and launch-intent capability version 1. Preserve all previous custom-factory artifacts, receipts and guest disks; changed runtime provenance is incompatible without a separate explicit rebuild/import. See [guest foregrounding](docs/GuestForegrounding.md).

**VERIFIED — no-VM checks:** 172 manager Swift tests, 34 Python checks, 554 upstream Swift tests and the full upstream no-VM fixtures pass. Both optimized compiled-admission checks pass. The complete ad-hoc kit rebuild and separately staged app pass exact source/archive/inventory pins, signatures, macOS 15 compatibility and diagnostic/layout verification. Source `85f5e561e5a277ccec08d7725c8714cb090c9011`; runtime-lock/compiled pin `f450c1ac80ba9d6cac3678cf72d80dd10d11f23e0af380acf516c8e11e35dc74`. No installed app, existing VM/factory data, permission or real credential was changed. No guest/app window was launched or release published. Exact commands, artifact paths and sandbox limits are in [guest foregrounding](docs/GuestForegrounding.md#verified-no-vm-checks--1-november-2026).

**TO PROVE:** actual guest foreground/window/⌘Tab behavior, delayed startup on a real Mac, background provisioning, multiple simultaneous displays, Spaces, clipboard and keyboard integration, host sleep/wake and crash behavior with the new kit. Stub tests establish only intent, identity transport, scheduling and cleanup. No real VM, image download, installed app replacement, UI takeover, permission grant or real signing credential is authorized for these implementation checks.

## Unattended defaults — user extension, 31 October 2026

**DESIGN DECISION:** the user requested reusable in-app defaults based on Omarchy's unattended-install guide. The prepared factory image's owner setup will receive an immutable new-profile snapshot, with the reusable password held in Keychain and only a temporary protected provisioning seed supplied to the guest. This explicitly permits a password for unattended owner creation; manager SSH still uses independent key authentication. Existing guests remain unchanged. See `docs/UnattendedDefaults.md` for verified ISO/OEM distinctions, the versioned private coupling and remaining checks.

## JSON guest CLI — user extension, 31 October 2026

**DESIGN DECISION:** add a concise JSON command-line interface for guest CRUD, resource configuration, start/stop/restart and bounded waits for running, stopped or authenticated SSH readiness. Use the existing GUI manager as the single lifecycle/registry owner through a private same-user local command socket; a short-lived CLI must never drop live runtime handles. Configuration edits remain stopped-only and must also respect an externally held runtime lock. New guests inherit saved owner defaults unless explicitly opted out.

Return the usable host SSH endpoint separately from authenticated guest IP information. NAT guests may have the same private guest IP; host connections use the allocated `127.0.0.1` port, managed identity and pinned host key. Do not expose passwords, private-key material or Keychain references in JSON. Reuse the supported kit launch API and existing guarded Trash helper. The CLI does not add arbitrary guest-command execution, public networking or a second VM supervisor. See `docs/CLI.md` for the command contract and validation.

### Per-VM owner overrides — user extension, 2 November 2026

**DESIGN DECISION:** CLI creation may override username, full name, email, hostname prefix, timezone and keyboard through explicit flags or a non-secret `ownerOverrides` configuration object. Merge only supplied fields into the new profile's immutable snapshot of enabled, saved Guest Defaults. Empty full name/email clears that field. Keep the saved credential reference, defaults revision and stable UUID hostname suffix. Never rewrite Guest Defaults, alter existing profiles or accept secret/credential fields. Reject invalid values, manual-setup combinations, disabled/unavailable defaults, unavailable protected credentials and updates. Existing password authentication and runtime contracts remain unchanged.

**VERIFIED — no-VM checks:** `make test build` passes 184 manager Swift tests in 33 suites, 43 Python script tests and the debug build. The compiled CLI's `--help` includes the new flags. Synthetic creation tests use disposable UUID fixtures and an in-memory credential store, proving field inheritance, optional-field clearing, immutable persistence, unchanged defaults bytes, preserved credential references and rejection without registry mutation or VM storage creation. The initial sandboxed run could not exercise local sockets/authentication-framework properties; the complete run with the required local access passes. No real Keychain secret, installed app, existing profile/disk, image download or VM was used or changed.

**TO PROVE:** packaged CLI/manager operation and real guest first boot with overrides. This implementation request explicitly leaves VM creation and launch for later; no install or live acceptance is claimed. See [CLI configuration](docs/CLI.md#configuration).

**USER AUTHORIZATION / VERIFIED — subsequent installation, 2 November 2026:** the user requested building/installing the updated app and CLI, explicitly creating/launching no VMs. `make build icon`, separate candidate assembly and full candidate/installed verification pass. Installed ad-hoc 0.9.4 (17) at `~/Applications/Omarchy VM Manager.app` and the repository `dist` path; all 64 files and bundle modes match the candidate. Preserved the original application at `~/Applications/.Omarchy VM Manager.backup-dbaf7fa4164e4de98d76190ce8bb7a14.app` and the prior project bundle at `dist/.Omarchy VM Manager.backup-0d54b8502af247089455ac1474190aa2.app`; both match their original inventories. Installed CLI and repository wrapper help/version checks pass. After a fresh check of one stopped guest and zero active sessions/runtime processes, the prior installed manager quit normally; the updated manager remains closed. Registry/defaults hashes and VM-tree metadata/settings hashes match baseline. No VM/profile/disk creation, launch, credential access, permission grant or real signing identity was involved. This supersedes only the earlier non-installation status; packaged creation/first-boot acceptance and provisioned protected-password behavior remain **TO PROVE**.

### Per-VM personal SSH key suppression — feedback correction, 2 November 2026

**DESIGN DECISION:** expose the existing creation API's `inheritDefaultPublicKey` choice through CLI `--inherit-default-public-key on|off` and a top-level optional boolean configuration field of the same camel-case name. Omission preserves prior inheritance. `off` suppresses only the personal public key inherited from Guest Defaults, preserving automatic owner setup, protected password reference, default-on managed SSH, per-VM manager keys and host pinning. An explicitly supplied public key still applies. Keep this setting creation-only; change no saved defaults, existing profile or guest key enrollment. Reuse the existing manager creation/enrollment path without runtime, storage-schema or credential-policy changes.

**VERIFIED — no-VM checks and corrected installation:** `make test build` passes 186 manager Swift tests in 33 suites, 43 Python script tests and the debug build. New fixtures cover flag/file precedence, strict boolean decoding, command/update rejection, default inheritance, explicit replacement and suppression. The suppressed disposable fixture's actual bootstrap manifest contains only its manager-generated key, with no personal-key file/fingerprint; saved defaults remain byte-identical. No QEMU guest or real credential is used. Rebuilt and reinstalled the ad-hoc 0.9.4 (17) app and CLI at both prior paths, preserving backups `~/Applications/.Omarchy VM Manager.backup-135fc7eab2134d44837ca9fa6f195497.app` and `dist/.Omarchy VM Manager.backup-dc29c912192d4548b938fb4ad7cb5938.app`. All 64 files/modes match the candidate; backups match their originals. Candidate and installed signatures, provenance, compatibility, host preflight, layout and both CLI help checks pass. Guest registry/defaults bytes and VM-tree metadata/settings hashes remain unchanged. The prior manager quit normally after zero-active admission; the updated installed manager was subsequently observed running again and left running, with one stopped guest, zero active guests and no helper/QEMU processes. No real VM/profile/disk creation or launch, permission grant, password access or real signing identity was involved.

**TO PROVE:** real guest boot/enrollment with personal-key suppression and provisioned protected-password behavior. Synthetic bootstrap content and read-only installed CLI help/list checks do not establish these outcomes.

## Shared factory download cache — user extension, 31 October 2026

**DESIGN DECISION:** manager-owned guests share the compressed factory image under `~/Downloads/Omarchy VM Manager/Factory Images/`. Keep the current pinned image and prune only obsolete owned image downloads unused for at least seven days. A successful verified reuse refreshes last use. Cleanup runs opportunistically when preparing a guest, never on a background schedule. Interrupted downloads remain resumable. The cache is independent of guest deletion and is safe to remove manually when no guest is being prepared.

**PRIVATE COUPLING:** the exact digest-pinned helper recognizes the existing protected manager UUID marker and selects this fixed cache directory internally. No development environment override is passed by the manager, and stock/default Try Omarchy roots retain their existing behavior. The kit still owns the download, directory lock, part and whole-image verification, atomic completion and decompression. Each guest's writable disk and decompressed factory remain local to its UUID root. Existing guest disks are not migrated or modified by the cache feature. See `docs/FactoryCache.md` for checks and limitations.

## Managed disk capacity — user extension, 31 October 2026

**DESIGN DECISION:** new manager profiles default to a 64 GiB sparse disk. Disk capacity is an explicit stopped-guest setting in the app and JSON CLI, constrained to 64–8192 GiB and grow-only. Legacy profiles without a manager disk policy retain their existing capacity until explicitly configured. Retained POC profiles remain unchanged.

**PRIVATE COUPLING:** the manager persists the profile's CPU, memory and disk choices in the existing schema-1 `vmResourcePreferences` setting before launch. The exact pinned Try Omarchy runtime owns sparse file extension, never shrinks an existing disk, and the guest's supported root-growth service expands the GPT partition and Btrfs filesystem at boot. The manager validates the stopped disk's current logical size and refuses reductions; it never truncates or partitions a disk itself.

## Manual Pause/Resume — user extension, 31 October 2026

**DESIGN DECISION:** expose in-memory manual Pause/Resume in the native UI and JSON CLI. A paused guest retains its runtime handle, resource/port reservations and disk lock until matching `.exited`. This does not add saved-state suspension or snapshots. Existing guests/disks must not be used or changed by implementation checks.

**PRIVATE COUPLING:** extend the reviewed kit's existing version-1 command/event channel with pause/resume and execution-state acknowledgements. Unknown events are already explicitly forward-compatible. Build the manager against the same reproducibly patched upstream SDK source as its embedded helper, using a generated local package dependency; keep the vendor checkout at stock v1.3.0. The exact compiled runtime pin must require the reviewed manual-execution capability. No separate VM protocol, process signaling control path or development environment override is introduced.

The helper owns QMP pause/resume and keeps manual ownership separate from host-sleep ownership. Wake must not resume a manually paused guest or an unrelated/error stop. Graceful shutdown resumes only a pause owned by this helper, releases its retained monitor connection, then sends ACPI shutdown; uncertain/unsafe recovery falls back to the existing termination path. Terminal exit remains the only resource-release boundary. A missing/late control acknowledgement never implies exit or frees reservations.

## Suspend-to-disk — clarified user requirement, 31 October 2026

**DESIGN DECISION:** the user clarified that the intended feature must offload guest memory to disk and release host RAM while preserving the guest session. The in-memory Pause/Resume candidate does not fulfill this requirement. It remains uncommitted and uninstalled; no existing guest/disk was used for implementation or checks.

**VERIFIED — pinned runtime limitation:** the launcher selects `virtio-gpu-gl-pci` with Cocoa OpenGL. The pinned QEMU commit `c3d48b7d1e89604920e5b81b91140c2ad39a1943` registers a migration blocker when VirGL is enabled (`hw/display/virtio-gpu-base.c`, lines 213–217). The verified stock binary also contains that blocker message. A manager save-state command cannot safely bypass it. Raw guest disks also cannot directly use QEMU's internal qcow2 `savevm` snapshots.

**TO PROVE:** guest-side Linux hibernation may offer a route that does not serialize the host GPU, but requires a separate disposable POC covering swap/resume configuration, kernel support and restoration of the accelerated desktop. Software graphics would change the current runtime/experience and is also unproven. Do not claim either route works, change existing guests, fork QEMU or expose a misleading Suspend action. See `docs/Suspend.md` for the scoped POC and acceptance criteria.


**VERIFIED — approved fresh hibernation POC:** a new 4 GiB/4 CPU/64 GiB guest booted unattended and authenticated over pinned SSH. The official image’s `7.2.8-23-omarchy` aarch64 kernel reports `# CONFIG_HIBERNATION is not set`; `/sys/power/state` contains only `freeze mem`, the hibernation/resume sysfs files are absent, and login1 reports `CanHibernate=no`. No swap or boot configuration change can enable this missing kernel feature. The POC stopped cleanly with no open disk handles; all six earlier profiles/activity/session IDs match baseline. Further Linux hibernation work requires a hibernation-enabled kernel, plus separate proof of accelerated desktop restoration. See `docs/Suspend.md`. No existing disk or guest was used for the experiment.


**DESIGN DECISION — authorized kernel experiment:** the user authorized rebuilding a hibernation-enabled kernel and testing suspend/resume only in the retained `Omarchy Suspend POC` (`C1FFB37D-49E6-4C55-899B-BAB105C895A4`). Keep the original installed kernel and a bootable original-kernel recovery image. The factory image/cache, other guest profiles/disks/sessions and the running main app remain unchanged. This is an experimental guest customization, not a replacement factory image or a product-wide kernel policy. Use the official matching 7.2.8-23 recipe at `omacom/omarchy-pkgs` commit `9db7ac36d410aca6d571975be1a5a77677918569`, with a distinct package/release and `CONFIG_HIBERNATION=y`. Guest disk changes require its stopped state and the runtime-compatible POSIX lock.


**VERIFIED — experimental kernel boot and recovery:** the distinct `7.2.8-23.1-omarchy-suspend-poc` kernel built, installed alongside the original and booted with managed SSH plus `freeze mem disk`. Only hibernation and its selected dependencies differ from the original kernel configuration. Original image checksums remained unchanged, and the original-kernel recovery entry booted and authenticated successfully. A first full hibernation trial with persistent swap stalled before VM exit and required force-stop of only this POC. Its unchanged-disk relaunch cold-booted with no synthetic memory workload restored. This is not successful suspend/resume and does not enable a product Suspend command. See `docs/Suspend.md` for exact provenance and the diagnostic follow-up.

**VERIFIED — kernel experiment result:** both full hibernation attempts stalled after task freezing; the verbose retry recorded snapshot preallocation and completed freezer stages but no completed image or power-off. Both required force-stop after graceful timeout, and both unchanged-disk relaunches cold-booted with no synthetic memory restored. The specific driver/runtime cause remains TO PROVE. The POC was returned to the preserved original kernel as its default, boot-checked over managed SSH with its original checksum, and shut down cleanly. The automatic test is disabled; both kernel packages and the POC disk are retained. Non-target disk metadata/settings hashes match inventory; independent registry changes prevent asserting continuity of all original profile sessions. No app was installed and no other guest command or disk mutation was performed. Temporary build-cache cleanup limitations are recorded in `docs/Suspend.md`.

## Kernel capability and experimental hibernation UI — 1 November 2026

**DESIGN DECISION:** the user explicitly selected an opt-in experimental suspend-to-disk workflow in addition to kernel capability detection. Preserve the earlier failed-POC findings. The guest UI must distinguish kernel support, basic guest readiness, an unverified saved session, verified memory restoration and a cold boot. Unknown capability is disabled. Require a hibernation-enabled running kernel, a live `disk` state, sufficient persistent swap, resume parameters and non-interactive logind authorization before offering an attempt. Every attempt and restore requires explicit experimental confirmation. No automatic kernel/swap/policy installation, sudo prompt or privilege grant is added.

**DESIGN DECISION — disk protection:** durably save a versioned guard before the fixed pinned-SSH power request. Retain runtime ownership/reservations until matching `.exited`, including on lost SSH or timeout. Protect a potentially suspended disk from ordinary launch, edits and deletion; restore only through resource/port admission with configuration/runtime/disk/firmware identity checks. A RAM-filesystem marker plus the original boot identity verifies restored memory. Accept an old launch nonce only inside that proof-bound recovery check, never as normal SSH readiness. A fresh boot with no marker requires explicit failed-restore acknowledgement before the guard is removed. Unknown recovery remains protected; no silent saved-state discard or automatic force-stop is permitted. Quit cannot interrupt an active transition, and host wake cannot cold-start a saved guest.

**VERIFIED / TO PROVE:** source builds and synthetic lifecycle/SSH checks cover the experimental contract. Working real-guest suspend/restore, accelerated device restoration and host sleep/wake during those transitions remain TO PROVE; both earlier kernel POC attempts failed. The installed main app and existing guests/disks remain untouched. See `docs/Suspend.md` for prerequisites, recovery and validation limits.

**DESIGN DECISION — failed-restore recovery:** once a restore has been attempted without a verified memory result, do not automatically boot that guarded disk again: a cold boot may already have modified its filesystem. Permit read-only recovery rechecks while it is running. Releasing protection after a verified cold boot additionally requires the operator’s explicit attestation that a guest administrator invalidated any stale resume image; the app neither performs nor claims to verify that cleanup. A stopped unresolved restore requires manual recovery. Preserve newly appeared or changed guard files, and bind late replies to the exact active session.

## Reviewed custom factory prerequisite — user extension, 1 November 2026

**DESIGN DECISION:** accept externally prepared custom Omarchy factory bundles through a reviewed manifest catalog packaged with the signed manager. The default/explicit official factory remains available. Import verifies a pinned review-manifest digest, every payload and provisioning-evidence hash, aarch64/UEFI image format, exact runtime inventory, integration package and owner-setup contract. Import does not approve a bundle, download an image or initialize a VM. No custom image is preapproved by this change.

**DESIGN DECISION — identity continuity:** factory selection is creation-only and recorded in the guest profile; new roots bind the same identity in protected metadata. Existing profiles with no factory field retain that absence, and all existing writable disks and recorded identities remain unchanged. Factory selection cannot be changed through configuration/update. The manager orchestrates the same cache/preparation, cloning, growth, lifecycle, NAT and SSH implementation rather than adding a VM implementation.

**PRIVATE COUPLING:** the reproducible private kit/client patch adds optional `VMFactorySelection` and explicit `customFactoryVersion: 1` provenance. Whole-kit verification and normal signing remain required. The helper verifies the selected bundle and passes its directory to the existing launcher, disabling the official download only for that selection. The launcher verifies the decompressed custom disk digest before cloning. Protocol 1 is insufficient evidence of factory support. See `docs/CustomFactories.md` for the bundle/review contract.

**TO PROVE:** real custom-image boot, unattended owner/SSH provisioning, integration health, accelerated desktop, concurrent focus, sleep/wake, hibernation and crash behavior. Synthetic checks establish validation and protocol behavior only. This prerequisite grants no new real-guest launch or image-download approval.


**DESIGN DECISION — custom-factory review corrections:** bind the packaged review list to a generated compiled digest, report rejected imports separately while keeping valid/official choices available, and move large verification/copy/preparation work outside the lifecycle actor. Admit/reserve a session before preparation, honor pending stop/force-stop/Quit when its handle arrives, and retain runtime ownership through matching `.exited`. Experimental restore uses private admission with its timeout installed before event handling; no global restore exemption is exposed while preparation is pending. Strict preparation validation rejects metadata the importer cannot accept. These changes add no image or guest approval.


## In-app factory import — user extension, 1 November 2026

**DESIGN DECISION — supersedes the build-time approval requirement for explicit imports:** the user requested an Import Factory button that selects and verifies a prepared bundle without editing JSON or rebuilding the app. A user-initiated UI or CLI import may register a new manifest digest locally after all existing image, runtime, package and provisioning checks pass. The packaged review list remains a backward-compatible path for prior entries; it is no longer required for an explicitly selected import. Whole-kit provenance and signing policy are unchanged.

**DESIGN DECISION — local record:** copy and reverify the prepared bundle, then atomically publish a private import receipt binding its exact factory identity to the current runtime-lock digest. Listing, selection and launch require a matching valid receipt or a legacy compiled pin, plus full bundle verification. Missing, damaged, unsafe or mismatched records fail closed. Preserve damaged entries; do not silently replace or migrate them. No existing profile identity or writable guest disk is changed.

**DESIGN DECISION — UI:** expose Import Factory in the toolbar and the New VM image picker. Show verification/copy progress, cancellation and validation errors; successful import from New VM selects the new factory. Import and verification start no VM and create no guest storage. Large work remains outside the lifecycle actor, cancellation before publication removes staging files, and final publication records only verified metadata. Selection expresses local user trust, not independent proof of a publisher, image contents or a successful boot. Real-image behavior retains its TO PROVE status.


**DESIGN DECISION — Import Factory review fixes:** library refresh results/errors are bound to their request and catalog revision, so an older scan cannot remove a newly imported choice. Import workers count as active manager work; Quit cancels and waits for uncommitted work, or waits for final publication to complete before exit. Recheck the exact descriptor and image-metadata bytes before deriving identity/capacity. These corrections preserve the receipt schema, runtime pin, existing guest identities and writable disks.

## CLI factory deletion — user extension, 1 November 2026

**DESIGN DECISION:** `factory-delete MANIFEST_SHA256` removes only an unused, verified imported factory. Protect the official factory and refuse any manifest digest referenced by a persisted profile, including stopped, metadata-only and saved-session guests, or by a pending creation. There is no force override. Serialize import/deletion and reserve the selected factory against creation throughout review and Trash. Check registry continuity before admission and immediately before Trash; fail closed if it changed externally.

**DESIGN DECISION — recoverability:** verify the full bundle and local receipt or legacy pin, then recheck private paths, payload stamps and identity before moving the bundle and receipt together to one recoverable Trash folder. Preserve the source bundle, registry, guest identities and disks. On failure, restore original paths without overwriting newly appeared files; preserve a recovery folder if rollback cannot finish. An admitted deletion remains manager-owned through client disconnect, and Quit waits for its outcome. Refresh the app library after CLI mutations. Damaged, unregistered or runtime-incompatible factories require manual review and cannot bypass verification through deletion.

**VERIFIED / TO PROVE:** synthetic no-VM checks cover references, mutation races, changed registry/payloads, Trash failure and rollback recovery. Native Trash interaction with a real prepared factory remains unobserved. This change grants no guest launch, image download or existing-disk modification approval.

## Reviewed lean owner contract — user extension, 1 November 2026

**DESIGN DECISION:** preserve `OwnerSetupContract.json` and its default official program set. Explicit custom-factory selection may choose the separately reviewed `lean-e4fffc6` contract; imported metadata cannot register another contract or add executable paths. Bind the digest to the verified factory descriptor, exact kit inventory and a versioned owner-contract provenance resource inside the complete signed kit. Require lean evidence to match the reviewed Omarchy program set, the kit's integration-source commit and the builder's hardware-policy package version. Unknown, mixed, damaged or incompatible sets fail closed at preparation/import and again in the guest before managed functions run.

**VERIFIED — source review / PRIVATE COUPLING:** both reviewed programs expose the same keyboard, account, finalization, cleanup and platform functions and the same 52 keyboard selections. Lean adds a top-level progress-script dependency and removes full-name/email propagation. Pin its progress script and finalizer too; the lean adapter applies the saved full name and Git name/email before upstream cleanup. Root-owned, non-writable regular programs and parents are checked with bounded non-following reads; source dependencies execute from private verified snapshots. The function adapter, rather than a replacement VM implementation, invokes the upstream provisioning sequence. A finalization warning blocks cleanup, preserving pending/setup-user for a same-account retry and withholding SSH enrollment. Opted-in failures report a bounded code and stop; unseeded interactive setup retains its normal path.

**DESIGN DECISION — identity and integration continuity:** transport the reviewed contract digest as an optional setup-seed field checked against the helper's verified factory. Omitted fields retain official semantics. Do not rewrite saved Guest Defaults, owner fingerprints, per-guest SSH identities, profiles or existing disks. The updated kit offers integration package 0.1.0-41; lean images must be rebuilt from its exact source with the builder's hardware-policy 0.1.0-41.1 variant, which the existing package installer preserves as newer. The current lean disk's 0.1.0-36.1 integration is insufficient and is not admitted for managed lean setup. Existing imports bound to an older runtime remain preserved and require newly prepared matching descriptors.

**TO PROVE:** live lean owner setup/retry, authenticated SSH, accelerated rendering, hardware integration, playbook idempotence and crash/sleep behavior. Source and disposable no-VM fixtures do not establish those results. This work must not launch any VM, replace the installed app, use personal credentials or grant macOS permissions.

**DESIGN DECISION — reviewed corrections:** bind lean finalizer execution to the canonical file whose hash was checked. Durably record the matching owner identity before upstream removes pending; retry both file and directory flushes on an existing record, and permit only the same bound identity to resume interrupted cleanup. Require all cleanup markers gone before acknowledgement. While a manager setup seed is active, SSH enrollment additionally requires a configured report matching the current VM/session. Preserve the normal manual/completed-guest SSH path and all existing profiles, defaults and disks. Guest package 42 and the builder's matching hardware-policy variant 42.1 supersede 41/41.1 for this corrected runtime.

**DESIGN DECISION — clarified installation authorization:** the user explicitly resolved the conflicting installation instructions in favor of installing the reviewed build and replacing the installed app. Installation may replace only inactive app bundles after full verification, retaining recoverable backups. Do not open the app, launch a VM, stop a running manager/helper, modify existing guests, use personal credentials or grant macOS permissions.


## Retained POC deletion — user request, 1 November 2026

**DESIGN DECISION — supersedes the Phase 2 deletion restriction:** the user requested removal of the hardcoded deletion protection for Omarchy POC A and B. These guests use the normal explicit confirmation, stopped-session admission, reviewed root/disk/settings identity, ownership/tree validation, runtime-compatible lock and whole-root Move to Trash transaction. Pending-deletion recovery accepts their registered UUIDs. Their original configuration and missing-root recreation restrictions remain unchanged. This change authorizes making deletion available; it does not delete, launch or modify either existing guest.

**TO PROVE:** native Trash of either original POC disk through the updated app. Disposable fixture tests establish the storage and lifecycle behavior without using existing VM storage.

**DESIGN DECISION — deletion review:** retain cached saved-session protection and additionally refuse any on-disk suspension guard at review/confirmation and under the runtime-compatible storage lock before Trash. A guard appearing after the manager opens cannot authorize deletion through stale cached state. This applies equally to original POC and other registered guests. See the isolated review results in [Phase2.md](docs/Phase2.md#poc-deletion-review--1-november-2026).

## Single application instance — user request, 1 November 2026

**DESIGN DECISION:** allow one manager application process per user and one main window. Acquire a private nonblocking application lock before constructing the model or opening the registry, and retain it through coordinated shutdown. All main/preview copies sharing manager data use the same lock. A duplicate launch requests activation of the existing manager and exits without creating a model. Launch Services additionally prohibits multiple instances. The synthetic layout gallery has a separate lock and activation name. Read-only `--diagnostics-json` remains available without opening a manager session.

**DESIGN DECISION — recovery:** retain the lock file permanently and let the operating system release ownership on process exit. Reject unsafe or inaccessible locks; do not remove a lock file or interrupt an existing process to recover. The registry's existing independent lock remains in place.

**VERIFIED — no-VM validation:** `make build` passes; `make test` passes all 159 Swift tests across 31 suites and all 15 Python script tests. The first sandboxed suite run could not bind local sockets; the complete rerun with local socket access passes. The new tests use disposable UUID directories and a Python lock-holder process, covering exclusive ownership, normal/process-exit release, preserved lock inode and unsafe-file rejection. No app window was opened, installed bundle replaced, image downloaded or VM launched.

**TO PROVE:** native Finder/Dock reopening, minimized-window restoration and simultaneous GUI launches with the packaged app. Disposable no-VM tests cover exclusive ownership, normal/process-exit release and unsafe-file rejection.

**VERIFIED — installation at the user's request:** `make app verify-app` passes with ad-hoc signing, exact pinned kit inventory, nested deep/strict signature checks, macOS compatibility, host preflight and no-factory-image layout checks. Installed version 0.9.3 (build 16) at `~/Applications/Omarchy VM Manager.app` after confirming the destination was inactive immediately before replacement. Both staged and installed copies pass full verification and recursive byte comparison against the verified build. The previous installed bundle is retained at `~/Applications/.Omarchy VM Manager.backup-478965ffc269438c9a6b6c972a955522.app`; the preceding project build is retained at `dist/.Omarchy VM Manager.build-backup-aab75d4609b345528b5298f3caf72329.app`. No app window was opened, guest launched, existing VM storage changed or macOS permission granted. Native GUI reopening retains its TO PROVE status.

**VERIFIED — user report, 1 November 2026:** the user confirmed that the installed single-instance update works. Individual Finder/Dock, minimized-window and simultaneous-launch cases were not separately reported; their detailed acceptance checks remain TO PROVE.

## Development prereleases — 1 November 2026

**DESIGN DECISION:** the user requested versioned GitHub prereleases from CI. Publish only explicitly tagged `vVERSION-dev.N` debug builds after both existing no-VM test jobs pass. Mark downloads as experimental ad-hoc-signed development fork builds, never as notarized or stable distribution. Developer ID signing, notarization and the production release-runtime gate remain separate work requiring authorized credentials.

**DESIGN DECISION — provenance continuity:** acquire the exact already reviewed development kit from a digest-named GitHub dependency prerelease. Verify the compiled lock pin, source patch, archive digest, manifest, full file inventory and signatures. Preserve the current runtime lock and compiled pin; do not rebuild a new kit, update factory receipts, change VM storage or weaken normal launch admission. Source and kit remain pinned to the same reviewed provenance.

**DESIGN DECISION — no-VM packaging:** assemble in a separate prerelease staging directory, preserve ZIP permissions/resource metadata, unpack and verify the result, and publish its checksum and source/runtime provenance. Bundle-only diagnostics explicitly skip host readiness and exit before constructing a manager session. Normal diagnostics and VM launches still perform host preflight. CI establishes packaging integrity; real guest, focus, sleep/wake and crash behavior retain their existing evidence status.

**VERIFIED / DESIGN DECISION — cross-builder signing:** the first tagged package run verified the original runtime on macOS 15, then correctly refused the inventory changes caused by re-signing it with that builder's `codesign`. Development prerelease assembly therefore preserves the exact existing upstream-pipeline ad-hoc kit signatures and verifies them and the full inventory before/after embedding. Sign the manager's executables and outer app normally. No provenance check is bypassed, and future Developer ID distribution still requires deliberate new signed-runtime provenance.

**VERIFIED / DESIGN DECISION — SwiftPM resource layout:** CI uses a flat core resource bundle while the local toolchain emits `Contents/Resources`. Accept exactly one of those layouts and compare all three resource files against source. Resolve packaged resources from the app before SwiftPM's test/build fallback and exercise owner-contract loading during bundle diagnostics. Both layouts, signature checks and exact runtime preservation passed local no-VM validation; this does not establish any new real-guest behavior.

## Authorized signed prereleases — 1 November 2026

**DESIGN DECISION / USER AUTHORIZATION:** after configuring the seven GitHub secrets, the user explicitly requested wiring signing/notarization into CI and running the first signed prerelease. This authorizes those credentials only in the tagged GitHub release job. It does not authorize local credential use, app installation/UI takeover, permissions, factory-image downloads or any real guest launch.

**DESIGN DECISION — signed fork policy:** add an explicit optimized `SIGNED_PRERELEASE` build mode. Admit only the compiled exact signed runtime lock plus expected signing team, original source-kit digest and original source-lock digest. Preserve the existing ad-hoc development lock/artifact and normal production-release refusal. Developer ID/notarization are verified distribution properties, not an official-upstream or real-VM acceptance claim.

**DESIGN DECISION — upstream signing boundary:** derive the signed kit through upstream's existing pipeline, including signing its three networking payloads before rebuilding the daemon that pins them. Preserve all unsigned guest/scripts/firmware/factory payloads exactly. Notarize/staple the kit before deriving its full signed inventory; sign and notarize/staple the app afterward. Verify all entitlements, Developer ID/team/hardened runtime/timestamps, exact bundle contents, Gatekeeper acceptance and the extracted ZIP before publishing. Never use deep force-signing.

**DESIGN DECISION — continuity and credentials:** keep a separately reviewed signed-runtime lock so later app builds reuse the same signed kit. Generate source pins only inside the disposable CI workspace and restore checked-in development pins on exit. Keep credentials in a temporary runner keychain, redact command failures, remove key material on exit, and expose no credentials to tests/pull requests or artifacts. Preserve existing profiles, custom factory receipts and disks; ad-hoc-bound custom factories remain incompatible until deliberately rebundled for the signed runtime. No automatic migration is authorized.

**TO PROVE:** end-to-end Apple acceptance, stapling and Gatekeeper checks on GitHub; clean-Mac installation/permissions and all real signed-build guest behavior. Local no-VM tests and optimized compilation do not establish those outcomes.

**VERIFIED / DESIGN DECISION — certificate container compatibility:** the initial signed CI attempt passed both test jobs but macOS rejected PKCS#12 import with a MAC-verification error, before any signing/notarization submission. Add verified OpenSSL decryption and same-identity rewrapping into a compatible temporary encrypted container with a random transfer password. Never skip MAC checks; remove the private temporary PEM immediately and all credentials on exit. Synthetic-certificate tests verify certificate preservation and rejection of a wrong password; the corrected-credential retry below confirms real import/signing.

**VERIFIED — initial signed CI credential gate:** `v0.9.3-dev.5` passed 160 manager Swift tests, 31 Python tests and 550 upstream tests. OpenSSL also rejected the then-configured PKCS#12 MAC. CI cleaned up credential files/keychain and published nothing; no real signing or Apple notarization submission occurred in that attempt. A credential correction was required before retrying.

**VERIFIED — corrected credentials, superseding the credential blocker above:** the user updated the export-password secret. The signing-only retry imported the Developer ID identity, validated the notarization API credentials and signed the runtime through the upstream pipeline. Apple received submission `9600b6bb-4040-473f-868b-b36ec0a55c52` and still reported `In Progress` when the run was deliberately cancelled before publication after discovering a remaining debug-only launch guard. No signed release was published, and no guest was launched.

**DESIGN DECISION — compiled admission correction:** optimized `SIGNED_PRERELEASE` builds must reach the same exact signed-provenance, host-preflight and signature validation used by managed launch. Ordinary release builds retain their private-runtime refusal; legacy fixed-root POC admission stays debug-only. Exercise the compiled admission branch in both optimized modes with an unpinned, nonexistent kit and no created storage. Preserve exact candidate archives alongside Apple diagnostics on CI failure so a pending submission's bytes remain available for review; never include credentials or publish an unaccepted candidate as a release.

**VERIFIED — admission correction checks:** local `make test-build-policies` passes the compiled admission regression in both optimized modes. `make test` passes 161 manager Swift tests and 31 Python tests. No real signing identity or notarization credentials were used locally, no app was opened or installed, and no VM/image/storage operation occurred. Apple acceptance, stapling, Gatekeeper and real signed-guest behavior remain TO PROVE.

**VERIFIED — corrected tagged CI checks:** [`v0.9.3-dev.6`, run `41274695838`](https://github.com/reactive-org/omarchy-vm-manager/actions/runs/41274695838), at manager commit `88bb8679934fdb286461f5a9a08198f54d7f159e`, passed 161 manager Swift tests, 31 Python tests, one compiled admission regression in each optimized mode, 550 exact patched upstream tests, app/icon builds and the isolated SSH job. No real guest was launched. These checks do not establish Apple acceptance or real signed-build guest behavior.

**VERIFIED — signed candidate / pending Apple gate:** the corrected job imported the real certificate, validated API credentials, signed the runtime and submitted it at `2026-11-01T04:57:16.237Z` as `78d5ad92-c756-4e67-a0f1-87dec516c5d4`. Apple still reported `In Progress` at `05:42:38Z`, after the 45-minute limit. CI cleaned up credentials, retained diagnostic/candidate artifact `13072336103` and skipped publication. The runtime archive SHA-256 is `b6dbfb08c213458b9d57486f30b699ecf9e2fccfb430276ad2fd9d7cbaccad4b`. Read-only downloaded-candidate verification with macOS trust-service access passed all 22 Mach-O Developer ID/team, hardened-runtime, secure-timestamp, entitlement, deep-signature and network-pin checks; all unsigned payloads match the original locked runtime. The development lock/pin remains `37aeca15303be1d491b9ed39109e4d0fc273093fe88dc1ac9f0b56fa05822cfb`.

**TO PROVE / external blocker:** Apple acceptance, fresh runtime/app stapling, final signed app/ZIP and Gatekeeper verification remain unobserved. No signed prerelease or accepted signed-runtime lock was published/committed. Existing real-guest acceptance limits remain unchanged. The user considered a local release and explicitly chose to keep CI running; local signing/notarization credentials and a real local signing identity remain unauthorized. No local credential use, installation, app UI or real guest launch occurred in this work.

**DESIGN DECISION — existing submission status:** the user requested checking Apple's result and finishing the prerelease if accepted. Add a manual, release-specific CI status job bound to the immutable `v0.9.3-dev.6` source commit and recorded submission ID. Use only the three authorized API secrets in a private temporary runner directory; import no signing identity, submit no new archive, and remove the key on success or failure. Retain the fresh status/rejection JSON. This extends the CI continuation path, not local credential authorization, VM approval or the publication gates.

**VERIFIED — fresh Apple status:** [CI status check `41278438740`](https://github.com/reactive-org/omarchy-vm-manager/actions/runs/41278438740) succeeded and Apple again returned `In Progress` for `78d5ad92-c756-4e67-a0f1-87dec516c5d4`. No new upload, signing, local credential use or VM operation occurred. The checker passed local `make test`: 161 manager Swift tests and 34 Python tests, including CI-only credential refusal, cleanup after API failure and mismatched-reply rejection. Apple acceptance and the remaining signed-prerelease gates remain TO PROVE.

## Factory preparation progress — 1 November 2026

**DESIGN DECISION / USER AUTHORIZATION:** fix the stale Preparing percentage in the existing runtime and rebuild/pin its complete kit. The user explicitly accepts that the changed provenance makes existing custom factories incompatible. Preserve their bundles, receipts, recorded profile identities and writable disks; no automatic migration, relabeling, installation, real signing identity, factory-image download or guest launch is authorized.

**PRIVATE COUPLING:** the upstream launcher measures decompression from sparse output size, which can remain at the last written range until close. Emit Preparing 100% only after decompression succeeds and the output has the expected size. Enter the existing Finishing phase before the custom raw-disk checksum and compaction, clearing the old unpacking percentage. Keep all verification and lifecycle boundaries intact. See [preparation progress](docs/PreparationProgress.md).

**TO PROVE:** live GUI progress timing and real custom/official guest behavior with the rebuilt kit. No-VM fixtures establish only marker ordering, parser behavior and failure handling.

**VERIFIED — no-VM validation:** `make test` passes 162 manager Swift tests and 34 Python tests; `make test-upstream` passes 551 upstream Swift tests and all remaining upstream no-VM fixtures. The complete kit rebuild, exact inventory/signatures, manager build and isolated app verification pass. The new source is `80156396a5daa795487c0f4a8308eee53f6ea68b`; the runtime-lock/compiled pin is `cac1444e48e0413f37cb0b97d196b5cad3034782b8c8245f500fc323004f77a0`. Exact commands, pins, sandbox limitations and the uninstalled candidate path are recorded in [preparation progress](docs/PreparationProgress.md). No real guest, image download, existing guest/factory data, installed app, UI takeover, personal credential or permission grant was involved.

**DESIGN DECISION / VERIFIED — subsequent user-authorized installation:** the user requested installation with a backup and explicitly no VM launch. Installed the fully verified candidate at `~/Applications/Omarchy VM Manager.app` after checking that destination was inactive; preserved the previous bundle at `~/Applications/.Omarchy VM Manager.backup-28e6f532f5a84184840df50395317f79.app`. Both bundles pass signature, compatibility, diagnostics and exact-layout verification against their own runtime locks; all 64 installed files and bundle modes match the candidate, and the backup matches the pre-install inventory. Left the separately running project manager untouched. No app window was opened, process stopped, VM launched or existing guest/factory/registry data modified. This supersedes only the installation restriction for this app replacement; live behavior remains TO PROVE.

**VERIFIED — subsequent user-authorized reopening:** the user explicitly requested quitting the running project manager and opening the installed update without launching VMs. Quit normally after observing zero active guests, confirmed process exit and no VM runtime processes, then opened only the installed manager. Its UI showed five stopped guests, zero active and zero allocated memory. Process inspection confirmed one manager at the installed path and no helper/QEMU processes. No VM launch or permission grant occurred; real preparation-progress behavior remains TO PROVE.

## Matching custom factory rebuild — 1 November 2026

**DESIGN DECISION / USER AUTHORIZATION:** the user requested rebuilding and repreparing the custom factory for the updated kit, preserving the original and launching no VMs. Use the existing dev-vm 20 GiB lean foundation builder with the exact clean integration source `80156396a5daa795487c0f4a8308eee53f6ea68b`. Preserve the original successful artifact, prepared bundles/imports and all guest profiles/disks. Publish a distinct build artifact and a separate flat prepared bundle. The existing builder may use its ARM64 Docker containers, guest-package downloads and isolated chroot/snapshot checks; it must not launch QEMU or install host software. This does not authorize boot acceptance, migration of existing guests or rewriting old factory evidence.

**VERIFIED — completed no-VM rebuild:** the existing dev-vm `make build-omarchy-image` target succeeds with explicit current-source/commit overrides and a 20 GiB disk. Published new artifact `af93b5f10d206637-7816326733d14d53` and separate `.Manager.factory` bundle; its manifest is `6b49ae727ec1865e15c90bc990bb13d46b2747012d7ac5f4ceb93b2fe245e5bf`. All 24 artifact checksums, independently streamed raw disk size/hash, exact seven-file managed integration comparison and production client validation against the installed kit pass. Package versions match the original artifact. Reverified all 24 original artifact checksums and preserved five prior prepared descriptors/timestamps; the dev-vm checkout remains clean. `latest` points to the new artifact. No import, VM launch, host-software installation or guest mutation occurred; process inspection found no helper/QEMU guest. Exact paths, hashes and limits are in [Lean owner setup](docs/LeanOwnerSetup.md#rebuilt-for-the-preparation-progress-kit--1-november-2026). Live behavior remains TO PROVE for this artifact.

**USER AUTHORIZATION / VERIFIED — subsequent import:** the user requested importing the rebuilt bundle through the updated manager, preserving the original and launching no VMs. Native `factory-import` succeeds; a fresh `factories` listing includes the new manifest and its receipt binds the exact current installed runtime lock. All 81 previous library entries and the source bundle are unchanged, and the imported payload hashes match the descriptor. Read-only before/after guest configuration/lifecycle hashes match for all five inactive guests; no helper/QEMU process is present. No old import/receipt or guest was replaced or changed. The rebuild-time non-import status is superseded only by this explicit import; actual boot/progress and other live acceptance remain TO PROVE. See [import evidence](docs/LeanOwnerSetup.md#subsequent-authorized-import--1-november-2026).

## Interactive-launch candidate installation — 1 November 2026

**USER AUTHORIZATION / VERIFIED:** the user requested installing the verified interactive-launch candidate, keeping a backup and launching/modifying no VMs. Installed 0.9.3 (16) at `~/Applications/Omarchy VM Manager.app` after confirming the destination was inactive immediately before replacement. Preserved the prior bundle at `~/Applications/.Omarchy VM Manager.backup-d11e7d2bc16944bea3526d14b188da00.app`. All 64 installed files and bundle modes match the candidate; the backup matches the prior inventory. Both bundles pass signature/compatibility/provenance/layout checks against their own runtime locks, and final installed-path diagnostics pass host preflight. No app UI, VM lifecycle/storage action, permission grant or real signing credential was involved. Installation changes no real-guest acceptance status; foreground/⌘Tab and integration behavior remain **TO PROVE**. See the [installation evidence](docs/GuestForegrounding.md#subsequent-authorized-installation--1-november-2026).

## Real launch-focus evidence — 1 November 2026

**USER AUTHORIZATION / VERIFIED — user report:** the user authorized CLI background testing on fresh disposable manager-owned guests and reported that UI launches focus the launched guest while the manager is focused. Record only that UI case as user-verified; do not infer ⌘Tab, Spaces or other focus scenarios.

**VERIFIED — real disposable CLI checks:** with the installed launch-intent kit (`85f5e561e5a277ccec08d7725c8714cb090c9011`, runtime-lock `f450c1ac80ba9d6cac3678cf72d80dd10d11f23e0af380acf516c8e11e35dc74`), CLI `create --start`, unattended owner/SSH setup, warm `start`, `restart` and a focused fresh-creation repeat kept the exact guest app and manager background while each guest owned a native window and reached authenticated SSH. Both new UUID guests stopped through normal matching terminal cleanup; no captured runtime/targeted bridge process or open test-root file remained. The original three guests' records and checked storage metadata/settings hashes match baseline. Test roots are retained pending a Trash decision. No permission, existing guest, factory import or installed app was changed.

**VERIFIED limitation / TO PROVE cause:** unattended fresh creation briefly activates macOS SecurityAgent (about 5.61 seconds in the identified repeat), before QEMU starts. Thus guest-display backgrounding passes but full host-focus preservation does not. The saved-password Keychain lookup is a possible cause, not established proof. No credential policy or permission was altered. Cold-manager CLI bootstrap, ⌘Tab, Spaces, clipboard/keyboard, concurrent guests, sleep/wake/crash and a safe SecurityAgent fix retain their TO PROVE status. See the [real background-launch evidence](docs/GuestForegrounding.md#authorized-real-background-launch-check--1-november-2026).

## Touch ID approval for new guest setup — 1 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** the user requested one Touch ID approval per new VM, with the Mac login password as fallback. They subsequently chose to prepare the feature and supply a Developer ID provisioning profile later. Implement the native biometric Keychain path and no-VM tests now. This does not authorize local signing credentials, profile creation, installation, credential access/upgrades, permission grants, UI takeover or real guest launches.

**DESIGN DECISION:** new setup passwords use the manager's versioned local data protection Keychain service, with `SecAccessControl.userPresence` and device-only, unlocked-device accessibility. Keychain itself requests authentication during one password retrieval at first launch; do not add a preliminary LocalAuthentication approval, reuse authenticated contexts between guests, use a recent Mac unlock as approval, or fall back to legacy password retrieval after failure. Cancelled/failed authorization stops launch before root preparation. Manual/completed guests skip retrieval; an interrupted setup attempt requires fresh approval on retry. New profile snapshots check protected-item metadata without requesting secret data or authentication.

**DESIGN DECISION — explicit upgrade:** Guest Defaults offers a one-time upgrade of only its saved credential. It may require the old login-Keychain authorization before copying the password to the protected service under the same UUID. Keep the original entry and metadata unchanged, preserving pending snapshots and rollback. Legacy copies retain their original access policy; this is not a claim that every historical copy becomes biometrically protected. No automatic legacy read or broad credential enumeration is permitted. Pending snapshots of a different historical credential remain preserved and fail closed until that exact credential is deliberately upgraded.

**DESIGN DECISION — signing boundary:** biometric Keychain access requires provisioned app entitlements. The app assembly accepts an explicit Developer ID profile only in authorized signed-prerelease mode, verifies its exact manager App ID/team/platform/expiry/distribution scope, and grants only the manager's own application identifier and team. The CLI, storage helper and kit gain no Keychain entitlement. Ad-hoc builds remain buildable, display the missing-capability limitation and refuse protected credential operations. The profile is still to be supplied; no fake Team ID, unprovisioned entitlement or local signing identity is used. See [Touch ID setup and validation](docs/TouchID.md).

**TO PROVE:** the final provisioned build and Apple profile/certificate admission; real Touch ID approval, Mac password fallback, cancellation and prompt count; native upgrade UI/layout; legacy upgrade after an ad-hoc binary change; and the original background-focus issue. Synthetic tests establish query policy, context isolation, error boundaries and profile-scope checks, not native authentication behavior.

**USER AUTHORIZATION / VERIFIED — subsequent profile validation:** the user supplied `Omarchy_VM_Manager_Developer_ID.provisionprofile` in their Documents signing folder and requested read-only validation. Its exact App ID, macOS Developer ID scope, current validity and requested entitlements pass project policy. The CMS signature and local Apple-signer trust pass, and its authorized public signing certificate/team exactly match the digest-verified `v0.9.3-dev.6` CI candidate. Profile SHA-256: `f5ddd1c8f3d572881bd85522ac086a4e271d351e4e0225442094987f706d2aed`; expiry: `2044-10-27T10:03:25Z`. No private key/identity was used, profile/certificate imported, CI setting changed, app signed/installed/opened, credential accessed or VM launched. This supersedes only the waiting-for-profile status. CI integration, signed-app admission, online revocation and native authentication behavior remain unobserved. See [profile validation](docs/TouchID.md#provisioning-profile).

**USER AUTHORIZATION / DESIGN DECISION — CI signed Touch ID release:** the user explicitly requested wiring the validated profile into CI and building a signed release with Touch ID support. Store its base64 bytes as `MACOS_KEYCHAIN_PROFILE_BASE64` in the existing repository's Actions secrets, pin only its exact digest/Bundle ID in source, and expose the secret only to the tagged release step. Stage and validate the profile in a private runner directory before importing signing credentials, embed it only in the main app, verify the actual signing certificate and process-level entitlement, and remove temporary copies on all exits. Signed prereleases must refuse a missing/changed profile; local builds remain ad-hoc. Prepare 0.9.4 (17), tag `v0.9.4-dev.1`, and publish only after the existing tests, Apple acceptance/stapling, provenance, signatures, profile/certificate checks, Gatekeeper and extracted-ZIP verification pass. Publishing the exact already-reviewed current runtime as its digest-named CI dependency is necessary for clean-runner packaging and authorized within this release request. Local signing credentials, installation, UI takeover, Keychain password migration, permission grants and VM launches remain unauthorized. Real biometric/guest behavior remains **TO PROVE**.

**VERIFIED — Touch ID release CI / pending Apple gate:** [`v0.9.4-dev.1`, run `41296495425`](https://github.com/reactive-org/omarchy-vm-manager/actions/runs/41296495425), at immutable manager commit `ef98347fde21cbdcb1002506c828e36e7ee9cda3`, passed 180 manager Swift tests, 43 Python tests, both optimized admission checks, 554 exact patched upstream Swift tests, app/icon builds and isolated SSH checks. The provisioned CI path validated the profile, certificate/password and API credentials, signed the runtime and submitted `c30ff885-b28d-4039-9314-1bf8f53267cf` (Apple createdDate `2026-11-01T10:19:22.100Z`). Apple still reported `In Progress` when the 45-minute wait stopped at 10:04 pm AEDT on 1 November 2026. CI cleaned up credentials/profile, retained artifact `13080912857` and skipped publication.

**VERIFIED — retained current signed candidate:** the ZIP SHA-256 is `d75f504b50ab7a690cd58bcfb7bbb6be1d40e3879ce17e07fbe4f843dd91f0d8`. Read-only downloaded-candidate verification with macOS trust services passed all 22 Mach-O Developer ID/team, hardened-runtime, timestamp, entitlement, deep-signature and networking-pin checks; every unsigned payload matches the tagged source-lock `f450c1ac80ba9d6cac3678cf72d80dd10d11f23e0af380acf516c8e11e35dc74`. Its exact bytes, manifest, original source lock and public receipt are preserved under ignored `VendorArtifacts/signed-candidates/v0.9.4-dev.1/`. No private signing/notarization credentials were used locally, app installed/opened, permission granted, password migrated or VM launched.

**DESIGN DECISION / TO PROVE — current continuation:** the status workflow and follow-up now bind the current immutable tag/commit and submission above. Preserve older evidence without publishing `v0.9.3-dev.6` or mixing its incompatible runtime into this release. Query the current ID without a new upload. Apple acceptance, fresh runtime/app stapling, final provisioned signed app/ZIP, Gatekeeper and native biometric/guest behavior remain unobserved and required before their corresponding claims.

## Development Keychain compatibility — user request, 2 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** restore the existing login-Keychain password flow for development builds while retaining Touch ID for provisioned releases. Preserve saved credentials, UUID references, defaults/registry schemas, VM profiles/disks, the exact runtime pin and the pending Apple submission. An unprovisioned `DEBUG` build without `SIGNED_PRERELEASE` selects the original `dev.omarchy.vm-manager.unattended` service before accessing credentials. Provisioned debug builds and all optimized/signed-prerelease builds retain the protected service and user-presence policy. Never retry a failed/cancelled protected lookup against the development service, or downgrade/copy protected-only items.

**DESIGN DECISION:** development snapshot creation reads only saved non-secret defaults; credential retrieval remains at first launch before storage preparation. Reuse the original service/account UUID and normal login-Keychain protection for development reads and explicitly entered new passwords. No implicit migration, credential replacement/deletion, broad enumeration, permissions, local real signing identity, app installation or VM launch is authorized by these implementation checks. The form reports the selected flow and hides unavailable biometric-upgrade controls. Diagnostics expose the compiled development mode without a credential read; signed verification requires it to be false. The pre-existing per-guest owner-override edits remain intact. See [compatibility details](docs/TouchID.md#development-compatibility--2-november-2026).

**TO PROVE:** native login-Keychain prompt count/trust after an ad-hoc binary change and the provisioned Touch ID/password flow. Synthetic checks do not establish live authentication, real guest, focus, sleep/wake or crash behavior. The Apple/notarization/installation boundaries above remain unchanged.

**USER AUTHORIZATION / VERIFIED — compatibility installation, 2 November 2026:** the user requested installing the verified compatibility build, explicitly retaining no backup of the current app and launching/modifying no VMs. A read-only query of the already-running manager reported one guest and zero active/transitional guests; process inspection found no VM runtime. Closed only the installed manager normally, then verified a staged candidate and atomically replaced `~/Applications/Omarchy VM Manager.app`. Final-path verification passes and all 64 installed files/modes match the candidate. The superseded app was removed from the transaction stage; no backup was retained and pre-existing older backups were untouched. Registry/defaults hashes and the complete guest-tree stat fingerprint (30 entries) match before installation/manager closure. No Keychain item, VM lifecycle/storage action, permission grant, real signing identity or notarization submission was involved. The installed app remains closed. See [installation evidence](docs/Validation.md#compatibility-build-installation--2-november-2026).


## Native host-folder sharing — 2 November 2026

**DESIGN DECISION — user request:** add explicit per-VM opt-in sharing, default host path `~/Shared` with native/CLI overrides. The user accepted the runtime's native `/mnt/mac` destination instead of `/mnt/shared`. Reuse the kit's existing writable virtio-9p export and packaged guest mount service; do not add a second sharing controller or guest bind mount. Read-only exports and hot-plug are unsupported. Native and CLI stopped edits persist schema-5 profile metadata and apply at the next start. Missing legacy metadata remains off.

**VERIFIED — pinned source inspection:** schema-1 `sharedFolderPreferences` stores path/isEnabled. The native guest integration mounts tag `mac` at `/mnt/mac` with `cache=readahead`; it is separate from the read-only managed SSH share. The public protocol supplies no sharing configuration or live mount-health event. Existing kit provenance and graphics/clipboard code stay unchanged.

**PRIVATE COUPLING:** ManagerStorage recognizes only the reviewed sharing payload, writes it under the matching runtime lock/revision and prevents global-preference inheritance. A separate read-only pinned SSH probe validates VM/session/owner and exact tag, destination, filesystem, read-write mode and cache policy. Its errors never release live sessions or reservations. Host paths are dedicated owned home subdirectories with bounded metadata checks, no automatic creation/chmod/TCC request. See [SharedFolders.md](docs/SharedFolders.md) for the trust boundary and native home-link behavior.

**TO PROVE:** actual file access, restart persistence, disablement, official/lean compatibility, repeated-write integrity, focus, sleep/wake and crash behavior. The source change grants no installation, runtime build, guest change or restart approval. Existing UUID `38012142-9431-437A-A042-64ECE8E9DD36` remains protected until the concrete validation proposal is approved.


**USER AUTHORIZATION / VERIFIED — sharing acceptance, 2 November 2026:** approved deployment and validation on the original Dev VM disk, with the user later confirming completion there before their own recreation. Manager 0.10.0 (23) retains the exact runtime. Lean integration 0.1.0-43.1/kernel 7.3.0-7-omarchy mounts `~/Shared` at `/mnt/mac` with read-write access and safe `cache=0x1`. Exact bidirectional/append file checks, restart persistence and clean disablement/home-link cleanup passed, followed by re-enablement. Disk identity/size, protected profile/factory and SSH-key/pin hashes remain unchanged. Accelerated VirGL and 2× native scaling are observed; the matching clipboard bridge runs without reading clipboard contents.

**DESIGN DECISION / PRIVATE COUPLING:** accept an omitted default protocol in Linux mount reporting while refusing a reported conflicting version; the pinned service still supplies 9p2000.L. Serialize optional power/sharing checks and bound transport retries to three; trust/configuration/authentication and malformed-report failures remain immediate. Fixed error categories exclude raw SSH stderr. An intermittent SSH exit-255 cause remains unproven. The storage helper now consumes the manager's shared schema-1–5 registry admission rather than a duplicate outdated range. The user's earlier Trash attempt was refused and moved no storage; helper admission tests use disposable metadata only.

**VERIFIED — final no-VM checks:** 206 Swift tests/35 suites, 43 script tests, manager build and exact packaged signature/inventory/compatibility/layout verification pass. **TO PROVE:** official and other lean artifacts, workload-wide write integrity, native form interaction, human clipboard/focus transfers, sleep/wake and crash behavior. See [the authorized live checks and limitations](docs/SharedFolders.md#authorized-live-validation--2-november-2026).


**VERIFIED — sharing final handoff:** final installed 0.10.0 (23) passes installed-path verification and 65 seconds of health observation across two monitor intervals. Dev VM remains Running / SSH ready / Mounted with `~/Shared → /mnt/mac` read-write. The two disposable test files are removed after inode/hash checks and guest confirmation; unrelated host files are preserved. No guest disk was replaced, reset or moved to Trash. Untested behaviors retain the TO PROVE distinctions above.

## Developer provisioning dependency checks — 2 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** implement milestone 1 of [the dev-vm plan](docs/DevVMProvisioningPlan.md) in its worktree: Homebrew dependency checks and feature gates, with no host tool installations or VM launches. Bundle the dev-vm engine in a later milestone and use compatible existing host dependencies initially; private bundled Python/Ansible runtimes remain a future packaging option. Keep VM implementation in Try Omarchy and lifecycle ownership in VMManager. A future live terminal is scoped to approved provisioning jobs, rather than a general SSH client; milestone 1 adds no terminal or guest execution.

The host-controller/runtime packaging choice in this initial decision is superseded by the shared Swift design below. The original milestone 1 implementation and its verification remain unchanged.

**DESIGN DECISION:** expose a native Provisioning tools page and local `omarchy-vm setup tools` report without opening the manager from the CLI. Reports distinguish tool prerequisites from implemented features; all execution gates remain disabled. Probe explicit executables with bounded output/time and a private temporary environment. Do not run install/upgrade commands, read credentials, check GitHub authentication, contact guests, query Docker or invoke Apple's potentially interactive Python launcher. See [dependency policy and checks](docs/ProvisioningTools.md).

**PRIVATE COUPLING:** host Ansible launcher resolution recognizes direct Python shebangs and the exact `/usr/bin/env python3` form. Preserve virtualenv entry paths, verify the selected interpreter's imports and matching CLI/package versions, and reject other wrappers. This adapter is separate from existing runtime/settings couplings and grants no upstream kit capability.

**VERIFIED — milestone 1 no-VM validation:** `make test build` passes 224 Swift tests/37 suites and 43 script tests, including 18 focused provisioning tests. Direct CLI checks preserve JSON/help/version behavior, reject an installation flag and leave execution disabled. Minimal-PATH read-only discovery admits the existing Homebrew 7.0.11/Python 3.14.9/PyYAML 6.0.3/Ansible Core 2.21.5 toolchain; GitHub authentication remains unverified. Probe locale is explicitly UTF-8. No host software was installed/upgraded, credential accessed, app installed/opened or guest contacted. Exact checks and limitations are in [ProvisioningTools.md](docs/ProvisioningTools.md).

**TO PROVE:** other supported Homebrew environments, native UI interaction and packaged behavior; engine integration, PTY authorization/echo, persistent sudo-grant cleanup, interrupted remote work, real guest compatibility, focus, sleep/wake, crashes and concurrent provisioning. Synthetic tool probes do not establish those behaviors or change prior real-VM evidence.

## Shared Swift provisioning design — 2 November 2026

**USER AUTHORIZATION / DESIGN DECISION — documentation only:** revise the plan to use one shared Swift provisioning package maintained with dev-vm and consumed by both the manager/helper and standalone dev-vm CLI. Port the host controller, strict manifest/feature resolution, planning, source snapshots and application coordination to the package. Bundle compiled Swift code and versioned playbooks/roles/catalogues/guest helpers. Invoke Homebrew's Ansible launchers; their Python dependencies stay Homebrew-managed. The manager will have no independently selected Python/PyYAML runtime requirement. Guest Python helpers and existing Python-based development/image-build tooling are separate and may remain. Do not start the port or change milestone 1 code in this documentation task.

**DESIGN DECISION — planned milestone 1A:** retain the dependency provider, GUI-safe discovery, bounded isolated probes, UTF-8 environment, change detection and native/CLI reports. Replace independent Python/PyYAML requirements, imports, Python overrides and shebang matching with coherent Homebrew Ansible CLI version/usability checks using fixed local fixtures without guest execution. Plan dependency-report schema 2 with explicit migration from schema 1; preserve existing guest-command protocol 1. JSON/YAML planning will use compiled Swift parsers without an external Python or Ansible requirement once that package is integrated. Keep unimplemented execution disabled and preserve all original milestone 1 validation evidence. Details are in [the revised plan](docs/DevVMProvisioningPlan.md#changes-to-milestone-1).

**PRIVATE COUPLING / TO PROVE:** the current Python-shebang adapter remains implemented until an authorized milestone 1A change retires it. Its replacement will isolate Homebrew installation identity and Ansible CLI interpretation behind contract-tested adapters. Swift package/API/resource layout, strict YAML/JSON/TOML and Python-controller parity, standalone compatibility, revised CLI probes, native terminal behavior and real guest/crash/sleep behavior remain unverified. Saving this revision changes no source code, installed app, dependency or guest.

## Homebrew Ansible CLI dependency contract — 2 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** implement milestone 1A only in this worktree, with no host tool installations, VM launches or shared Swift package port. Dependency reports now use schema 2: remove standalone Python/PyYAML rows, imports, interpreter selection and shebang parsing; reject retired overrides with migration guidance; retain existing guest-command protocol 1. Local JSON/YAML planning has no external tool blockers, but the package/parsers and every execution capability remain unimplemented and disabled. System transports, Homebrew discovery, isolated bounded probes, optional-tool deferral and ordinary VM lifecycle ownership retain their prior boundaries.

**PRIVATE COUPLING — implemented:** validate the active installation returned by `brew --prefix --installed ansible`, its directory identity and expected command targets, identical stable Core 2.21.x versions, a fixed static INI inventory listing and a fixed playbook syntax check. Do not run tasks, gather facts, evaluate user manifests, connect to a guest or select Ansible's internal Python. Support installation-provided wrappers and reject foreign/mismatched targets. Replacing Homebrew, either command or its active directory invalidates pair readiness. stdout/stderr have separate streams with a combined 32 KiB limit, five-second timeout and private process-group cleanup. Parse OpenSSH's stderr version explicitly; never log raw diagnostics. The inventory contract accepts only the fixed synthetic host and its optional empty `ansible_local` namespace.

**VERIFIED — no-VM acceptance:** `make test build` passes 224 Swift tests/37 suites and 43 script tests, including 18 focused provisioning tests. A minimal-PATH existing-host report admits Homebrew 7.0.11 and both Core 2.21.5 commands after fixed local self-checks, emits schema 2 without Python/PyYAML/interpreter rows, preserves help/version and guest-command protocol 1, rejects retired overrides and an installation flag, and leaves execution disabled. GitHub authentication is unverified. No tool installation/upgrade, real signing identity, credential access, app installation/opening, guest contact or VM operation occurred. See [exact checks and limits](docs/ProvisioningTools.md).

**TO PROVE:** other Homebrew installations/Core versions, native UI interaction and signed packaged admission; the shared Swift package, parsers and controller port; actual setup, PTY authentication, authorization cleanup and real guest/focus/crash/sleep behavior. Earlier milestone 1 and shared-design sections preserve historical decisions and evidence; this section supersedes only their pending dependency-contract implementation status.

**USER AUTHORIZATION / CONFIRMED — isolated UI review:** the user requested the UI, accepted its appearance and asked to stop the preview and proceed. A temporary ad-hoc native app used the unchanged provisioning view and current core, with live dependency checks and no manager/registry/runtime initialization or VM controls. It was closed on request. The installed manager and guests were untouched. This establishes the isolated visual review only; full manager interaction and packaged behavior remain TO PROVE. The shared Swift package port remains deferred under the earlier explicit instruction.

## Shared Swift provisioning foundation — 2 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** start milestone 2 with shared Swift package structure and strict manifest parsing, with no host tool installation or VM launch. This supersedes the earlier instruction to defer the port for this scope only. Keep the package in dev-vm on its isolated `codex/swift-provisioning-package` branch; the manager's dependency pin and helper integration remain pending. No manager execution gate changes.

**DESIGN DECISION:** expose `DevVMProvisioningCore` and a validation-only `dev-vm` executable, targeting Swift 6/macOS 15+. Swift validates bounded plain data and typed setup declarations. Compile the pinned CYaml/LibYAML parser subset from Yams 6.2.2 through an event bridge, rejecting aliases/anchors/tags/version-tag directives before composition. JSON uses a bounded separate grammar and Foundation string decoding. Bundle schema/catalogue and license notices with exact revision/hash inventory checks. There is no new host Python or YAML-library runtime dependency. Keep custom task YAML opaque; source references and factory selectors are declarations only. Exact scalar differences, source revisions and the committed dev-vm foundation (`e86550e`) handoff are recorded in [the implementation plan](docs/DevVMProvisioningPlan.md#milestone-2-foundation-handoff--2-november-2026).

**VERIFIED — local no-VM foundation:** make-based package build, 12 Swift test functions (including 94 parameterized cases), 18 unchanged-Python-loader oracle fixtures, and Swift tests/CLI with Python and Ansible absent from PATH pass. The existing dev-vm suite passes 235 tests with one Lua fixture skipped because Lua is absent, using the installed Homebrew Python and local socket access; both unchanged playbooks pass syntax checking. System Python 3.9/TOML and sandboxed Ansible local RPC failures were environmental and are recorded, not hidden. No host tool installation/upgrade, image download, credential access, app opening/install or existing-VM operation occurred.

**TO PROVE:** complete feature/profile/catalogue resolution, TOML/effective option semantics, source freezing, plan parity, full guest resources, immutable manager packaging/integration, operational CLI compatibility, read-only relocation, transport/authorization, jobs and live terminal. All manager setup features remain unimplemented/disabled. Foundation parser fixtures establish no VM or real-guest acceptance and change no existing runtime provenance or lifecycle policy.


## Shared Swift offline planning — 2 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** continue milestone 2 with feature/profile resolution, source snapshots and offline proposals against the Python oracle, without host tool installations or VM launches. Extend the existing dev-vm companion worktree; manager production dependencies and execution gates stay unchanged. The dev-vm continuation is committed at `56dba82368d13287b01e28a459a69b42da8620a1`.

**DESIGN DECISION / IMPLEMENTED:** port inheritance/conflict/override/tombstone behavior, dependency ordering, native package/mise requirements and predicted effects to the shared library. Preserve catalogue declaration order in JSON/YAML. Pin Swift-native TOMLDecoder with bounded TOML 1.0 compatibility checks. Freeze only selected inputs through no-follow descriptor-relative reads into an immutable in-memory snapshot, bound files/bytes/directories/depth, expand dotfiles and capture custom task YAML as opaque bytes. Bind proposals to source/resource/dependency inventories and input/plan digests; revalidation detects selected edits, additions/removals, permissions and root replacement. Existing Python controllers remain operational; Swift adds an offline `plan` command. Variable values and file/task contents are excluded from serialized proposals. Factory selectors remain declarations requiring manager admission; no new VM implementation or lifecycle owner is introduced.

**VERIFIED — no-VM checks:** build, 20 Swift test functions, 18 plain-data fixtures and 66 complete proposal/error cases (41 accepted/25 rejected) pass against the unchanged Python oracle. Oracle Python planning forbids subprocesses/manager access/interpreter fallback; native children use an empty tool PATH. All 20 Swift tests also pass with an empty tool PATH. An isolated CLI copy rejects a damaged bundled catalogue with a fixed error. Existing dev-vm regression tests pass 235 tests with the missing-Lua fixture skipped, and both unchanged playbooks pass syntax checking. Development-only Python is already installed; none is invoked by the compiled Swift planner. No host install/upgrade, credential access, app opening/install, guest contact or VM operation occurred. Exact pins, snapshot limits, compatibility changes and remaining evidence boundaries are in [the continuation handoff](docs/DevVMProvisioningPlan.md#milestone-2-offline-planning-continuation--2-november-2026).

**TO PROVE:** full parser/TOML parity beyond the fixture matrix, adversarial-writer filesystem transactions (not claimed), job snapshot materialization, full resource packaging, immutable manager integration, signed provenance/relocation, operational CLI cutover, transport/authorization, jobs/live terminal and real-guest behavior. In-memory snapshots and offline proposals grant no execution authorization. Earlier runtime provenance, guest/lifecycle rules and all disabled feature gates are preserved.


## Shared Swift transport and authorization contracts — 2 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** continue milestone 2 using fake guest adapters only, with no host tool installs or VM launches. Implement shared typed adapter contracts, native guest command descriptions and authorization/cleanup sequencing in dev-vm; no real transport or production manager execution path is added. This dev-vm continuation is committed at `f807104850dfd06527bcbee4ba5f0aca5a1404f4`.

**DESIGN DECISION / IMPLEMENTED:** bind explicit review to frozen source/engine, job, VM/runtime session, non-root owner/UID, host key, dependencies, mode/tasks/check policy, conflict policy and input lease. Require separate task/persistent-grant/Docker acknowledgements. A single-use actor validates every operation and correlated reply, arms cleanup before staging/grants, and separates primary failures from cleanup uncertainty. Cancellation interrupts only the matching command and retains the outstanding adapter call; cleanup survives caller cancellation. Require remote-work quiescence and compound native grant/cache revocation proof before reporting cleanup or restart readiness. Return restart-required metadata only; VMManager retains lifecycle ownership. Check mode never changes grants/cache, installs manifest packages or opts into Docker; custom tasks require explicit check selection and trust.

**PRIVATE COUPLING:** native guest command contract version 1 follows the inspected Python controller at `56dba82`, including stale-grant reset, interactive native persistent grant, cache invalidation, inactive-policy verification and native Docker consent/owner verification after revoke. The shared code describes fixed guest argv only and executes none. Reports/events carry fixed codes and job/command/VM/session IDs, exclude credentials/bindings/terminal bytes/raw errors, and use redacted descriptions for sensitive request/transport/recovery objects. Cleanup tickets are in-memory and pinned to the original target/dependencies/payload; recovery grants nothing and performs no setup or lifecycle work. Persistent recovery and explicit post-restart rebinding remain deferred. Attempt completion is not a VM `.exited` event and releases no runtime ownership/reservations.

**VERIFIED — fake-only tests:** build and 38 Swift test functions pass (18 new sequencing/native-contract functions), including partial grants, uncertain staging/cleanup, cancellation and reentrant-driver rejection, check/trust/input rules, 10 reply/pin mismatch cases, source invalidation, post-revoke checks, recovery without original sources and sanitized results. All 38 pass with an empty tool PATH. The 18 parser and 66 planning oracle cases remain passing; seven targeted existing Python tests run with mocked guest, Ansible and lifecycle calls. No actual SSH/Ansible command, host install/probe, credential access, UI action or VM operation occurred. The earlier full legacy suite was not rerun because this slice uses fake guest adapters only; prior evidence remains historical.

**TO PROVE:** actual identity/receipt authenticity, native commands and password echo/quoting, adapter deadlines and local/remote process cancellation/quiescence, concrete transports/payload staging, private persistent recovery/session rebinding, CLI/helper/UI integration, signed/pinned packaging, live terminal and real guests. Deadlines are an adapter contract, not proven wall-clock termination. Existing VM policy and manager execution gates remain unchanged. See [the transport/auth handoff](docs/DevVMProvisioningPlan.md#milestone-2-transportauthorization-slice--2-november-2026).


## Shared Swift concrete transport adapters — 2 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** implement the next milestone-2 slice
in the dev-vm companion worktree: concrete SSH/Ansible adapters, fake process
runners only, no host installations or VM launches. Manager changes are docs only;
all execution gates, lifecycle ownership, pinned-kit and personal-VM rules remain.
The dev-vm adapter slice is committed as
`9ebaf178de48e6480e248f8b20eae1f35c0d16b6` on
`codex/swift-provisioning-package` (3 November 2026).

**DESIGN DECISION / IMPLEMENTED:** pinned loopback SSH and Ansible command
construction, private immutable job materialization and bundled maintained guest
resources sit behind an injected runner and manager-owned session authority.
Revalidate dependencies/credential metadata/session before each process; never
read key contents. Preserve Ansible launcher entry paths while hashing resolved
targets. Interactive native authorization/Docker/package commands request an input
lease and terminal stream; Ansible requests live output with closed stdin. Track
cancellation between processes and require exact local exit before cleanup.
No live process runner, PTY, UI terminal or operational Swift command is shipped.

**PRIVATE COUPLING:** a guest-only Python helper binds one exclusive UUID payload
lease to recorded systemd user scopes and an Ansible shell wrapper. Preparation
requires Linux/aarch64/non-root Python 3, cgroup v2, a user manager/bus and scoped
execution with `--expand-environment=no`, before sudo grant. Quiescence seals new
body work and requires known scopes inactive/empty; uncertain registration blocks
proof/removal. Only the verified guest job temp root may be removed. This is not
a sandbox for trusted task code or independent services. Uncertain startup can
require manual recovery. The helper adds no host Python runtime or VM lifecycle
implementation; Homebrew continues to supply Ansible's dependencies.

**VERIFIED — fake-process checks:** make build and 50 Swift test functions,
including 12 new transport functions, pass; all 50 pass with an empty tool PATH.
The 18 parser/66 planning oracle fixtures and seven mocked Python sequencing tests
pass. New Python files compile and 21 bundled YAML files parse statically. No
real SSH/SCP/SFTP/Ansible executable, credential contents, host install, app/UI or
VM operation is used. Full legacy/Ansible syntax execution was not repeated for
this fake-process-only slice. Prior real-VM evidence remains unchanged.

**TO PROVE:** real authentication/SSH quoting, Ansible/native package parity,
guest systemd/cgroup registration and privileged descendants, hard deadlines,
local/remote cancellation/quiescence, PTY/password echo/live output, persistent
recovery/session rebinding, operational CLI and manager/helper integration, signed
packaging and real-guest acceptance. See [the concrete adapter handoff](docs/DevVMProvisioningPlan.md#milestone-2-concrete-command-adapters--2-november-2026).


## Shared Swift local process runner and PTY — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** continue milestone 2 with a local
process runner and PTYs, tested solely using disposable local fixtures. No real
SSH/Ansible, host installs or VM launches. Manager changes are docs only; no
production dependency, setup feature gate or lifecycle policy changes.
The dev-vm continuation is committed as `bb3fae22be45b38035fac52aefa0eb270a9d0fea` on
`codex/swift-provisioning-package` (3 November 2026).

**DESIGN DECISION / IMPLEMENTED:** exact argv/environment/cwd, bounded separate
capture or raw terminal streams, closed/bounded stdin, new local sessions and
matching-ID cancellation/deadlines. Retain a waitable leader until the owned
group is inactive and output EOF, then reap; uncertain cleanup retains ownership
and blocks new runners for that VM/session. Explicit reconciliation and a retained
local reaper never relaunch or signal a reused PID. This is in-memory ownership,
not persistent recovery or a sandbox for deliberately detached code.

A small Darwin C syscall bridge and pinned `dev-vm-process-host` exec launcher
supply controlling PTY semantics without fork in the Swift runtime. Future helper
packaging must admit/distribute that binary. No new Homebrew/Python runtime is
required. Terminal bytes remain bounded, sequenced, memory-only and separate from
structured events; slow readers get explicit gaps. One reviewed input lease
controls bounded input/resize; local PTYs are raw/no-echo, and revocation drops
pending input without cancelling the job. No renderer, IPC attach or automatic
secret redaction is supplied.

**VERIFIED — local fixtures:** make build and 64 Swift test functions pass (14
new local-runner functions), including controlling/foreground terminal, sizing,
synthetic input without echo, overflow, cancellation/TERM-resistant children,
exact capture, descriptor isolation, stale admission and uncertain-pipe cleanup.
All 64 also pass with an empty tool PATH; 18 parser and 66 planning oracle cases
remain passing. PTY `/dev/tty` access required execution outside the workspace
filesystem sandbox; restricted failures are recorded in the handoff. Tests use
private UUID roots with copied compiled binaries and confirm no live fixture
children; launchd reaps orphan zombies. No real SSH/SCP/SFTP/Ansible command,
credential, host installation, UI or VM operation occurs.

**TO PROVE:** actual remote SSH/Ansible/guest authorization and echo/quiescence,
deliberately detached code and kernel stalls, foreign reapers, cross-process/crash
recovery, launcher signature/relocation/admission, terminal renderer/escape policy,
IPC/viewer resynchronization and operational CLI/manager integration. Local process
exit is not guest quiescence or VM exit and releases no runtime resources. See
[the local runner handoff](docs/DevVMProvisioningPlan.md#milestone-2-local-runner-and-pty--3-november-2026).


## Pinned provisioning manager/helper integration — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** integrate the pinned shared package and
resources into manager/helper builds, tested with local fixtures only. No real
SSH/Ansible, installs or VM launches. Add offline admission/planning only; no setup
execution gate, job coordinator, lifecycle policy or installed app changes.

**IMPLEMENTED:** an unchanged 79-file source export at dev-vm `bb3fae22be45b38035fac52aefa0eb270a9d0fea`
is bound by a source/resource lock and generated compiled pin. Root SwiftPM links
the library into core/helper and exactly resolves TOMLDecoder. Builds verify
source drift and refuse optional parser plugins. The pinned C launcher is built
unchanged through a separate generated SwiftPM package. App assembly/signature/
layout checks now include the provisioning resources/licenses, offline helper,
launcher, source lock and final signed-child hash manifest. Bundle diagnostics
include source revision and disabled execution. No runtime-kit source is changed.

**PRIVATE COUPLING:** bounded embedded package admission supports the two known
SwiftPM layouts, refuses overrides/links/special files/extra or damaged resources
and changed child binaries, and repeats verification after offline work. The
helper accepts verify-package/validate-manifest/plan only, returns fixed errors
for execution, and never initializes registry/credentials/socket/tool probes or a
runner. Plans stay nonexecutable. Integrity manifests do not establish signing
authority; the app signature pipeline supplies that distinct check.

**VERIFIED — local checks:** build, 227 Swift tests/38 suites, 48 script tests
and actual offline helper relocation fixtures pass. A private ad-hoc sealed
fixture app, with no runtime kit, validates/plans read-only with empty tool PATH
and private empty HOME/TMPDIR; it rejects execution, resource overrides and
resource/launcher damage, and does not serialize synthetic variable values.
Strict deep signature checks pass before resource damage and reject it afterward.
The fixture manager executable is sealed but never opened/executed. No real SSH/
SCP/SFTP/Ansible, Keychain item, permission prompt, host install, UI action, image
download, installed-app change or guest operation occurs. Sandbox socket/context
failures and the initial unavailable-network update are recorded in the handoff;
full fixture regression passes outside that restriction using existing exact
source objects and private caches. The separate dev-vm code remains unchanged.

**TO PROVE:** complete runtime-kit app assembly/release signature/notarization,
other-Mac relocation, coordinator/journal/session adapters and helper IPC, terminal
UI/attach, operational CLI, persistent recovery and real guest/SSH/Ansible/echo/
quiescence behavior. Package fixture success changes no VM `.exited` ownership,
kit provenance or earlier real-guest evidence. See [the integration handoff](docs/DevVMProvisioningPlan.md#milestone-2-pinned-managerhelper-integration--3-november-2026).


## Provisioning coordinator and job journal foundation — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** start milestone 3 with coordinator and
private job-journal implementation, tested using fake runtimes/adapters and local
fixtures only. No real SSH/Ansible, installs or VM launches. Constructor/backend
injection stays internal, with no app/helper/CLI execution entry point, production
journal creation or enabled setup gate. Shared engine/resource pin remains
`bb3fae2`; the pinned sequencer still owns native guest authorization/cleanup.

**IMPLEMENTED:** one detached provisioning worker per coordinator/VMManager,
accepted-job/review deduplication, stale source/engine/session/dependency admission,
explicit cancellation and independent viewer lifetime. Journal state and command
correlation precede adapter calls. The explicit private 0700/0600 schema-1 store
uses exclusive file-description locking, atomic fsynced writes, directory/lock
identity and revision checks, bounded strict decoding and fixed result codes.
It stores digests/manager-owned IDs/status only, excluding credentials, source
paths/data, terminal bytes and helper PIDs. Bad/changed journals are preserved and
new work fails closed; write failures still permit original-target revocation.

**DESIGN DECISION / IMPLEMENTED:** VMManager leases protect active/unresolved jobs
from pause/suspend/edit/delete/start and defer ordinary shutdown for cleanup.
Confirmed force stop and unexpected session/execution/SSH changes retain cleanup
risk. Quit uses bounded cleanup attempts before normal shutdown, never releases a
VM handle before matching `.exited`, and preserves uncertain work on disk. Final
clean proof is sealed against later lifecycle races; diagnostic `.error` is not a
boundary. Restart-required is metadata only, without automatic lifecycle actions.

**PRIVATE COUPLING / LIMIT:** explicit same-process recovery uses the engine's
opaque live ticket and exact original pins, independent of sources/input. Reopen
never resumes apply or reconstructs ownership from a PID. The pinned package has
no persistent ticket API; durable frozen-input capsules, authenticated helper
recovery and explicit restart rebinding remain pending. Journal cleanup holds
cannot be cleared from a stopped observation alone. No source/credential copies
are persisted by this foundation.

**VERIFIED — local checks:** make build/test passes 248 Swift tests/40 suites
(21 new coordinator/journal functions), 48 script tests and existing relocated
package fixtures. Tests cover write-ahead/private storage, corrupt/replaced
journals, duplicate/stale admission, missing input, viewer detach, shutdown/force
stop, sleep/exit/SSH loss, cleanup deadline/late worker ownership, disk failure
with attempted revoke, live cleanup recovery without sources and conservative
reopen. New provisioning paths use no subprocess; existing socket/synthetic
LAContext fixtures run outside the workspace sandbox without Keychain calls or
authentication UI. No real SSH/SCP/SFTP/Ansible, host install, UI, image download,
installed app or VM operation occurs.

**TO PROVE:** real coordinator/helper IPC and ownership, durable inputs and
post-crash authenticated recovery, SSH-ready waiting/restart rebinding, UI/CLI and
terminal jobs, retention/migration, kernel/helper failures and actual hard cleanup
deadlines, and real guest/auth/echo/quiescence behavior. This is the milestone-3
foundation only. Existing VM lifecycle/provenance and real-guest evidence retain
their prior labels. See [the coordinator/journal handoff](docs/DevVMProvisioningPlan.md#milestone-3-coordinatorjournal-foundation--3-november-2026).


## Durable provisioning inputs and cleanup checkpoints — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** continue milestone 3 using fake runtimes
and local fixtures only. No real SSH/Ansible execution, host installs or VM launches.
Execution gates and offline-only helper entry points remain disabled.

**IMPLEMENTED:** new jobs preallocate a payload UUID and worker token, then fsync
private frozen inputs and a separate cleanup checkpoint before journaling the
running risk marker and delegating work. Schema-2 journal rows bind both artifact
hashes; schema-1 risk is preserved without inventing missing authority. Journal
size is 256 KiB to match the strict parser (superseding the earlier 1 MiB claim).
The 0700 artifact directory/0600 immutable files have exact hashes, link/mode/root
checks and a 256 MiB/512-file quota counting orphans. No automatic import, replay,
pruning or deletion occurs. Selected user configuration may be sensitive and is
kept out of reports/terminal/journal; private storage is not encryption.

The versioned bounded binary input archive retains selected bytes/modes/directory
membership and restores inert data only. It cannot reconstruct an executable plan,
resume apply or extract files into user paths. A cleanup checkpoint restores only
conservative original-scope cleanup risk. The engine retains its payload/control
helper while grant/cache inactivity is unproved.

Explicit persistent cleanup requires the exact original live VM/session/guest,
approved review, payload/worker, engine/dependency/binding/checkpoint pins, plus a
fresh challenge response proving the prior worker is stopped AND fenced from
launch. This authority is injected and fake-only in this slice; PID/disk metadata
is never sufficient. Session/dependency authority is rechecked after awaits and
before commands. Missing/corrupt input archives cannot suppress cleanup. Damaged
checkpoints without a genuine live ticket preserve uncertainty. Idle close/reopen
drops all tickets and releases the journal lock; active close is refused and VM
holds survive handoff. No body command, grant, prompt, restart or rebinding can be
issued by recovery; matching `.exited` still owns VM handle/resource release.

**PRIVATE COUPLING:** the manager consumes base `bb3fae2` plus the exact hashed
`Patches/dev-vm-durable-state.patch`, with base/result inventories and a resulting
source-snapshot digest. This supersedes the earlier unchanged-engine statement.
Source preparation verifies patch lineage locally and uses no mutable checkout;
license/parser/guest-resource and C launcher bytes remain unchanged.

**VERIFIED — fakes/local fixtures:** full `make test` passes 260 manager Swift
functions/40 suites, 49 script tests and relocated/read-only offline-helper checks.
Shared build/tests plus static oracles pass 68 Swift functions, 18 parser and 66
planning/error fixtures. Coverage includes fresh fenced worker proof, interrupted
markers, source/input removal, corrupted/cross-job/unsafe checkpoints, quota/orphan
preservation, legacy migration and no replay. A graceful-shutdown completion race
now cancels body work without misclassifying the still-valid guest or suppressing
cleanup. Existing socket/mock-context and local PTY fixtures need the sandbox
exception; no actual credentials/auth UI or real transport/VM operations occur.

**TO PROVE:** production helper IPC/fencing and coordinator construction, recovery
after full manager/VM restart, reviewed session rebinding, real helper absence/
crash and power-loss durability, retention/removal, SSH waits, live terminal/job
UI and CLI, and all real guest/transport/authentication behavior. These local
foundations do not promote any existing real-guest evidence labels. See the
[durable continuation](docs/DevVMProvisioningPlan.md#milestone-3-durable-inputs-and-cleanup-recovery--3-november-2026).


## Authenticated provisioning helper control and ownership — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** continue milestone 3 with authenticated
helper IPC/ownership reconciliation, using fake runtimes and local fixtures only.
No real SSH/Ansible, host installs or VM launches. The supplied Setup-tab screenshot
is the future stage-strip/live-terminal reference, not guest-validation evidence;
no UI takeover, permission grant or terminal rendering is performed.

**IMPLEMENTED:** an inherited same-user AF_UNIX control connection uses a private
per-launch capability delivered only through an anonymous bootstrap pipe. HMAC
frames bind direction, instance/binary/package pins, channel, sequence and exact
payload. Strict bounded messages reject unknown/duplicate fields, replay,
reflection, wrong keys/pins and uncorrelated request/challenge replies. Capability
bytes never enter argv/environment/disk/journal/status/logs. One request is allowed
in flight; timeouts/malformed replies poison the channel without automatic retry.
No listener/path discovery or stored-PID ownership inference is introduced.

The helper registry accepts worker bindings from its trusted local owner only;
wire requests cannot register or start anything. Missing/new helper state returns
unknown. A process-runner wrapper permanently fences the original worker before
waiting, owns each delegated task/ID and retains uncertain/mismatched process
receipts. Only matching local exit/not-started or exact retained local cleanup
can prove the local worker stopped and fenced. A stopped task/EOF/diagnostic never
proves guest quiescence, grant revocation or success. Disconnect fences local
workers and stops new registration. The coordinator can consume this authenticated
proof for its existing explicit cleanup-only recovery after reopen, with fresh
original-session/dependency checks. VM ownership still ends only at `.exited`.

**PRIVATE COUPLING:** helper control API 1 has only reconciliation, no shell,
apply, terminal/input, PID, arbitrary path or registration command. The packaged
helper's internal inherited-channel mode admits its distribution and bootstrap
pins, then serves an empty ownership registry without a runner/tool probe/journal/
Keychain/VM. It reports unknown; production job launch and worker registration are
not enabled. The shared package source/resource pin is unchanged. Authentication
is possession of a privately handed-off capability, not signing/notarization or
protection from a malicious same-user memory writer. Automatic production launch
must independently admit the child and preserve exclusive backend ownership.

**VERIFIED — fake/local checks:** full `make test` passes 275 Swift functions/41
suites (15 new IPC/coordinator functions), 49 script tests and expanded relocated
read-only package checks. Swift worker backends are all fake. The actual ad-hoc
sealed helper authenticates an inherited socket/pipe with empty PATH/private
HOME/TMPDIR; it reports unknown for missing ownership, rejects replay/wrong MAC/
bootstrap pins and leaks no secrets or host state. Existing strict signature/
tamper tests still pass. Full regression uses the existing local socket/mock-auth
sandbox exception, without real auth UI, tools/guests or host installs. Shared
package sources/pins remain unchanged and were not retested in this docs-only
companion handoff.

**TO PROVE:** production admitted launch/registration/executor wiring, operational
job IPC, full manager-process restart and reviewed session adoption, signing/
audit policy where needed, real helper/guest crash and remote cleanup, hard kernel
stall deadlines, live terminal streams/input leases and UI/CLI. This slice can
reconcile a surviving helper after coordinator reopen; an empty replacement helper
cannot prove lost ownership. Existing real-guest evidence labels remain unchanged.
See the [helper-control handoff](docs/DevVMProvisioningPlan.md#milestone-3-authenticated-helper-ipc-and-ownership--3-november-2026).


## Admitted provisioning helper launch and inert registration — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** continue milestone 3 using fake runtimes
and local fixtures only. No real SSH/Ansible, host installs, VM launches or UI
operations. Admit and register an inert helper worker only; engine/job dispatch,
transport activation and product setup entry points remain disabled.

**IMPLEMENTED:** an internal launcher verifies package/resource/binary pins,
strict outer/nested signatures, and the retained executable's identity. Default
admission requires non-ad-hoc matching app/helper Team IDs; only explicit internal
fixtures may choose ad-hoc/no-team admission. Before capability handoff, verify
the owned spawned child's dynamic code against the admitted cdhash requirement.
The PID is a transient lookup from this waitable child, never stored or used for
adoption/signaling/ownership proof. Spawn passes explicit cwd/private HOME/TMPDIR,
empty tool PATH, anonymous bootstrap stdin, null stdout/stderr and one inherited
control fd, with CLOEXEC-default exclusion of unrelated descriptors. Capabilities
remain volatile and never enter arguments/environment/disk/diagnostics.

Private bootstrap 2 reserves one metadata-only original worker and receives an
authenticated exact-digest receipt. Bootstrap 1 stays empty/unknown. Reserved
workers have no activation or engine API; fencing retires them permanently.
Unknown/partial registrations, receipts, owner substitution and duplicate launch
tickets fail closed. A helper instance is freshly minted per new job; a saved
owner cannot create a replacement helper claiming earlier work.

The coordinator freezes inputs and publishes schema-3 helper instance/executable/
package pins, registration digest and pending marker before spawn. It revalidates
review/package/source/session/dependencies before and after registration, then
marks the receipt accepted while keeping the job queued/no engine worker and a
conservative cleanup hold. Duplicate submissions cannot dispatch body work.
Schema 1/2 records preserve risk without invented helper authority; partial/unknown
owner fields and owner fields in legacy schemas are rejected. Existing private
file/lock/hash/size/quota/orphan rules remain. After owner publication, failures
retain its exact identity and cleanup-required status rather than quietly retrying.

Explicit cleanup after coordinator reopen requires the same retained authenticated
launch service, fresh original-owner proof and original guest/session checks.
Confirmed remote cleanup closes the exact helper channel; child handles/capabilities
remain owned until matching helper exit, independently of VM ownership. A lost
child wait retains uncertainty; there is no arbitrary PID kill or automatic
replacement. Control metadata roots are explicit/private, not VM storage. The
shared engine/resource pin and VM `.exited` lifecycle policy are unchanged.

**PRIVATE COUPLING:** schema 3, private bootstrap 2 and metadata-only receipt extend
the earlier authenticated control contract. A debug-only Swift fixture target
exercises the real factory against an ad-hoc sealed disposable app and is excluded
from app staging; its release entry point is disabled. No signing credentials or
real identity are used. The screenshot remains the terminal design reference.

**VERIFIED — fake/local checks:** `make test` passes 284 Swift functions/42 suites
(9 new registration/coordinator/journal functions), 49 script tests and expanded
read-only signed package fixtures. Fakes cover journal-before-spawn, changed
admission/session, failed/mismatched receipts, final-write failure, duplicate
submissions, persisted owner pins and original-service recovery after reopen.
The debug-only fixture runs the real factory with an explicit ad-hoc policy:
production policy rejects ad-hoc code; resource tamper and executable inode
replacement fail before admission; normal bootstrap/registration/reconciliation
passes and the matching child is reaped with no control-directory output.
Existing protocol/signature/tamper checks pass. Fixture lookup was corrected to
use either admitted SwiftPM resource layout. No real signing credentials,
authentication UI, host installs, guest transport or VM operation is used. Existing
local socket/mock-auth sandbox exceptions apply; shared code/pins are unchanged.

**TO PROVE:** product wiring and operational engine/backend dispatch, actual
release signer/Team policy, full manager restart/reconnect and reviewed VM/session
adoption, real helper/guest failures and grant cleanup, hard kernel stalls,
retention/removal, SSH waits and terminal/input/UI/CLI. Earlier real-guest evidence
keeps its labels. See [the admitted-launch handoff](docs/DevVMProvisioningPlan.md#milestone-3-admitted-helper-launch-and-worker-registration--3-november-2026).


## Helper-side shared-engine dispatch and activation — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** continue milestone 3 with helper-side
engine dispatch and worker activation, using fake runtimes and local fixtures only.
No real SSH/Ansible, installs or VM launches. Production backend/context factories,
app/CLI execution gates and terminal UI remain disabled.

**IMPLEMENTED:** a prepared worker consumes one immutable activation bound to its
original registration/owner/plan/input/review/engine/dependency/session scope.
Authenticated typed activate/status/cancel requests preserve MAC/request/sequence
correlation and contain no plan bytes, arbitrary paths, executable/credential or
terminal data. Activation's acknowledgements are ANDed with helper-local approval;
missing task/grant/Docker consent cannot be invented. Duplicate identical activation
returns status without another task; a changed activation or a prior fence cannot
reopen the worker. Preparation must run no guest/process operations.

The helper validates a local prepared context then invokes the pinned shared
sequencer with the original payload ID. Its owned task survives viewer/RPC detach.
Command bindings, package/body admission, session/dependency authority and a known
closed-channel body gate are checked around work. Cancellation/fencing stops body
work while permitting known-target sequencer cleanup. Completion retires/fences
its owned runner; local uncertainty overrides apparent guest success. Contexts,
owned local tasks and handles remain retained, and helper EOF is not an exit or
remote-cleanup proof. Status/results are bounded fixed types, not terminal/raw
errors or source values. No authorization/Ansible logic is duplicated.

Schema 4 journals activation UUID/digest and risk before the activation RPC. Manager
polling is detached from viewers and checks exact activation/correlation and
monotonic status. Lost replies, invalid status, disk failure and runtime/session/
dependency invalidation preserve cleanup-required without automatic replay. Old
schemas preserve risk without invented activation. Coordinator reopen records
interruption, not a restarted apply. Existing lifecycle interlocks, cancellation
grace and final proof sealing remain; matching VM `.exited` still releases guest
resources independently of helper-child exit.

**PRIVATE COUPLING:** control payloads extend frame 1/bootstrap 2 with activation
and sanitized results. The normal helper provides no engine context factory and
rejects execution. A separate ad-hoc-signed temporary fixture app uses the excluded
debug fixture binary as its helper, with a fixed synthetic manifest/fake backend;
no production argument/environment/RPC enables it. This preserves the admitted
image/capability/owner chain while testing actual helper-process dispatch. Shared
package sources/resources/pins are unchanged. There is no frozen-archive extraction
or arbitrary executable/source transfer added to the control channel.

**VERIFIED — fake/local checks:** `make test` passes 297 Swift functions/43 suites
(13 new engine/coordinator/journal functions), 49 script tests and expanded signed
package fixtures. Coverage includes one-shot apply/check, consent/context/source
refusal, fence/cancel/disconnect ordering, physical uncertainty, journal-before-RPC,
viewer detach, shutdown, lost/malformed replies, failed writes, no replay after
reopen, schema preservation and runtime/SSH/dependency invalidation. Diagnostics
alone are not lifecycle exit. The normal helper refuses activation without a
factory. A separately sealed/ad-hoc-signed temporary fixture helper runs the
actual sequencer with only synthetic adapters, reports clean completion and
cancellation/cleanup, and is reaped through the owned launcher. Existing protocol/
signature/tamper checks still pass. No real signing credentials, auth UI, host
installs, SSH/Ansible or VM operations occur; existing local socket/mock-auth
sandbox exceptions apply. Shared sources/pins are unchanged and not retested.

**TO PROVE:** production frozen-context/consent transfer, exclusive real backend
and manager-aware session authority, product wiring, full restart/reconnect and
reviewed rebinding, release signer acceptance, real guest/auth/echo/quiescence/
crash/kernel behavior, terminal/PTY/input/UI/CLI. The screenshot remains a reference;
no user UI or installed app is changed. Earlier real-guest evidence labels remain.
See the [helper dispatch handoff](docs/DevVMProvisioningPlan.md#milestone-3-helper-side-engine-dispatch-and-activation--3-november-2026).

## Frozen-input delivery and helper context validation — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** continue milestone 3 using fake runtimes
and disposable local fixtures only; no real SSH/Ansible, installs or VM launches.
This supersedes the pending frozen-context handoff in the preceding record.

**DESIGN DECISION / IMPLEMENTED:** persist a private immutable `DVMCNTX1` delivery
blob containing the existing selected archive and strict reviewed-request metadata.
Bind exact total/metadata/archive hashes and byte count into the authenticated
registration and schema-5 journal, before spawn. A retained read-only descriptor
checks private ownership, mode, single link, file/path identity and digest. Spawn
inherits an empty separate socket at fd 4; only after verifying package and owned
live-child code send bootstrap 3 and bounded chunks. No source path or content
enters arguments, environment, control/status/terminal frames or diagnostics.
Capabilities still exist only in memory/private pipes, never in these artifacts.

**DESIGN DECISION / IMPLEMENTED:** validate hashes, strict fields and original
job/guest/session/dependency/review bindings before materializing only into a fresh
private helper-owned UUID tree. Descriptor-relative no-follow/exclusive traversal,
file/directory/depth/byte bounds and fsync preserve selected binary bytes, modes
and empty directories. Independently replan inside that tree using the original
relative manifest; compare plan/input/engine and reconstructed review identities
before acknowledging registration. The archive remains inert data, never an
imported executable plan, cleanup proof or automatic apply/resume authority.
An injected backend receives the validated context; delivered, backend and explicit
activation consent combine by AND. Retain/recheck its private storage through work;
cleanup still uses the independently bound original checkpoint without source or
input availability. Product helper backend construction and execution gates stay
disabled. Only the excluded Debug fixture uses synthetic guest adapters.

**DESIGN DECISION:** original source verification remains required before job
publication/handoff. After a frozen registration is accepted, the selected private
copy defines the reviewed job; mutable checkout changes/removal cannot replace or
invalidate that copy. Manager activation checks persisted delivery/inputs and the
helper checks its rebuilt private context. Legacy non-delivery registrations keep
source preflight. No replay, guest rebinding, input grant or restart adoption is
added. Schemas 1–4 preserve risk and ownership without invented delivery receipts.
No artifact is automatically imported or removed; partial private trees are retained.

**PRIVATE COUPLING:** shared `SetupPlan.manifestPath` is now public read-only.
Update its engine inventory and manager's exact base-plus-integration-patch lock
and compiled pin together (82 resulting files). The base remains `bb3fae2`; the
patched result has a new engine/source identity. Guest resources, parser dependencies
and C launcher are unchanged. No mutable external checkout dependency is used.

**VERIFIED — fake/local checks:** `make test` passes 308 manager Swift functions/
44 suites, 49 script tests and expanded relocated/read-only signed-helper fixtures.
Coverage includes independent replan, custom manifest/catalogue/tasks, binary/mode/
empty-directory preservation, changed metadata/identities/framing/hashes, private
file/root/link substitution, implicit-directory bounds, strict receipt/bootstrap/
journal migration, consent constraints and frozen activation after source removal.
Actual admitted product helper validates delivery but denies activation. The
separately sealed/ad-hoc-signed Debug helper validates a multi-frame payload and
uses only fake adapters for completion/cancellation after parent source deletion.
Changed delivery is refused; matching child exits are reaped. No fake backend is
installed into the product app. Shared build/tests and development oracle checks
pass 68 Swift functions, 18 parser fixtures and 66 complete planning/error fixtures.
Only disposable local socket/mock-auth/PTY sandbox exceptions and ad-hoc fixture
signing are used; no real signing credentials, auth UI, transport, installs or
VM operation occurs. Existing real-guest evidence labels remain unchanged.

**TO PROVE:** trusted manager-aware session/dependency authority and exclusive real
backend construction, product coordinator wiring, full restart/reconnect/rebinding,
real release-signature acceptance, power-loss durability/retention UX, live terminal/
PTY/input/UI/CLI integration and real guest/auth/echo/quiescence/crash/kernel behavior.
The supplied screenshot remains a visual reference; no UI or installed app changes.
See the [frozen-input handoff](docs/DevVMProvisioningPlan.md#milestone-3-frozen-input-delivery-and-helper-context-validation--3-november-2026).

## Helper backend construction and manager session authority — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** continue milestone 3 using fake runtimes
and disposable local fixtures only. No real SSH/Ansible, installs or VM launches.
This supersedes the pending construction/authority foundation above; execution
surfaces remain disabled and no UI or installed app changes.

**DESIGN DECISION / IMPLEMENTED:** a single-use helper backend constructs the
existing shared SSH/Ansible adapter and original-worker fenced runner from an
explicit trusted helper-local transport-resource provider. Require the validated
frozen request, original bindings/digests, package admission and fresh manager
permission before resource access and runner construction. Verify connection/tool
pins around awaits without probes or reading identity-file bytes. The exact same
manager authority guards the context, adapter and runner; authority-bound workers
cannot fall back to local-only validation. Product entry points provide no resource
provider or operational runner; all tested factories return fake process runners.
Production managed-SSH/Homebrew resource admission and handoff remain product work.

**DESIGN DECISION / IMPLEMENTED:** bootstrap 4 binds the authority version and an
independent inherited fd-5 session channel. Frozen data/control remain separate.
Session HMAC keys have a distinct derivation domain and counters; control packets
cannot act as authority. One-shot registration/activation binding follows durable
activation/lease publication. A separate reverse-RPC loop awaits the coordinator
without blocking the launcher's control lock, keeping status/cancel serviceable.
Fresh challenge-bound checks cover preparation, commands, process invocations and
completion. Strict bounded metadata includes original opaque scope and typed
operation/purpose, never owner names, credentials, paths/argv or terminal bytes.
No successful decision is cached; bad/lost/replayed replies poison the channel.

The coordinator compares the live generation/journaled activation and original
scope, revalidates the actual VMManager lease plus dependency/binding authority,
and repeats its state checks after awaits. Current running session, SSH owner,
shutdown/power/execution/storage state remain manager-owned. Process ownership is
recorded before permission; fencing/cancellation is checked again before backend
launch. Body revocation returns not-started locally and typed cancellation to the
sequencer. Valid original-target cleanup can continue after cancellation or package/
source loss; failed journal writes stop body work while permitting cleanup against
the retained lease and preserving risk. Missing/expired/invalid authority cannot
invent remote cleanup proof. Physical uncertainty retains the exact local runner.

**DESIGN DECISION / IMPLEMENTED:** schema 6 persists the optional original session
version, requiring genuine delivery and helper owner. Unknown/null/legacy markers
fail closed; schemas 1–5 retain risk/pins without invented authority or replay.
Lost channels fence local work. A new helper, saved PID or disk row cannot adopt
manager/VM ownership. Matching VM/helper exit boundaries remain separately retained.

**PRIVATE COUPLING:** shared connection verification is public stat-only metadata
revalidation, tool verification is public, and fixed process purposes gain Codable.
The engine inventory and exact 82-file base-plus-patch export/compiled pin change
together. Base `bb3fae2`, guest resources, parser dependencies and C launcher remain
unchanged; the patched engine identity is new.

**VERIFIED — fake/local checks:** `make test` passes 319 manager Swift functions/
45 suites, 49 script tests and expanded relocated/read-only signed-helper fixtures.
Coverage includes concrete adapter apply/check with fake runners, construction
resource checks, fresh per-invocation permission, cancellation/shutdown/exit/SSH/
dependency/package/channel races, cancellation during dependency validation,
failed-journal cleanup, strict MAC/challenge/schema/one-shot binding, local-authority
bypass refusal and physical-uncertainty recovery without backend reconstruction.
The actual product helper refuses activation without a provider. A separate
ad-hoc-signed Debug helper constructs the adapter with inert files/fake runner and
uses the actual inherited authority channel for completion and deterministic
cancellation/cleanup; matching owned child exit is reaped. Shared checks pass 68
Swift functions, 18 parser oracle fixtures and 66 complete planning/error fixtures.
Only local socket/mock-auth/PTY sandbox exceptions and ad-hoc fixture signing are
used. No real credentials/auth UI, transport, installs or VM operation occurs.

**TO PROVE:** product transport-resource admission/handoff and construction, real
runner/terminal/input leases, UI/CLI, full restart/reconnect/rebinding, release
signatures, power-loss/retention UX and real guest/auth/echo/transport/quiescence/
cleanup/crash/kernel behavior. Fresh RPC checks are not atomic remote execution
or proof of guest liveness after a reply. Earlier real-guest evidence labels stay
unchanged; the supplied terminal screenshot remains a visual target.
See the [backend/session-authority handoff](docs/DevVMProvisioningPlan.md#milestone-3-helper-backend-and-manager-session-authority--3-november-2026).

## Transport-resource admission and private handoff — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** continue milestone 3 with fake runtimes
and local fixtures only; no real SSH/Ansible, host installs or VM launches. This
implements the admission/handoff foundation previously pending. Product execution
gates stay disabled; no UI, installed app or operational runner is enabled.

**DESIGN DECISION / IMPLEMENTED:** admit transport resources from the current
VMManager session/profile and explicit owned root. Require running/ready original
owner/session and no conflicting lifecycle/storage operation. Validate public
managed SSH manifests, exact port and known-host identity plus root identity;
derive the private identity-file reference without reading its bytes. Never call
credential generation, key-reading storage validation or a guest probe. Admission
consumes an already verified schema-2 tool report, checks fixed system entries,
coherent Homebrew Ansible version/installation/targets and current fingerprints,
and captures original executable hashes/stamps and a stat-only single-link key
reference. It does not rerun tool probes or claim new signing/runtime provenance.

Compute the dependency digest from the canonical original resource selection and
require it in the reviewed request. Bind the ephemeral private handoff to the
original job/VM/session/payload/worker/review/checkpoint/source/engine/mode. Recheck
against the actual manager root/port at publication, handoff, acceptance, activation
and command/invocation authority boundaries. Replaced resources need new review;
changed credentials/tools never become cleanup replacements by inference.

**DESIGN DECISION / IMPLEMENTED:** bootstrap 5 binds a resource receipt and separate
inherited fd-6 stream, handed over only after package/owned-child code admission.
Strict bounded parsing, SHA/size/EOF and original proof comparison precede helper
acknowledgement. Paths, public metadata and stat/hash proofs stay in memory/private
stream; no descriptor is saved and no paths/bytes enter argv/environment/control/
status/terminal/journal. Private-key contents are neither read nor transferred.
The helper's host policy is independent of the descriptor; only explicit test code
injects fixture policy. A resource-bound backend must use the validated handoff.
Product helper has no process-runner factory and still refuses activation.

**DESIGN DECISION / IMPLEMENTED:** schema 7 stores only the original resource
receipt, requiring matching dependency, frozen inputs and manager authority.
Schemas 1–6 preserve risk and old pins without invented resources or replay.
Live admission/service state is retained separately; reopening never reconstructs
credentials or replays a queued job from journal metadata. Existing explicit
cleanup/ownership protocols remain separate; no new restart adoption or automatic
resource import/removal is introduced.

**PRIVATE COUPLING:** shared `ProvisioningTransportReference` privately exports/
imports original executable and identity proofs, with exact expected binding/paths,
strict nested schemas and link-count checks. It never authorizes execution or
recaptures changed files. Base-plus-patch export now contains 83 files with updated
source/engine/compiled pins; base remains `bb3fae2`. Guest resources, parsers and C
launcher retain their bytes.

**VERIFIED — fake/local checks:** `make test` passes 328 manager Swift functions/
46 suites, 49 script tests and expanded signed-helper fixtures. Cases cover managed
endpoint/report/private round trip, original key/tool/alias/installation/metadata/
root changes, cross-job/mode/dependency/format damage, host policy, acknowledgement
refusal, schema preservation, fresh activation/invocation checks and no replay.
Concrete apply/check use only fake process runners. The separately sealed/ad-hoc
Debug helper imports the actual private stream, constructs the shared adapter from
original proofs, completes/cancels with fake replies and reaps its owned child.
The product helper rejects fixture paths under host policy; no fixture policy or
runner is installed into it. Shared checks pass 70 Swift functions, 18 parser oracle
fixtures and 66 complete planning/error fixtures, including stat-only round trip
with an unreadable synthetic identity. Only existing local IPC/mock-auth/PTY sandbox
exceptions and ad-hoc signing are used. No real credential/auth UI, host install,
guest transport, VM launch or installed-app change occurs.

**TO PROVE:** product resource acquisition/coordinator wiring and report provenance/
lifetime, genuine managed-SSH/Homebrew admission across supported installations,
operational runner/terminal/input/UI/CLI, full restart/reconnect/rebinding, release
signatures, power-loss/retention UX and real guest identity/auth/echo/transport/
remote cleanup/quiescence/crash/kernel behavior. Hash/stat/RPC checks are not atomic
remote execution or proof of guest liveness after a reply. Prior real-guest labels
remain unchanged; the terminal screenshot remains a later visual target.
See the [transport admission/handoff record](docs/DevVMProvisioningPlan.md#milestone-3-transport-resource-admission-and-private-handoff--3-november-2026).


## dev-vm milestone 3 completion — 3 November 2026

**DESIGN DECISION:** milestone 3 is complete within fake/local acceptance. One
manager-owned service coordinates strict workflow/child journals, SSH wait/review,
admitted helper activation, original exit observation, matching-exit restart and
fresh explicit rebind/check review. Duplicate/concurrent acceptance cannot replay.
Corruption or uncertain ownership preserves risk and blocks normal VM lifecycle.
App composition installs the service with execution disabled and performs no host
tool probes, helper launch or VM operation. The packaged helper still has no
operational runner factory; terminal/input transport is milestone 4 and UI/CLI is 5.

**DESIGN DECISION:** a full manager process restart loses its private helper and VM
ownership capabilities. Journal rows, saved PIDs, locks or diagnostic markers cannot
recreate them. Interrupted jobs retain cleanup-required holds; no automatic worker
adoption, execution replay, source import or restart occurs. Explicit cleanup after
service/coordinator reopen requires original authenticated stopped-and-fenced proof,
current manager-owned session authority and re-supplied original resource proofs.
Private/orphan recovery files are retained; bounded quotas refuse new work rather
than deleting them. Manual recovery/retention UX remains a later acceptance concern.

**VERIFIED:** `make test` passes 347 Swift test functions in 48 suites, 49 script tests, and relocated/read-only ad-hoc-signed helper fixtures. The final `make test-provisioning-tools` run passes 141 functions in 13 suites after the last cancellation/recovery guard changes. Package/export validation and companion/vendor source/engine matching pass. See the
[completion record](docs/DevVMProvisioningPlan.md#milestone-3-completion--3-november-2026)
for exact checks and limits. Separate processes exercise owner loss during fake work
and a fresh manager's refusal to invent ownership; surviving-capability recovery,
local runner construction/output, lifecycle, durable failure and retention use
fake runtimes/local fixtures. No real transports, authentication UI, host installs,
VMs, permission grants or installed-app changes are exercised.

**PRIVATE COUPLING:** original manager session/root/managed-SSH ownership and pinned
helper/resource inventories remain required. This is orchestration above the shared
package, not a duplicate VM implementation.

**TO PROVE:** live terminal/input/rendering, operational UI/CLI, genuine guest
identity/authentication/echo, restart/check and remote cleanup after failure,
positive recovery after full process loss, host sleep/wake/crash/power-loss/kernel
behavior and release signatures. Real guest evidence and all prior TO PROVE labels
remain unchanged. The Setup screenshot remains a later visual target.


## dev-vm milestone 4 completion — 3 November 2026

**DESIGN DECISION:** one dedicated anonymous inherited terminal socket, separately
MACed from control and manager authority, carries bounded byte frames and viewer
operations for the original admitted helper/job. Viewers start read-only; one
explicit input owner controls the reviewed scope and PTY size. Tokens bind viewer,
invocation and sequence. Detach, expiry, stream loss, completion/cancellation/fence
and observed output gaps revoke input; pending keystrokes are discarded. No raw
terminal/input is journaled or logged. Slow viewers never block process draining or
control cleanup. Missing output requires a visible reset/jump to the live tail and
fresh deliberate input claim, never invented screen reconstruction or disk replay.

**VERIFIED:** `make test` passes 362 Swift functions in 49 suites, 49 script tests
and the signed local helper fixtures. The final shared package checks pass 72 Swift
functions, 18 parser oracle fixtures and 66 planning/error oracle fixtures; package
export verification, companion/vendor matching and both diff checks pass.
See the [milestone 4 completion record](docs/DevVMProvisioningPlan.md#milestone-4-completion--3-november-2026).
Tests use synthetic inputs, fake runtimes/transports, disposable local PTYs/processes
and excluded ad-hoc-signed debug helpers. Scoped local TTY restoration covers normal,
error and cooperative-cancellation exits, allowing Darwin's transient PENDIN bit.
No real transports, installs, downloads, VM or user UI operations are performed.

**PRIVATE COUPLING:** bootstrap 6 / terminal protocol 1 / inherited fd 7 are private
manager/helper interfaces pinned to the existing admitted registration and original
session/resource authority. Shared scope reservation grants no typing permission;
an explicit live attachment is required. Public product execution stays disabled.

**TO PROVE:** native emulator/rendering/host-action escape policy, Setup UI and
external CLI attachment are milestone 5. Actual nested SSH, guest password prompts,
resize, remote cleanup/restart/check, sleep/wake/crash and real signatures retain
their separate acceptance gates. No positive recovery after full process loss or
TTY restoration after hard process termination is claimed. The Setup screenshot
remains the visual target for milestone 5.

### 3 November 2026 — provisioning milestone 5 terminal/observation slice

- **DESIGN DECISION:** Setup and the separate setup CLI share one manager-owned
  observation/cancellation/attachment service. Offline preset/folder previews use
  the pinned planner. Attachments start view-only; deliberate input ownership,
  typed invocation metadata, bounded transient input and gap/reset handling apply.
  Existing VM command JSON contracts and production execution gates remain intact.
- **PRIVATE COUPLING:** library-only SwiftTerm 1.99.0 at
  `2dad6a1e516f755bed77cf9bbd09455062f54758` requires Swift 6.2+ (tested with 6.4),
  with one reviewed grapheme-length guard, two integration files and inventory.
  The scoped display filter blocks host-action escapes before native/CLI rendering;
  protocol-1 `setup-v1.sock` uses private same-user Unix-socket admission and never
  exports helper capabilities. Terminal content/input is never journaled/logged.
- **VERIFIED:** `make test` passed 376 manager Swift test functions in 50 suites, 52 script tests, and the relocated/read-only/ad-hoc-signed helper fixtures (including original owner-loss/reopen and terminal streaming). The focused UI/CLI coverage contains 13 functions plus the four-case bundled-preset test: split Unicode/ANSI, cursor/colour/CR rendering, blocked host actions, oversized/malformed streams, storage bounds across cursor/style changes, native viewer ownership/search/reset, strict correlated protocol refusal, cross-view input ownership, EOF/gap/reclaim, distinct cancellation and disposable PTY termios/signal/open-file-flag restoration on detach, connection loss and task cancellation. Vendor inventory, the reviewed two-line source patch, exact upstream export comparison, unchanged shared-package export checks and `git diff --check` passed. No user window was opened or real transport executed.
- **TO PROVE:** full milestone-5 creation/selection, frozen preview/apply and explicit
  hash-bound task trust, restart/check/recovery execution actions, complete visual
  acceptance, nested guest/SSH authentication and cleanup, hard-kill TTY recovery,
  and distribution. This is an uninstalled worktree build. No real transports,
  host installs, factory downloads, VM operations or user UI takeover occurred.

### 3 November 2026 — milestone 5 frozen review and explicit task trust

- **DESIGN DECISION:** manager-owned Preview freezes selected inputs into a fresh
  private UUID tree, replans and verifies hashes, then binds an explicit target
  review/consent to that snapshot. Later source edits do not alter it. UI and CLI
  share capture/lookup, explicit task-source inspection, prepare/apply and status.
  Task trust has its own digest over the exact review, all frozen inputs and
  selected tasks; general Apply, sudo and Docker consent do not imply it.
  Submission repeats package, original resource/session and fresh dependency
  checks before existing helper admission, with one owned operation per UUID and
  no automatic mutation retry. Source bytes are returned only on a deliberate
  task-source read; no terminal/input/archive/credential enters normal status.
- **PRIVATE COUPLING:** additive review operations on setup protocol 1, bounded
  previews/task chunks and memory-only review/consent handles. Existing strict
  workflow/helper journals govern prepared jobs; retained private source trees
  are not executable authority after reopen. Product composition has neither an
  enabled execution gate nor an operational owner/UID/key resolver. Tests inject
  synthetic evidence; the manager never guesses a real guest UID.
- **VERIFIED:** `make test` passed 390 manager Swift test functions in 52 suites, 52 script tests and the relocated/read-only/ad-hoc-signed helper fixture suite (including original-owner loss/reopen and terminal streaming). `make test-provisioning-review` passed 28 functions in three suites: frozen previews, original-source edits, explicit task-source chunking, preview quotas, no authority after reopen, separate task/sudo/Docker consent, exact duplicate submission, changed source/tool/session admission, cancellation during a gated final recheck, stale task trust, strict nested protocol cases and CLI/native service interoperability. Tests call the native service API and actual private CLI socket, without opening the form or claiming visual acceptance. Package/export and both diff checks pass; shared package sources/resources/pins are unchanged.
- **TO PROVE:** native feature editing/New VM coupling, reviewed restart/check/
  recovery surfaces, operational guest identity/runner admission, visual and
  signed distribution acceptance, all real guest/SSH/echo/cleanup/crash/sleep/wake
  behavior. No actual transport, host install, factory download, VM or user UI
  operation occurred. The shared package source/resources/pin are unchanged.

### 3 November 2026 — milestone 5 reviewed workflow actions

- **DESIGN DECISION:** Setup and CLI share preparation/consent for existing workflow
  restart, post-restart check and cleanup recovery. Action UUID/digest binds exact
  workflow/VM/session/job, sequence and input/dependency scope. No acknowledgement
  is inferred from Apply/task trust. Duplicates share one owned operation; failed
  operations require a deliberate fresh review, and action authority is not restored
  from disk. Restart waits for matching `.exited`, check requires the admitted new
  session and excludes custom tasks, and recovery is restricted to original cleanup.
- **PRIVATE COUPLING:** additive strict setup-socket action schemas delegate to the
  existing M3 restart/rebind/recovery paths. Recovery’s lazy adapter constructor
  cannot run before original authenticated worker/checkpoint admission. A new
  process, journal or PID cannot manufacture ownership. Active provisional cleanup
  risk is not a recovery action. Product execution/resolver/recovery factory remain
  disabled; no operational runner is installed.
- **VERIFIED:** `make test` passed 403 manager Swift test functions in 54 suites, 52 script tests and the relocated/read-only/ad-hoc-signed helper fixtures, including original-owner loss/reopen and terminal streaming. `make test-provisioning-actions` passed 13 functions in two suites (including ten malformed-wire variants and three final-check admission/cancellation variants). Fake fixtures cover explicit consent, shared CLI/native action lookup, duplicate restart/check, diagnostic-vs-exit boundaries, fresh-session frozen checks with custom tasks excluded and no authorization input, active-risk recovery refusal, lazy factory ordering, missing original capability after reopen, source-free cleanup, failed revocation/retained holds, stale sibling recovery reviews, failed-operation non-replay and lost in-memory consent. Product endpoint tests prove disabled refusal before probes/factories. UI controls compile; complete interactive/visual acceptance was not performed. Package/export checks and both diff checks pass. Shared package sources/resources/pins are unchanged.
- **TO PROVE:** native feature editing/New VM handoff, operational identity/factories,
  complete visual interaction, actual guest/SSH/echo/revocation/restart/check,
  crash/sleep/wake and signed distribution. This slice uses only fake runtimes,
  fake adapters and disposable private UUID fixtures. No real transport, host
  install, factory download, VM or user UI operation occurred. Shared sources,
  resources and pins are unchanged.


## Native feature choices and New VM setup selection — 3 November 2026

- **DESIGN DECISION:** Setup and New VM expose typed Use source/Enable/Disable
  choices for common built-ins; advanced settings remain source-owned and shared
  planning resolves dependencies/conflicts. Native edits derive a private generated
  manifest from frozen bytes, preserve the original manifest/mode and bind all
  selected bytes into new hashes. No selected source file is overwritten.
- **DESIGN DECISION:** New VM saves a separately acknowledged frozen selection,
  while resource/factory/SSH/owner/sharing fields come from manager creation
  arguments. Saving is metadata only and grants no Apply, task trust or sudo
  authority. Duplicate consent plus identical creation arguments returns the
  original UUID without mutation/launch; uncertain saves retain their reservation.
- **PRIVATE COUPLING:** strict setup-socket creation prepare/lookup and guest
  creation consent share the native service. Registry schema 6 stores a validated,
  immutable non-secret receipt. Preview binding requires its matching saved VM;
  reopening retains metadata lookup only and cannot recreate execution consent.
  Older registry versions still load; older builds reject schema 6.
- **VERIFIED:** `make test` passed 419 manager Swift functions in 55 suites, 52
  script tests and relocated/read-only/ad-hoc-signed helper fixtures. Focused
  local selection tests pass 16 functions in one suite,
  including frozen bytes/modes, typed protocol refusal, shared dependency resolution,
  resource/factory precedence, duplicate and uncertain saves, port admission and
  inert reopen. Full-suite evidence is recorded in the
  [milestone-5 handoff record](docs/DevVMProvisioningPlan.md#milestone-5-native-features-and-new-vm-handoff--3-november-2026).
- **TO PROVE:** full native visual/interaction acceptance, operational guest
  owner/UID/key evidence and runner factories, real guest/SSH/echo/cleanup/restart/
  check/crash/sleep/wake and signed distribution. Execution/resolver/recovery
  construction remain disabled. No host install, real transport, factory download,
  VM or user UI operation occurred. Shared sources/resources/pins are unchanged.

## Authenticated provisioning identity and dormant runtime composition — 3 November 2026

- **DESIGN DECISION:** retain the UID/owner from the existing authenticated managed
  SSH probe, bound to its exact VM/session, UUID-root inode/device, port, host key,
  public metadata hashes and stat-pinned client identity. A strict bounded parser
  refuses malformed replies. Readiness-only state, guest status, manifests and
  saved receipts cannot supply provisioning identity. Evidence is memory-only,
  redacted and fresh for at most 45 monotonic seconds.
- **PRIVATE COUPLING:** the pinned guest `managed-ssh-identity` command supplies
  exactly VM/session/user/UID, as confirmed by source inspection. Successful
  30-second refreshes preserve readiness; failures and identity changes invalidate
  authority. Retry/pause/shutdown/exit clear evidence and fence late callbacks.
  Host transport admission/revalidation require current authenticated evidence.
- **DESIGN DECISION:** product composition now supplies inert identity/recovery
  constructors. A single fixed-false build-time gate keeps manager execution and
  helper runner selection disabled. Dormant worker construction reuses package/
  engine/resource/launcher admission and original session/invocation fencing.
  Recovery construction remains behind original-helper proof and cleanup-only
  scope; it rechecks transport and manager authority. A new runner proves no prior
  worker exit and grants no task, sudo or user-input authority.
- **VERIFIED:** `make test` passes 428 manager Swift functions in 56 suites, 52
  script tests and relocated/read-only/ad-hoc-signed helper fixtures. Focused
  fake/local identity/backend validation passes 43 functions
  across nine suites, including the normal monitor with fake SSH execution and
  fixture sleeps. Source inspection confirms the four-field guest identity format.
  The [implementation/evidence record](docs/DevVMProvisioningPlan.md#milestone-6-preparation-authenticated-identity-and-dormant-backends--3-november-2026)
  records final full-suite and offscreen component checks. Actual controls and
  correctly oriented Unicode/ANSI terminal rendering were inspected in a labelled
  synthetic PNG, without AppModel/registry access or a visible window. This does
  not establish whole-screen interaction or real prompt/echo acceptance.
- **TO PROVE:** real owner/UID/key authenticity, guest/nested SSH/TTY behavior,
  remote cleanup, end-to-end setup/reapplication/restart/check, crash/sleep/wake,
  whole-screen interactive acceptance and signed distribution. No product execution
  was enabled, real transport/VM operation performed, host tools installed,
  factory downloaded, personal credential accessed or user desktop taken over.
  Shared package sources/resources/export and engine pins remain unchanged.

## Full Setup/New VM fake acceptance and disposable-guest runbook — 3 November 2026

- **VERIFIED:** 56 isolated checks exercise actual New VM/selection/manager Setup
  views and shared actions: review/acknowledgment, edits/races/refusal, explicit
  resource/factory precedence, frozen handoff/duplicate creation, complete task
  inspection, independent apply consent, terminal search/expand and cancellation.
  Eight full-screen light/dark/scrolled PNGs were inspected. The DEBUG harness
  runs before normal model/registry construction with in-memory fake services and
  a never-started FakeRuntime. Nonactivating backing windows lie outside every
  display; no OS input or desktop capture is used. The temporary support root
  remains absent. [Evidence and limits](docs/DevVMUIAcceptance.md) are recorded.
- **VERIFIED:** `make test` passes 428 Swift functions in 56 suites, 52 script tests,
  relocated/read-only/ad-hoc-signed helper fixtures and the 56 screen checks.
  The final screen target and package/export verification pass. Release compilation
  passes without signing credentials; fixture entry point/markers are absent from
  the release binary. This is compile evidence, not signed-distribution acceptance.
- **DESIGN DECISION:** button/action guards are shared, including required-task
  inspection. Loaded frozen input is explained independently of the source picker.
  Fixture state is injected locally in DEBUG, never selected through a real
  execution override. Product execution and shared package/resource/export/engine
  pins remain unchanged.
- **TO PROVE:** physical input, focus/VoiceOver, native file/task/confirmation
  dialogs and real guest/SSH/Ansible/TTY/cleanup/restart/check/crash/sleep/wake.
  The [milestone-6 runbook](docs/DevVMMilestone6Runbook.md) is prepared, not run.
  It requires a scoped, separately reviewed operational candidate and explicit
  disposable-guest consent before execution. No real transport, host installation,
  VM launch/change, factory download, personal credential or desktop takeover
  occurred. Milestone 6 real acceptance and milestone 7 distribution remain open.

## Milestone 6 disposable admission — 3 November 2026

- **DESIGN DECISION:** ordinary product approval is `nil` and execution stays false.
  A future private candidate may embed only the original explicitly reviewed
  disposable UUID/root/device/inode/ownership-marker pins in both manager/helper.
  There is no separate Boolean bypass or approval loader from CLI, environment,
  manifest, registry, journal, readiness or IPC. Internal fixture injection remains
  trusted test composition. An ownership marker does not itself mean disposable.
- **DESIGN DECISION:** hold root descriptors; recheck private ownership/mode,
  canonical namespace, device/inode and strict markers. Reject retained POC IDs,
  replaced roots, arbitrary symlinks and unlisted UUIDs. The manager also checks
  its profile/session root at preparation, transport, leases, cleanup and both
  sides of restart. A compiled candidate's initial start and coordinator-close
  paths retain scope. The helper independently checks before runner construction
  and before/after reverse RPC for every command/invocation. Input claim/send/resize
  failure releases ownership; output remains viewable. Recovery never bypasses
  approval or original-worker quiescence/session/provenance/cleanup requirements.
- **VERIFIED:** 12 fake/local admission test functions cover admitted work,
  unlisted/foreign/same-UUID roots, invalid/stale pins, marker/mode/symlink changes,
  independent manager/helper refusals, RPC races, restart/replacement, recovery
  construction/commands and terminal ownership. See the
  [implementation record](docs/DevVMProvisioningPlan.md#milestone-6-disposable-admission-foundation--3-november-2026)
  and updated [runbook](docs/DevVMMilestone6Runbook.md). Full `make test` passes
  440 Swift functions in 57 suites, 52 script tests, signed local helper fixtures
  and 56 isolated screen checks. The final focused admission target, release
  compilation without signing credentials, package/export and diff checks pass.
- **TO PROVE:** approval of concrete newly prepared disposable roots and a real
  signed operational candidate, then guest/SSH/Ansible/TTY/apply/cleanup/restart/
  check/crash/sleep/wake and milestone-7 distribution. No actual approval values,
  host installs, VM launches/changes, factory downloads, real transport, personal
  credentials or desktop takeover occur in this slice. Shared package/resources/
  export/engine pins remain unchanged.

## Separate setup Source and multiple profile cards — 3 November 2026

- **DESIGN DECISION:** native Source selects bundled configuration or a local
  `vm.yml` folder; profile cards select one or more bundled profiles. Local declared
  profiles/settings/tasks stay included and cards add profiles. Individual feature
  overrides are hidden in the native UI. Colored native badges and summaries come
  from the shared resolver's expected inclusions, not observed guest contents.
- **PRIVATE COUPLING:** optional bundled/profile source fields use the same strict
  local protocol and generated frozen-manifest projection. Legacy CLI presets stay
  compatible. Bounded unique builtin additions preserve source bytes and deduplicate
  aliases; shared merge/dependency/conflict rules remain authoritative. Conflicts
  are refused until explicitly resolved; review acknowledgment is invalidated on
  profile edits. No package/engine/runtime source is duplicated or ported here.
- **VERIFIED:** 24 focused selection functions (eight new profile tests), 448 Swift
  functions in 58 suites, 52 script tests, local signed helper fixtures and 62
  isolated UI checks pass. Eight light/dark/scrolled PNGs were inspected. Release
  compilation without real signing credentials, package/export and diff checks
  pass. [UI evidence](docs/DevVMUIAcceptance.md#separate-source-and-multiple-profiles--3-november-2026)
  records current captures and limits.
- **TO PROVE:** physical UI/focus/VoiceOver/native dialogs and real candidate/guest/
  SSH/Ansible/TTY/cleanup/restart/check/crash/sleep/wake/distribution. Product approval
  stays nil and execution disabled; no host install, factory download, real VM or
  transport operation occurred. Shared package/resources/export/engine pins are
  unchanged. Local custom profiles stay manifest-defined, outside the bundled card
  catalogue; their task trust and all execution consent remain independent.

## Conditional optional-app trimming — 3 November 2026

- **DESIGN DECISION:** expose Trim optional apps only for the official Try Omarchy
  factory, initially off. The tooltip describes its broad bundled apps and a more
  sensible base. Guest setup changes the VM, not reusable factory bytes. Trim and
  factory edits invalidate review; unsupported provenance resets/hides the choice.
  Native on/off explicitly overrides local manifest trimming; legacy absent
  overrides preserve the existing `vm.lean_developer` setting.
- **PRIVATE COUPLING:** freeze the Boolean in the private selection manifest and
  enforce actual official identity at creation reservation/workflow preparation.
  The shared planner lists candidate removals, excluding selected software. Reuse
  the upstream guest helper/allowlist through the supervised, streamed apply path;
  check never trims. The optional-app-trim integration patch updates the pinned
  source/resources/tests and compiled admission identity. No host Python is added.
- **TO PROVE:** real guest trim/dependency closures/reapply and live terminal under
  an explicitly approved disposable candidate. Product approval remains nil and
  execution disabled. No host installation, image change/download or VM launch.
- **VERIFIED:** 28 focused manager selection functions, 452 manager Swift functions
  in 59 suites, 52 script tests, final seven package functions/six package scripts
  and signed local helper fixtures pass. Final shared tests pass 77 functions;
  twelve upstream helper tests use mocked subprocess replies. Final screen checks
  pass 74 checks with twelve synthetic PNGs; four new scrolled trim images were
  inspected. Release compilation, immutable patch verification and diff checks pass.
- **VERIFICATION EXCEPTION:** the companion broad test target invoked installed
  Ansible against temporary local inventories and fake helper files before its
  full scope was inspected. This exceeded the no-real-Ansible instruction; it
  contacted no guest and installed no host tools. The run failed (10 failures,
  44 errors, one skip/235 tests), so it is not acceptance evidence. Subsequent trim
  tests use fake runners/mocked helpers. Exact checks, limits and this exception
  are recorded in the [implementation plan](docs/DevVMProvisioningPlan.md#optional-app-trim-selection--3-november-2026).

## Theme and layout selection — 3 November 2026

- **DESIGN DECISION:** native New VM/Setup use an initially collapsed Theme & layout
  section for a GitHub repository URL, random/most-starred and keep/select/remove
  for a Lua layout. Blank preserves source/current choices. Random uses ten stars
  by default; zero skips ranking. Star-based choices require existing authenticated
  gh; no install/sign-in flow is initiated. Theme/layout edits invalidate review.
- **PRIVATE COUPLING:** shared Swift selector/resolver with injected HTTP/star
  providers owns strict roots, catalogue figures, thresholds/ranking and final GET
  acceptance. The manager uses bounded credential-free ephemeral GETs and the
  existing bounded read-only gh runner. It resolves once during review and freezes
  the concrete URL. GET accessibility establishes neither theme validity nor a Git
  content pin. Selected regular UTF-8 layout bytes (at most 256 KiB) are captured
  without following symlinks or executing Lua, copied into private reviewed inputs
  and hashed. Original files/settings remain unchanged. Existing snapshot/Ansible/
  native Omarchy paths own apply; workstation disable is refused. CLI/socket review
  APIs share strict appearance selections. No new lifecycle owner or host Python.
- **PRIVATE COUPLING:** the theme-selection export patch and lock/engine/snapshot
  pins include the shared implementation and fake tests. Product approval stays nil
  and execution disabled; creation/review never authorizes setup or custom tasks.
- **VERIFIED:** full manager make test passes 463 Swift functions in 61 suites,
  52 script tests, local signed helper fixtures and 82 offscreen checks. Eleven
  focused appearance functions, 84 shared Swift functions, eighteen selected
  upstream mocked/controller or disposable stub-shell fixtures, syntax checks,
  release compilation, reverse export and diff checks pass. Four new light/dark
  captures were inspected; [evidence and limits](docs/DevVMProvisioningPlan.md#theme-and-layout-selection--3-november-2026)
  are recorded. No real HTTP/gh/SSH/Ansible, host install, factory operation or VM
  launch occurs in this slice. The broad companion Ansible target is skipped to
  honor the user's explicit fake/local constraint.
- **TO PROVE:** live catalogue/authentication/rate limits and theme contents,
  native dialogs/hover/focus/physical input, actual guest apply/reapply/check/layout
  login behavior, cleanup and distribution under explicit disposable approval.

## Bundled dev-vm layout example cards — 3 November 2026

- **DESIGN DECISION:** Desktop layout → Examples offers the four upstream example
  layouts as single-select wireframe cards, with split proportions/browser overlap,
  descriptions and prerequisite apps. The gallery uses full width and adapts to
  four or two columns in the tested forms. Keep/Custom file/Remove remain. Choosing
  a card freezes its original Lua; it does not implicitly add app installs or
  authorize execution. Wireframes illustrate intended floating placement, not
  observed guest state. Applications must be available separately at guest login.
- **PRIVATE COUPLING:** shared catalogue/API binds four fixed IDs, metadata and
  source hashes to bundled copies of the unchanged original Lua. A strict optional
  appearance field is mutually exclusive with custom-file/removal choices. Native,
  CLI and socket paths share it; the existing frozen-input/private-manifest/shared
  planner/transport path owns application. Preview naming uses the actual frozen
  source hash. A new integration patch updates engine/resource/snapshot/lock pins;
  product approval remains nil and execution disabled.
- **VERIFIED:** full manager tests pass 468 Swift functions in 62 suites, 52 scripts,
  signed local helper fixtures and 100 isolated screen checks. Shared tests pass 86
  functions. Original and bundled sources/catalogue match byte-for-byte; resource
  sync syntax parsing and reverse export/diff checks pass. Four new light/dark
  captures were inspected; [checks and limits](docs/DevVMProvisioningPlan.md#bundled-dev-vm-layout-example-cards--3-november-2026)
  are recorded. No actual Lua/HTTP/gh/SSH/Ansible, host install, factory operation or
  VM launch occurs in these checks. The broad Ansible target remains skipped.
- **TO PROVE:** physical card interaction/VoiceOver and actual guest app availability,
  startup, placement, manual resizing, reapplication and next-login behavior under
  explicit disposable approval. Historical dev-vm captures are separate evidence.

## Offline provisioning candidate preflight — 3 November 2026

- **DESIGN DECISION:** an offline build evidence report cannot enable execution or
  approve a disposable scope. The existing product approval remains nil. Build
  hashes and source status are observations, not signed/loaded-code admission or
  proof that binaries were built from HEAD. New stopped disposable root preparation
  and an actual guest run still require their concrete explicit approvals.
- **PRIVATE COUPLING:** `make provisioning-preflight` reuses the pinned export,
  generated source pin and resource inventory, records existing binary hashes and
  optionally checks an assembled provisioning seal/runtime-lock copy. Read-only
  export validation creates only its temporary reverse-patch copy, never build
  inputs. The tool reads no user guest/registry/factory-image or credentials and
  invokes no candidate or signing/dependency/transport tools. It is repository
  development tooling, not a product Python runtime.
- **VERIFIED — offline/local:** ten static checks and all 61 script tests pass,
  including nine new tamper/replacement/read-only regression fixtures. The previous
  Swift/shared/UI results remain scoped to their recorded source. See the
  [runbook](docs/DevVMMilestone6Runbook.md#offline-candidate-preflight).
- **TO PROVE:** approved original root identities and operational candidate,
  signatures/loaded code, fresh real factory/tool admission and all guest rows.

## Private scoped provisioning candidate — 3 November 2026

- **DESIGN DECISION:** the approved stopped disposable profile/root and its original
  pins can identify a private candidate without authorizing launch or provisioning.
  Main source remains nil/disabled. Private source overlay and actual identifiers
  stay outside version control; constants cannot be supplied by a file, environment,
  CLI, manifest or IPC. Invalid original scope fails closed rather than falling
  back to ordinary composition. Production helper-signing policy is unchanged.
- **PRIVATE COUPLING:** a private six-file overlay over commit `1cb2bdd` installs the
  original scope in both manager/helper and a read-only inspection path before
  AppModel/registry/worker dispatch. Existing make/SwiftPM, exact kit resources and
  packaging are retained. No virtualization implementation or shared source changes.
- **VERIFIED — offline/local:** thirteen artifact checks, actual packaged component
  reports before/after relocation, fake-runtime refusal probes with zero starts,
  and twelve ordinary admission tests pass. Kit archive/inventory and signatures
  match; local app signatures verify. Only ad-hoc signing is used. Root, metadata
  and full registry are unchanged. Production same-team signing correctly refuses
  the candidate; no fixture policy replaces it. See the
  [runbook](docs/DevVMMilestone6Runbook.md#private-scoped-candidate-preparation).
- **TO PROVE:** authorized signing/loaded-child admission, separately approved SSH/
  owner configuration, existing factory/tool readiness, exact inputs/consents and
  all real guest acceptance. No launch, real SSH/Ansible, install, credential use,
  normal UI or worker body occurred. Real acceptance remains NOT_RUN.

## Offline candidate signing/readiness audit — 3 November 2026

- **VERIFIED — static/local:** nineteen checks confirm unchanged candidate/evidence,
  exact inventories/signatures, source archive/overlay and original root/registry.
  Static Ansible metadata is Core 2.21.5 in the expected family, with no CLI execution
  or readiness claim. Factory metadata is present but bytes are access-denied and
  checksum NOT_VERIFIED. No permission grant, image/disk creation, credential, host
  install, normal UI, workflow, signing, network or real transport/guest operation.
- **PRIVATE COUPLING / SOURCE INFERENCE:** supported promotion rebuilds signed
  runtime/profile/pin composition while retaining original scope. Existing tag CI
  checks out ordinary source and publishes archives; it is unsuitable unchanged for
  this ignored private candidate. A private nonpublishing handoff and final original-
  Mac scope validation must precede later authorized signing. No such route is run
  or implemented here; detailed artifacts and pins remain outside Git.
- **TO PROVE:** seven signing/readiness gates, including fresh CLI checks, approved
  SSH/owner/input configuration, verified factory bytes and actual loaded-child/
  guest behavior. Product approval remains nil and guest rows remain NOT_RUN. See
  the [audit record](docs/DevVMMilestone6Runbook.md#offline-signing-and-readiness-audit).

## Private signing/packaging handoff — fake/local, 3 November 2026

- **DESIGN DECISION:** private build-input bindings and a frozen signing request
  confer no guest/signing consent. CLI preparation never reads the target VM root,
  recaptures original pins, runs a signer or accesses credentials. Ordinary product
  approval stays nil. Real requests cannot enter the synthetic signing runner;
  production signature requirements and public release automation are unchanged.
- **PRIVATE COUPLING:** existing runtime-origin/payload, profile-entitlement and
  provisioning seal validators enforce fake profile/rebuild/child-sign/seal/outer-
  sign/verify/archive ordering. Both component receipts/code bodies retain the same
  scope. Private fresh outputs, immutable input digests, tag/release/VM namespace
  guards, archive checks and private failure retention prevent overwrite/replay or
  publishing. Build tooling remains separate from the shipped Swift controller.
- **VERIFIED — local fixtures:** eighteen new functions/22 rejection variants and
  all 79 script tests pass. The actual candidate yields a private 101-file request;
  synthetic ZIP roundtrip evidence records no process, network or credential call.
  Real request simulation is refused. Original candidate/root/registry are unchanged;
  detailed artifacts and pins stay ignored. See the
  [handoff](docs/DevVMMilestone6Runbook.md#private-signing-and-packaging-handoff--fakelocal-path).
- **TO PROVE:** authorized real signer/compilation, cryptographic/profile/loaded-child
  validation and original-Mac scope evidence; prior factory/tool/account and all
  guest gates remain pending. No real signing, installs, SSH/Ansible, workflow,
  credential, UI or VM operation occurs. Guest acceptance remains NOT_RUN.

## Private signer adapter — fake processes, 4 November 2026

- **DESIGN DECISION:** a developer-only adapter connects the frozen private request
  to existing signed-prerelease build/SDK commands. The system runner refuses by
  default before material IO; trusted in-memory authorization binds request, scope,
  material and allowed effects. No signing CLI, credential import/unlock/search,
  runtime download, notary submission or publication path is added. Secure
  timestamps require signing approval. Product approval remains nil.
- **PRIVATE COUPLING:** reconstruct the exact archive/overlay, preserve original
  scope/operational composition, project signed pins and inspector branch, use
  clean pinned local dependencies, and retain child-sign/seal/outer-sign order.
  Existing origin/payload/profile/seal policies plus SDK team/authority/hardened/
  timestamp/certificate checks and read-only archive roundtrip gate success.
- **VERIFIED — fake/local:** twelve new test functions, 33 command/signature failure
  cases and four runtime variants; all 91 script tests pass. Injected fake processes
  and mocked system dispatch exercise command/timeout contracts without a real
  child, tool, credential, Apple request, install, UI, disk or guest operation.
  Fixture results explicitly establish no production cryptography or launch
  readiness. Actual handoff/candidate/pins remain private and unchanged. See the
  [runbook](docs/DevVMMilestone6Runbook.md#private-signer-adapter--fake-process-runners-4-november-2026).
- **TO PROVE:** authorized local runtime/materials and actual compiler/SwiftPM,
  SDK/profile/signature behavior, notarization, final original-Mac scope and loaded
  child admission. Factory/tool/SSH/owner and all guest rows remain pending/NOT_RUN.

## Real signed-candidate gate preparation — 4 November 2026

- **DESIGN DECISION:** a private review-only packet binds the retained candidate,
  request/original scope/source and committed adapter, exact runtime/profile
  requirements and unresolved material selectors. Every approval is NOT_GRANTED;
  no file/env input becomes execution authority. Named material inspection,
  optional upstream runtime preparation, app build/key use/secure timestamps,
  original-Mac/loaded-child checks, notarization and guest acceptance are distinct.
- **VERIFIED — read-only local:** candidate inventory/reviewed digest and frozen
  request match; canonical client/parser checkouts are clean at the archived pins.
  Local Git uses no fetch/hooks/fsmonitor or optional index writes. No root/registry
  observation, pin recapture, SDK/signing command, credential access, Apple/network,
  SSH/Ansible, install, UI, disk or guest operation. Adapter/shared/product source
  and its 91-test evidence remain unchanged; actual pins and packet stay private.
- **PRIVATE COUPLING:** runtime consumption needs the signed variant of the exact
  frozen development kit, sharing the selected app team and immutable origin/
  payload. A missing runtime needs separate upstream preparation; its signer lacks
  an explicit keychain selector. The ordinary release wrapper couples credentials,
  notarization and publication and must not be used unchanged for this gate.
- **TO PROVE:** no real runtime/team/identity/keychain/profile path is selected or
  inspected. Real material binding/trusted caller, compiler/SDK/profile/signature,
  notarization/original-Mac/loaded-child and all guest rows remain unproven. See the
  [gate](docs/DevVMMilestone6Runbook.md#real-signed-candidate-gate-preparation--4-november-2026).
