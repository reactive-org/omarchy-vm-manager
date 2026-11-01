# Native host folders

Sharing is opt-in per VM. In **Configure**, enable **Share a host folder** and review the full host path. The default is `~/Shared`; edit the field to choose another dedicated folder. The folder must already exist. The guest receives **read & write** access at `/mnt/mac`. The user accepted this native destination in place of the originally requested `/mnt/shared`; no alias, bind mount or repository-owned sharing controller is installed.

The Network page shows the path, destination, access mode and separate mount status. A configured mapping is not a verified mount. Managed SSH must be enabled for mount verification. It remains a separate read-only integration share at `/run/try-omarchy/managed-ssh-share`.

## Create and update

These are usage examples. The update/start/disable flow was subsequently exercised on the approved existing Dev VM; see the live validation record below.

```sh
# Metadata only: no guest starts and no host folder is created.
omarchy-vm create work --share on
omarchy-vm create work-alt --share-path "$HOME/WorkShare"

# Update requires a stopped VM, including the matching runtime exit.
omarchy-vm update UUID --share on --share-path "$HOME/Shared"
omarchy-vm start UUID --wait ssh
omarchy-vm get UUID

# Disable while stopped; the following start exports no personal folder.
omarchy-vm update UUID --share off
omarchy-vm start UUID --wait ssh
```

JSON configuration accepts `"share": true|false` and `"sharePath": "/absolute/path"` (or `"~/Shared"`). Flags override JSON. `--share on` reuses the per-VM remembered path, defaulting to `~/Shared`. A supplied `--share-path` opts in unless `--share off` is also explicit. Omitting both fields preserves the current mapping on update and leaves sharing off on create. Disablement retains the remembered path and works if the folder has disappeared or become inaccessible. No CLI option changes the fixed guest destination or pretends to provide a read-only export.

`get` and `list` include `sharedFolder` (hostPath, enabled, guestPath, access), `sharedFolderStatus` and `sharedFolderError`. Status is `disabled`, `stopped`, `unverified`, `waiting-ssh`, `checking`, `mounted` or `failed`. `--wait ssh` waits for authenticated SSH, not for the independent mount check; poll `get` for `mounted` and inspect its error on failure. SSH monitoring rechecks the mount on each successful check, normally every 30 seconds. **Retry SSH Check** also repeats it. Sharing checks wait for the optional power-capability probe, then make at most three bounded attempts for transport failures. Identity, configuration, authentication and malformed mount-report failures are not retried. Error stages use fixed categories and never expose SSH stderr. Pausing, Mac sleep, shutdown and exit invalidate mount readiness; a stale result cannot mark another session mounted.

Native app edits and CLI edits share the same stopped-VM policy. Existing settings are written only at the next launch, under the runtime-compatible VM lock and the explicit configuration revision. Settings changed outside the manager are preserved and require another configuration review. The manager never adopts an unrequested stored share. Registry schema 5 records the opt-in; older manager versions reject it. Keep the updated manager and storage helper together. No automatic downgrade is supported.

## Runtime and guest prerequisites

**VERIFIED — inspected pinned source:** the existing runtime consumes schema-1 `sharedFolderPreferences` from that VM's `settings.json`. Its Swift and shell boundaries validate the selected directory and construct a native virtio-9p export with tag `mac`, `security_model=none` and uid/gid 1000 ownership presentation. This needs no new host software or runtime rebuild. The public run protocol has no sharing field; this adapter is **PRIVATE COUPLING** to the exact verified kit, not a capability inferred from protocol 1. Production receives no environment overrides.

The `try-omarchy` integration package's `omarchy-native-mac-share.service` mounts the export at `/mnt/mac` before the display manager starts. Its user link service may also expose `~/<host-folder-name>`; these are the same files. Disabling the export on a later boot lets the upstream integration remove its managed home link. The destination is fixed to avoid arbitrary mounts over guest system directories. Native mounts can obscure files already under `/mnt/mac` without deleting them: check that location before enabling an existing guest. The manager does not move or erase guest files to make room.

| Factory | Required guest support | Evidence |
| --- | --- | --- |
| Official aarch64/UEFI | Reviewed `try-omarchy` package, native share service/script, kernel 9p and virtio transport support, uid/gid 1000 owner; managed SSH, Python 3 and `findmnt` for verification | Source contract checked; live sharing remains TO PROVE |
| Lean aarch64/UEFI | Same sharing service/script and kernel support, retained in its compatible integration package; managed SSH, Python 3 and `findmnt` | Verified on the approved existing lean Dev VM with integration 0.1.0-43.1 and kernel 7.3.0-7-omarchy; other lean artifacts remain TO PROVE |

No guest package install, factory rebuild, kernel replacement or permission grant happens automatically. A missing service, module or utility produces an unverified/failed mount. Review `systemctl status omarchy-native-mac-share.service --no-pager` and `findmnt -n -t 9p -o SOURCE,TARGET,OPTIONS /mnt/mac` in the guest. Restore prerequisites through an explicitly approved guest administration step, or disable sharing. Host access failures require choosing an accessible folder; the manager does not chmod it or request macOS privacy permissions.

