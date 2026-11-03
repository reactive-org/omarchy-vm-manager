# Guest Touch ID for sudo

This is separate from the manager’s Touch ID approval for reading a saved setup password. The manager never uses that password to pair a guest or approve sudo.

## Use

Shut down the guest, edit it and select **Allow Touch ID inside this VM**. Save and start it on the next authorized run. The setting defaults off, including profiles saved by older versions. A running, paused, stopping, failed-but-active or suspended guest cannot be edited. Disabling the host setting stops the bridge at the next start; it does not silently remove guest enrollment or PAM rules.

Inside the focused guest, choose **Setup → Security → Touch ID for sudo**, or run `try-omarchy-touch-id`. Upstream asks for the guest password and explicit Touch ID enrollment before adding its sudo rule. Use its test/re-pair/disable actions there. Pairing state is unknown to the manager. Moving/cloning a disk under another manager UUID, moving Macs/accounts or changing enrolled fingerprints requires explicit re-pairing. A cloned guest ID cannot select another UUID’s host key or a personal Try Omarchy key.

Touch ID denial, cancellation, prompt contention or unavailable authentication falls back to the **Linux guest password**. The manager’s setup-password flow has a different Mac-login-password fallback. No fingerprints cross into the guest. Approval binds sudo’s user/service/TTY context, not the exact command, and is not a login, screen-unlock or general authentication grant.

CLI examples (configuration only):

```sh
omarchy-vm create Work --guest-touch-id on
omarchy-vm update UUID --guest-touch-id off
```

JSON configuration uses `"guestTouchID": true`. Status contains `guestTouchID.enabled`, `hostBridge` (`disabled`, `next-start`, `requested`, `unavailable`) and `guestPairing: "unknown"`. Requested means the host bridge was included for the run; it is not a bridge-health handshake, enrollment report or successful authentication claim.

## Host policy and provenance

**DESIGN DECISION / PRIVATE COUPLING:** the reviewed host configuration carries manager-selected VM/run UUIDs. Keys live under `Application Support/Omarchy VM Manager/Native Authentication Keys/<VM UUID>/<validated guest ID>.key`. Guest data never selects a directory. Private directory, file ownership and symlink checks fail closed. Personal Try Omarchy keeps its upstream key namespace and behavior.

A shared nonblocking `flock` lease serializes manager guest prompts. Contention returns immediately; it does not queue another prompt. Ownership retains the VM/run identity and checks exact captured QEMU/controller executable and PID birth identities. Kernel closure releases the lease after a crash; no stale lock file is stolen or unlinked. Upstream protocol 3, Secure Enclave signer, guest broker, nonce/context signing and 15-second approvals remain in use.

Pause, sleep, shutdown and exit revoke a per-run epoch before changing execution. Resume creates a new epoch only for a running, non-stopping guest. An independent 50 ms monitor cancels a pending context on revocation, process loss, stop or loss of focus. Cancellation is latched for that request. The Apple-signed LocalAuthentication UI agent at its system framework path may receive focus during a prompt. The existing strict QEMU focus/process check still runs after signing. Native focus transitions faster than the polling interval and OS-specific prompt presentation need observation; these checks do not establish native success.

The host admission requires `managedAuthenticationVersion: 1` from exact hash/inventory-verified provenance and the explicitly reviewed authentication package identity. Protocol 1 and owner setup compatibility alone confer no authentication capability. Existing signed locks describe historical bytes and fail source compatibility after this helper change. Signing/notarization/publication require a separate request.

**VERIFIED — package inspection:** the official archive SHA-256 is `ddef5befc16d2fe7a7ef7bc1e56c3ce5c8e89df83d3b244525ebe6d32fc75c5b`; lean is `9fc986521b67cfa9e891fd826453553f1e2e4a319e6edb1302c760f1e22a2211`. Nine authentication-named tools/rules/units match the pinned upstream source byte for byte in both archives. Both declare Python, OpenSSL, GTK 3, polkit and Python GObject dependencies. Existing full-package compatibility checks remain required. The host extension does not change the guest tree, package or authentication wire protocol. Package evidence does not measure an installed disk: sudo/PAM modules, completed package installation and runtime dependencies remain TO PROVE.

## Native test plan — separate approval required

