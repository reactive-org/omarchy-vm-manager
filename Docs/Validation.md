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

The completed real POC run subsequently validated basic concurrent clipboard, background receive/publish suppression for each guest, user-initiated sleep/wake, effective Super shortcuts, independent Force Stop, cancelled/normal Quit and manager force-quit cleanup. Final normal Quit recorded both matching `.exited(0)` events and no owned runtime processes; both disks remain intact and unlocked. The user accepted Phase 1 as complete on 31 October 2026 with the intermittent graphics startup failure carried forward for investigation, and explicitly requested keeping both disks for now. The explicitly unverified checks in [the run report](Phase1-POC.md) retain that status. See [the reduced graphics observation](Phase1-Graphics-Repro.md).

## Phase 2 follow-up

The persistent native manager now passes 53 Swift and 9 artifact tests. The updated private runtime passes 526 upstream Swift tests plus its broader no-VM suites. App assembly, exact inventories, signatures, compatibility and host preflight pass. Real native UI create/configure/rename/relaunch and a synthetic actual Trash transaction pass, and both retained POC storage trees compare unchanged. See [Phase 2 results and real-guest limitations](Phase2.md). The changed guest app identity has not been validated with a running guest.

## Managed SSH implementation — private build 0.3.0

- `make test`: 66 Swift tests in 12 suites and 9 artifact tests pass. The live-probe test is gated without its explicit container fixture.
- `make -C /private/tmp/omarchy-managed-ssh-source test`: 529 upstream Swift tests in 102 suites, 92 existing guest tests, 6 new managed-SSH guest tests, and the broader run-mode/shell/compatibility/relocation suites pass.
- `python3 Scripts/test_managed_ssh.py --source /private/tmp/omarchy-managed-ssh-source --base-image omarchy-manager-ssh-builder --swift-probe`: two Arch containers pass real key authentication, optional-key login, localhost-only bindings, cross-guest rejection, changed-host-key rejection and production Swift readiness verification.
- `python3 Scripts/test_managed_ssh.py --swift-probe`: the Ubuntu CI container path passes the same checks. Containers are removed afterward.
- `GUEST_BUILDER_IMAGE=omarchy-manager-ssh-builder make patched-kit`: upstream guest-package build, helper build and `test-kit` pass. Exact reconstructed source `06a8843b6aa392d29f2d702d3a6a60bef8388910`, kit SHA-256 `217a628e5299ebd6696092235c4c2555920ff4388bf9651d35898ae1478a6bfd`, guest package `0.1.0-37`, managed SSH capability 1.
- `make app verify-app`: private app 0.3.0 builds, exact inventory/signatures/layout/compatibility/preflight pass. Ad-hoc signing only.
- Native UI: default-on SSH, optional synthetic public-key selection/fingerprint, saved localhost endpoint and stopped-state display pass. Creating the synthetic profile creates no VM root/private key. Removing it removes its staged public key and leaves both retained POCs alone.
- Fresh-root admission regression: real launch exposed Foundation directory-URL and `/tmp` alias differences before any guest storage was created. Existing-ancestor canonicalization now passes file/directory URL forms and rejects unrelated/non-file roots; the full manager suite and app checks pass after the fix.
- Retained POC storage matches `.build/phase2/poc-storage-before.json`: complete entry sets, inodes/devices, modes, sizes, modification/change times and marker/settings digests. Personal Try Omarchy remains untouched.

The user approved two fresh disposable real SSH guests on 31 October 2026. Their first-boot, restart, sleep/wake and shutdown checks are in progress. These remain **TO PROVE**, not inferred from the container results. See [managed SSH](ManagedSSH.md).

Before the first real SSH boot, review caught a potential default systemd timer/service dependency cycle. The timer now orders only after the early host-config service; its fired service waits for package installation. Real `systemd-analyze verify` passes in Arch and Ubuntu containers and is part of `make test-ssh`. Guest contracts now pass 92 existing + 7 SSH tests. The corrected runtime pin is `b6fc151c12c4afed4a40b4cfea2c14e8576d206d`, kit SHA-256 `28791bf2c1df3ede63ca66042de79c19fc6f12e59d38a96efe240781e2f8bb9b`. Its kit/app checks, container authentication/rejection checks, production probe and manager suite pass.

Fresh disposable SSH Test A has reached the upstream `.ready` boundary and binds only `127.0.0.1:2222`. SSH readiness has not been claimed; normal owner-account setup is pending. Test B is prepared on a distinct port, with an explicitly selected synthetic optional public key, and remains stopped. Retained POC profiles remain stopped and unchanged. An intentional cancellation during A's image preparation was surfaced as generic helper exit 143; it retained the download and storage, and the next launch resumed successfully. Improve this cancellation presentation separately.

## Manager artwork

Original editable stacked-frame artwork in `App/Assets/OmarchyVMManager.svg` uses Omarchy-inspired greens on a dark rounded tile. `make icon` renders it through the pinned upstream AppKit SVG tool, then packages all ten standard macOS representations with upstream's validated packer. The transparent master PNG is 1024×1024; native AppKit decodes the ICNS at 16, 32, 64, 128, 256, 512 and 1024 pixels. The artwork is visually inspected and used by the bundle's icon declaration, sidebar and guest Home card.

`make app-preview verify-preview` passes Swift compilation, signed bundle layout, icon payload checks, exact runtime provenance, macOS compatibility and host preflight. It creates a sibling preview app, leaving the live main app and SSH Test A untouched. The main bundle has not been replaced during the active guest session; the next normal app assembly includes the new artwork. The preview app was not launched against the live manager's registry. No permissions or VM storage were changed for this artwork task.