The upstream mount uses `trans=virtio,version=9p2000.L,msize=1048576,cache=readahead`. Verification requires source `mac`, target `/mnt/mac`, type `9p`, read-write access, read/write/search permission for the authenticated guest owner, and `cache=readahead` or `cache=0x1`. A kernel may omit the default protocol from `findmnt`; an explicitly conflicting version is refused. The pinned service still supplies `version=9p2000.L`. Verification refuses writeback/mmap caching. Keep SQLite WAL databases, writable shared mmap and mmap-based IPC on the guest disk. This policy avoids the upstream-documented writeback path; it does not prove a kernel corruption bug fixed or every workload compatible. See the pinned [shared-folder safety notes](../Vendor/try-omarchy/docs/shared-folder-safety.md).

## Host access and recovery

**DESIGN DECISION:** accept dedicated directories inside the current Mac user's home. Reject the whole home, outside/home/system paths, Library, hidden path components and broad top-level personal folders. Selected paths and their parents must be owned, readable/searchable, non-linked and not group/world writable; the selected directory must also be writable. Preflight checks at configuration and launch refuse existing symbolic/hard links, special files, foreign ownership, unsafe modes and known credential entries inside the subtree, with a 100,000-entry bound. No file contents are read for this check. Use an empty or small dedicated data folder rather than a source tree containing credential configuration.

Read-write means the guest can read, create, alter and delete every permitted file in the selected tree as the Mac user. The preflight is not a continuing content filter: files you add later, including credentials, become exposed too. Do not put secrets there. Host folder permissions remain part of the boundary; scans cannot eliminate changes between validation and runtime open. The runtime independently checks the path again. There is no live hot-plug, dynamic revocation, read-only mode or security-scoped bookmark support in this kit.

For a mount failure the VM stays running and retains its runtime handle, memory and port reservation. No automatic restart or disk repair occurs. Correct host access or guest prerequisites and retry verification; a changed export path requires a stopped update and normal restart. A missing host path fails launch admission rather than creating a replacement. Disabling is always a stopped update followed by a new boot, not an immediate revocation from a running guest. Close guest applications using shared files and shut down cleanly first. Disabling never removes host files or recursively erases guest data.

## Approved existing-VM validation plan

Target only UUID `38012142-9431-437A-A042-64ECE8E9DD36`. This plan was presented while the installed 0.9.4 manager and guest were untouched. The user explicitly approved deployment and the validation on 2 November 2026, then confirmed that validation should finish on this existing disk before they recreate the VM themselves. No VM deletion or reset was performed by this work.

1. With approval, read the current manager/profile/runtime identity and authenticated guest identity. Confirm the factory and share prerequisites, `/mnt/mac` is absent or an empty non-linked directory, no conflicting `~/Shared` guest path/link, and the existing managed SSH share is still the expected read-only 9p tag. Record disk inode/size and graphics/display settings without reading private guest content. Inspect `~/Shared` safely; if missing, obtain approval to create only that dedicated host directory.
2. Deploy/open the updated manager only with explicit permission, coordinating its normal shutdown with the running VM. Preserve the existing disk and all runtime pins. Update this stopped UUID with `--share on --share-path "$HOME/Shared"`; start normally and require authenticated SSH plus `sharedFolderStatus: mounted`.
3. Exclusively create one random UUID-named host test file and one guest test file under that folder. Verify exact bytes in both directions, including a guest append/read-back. Never overwrite existing files. Record only test hashes/metadata.
4. Shut down normally, await matching `.exited`, restart the same disk and verify the same mapping and disposable files. Recheck managed SSH, clipboard behavior with human focus, hardware VirGL and native Retina settings; source preservation is not live proof of those behaviors.
5. Shut down normally, disable sharing, start the same disk and confirm no personal `mac` 9p device/mount while managed SSH remains ready. Verify both disposable files still exist on the host. Remove only those exact test files after byte/identity checks. After verifying clean disablement, re-enable the same mapping in one further normal shutdown/start cycle and verify it again. Leave the existing VM running with sharing enabled. The complete proposal includes four normal shutdown/start cycles: initial enablement, persistence, disablement and re-enable.

**Evidence at proposal time:** all live checks were TO PROVE, and source implementation had touched no existing guest. The observations below supersede that status only for the explicitly tested lean VM and checks.


## Initial source validation — 2 November 2026

**VERIFIED — no-VM checks:** `make test` passes 202 Swift tests in 35 suites and 43 Python script tests; `make build` passes. The ten new Swift test functions include parameterized path/credential/link/mode checks, strict CLI/JSON behavior, schema-5 persistence and old-profile opt-out, stopped settings enable/restart/disable with unchanged SSH key and forwarding plus guest sentinel bytes, malformed-settings preservation, exact guest mount/session/cache report checks, retained lifecycle allocations on failure and stale-report cancellation, and pinned native runtime/SSH-share separation. These are fixtures and protocol checks, not observed live mounts. Logs are in ignored `.build/shared-folder-tests.log` and `.build/shared-folder-build.log`. `git diff --check` passes.