Do not execute this plan in the source implementation session. Obtain explicit approval for two new manager-owned disposable UUID roots, factory download/guest boot if needed, guest pairing/PAM changes and native interaction. Record app source/build, runtime source/lock/archive identities, macOS version and anonymized test labels; exclude clipboard, passwords and guest secrets from logs.

1. Create two fresh UUID profiles A and B with NAT and explicit bridge lists. Confirm default-off prevents a guest Touch ID prompt and preserves Linux password sudo. Stop both before enabling the setting.
2. Enable A, start and pair manually inside A. Test `sudo -k; sudo true` for Touch ID success, cancel and unavailable-biometry fallback. Enter the Linux password in the guest. Check prompt count, product/guest name and no setup-password approval reuse. Test guest disable and re-pair explicitly.
3. Enable and pair B independently. Make overlapping requests from A and B. Verify only the focused eligible guest prompts, the lease loser immediately gets password fallback and no delayed prompt appears after A completes. Switch focus between A, B, another app and the native authentication dialog. Test rapid switches and return-to-guest behavior before/after approval.
4. During a pending prompt, exercise manual pause/resume, shutdown, forced stop, Mac sleep/wake and approved manager/helper/QEMU crash scenarios separately. Verify cancellation, no late signed success, no prompt resurrection on resume and a fresh request works only with a new valid run. Confirm exact `.exited` events before releasing manager client/resource reservations. Test stale epoch/run and PID birth rejection through fixtures; never kill an unrelated process to force PID reuse.
5. With separately authorized copied disposable guest storage, test a cloned guest ID under a different manager UUID: existing pairing must not succeed until explicitly re-paired. Confirm disabling one guest leaves the other’s enrollment intact. Test re-pairing after fingerprint changes only with separate approval for that macOS setting change.
6. Shut down every test guest. Confirm matching `.exited` and no remaining helper/QEMU processes using captured exact identities. Offer to move the verified stopped UUID roots to Trash under the compatible lock. Never recursively erase VM storage or remove personal Try Omarchy keys.

## Focus-preserving pause/resume check

**VERIFIED — source inspection:** the bundled CLI sends pause/resume through the manager's existing command socket without activating its window; if the manager is unavailable, its fallback opens the app in the background. The upstream `try-omarchy-touch-id-test` clears sudo's timestamp and uses a failing askpass helper, disabling Linux-password fallback for that test. These source checks do not prove native lifecycle cancellation.

**Manual procedure / TO PROVE:** use only an explicitly selected test guest, with its manager already running. Clicking the manager during a prompt can trigger the already-tested focus cancellation before pause; use a background command to isolate the lifecycle transition. In a Mac terminal, replace `TEST_VM` with the exact test guest name or UUID:

```sh
test_cli='/Applications/Omarchy VM Manager.app/Contents/MacOS/omarchy-vm'
test_guest='TEST_VM'
(
  sleep 15
  "$test_cli" pause "$test_guest" >/dev/null || exit 1
  sleep 5
  "$test_cli" resume "$test_guest" >/dev/null
) &
```

Immediately focus that guest and run `try-omarchy-touch-id-test`. Leave the native prompt untouched. The timer pauses after 15 seconds and resumes five seconds after a successful pause acknowledgement. The pending prompt must cancel; after resume, the old guest test must fail without a late Touch ID success. A new `try-omarchy-touch-id-test` request should then pass when the user approves it. If either CLI action fails, do not claim a lifecycle result; inspect the state and stop that test. This snippet does not stop/start/delete a VM, sleep the Mac or run two guests, and has not been executed by the agent.

## Optional 1Password follow-up

The upstream package already ships its narrowly scoped polkit agent, password dialog and disabled service unit. This sudo milestone refuses `onepassword-unlock` in manager-scoped helpers. A follow-up must deliberately enable that operation and validate its existing signed context/cancellation boundary before native testing.

After sudo validation and separate authorization: install/sign in to 1Password in a disposable guest, turn on its **Unlock using system authentication**, then use **Setup → Security → Touch ID for 1Password** or `try-omarchy-onepassword-touch-id enable`. Validate the fingerprint action, account-password-after-restart policy, guest Linux-password fallback and guest PAM lockout behavior. Do not grant blanket polkit authorization or replace the session-wide agent. See the pinned upstream [sudo guide](../Vendor/try-omarchy/manual/touch-id.md) and [1Password architecture](../Vendor/try-omarchy/docs/onepassword-touch-id.md).