## Real SSH enrollment fix

A's completed desktop initially still reported SSH provisioning failure. Package `0.1.0-38` added bounded, validated stage/code/exit diagnostics through the existing guest-status channel. No console bootstrap was requested. It identified `share-mount / unsafe-directory`: the first enrollment mounted the host's 9p share, then the next timer invocation applied guest-owner checks to its Mac-owned root.

Package `0.1.0-39` checks the private guest parent before mounting, then validates the exact 9p tag, mount point, directory type and read-only VFS flag. It refuses symlinks, writable mounts and wrong sources. Ordinary guest-directory ownership checks remain strict. A regression test exercises repeated enrollment where applying guest ownership checks to the mounted share would fail, plus wrong-source/writable-mount rejection. Guest tests pass 92 existing + 9 SSH cases. The manager suite passes 67 Swift tests in 13 suites + 9 artifact tests; synthetic real-SSH/systemd/probe tests pass.

The corrected source pin is `9a09bf1c6ad1feb61ef24c52d1c43f077a4327d7`; kit SHA-256 is `6df11fc6a1f673878a195f275da1ae782958d65f1ecab62900b1c224b3957d06`. Kit/app signature, layout, payload, compatibility and preflight checks pass. The normal app now includes the new manager icon; its bundle was replaced only while all manager-owned guests were stopped.

A then upgraded to `0.1.0-39`, reported current-session configuration and became **Ready** after an authenticated, pinned connection. An independent host connection confirmed the expected non-root owner and VM/session identity. The exact generated SSH configuration also authenticated. All original client/host key and pin file inodes, modes, sizes and modification times match the first-launch baseline; public key/pin hashes match too. The vendor SSH service, enrollment timer and graphical session were active. B was launched alongside A and reached `.ready`; its normal account setup and remaining two-guest checks are pending.

The final exact source also passes `make test-upstream`: 530 Swift tests in 103 suites, 92 existing guest tests, 9 SSH guest tests and the broader no-VM contracts/shell/compatibility/relocation checks. With B at first-boot account setup, its SSH state is explicitly Waiting for guest account setup. A remains authenticated and rejects B's already-generated managed client key. No listening-port-only readiness was inferred.

## Two real SSH guests

B completed normal account setup, then became Ready automatically. Both generated SSH configurations authenticate to the intended non-root owner and VM/session. B's explicitly selected synthetic optional key also authenticates. Both cross-VM client-key attempts are rejected. A connection given B's host public key under A's alias is rejected with strict host-key checking; actual pins are unchanged.

B shut down through matching `.exited` and restarted from its existing disk, receiving a fresh session nonce and recovering SSH automatically. A stayed authenticated throughout and retained its session. With separate user approval, A's `wayland-wm@hyprland.desktop.service` was stopped; the unit was inactive and the Hyprland process absent. Several authenticated SSH connections still succeeded, and B remained accessible. Directly starting A's graphical unit over SSH returned failure, so A was restored through a normal graceful guest shutdown/start. B stayed authenticated through that shutdown too. A then recovered SSH and an active graphical session. Both sets of key/pin file identities, permissions, sizes, times and public hashes match the pre-restart baseline.

Before user-initiated sleep, both graphical sessions were active and both guests passed managed-key, optional-key and isolation checks. `.build/managed-ssh/pre-sleep.json` records the two session references/endpoints for the wake check. No personal VM or retained POC disk was modified. Sleep/wake and final stopped-process/storage cleanup are pending.

## Main-view branding and keyboard recheck

The library now has a prominent logo/title card above the guest list, with the running count and memory summary. The app declares the full ICNS family and explicitly sets `NSApplication.applicationIconImage` at launch. Build number 4 refreshes the bundle metadata. `make app-preview verify-preview` and `make app verify-app` pass. Native before/after inspection confirms the logo, title, counters and guest cards are readable with normal scrolling and no header overlap.

Both disposable guests were shut down through coordinated Quit; terminal states, manager exit and closed guest-disk handles were confirmed before replacing the main bundle. All four disks were preserved. The user then reported A's Command+Space failure. Read-only inspection found effective manager Accessibility trust false and no keyboard taps in either verified QEMU process, while A had live Super+Space bindings. The user manually refreshed only the current manager's Accessibility entry. Before relaunch, effective trust was true; afterward both verified QEMU processes had enabled HID keyboard taps. Both guests recovered authenticated SSH, optional-key login and credential isolation. User shortcut and sleep/wake confirmation are pending; no further app rebuild is planned during that check. The intermittent graphical startup issue remains a separate open follow-up.

The user confirmed both guest launchers work after Mac sleep/wake. Independent pinned host connections then authenticated to both expected guest/session identities on the original endpoints, including optional-key and isolation checks. Both disposable SSH guests were gracefully stopped; terminal states, closed guest-disk handles and disappearance of their verified QEMU processes were checked. Both original POC trees still match their complete baseline. The user requested keeping both fresh SSH test disks as well as the original POC disks, so all four remain stopped and preserved. The managed SSH milestone's real two-guest checks are complete; the separately tracked intermittent graphical startup finding remains open.


## Unattended defaults implementation — 31 October 2026

The user chose to keep both fresh SSH test disks. All four manager test guests remain stopped, with no unattended snapshots applied. The new Guest Defaults flow is opt-in until saved and takes immutable snapshots for new profiles only. Models, registry/schema migration, guarded seed staging, native UI and guest adapter are implemented; see `UnattendedDefaults.md` for the exact no-VM checks and remaining real first-boot gate. The earlier SSH/restart/sleep validation used package 39 and does not prove unattended setup in package 40.
