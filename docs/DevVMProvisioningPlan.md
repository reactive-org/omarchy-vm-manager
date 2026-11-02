# Bundled dev-vm implementation plan

Status: planning only; implementation has not started.

Date: 2 November 2026 (Australia/Melbourne).

Integrate a pinned copy of dev-vm into Omarchy VM Manager so users can create and configure a developer workstation through the native app or CLI without a separate dev-vm checkout. Show the actual provisioning process in an interactive terminal, including guest authorization prompts.

**DESIGN DECISION — user direction:** bundle the dev-vm engine first, assume Homebrew is available, and enable provisioning features according to compatible host tools and their capabilities. Bundling Python and Ansible is a later packaging improvement. Do not install or upgrade host tools automatically.

Saving this plan authorizes documentation only. Implementation, host dependency installation, signing credential use, permission grants, UI takeover and real guest operations require their applicable authorization. Existing VM and runtime safeguards in [intent.md](../intent.md) and [AGENTS.md](../AGENTS.md) continue to apply.

## Scope and ownership

The manager drives the workflow:

```text
Preview setup
  → Create profile and launch through VMManager
  → Complete owner setup and verify SSH
  → Request guest setup authorization in the terminal
  → Apply developer setup
  → Revoke authorization and verify cleanup
  → Restart through VMManager if included in the approved plan
  → Reverify SSH and check the workstation
```

Try Omarchy continues to own the VM implementation. VMManager owns lifecycle, storage admission, resource and port reservations, and authenticated guest identity. dev-vm owns workstation preferences, feature resolution and configuration through Omarchy and mise. The UI and CLI operate the same manager-owned jobs.

The first release includes bundled presets, explicitly selected local setup folders, developer features, themes, layouts, dotfiles, preview/apply/check, deliberate reapplication and a live provisioning terminal. Use official or already imported compatible factories through existing manager admission.

Defer remote repository cloning, custom factory building in the app, automatic third-party collection installation, concurrent provisioning and a general-purpose SSH terminal. Docker remains conditional on the separate image-building workflow. Do not require Git merely to use bundled engine assets or local setup folders.

The terminal is a scoped exception proposed for the embedded-terminal non-goal in intent.md. Record that exception and the new orchestration decisions in intent.md before implementation; do not interpret this planning document as changing the current launch or permission policy.

## Existing source evidence

**VERIFIED — source inspection during planning:** the manager has owner setup, managed authenticated SSH, a shared command service and a private same-user Unix socket. Its current command transport returns one JSON response per request; it does not provide terminal streaming. See [GuestCommands.swift](../Sources/OmarchyVMManagerCore/GuestCommands.swift), [CommandSocket.swift](../Sources/OmarchyVMManagerCore/CommandSocket.swift) and [CLI.md](CLI.md).

**VERIFIED — local dev-vm source inspection:** standard bootstrap does not require Ansible, while feature playbooks and external setup application do. YAML parsing requires PyYAML, which the current loader can locate through an existing Ansible runtime. The checkout pins Python 3.14.10 and ansible-core 2.21.5 for development; those are compatibility reference points, not established minimum host versions for this feature. Ansible currently uses checkout-relative temporary storage.

**VERIFIED — local dev-vm implementation:** setup enables a native persistent passwordless guest sudo grant, then revokes it and clears cached authentication. The grant has no automatic expiry and can survive a reboot. Do not describe it as a 60-minute grant. Failure to verify revocation must remain actionable.

dev-vm source and reference documentation:

- [Repository](https://github.com/reactive-org/dev-vm)
- [Prerequisites](https://github.com/reactive-org/dev-vm/blob/main/README.md)
- [External setup repositories and task trust](https://github.com/reactive-org/dev-vm/blob/main/docs/omarchy-setup-repositories.md)
- [Current controller](https://github.com/reactive-org/dev-vm/blob/main/scripts/omarchy_vm_manager.py)

These links identify the source projects. Implementation must select and record an immutable engine commit and artifact inventory rather than execute a moving branch.

## Homebrew dependency discovery and feature gates

Create a dependency-provider abstraction so the first host-tool implementation can later be replaced by a private bundled runtime. Keep ordinary VM management available when provisioning prerequisites are unavailable.

| Capability | Requirements | Missing or incompatible behavior |
| --- | --- | --- |
| Homebrew installation guidance | Discovered executable with a successful bounded probe | Show Homebrew unavailable; never bootstrap it automatically |
| Basic provisioning and JSON planning | Compatible Python, system Bash and required system OpenSSH tools | Disable affected provisioning operations |
| YAML setup files | PyYAML importable in the selected Python runtime | Disable YAML input; retain JSON when supported |
| Developer features and external setup application | Compatible ansible-playbook and ansible-inventory, their Python dependencies and supported guest prerequisites | Disable application; retain data-only previews where possible |
| Git-based setup retrieval, deferred | Git and the explicitly requested repository access | Gate retrieval only |
| GitHub-star theme selection | Authenticated gh or an explicitly configured token | Disable this selector; retain direct theme selection |
| Custom factory building, deferred | Docker CLI, reachable ARM64 Linux engine and the builder's requirements | Keep unavailable in the first integrated release |

Discover tools without assuming a GUI launch inherits the user's shell PATH. Search explicit user overrides, known Homebrew paths such as /opt/homebrew/bin and /usr/local/bin, and a controlled PATH fallback. Query a discovered brew executable for its prefix when necessary. Do not launch a login shell, source shell configuration, execute brew shellenv output or scan credentials.

For every dependency, record the resolved absolute executable, version, provider, probe result and relevant capabilities. Report Available, Missing, Incompatible, Needs authentication or Check failed. Bound probe duration and output; an executable's presence alone does not establish readiness.

Select a coherent Python environment. Verify PyYAML and the required Ansible modules in the interpreter actually used by the selected Ansible commands; an unrelated successful python3 import is insufficient. Safely resolve supported launcher layouts and reject ambiguous environments. Do not assume a shebang always names a plain interpreter path. Define tested version ranges during the first engineering milestone, using the dev-vm CI pins as initial reference points.

Expose Provisioning tools in Settings and a matching structured CLI report. Show detected versions, disabled capabilities and copyable Homebrew commands where applicable, such as brew install python or brew install ansible. Explain interpreter mismatches instead of suggesting a global pip install. Installation remains a user action outside the app.

Recheck dependencies when previewing and immediately before a job starts. Bind each job to the resolved executable paths and checked runtime identities. If tools change after approval, stop for revalidation rather than switch silently. An update during an active process is a failure/recovery case, not a reason to restart the job automatically.

Do not forward the manager's inherited environment wholesale. Build explicit Python and Ansible search paths, a manager-controlled Ansible configuration and private per-job temporary directories. Exclude unrelated host Python packages, Ansible configuration/plugins and development overrides from normal built-in execution. Explicitly trusted custom tasks remain executable controller code, not a sandbox.

## Bundle the engine independently of host runtimes

Package a pinned dev-vm source inventory containing the runtime scripts, playbooks, roles, feature catalogue and schemas, presets and guest helpers. Keep tests, image builders, generated artifacts, local variables and personal configuration out of the production engine bundle.

Proposed app layout:

```text
Contents/
  MacOS/
    OmarchyVMManager
    omarchy-vm
    OmarchyVMProvisioningHelper
  Helpers/
    TryOmarchyKit.bundle
    DevVMEngine.bundle/
      engine/
      engine-manifest.json
```

The engine manifest records its commit, source hashes, API version and supported setup schemas. Extend app assembly, inventory verification and notices for this component without changing the exact Try Omarchy runtime pin. Keep the app bundle read-only: inventories, Ansible temporary files, generated configuration and Python caches belong in private job storage outside it.

Retain dev-vm as the independently maintained source of provisioning behavior. Add the embedding interface there and reuse it from its standalone commands. Do not copy the same provisioning logic into Swift or invoke make as a runtime dependency.

Later, a bundled dependency provider can add a redistributable Python runtime and locked ansible-core/PyYAML dependency set. That phase needs artifact provenance, redistribution notices, native-library inventory, relocation checks and authorized signing/notarization validation. It should not change setup manifests, jobs or terminal attachment semantics.

## Engine interface

Add a versioned capabilities, plan, apply, check and cleanup interface. Pass an explicit verified guest connection to apply/check/cleanup. Do not invoke the existing top-level bootstrap command from inside the manager: it calls the manager to create and restart guests and would duplicate orchestration.

Keep terminal output separate from structured events. The terminal receives actual process bytes. A dedicated control channel reports stages, authorization requests, restart requests, checks, cleanup status and completion. Never infer success from matching human-readable Ansible output.

Planning resolves only data and freezes selected inputs without contacting a guest or evaluating custom Ansible. Record the engine identity, plan digest, input hashes, required tools, package additions/removals, dotfile conflicts, update policy and restart requirements. Changing inputs or capabilities invalidates approval. Custom tasks remain opaque executable operations in the preview.

Keep inventory and transport parameters manager-owned, with the exact VM UUID, expected non-root account, pinned SSH host identity and verified session. Revalidate before mutation and after planned restarts. Do not discover guests by incidental port availability or silently substitute a different guest.

**PRIVATE COUPLING — proposed adapter boundary:** isolate source-specific dev-vm authorization commands and helper contracts in a versioned engine adapter with contract tests. Existing manager settings and kit couplings retain their own versioned boundaries. Do not treat these adapters as public upstream VM APIs.

## Provisioning jobs and lifecycle coordination

Add a ProvisioningCoordinator actor alongside VMManager. Persist a versioned job journal containing job/VM identifiers, approved plan and engine identities, resolved dependency identities, expected session, stage, structured result and cleanup status. Store necessary frozen inputs privately; never journal credentials or terminal input/output.

Suggested job stages:

```text
Planned → Waiting for SSH → Awaiting authorization → Applying
        → Cleaning up → Restarting → Checking → Succeeded

Failure outcomes: Failed, Cancelled, Interrupted, Cleanup required
```

Setup status is separate from VM lifecycle and SSH readiness. SSH ready is not workstation configured. A failed setup leaves the VM available for inspection and deliberate retry; it never resets, recreates or deletes the disk. Retry revalidates the plan and reuses idempotent operations, rather than claiming transactional rollback or an arbitrary mid-task resume.

Allow one provisioning job across the app initially. Block competing setup jobs and incompatible pause/suspend/configuration actions. Coordinate ordinary shutdown and app Quit by cancelling the job, attempting bounded cleanup, recording any unresolved cleanup and then following existing VM shutdown policy. Force stop remains explicit and records that cleanup may be unresolved.

Only VMManager requests restart and controls lifecycle clients. Bind events to job, VM and session identifiers. A planned restart permits explicit rebinding after the previous session exits and the new guest identity is authenticated; unexpected session changes stop setup. Retain resource/port reservations and runtime handles through matching .exited regardless of provisioning errors.

Closing a view or disconnecting the CLI detaches the viewer. It does not cancel the job. After a manager restart, reconcile the journal and any helper state; mark interrupted or uncertain work rather than silently reapply it. Identify helpers by an authenticated ownership channel, not a stored PID alone.

## Live terminal and input ownership

Use a native terminal emulator in a SwiftUI wrapper. SwiftTerm is a candidate; select a pinned release compatible with the chosen Swift 6 toolchain and macOS 15. Its current main branch requires Swift tools 6.2, so do not adopt main without a compatibility check. See [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).

The manager-owned provisioning helper controls the PTY, child process session and cleanup channel. The UI renders bytes and sends input/resize messages; closing or recreating the view does not own or terminate the process. Spawn only the reviewed engine entry point with explicit arguments, working directory and environment.

Support ANSI colours, cursor movement, carriage-return progress, UTF-8 across chunk boundaries, interactive prompts, terminal resizing propagated through nested SSH, selection/copy, search, font sizing, bounded scrollback and jump to latest. Maintain native stage and input-required indicators alongside actual terminal output. Use declared authorization events rather than prompt-text heuristics.

Allow multiple viewers but one explicit input owner. Input ownership also determines PTY dimensions. Revoke its lease on disconnect and require deliberate ownership transfer; a second attachment must not type into another user's password prompt. Control messages include job identity, sequence and bounds. Slow viewers cannot block the provisioning process; report output gaps and provide a terminal-state resynchronization strategy instead of silently replaying an incomplete screen.

Do not record or audit input. Verify that native password prompts disable echo and that helper/transport code never duplicates keystrokes into output. Test local terminal restoration after errors and attachment termination. Cancellation is a job operation with cleanup, not an unqualified kill of the whole process tree.

Disable escape sequences that modify the Mac clipboard or initiate host actions. Require explicit user activation for links and use bounded rendering buffers. Keep raw output in memory only and out of logs, crash attachments and persistent diagnostics. Trusted custom tasks can print arbitrary data, so do not promise automatic secret redaction. Persist only reviewed structured results with bounded, non-secret error categories.

## Guest authorization and recovery

Keep guest sudo interaction inside the PTY. Do not fetch the saved owner password from Keychain and inject it into SSH, arguments, environment variables or a script. The existing owner-setup credential policy remains separate.

For the first release, adapt the existing native persistent grant with cleanup coverage established before requesting it. Request confirmation/password interactively, apply the approved setup, revoke the grant, clear cached sudo authentication and verify revocation before success or restart.

The helper should attempt bounded cleanup when its manager channel closes. Account for descendants and remote processes: stopping a local SSH client does not prove guest work has stopped. Reconcile remote work and authorization state before retrying or reporting cancellation complete.

If revocation cannot be confirmed, persist Cleanup required and offer a specific recovery action. Recovery must reconnect to the same authenticated guest, verify any active work and revoke through the reviewed engine interface. Do not silently reconnect to a changed host key, rerun setup or announce successful cleanup based on local process exit.

Treat guest-side expiry/watchdog support as a separate hardening proposal. The first design cannot guarantee revocation after every host crash or lost connection. Until recovery is verified, keep that condition visible and prevent a new apply to the affected guest.

## Native UI

Add Developer setup to New VM: None, a bundled preset, or a selected local setup folder. Present common feature options natively and retain the existing manifest for advanced selections. Show unavailable options with their missing-tool reason; provide a route to Provisioning tools rather than failing only after launch.

Preview selected software, removals, update policy, dotfile conflicts and restart requirements before creating/applying. Match existing manager resource limits and factory admission; do not blindly inherit the standalone controller's workstation defaults. Existing-guest apply requires an explicit target and approval and cannot resize, replace its factory or restart it outside the approved workflow.

After launch, select a Setup page containing the stage strip, large dark terminal, input-required indicator, cancellation and valid retry/check/recovery actions. Preserve real colour output without simulated typing or fabricated progress percentages. The Home page shows a separate setup badge and concise result.

Require explicit trust for custom Ansible tasks tied to frozen input hashes. General Apply confirmation is insufficient. Tasks, plugins, lookups and delegation can access the controller Mac; a guest inventory is not a sandbox. Dependency discovery does not imply permission to read host tokens or personal SSH configuration.

## CLI and streaming transport

Proposed commands, not current functionality:

```sh
omarchy-vm setup tools
omarchy-vm setup presets
omarchy-vm setup plan --preset project-managed
omarchy-vm setup plan --from /path/to/workstation
omarchy-vm create work --setup project-managed --start --wait configured
omarchy-vm setup apply work --plan PLAN_ID --attach
omarchy-vm setup status JOB_ID
omarchy-vm setup attach JOB_ID
omarchy-vm setup check work
omarchy-vm setup cancel JOB_ID
omarchy-vm setup recover JOB_ID
```

Preserve existing commands and their single-JSON-response behavior. Add capability discovery and a separately versioned streaming endpoint using the existing private same-user Unix-socket security model. Support bounded terminal-byte frames, structured events, sequence numbers, resize/input ownership and detach. Keep terminal output separate from control messages and stable result JSON.

| Mode | Contract |
| --- | --- |
| Default JSON | Return job identifiers, status and structured results without terminal bytes |
| --attach | Attach the caller's terminal interactively; restore local terminal settings on every exit path |
| --events | Emit documented NDJSON structured events without raw terminal output |

No attached input owner means an interactive job stays visibly Awaiting authorization and a CLI wait returns authorization-required with its job ID. Bound that waiting period and cancel safely if it expires. An automation mode must decline prompts rather than grant authorization implicitly. No password flag or stdin-secret automation contract is added in the first release.

Keep pure data planning independent of a VM connection. Add request deduplication and job lookup so a lost submission reply can be reconciled without automatically repeating a mutation. Report cancellation, timeout, detachment, setup failure and cleanup uncertainty distinctly. Existing VM waits remain unchanged; configured is an additional setup-aware completion condition.

## Implementation sequence and acceptance

| Milestone | Main changes | Acceptance gate |
| --- | --- | --- |
| 1. Contracts and dependency probes | Intent amendment, provider interface, tool discovery, tested compatibility ranges and capability model | Fake toolchains cover GUI PATH, missing/old tools, interpreter mismatch, auth missing, probe timeout and replacement; no host installation or VM activity |
| 2. Engine interface and packaging | dev-vm embedding API, pinned asset bundle, immutable inputs and private work directories | Standalone and embedded plans agree; packaged engine works from read-only relocated paths; no make/runtime checkout dependency |
| 3. Job coordination | Journal, admission, lifecycle interlocks, cancellation and recovery | Fake-runtime tests cover session changes, duplicates, failure retention, interrupted work and .exited ownership |
| 4. PTY and stream transport | Helper, terminal frames, input lease and attachment | Local fixture processes prove colours, prompts, hidden input, resizing, detach/reconnect, output limits and process cleanup |
| 5. UI and CLI | Setup selection, preview, tools report, terminal page and commands | Both surfaces operate the same job and expose identical dependency/recovery states; old CLI contract remains valid |
| 6. Guest acceptance | Explicitly approved manager-owned disposable guest only | End-to-end setup, reapplication, authenticated restart, check and sudo revocation observed; failure scenarios recorded |
| 7. Distribution | Notices, inventory, authorized signing/notarization validation | Complete app/helper/engine admission; host dependency requirements documented without implying bundled Python/Ansible |

Use Swift 6, macOS 15+, SwiftPM and make. Proposed focused targets include test-provisioning, test-provisioning-tools and test-terminal; integrate required checks into existing test/build/app verification. Run dev-vm's documented test-omarchy and syntax-check checks for engine/playbook changes.

No-VM tests use fake runtimes, disposable UUID metadata roots, fake executable fixtures and local PTY processes. They must not download factory images, launch QEMU or inspect/change existing user guests. Test secret handling with synthetic canary values only.

Real acceptance requires separate authorization. After an authorized disposable-guest run, shut down test guests, observe matching .exited, verify no remaining owned processes and offer to move their roots to Trash through the existing safe flow. Never recursively erase VM storage.

## Remaining validation boundaries

**TO PROVE:** native password interaction and echo behavior across nested PTYs; runtime discovery under actual GUI launches; compatibility with selected Homebrew package versions; terminal library/toolchain compatibility; interrupted remote work and persistent-grant recovery; host sleep/wake; manager/helper crashes; official and selected lean guest compatibility; and future concurrent provisioning.

Ansible check mode and plan output cannot guarantee arbitrary trusted task behavior. Real two-VM, focus, sleep/wake and crash claims retain the exact evidence limits in intent.md and existing validation records. No packaging, build, dependency, UI or real-guest acceptance is established by saving this plan.
