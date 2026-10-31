# Route the native clipboard only through the focused QEMU guest

Stock Try Omarchy v1.3.0 runs an independent clipboard bridge per QEMU process. Each polls the same Mac pasteboard, so a second background guest receives host updates and can overwrite copies from the foreground guest.

This patch adds `ClipboardFocusProviding`, with a production adapter that compares the exact target PID against `NSWorkspace.shared.frontmostApplication` and revalidates the captured kernel process identity. No process-name matching, Accessibility grant or run-protocol change is introduced.

`FocusedClipboardRouting` is the bridge's shared test/live state machine. Its poll and guest handlers run on the existing serial state queue. They ignore background sync/clipboard messages, reset echo state on observed focus loss/gain, synchronize the current host selection once on focus gain, and recheck focus immediately before sends and host writes. If a guest clipboard event first detects activation, the host selection wins that transition so a queued background copy cannot replace it. Existing two-second echo suppression remains intact. Payloads are never logged.

The tests use two real routing instances, two fake focus probes and one fake pasteboard. They cover both directions, foreground echoes, background suppression, activation synchronization, rapid switching, focus lost during a read, focus lost immediately before side effects and unavailable focus. Existing single-VM clipboard tests still pass.

The patch is saved as a dedicated reproducible local commit with the exact identity in `Config/TryOmarchyClipboardPatch.json`. It is based on v1.3.0 commit `13d63df8da2947f833c04025ff5ade187d39ba81`; the vendor checkout remains at that baseline. No upstream PR has been published.

Real multi-guest clipboard, Cocoa foreground identity, rapid UI focus transitions and sleep/wake remain TO PROVE. Focus is reconciled by the existing 250 ms poll and at every message/side effect; events during an unobserved loss-and-regain interval have no focus epoch in protocol 1. The exact real-world behaviour must pass the two-VM gate before claiming this fixes the product use case.

## Headless focus-cache repair found by Phase 1

The first real run exposed a flaw missed by the fake-focus tests. The native clipboard helper blocked its main thread on its socket read. A read-only probe reproduced the same context: fresh per-PID active flags tracked A and B, but the workspace's cached foreground application stayed on the original host app. The focus gate consequently refused traffic in both guests. Apple documents the main-run-loop cache policy in the NSRunningApplication SDK header; see also [NSRunningApplication](https://developer.apple.com/documentation/appkit/nsrunningapplication).

The corrected helper initializes the workspace on the main thread, keeps the main run loop in a common mode, and performs the blocking guest-channel read on a worker queue. Every foreground lookup requested by routing executes synchronously on the main thread, with a direct path when already on that thread. Reader completion/errors are delivered back through the run loop. Clipboard routing and its final focus checks stay serialized on the existing state queue. No permission dependency, clipboard logging or protocol change is introduced.

A standalone headless executable compiles the actual run-loop and focus-adapter implementations from the bridge source. It verifies main-queue responsiveness while the reader waits, immediate completion, error propagation and main-thread foreground reads requested from either thread. It also covers matching/mismatching PIDs, unavailable focus and stale identity rejection. This tests the CLI execution context without launching a VM, displaying a window, generating input or reading clipboard contents. The repaired source and binary hashes are generated into the current committed locks; the old POC artifacts are preserved for audit.

The first main-loop repair restored A's clipboard, but B still failed both directions after a service restart, A's shutdown and B's isolated restart. A controlled human focus cycle then separated two read-only headless probes: background-only polling stayed on its initial host app, while main-thread reads tracked B → Mac → B. Keeping an idle main run loop alive was insufficient in this context. The foreground lookup now explicitly crosses to the main queue on every check. Real two-guest clipboard and background suppression still require validation with this updated artifact.

## Phase 2 runtime extension

The combined reproducible patch now also gives explicitly rooted run-mode guests stable bundle identifiers for native Dock/Spaces assignment. It hashes a POSIX-canonical root, including an equivalent canonical parent before initial root creation, and stamps the generated product app. No public client protocol, QEMU binary, guest image or default-root identity is changed. The identity tests include first creation, symbolic aliases, separate roots, generated plist validation and the actual run-mode environment passed to a no-VM launcher stub.

Phase 1 validated the four focused clipboard paths, background suppression and user-initiated sleep/wake with source `9341b7a...`. Phase 2 preserves that clipboard code and adds guest app identity; the changed runtime has no new real-guest acceptance claim. See [Phase 2 validation and remaining checks](Phase2.md).