The initial sandboxed run could not bind existing local socket/loopback fixtures. The full passing run used the approved local test execution outside that sandbox. No host software was installed/downloaded, no runtime/QEMU was built, no signing identity or macOS permission was used, and no existing guest was contacted or changed. At that stage the installed manager remained 0.9.4. UI controls compiled but have not been exercised through a live application window.


## Authorized live validation — 2 November 2026

**VERIFIED — existing lean Dev VM:** deployed manager **0.10.0 (23)** to `~/Applications/Omarchy VM Manager.app` and the repository's `dist` app. Only the manager/client were compiled and ad-hoc signed. The exact pre-existing runtime lock and embedded inventory/signatures remain unchanged; no runtime/QEMU build, factory download, guest package installation, real signing identity or macOS permission grant was used. Both manager and QEMU were initially absent, so validation began by booting the original disk with sharing off.

The guest runs `try-omarchy 0.1.0-43.1` and kernel `7.3.0-7-omarchy`. Confirmed the native mount service/script, an empty safe destination and no conflicting guest home link before enabling. The existing managed SSH share stayed the expected **read-only** `tryomarchy-managed-ssh` 9p mount throughout.

The enabled mount reports source `mac`, target `/mnt/mac`, filesystem `9p`, and `rw,relatime,cache=0x1,access=client,msize=512000,trans=virtio`. The owner has read/write/search access. Linux omits the protocol option in this report; the verifier now accepts omission while rejecting an explicitly incompatible version. This observed report is covered by a regression fixture.

Exclusively created two random UUID-named disposable files in the selected host folder. Exact host-to-guest reads, guest-to-host reads and a guest append visible on macOS all passed. Both files and their exact bytes/host inode identities survived normal restarts on the existing disk. Disabling sharing through the stopped CLI configuration and rebooting removed the personal 9p device, mount and upstream home link; both host files remained unchanged and authenticated SSH stayed ready. Re-enabling restored the same mapping.

Live checks identified intermittent SSH exit-255 failures in the additional mount probe even while independent pinned SSH and the mount worked. The exact underlying transport cause is not established. The manager now serializes optional power/sharing checks, bounds transport retries, and reports fixed failure stages without raw stderr. Guest mount/identity validation still fails closed. Lifecycle handles and reservations stay retained on a probe failure.

The user stopped the VM during validation and attempted Trash while expecting the work complete. The old helper refused registry schema 5 and moved nothing. After confirming the disk/keys/profile intact and no pending deletion, the user directed completion on the existing VM. The helper now uses the same versioned registry admission as the manager. Disposable metadata tests cover schema 5 and legacy acceptance, unknown schema, missing review, duplicate UUID and wrong target refusal. No real guest was used for a deletion test.

Final no-VM checks: **206 Swift tests in 35 suites and 43 script tests pass**, along with `make build`, ad-hoc bundle/signature verification, exact kit inventory, macOS 15 compatibility, NAT/no-factory-image layout and `git diff --check`. Additional tests cover transport recovery/exhaustion, immediate trust/report failure, and ordering the optional power check before sharing. Logs and non-secret validation receipts are in ignored `.build/shared-folder-validation/`.

The original disk's device/inode and 64 GiB size, protected profile fields, factory identity, SSH private-key hash and host-pin hash remain unchanged. Existing QEMU display/GPU arguments are identical. Guest utilities confirm accelerated **VirGL**, no software renderer, and **4960 × 2790 at scale 2**. The focus-aware clipboard bridge is running for the matching QEMU process; no clipboard payload or screen pixels were read.

**TO PROVE:** official-factory live sharing; other lean artifacts/kernels; workload-wide or concurrent extending-write integrity; focus-sensitive clipboard transfers, sleep/wake and crash behavior. The native form compiled, but the approved live configuration used the CLI rather than UI automation. No observation here upgrades those untested behaviors.


**VERIFIED — final handoff:** the installed final build passed a 65-second observation spanning two periodic health-check intervals, ending with **Running / SSH ready / Mounted**. Reverified both disposable files after the final build's restart, then removed only those two exact UUID-named paths after matching host inode and content hashes. Their absence was confirmed from the guest. Unrelated files subsequently placed in `~/Shared` were preserved without reading their contents. Final package/script identity, accelerated VirGL, 2× scaling, matching clipboard bridge, original disk/profile/SSH hashes and the separate read-only SSH mount all pass. Dev VM is left running with `~/Shared` mounted at `/mnt/mac`, read-write. The final non-secret receipt is `.build/shared-folder-validation/result.json`; periodic observations are `final-monitor.json`. Installed-path bundle verification also passes.
