# Stable and Dev

The existing app and its VMs are the stable channel. Its bundle identifier, Application Support directory, command endpoint, credentials and default SSH allocation are preserved. “Stable” identifies the everyday app and its data; it does not relabel a published prerelease as a stable release.

Dev is a separate build of the same source, named **Omarchy VM Manager Dev**, with a purple DEV icon, Dev window/sidebar titles and `[Dev]` guest display names. Both apps can be installed together. Dev starts with an empty registry and independent Guest Defaults, disk defaults, selected public keys, imported factories, logs, VM disks, SSH credentials and saved setup passwords. It never imports or migrates stable data automatically.

| Identity | Stable | Dev |
| --- | --- | --- |
| Bundle ID | `dev.omarchy.vm-manager` | `dev.omarchy.vm-manager.dev` |
| Application Support folder | `Omarchy VM Manager` | `Omarchy VM Manager Dev` |
| Downloads cache | `Omarchy VM Manager/Factory Images` | `Omarchy VM Manager Dev/Factory Images` |
| CLI | `omarchy-vm` | `omarchy-vm-dev` |
| Default SSH allocation | 2222–49151 | 49200–59999 |

Both folders are beneath the current user's normal `~/Library/Application Support` or `~/Downloads`. VM roots remain derived as `VMs/<UUID>` within their channel. Each channel has its own application/registry locks, activation notification and private same-user command socket. Existing endpoint metadata is never silently reassigned; host bind checks and QEMU's final bind remain authoritative.

## Build and use

After preparing the pinned runtime as described in the repository README:

```sh
make test-dev app-dev verify-dev
./bin/omarchy-vm-dev --version
make run-dev
```

`app-dev` builds the manager, CLI, storage helper and provisioning helper with `DEVELOPMENT_CHANNEL`, using the separate `.build/dev` SwiftPM scratch directory. It includes the shared Swift provisioning resources and channel-neutral C process launcher, then assembles `dist/Omarchy VM Manager Dev.app`. `verify-dev` performs no-VM bundle, signature, provenance, channel and layout checks. `run-dev` explicitly opens only Dev. Rebuild Dev while the stable app remains running; stop Dev's own guests before replacing its bundle.

`bin/omarchy-vm-dev` resolves only the Dev bundle beside this checkout. The packaged CLI is `Contents/MacOS/omarchy-vm-dev`; it may be symlinked to a chosen tools directory. It starts only its containing Dev app when needed and never falls back to a stable socket. `--version` includes `appChannel`. Normal commands require a containing app matching the compiled channel. The storage helper also checks that containing identity before it reads a registry or handles deletion.

Existing `make app`, `make run` and `bin/omarchy-vm` retain the stable channel. `make app-preview` and `make verify-preview` are compatibility aliases for Dev. The no-VM layout gallery remains separate. Dev selection is compiled, independent of optimization, and cannot be changed through preferences, environment variables or renaming the app.

Each app embeds its own complete verified runtime. Dev requires pinned `managerChannelsVersion: 1`; an older kit cannot silently reuse stable runtime storage. Rebuilding this runtime preserves the guest packages, QEMU, firmware and factory contracts. Legacy exact-runtime custom factory receipts may need a separate explicit import for a changed runtime; no receipt or disk is migrated automatically.

## Host integrations

The runtime resolves Dev from the exact enclosing manager app's bundle identifier. Dev downloads and guest Touch ID key representations use Dev directories. Guest setup Keychain services are channel-specific; Dev does not probe or upgrade stable passwords. Ad-hoc Dev builds retain the existing development login-Keychain flow. The current stable provisioning profile is refused for Dev signing; a signed Dev distribution needs separately reviewed provisioning. This implementation uses no real signing identity or credentials.

The native authentication prompt lease intentionally remains shared at the existing stable `Native Authentication Keys/.prompt.lock` so Dev and already installed stable helpers cannot present competing prompts. The lease is a non-secret coordination file; guest key files are separate. The Mac pasteboard and physical devices remain host resources, with existing focus and bridge policies retained. Folder sharing stays explicit and can intentionally expose the same selected host folder to both channels.

There is no combined CPU/memory budget and no additional Dev resource cap. Each manager retains its existing admission policy; the user manages allocation across the two apps. Updating stable still requires stopping its guests because the manager owns their runtime handles.

## Evidence

