# Guest command line

Build with `make app verify-app`. Run `./bin/omarchy-vm` from this repository, or run the bundled `dist/Omarchy VM Manager.app/Contents/MacOS/omarchy-vm`. Add this repository's `bin` directory to `PATH` to use `omarchy-vm` directly. No global symlink or privileged service is installed.

```sh
./bin/omarchy-vm list
./bin/omarchy-vm create dev --memory 4GiB --cpus 4 --disk 64GiB --start --wait ssh --timeout 1800
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

Commands accept a full UUID or exact guest name. Names are unique under the existing registry policy. UUIDs are preferable in scripts. Creation accepts a positional name or `--name`; update can rename with `--name`.

Replies are one compact JSON object on stdout. `--help` prints human-readable usage; `--version` returns JSON. Exit 0 means success, 1 means failure and 124 means wait timeout. Failure replies contain a stable `error.code` and message. When a create/start or wait fails, the reply includes the created/current guest so its UUID and state can be inspected. A timeout, closed CLI or disconnected client leaves the VM under the manager's lifecycle ownership; it does not shut down or delete it. A lost transport reply can leave a mutation's outcome unknown, so the client does not automatically repeat a sent mutation.

## Configuration

Use flags or `--config FILE.json`. Explicit flags override file settings. Supported JSON keys are `name`, `memoryMiB`, `cpus`, `diskGiB`, `clipboard`, `immersive`, `ssh`, `ownerDefaults`, `publicKey` and creation-only `factory`. Unknown keys and nulls are rejected. For example:

```json
{"memoryMiB":8192,"cpus":8,"diskGiB":64,"clipboard":true,"immersive":false}
```

The current policy requires at least 4 CPU cores and 4 GiB RAM, with RAM in whole GiB, within the Mac's existing guest budget. New guests use a 64 GiB sparse disk. `--disk 64GiB` and `--disk-gib 64` set capacity from 64 through 8192 GiB; an existing disk can only grow. `--memory` accepts MiB or GiB suffixes; a plain integer means MiB. `--memory-mib` is also available. Boolean flags take `on`/`off` or `true`/`false`.

Factory selection, SSH and owner setup are creation-only. New guests inherit saved Guest Defaults and enable managed SSH by default. `--owner-defaults off` selects the normal guest owner wizard. `--ssh off` disables SSH enrollment. `--public-key FILE.pub` imports only an explicitly selected public key; no personal credentials are scanned. Configure reusable passwords locally in the app's Guest Defaults page; no CLI password argument or secret field is supported.

`update` refuses active, stopping or otherwise busy guests and retained POC profiles. An external runtime-compatible storage lock also prevents edits. Changes apply on the next start. Disk capacity can grow but never shrink; growth uses the official runtime and guest root-growth service on the next boot. SSH enrollment, owner snapshots, disk paths and general port forwarding cannot be changed by update.

## Readiness and SSH

`start` and `create --start` return after launch admission unless a wait is requested. `--wait running` means the upstream runtime reached its normal ready boundary; it does not prove an owner account or SSH is usable. `--wait ssh` waits for an authenticated pinned connection, then verifies the current owner/VM/session again before returning literal guest addresses. Use `wait ID --for ssh|running|paused|stopped` to continue observing an existing session. Stop accepts `--wait` for matching terminal exit; `--force` explicitly requests forced termination. Restart waits for the old session's matching exit before starting another.

The default wait limit is 600 seconds, configurable from 1 to 3600. The same deadline applies across restart's stop/start waits. Existing manual-setup guests need their owner wizard completed before SSH can become ready. Closing or restarting the GUI manager still follows its normal coordinated shutdown; the CLI is a client of that long-running app. If needed, the CLI opens the bundled manager hidden in the background.

Connection details distinguish the two addresses:

```json
{"ssh":{"enabled":true,"status":"ready","host":"127.0.0.1","port":2224,"user":"owner","command":"ssh ..."},"network":{"mode":"nat","guestIPs":["10.0.2.15"],"hostAddress":"127.0.0.1","addressesVerified":true}}
```

Use `ssh.command` for the generated client configuration, independent managed key and pinned server identity. The private guest IP is informational and may be shared by different NAT guests. `get` refreshes addresses when SSH is ready; list may include the last checked addresses for the same active session. Paused, stopped or replaced sessions do not report verified addresses. Passwords, private keys and Keychain references are excluded from replies.

## Pause and resume

This is the uninstalled in-memory development candidate. It retains RAM; see [Suspend](Suspend.md) for the clarified RAM-releasing requirement and current runtime blocker.

`pause ID` and `resume ID` wait for a matching helper acknowledgement, with a limit of ten seconds (or a shorter `--timeout`). They do not need `--wait`. `wait ID --for paused` observes a manual pause. Paused replies have `state: "paused"`, `active: true` and SSH status `"paused"`; connection addresses are withheld until running again. `wait --for ssh` fails with `guest-paused` while execution is paused or uncertain.

A pause keeps the process, RAM, disk lock and localhost port. Active edit/delete guards still apply. Mac wake does not resume a manual pause. Stop, restart and application Quit first recover an owned pause to let Linux shut down normally. Force Stop terminates it. See [Pause/Resume](PauseResume.md).

If an execution acknowledgement is lost, the reply fails with `execution-timeout` and the guest stays active with `state: "execution-unknown"`. The command is not repeated automatically. Another Pause/Resume is refused until the late acknowledgement arrives; stop remains available. A disconnected CLI does not undo a command already sent.

## Local control and deletion

The manager keeps the registry lock and all runtime clients. The CLI uses a bounded, versioned JSON protocol on an owned mode-0600 Unix socket inside a mode-0700 directory under `/private/tmp`; both peers check the local UID. The socket directory includes a digest of the fixed application-support location and UID. No TCP command listener, authentication bypass or arbitrary storage-root override is exposed.

`delete` requests the manager's existing reviewed whole-root Trash transaction. It never recursively erases a VM. Running guests and protected saved sessions cannot be deleted. Stopped retained POC guests use the same reviewed deletion flow as other guests. A profile without initialized storage is removed as metadata only. Inspect and restore any trashed VM files using the Mac's normal Trash workflow; automatic restoration is outside this CLI.

The guest record's `protected` field identifies retained POC configuration protection. It does not prohibit confirmed deletion of a stopped guest. Lifecycle and saved-session guards are checked when the command executes.

## Validation status

**VERIFIED — no-VM checks:** 93 Swift tests in 21 suites and 9 artifact checks pass. Fake-runtime tests cover CRUD, immutable creation fields, active/protected guards, grow-only disk capacity, external locks, session-bound waits, timeout behavior and restart sequencing. Real Unix-socket tests cover private permissions, bounded same-user request/response exchange, live endpoint refusal, malformed schemas and client disconnect. Normal app/CLI signature, compatibility, layout and host-preflight checks pass.

**VERIFIED — packaged CLI:** build 0.5.0 (7) automatically opened the manager hidden, returned JSON for version/list and restored the four existing profiles as stopped. A new metadata-only fixture with owner defaults and SSH off was created, updated from a JSON file, renamed, looked up by exact name, waited for as stopped and deleted through the CLI. Its updated 5 GiB configuration appeared in the same GUI. It never acquired a storage root or launched a VM. All four earlier profile values and disk identities match their baseline.

**VERIFIED — approved fresh VM:** the user authorized one additional disposable CLI guest and its final Trash cleanup. `create --start --wait ssh --timeout 1800` reused saved unattended defaults across the app update, booted without a manual console bootstrap and returned guest IP `10.0.2.15`, host `127.0.0.1`, port `2224`, the owner and generated SSH command. A concurrent get during the initial wait returned progress without blocking the owner; after readiness, a separate get refreshed the authenticated address report.

An independent connection through that generated pinned SSH configuration verified the expected non-root account and current VM/session. A running CPU/RAM update failed with `vm-not-editable` and preserved the original configuration. `stop --wait` reached matching terminal exit and closed disk handles. A stopped update from 4 GiB/4 CPUs to 5 GiB/6 CPUs applied on the next start: the guest itself reported six CPUs and over 800 MiB additional usable RAM. The boot/session changed; the SSH endpoint, client/server key metadata and host pin remained unchanged. The temporary owner password seed stayed absent.

A real one-second wait for stopped returned exit 124 with `wait-timeout` while leaving the guest running. Final normal stop reached `Exited (0)`, with no QEMU process or open disk handle for the test guest. The CLI then moved only that guest's entire root to recoverable Trash as authorized and removed its profile. All four earlier profiles and disk identities match their baseline; both original POC trees also match every recorded stat/hash entry. They remain stopped. No personal VM or personal private SSH key was used.

**VERIFIED — grow-only disk:** the accepted `Dev Omarchy` guest was gracefully stopped, updated from its legacy factory capacity to `diskGiB: 64`, and restarted through the packaged 0.6.0 CLI. The host image reports exactly 68,719,476,736 logical bytes while remaining sparse at about 9.9 GiB allocated. Inside the guest, `/dev/vda` reports 64 GiB, the Btrfs root partition reports about 62 GiB, and `df` reports 52 GiB available. The manager did not truncate, partition or directly edit the filesystem.

Abrupt manager/helper crash recovery and unsupported future guest-image behavior retain their earlier documented limits. This CLI milestone does not add general port forwarding or migrate existing SSH/owner enrollment.

New guests share the factory image in `~/Downloads/Omarchy VM Manager/Factory Images/`. The current pinned image is retained; obsolete downloads are pruned after seven days without use. Deleting a guest does not discard the cache. See [factory cache](FactoryCache.md).

## Experimental hibernation status

Guest replies additionally expose `hibernation` when the current authenticated guest check is available, `experimentalSuspendAvailable`, `experimentalRestoreAvailable`, `suspension` and `suspensionMetadataUnsafe`. Kernel support is `supported`, `unsupported` or `unknown`; readiness also requires disk sleep state, persistent swap, resume setup and non-interactive guest permission. No marker token or boot identity is returned. Stopped or unverified capability never enables an attempt.

Experimental suspend/restore is an opt-in **UI** workflow. Ordinary CLI `start`, `restart`, update and delete refuse a protected saved-session disk. Use **Restore / Recover…** in the manager; a verified cold boot requires administrator cleanup of any stale resume image and explicit acknowledgement before protection is released. An unresolved restore cannot automatically boot again. CLI `resume` continues to mean in-memory resume. See [Suspend](Suspend.md).

## Factory import, selection and deletion

`factory-import /absolute/path/Prepared.factory` verifies a prepared bundle, copies it into the private library and saves a local import record. No catalog edit or app rebuild is required; the app’s **Import Factory** button uses the same path. `factories` lists verified imported images and the official factory; damaged entries appear separately in `factoryIssues` and cannot be selected. `create NAME --factory official|MANIFEST_SHA256` (or the creation config key `factory`) records that immutable selection in the profile; the New VM sheet offers the same choices. The default is `official`. Replies include the recorded `factory` when present. Existing profiles retain their original disks and metadata, including an absent factory field. Update refuses image changes.

Import starts no VM and downloads no image. The image, provisioning evidence, integration package and exact runtime hashes must pass validation. The local receipt preserves the verified identity across app restarts. Select a source you trust; integrity checks do not prove a guest will boot. See [Custom factories](CustomFactories.md) for preparation, review, cache location and the helper capability contract.

Prepared bundles may explicitly select the reviewed `lean-e4fffc6` owner contract through the preparation tool; the CLI never accepts arbitrary program hashes or executable contract paths. Lean requires the matching integration-source rebuild and hashed compatibility/build evidence. [Lean owner setup](LeanOwnerSetup.md) gives the exact rebuild, preparation, import and disposable metadata-only creation commands. Official factory selection keeps its preserved contract.

`factory-delete MANIFEST_SHA256` moves an unused verified imported bundle and its receipt together to Trash and returns its identity in `deletedFactory`. Use the exact lowercase manifest digest from `factories`. The official factory is protected (`factory-protected`); any reference from an existing profile or pending creation blocks removal (`factory-in-use`), including stopped and metadata-only guests. There is no force override or guest reassignment. No guest disk, profile, original prepared source or official download cache is changed.

Import and deletion serialize (`factory-busy`), and new creation cannot select a factory being deleted. Damaged, unregistered or runtime-incompatible factories are preserved for manual review. The command waits for the recoverable Trash operation, remains manager-owned after CLI disconnect, and is not retried automatically. See [factory deletion and recovery](CustomFactories.md#delete-an-unused-factory) for failure codes and recovery folders. The app refreshes its picker after CLI factory changes.
