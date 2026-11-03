# Guest Touch ID for sudo

This is separate from the manager’s Touch ID approval for reading a saved setup password. The manager never uses that password to pair a guest or approve sudo.

## Integration status

**DESIGN DECISION — 3 November 2026:** integrate the current sudo milestone after the signed build 26 validation run. Guest Touch ID remains off by default, pairing remains explicit, guest pairing status remains unknown to the manager, and managed 1Password unlock remains disabled. The remaining native cases below are follow-ups; they are not represented as completed tests.

**VERIFIED — automated/distribution evidence:** 231 manager tests, 66 script tests, both optimized policy modes, all 562 upstream Swift tests and isolated SSH checks pass. The signed/notarized `v0.11.0-dev.2` app and exact runtime were independently checked against published digests, original Apple-accepted archives, signatures/profile/entitlements, stapling and Gatekeeper.

**VERIFIED — user-reported native cases:** enrollment and password-free sudo, cancellation to Linux-password fallback, focus loss/fresh-request recovery, manual pause/resume, Mac sleep/wake, shutdown/restart without re-enrollment, independent A/B enrollment, delayed background rejection followed by focused success, and B disable leaving A functional. Read-only helper reports corroborate the recorded execution transitions. Both disposable test guests exited with status 0; their processes are gone and their roots were moved recoverably to Trash with approval.

**TO PROVE — retained native follow-ups:** cloned identical guest-ID isolation under a new manager UUID; the actual `lease-busy` branch (ordinary background rejection exercises focus gating); forced-stop/helper/manager crash paths; unavailable-biometry fallback; host opt-out/re-pairing; exact prompt counts and rapid focus transitions. Synthetic clone, process-lease, cancellation and admission fixtures remain separate evidence. The chronological records below preserve the scope and limits of each observation.

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
  "$test_cli" pause "$test_guest" || exit 1
  sleep 5
  "$test_cli" resume "$test_guest"
) &
```

The Mac terminal replies must show `ok: true` and states `paused`, then `running`; inspect the reply if either action fails. Immediately focus that guest and run `try-omarchy-touch-id-test`. Leave the native prompt untouched. The timer pauses after 15 seconds and resumes five seconds after a successful pause acknowledgement. The pending prompt must cancel; after resume, the old guest test must fail without a late Touch ID success. A new `try-omarchy-touch-id-test` request should then pass when the user approves it. If either CLI action fails, do not claim a lifecycle result; inspect the state and stop that test. This snippet does not stop/start/delete a VM, sleep the Mac or run two guests, and has not been executed by the agent.

## Focus-preserving Mac sleep/wake check

**VERIFIED — source/manual inspection:** the helper revokes its authentication epoch synchronously before host-sleep preparation. Wake allows a fresh epoch only for running, non-stopping execution; a manual pause remains separate. The local macOS `pmset` manual describes `sleepnow` as immediate system sleep, distinct from display sleep. These checks do not establish native cancellation/recovery.

**Manual procedure / TO PROVE:** begin with the selected test guest running, not manually paused. In a Mac terminal, schedule the transient host-sleep command without redirecting errors:

```sh
(
  sleep 15
  /usr/bin/pmset sleepnow
) &
```

Within 15 seconds, focus the guest and run `try-omarchy-touch-id-test`. Leave the native prompt untouched. The whole Mac should sleep; wake and unlock it normally after roughly 10–20 seconds. Mac unlock is separate from guest approval. Return to the guest and inspect the old test: it must report authentication failure without a guest-password fallback or late signed success. Then run `try-omarchy-touch-id-test` again and approve Touch ID; the fresh request should pass.

If the command reports an error or the Mac only turns off its display, do not claim a host-sleep result or add privileged commands automatically. Record the actual old/fresh guest test outcomes and distinguish user observations from helper state reports. This procedure does not change power settings, schedule an automatic wake, start/stop a guest, use experimental disk suspension or require a custom guest kernel. It has not been executed by the agent.

## Focus-preserving graceful-shutdown check

**VERIFIED — source inspection:** the existing CLI `stop --wait` requests shutdown and waits for the manager's retained session to reach matching terminal exit. The helper revokes authentication before requesting QMP `system_powerdown`; shutdown cannot re-enable its epoch. Ordinary runtime shutdown retains its existing timeout/cleanup policy; this test adds no `--force` or new force-stop action. These source checks do not establish native cancellation.

**Manual procedure / TO PROVE:** use the same explicitly selected test guest, initially running, and replace `TEST_VM` with its exact name or UUID. In a Mac terminal:

```sh
test_cli='/Applications/Omarchy VM Manager.app/Contents/MacOS/omarchy-vm'
test_guest='TEST_VM'
(
  sleep 15
  "$test_cli" stop "$test_guest" --wait --timeout 120
) &
```

Within 15 seconds, focus the guest and run `try-omarchy-touch-id-test`. Leave Touch ID untouched. At shutdown, the pending prompt must cancel, with no late approval or resurfacing prompt. The old test may print authentication failure, but shutdown can end the guest terminal first; a missing final line is not proof of either success or failure. Require the Mac CLI reply to report `ok: true`, `active: false`, normally `state: stopped`, and inspect any error/failure. A timeout does not authorize a manual force-stop or a passing result. Distinguish normal shutdown from the runtime's existing timeout fallback if that occurs.

After confirmed terminal exit, the user may launch that same test guest again through the manager. Once booted and focused, run `try-omarchy-touch-id-test` and approve Touch ID. It should pass without re-enrollment; no old-run prompt should reappear. Record observed cancellation, exit and fresh-run result separately. The agent has not executed this procedure, stopped/started a VM, read keys or controlled authentication UI.

## Two-VM manual setup and observation scope

**VERIFIED — read-only preflight:** the host reports 128 GiB RAM, 18 logical CPUs and macOS 27.0.1, with approximately 698 GiB free on the data volume. The current manager report has one active 4 GiB/4 CPU guest; adding two 4 GiB/4 CPU profiles fits the current aggregate limits. The proposed test names are unused. Existing CLI creation assigns fresh UUIDs, NAT and individual managed SSH endpoints; it rejects a conflicting name. These observations do not authorize agent-driven guest/storage/UI actions.

**Manual setup / TO PROVE:** create two fresh disposable manager-owned profiles, using enabled saved Guest Defaults for setup but omitting personal SSH-key inheritance and host folder/clipboard sharing. The user handles any protected setup-password approval locally. This command creates stopped profile metadata only; it does not include `--start`:

```sh
test_cli='/Applications/Omarchy VM Manager.app/Contents/MacOS/omarchy-vm'
for test_guest in 'Touch ID POC A' 'Touch ID POC B'; do
  "$test_cli" create "$test_guest" \
    --factory official --memory 4GiB --cpus 4 --disk 64GiB \
    --guest-touch-id on --clipboard off --share off \
    --owner-defaults on --inherit-default-public-key off || break
