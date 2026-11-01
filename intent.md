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
- Embedded guest display, VNC, SPICE, terminal, interactive SSH client UI or file browser. Provisioning guest SSH access and exposing connection details for host tools are in scope.
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

## Unattended defaults — user extension, 31 October 2026

**DESIGN DECISION:** the user requested reusable in-app defaults based on Omarchy's unattended-install guide. The prepared factory image's owner setup will receive an immutable new-profile snapshot, with the reusable password held in Keychain and only a temporary protected provisioning seed supplied to the guest. This explicitly permits a password for unattended owner creation; manager SSH still uses independent key authentication. Existing guests remain unchanged. See `docs/UnattendedDefaults.md` for verified ISO/OEM distinctions, the versioned private coupling and remaining checks.

## JSON guest CLI — user extension, 31 October 2026

**DESIGN DECISION:** add a concise JSON command-line interface for guest CRUD, resource configuration, start/stop/restart and bounded waits for running, stopped or authenticated SSH readiness. Use the existing GUI manager as the single lifecycle/registry owner through a private same-user local command socket; a short-lived CLI must never drop live runtime handles. Configuration edits remain stopped-only and must also respect an externally held runtime lock. New guests inherit saved owner defaults unless explicitly opted out.

Return the usable host SSH endpoint separately from authenticated guest IP information. NAT guests may have the same private guest IP; host connections use the allocated `127.0.0.1` port, managed identity and pinned host key. Do not expose passwords, private-key material or Keychain references in JSON. Reuse the supported kit launch API and existing guarded Trash helper. The CLI does not add arbitrary guest-command execution, public networking or a second VM supervisor. See `docs/CLI.md` for the command contract and validation.

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

**TO PROVE:** the first real Developer ID/notarization run and Gatekeeper checks on GitHub; clean-Mac installation/permissions and all real signed-build guest behavior. Local no-VM tests and optimized compilation do not establish those outcomes.

**VERIFIED / DESIGN DECISION — certificate container compatibility:** the initial signed CI attempt passed both test jobs but macOS rejected PKCS#12 import with a MAC-verification error, before any signing/notarization submission. Add verified OpenSSL decryption and same-identity rewrapping into a compatible temporary encrypted container with a random transfer password. Never skip MAC checks; remove the private temporary PEM immediately and all credentials on exit. Synthetic-certificate tests verify certificate preservation and rejection of a wrong password. The actual configured credential result remains TO PROVE until the next CI attempt.
