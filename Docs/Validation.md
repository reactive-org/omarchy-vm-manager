# Phase 0 / Phase 0A validation

Recorded 31 October 2026 (Australia/Melbourne). No real VM was launched and no factory image was downloaded. Only the stock kit, checksum and manifest release assets were fetched. Tests use temporary protocol stubs and small synthetic data.

## Host

Apple Silicon MacBook Pro (Mac17,7, Apple M5 Max), macOS 27.0.1 (26A434), 128 GB RAM, 18 CPU cores and approximately 1.1 TiB free at initial inspection. Xcode 27.0 (27A266a), Swift 6.4. The sandbox refused `sysctl` queries; read-only hardware inspection supplied memory/core information, and the assembled app's preflight passed outside the sandbox. No machine settings or permission grants were changed.

## Exact provenance

- Vendor submodule: stock `v1.3.0`, commit `13d63df8da2947f833c04025ff5ade187d39ba81`, clean checkout.
- Stock kit SHA-256: `3ad65381b34ced2ebe3f5f19b95d58ec1a2c51a77a6edf7599666a939b6991a6`.
- Local clipboard patch commit: `a135f003c2ffd2ce820900b5896b7ad9e2b84a96`.
- Patch SHA-256: `0c6ca8e97cbf81393ff00c6789eb415a79452027f21e7cabfc6ad2a1631eff18`.
- Private kit SHA-256: `24d569ea2ee06e4f8fd435ea215483db4b968720e509f194ad8d2913a8f44d6e`.
- Manifest: `development`, format 1, run protocol 1, build date `2026-10-31T00:28:33Z`.
- Runtime-lock SHA-256 compiled into the app: `4d89684e7a46d3a3cc2e68a2bb05746a65dd247c522104c23bf5e0698914edae`.

The helper and networking are source-built from the exact patch commit. QEMU, firmware, guest package and factory download metadata come from the verified stock kit. Upstream's `macos/build-kit.sh` derives and signs the complete result; upstream `make test-kit` verifies it. This intentionally uses the lower-level upstream kit pipeline rather than `make kit`, because the latter depends on `make guest` and a factory image build. No guest stand-in is shipped and no image is present in the app.

## Results

| Command/check | Result |
| --- | --- |
| `make fetch-kit` | PASS: committed digest, sidecar, manifest, exact extracted payload and stock signature verified; only the three small assets |
| `make patched-kit` | PASS: exact patch commit reconstructed, patched Swift tests passed, release helper built, complete kit signed ad hoc |
| Upstream `make test-kit` | PASS: 22 Mach-O signatures/entitlements, archive digest/content, manifest, no bundle identity, network pins, launcher inspection, QEMU `--version` and helper refusal cases; starts no VM |
| `make test-upstream` | PASS: 523 Swift tests in 99 suites plus the full upstream contract, guest-package contract and shell fixture suites |
| `make test` | PASS: 26 manager Swift tests and 9 Python artifact-contract tests |
| `make app` | PASS: debug manager/storage helper, exact embedded kit, upstream signing order, outer app signed last |
| `make verify-app` | PASS: outer/nested signatures, 24 Mach-O images compatible with macOS 15.0, compiled runtime pin and every kit file, host preflight, app layout, no image and no registered networking job |
| Manager window | PASS: opened only the manager, inspected its real accessibility tree and screenshots, checked disabled Start actions, both profiles, diagnostics, refresh, scrolling and wrapping |

The focus suites include all five original clipboard tests and five added focus-routing tests. Manager tests cover ordered synchronous callbacks, stale sessions, independent states, handle ownership through error, release after exit, duplicate commands, shutdown/force-stop intent, quit with zero/one/two sessions, missing/damaged/incompatible kits, compiled lock tampering, source-pin contracts and stock clipboard refusal. Real client integration tests run two concurrent executable protocol stubs, graceful commands, malformed/unknown events, helper exit, termination and bounded stderr.

Initial sandboxed upstream tests could not bind local sockets or register macOS notification observers. They passed when rerun outside the sandbox. The initial full suite also encountered the default Python 3.9; scripts now select the installed modern interpreter. The upstream Makefile breaks in paths with spaces, so the exact source is reconstructed under `/private/tmp` for its `make` targets. The native UI inspector initially timed out; resetting it and selecting the app by bundle identifier succeeded. These were environment/tooling issues; no tests were weakened or skipped.

CI is configured for the manager and exact patched upstream no-VM suites. No remote CI run, PR, signing identity, credential, notarization or permission request was used.

## Original Phase 0/0A evidence boundary

The two-VM run is intentionally unperformed. Real foreground-PID behaviour, clipboard in both directions across two guests, rapid focus changes, independent disks/shutdown, sleep/wake, normal/cancelled/forced app quit and orphan prevention remain TO PROVE. No public multi-VM support claim is made.

The production adapter refuses real launch in this milestone. Before an approved POC, implement the guarded runner and manager-owned root initialization/admission described in Docs/POC.md. Registry persistence, effective-settings/resource/port policies and the storage helper's locked Trash transaction remain later phases. Release builds reject the development kit. Distribution needs an official reviewed focus-aware release or an explicitly designated internal fork, plus user-authorized signing/notarization and the same real acceptance matrix.

## Phase 1 follow-up

These Phase 0/0A results describe the original `a135f003...` artifact. The first real POC found that its headless helper did not pump the main run loop, leaving the AppKit foreground-app cache stale and disabling clipboard transfers. It is superseded by the repaired patch and kit identified in the current runtime lock. See Docs/Phase1-POC.md and Docs/ClipboardPatch.md for the failure, repair and real validation status. The earlier fake-focus test pass was not a real clipboard success.

The completed real POC run subsequently validated basic concurrent clipboard, background receive/publish suppression for each guest, user-initiated sleep/wake, effective Super shortcuts, independent Force Stop, cancelled/normal Quit and manager force-quit cleanup. Final normal Quit recorded both matching `.exited(0)` events and no owned runtime processes; both disks remain intact and unlocked. The full decision gate remains open for intermittent graphical startup failure and the explicitly unverified checks in [the run report](Phase1-POC.md). See [the reduced graphics observation](Phase1-Graphics-Repro.md). No later product phase is accepted by these partial passes.