## No-VM check evidence

**VERIFIED — 3 November 2026:**

- `make prepare-source`: reconstructs clean source `8d5015ec740aad5417b601e05d451b28ed45d573` from stock v1.3.0 plus patch SHA-256 `d27bd42e8af1a66ef106001c7f1ca3e516532e2ed08d45771c5200c67498f647`. The guest tree is identical to `033d2460dc44796afeb6d08b6a32aaf51febf8be` (tree `aa461dab54d5d6625537ef506259d4e5155c83ba`).
- `make patched-kit REUSE_GUEST_PACKAGE_KIT=...`: verifies the complete previous kit, unchanged guest sources/package, source-built release helper and all 22 ad-hoc Mach-O signatures through upstream kit verification. Final archive SHA-256 `ec002c2b241454d7430729ebf850cb6f58612db2b96b8a6c8c30f2f6d64e3ded`; source-lock SHA-256 `91223707e872d9113a5b54ddf83a2d09fc9ebb65f9e23e3a377d657bc3c0f0e6`. The unchanged package was copied from the previously verified local kit; no image/package download or guest launch occurred.
- `make test test-build-policies app verify-bundle`, followed by `make test` after adding four guest-verifier fixtures: **229 manager Swift tests in 38 suites**, **59 script tests**, two admission/credential-policy checks in each optimized mode, Swift app/CLI/storage-helper builds, ad-hoc app assembly and uninstalled bundle verification pass. The final UI copy was included in the debug app build. Bundle verification reports exact locked inventory, NAT-only, no bundled factory image, no host preflight and `vmLaunchEnabled: false`.
- `make test-upstream`: **561 Swift tests in 110 suites**, guest/package, signing-payload contracts, script and shell run-mode fixtures, compatibility and relocation checks pass. These are synthetic/local fixtures, including the fixture image-download tests. An earlier sandboxed upstream Swift run could not exercise local sockets and host framework properties; the final complete run with the needed local access passes.
- New tests cover profile default/round-trip/persistence, strict CLI/config input, end-to-end command creation/status, capability/package refusal, explicit scoped bridge configuration and edit refusal until matching exit. Upstream additions cover cloned guest IDs, unsafe paths/symlinks, cross-process prompt contention and lease release, stale PID birth identities, epoch revocation, focus/stop/process/pause cancellation, latched late-result rejection, monitored cancellation while a signer is blocked, scope parsing and missing-controller fail-closed behavior. Existing upstream signature/context and prompt-timeout tests remain in the complete suite. Four manager script tests also exercise the unchanged guest broker with disposable software P-256 keys, proving signed context tampering, expired/future approval, request replay, unsigned boolean and wrong-enrollment-key refusal. These fixtures neither access Secure Enclave keys nor enroll anything.
- The existing factory compatibility suite passes with the unchanged guest contract. Format-2 reviewed lean factories keep independent package compatibility; legacy manifests retain exact-runtime binding and may require a separately prepared compatible bundle. No existing receipt/factory/profile/disk is migrated or rewritten.
- `git diff --check` passes. Original checkout and historical signed locks are unchanged. No real signing/notarization identity, credential read, permission grant, installed app change, UI control, real enrollment, guest PAM change or VM launch was performed.

**TO PROVE:** all native multi-VM authentication, actual Mac dialog focus, success/fallback/cancellation, installed guest dependency availability, lifecycle/crash behavior and UI layout. The app bundle remains local and uninstalled. 1Password unlock is deliberately deferred. Native testing and release publication are separate approval steps.


## Signed verification candidate