**DESIGN DECISION:** the existing identity/data are stable, Dev has separate writable state, and no cross-channel resource policy is added at the user's request.

**PRIVATE COUPLING:** the pinned helper's enclosing-app channel resolution, Downloads cache selection and native authentication key directories. The old prompt lease location is retained for compatibility with already running stable helpers.

**VERIFIED — no-VM checks, 5 November 2026:** `make test test-dev app app-dev verify-bundle verify-dev test-channel-bundles test-build-policies` passes 255 Swift tests in 42 suites in each compiled channel, all 82 script tests and both executable builds. It passes both bundle layouts, exact inventories, all 22 runtime Mach-O ad-hoc signatures, macOS compatibility, matching manager/CLI/helper channel diagnostics, mismatched-app CLI/helper refusal and the two optimized launch/credential cases in each ordinary-release and signed-prerelease mode. Bundle diagnostics report `hostPreflightPerformed: false` and `vmLaunchEnabled: false`. Both CLI wrappers report the expected distinct `appChannel` with version 0.11.0. The new purple icon was rendered and visually inspected without opening the app. `make test-upstream` passes all 566 Swift tests in 113 suites plus the existing shell, contract, guest-package, compatibility and relocation fixtures. The live home-disk acceptance test remains disabled.

Runtime source is `d6dd3dbe860f55302a66be884113e647e42b0eba`; kit ZIP SHA-256 is `5b30b9b3a82a80eac5c32e96302a8abe5d8a50c9a05853b876f0603a63839839`. Compared with the prior local runtime inventory, only the host helper, kit manifest, owner provenance receipt and signature resource changed. Every other payload, including QEMU, firmware, scripts and both guest package archives, is byte-identical. The complete kit was rebuilt using the existing local reference and verified guest archives, with no download or real signing identity. Historical signed provenance remains unchanged.

The first no-VM runs exposed a noncanonical new authentication fixture path, a URL directory-hint comparison in the new storage fixture, throwing-macro syntax in that fixture and a Dev display-name packaging error; all were corrected before the final checks. One unrelated upstream UDP port-availability fixture failed transiently in the first run and passed in both subsequent complete suites without a production change. The existing home-mount fixture now mocks `Path.stat` directly so the installed Python's pathlib implementation observes its synthetic device identity; production guest code and packages are unchanged. Logs are retained under the worktree's ignored `.build/channel-validation/` directory.

**TO PROVE:** two actual app instances with real guests, native permission attribution, Keychain prompts, guest Touch ID enrollment, clipboard focus transitions, sleep/wake and crash behavior across channels. Synthetic fixtures and bundle checks do not establish these outcomes. No installed app or existing VM is changed by the build workflow.

## Authorized Dev installation — 5 November 2026

**USER AUTHORIZATION / VERIFIED:** the user requested installing and opening Dev alongside the running stable app, with work VMs untouched. Installed the previously verified bundle as a new `~/Applications/Omarchy VM Manager Dev.app`; no prior Dev destination existed. A private staging copy and final installed copy both passed bundle-only signature, exact kit inventory, compatibility, channel and layout verification. Every installed file hash and mode matches the built source. The final move used exclusive atomic rename; no app was replaced. Opened only Dev and confirmed that exact installed path has finished launching, is not hidden and owns one visible manager window.

Read-only same-user manager queries before/after show both stable work-VM sessions remain active with identical session identities and states. All 17 captured stable manager/runtime process identities remain unchanged. Stable registry, Guest Defaults, disk defaults and installed stable app metadata/executable hashes match their baseline. Dev's own command endpoint responds with an empty guest list and no active guests. No guest lifecycle command, disk operation, factory download, saved credential access, permission grant or real signing identity was used. The stable app was neither replaced nor restarted. This verifies manager coexistence while existing stable guests run; a guest running in Dev, native focus/clipboard, authentication, sleep/wake and crash behavior across channels remain **TO PROVE**.

Private before/after receipts and staged/installed verification logs are retained in the ignored `.build/channel-validation/dev-install/` directory. No VM names, credentials or guest contents are included in the public record.

## Authorized disposable Dev guest acceptance — 5 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** the user requested one disposable VM in the installed Dev app, running alongside the existing stable work VMs without changing or stopping them. Use a new Dev-owned UUID with 4 GiB RAM, four CPUs, a 64 GiB system disk, single-disk layout, NAT and background launch intent. Disable saved owner defaults, SSH, personal-key inheritance, clipboard, guest Touch ID, sharing and immersive mode. Manual account setup is deliberately left incomplete. No saved credentials, host permission grants, UI automation or factory download is required.