done
```

Check each reply for `ok: true`. Do not repeat a successful creation or overwrite another guest if a command fails. Launch A through the manager and wait for its first boot/setup to finish before launching B; startup may download the official factory image if the verified cache is unavailable. Keep existing guests untouched. Pair sudo Touch ID inside A with `try-omarchy-touch-id` and verify `try-omarchy-touch-id-test` passes. Leave B unpaired initially and report when both are running.

The next observations must distinguish background focus rejection from actual lease contention: current `ManagedAuthenticationEnvironment.begin` checks target focus before acquiring the nonblocking global lease. A background denial therefore does not demonstrate the `lease-busy` path. Independent enroll/disable/re-test exercises per-guest independence, but two fresh guest IDs do not prove isolation of a cloned identical guest ID under another manager UUID. The existing process/clone-identity fixtures remain separate synthetic evidence; a native copied-disposable-disk case needs a separately scoped copy procedure. Do not claim these stronger results from ordinary focus switching.

After the user-driven test run, shut down both disposable guests, confirm matching exits and absence of their captured helper/QEMU processes, then offer to move their verified stopped UUID roots to Trash under the compatible lock. No deletion or existing-guest changes are included in setup. No profile, factory, guest, pairing or permission action has been executed by the agent.

## Overlapping requests with one focused guest

**Manual procedure / TO PROVE:** with A and B independently enrolled and running, execute `sleep 15; try-omarchy-touch-id-test` in B's guest terminal as a foreground command (no `&`). Immediately focus A and run `try-omarchy-touch-id-test` before B's 15-second timer expires. Leave A's native prompt open for about 20 seconds, maintaining focus on A or its native authentication dialog, then approve A.

B's delayed request should fail without opening another Mac prompt or dismissing A's prompt. A should pass after its approval. Return to B and inspect its completed output; a host "Touch ID was not approved" denial distinguishes an exchanged host request from an earlier missing-TTY/guest-policy failure. Then run a fresh focused B test and approve it; B should pass. Record all three outcomes and any extra/queued prompt. Do not count a request that ran before A's prompt opened as an overlapping case.

The foreground delayed command preserves B's controlling terminal; no detached/background-shell input assumptions are needed. Source broker inspection checks `PAM_TTY` and root/sudo context before exchange, and the test disables password fallback. Since the host checks focus before acquiring its lease, the expected B denial is focus rejection. This procedure does not by itself establish native `lease-busy` contention or same-guest-ID key isolation. No guest command or native interaction was performed by the agent.

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


## Helper-reported manual pause/resume — 3 November 2026

**VERIFIED — read-only runtime report:** after the user ran the timed native procedure and questioned whether pause/resume worked, the manager's existing status report contains `Execution: paused (pause)` at `2026-11-03T04:35:48Z` followed by `Execution: running (resume)` at `2026-11-03T04:35:53Z`. Both records match the same currently active guest and launch session. Record only these state/timing tokens, without guest names, UUIDs, paths, process IDs or key identifiers. The helper reported the expected five-second pause/resume cycle; this is not an independent observation of a frozen guest display or of authentication cancellation. The agent read metadata only and sent no lifecycle command.

**DESIGN DECISION / TO PROVE:** in-memory Pause/Resume retains RAM and is separate from experimental suspend-to-disk/hibernation; it does not need a hibernation-enabled guest kernel. A paused guest display may retain its last frame. The manual snippet suppressed CLI replies, obscuring success as well as errors; show those replies in future runs and require `ok: true`, `state: paused` followed by `state: running`. Pending Touch ID cancellation, old-test failure and fresh-request recovery in this lifecycle cycle await explicit user confirmation. Other lifecycle/multi-VM tests remain **TO PROVE**.


**VERIFIED — scoped user clarification, 3 November 2026:** the user noticed the native Touch ID prompt cancel during the pause/resume test sequence, but could not confirm the other outcomes. Record observed prompt cancellation only, alongside the previously recorded helper pause/resume acknowledgements. The exact timing/cause of cancellation was not independently observed. **TO PROVE:** the old password-fallback-disabled guest test returned failure after resume without late authentication, and a fresh request subsequently succeeded. Do not mark the complete lifecycle cancellation/recovery test passed. No further pause/resume, guest action or authentication interaction was performed by the agent.


## User-confirmed pause cancellation and recovery — 3 November 2026

**VERIFIED — user report plus helper acknowledgements:** following the previously recorded five-second pause/resume cycle and observed native prompt cancellation, the user supplied both guest test outputs. The old `try-omarchy-touch-id-test` reported denial, no supplied guest password and authentication failure with password fallback disabled. A fresh invocation then reported successful sudo authentication without a guest password. Record the described manual pause/resume cancellation/recovery case as passed in the build 26 test sequence: the old request failed and a fresh request succeeded. This supersedes the immediately preceding unknown old-test/fresh-request outcomes. The agent did not operate the guest or observe exact native timing; no key, password or personal identifiers are recorded.

**TO PROVE:** Mac sleep/wake, shutdown/forced-stop/crash cancellation, rapid focus transitions/exact prompt counts, unavailable-biometry fallback, re-pairing and two-VM contention/key isolation remain pending. The passed manual case does not establish all lifecycle behavior or grant agent-driven native interaction.


## User-confirmed Mac sleep/wake cancellation and recovery — 3 November 2026

**VERIFIED — user report:** in the build 26 verification sequence, the user reported that the Mac slept and woke successfully, the old password-fallback-disabled guest test failed, and a fresh Touch ID test passed. Record this described manual host sleep/wake denial/recovery case as passed. The statement establishes these test outcomes; it does not independently measure prompt timing/count or every host sleep mode.

**VERIFIED — separate read-only helper evidence:** the manager's existing report for the same currently active guest and launch session contains `Execution: host-sleeping` at `2026-11-03T04:44:47Z` and `Execution: running` at `2026-11-03T04:45:04Z`. These are helper-reported execution transitions, not an independent measurement of hardware sleep duration. Only state/timing tokens are retained; guest names, UUIDs, paths, process IDs, credentials and key identifiers are excluded. The agent sent no sleep, wake, guest-control or authentication command and changed no power setting.

**TO PROVE:** shutdown/forced-stop/crash cancellation, rapid focus transitions and exact prompt counts, unavailable-biometry fallback, re-pairing and two-VM contention/key isolation remain pending. This user-confirmed case supersedes the prior pending sleep/wake result only for the described sequence and does not grant agent-driven native interaction.


## Shutdown exit confirmed; authentication outcome pending — 3 November 2026

**VERIFIED — user CLI output:** the user supplied the timed `stop --wait` reply reporting `ok: true`, `active: false` and `state: stopped`. Record only these state/result fields; exclude the supplied guest/request UUIDs, name, endpoint and other personal/profile identifiers.

**VERIFIED — separate read-only runtime report:** the latest shutdown sequence contains `Stopping` at `2026-11-03T04:48:21Z` and matching `Exited (0)` at `2026-11-03T04:48:22Z` for the same VM and old launch session. At inspection, that guest's current row was already active and running again. These reports support successful shutdown and matching terminal cleanup, rather than a wait timeout; they do not independently prove native prompt cancellation or post-restart guest authentication. No agent-driven stop/start or authentication action occurred.

**TO PROVE:** whether the pending native prompt cancelled during this shutdown, whether any old prompt resurfaced, and whether a fresh post-restart `try-omarchy-touch-id-test` passes without re-enrollment. Do not mark the complete shutdown cancellation/recovery case passed from the stopped JSON alone. Other crash/forced-stop and two-VM checks remain pending.


## User-confirmed shutdown cancellation and restart recovery — 3 November 2026

**VERIFIED — user report plus terminal-exit evidence:** the user confirmed that the pending Touch ID prompt cancelled during shutdown and that a fresh `try-omarchy-touch-id-test` passed after restarting the same guest without re-enrollment. Together with the supplied `stop --wait` reply (`ok: true`, stopped, inactive) and matching old-session `Exited (0)` report recorded above, mark this described manual shutdown cancellation/restart recovery case passed in the build 26 sequence. This confirmation supersedes the preceding pending prompt/fresh-test outcomes. The agent did not stop/start the guest, operate native authentication, read keys/credentials or independently observe prompt timing. No personal/key identifiers are retained.

**TO PROVE:** forced-stop/crash cancellation and extended late-prompt/replay scenarios, exact prompt counts/rapid focus transitions, unavailable-biometry fallback, re-pairing and two-VM contention/key isolation remain pending native observation. The passed single-guest shutdown case does not establish every lifecycle failure path or authorize agent-driven VM, factory, storage or UI operations.


## User-confirmed independent two-guest enrollment — 3 November 2026

**VERIFIED — user reports:** the user completed A's enrollment/test, then reported B's password-fallback-disabled test failed without a Mac prompt while B was unpaired. After explicit enrollment of B, the user confirmed B's built-in test passed and A's subsequent fresh test still passed. Record independent guest enrollment and no observed interference from B's enrollment with A. The unpaired failure alone is not proof of host UUID-key isolation: the fresh guests have distinct guest IDs and their PAM setup differs before enrollment.

**VERIFIED — read-only manager report:** both proposed disposable test profiles are active/running, with distinct UUIDs and distinct storage roots. Only these booleans and anonymized A/B labels are retained; no profile/root/process/key identifiers or credentials are recorded. The agent did not create, boot, enroll, alter or control either guest.

**TO PROVE:** overlapping focus routing, actual native `lease-busy` contention, cross-guest disable/re-enrollment effects and cloned-identical-guest-ID isolation remain untested. Existing synthetic cross-process lease and cloned-ID namespace fixtures remain separate evidence.


## User-confirmed two-guest routing and disable independence — 3 November 2026

**VERIFIED — user reports:** after independently enrolling A and B, the user confirmed the overlapping procedure's three outcomes: A's pending test passed, B's delayed request failed, and a fresh focused B request passed. The user then confirmed B's disable operation reported enrollment removed from the guest and Mac (not local-only cleanup), B's password-fallback-disabled test failed without a Mac prompt, and A still passed afterward. Record these described manual two-guest routing and disable-independence cases as passed for build 26. No exact prompt count or native diagnostic code was supplied; do not promote the background failure into proof of the `lease-busy` branch.

**VERIFIED — read-only cleanup preflight:** both disposable profiles remain running. The actual running manager's bundle metadata confirms 0.11.0 (26), `v0.11.0-dev.2`. A read-only probe built from the pinned `KernelProcessIdentity` implementation captured eight current processes for each guest, including its QEMU executable and distinct owning `--run-vm` helper. Each association is bound to the exact open disposable disk and validated manager UUID root. PID, executable and kernel birth (seconds/microseconds), session and root inode/device identities are held only in a private ignored cleanup ledger; none are published. No key/credential or disk contents were read, and no guest/UI/lifecycle operation was performed by the agent. Early static-executable assumptions did not identify the QEMU wrapper; the successful capture handles upstream naming variants and verifies exact disk ownership and helper ancestry rather than guessing a PID.

**TO PROVE / cleanup pending:** native identical-guest-ID isolation under a new manager UUID, actual `lease-busy` contention, exact prompt counts/rapid focus transitions, unavailable-biometry fallback, re-pairing and forced-stop/crash paths remain separate from these results. The existing synthetic cloned-ID and cross-process lease fixtures remain verified evidence, not native proof. The next action is user-driven shutdown of A and B, then read-only matching-exit/process verification and an offer to move the verified stopped UUID roots to Trash. No existing guest or storage is included, and no deletion is authorized by recording the test results.


## Two-VM test guests stopped and verified — 3 November 2026

**VERIFIED — user report and read-only cleanup audit:** the user reported both disposable guests stopped. Their captured launch sessions have matching `Exited (0)` records: A at `2026-11-03T05:14:42Z`, B at `2026-11-03T05:14:43Z`. Both profiles are stopped/inactive with no current session. Exact PID/executable/kernel-birth comparisons show all eight captured processes per guest have exited (16 total), including QEMU and each owning run helper. A narrow open-file audit of the two exact disks finds no remaining runtime or other open-disk processes. Both private manager UUID roots retain their captured device/inode identities, ownership and safe root type; no protected suspended-session marker exists.

**DESIGN DECISION — optional Trash cleanup:** offer moving only A/B through the manager's normal confirmed deletion workflow, which rechecks stopped admission and storage identity and uses the runtime-compatible lock before Trash. The user has not yet selected Trash versus retaining the stopped profiles. No profile/root was deleted or moved, no other guest was controlled, and no macOS permission was granted by the agent. Private operational identities remain in the ignored cleanup ledger; public evidence contains only anonymized labels, state/timing and counts. This completes shutdown/process cleanup of the manual run independently of the optional storage choice.

**TO PROVE:** native cloned-identical-guest-ID UUID isolation, actual `lease-busy` contention, exact prompt counts/rapid focus transitions, unavailable-biometry fallback, re-pairing and forced-stop/crash cases remain separate pending gates. Do not promote the successfully completed manual cases into a claim that every native branch has been observed.


## Approved disposable-guest Trash cleanup completed — 3 November 2026

**USER AUTHORIZATION / VERIFIED:** after matching successful exits, no remaining captured/runtime disk processes and unchanged stopped UUID roots were verified, the user explicitly selected moving only disposable A and B to Trash. Recheck stopped manager admission and captured root inode/device identity before each single-root operation, then invoke the installed manager's normal guarded deletion by the captured UUID. The manager's existing workflow performs its stopped/protected-state/identity/tree checks and runtime-compatible locking; no direct recursive erase is used.

**VERIFIED — post-operation checks:** both manager operations succeed, both registry profiles are absent and both original VM paths are absent. Each default-name Trash destination is independently present with the exact captured directory inode/device identity, confirming recoverable moves. A final kernel-identity check still finds none of the 16 captured runtime processes alive. Only the two approved test UUIDs were targeted; no other guest, factory, saved default, native permission or UI was changed by the agent. No guest key/credential or disk contents were read. Private operational receipts and process identities remain ignored, with no identifiers published.

**Completed scope / TO PROVE:** this closes shutdown/process/storage cleanup of the guided build 26 validation run. The user-confirmed enrollment, password fallback, focus recovery, manual pause, Mac sleep/wake, shutdown/restart, two-guest routing and cross-guest disable cases retain their exact recorded scope. Native cloned-identical-guest-ID isolation, actual `lease-busy` contention, precise prompt counts/rapid transitions, unavailable-biometry fallback, re-pairing and forced-stop/crash scenarios are not implied by these results and remain pending unless separately scoped. No additional native run or copied disk was started.