[v0.11.0-dev.1, version 0.11.0 (25)](https://github.com/reactive-org/omarchy-vm-manager/releases/tag/v0.11.0-dev.1) is Developer ID signed, notarized and independently verified. The app source remains `01631ee`; runtime source remains `8d5015ec740aad5417b601e05d451b28ed45d573`. The [release record](Prereleases.md#published-guest-sudo-touch-id-candidate--3-november-2026) distinguishes successful distribution checks from native behavior, which remains **TO PROVE**. No VM was launched for release verification. Guest sudo Touch ID is off by default; 1Password remains deferred.


## Guest authentication main-loop regression — 3 November 2026

**VERIFIED — user report and read-only inspection:** enrollment in signed 0.11.0 (25), `v0.11.0-dev.1`, returns “Touch ID was not approved” without a macOS prompt. The user reproduced it with a custom kernel and the official Try Omarchy factory image. Installed app/runtime identities match the published candidate. Read-only process and gate metadata show a live authentication helper, matching live parent/target processes and a private regular per-run epoch file. The manager key namespace exists with no enrolled key files for the active guest. No key contents, credentials, personal identifiers or guest disk contents were read or logged. The generic guest denial does not establish its host cause.

**VERIFIED — source regression / DESIGN DECISION:** the authentication bridge reads its guest channel and waits synchronously for LocalAuthentication on the main thread. Unlike the previously fixed clipboard bridge, it does not service the main run loop or serialize AppKit foreground reads there. Share the existing headless clipboard run-loop implementation with authentication, move its blocking reader/prompt wait to a worker and perform foreground/active-process and trusted Apple authentication-UI checks on main. Preserve exact process birth/executable identities, pre/post QEMU focus, revocable epochs, immediate cross-guest lease refusal, biometrics-only approval, signed protocol 3 and late-result rejection. Guest package sources and wire protocol are unchanged. This corrects a demonstrated scheduling defect; native attribution and successful enrollment remain **TO PROVE**.

**DESIGN DECISION — diagnostics:** emit only a closed set of non-secret host status codes for focus, process, epoch, lease, biometric availability, pairing and signing failures. Read complete whitelisted lines from the current client's bounded stderr for a manager notice and additive JSON status; never display arbitrary guest/error text. Successful host approval clears the old denial notice without asserting guest pairing or readiness. Diagnostics do not drive lifecycle or release reservations; only the matching `.exited` does.

**VERIFIED — initial regression checks:** 562 upstream Swift tests in 111 suites pass, including a standalone executable built from the actual authentication run entry point, shared run-loop adapter and prompt wait. Synthetic providers require AppKit-facing reads on main and exercise asynchronous main-queue completion, focus loss/return, inactive/unavailable targets and stale process refusal while the reader runs on a worker. Existing clipboard main-loop regression checks remain passing. These checks invoke no native prompt, Secure Enclave enrollment or VM.

**TO PROVE / authorization boundary:** native enrollment and sudo success/fallback, prompt presentation/count, native focus transitions and cancellation still require a new signed candidate and user testing. This investigation changes source and disposable build outputs only. It does not authorize changing the installed app, restarting or modifying the running guest, granting permissions, reading saved credentials, enrolling keys or controlling authentication UI. Historical signed runtime evidence remains preserved.

**VERIFIED — rebuild finding:** the first clean runtime rebuild exposed a pre-existing parallel test race: a child between fork and exec can briefly retain a close-on-exec lease descriptor after the owner closes it. The monitor fixture now bounds eventual reacquisition after cancellation; production lease acquisition remains a single nonblocking attempt. Preserve specific monitor rejection diagnostics when cancellation increments the signer generation. The failed attempt and final build logs are retained in local temporary build logs.

**DESIGN DECISION — next verification candidate:** prepare `v0.11.0-dev.2`, manager 0.11.0 (26), with the corrected source and a newly built pinned runtime. Retain the published dev.1 artifacts and versioned signed runtime lock unchanged. Native testing requires a signed/notarized build; no local real identity, installed app or user guest is used during preparation. Publication and CI credential use will follow the session authorization boundary.


**VERIFIED — final no-VM candidate checks:** `make patched-kit REUSE_GUEST_PACKAGE_KIT=...` completes with exact source `37c635f8992a9e19cc99696542bf061baff804c0`, patch SHA-256 `b4184dfdd39de0dfa7e0796e037db675fe372e1b1349216cfb8ac5b7d866c46e`, development ZIP SHA-256 `388144ccce86a6a04c383fb7893b163580d3722580bebd447330abbc3742494d` and source-lock SHA-256 `328acd039129cd6d5dae139cd1f426e18c50cfeaf91268e63541b6186686fd9d`. Complete inventory and all 22 ad-hoc Mach-O signatures verify. The guest-package/LICENSE trees and the reviewed package archive are unchanged. `make test test-build-policies app verify-bundle` passes 231 manager Swift tests in 38 suites, 66 script tests, both optimized admission/credential-policy modes, the app/CLI/storage helper build and uninstalled bundle verification (`vmLaunchEnabled: false`). `make test-upstream` passes all 562 Swift tests in 111 suites plus package, script, shell, compatibility and relocation fixtures. An early manager run started before the new runtime lock was written and correctly failed the old-lock/new-patch contract; the complete final run uses the matching generated lock/pin and passes. The earlier monitor-fixture failure is consistent with transient fork/exec descriptor inheritance under parallel fixtures; this is an inference, not an observed production authentication cause. No production retry/queue or weakened authentication check was introduced.

**DESIGN DECISION — signed runtime transition:** after byte-for-byte equality with `Config/SignedRuntimes/v0.11.0-dev.1.lock.json`, remove only the active `Config/TryOmarchySignedRuntime.lock.json`. The changed helper requires a fresh signed runtime; historical accepted dev.1 provenance cannot authorize it. Preserve every versioned signed lock and all published releases. Candidate `v0.11.0-dev.2`, 0.11.0 (26), is locally prepared and tested. CI signing/notarization/publication and native verification remain **TO PROVE**; no local real signing identity or installed app/guest was used.


## Signed run-loop fix available

[v0.11.0-dev.2, manager 0.11.0 (26)](https://github.com/reactive-org/omarchy-vm-manager/releases/tag/v0.11.0-dev.2) contains the host run-loop/focus-read fix and non-secret denial notices. CI and independent downloaded-package checks pass, including accepted original archives and all signature/profile/notarization/Gatekeeper gates. See [the release evidence](Prereleases.md#published-guest-authentication-run-loop-fix--3-november-2026). Restart the test guest and manager manually when replacing the app. The subsequent user-reported enrollment/password-free-sudo result is recorded below. Other native behavior remains **TO PROVE**; release verification launched no VM or authentication UI.


## User-reported guest enrollment and sudo success — 3 November 2026

**VERIFIED — user report:** in the `v0.11.0-dev.2` verification sequence, the user supplied guest console output reporting successful host-key enrollment and a successful sudo authentication test with guest-password fallback explicitly disabled. Record this as user-reported successful guest enrollment and password-free sudo on this test guest. Read-only installed-app metadata confirms 0.11.0 (26), `v0.11.0-dev.2`. Do not retain the host key identifier, guest username, password input or other personal identifiers. The agent did not access keys/credentials, control authentication UI, change the installed app/guest or perform the test.

**TO PROVE:** exact native prompt presentation/approval and prompt counts were not independently observed; the console itself makes its Touch ID interpretation conditional on user approval of the prompt. Other guests, Linux-password fallback after denied/unavailable biometrics, focus changes/cancellation, contention, pause/sleep/wake/shutdown/crash and re-pairing remain untested natively. This result supersedes pending enrollment/password-free-sudo evidence only for the user-reported happy path; it does not prove that every preceding denial had the same cause.


## User-confirmed fallback, focus cancellation and recovery — 3 November 2026

**VERIFIED — user report:** after being given three single-guest checks in the build 26 verification sequence, the user confirmed them: (1) a fresh sudo request with Touch ID cancelled permits the Linux guest password fallback; (2) switching to another app during a pending request prevents that old Touch ID request from succeeding later; (3) returning to the guest and making a fresh request permits Touch ID authentication again. Scope this confirmation to those three described checks on the current test guest. The agent did not independently observe authentication UI, perform the tests, inspect secrets or change any VM. No personal/key identifiers are recorded.

**TO PROVE:** pause/resume, Mac sleep/wake, shutdown/forced-stop/crash cancellation, rapid focus transitions and exact prompt counts, unavailable-biometry fallback, re-pairing and two-VM contention/key isolation remain pending native observation. This report supersedes the earlier pending cancel-to-password fallback, ordinary focus-loss cancellation and fresh-request recovery claims only for the user-confirmed manual cases. It does not establish lifecycle or multi-VM behavior or authorize agent-driven native interaction.