**VERIFIED — factory and boot:** import the existing reviewed format-2 factory `092b66bda3e91a30a8ccd85606a4e35b0589d75d60ead52b80af3bca384297f2` through Dev's normal complete-verification/import path. Its stable-library source is read-only and its descriptor hash remains unchanged. Create only a new stopped Dev profile, then start that exact UUID with `--wait running --timeout 600`. The independent root reaches the matching runtime Ready boundary and owns one native QEMU guest window, observed through target-PID window metadata without screenshots or activation. The guest reports kernel `7.3.0-7-omarchy`, Omarchy `4.0.0.r7481.ge4fffc6-1.1`, integration package `0.1.0-47.1` and successful offline integration installation. No managed SSH credentials or owner setup seed are created.

**VERIFIED — independent lifecycle and stable isolation:** Dev Pause acknowledges `paused` while retaining the active test session; Resume acknowledges `running`, and a guest status heartbeat advances after the resume response. Before preparation and after import, running, pause, resume and final shutdown, both stable work VMs retain their original session identities and states. All 17 captured stable manager/QEMU/helper process identities remain unchanged. Stable registry, Guest Defaults, disk defaults, installed app metadata/executable and per-VM settings/ownership-marker hashes match baseline. Stable system/home disk device, inode and logical-size identities also match. No stable lifecycle or guest command is sent; ordinary writes performed by the running work guests are not frozen or compared.

**VERIFIED — test shutdown and retained cleanup:** `stop <test UUID> --wait --timeout 180` returns stopped/inactive and the Dev manager records matching `Exited (0)` for that exact launch session. All six captured disposable runtime process identities are gone, the test disk has no open handles, and the existing runtime-compatible POSIX lock is available. Both stable work VMs remain active. The stopped test profile/root and imported Dev factory are retained; offer guarded whole-root Trash separately. No root is reset, recursively removed or automatically deleted.

The installed Dev CLI performs factory import, create, start, get, pause, resume and stop; the stable endpoint is queried only for read-only session status. Private command receipts, baseline/final audits, guest boot/heartbeat evidence, captured process identities and the one-off runner are retained under `.build/channel-validation/live-dev-coexistence/8323B0CB-0FFA-48A5-A673-6EBA3A067F19/`. The source/runtime and installed app are unchanged during this run.

**TO PROVE:** completed interactive account/desktop setup and authenticated SSH in Dev, cross-channel clipboard/focus/keyboard use, guest Touch ID and prompt coordination, official-image Downloads cache isolation, sleep/wake, crash/forced-stop recovery and workload/performance behavior. This run proves basic guest boot and independent pause/resume/normal shutdown alongside the two unchanged stable sessions; it does not establish those additional cases or human-observed work-guest responsiveness.

## Approved disposable Dev cleanup — 5 November 2026

**USER AUTHORIZATION / VERIFIED:** the user explicitly approved moving only the disposable Dev test VM to Trash while leaving stable work VMs and all other data untouched. Rechecked the recorded UUID/root and ownership marker, stopped/inactive state, absent captured test processes, no open test-disk handles and available runtime-compatible lock. The installed Dev CLI's `delete <exact UUID>` succeeded through the manager's reviewed identity and separate storage helper; that helper performs the whole-root Foundation Trash move while holding the runtime-compatible lock. The original root is absent and the test profile/session are removed. No recursive removal or Trash emptying was used.

Both stable work VMs retain their sessions and all captured stable process identities. Stable configuration/settings hashes, installed app hashes and VM disk identities match a fresh pre-cleanup baseline. Other Dev profile/session records, defaults and all unrelated Dev filesystem metadata—including the imported factory—are unchanged. All six captured test runtime process identities remain absent. The imported factory, audit evidence and installed apps are retained.

**VERIFIED LIMITATION:** macOS privacy denied independent terminal enumeration of the Trash directory. The guarded native helper's successful Trash result and removal of the exact source root/profile are verified; the destination inode was not independently inspected. No extra permission was requested or granted. Private preflight, native command response and post-check receipts are retained under the acceptance run's `trash-cleanup/` directory. All prior native-feature limitations remain unchanged.
