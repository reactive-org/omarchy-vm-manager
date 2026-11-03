# Shared Swift dev-vm provisioning implementation plan

Status: original milestone 1 committed as `62a4c62`; milestone 1A committed as `915642e`. Milestone 2 has started with the shared package structure and strict manifest parsing committed in dev-vm at `e86550e`. Feature/profile resolution, source snapshots and offline proposals are committed in dev-vm at `56dba82`. Adapter-only transport/authorization sequencing is committed in dev-vm at `f807104` and tested against fakes; concrete SSH/Ansible command adapters and private materialization are committed in dev-vm at `9ebaf17`, tested against fake process runners. The opt-in local runner/PTY is committed in dev-vm at `bb3fae2` with disposable-fixture coverage; the manager now links the pinned package and ships an offline-only helper/resource/launcher integration; the milestone-3 foundation includes durable inputs, admitted helper launch and helper-side sequencer activation/status/cancellation tested with fake adapters and signed local fixtures; production context/backend wiring and terminal integration remain pending.

Date: 3 November 2026 (Australia/Melbourne).

Integrate a shared Swift provisioning package maintained with dev-vm into Omarchy VM Manager so users can create and configure a developer workstation through the native app or CLI without a separate dev-vm checkout. Invoke Homebrew's Ansible for configuration tasks and show the actual process in an interactive terminal, including guest authorization prompts.

**DESIGN DECISION — revised user direction, 2 November 2026:** port the host-side dev-vm controller to one shared Swift package consumed by the manager and a standalone dev-vm CLI. Bundle its compiled code and configuration assets; use Homebrew's existing Ansible installation. The manager will have no separate host Python/PyYAML runtime requirement. Ansible still uses the Python and libraries managed by its Homebrew installation; Python guest helpers remain guest-side dependencies. Do not install or upgrade host tools automatically. Bundling Python or Ansible is outside this revised plan.

The original milestone 1 used the earlier Python-controller design. The user subsequently authorized milestone 1A only: replace those dependency checks with Homebrew Ansible CLI checks, without installing host tools, launching VMs or starting the shared Swift package port. See [the current dependency reference](ProvisioningTools.md). Later implementation, host dependency installation, signing credential use, permission grants, UI takeover and real guest operations retain their applicable authorization boundaries. Existing VM and runtime safeguards in [intent.md](../intent.md) and [AGENTS.md](../AGENTS.md) continue to apply.

The subsequent milestone-2 authorization covers the shared Swift package structure and strict manifest parsing only, with no host tool installation or VM launch. See [the foundation handoff](#milestone-2-foundation-handoff--2-november-2026). This supersedes the earlier instruction to defer starting the port; execution and real-guest safeguards remain in force.

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

Try Omarchy continues to own the VM implementation. VMManager owns lifecycle, storage admission, resource and port reservations, and authenticated guest identity. The shared dev-vm Swift package owns workstation preferences, feature resolution, planning and configuration through Omarchy, mise and Ansible. The UI and CLI operate the same manager-owned jobs. The package receives host/guest transport interfaces; it must not depend on OmarchyVMManagerCore or create a second VM lifecycle owner.

The first release includes bundled presets, explicitly selected local setup folders, developer features, themes, layouts, dotfiles, preview/apply/check, deliberate reapplication and a live provisioning terminal. Use official or already imported compatible factories through existing manager admission.

Defer remote repository cloning, custom factory building in the app, automatic third-party collection installation, concurrent provisioning and a general-purpose SSH terminal. Docker remains conditional on the separate image-building workflow. Do not require Git merely to use bundled engine assets or local setup folders.

The terminal is a scoped exception to the embedded-terminal non-goal recorded with the provisioning design decision in intent.md. Milestone 1 implements dependency reports only; the terminal and orchestration remain future work. Current launch and permission policy continues to apply.

## Existing source evidence

**VERIFIED — source inspection during planning:** the manager has owner setup, managed authenticated SSH, a shared command service and a private same-user Unix socket. Its current command transport returns one JSON response per request; it does not provide terminal streaming. See [GuestCommands.swift](../Sources/OmarchyVMManagerCore/GuestCommands.swift), [CommandSocket.swift](../Sources/OmarchyVMManagerCore/CommandSocket.swift) and [CLI.md](CLI.md).

**VERIFIED — local dev-vm source inspection:** standard bootstrap does not require Ansible, while feature playbooks and external setup application do. YAML parsing requires PyYAML, which the current loader can locate through an existing Ansible runtime. The checkout pins Python 3.14.10 and ansible-core 2.21.5 for development; those are compatibility reference points, not established minimum host versions for this feature. Ansible currently uses checkout-relative temporary storage.

Those observations describe the existing Python implementation, not the proposed Swift runtime. Homebrew's [Ansible formula](https://formulae.brew.sh/formula/ansible) manages Ansible's Python dependency. Porting the host controller removes the manager's independent interpreter selection and YAML-import requirement; it does not remove Python from Ansible or Linux guests. Existing Python-based build tooling and the deferred factory builder are separate from the installed manager's runtime dependencies.

**VERIFIED — local dev-vm implementation:** setup enables a native persistent passwordless guest sudo grant, then revokes it and clears cached authentication. The grant has no automatic expiry and can survive a reboot. Do not describe it as a 60-minute grant. Failure to verify revocation must remain actionable.

dev-vm source and reference documentation:

- [Repository](https://github.com/reactive-org/dev-vm)
- [Prerequisites](https://github.com/reactive-org/dev-vm/blob/main/README.md)
- [External setup repositories and task trust](https://github.com/reactive-org/dev-vm/blob/main/docs/omarchy-setup-repositories.md)
- [Current controller](https://github.com/reactive-org/dev-vm/blob/main/scripts/omarchy_vm_manager.py)

These links identify the source projects. Implementation must pin the shared Swift package to an immutable commit and record its resource inventory rather than consume a moving branch.

## Changes to milestone 1

**VERIFIED — original implementation:** commit `62a4c62` contains the provider abstraction, Homebrew/tool discovery, native and CLI reports, isolated bounded probes, executable change checks and prerequisite gates. Its Python/PyYAML import and shebang checks are preserved in that commit; milestone 1A removes them from current code. Its test results remain historical evidence and do not establish a completed shared-controller migration.

**DESIGN DECISION — implemented milestone 1A:** adapt the existing infrastructure before integrating the shared Swift package. Preserve the original commit and its validation history.

| Existing milestone 1 area | Retain or change for the Swift approach |
| --- | --- |
| Provider abstraction, GUI-safe Homebrew discovery and command-scoped overrides | Retain; resolve Homebrew's Ansible command pair through its installation prefix and controlled absolute paths |
| Bounded process runner, process-group cleanup, private HOME/config/temp, UTF-8 locale, minimal environment and executable change checks | Retain and extend for Ansible CLI self-check fixtures |
| Native Provisioning tools page and local `setup tools` report | Retain; show Ansible as the runtime dependency rather than requiring a separately selected Python/PyYAML environment |
| Independent `python` and `yaml` tool requirements, Python override and `brew install python` guidance | Remove from the revised runtime contract; shared Swift parsing supplies JSON/YAML planning |
| Python import script, Ansible Python-shebang resolution and exact interpreter-path matching | Replace with compatible, usable Ansible CLI checks; do not discover or invoke the interpreter ourselves |
| Ansible version and package coherence checks | Keep core-version admission and command-pair coherence, verified through Homebrew origin, executable identities and CLI self-checks rather than Python imports |
| Feature prerequisites | Recalculate: local data-only planning needs the compiled package/parsers; feature application needs Ansible plus required system transports; no independent Python blocker |
| Report schema and Python-related tests | Introduce dependency-report schema 2 with documented migration; replace interpreter/shebang cases with CLI failure, wrapper and command-pair cases while preserving isolation/timeout/replacement tests |
| Engine availability and authorization | Keep execution disabled until the corresponding engine/job milestones are implemented and approved |

Schema 2 now replaces schema 1 in the local dependency report; existing guest-command protocol 1 is unchanged. Python/PyYAML overrides return `retired-tool-override` with actionable Ansible selection guidance. Ansible's Python details do not become a separately managed dependency or fixed Python-major gate. The per-tool `installation` identity replaces `interpreter`; report consumers must check the schema version.

The original Python-selection tests remain evidence for commit `62a4c62`. Milestone 1A tests prove that planning prerequisites have no external Python/PyYAML blocker, a working Homebrew Ansible is admitted without a Python probe, and broken or mismatched installations fail closed. Recorded manager requests exclude direct Python invocation and absolute-path fallbacks; Ansible's internal Python processes are expected. Actual JSON/YAML planning and parser parity remain milestone 2 work; all feature execution stays disabled.

## Homebrew dependency discovery and feature gates

Use the milestone 1 dependency-provider abstraction for Homebrew's Ansible and optional host tools. Ordinary VM management stays available when Ansible is absent. Schema 2 now reports no external blockers for data-only planning; that planning will become available only after the shared package/parsers are integrated. The following table includes those later package requirements.

| Capability | Requirements | Missing or incompatible behavior |
| --- | --- | --- |
| Homebrew installation guidance | Discovered executable with a successful bounded probe | Show Homebrew unavailable; never bootstrap it automatically |
| JSON and YAML planning | Compiled shared Swift package with validated parsers and resource schemas | No external Python, PyYAML, Ansible or guest connection required; unimplemented planning remains disabled |
| Basic provisioning through native guest commands | Shared Swift controller, system Bash and required system OpenSSH tools | Disable affected application operations; retain local planning |
| Developer features and external setup application | Compatible, usable Homebrew ansible-playbook and ansible-inventory, system transports and supported guest prerequisites | Disable application; retain data-only previews |
| Git-based setup retrieval, deferred | Git and the explicitly requested repository access | Gate retrieval only |
| GitHub-star theme selection | Authenticated gh or an explicitly configured token | Disable this selector; retain direct theme selection |
| Custom factory building, deferred | Docker CLI, reachable ARM64 Linux engine and the builder's requirements | Keep unavailable in the first integrated release |

Discover tools without assuming a GUI launch inherits the user's shell PATH. Search explicit user overrides, known Homebrew paths such as /opt/homebrew/bin and /usr/local/bin, and a controlled PATH fallback. Query a discovered brew executable for its prefix when necessary. Do not launch a login shell, source shell configuration, execute brew shellenv output or scan credentials.

For every dependency, record the resolved absolute executable, version, provider, probe result and relevant capabilities. Report Available, Missing, Incompatible, Needs authentication or Check failed. Bound probe duration and output; an executable's presence alone does not establish readiness.

Validate both Ansible commands against the supported Ansible Core line and the same reviewed Homebrew installation. Initially retain the existing Core 2.21.x policy as the migration baseline; do not widen it automatically when Homebrew ships a newer line. Let the installed launchers select their own Homebrew-managed runtime. Do not parse their shebangs to select Python, import Python modules from Swift, impose the old standalone Python 3.11–3.14 gate, or offer Python/PyYAML overrides.

Supplement bounded version probes with a fixed, manager-owned local self-check: for example, static inventory listing and syntax validation of a bundled minimal built-in playbook. Use private configuration and no user inventory, playbooks, custom plugins, credentials, SSH, guest task execution or package downloads. Validate the exact commands and expected output in no-VM fixtures. Reject conflicting command versions, mismatched installation identities, broken wrappers, failed runtime/module loading and unexpected output. These checks validate the CLI boundary; full playbook compatibility still needs separate engine and guest acceptance.

Expose Provisioning tools in Settings and a matching structured CLI report. Show Ansible Core versions, installation identity, failed capabilities and copyable Homebrew commands where applicable, such as `brew install ansible`. Explain a broken or unsupported Ansible installation without directing users to repair a separate Python environment or perform a global pip install. Installation remains a user action outside the app.

Recheck dependencies when previewing and immediately before a job starts. Bind each job to the resolved executable paths and checked runtime identities. If tools change after approval, stop for revalidation rather than switch silently. An update during an active process is a failure/recovery case, not a reason to restart the job automatically.

Do not forward the manager's inherited environment wholesale. Keep a controlled executable PATH, manager-owned Ansible configuration, UTF-8 locale and private per-job temporary directories. Exclude inherited Python package overrides, Ansible configuration/plugins and development overrides from normal built-in execution while allowing Homebrew's launcher to find its packaged dependencies. Explicitly trusted custom tasks remain executable controller code, not a sandbox.

## Shared Swift package and resource packaging

Maintain a SwiftPM package at the dev-vm repository's root `Package.swift`, with a `DevVMProvisioningCore` library and a standalone `dev-vm` executable consuming that library. These products now exist in the milestone-2 foundation branch; the executable supports offline validation and planning only. The manager now consumes the immutable `bb3fae2` source export under `Vendor/dev-vm`, verified by `Config/DevVMProvisioning.lock.json`, and links the same library into manager core and an offline-only provisioning helper. Keep Swift 6 and macOS 15+ compatibility and a make-based build/test entry point.

Move host-side manifest parsing, feature/profile resolution, plan generation, input freezing/hashing, source validation, inventory/argument generation, guest payload staging, native-command sequencing and authorization cleanup coordination into this package. Manager-specific transports and lifecycle actions are injected adapters; the package must not import the manager or create dependency cycles. In the app, all lifecycle actions still pass through VMManager. The standalone executable calls the same package and uses the manager's public CLI for authorized VM lifecycle operations.

Keep Ansible playbooks, roles, feature catalogues/schemas, presets and guest-side Python/shell helpers as versioned package resources wherever behavior is compatible. Port the host driver rather than reimplement Ansible in Swift or rewrite Python helpers as Linux Swift programs. Build the compiled package into the app; users do not need Swift, Xcode or a source checkout at runtime.

Proposed app layout:

```text
Contents/
  MacOS/
    OmarchyVMManager
    omarchy-vm
    OmarchyVMProvisioningHelper
      [links DevVMProvisioningCore; offline only]
    dev-vm-process-host
      [pinned PTY exec launcher; not invoked by the offline helper]
  Resources/
    <SwiftPM provisioning resources>.bundle/
      playbooks, roles, catalogues, presets, guest helpers
      provisioning-manifest.json
  Helpers/
    TryOmarchyKit.bundle
```

The exact SwiftPM-generated resource bundle name is resolved during implementation. Expose resource locations through the shared package instead of guessing installed paths. The provisioning manifest records the package revision, resource hashes, API and supported schemas. Extend app assembly, inventory verification and notices for compiled code and resources without changing the exact Try Omarchy runtime pin. Keep the app bundle read-only: inventories, Ansible temporary files, generated configuration and runtime caches belong in private job storage outside it.

Preserve one maintained controller. During migration, compare Swift behavior with the existing Python controller as a test oracle on synthetic fixtures. Keep the legacy standalone entry points until an explicit cutover to the shared Swift executable; do not embed the Python controller as a production fallback in the manager or maintain parallel controllers after cutover. Document standalone command compatibility and explicit changes before switching entry points. The deferred Python factory builder may remain outside this runtime migration.

Use Swift validation over the pinned LibYAML event parser described in the foundation handoff. Reject forbidden YAML constructs before composition. Preserve the existing plain-data rules: unknown/duplicate keys, aliases, anchors, explicit tags, merge keys, templates, non-finite values, nesting and input-size limits must be tested. Preserve custom Starship TOML validation with a reviewed Swift parser or an explicitly equivalent supported contract. JSON planning and parser tests must run with Python and Ansible absent from PATH. Exact supported scalar differences and limited fixture evidence are recorded below; full parser/controller parity remains TO PROVE.

## Engine interface

Define typed, versioned capabilities, plan, apply, check and cleanup interfaces in the shared Swift library, with Codable messages at the helper/CLI process boundary. Pass an explicit verified guest connection to apply/check/cleanup. The standalone Swift executable exposes the same operations using the same library. Do not invoke a standalone top-level bootstrap command from inside the manager, since that would duplicate orchestration and call back into the manager unnecessarily.

Keep terminal output separate from structured events. The terminal receives actual process bytes. A dedicated control channel reports stages, authorization requests, restart requests, checks, cleanup status and completion. Never infer success from matching human-readable Ansible output.

Planning resolves only data and freezes selected inputs without contacting a guest or evaluating custom Ansible. Record the engine identity, plan digest, input hashes, required tools, package additions/removals, dotfile conflicts, update policy and restart requirements. Changing inputs or capabilities invalidates approval. Custom tasks remain opaque executable operations in the preview.

Keep inventory and transport parameters manager-owned, with the exact VM UUID, expected non-root account, pinned SSH host identity and verified session. Revalidate before mutation and after planned restarts. Do not discover guests by incidental port availability or silently substitute a different guest.

**PRIVATE COUPLING — adapter boundary:** isolate native guest authorization commands, guest-helper contracts and Homebrew Ansible CLI interpretation behind versioned adapters with contract tests. Milestone 1A retires the original Python-shebang adapter and implements the Homebrew command-pair/self-check adapter only. Guest authorization and shared-controller integration remain future work. Existing manager settings and kit couplings retain their own versioned boundaries. Do not treat these adapters as public upstream VM APIs.

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

The user-provided Setup-tab reference is the visual target: reviewed source/profile/features, readiness checks, stage strip, a large dark terminal with Follow output/expand, cancellation and job details. Its concept/sample output is illustration, not evidence of a configured guest. Keep actual terminal bytes separate from structured control messages; the authenticated ownership slice below adds no UI or stream rendering.

Use a native terminal emulator in a SwiftUI wrapper. SwiftTerm is a candidate; select a pinned release compatible with the chosen Swift 6 toolchain and macOS 15. Its current main branch requires Swift tools 6.2, so do not adopt main without a compatibility check. See [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).

The manager-owned Swift provisioning helper links the shared package and controls the PTY, child process session and cleanup channel. It invokes reviewed Homebrew Ansible and system SSH/native-command transports with explicit arguments, working directory and environment. No Python host-controller subprocess is required. The UI renders bytes and sends input/resize messages; closing or recreating the view does not own or terminate the process.

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

`setup tools` now implements schema 2 under milestone 1A. All other commands below remain proposed:

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
| 1. Original dependency probes — committed | Provider, native/CLI report, host Python/PyYAML/Ansible checks and feature gates at 62a4c62 | Existing no-VM results retained as historical evidence; not the final Swift dependency contract |
| 1A. Swift dependency contract — implemented | Retained discovery/isolation; replaced direct Python/shebang/import gates with Homebrew Ansible CLI checks; dependency-report schema 2 | No-VM fixtures cover independent planning prerequisites, healthy/broken/wrapped/mismatched command pairs, GUI PATH, timeout, replacement and authentication deferral; execution stays disabled; see ProvisioningTools.md for exact evidence |
| 2. Shared Swift controller and packaging — offline planning, sequencing and concrete command adapters implemented; remaining port pending | SwiftPM library, strict parsers, offline plans/snapshots, pinned SSH/Ansible command construction, private materialization, bundled guest resources and scope-control helper; local process runner/PTY now implemented against disposable local fixtures; offline manager/helper package/resource/launcher integration now implemented; operational CLI, job/session adapters and full release acceptance remain pending | 227 manager Swift tests / 48 script tests plus relocated package fixtures and prior 64 package tests plus 18 plain-data/66 proposal-error oracle fixtures pass; adapters use fake runners and the local runner uses disposable local processes. Remote guest/process proofs, complete parity and full runtime-app/release acceptance remain pending |
| 3. Job coordination — helper backend/session authority foundation implemented, product wiring pending | Frozen delivery/replan, schema-6 journal, single-use shared-adapter/fenced-runner construction and independent authenticated manager authority; product provider disabled | Fake runtimes/process runners and signed local helpers cover session/command/invocation admission, construction, cancellation, cleanup, uncertainty and no replay. Product resource handoff, operational terminal/runner wiring and restart acceptance remain pending |
| 4. PTY and stream transport | Helper, terminal frames, input lease and attachment | Local fixture processes prove colours, prompts, hidden input, resizing, detach/reconnect, output limits and process cleanup |
| 5. UI and CLI | Setup selection, preview, tools report, terminal page and commands | Both surfaces operate the same job and expose identical dependency/recovery states; old CLI contract remains valid |
| 6. Guest acceptance | Explicitly approved manager-owned disposable guest only | End-to-end setup, reapplication, authenticated restart, check and sudo revocation observed; failure scenarios recorded |
| 7. Distribution | Shared package/resource inventory, notices and authorized signing/notarization validation | Complete app/helper/resource admission; Homebrew Ansible requirement documented; no independent manager Python runtime or bundled Ansible claimed |

Use Swift 6, macOS 15+, SwiftPM and make. Retain `make test-provisioning-tools`; add focused shared-package/parser/parity and terminal checks as their milestones are implemented. Run dev-vm's existing test-omarchy and syntax-check checks for migration/playbook changes. Python can remain available in the development test environment for the old-controller oracle and existing build scripts; the shipped manager must not invoke it as its host controller.

Break milestone 2 into reviewable steps: establish the resource/library boundary and strict parsers; port resolution, snapshots and planning against shared golden/error fixtures; port transport and authorization sequencing against fake guest adapters; move the standalone CLI to the library; then integrate and verify the package in the manager/helper. Gate each step on parity or documented explicit compatibility changes. Do not use a real guest to discover parser or plan differences.

No-VM tests use fake runtimes, disposable UUID metadata roots, fake executable fixtures and local PTY processes. They must not download factory images, launch QEMU or inspect/change existing user guests. Test secret handling with synthetic canary values only.

Real acceptance requires separate authorization. After an authorized disposable-guest run, shut down test guests, observe matching .exited, verify no remaining owned processes and offer to move their roots to Trash through the existing safe flow. Never recursively erase VM storage.

## Remaining validation boundaries

**TO PROVE:** full shared-controller API and strict YAML/JSON/TOML parity beyond the foundation evidence below, Python-controller behavior migration, operational standalone command compatibility, resource relocation, other Homebrew installations/Core versions, native password interaction and echo behavior across nested PTYs, GUI/native packaged discovery, terminal library/toolchain compatibility, interrupted remote work and persistent-grant recovery, host sleep/wake, manager/helper crashes, guest compatibility and future concurrent provisioning.

Ansible check mode and plan output cannot guarantee arbitrary trusted task behavior. Real two-VM, focus, sleep/wake and crash claims retain the exact evidence limits in intent.md and existing validation records. Original milestone 1 results remain valid for their commit. Milestone 1A evidence is scoped to dependency reports and fixed local probes; it establishes no shared-controller port or real-guest acceptance.

## Milestone 2 foundation handoff — 2 November 2026

**DESIGN DECISION / IMPLEMENTED:** the shared package belongs in dev-vm, as planned. Development is isolated on its companion `codex/swift-provisioning-package` worktree branch, starting from `ed36bbec92943c10f9a0b1b2d4887a4f4a190bff`. The manager stays on `codex/dev-vm-provisioning-plan`. No unpublished absolute-path dependency is added to the manager's `Package.swift`; publication and an immutable manager pin remain a later integration step. The package/parser foundation and its docs are committed in dev-vm at `e86550e59cbf7fc90ca4e8efe9c608951fbb984a`. This manager documentation records that handoff without adding a production package dependency.

The package contains:

- `DevVMProvisioningCore`: Sendable plain-data values, typed schema-1 setup/VM/dotfile/task declarations and strict manifest validation. It imports no manager code and has no process, SSH, Ansible or VM lifecycle interface.
- `dev-vm validate-manifest PATH`: a validation-only migration CLI. It returns counts and explicit `structure_valid: true`, `resolved: false`, `execution_available: false`. Errors are fixed codes with optional numeric locations; manifest values, paths and variables are not printed. Existing Python make/CLI entry points remain unchanged.
- Bundled selection schema/catalogue and MIT notices. The inventory records exact upstream/dependency revisions and SHA-256 hashes; tests check hashes and equality with the maintained dev-vm originals. Playbooks, roles, presets and guest helpers are not yet packaged.
- Make-based Swift build/test targets, an existing-Python development oracle with subprocess fallback explicitly disabled, and CI steps for both. Python is not a library/CLI runtime dependency.

**DESIGN DECISION — parser boundary:** the unmodified parser subset of Yams 6.2.2's CYaml/LibYAML is pinned at `a27b21e0c81c5bf42049b897a62aaf387e80f279`, compiled into a private C target behind an event bridge and Swift validation. Its event interface rejects aliases, anchors, explicit tags and version/tag directives before building the plain-data tree. No high-level alias composer or installed host YAML library is used. JSON has a separate bounded grammar with Foundation string escape decoding; malformed JSON cannot fall back to YAML, and valid escaped surrogate pairs remain supported.

Both formats enforce UTF-8, 256 KiB, 30 container levels, unique string keys, finite numbers, no template markers or merge keys. File reads accept explicit regular files only, reject leaf symlinks/FIFOs/directories, bound the actual read and detect size/time changes during it. They do not claim to snapshot a repository or protect later asset accesses. Unknown root/nested fields and invalid VM types/ranges are rejected. Selection options use the bundled finite schema-keyword subset; unsupported schema keywords fail closed when evaluated. Builtin names and duplicate aliases are checked; external names remain unresolved lexical declarations.

**EXPLICIT COMPATIBILITY CONTRACT:** integers are signed 64-bit; finite decimal floating point and exponent notation are supported. YAML 1.1 boolean spellings remain supported. Unquoted timestamps and legacy octal/hex/binary, underscored or sexagesimal numbers are rejected; quote them to express strings. Exponent notation in YAML mappings is consistently numeric, unlike PyYAML's context-dependent behavior. DEL in bounded names/paths, any `.git` path segment, canonically equivalent duplicate Unicode keys and bare/`pkg:` selectors naming the same package are also refused. These differences are intentional, not full legacy parity.

**VERIFIED — no-VM checks:** `make build-provisioning test-provisioning test-provisioning-oracle` passes: 12 Swift test functions, including 94 parameterized cases, plus agreement on 18 shared plain-data oracle fixtures. The Swift tests and validation CLI also pass with `PATH=/nonexistent`, invoking the test runner by absolute toolchain path. `make test-omarchy` passes 235 tests with one Lua fixture skipped because Lua is absent, using the already-installed Homebrew Python and local socket access. The initial system Python 3.9 run lacked `tomllib`; the sandboxed run could not start Ansible's local RPC server. No installation or source workaround was needed. `make syntax-check` passes both unchanged playbooks with expected empty-host warnings. This verifies bounded parsing and local fixture behavior only.

**TO PROVE / REMAINING:** feature/profile/catalogue resolution and merging, effective option/TOML semantics, source traversal and immutable snapshots, expanded dotfile overlap detection, factory admission, deterministic plans, full resources and standalone operational compatibility. Custom task YAML remains opaque and unopened. No manifest is admitted as an executable plan. Manager/helper integration and immutable packaging, transport/authorization, job coordination and the live terminal remain future work. Every manager feature still reports `implemented: false` and `enabled: false`. No host tool installation, image download, VM launch or existing-VM operation occurred.


## Milestone 2 offline planning continuation — 2 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** continue the same dev-vm worktree with feature/profile resolution, source snapshots and planning against the Python oracle; no host tool installation or VM launch. The continuation is committed as `56dba82368d13287b01e28a459a69b42da8620a1` on `codex/swift-provisioning-package`; the foundation remains `e86550e`. This manager worktree records the design and results without linking an unpublished package or enabling execution.

**IMPLEMENTED:** `FeaturePlanner.resolve` handles explicitly supplied data-only extension catalogues, builtin aliases, prerequisites, all-graph cycle/depth checks, profile inheritance, sibling conflicts, empty map/list clearing, null tool tombstones, effective options and package/mise provider conflicts. JSON and YAML retain catalogue declaration order. Results include reasons, native package/tool ownership and predicted effects, using the same shape as the Python resolver. Limits are 32 catalogues, 512 features/profiles and 30 graph levels.

**DESIGN DECISION — TOML:** pin Swift-native TOMLDecoder 0.4.5 at `a2bbd2796fe3064e107de18cb56031052c4fa899` in the package manifest/lock, with its MIT notice in package resources. Its TOML 1.1 parser is preceded by bounded lexical checks that reject the added escapes, optional time seconds, multiline inline tables and inline-table trailing commas to retain the oracle's TOML 1.0 contract. Prompt text is at most 64 KiB with bracket/key depth at most 30. Validate selected enabled zsh/Starship configuration after inheritance/overrides; allow unselected invalid prompt defaults to be repaired before selection. Runtime parsing invokes no external tool.

**IMPLEMENTED — snapshot/plan boundary:** `SetupPlanner.plan` reads only explicitly declared manifest/catalogue/layout/dotfile/task/asset paths below one selected repository descriptor. No-follow descriptor-relative traversal refuses symlinks, `.git`, special files and unsafe paths, and checks for detectable changes while reading. `SourceSnapshot` holds immutable bytes/modes in memory, binds empty-directory entries and expands dotfile trees to explicit destinations. Limits are 4,096 files, 32 MiB total, 4,096 directories, 8,192 entries per directory and 64 path levels. Revalidation detects selected content/mode changes, additions/removals, root replacement and changed engine/resources. Unrelated files are excluded. This is a reviewed byte snapshot, not a filesystem transaction against an adversarial writer; materialization into private job storage is deferred.

`dev-vm plan REPOSITORY [MANIFEST]` emits a versioned offline proposal: effective features/options, package/mise requirements and provenance, predicted effects, dotfiles, opaque task declarations, input receipts, engine inventory and deterministic input/plan digests. It states tool/trust/restart/update requirements and pending guest conflict/factory checks. Variable values and opaque task/file contents are not serialized. Factory selectors remain unverified declarations; the planner does not open/admit a factory or contact VMManager. Guest state and actual installation/removal/conflict results are unknown offline. `execution_available` is always false. Existing Python entry points and all manager execution gates are unchanged.

The checked-in engine resource records source, resource and immutable dependency-pin hashes. A make-time Python development script regenerates it, and tests detect drift; the installed Swift CLI/library has no Python dependency. This does not yet establish signed app/helper provenance. The Python oracle compares every legacy proposal field except the intentionally different engine identity, normalizing only the bundled catalogue path to `builtin/catalogue.json`. It forbids subprocesses, manager calls and loader interpreter fallback during Python planning. Native CLI children use `PATH=/nonexistent`.

**VERIFIED — no-VM checks:** make-based build and 20 Swift test functions pass, including snapshot bounds and mutation checks, graph/dependency ordering, TOML compatibility, engine inventories and equal plan identities across equivalent roots. All 18 plain-data fixtures and 66 complete proposal/error cases agree with Python (41 accepted, 25 rejected). The existing dev-vm suite passes 235 tests with the Lua fixture skipped because Lua is absent; both unchanged playbooks pass syntax checks. The complete planning oracle used the existing Ansible-managed Python 3.14 as development tooling only. All 20 Swift tests also pass with `PATH=/nonexistent` using the absolute toolchain runner. An isolated CLI/bundle copy plans successfully; altering its bundled catalogue returns only `manifest.resource` and exit 1. This is not full app relocation acceptance. No host tool installation/upgrade, credential access, app opening/install, guest contact or VM operation occurred.

**TO PROVE / REMAINING:** complete parser/TOML parity beyond these fixtures, job snapshot materialization, full guest resources, immutable manager pin and helper/UI/CLI integration, signed packaging/relocation, operational standalone cutover, transport/authorization, live terminal and all real-guest acceptance. Earlier foundation limitations remain historical to `e86550e`; this continuation supersedes only their pending offline-resolution/snapshot/planning status.


## Milestone 2 transport/authorization slice — 2 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** continue the same dev-vm worktree with shared transport and authorization sequencing tested using fake guest adapters only; no host tool installation or VM launch. The slice is committed as `f807104850dfd06527bcbee4ba5f0aca5a1404f4` on `codex/swift-provisioning-package`. The manager receives documentation updates only: no package dependency, setup entry point or feature gate changes.

**IMPLEMENTED — typed adapter boundary:** `ProvisioningGuestAdapter` accepts typed commands and replies; the only implementation is the in-memory Swift test fake. No process, SSH/Ansible, PTY, real payload staging, guest discovery or lifecycle backend is provided. `ProvisioningSequencer` drives single-use apply/check and cleanup-only recovery attempts. Reviewed requests bind the frozen plan, exact job and VM/runtime-session identity, non-root owner/UID, host-key and dependency pins, mode, task/check selection, conflict policy and input lease. Approval additionally acknowledges executable custom tasks, the persistent sudo grant and any Docker root-equivalent opt-in. Approval/source/input/trust failures stop before contacting an adapter. Check skips custom tasks unless separately selected and trusted, and never changes authorization, installs manifest packages, changes Docker policy or requests restart. Trusted check-mode tasks remain executable code, not sandboxed data.

Each operation rechecks identity and each reply must match protocol, command/job IDs, VM/session/owner/UID/key/dependency pins and the expected proof. Source/engine checks precede body operations; cleanup remains possible after sources change. Correlated schema-1 events contain fixed phases/codes and command/job/VM/session IDs, with started/completed/failed records. Reports exclude owner/key material, source paths/data, terminal bytes and raw adapter errors; recovery handles and request/command/binding descriptions are redacted. Actual authentication and trustworthy proofs remain adapter responsibilities, not established by fake echoes.

**PRIVATE COUPLING — native contract version 1:** fixed guest `bash -lc` argv follow the Python controller at `56dba82`: stale grant disable/cache reset, native interactive `omarchy sudo passwordless permanent`, active policy with noncached sudo verification, revoke/cache-clear/inactive compound verification, native Docker consent with deferred reboot and local-socket Docker owner checks. No user value is interpolated and no nonterminal password/secret input is accepted. These builders do not execute commands. The native semantics are private guest CLI couplings, not public runtime-kit APIs or a new VM owner.

**IMPLEMENTED — sequencing and cleanup:** coverage begins before staging and before reset/grant attempts. Stage frozen inputs, reset/clear stale authorization, request the interactive native grant, verify it, apply packages/features, perform selected Docker opt-in and repository work, quiesce owned work, revoke/clear/verify, check Docker again without the grant, quiesce that check and remove the job-owned payload. Docker success returns a restart-required result; only VMManager may later restart. Cancellation interrupts the exact active adapter command and does not discard its outstanding call. Cleanup runs in an independent cancellation scope and never prompts, grants or depends on original inputs. Local completion is not remote quiescence; an explicit job-scoped proof is required. Work uncertainty prevents payload removal and keeps grant risk even after a momentary inactive observation.

Unresolved work/grant/payload state yields `cleanupRequired`, preserving primary and cleanup failures separately, with an in-memory ticket pinned to the original guest, dependencies and payload UUID. New-driver recovery can only quiesce/revoke/clear/verify/remove against those pins; it cannot stage, apply, check, prompt, grant, restart or silently rebind. Recovery works without original repository files and confirms cleanup only. Persistent journals and cross-restart recovery/rebinding remain future manager work. A lost revoke/cache-clear reply may be reconciled by a later compound proof once work is stopped. An attempt finishing never releases VM lifecycle ownership; existing clients/reservations still require matching `.exited`.

Adapter deadline contracts are 10 seconds for identity, 30 for grant/cache probes and cleanup, 120 for interactive requests and 3,600 for setup operations. Actual wall-clock enforcement/local process exit belongs to a concrete transport. Injected fake timeout failures establish state transitions only, not termination of an uncooperative adapter or real remote descendants.

**VERIFIED — fake-only checks:** package build and 38 Swift test functions pass, including 18 new sequencing/native-contract tests and 10 reply/identity mismatch cases. All 38 also pass with `PATH=/nonexistent`. The 18 parser and 66 complete proposal/error oracle cases still pass. Seven selected existing Python tests using mocked guest/Ansible/lifecycle operations preserve the Python authorization/check ordering reference. The full legacy suite that runs local Ansible was deliberately not rerun in this fake-only slice; its earlier `56dba82` evidence remains historical. No host tool installation/probe, actual SSH/Ansible command, credential access, app opening/install or VM operation occurred.

**TO PROVE / REMAINING:** actual guest authentication/pins and proof authenticity, native commands/quoting/TTY echo, adapter timeout/cancellation/process ownership, remote quiescence, job payload materialization, persistent journal/recovery and explicit session rebinding, operational Swift CLI cutover, immutable manager/helper/UI packaging, live terminal and all real-guest acceptance. CLI output still declares execution unavailable and every manager execution gate remains disabled. This supersedes only the earlier pending adapter-contract/authorization-state-machine status, not the remaining concrete transport or guest-acceptance work.


## Milestone 2 concrete command adapters — 2 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** continue in the same dev-vm companion
worktree with concrete SSH/Ansible adapters tested only through fake process
runners. No host tool installation or VM launch. The manager receives these docs
only; package consumption, UI/CLI execution gates and VM lifecycle ownership stay
unchanged. The dev-vm slice is committed as
`9ebaf178de48e6480e248f8b20eae1f35c0d16b6` on
`codex/swift-provisioning-package` (committed 3 November 2026).

**IMPLEMENTED:** `SSHAnsibleGuestAdapter` constructs exact admitted executable,
argv, environment, stdin/output policy, deadline and correlated process IDs through
`ProvisioningProcessRunner`. No live runner or PTY is supplied. Session authority
remains manager-owned; each invocation revalidates VM/session/dependency admission,
credential metadata and executable identity/hash. The adapter uses loopback-only
SSH, a pinned ed25519 host key, private known_hosts/config and explicit owner/key,
with agent/forwarding/proxy/multiplexing disabled. Key bytes are never read by the
adapter. Executable entry paths are preserved after resolved-target validation
because Homebrew Ansible launchers can dispatch by symlink name.

Frozen selected repository bytes and authenticated maintained playbooks, roles,
catalogue and guest helpers are materialized into private UUID job storage.
Build-time copies have checked inventories. Ansible receives private fixed
inventory/config/JSON variable files, fixed transport overrides, explicit tags and
`--check` where selected. No new host Python selection/runtime is introduced;
Homebrew still owns Ansible's dependencies. Native package installation follows
Omarchy and mise rather than replacing their update paths. The exact nested
manifest path is retained to recover frozen variables without reparsing another
file. Caller environment/plugin/agent state is not inherited.

**LIVE TERMINAL CONTRACT:** native authorization, Docker consent and package
installers request SSH TTY plus an opaque input lease; Ansible requests a live
terminal output stream with stdin closed. A future runner must implement actual
PTY allocation, ownership, no-secret-echo, bounded streaming/deadlines and local
descendant exit. Structured events/results contain no terminal bytes. The adapter
tracks cancellation across gaps between processes, interrupts only the matching
active invocation and prevents a subsequent body launch. Cleanup is independent
and noninteractive. There is no terminal view or actual streaming implementation
in this slice; the standalone Swift CLI still offers offline commands only.

**PRIVATE COUPLING:** the guest-only Python `provisioning-job.py` protocol binds a
non-root Linux/aarch64 job/payload lease, recorded systemd user scopes and a scoped
Ansible shell wrapper. Before granting sudo, preparation checks Python 3, cgroup
v2, user manager/bus and `systemd-run --scope --expand-environment=no` capability
(the flag requires systemd 254+). Quiescence seals body work, stops recorded scopes
and checks inactive/empty groups before reporting proof. Pending/uncertain launch
registration blocks proof/removal. Cleanup may create scopes after sealing for
revocation checks; a final quiescence precedes removal of the exact owned UUID
temporary payload. No VM storage is touched. Trusted custom tasks are executable
code, not sandboxed; deliberate scope escape/independent services are outside this
proof. Uncertain startup can require manual review. No local SSH exit or arbitrary
process-name match establishes guest quiescence.

**VERIFIED — fake-process slice:** make build, 50 Swift test functions (12 new
transport functions with parameterized failure cases), 18 parser and 66 complete
planning oracle fixtures pass. All 50 Swift tests also pass with an empty tool
PATH. Seven focused existing Python sequencing tests use mocked guest/Ansible/
lifecycle calls. New helper/build scripts pass syntax compilation and 21 bundled
YAML resources pass static parsing. No real SSH/SCP/SFTP/Ansible executable,
credential contents, UI, host install or VM operation is used. The full legacy
suite and actual Ansible syntax commands were deliberately not rerun for this
fake-process-only scope; previous results remain historical evidence.

**TO PROVE / REMAINING:** actual SSH pins/authentication/quoting, Ansible and
native package parity, guest helper/systemd scope registration and privileged
cgroup descendants, hard deadlines/process ownership, real cancellation and remote
quiescence, PTY/password echo/terminal delivery, persistent recovery and explicit
session rebinding, operational CLI cutover, manager/helper/UI integration and
signed/pinned packaging/relocation. Fake runners validate specifications and result
handling, not these runtime properties. This supersedes the prior pending concrete
command-adapter/resource-materialization status only.


## Milestone 2 local runner and PTY — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** continue in the dev-vm worktree with
local process execution and PTYs tested using disposable local fixtures only.
No real SSH/Ansible execution, host installs or VM launches. The manager changes
are documentation only. No operational CLI/app setup action or feature gate is
enabled. The dev-vm continuation is committed as `bb3fae22be45b38035fac52aefa0eb270a9d0fea`
on `codex/swift-provisioning-package` (3 November 2026).

**IMPLEMENTED:** `LocalProvisioningProcessRunner` accepts exact absolute program,
argv, working directory and environment specifications. It performs no discovery,
shell expansion, credential access or inherited environment merge. Closed stdin
and bounded byte input use pipes; stdout/stderr remain separate under the combined
32 KiB capture limit. Streaming publishes raw bytes and returns empty structured
stdout/stderr. Invalid requests/missing input ownership fail before launch;
overflow/I/O errors cannot become successful zero exits.

A small `CDevVMProcess` Darwin bridge calls `posix_spawn` with a new session,
explicit signal state and close-on-exec-default descriptors. PTY execution also
requires an explicitly pinned compiled `dev-vm-process-host` launcher: Darwin
creates the session after spawn file actions, so the launcher claims its
controlling tty then execs the target under the same PID. No fork runs in the
Swift runtime. The launcher adds a package-owned binary to future helper
packaging/admission; it is not a Homebrew or Python dependency. The separate C
fixture target is test-only. Signed/relocated distribution remains pending.

Register ownership before spawn and serialize one invocation per runner and one
local invocation per VM/session across runner instances in this process. TERM
escalates to KILL after 150 ms. Keep the leader waitable to reserve its PID/group;
reap only after no live owned group members and output EOF. Background children
after parent exit force failure/cleanup. Bound post-exit draining to a 250 ms
grace, then attempt cleanup for up to 2 seconds. If proof fails, return
`cleanupUnconfirmed`, retain descriptors/ownership and block fresh runners for
that session. Exact-ID local reconciliation never launches another command.
Dropping an uncertain runner transfers retention to a local reaper; loss of wait
ownership never permits speculative PID signaling or fresh work. These controls
are in-memory and do not establish persistent/crash recovery. Process groups do
not contain deliberately detached task code; inherited-pipe evidence can reveal
some escapes but cannot prove that arbitrary code has stopped.

**LIVE TERMINAL / INPUT:** `ProvisioningTerminal` stores actual sequenced raw
frames in memory only, bounded to 8 KiB–1 MiB and 1,024 frames, with 64 KiB
snapshot batches and explicit gaps. Slow/detached viewers cannot block draining.
Frames preserve ANSI, carriage returns and split UTF-8; their descriptions are
redacted and no bytes enter structured provisioning reports. Snapshots expose
active invocation/input metadata. This is a backend, not a terminal renderer or
IPC/UI implementation. Screen reconstruction after gaps and host-action/clipboard
escape filtering remain renderer work.

One explicit lease binds reviewed job/VM/session/dependencies/mode. Input and
resize require active invocation, owner and monotonic message sequence. Limits
are 4 KiB per input, 64 KiB pending, 1–500 rows and 1–1,000 columns. Initial and
flush-time local PTY settings are raw/no-echo. Revocation is serialized with actual
nonblocking writes and drops pending input; it detaches rather than cancels the
job. Missing answers expire at the invocation deadline. No silent mid-command
owner transfer or retired lease reuse. Programs can print secrets; no automatic
redaction is promised. Native SSH/sudo password echo is still TO PROVE.

**VERIFIED — local fixture checks:** make build, 64 Swift test functions (14 new
local-runner functions), 18 parser and 66 complete planning oracle fixtures pass.
All 64 tests also pass with empty tool PATH and the absolute Swift toolchain.
Compiled launcher/fixtures are copied into private disposable UUID roots. Tests
cover exact argv/environment, stdin/EOF/capture/limits, stream floods/gaps/UTF-8,
controlling/foreground tty, SIGWINCH sizing, synthetic no-echo input, revoked or
replayed input, early/stale/concurrent cancellation, descriptor isolation,
TERM-resistant group descendants, parent exit, changed launchers and uncertain
pipe reconciliation. Fixture checks establish no live child after cleanup;
launchd reaps orphan zombies. Restricted PTY runs could not open `/dev/tty`; the
full suite passes outside that workspace filesystem restriction. An initial
direct Swift command lacked the make cache environment and failed a restricted
cache write; normal make checks use repository-local caches. No real SSH/SCP/
SFTP/Ansible executable, host install, credential, UI or VM operation is used.
The legacy suite that runs Ansible is not repeated for this scope.

**TO PROVE / REMAINING:** real SSH/Ansible/nested terminal and guest auth/echo,
remote quiescence, deliberate detached execution, kernel stalls/foreign reapers,
crash/cross-process ownership and persistent cleanup, helper admission/signing/
relocation, terminal renderer/escape filtering/viewer resynchronization, IPC and
operational CLI/manager integration. Local `.exited` proves the owned process
group/descriptors only and never releases VM clients/reservations or substitutes
for the manager's matching VM `.exited`. Earlier 9ebaf17 fake-process evidence
remains historical; this supersedes pending local-runner/PTY construction only.


## Milestone 2 pinned manager/helper integration — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** integrate the pinned Swift package and
resources into manager/helper builds, using local fixtures only. No real SSH/
Ansible, host installs or VM launches. This continuation adds
an offline package boundary; setup jobs, execution gates and VM policy remain
unchanged. No manager window is opened and no installed app is replaced.

**IMPLEMENTED — source pin:** consume an unmodified 79-file package snapshot at
`bb3fae22be45b38035fac52aefa0eb270a9d0fea` under `Vendor/dev-vm`. The Config lock
records the immutable revision, exact source/resource hashes and engine hash;
make preparation refuses drift, links and extra source files, then generates a
compiled pin. Source export avoids requiring the separate/unpublished dev-vm
worktree. Root `Package.resolved` exactly pins TOMLDecoder to `a2bbd27`; the
upstream lock/source/engine inventory stay untouched. Parser licenses ship inside
the resource bundle and the manager's notices now identify them. Optional parser
plugin/doc/benchmark flags are refused. Builds use local SwiftPM caches and skip
update checks; fresh developer builds can still need normal SwiftPM source
resolution for the exact TOML dependency. No host program is installed.

**IMPLEMENTED — offline manager/helper API:** manager core links
`DevVMProvisioningCore` and exposes `BundledProvisioning` admission, validation
and planning. `OmarchyVMProvisioningHelper` supports only
`--verify-package-json`, `--validate-manifest-json FILE` and
`--plan-json REPOSITORY [MANIFEST]` (plus help). It never creates a process runner,
reads manager registry/Keychain/defaults, connects to the manager socket, discovers
tools or reaches a VM. Apply/check/recover/exec commands are refused. Plans still
emit `execution_available: false`. The existing CLI/guest-command schema and all
setup feature gates remain unchanged; tools-page text now distinguishes packaged
offline APIs from the disabled product workflow.

**IMPLEMENTED — packaging:** compile the unchanged pinned `dev-vm-process-host`
C entry point through a generated standalone SwiftPM package. Its manifest and
single source file are the only admitted build inputs. App assembly embeds the
shared SwiftPM resource bundle and licenses, provisioning helper, PTY launcher,
source lock and a final-binary-hash distribution manifest. Child executables are
signed before their hashes are recorded; the outer app signature seals that
manifest. Existing layout, bundle-only, diagnostics and signed-release verifiers
now require these assets. Manager bundle diagnostics report the source revision
and disabled provisioning execution. No existing runtime kit/factory is changed.

Admission rejects a changed source lock, missing/damaged/extra resource data,
symlinks/special files, ambiguous resource layouts, changed/nonexecutable children,
malformed or duplicate metadata, and debug resource-bundle overrides. Embedded
resources are checked against the compiled hash inventory before/after offline
work; library-generated plan engine identity must also match the admitted engine.
Both flat SwiftPM bundles and `Contents/Resources` layouts are supported. File
reads are bounded/no-follow with before/after metadata checks. These are integrity
checks; signing authority is checked by the app's packaging/signature pipeline,
not granted by the editable distribution manifest or a tools report.

**VERIFIED — no-VM checks:** `make build`, `make test-provisioning-package` and
`make test` pass: 227 Swift tests in 38 suites, 48 script tests, and relocated
package fixtures. New admission tests cover both layouts and damage/missing/
extra/symlink/metadata cases. A copied fixture app is ad-hoc signed, moved to a
path containing spaces/apostrophes and made read-only. Its actual offline helper
validates/plans with `PATH=/nonexistent` and empty private HOME/TMPDIR, produces no
host state, omits synthetic variable values, rejects execution commands and
resource overrides, and fails on resource/launcher tampering. Deep strict ad-hoc
signature verification passes before tampering and rejects changed resources.
The fixture contains manager code for sealing but never executes or opens it;
it contains no runtime kit or VM. No real SSH/SCP/SFTP/Ansible, credential access,
host installs, UI takeover, image download, app installation or guest operation
occurs. The separate dev-vm source/engine code remains unchanged at its pin.

Initial sandboxed full regression runs could not bind local sockets and could not
retain expected synthetic LAContext properties; the complete suite passes outside
that restriction without authentication UI or real Keychain calls. An initial
SwiftPM update attempt lacked network access; subsequent builds reused existing
exact Git objects with update checks disabled. Neither workaround changes host
software or the dependency version.

**TO PROVE / REMAINING:** full app assembly with the unchanged real runtime kit,
Developer ID/notarization and other toolchain/install layouts, read-only release
relocation on another Mac, job journal/coordinator/lifecycle interlocks and
manager session/dependency adapters, authenticated helper IPC, terminal renderer/
stream attach, operational UI/CLI, persistent recovery and all real SSH/Ansible/
guest authorization/echo/quiescence checks. A relocated offline package fixture
is not full installed-app or real-guest acceptance. VM clients and reservations
still require the matching VM `.exited` boundary.


## Milestone 3 coordinator/journal foundation — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** start milestone 3 with a provisioning
coordinator and job journal, using fake runtimes/adapters and local fixtures only.
No real SSH/Ansible, host installs or VM launches. This foundation is maintained on
`codex/dev-vm-provisioning-plan`.
The foundation has no public constructor or app/helper/CLI execution entry point;
existing execution gates remain disabled. The immutable dev-vm code/resource pin
stays `bb3fae2` and the shared sequencer continues to own guest authorization and
cleanup order. The manager does not duplicate Ansible or VM orchestration.

**IMPLEMENTED — coordinator:** `ProvisioningCoordinator` owns one detached job at
a time alongside VMManager, with an explicit package-admission callback and typed
session/dependency authority. Submission validates reviewed source/engine identity,
task/grant consent and exact current VM/session/SSH owner; the engine handles the
remaining authorization policy. An accepted job UUID plus review digest deduplicates
lost replies, including completed attempts. Conflicting reuse is refused and a
new apply needs a fresh reviewed job. Waiting or cancelling a viewer cannot cancel
the worker; cancellation is an explicit job operation. Missing input returns
`authorizationRequired` without any guest call; attaching/resuming such a prompt
within the same job is future UI/IPC work and currently requires a fresh review.

A manager wrapper journals command/job/payload correlation before delegation and
revalidates the lifecycle lease and dependency authority around actor hops. It
rejects stale generations/payloads and body work after cancellation. Package
admission is repeated before body work. Frozen original cleanup commands may
still run if source/package data changes; they require the same verified guest
and dependencies. Primary failure and bounded typed cleanup failures remain
separate. Restart-required results are metadata only; no automatic restart or
rebinding is added. Public snapshots carry fixed states/codes and manager-owned
IDs, never terminal bytes, source contents or arbitrary adapter diagnostics.

**IMPLEMENTED — journal:** `ProvisioningJobJournal` takes one explicit owned
0700 directory and retains a private 0600 file-description lock. Schema-1
`jobs.json` stores approved review/plan/input/engine/dependency/binding digests,
job/VM/session/payload/command IDs, mode, sequence, attempt count and structured
status. Binding is an opaque digest, not an owner/key record. No credentials,
credential paths, source paths/bytes, terminal data or helper PID are persisted.
Writes are private atomic rename plus file/directory fsync. Check directory/lock
identity and index revision before writes. Unknown/duplicate fields or IDs, bad
schemas/digests/states, links, insecure modes, excess size, external edits/removal
and replaced directories/locks fail closed and preserve existing data. Limits are
128 records, 1 MiB and 32 typed cleanup codes; no history is silently pruned.

Persist conservative cleanup risk before starting the shared driver and command
identity before any adapter call. A journal failure stops new body work while
still attempting known-target quiescence/revocation. The last durable risk marker
and in-memory lease stay conservative if a final write fails; new admissions are
blocked rather than reporting success. On reopen, unfinished jobs become
interrupted or cleanup-required, never resumed. Private source snapshots remain
in memory for the current attempt; durable frozen-input capsules are not added in
this foundation, and no arbitrary setup replay is supported after a crash.

**IMPLEMENTED — lifecycle interlocks:** an installed coordinator reserves one
job in VMManager. Pause/resume, suspend/restore, start, configuration and deletion
are blocked for the affected VM while work or unresolved cleanup is held. Ordinary
shutdown is deferred while cancellation/cleanup runs; Quit follows the same path.
Force stop requires the existing explicit confirmation, invalidates the job and
retains cleanup uncertainty. Unexpected VM exit, execution sleep/pause/unknown or
SSH-owner/readiness changes cancel setup and prevent retargeting. `.error` remains
a diagnostic only. Only matching VM `.exited` releases runtime handles, memory and
ports; no job completion or journal status releases them.

A default 240-second cancellation-cleanup grace (up to 300, shortened in fixtures)
records uncertainty on expiry while retaining the outstanding worker/lease. For a
pending shutdown/Quit, VMManager then follows its normal graceful shutdown policy;
it may finish Quit after the matching VM exit even if setup remains unresolved.
It does not infer remote quiescence or kill a helper by stored PID. Final clean
engine proof is sealed atomically in VMManager before a later lifecycle event can
invalidate an already-completed attempt. No automatic forced power-off is added.

**IMPLEMENTED — recovery boundary:** same-process explicit cleanup recovery uses
the engine's original opaque ticket, exact guest/session/dependency/engine pins and
a new driver/generation. It needs neither original sources nor terminal input and
never stages, grants, applies or restarts. Clean proof clears the affected hold.
The pinned engine does not export a persistent cleanup-ticket format: after
process restart, `recoveryUnavailable` preserves the cleanup hold until a future
authenticated helper/recovery protocol supplies proof. Stopped state or a saved
PID cannot clear it. This is intentionally not full post-crash recovery.

**VERIFIED — fake/local checks:** `make test` passes 248 Swift test functions in
40 suites (21 new coordinator/journal functions with parameterized cases), 48
script tests and the existing relocated/read-only offline-helper package checks.
Coverage includes write-ahead bytes/modes and exclusive locking, corruption and
external replacement, stale review/source/dependency/package admission, duplicate
submissions, missing input, viewer cancellation, shutdown during authorization,
confirmed force stop, unexpected exit/sleep/SSH loss, cleanup deadlines with an
unresponsive fake, journal failure during work, live recovery after source removal,
reopen without resume and preservation of VM ownership until matching exit. New
provisioning tests execute no subprocess; package and existing dependency tests
use local fixtures. Full regression uses the previously required sandbox exception
for existing socket/synthetic LAContext tests, without actual Keychain access or
authentication UI. No real SSH/SCP/SFTP/Ansible, host installation, UI action, image
download, installed-app change or VM operation occurs.

**TO PROVE / REMAINING:** production coordinator construction and authenticated
helper IPC/ownership, durable frozen inputs and persistent ticket/recovery design,
explicit SSH-ready waits and reviewed restart/session rebinding, UI/CLI job and
terminal attachment, journal retention/migration policy, real helper crash/kernel
stalls and hard wall-clock cleanup guarantees, and every real guest/transport/
authorization/echo/quiescence scenario. Private metadata locking is not a
transaction against a malicious same-user writer. This slice establishes a
coordinator/journal foundation, not completion of milestone 3 or guest acceptance.


## Milestone 3 durable inputs and cleanup recovery — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** continue milestone 3 using fake runtimes,
fake guest adapters/ownership authorities and disposable local fixtures only. No
real SSH/SCP/SFTP/Ansible execution, host installs, VM launches or UI operations.
This section supersedes the earlier foundation's pending durable-input/checkpoint
status and 1 MiB journal limit. Operational execution remains disabled.

**IMPLEMENTED — frozen inputs:** before publishing the running risk marker or
starting a worker, allocate the payload UUID and worker token, then fsync two
immutable UUID-named files in an explicit private 0700 artifact directory. The
0600 `.inputs` archive holds only the selected frozen manifest/files, original
modes and selected directory membership, including empty directories. It contains
no absolute host paths/root inode identities or fetched credentials. Selected
user configuration can itself be sensitive: this archive is private storage,
never status/plan/terminal output. It is not encrypted or a credential vault.

The shared `DVMSNAP1` binary format has a versioned, duplicate-aware JSON metadata
header and raw file bytes. Its reader checks exact fields, safe relative paths,
file hashes, lengths, sorted unique entries, directory references, snapshot
identity and EOF. Bounds are 8 MiB metadata, 32 MiB file bytes, 4096 files, 4096
directories, 8192 total children and 150000 JSON values; path depth is at most 64.
Restoration returns a redacted, inert `FrozenInputsArchive`, never a SetupPlan or
apply authority. There is no extraction/replay API or resume-apply path. Body
admission checks the archive's exact journaled SHA-256 as well as the original
source/package/session/dependency checks.

**IMPLEMENTED — durable cleanup:** the separate 0600 `.cleanup` envelope binds a
version-1 shared-engine checkpoint to the worker token. Schema-2 `jobs.json`
contains only both artifact hashes and the token/payload alongside the existing
approved review/plan/input/engine/dependency/binding digests. It still excludes
source bytes/paths, credentials, guest owner/key values, terminal bytes and PIDs.
The checkpoint privately contains the original guest identity and cleanup scope;
it carries no private key, terminal input or source bytes. Restoring it compares
all fields with an independently supplied original identity and always assumes
work/payload risk, plus grant risk for apply. Stored flags cannot claim cleanliness.
The engine now retains its control payload until both work and grant/cache
inactivity have been proved, so failed revocation proof cannot remove the helper.

Cleanup after reopening is explicit. A fresh caller supplies the original live
GuestBinding; exact VM/session, binding, engine and dependency checks still apply.
An injected recovery authority must answer a fresh UUID challenge binding the job,
VM/session/payload/worker, checkpoint, engine/dependencies and approved review. It
must prove the previous worker is **stopped and fenced from further launch**;
stopped/running/unknown metadata or a PID is insufficient. A stale/mismatched
permit is refused, and session/dependencies are rechecked after the await and
before every guest call. The original live ticket may be used when available;
a reopened coordinator instead restores the hash-bound checkpoint. No input
archive or source tree is needed for cleanup, so damage there cannot suppress
revocation. Missing/damaged checkpoints without a genuine live ticket preserve
`cleanupRequired` and delegate nothing.

The permitted sequence verifies identity before each of quiescence, apply-only
revoke/cache clear/inactive proof, and payload removal. It cannot stage, install,
configure, grant, prompt, resume apply, restart or rebind. Only fresh final clean
proof clears the lifecycle hold. Idle close/reopen releases the journal lock and
drops all live tickets; active close is refused and VM blocks survive handoff.
The fixture recovery boundary is a surviving VMManager session, not adoption of a
VM after a full manager/VM restart. No production ownership-channel implementation
or helper IPC is enabled in this slice.

**IMPLEMENTED — storage bounds/migration:** journal schemas 1 and 2 are readable;
new writes use 2. Legacy rows retain risk and never acquire invented checkpoints.
Unknown schemas, partial durable references, unsafe modes/links/root replacement,
changed hashes and oversize data fail closed and preserve files. The journal limit
is now 256 KiB, matching the existing strict parser; 128 rows and 32 cleanup codes
remain. Artifact quota defaults to 256 MiB and at most 512 files, counts orphans,
and fails admission before any worker. Pre-index crash artifacts are never
imported/replayed or automatically deleted. Cleanup completion retains artifacts;
a reviewed retention/removal policy remains future work. File/directory fsync and
index-before-delegate ordering are tested locally; this is not a transaction
against a malicious same-user writer or evidence of power-loss durability.

**PRIVATE COUPLING — package provenance:** the manager now uses the immutable
`bb3fae22be45b38035fac52aefa0eb270a9d0fea` base plus the exact content-hashed
`Patches/dev-vm-durable-state.patch`, rather than claiming an unchanged base engine.
The lock records the base inventory, patch hash, resulting 82-file inventory,
source-snapshot digest and updated engine resource hash. Preparation verifies the
result, reverse-applies the patch in a disposable directory and checks the exact
base inventory. No mutable external checkout is a build/runtime dependency.
Package status/diagnostics expose the resulting source-snapshot digest alongside
the base revision. Parser/guest-resource bytes and the C launcher are unchanged.
See [the package boundary](../Vendor/DevVMProvisioning.md).


**VERIFIED — fake/local checks:** `make test` passes 260 manager Swift test
functions in 40 suites, 49 script tests and the relocated/read-only offline-helper
package checks. The 12 new coordinator/journal functions include parameterized
cases for fresh fencing challenges, running/unknown/mismatched worker proof,
wrong original session/binding/dependencies, target exit during proof, interrupted
risk markers, source/input removal, checkpoint corruption/swap/links/modes/root
replacement, quota/orphan handling, archive privacy and active-close rejection.
An existing graceful-shutdown race was also fixed: completion checks the original
guest identity independently of new body admission, so pending graceful shutdown
cancels body work without suppressing cleanup. The fake can explicitly ignore
interrupts to exercise that boundary. Force-stop/changed-target interlocks remain.

Shared `make build-provisioning test-provisioning test-provisioning-oracle test-provisioning-planning-oracle ORACLE_PYTHON=/opt/homebrew/opt/ansible/libexec/bin/python`
passes 68 Swift functions, 18 parser oracle fixtures and 66 planning/error oracle
fixtures. The existing Ansible-environment Python is used only for development
comparisons; no Ansible executable or runtime fallback is used. Existing local
PTY tests need `/dev/tty` outside the workspace sandbox; full manager regression
uses the existing exception for local sockets/synthetic LAContext and ad-hoc sealed
package fixtures. No real SSH/SCP/SFTP/Ansible, Keychain/authentication UI, host
install, image download, manager UI or VM operation occurs. Local file/fsync checks
do not demonstrate real helper/process-crash or power-loss recovery.

**TO PROVE / REMAINING:** authenticated production helper ownership/fencing,
coordinator/helper construction, full manager process restart and reviewed VM
session rebinding, SSH-ready waits, live terminal/job UI and CLI, reviewed artifact
retention, real helper/guest crash recovery, absent control-helper reconciliation,
power-loss behavior and every real SSH/Ansible/authorization/echo/quiescence case.
If a missing helper cannot prove absence, cleanup remains required. Real VM
clients/resources still require matching `.exited`; archives do not change VM
ownership policy. This slice does not complete milestone 3 or real guest acceptance.


## Milestone 3 authenticated helper IPC and ownership — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** add authenticated helper IPC and ownership
reconciliation using fake runtimes/process runners and local fixtures only. No
real SSH/SCP/SFTP/Ansible, host installs or VM launches. Use the supplied Setup-tab
screenshot as the future terminal UI reference; no user UI is opened or changed.
This section supersedes the earlier pending IPC/fake-authority-only statements.
Production job submission/delegation and setup execution gates remain disabled.

**IMPLEMENTED — private control protocol 1:** a manager/helper connection is an
explicit inherited AF_UNIX stream, with same-user peer credentials and CLOEXEC/
nonblocking/no-SIGPIPE descriptors. There is no path-addressed listener, discovery,
PID lookup or credential file. A fresh per-launch 256-bit capability and channel
UUID pass through a bounded anonymous stdin pipe, never arguments, environment,
disk, logs or the job journal. Capability descriptions are redacted. Both peers
share an independently expected helper instance UUID, exact helper executable
SHA-256 and package-lock SHA-256. The packaged helper independently admits its
resources/distribution and compares bootstrap pins with its actual executable.

Length-prefixed bounded frames carry canonical signed JSON and HMAC-SHA256. The
MAC covers protocol version, complete helper identity, channel, direction,
monotonic sequence and exact payload bytes. Request UUID and a fresh coordinator
challenge bind every reply to the exact original job/VM/session/payload/worker,
engine, dependencies, guest-binding digest, approved review and checkpoint hash.
Unknown fields/types/versions, duplicate keys, changed pins, reflection/replay,
wrong keys, partial/oversize frames and uncorrelated replies fail closed. Frame
size is 24 KiB, payload 12 KiB and bootstrap 4 KiB. Active frame/send deadlines
are bounded (default 3 seconds); idle server reads remain interruptible by socket
shutdown. One client request may be outstanding; the server serves only once.
A lost/malformed reply poisons the channel, never automatically retries a command
or clears cleanup. A new channel requires a new trusted bootstrap.

This is capability authentication tied to an admitted launch, not a claim of
Developer ID/signing authority or protection against a malicious same-user memory
reader. The production manager must launch the exact independently admitted helper
and pass only its private descriptors. That automatic launcher/executor wiring
remains disabled. A saved helper ID, PID or matching user alone proves nothing.

**IMPLEMENTED — original-worker ownership:** the helper-side registry accepts
immutable bindings only from the trusted local job owner, never a wire registration
or disk import. It retains at most 128 original-worker records/tombstones and
rejects replacement. Missing state, an empty/new helper or changed scope returns
`unknown`; absence cannot prove another helper's worker stopped. Each registered
worker uses a `ProvisioningFencedProcessRunner` over its exclusively owned backend.
The wrapper validates the original job/payload/guest/session/dependency/mode on
every invocation, registers ownership before its launch actor hop, rejects ID
reuse, and permits one local invocation at a time.

Reconciliation permanently closes that runner's launch gate before any await,
cancels/interrupts only its exact owned invocation, waits for its matching result
and requires `.exited`/`.notStarted` or exact retained local-cleanup reconciliation.
A wrong invocation ID or `cleanupUnconfirmed` retains the backend and uncertainty.
Late/duplicate observers cannot erase uncertainty. Concurrent queries share one
stop attempt and completed tombstones never reopen the gate. Task cancellation,
a diagnostic, socket EOF or a local exit alone cannot prove guest quiescence or
sudo revocation. Disconnect fences registered local workers and refuses new
registration. If a backend stalls, the client times out but the helper retains
its outstanding task/ownership; it does not signal a PID read from disk.

The authenticated client now conforms to the coordinator recovery-authority
contract. Fake-runtime tests close/reopen the coordinator, authenticate/fence its
original registered worker, then run only the existing shared-engine cleanup
sequence against a freshly revalidated original session. Missing ownership,
uncertain processes or a disconnected helper preserve the VM cleanup hold. The
old worker's runner stays fenced even after clean remote proof. VM handles and
reservations still require the matching runtime `.exited`.

**IMPLEMENTED — packaged helper boundary:** the internal
`--ownership-channel-fd FD` mode consumes only an inherited Unix stream and
anonymous bootstrap pipe after package admission. It constructs an **empty**
ownership registry and can authenticate an `unknown` response, but creates no
runner, journal, saved guest credential/Keychain access, VM, tool probes or operational job.
There is no apply/check/recover/exec/terminal/PID command in this wire protocol.
The existing offline validate/plan APIs and disabled execution report remain.
The shared dev-vm code/resources and immutable base-plus-durable-patch pin are
unchanged by this manager-only continuation.

**VERIFIED — fake/local checks:** `make test` passes 275 manager Swift test
functions in 41 suites (15 new IPC/coordinator functions with parameterized cases),
49 script tests and the expanded relocated/read-only helper packaging fixture.
New tests cover wrong keys/pins, directional replay/reflection, duplicate/unknown/
oversize/truncated frames, request/challenge mismatches, busy/one-shot channels,
exact process receipts, concurrent stop queries, worker tombstones, disconnect/
timeout uncertainty, unchanged original bindings, missing state and authenticated
cleanup after coordinator reopen. All invocation backends in the new Swift tests
are fake; no real process runner is constructed there.

The actual packaged helper is ad-hoc signed/sealed in a disposable app without a
runtime kit and relocated read-only. Empty PATH and private empty HOME/TMPDIR are
used for the inherited socket/pipe fixture. A development Python peer verifies
the helper's response MAC and exact correlation; the empty registry returns
unknown, valid request replay/wrong MAC close the channel, mismatched bootstrap
binary pins are rejected, and no stdout/stderr secrets or host state are produced.
Strict app-signature/resource-damage checks still pass. The fixture launches only
the ownership/offline helper, never the manager UI or an operational engine.
Full regression uses the existing sandbox exception for local sockets/synthetic
LAContext; no actual Keychain/authentication UI, real SSH/SCP/SFTP/Ansible, host
install, image download, installed-app change or VM operation occurs. Shared-engine
code/pins are unchanged, so prior package/oracle evidence is not claimed as a new
shared test run. These fixtures do not prove release signer or real guest behavior.

**TO PROVE / REMAINING:** automatic admitted manager/helper launch, exclusive
backend construction and registration before operational job start, sequencer/job
IPC delegation, signer/audit-token policy where required by distribution, full
manager process restart/reconnection and reviewed session rebinding, helper-crash
and guest-side quiescence/revocation, hard kernel-stall deadlines, terminal stream/
input-lease transport and UI/CLI attachment. The inherited capability and live
helper registry currently survive coordinator reopen, not full manager/VM restart
adoption. A replacement empty helper cannot manufacture lost ownership proof.
Channel-close local fencing is not yet an operational remote-cleanup driver.
Raw terminal/input bytes remain separate and in memory only; no sample output or
ANSI parsing is used for ownership or successful completion.


## Milestone 3 admitted helper launch and worker registration — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** continue milestone 3 with admitted helper
launch and worker registration using fake runtimes and local fixtures only. No real
SSH/SCP/SFTP/Ansible execution, host installs or VM launches. This supersedes the
previous pending launch/registration and empty-registry-only statements. The new
internal path reserves an **inert** worker; it never constructs a transport runner,
dispatches the shared engine or enables an app/CLI execution gate.

**IMPLEMENTED — admission/launch:** `ProvisioningHelperLauncher` admits one pending
or live helper at a time, rooted in an explicit private control directory. Admission
checks the exact embedded package/distribution, the strict signed outer app and
nested helper signatures, the helper's complete SHA-256 and code-directory hash.
The default policy requires non-ad-hoc app/helper code with the same nonempty Team
ID. An explicit internal `adHocFixture` policy accepts only ad-hoc/no-team code for
local tests; no product entry point chooses it or creates a launcher.

Admission retains the original executable descriptor and checks inode/device,
mode, size, timestamps, path identity, bytes and signatures again at launch.
`posix_spawn` uses the exact executable path, fixed ownership-channel arguments,
explicit private cwd/HOME/TMPDIR and an empty tool PATH. CLOEXEC-default spawn
inherits only stdin bootstrap, null stdout/stderr and control descriptor 3; other
descriptors are closed. Capability bytes travel through the bounded anonymous
pipe, never argv/environment/files/logs. Before handing over those bytes, recheck
the admitted package and the **owned live child** through Security.framework with
a dynamic cdhash requirement. This avoids trusting a path replacement or a PID
alone. The transient PID is obtained only from this spawn and is neither persisted
nor used to adopt, signal or claim a previous helper.

The waitable child handle, socket, bootstrap state and volatile launch capability
stay owned until the matching child is reaped. EOF closes only the exact owned
channel; no speculative PID kill is added. A lost/unconfirmed child wait retains
uncertainty and prevents another launch. Completed entries become bounded
non-secret tombstones (128 maximum); duplicate tickets/jobs cannot relaunch and
there is no automatic restart. Empty private control directories may remain; no
VM storage is created, reset, deleted or moved.

**IMPLEMENTED — bootstrap/registration:** private bootstrap version 2 extends the
existing authenticated channel with one metadata-only worker reservation. It
contains original job/VM/session/payload/worker, review/engine/dependency/binding/
checkpoint identities, plus plan/input digests, mode and the new expected helper
identity. No executable plan, source content, guest username/key/credential,
process invocation, tool location or terminal bytes are sent. Version 1 remains
an empty ownership registry for compatibility; it cannot acquire registrations.
The helper checks its actual package/binary pins and exact owner, registers the
reservation locally, then sends an authenticated `registered` receipt covering the
whole registration digest before accepting reconciliation. The MAC sequence
continues after this first receipt; it is not reset. A changed/missing receipt
poisons the connection. No ordinary registration, activation, shell or start
command is added to the wire protocol.

A reserved worker cannot run anything. Reconciliation permanently retires its
not-started reservation; replacement/duplicate registration cannot reopen it. An
empty helper still returns unknown for missing records. Existing active-runner
fencing remains separate and still requires matching local exit/cleanup proof,
followed by the shared engine's original-guest remote cleanup. Future executor
activation must consume the original reservation without reopening a fenced one.

**IMPLEMENTED — durable coordinator ordering:** `registerHelperWorker` repeats
review/package/source/session/dependency admission around helper preparation and
receipt. It freezes inputs, allocates payload/worker IDs, prepares an admitted
launch ticket without spawning, then fsyncs schema-3 owner metadata **before**
launch. The row records helper instance/executable/package pins, full registration
SHA-256 and `helperRegistered: false`. Only the exact authenticated receipt and
fresh admission permit the final true marker. The job stays `queued`, with no
engine task (`workerOutstanding: false`) and a conservative cleanup hold. This
marker describes a reserved helper worker, not a running or successful setup.
Accepted duplicate job/review submissions return that same state without launch
or body dispatch; other setups cannot bypass the outstanding helper hold.

Schema 3 reads schemas 1/2 without inventing owners and rejects owner fields in old
schemas, unknown nested fields and partial owner records. Existing privacy,
256 KiB/128-row limits, private atomic/fsynced writes and artifact quota/orphan
rules remain. A failed admission before publishing can leave counted immutable
input orphans; they are never silently replayed/overwritten. After owner
publication, spawn/receipt/final-write/session failures preserve that exact owner,
`cleanupRequired` and typed failure, close only its channel and retain any owned
child through exit. No saved owner is converted into a new launch credential.

Explicit recovery uses the same surviving launch service/channel, original owner
and a fresh challenge; another helper instance cannot substitute itself. Clean
remote proof invokes the exact launcher's release callback, closing its helper
channel while its child observer retains ownership until exit. Closing/reopening
the coordinator keeps durable owner pins/VM holds; the caller must retain and
explicitly supply the same live launch service. Full manager-process restart
adoption remains unavailable, and an empty replacement helper proves nothing.
Only VMManager still owns guest lifecycle/resources until matching VM `.exited`.

**VERIFIED — fake/local checks:** `make test` passes 284 manager Swift test
functions in 42 suites (9 new registration/coordinator/journal functions with
parameterized cases), 49 script tests and the expanded relocated/read-only signed
package fixtures. New Swift tests use fake runtimes/launch providers and local
sockets, never real SSH/Ansible runners. They cover pre-spawn journal owner pins,
exact receipt/digest/correlation, inert duplicate submissions, stale source/tools/
package during admission, prepare/spawn/receipt/final-write failure, session exit,
owner substitution, same-service coordinator reopen and schema-1/2 preservation.

The actual admitted factory is exercised by `OmarchyProvisioningLaunchFixture`, a
debug-only Swift build product excluded from app staging and disabled in release.
Against a private ad-hoc sealed/read-only app, production signing policy rejects
the fixture; explicit fixture policy admits it. Resource tampering and an
identical-byte executable inode replacement between preparation and launch are
rejected. Normal launch verifies the loaded child's cdhash, hands off bootstrap 2,
receives the registered receipt, fences its inert worker, refuses a duplicate
ticket, closes the channel and observes the matching reaped child. The private
control cwd remains empty; keys are not written or printed. The existing empty
bootstrap-1/unknown/replay/wrong-key/binary-pin and strict signature/tamper fixtures
still pass. An initial fixture failure assumed one SwiftPM resource layout; the
fixture now uses the same unambiguous admitted resource lookup as the helper.

Full regression uses the existing sandbox exception for disposable sockets,
synthetic LAContext and local helper fixtures. Only ad-hoc fixture signing is used;
no real signing credentials, Keychain/auth UI, SSH/SCP/SFTP/Ansible, installs,
images, manager UI or VM operations occur. Shared engine sources/pins are unchanged,
so its prior package/oracle results are historical evidence rather than a new run.
This does not demonstrate positive release-signer admission or real guest behavior.

**TO PROVE / REMAINING:** operational engine/job dispatch and backend activation,
product coordinator/launcher construction, real Team-ID/release signer acceptance,
audit/reconnect policy and full manager restart, reviewed guest session rebinding,
SSH-ready waits, real helper/guest crashes and remote grant cleanup, kernel-stall
hard deadlines, reviewed retention and live terminal/input-lease/UI/CLI integration.
The prior Setup-tab screenshot remains a visual reference; this slice changes no
UI and emits no fabricated terminal output. Shared dev-vm source/resources and the
base-plus-durable-patch engine pin remain unchanged.


## Milestone 3 helper-side engine dispatch and activation — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** continue milestone 3 with helper-side
engine dispatch/worker activation, tested using fake runtimes and local fixtures
only. No real SSH/SCP/SFTP/Ansible, host installs or VM launches. This section
supersedes the earlier no-activation/dispatch foundation status. The shared engine
is invoked against injected fake adapters; the product helper has **no backend
factory**, returns `executionUnavailable`, and every product execution gate remains
disabled. This is not an operational VM provisioning release.

**IMPLEMENTED — one-shot activation:** new authenticated control payloads expose
`activate`, `status` and `cancel` over the existing frame-1/bootstrap-2 channel.
Activation binds one activation UUID, the exact registration digest and original
job/VM/session/payload/worker/review/engine/dependency/binding/helper identities.
It also carries the review acknowledgements for custom tasks, persistent grant
and Docker root access. The helper combines each acknowledgement with its locally
prepared approval using AND, so a permissive factory cannot invent missing consent.
There is no command line, executable path, arbitrary source/plan, credential,
terminal input or guest-discovery parameter in these messages. Request UUID,
activation/digest, direction and MAC sequence remain exact correlation boundaries.
Unknown kinds/fields/types, changed identities or malformed status poison the
channel; known fixed denials are authenticated and never trigger fallback/retry.

Each prepared registration owns a `ProvisioningHelperEngineWorker`. Its first
activation reserves the immutable activation identity before an owned task can
prepare context or run. The same activation returns the current snapshot without
another preparation/task, even after completion; any changed activation conflicts.
A reservation fenced before activation cannot reopen. The context factory is
helper-local, injected and required to prepare without running processes/guest
commands. It returns the reviewed request/approval, original session authority,
exclusive fenced runner and adapter. Validate job/guest/binding/dependencies/mode,
review, plan/input hashes, engine identity, runner scope and frozen sources before
using it. Product frozen-input/context transfer and real transport construction
are not enabled by this API.

**IMPLEMENTED — helper execution:** the worker invokes the pinned shared
`ProvisioningSequencer` once, with the preallocated original payload UUID. The
helper does not duplicate its native authorization/apply/check/cleanup rules.
An adapter wrapper revalidates original command/context/plan/mode and session/
dependencies around commands. Package admission is checked before body work;
cleanup remains independent of current source/package availability. A known-closed
manager channel prevents body dispatch before/after asynchronous preparation and
admission. Cancellation/fencing bars further body work while allowing the shared
sequencer's original-target cleanup attempt, without input. No terminal/prompt
text is parsed for control or completion.

The task outlives its viewer/RPC. Control reads status and requests cancellation
without waiting for the whole job. Bounded typed snapshots expose activation,
monotonic sequence, phase, command/operation, outcome, primary failure and separate
cleanup failures, not inputs, owner names, credentials, terminal or raw errors.
A completed engine is not sufficient local-exit proof: retire its command gate,
fence/reconcile its exact local runner, and override apparent guest success with
cleanup-required if local ownership is uncertain. The original context/runner
stay retained. Disconnect requests cleanup/fencing and the helper waits for owned
local tasks/cleanup rather than exiting on EOF with an unconfirmed child. Local
reconciliation never reruns the engine or claims remote grant revocation. Hard
kernel stalls remain unproved; retaining uncertainty is deliberate.

**IMPLEMENTED — coordinator/journal:** `activateHelperWorker` revalidates the exact
registered review, private inputs, package, session and dependencies, reserves the
VM lease and fsyncs schema-4 activation UUID/digest plus running/cleanup risk before
sending any activation RPC. Detached manager polling then consumes authenticated
status and sends explicit cancellation once when requested. One control request
is in flight; viewers do not own the helper task. Regressing sequence, conflicting
same-sequence snapshots, wrong activation/result, lost replies or journal failure
retain cleanup-required and close only that helper channel. No automatic body
retry occurs. Accepted duplicate activation, including after coordinator reopen,
returns recorded state rather than dispatching again.

Schemas 1/2/3 preserve existing risk and never acquire invented activation markers.
New markers require an acknowledged original helper and reject partial/null/legacy
fields. Reopen converts unfinished work to cleanup-required and does not resume
polling/apply. The original surviving service/owner is still required for explicit
cleanup recovery. Helper failure, runtime exit, SSH/readiness or dependency changes
cannot clear the VM hold; an error diagnostic alone remains nonterminal. Ordinary
shutdown cancels/cleans before normal guest shutdown, and the existing cleanup
grace records risk before abandonment. Final clean proof seals the original lease;
matching VM `.exited` alone releases its handles/resources. Matching helper-child
exit remains separately owned by the launch service.

**PRIVATE COUPLING / PRODUCT BOUNDARY:** the product helper's public inherited
entry point passes a nil context factory. A distinct, excluded debug fixture binary
contains the synthetic factory. Tests copy that binary into a *separate* temporary
fixture app's helper slot, regenerate its distribution manifest and ad-hoc-sign it.
The admitted launcher therefore verifies the actual fixture image before handoff;
the normal app/helper is not modified or enabled. The fixture prepares a fixed
synthetic manifest in its private cwd and uses fake proofs/no executable backend.
No production flag, environment override or RPC can select that factory. Raw
archive transfer, reconstruction into an executable plan and terminal transport
remain absent. Shared dev-vm code/resources and engine/source pin are unchanged.

**VERIFIED — fake/local checks:** `make test` passes 297 manager Swift test
functions in 43 suites (13 new engine/coordinator/journal functions with
parameterized cases), 49 script tests and the expanded signed package fixtures.
New tests cover shared-sequencer apply/check, exact original payload/guest pins,
activation idempotence/conflict, missing acknowledgement, changed context/source,
fence-before-activation, disconnect during preparation, cancellation with grant
cleanup, physical uncertainty overriding clean guest result, and retained runner
reconciliation without another engine run. Manager tests verify journal-before-RPC,
viewer detach, shutdown ordering, malformed/lost status/replies, failed writes,
no replay after reopen, source preflight and explicit original-owner recovery.
Exit/SSH/dependency changes retain cleanup-required; error diagnostics alone leave
runtime ownership intact. Schema-4 activation fields reject partial/null/legacy or
unregistered markers and preserve legacy owner/risk metadata without invention.

The regular relocated/read-only helper rejects activation with no factory. A
separate temporary fixture app is explicitly re-sealed/ad-hoc-signed with the
excluded debug binary as its helper. The real admitted launcher verifies that
image, activates its actual shared sequencer using only synthetic adapters, polls
completion, cancels a second fixture job with cleanup, fences the original worker,
rejects duplicate launch and observes matching reaped child exit. No fake backend
is installed into the normal helper/app. Capability/registration/signature/tamper
fixtures still pass. The shared package is unchanged; prior package/oracle checks
are not presented as a new run.

Full regression uses existing sandbox exceptions for disposable sockets,
synthetic LAContext and local helper fixtures. Only ad-hoc fixture signing is used.
No real signing credentials, Keychain/auth UI, real SSH/SCP/SFTP/Ansible, host
installation, image download, user UI, installed-app change or VM operation occurs.
These are synthetic guest proofs, not new real-guest validation evidence.

**TO PROVE / REMAINING:** production frozen-context delivery/validation and consent
handoff, exclusive real adapter/backend construction, manager-aware per-command
session authority, product coordinator/launcher wiring, live terminal/PTY/input
leases and UI/CLI attachment, full manager/helper restart/reconnect and reviewed
rebinding, real release-signature acceptance and all real guest/auth/echo/remote
quiescence/crash/kernel behavior. Existing disposable signed-helper evidence does
not establish guest correctness. The Setup-tab screenshot remains a visual target,
and this slice changes no UI or installed app.

## Milestone 3 frozen-input delivery and helper context validation — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** continue milestone 3 with frozen-input
delivery and helper-side validation using fake runtimes and local fixtures only.
No real SSH/SCP/SFTP/Ansible, installs or VM launches. This supersedes the pending
frozen-context handoff above. The normal helper now validates delivered inputs,
but still supplies **no transport backend** and rejects activation with
`executionUnavailable`. App/CLI execution gates remain disabled; no UI is changed.

**IMPLEMENTED — private delivery:** after preparing the selected `.inputs` archive
and independent cleanup checkpoint, the coordinator writes/fsyncs an immutable
0600 `.delivery` file under its explicit 0700 artifact root. `DVMCNTX1` contains
strict version-1 JSON request metadata (at most 256 KiB) and the existing private
`DVMSNAP1` archive. Metadata records the relative manifest path, original job and
VM/session/non-root owner/UID/host-key binding, dependency digest, mode, selected
tasks/check policy, conflict policy, input lease UUID and review acknowledgements.
It contains no fetched credentials, passwords, private keys or terminal input.
Selected configuration may itself be sensitive: the entire blob stays private.

The registration binds version, exact byte count and SHA-256 of the whole blob,
metadata and archive. Its existing authenticated registration digest therefore
binds delivery to the original owner/worker/payload/review. Schema 5 persists this
receipt alongside the original archive hash before spawn; schemas 1–4 preserve
risk/ownership without inventing a receipt. Unknown/null/legacy receipt fields,
missing owner and a different original archive hash fail closed. Counts include
orphans in the existing 256 MiB/512-file artifact quota. No automatic artifact
import, replay, deletion or retention sweep is introduced.

The launch service retains a read-only, no-follow descriptor and checks owned
0600 regular-file/single-link status, inode/device, size, mode, timestamps, path
identity and exact digest before delivery. Source paths do not reach the helper.
Spawn inherits an **empty** second private AF_UNIX socket at fd 4, in addition to
the control socket at fd 3 and anonymous bootstrap pipe at stdin. Only after
package/file and owned-live-child code admission does the manager send bootstrap
3 and the frozen bytes. This avoids exposing a readable source descriptor to a
child before its loaded image is verified. Bootstrap 1/2 remain supported without
delivery; a version downgrade cannot silently discard a delivery receipt.

Data uses a separate one-shot length-framed channel with 16 KiB sending chunks,
the existing 24 KiB frame ceiling, exact total length, SHA-256 and EOF. A 15-second
transfer deadline bounds the whole stream, including EOF; each packet also has
the existing three-second limit. The registration receipt can wait at most 30
seconds for validation. Oversize, truncation, extra bytes, hash damage, missing
EOF and missing/wrong inherited sockets fail closed. No source bytes travel in
control/status/terminal frames, command arguments, environment or diagnostics.
The whole-blob digest is bound through the private authenticated bootstrap;
individual data chunks are not a new general-purpose authenticated RPC protocol.

**IMPLEMENTED — helper validation:** the helper verifies framing/hashes, strict
metadata and archive identity before materialization. It checks original job,
VM/session/target binding, mode, dependencies and reviewed approval identity.
It creates only a new `inputs-UUID` tree inside its owned private launch directory.
Descriptor-relative `mkdirat`/`openat`, `O_NOFOLLOW` and exclusive file creation
reject links, existing paths and file/directory aliases. Safe relative paths have
depth at most 64; 4096 files and 4096 directories include implicit ancestors.
Files, modes, binary bytes and empty directories are preserved and fsynced;
partial/failed trees remain private and retained. The root and parent identities
are retained and rechecked. No user checkout or VM storage is an extraction target.

Inside that tree, the pinned shared planner independently reparses the original
manifest and extension catalogues, resolves features/profiles and captures the
selected files again. Compare plan, input and engine identities; reconstruct the
request including task/check/conflict/input-lease policy and compare its exact
review identity. Only then can the helper register the inert worker and return an
authenticated receipt containing the validated delivery digest. The archive reader
still returns inert data, never a deserialized executable plan or apply permit.

An injected backend receives only this validated context. Its returned request
must match the reviewed context/tree; the engine repeats scope/target/runner/
plan/package/session checks before work. Delivered consent is ANDed with backend
consent and then with explicit activation consent. A permissive backend cannot
invent a missing acknowledgement. The owned tree stays retained through the
worker; root/source validation precedes body work, while original-target cleanup
remains independent of source/package/delivery availability. The product helper
provides no backend. Only the excluded Debug fixture constructs synthetic adapters.

**DESIGN DECISION — frozen review ownership:** source/package/session/dependency
checks still precede publication and handoff. Once a frozen registration is
accepted, its private selected bytes define that reviewed job. Later changes or
removal of the original checkout cannot replace those inputs or prevent activation
of that accepted copy. Manager activation verifies the persisted delivery and
`.inputs`; helper activation verifies its independently rebuilt private tree.
Legacy registrations without delivery keep the earlier original-source check.
This does not resume apply after restart, grant an input lease, adopt a new guest
session or permit replay. Existing one-shot activation and cleanup holds remain.

**PRIVATE COUPLING:** shared `SetupPlan.manifestPath` becomes public read-only so
the manager records the actual reviewed relative manifest path. The source/engine
inventory and exact base-plus-integration patch pins are updated together; the
82-file export remains based on `bb3fae22be45b38035fac52aefa0eb270a9d0fea` plus
`Patches/dev-vm-durable-state.patch`. This is not an unchanged engine claim.
Guest resources, parser dependencies and C launcher bytes remain unchanged.

**VERIFIED — fake/local checks:** `make test` passes 308 manager Swift functions
in 44 suites, 49 script tests and expanded relocated/read-only signed-helper
fixtures. New parameterized cases cover independent replan after source removal,
custom manifest/catalogue/tasks, binary/mode/empty-directory preservation,
metadata/registration/hash/framing damage, changed private descriptors and links,
root substitution, implicit-directory bounds, strict bootstrap/receipt/schema
handling, refusal of consent expansion, frozen activation and damaged delivery.
The excluded fixture helper receives a payload larger than a control frame,
validates it in its actual child process, then applies/cancels through fake adapters
after the parent checkout is deleted. The actual product helper validates delivery
but refuses execution. Changed delivery is refused and the owned child is reaped.

Shared checks:
`make build-provisioning test-provisioning test-provisioning-oracle test-provisioning-planning-oracle ORACLE_PYTHON=/opt/homebrew/opt/ansible/libexec/bin/python`
pass 68 Swift test functions, 18 parser oracle fixtures and 66 complete planning/
error fixtures. This uses an existing Python runtime solely for development-time
oracle comparisons, never Ansible execution or a product Python fallback.
Local IPC/mock-auth/PTY and ad-hoc signed fixture checks use existing sandbox
exceptions. No real signing credentials, auth UI, host installs, actual guest
transport, VM operation or installed-app change occurs.

**TO PROVE / REMAINING:** exclusive real backend/adapter construction, trusted
manager-aware session/dependency authority across the helper boundary, product
coordinator wiring, stream/PTY/input leases and live terminal UI/CLI, full manager/
helper restart/reconnect and reviewed rebinding, real release-signature acceptance,
power-loss durability and artifact-retention UX. Real guest authorization, echo,
remote cleanup/quiescence, crashes and kernel stalls remain unproved. The Setup-tab
screenshot remains a visual target; this slice does not complete milestone 3.

## Milestone 3 helper backend and manager session authority — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** continue milestone 3 with helper backend
construction and manager-aware session authority, using fake runtimes and local
fixtures only. No real SSH/SCP/SFTP/Ansible, host installs or VM launches. This
supersedes the pending construction/authority foundation above. Product setup gates
remain disabled. The product helper supplies no transport-resource provider and
still rejects activation; neither UI nor installed app changes.

**IMPLEMENTED — backend construction:** after explicit activation, the helper
constructs the existing shared `SSHAnsibleGuestAdapter` and one permanently fenced
process runner for the original worker. A trusted helper-local provider supplies
an explicit pinned connection, transport tools, dependency digest and idle process
runner factory. These resources are not decoded from a manifest, journal, control
request or arbitrary path/command argument. Preparation is single-use, including
a failed preparation. Recheck frozen root/source/review, original job/session/mode,
plan/input/engine identities and package admission before asking for resources.

Require the manager's fresh session permission before provider access and again
before runner creation. Compare the connection's exact guest binding and dependency
digest, revalidate the explicit identity-file reference without reading its bytes,
and verify every executable pin without running a probe. Repeat checks around
asynchronous preparation, then construct the shared adapter with that same authority
and runner. The worker verifies the concrete manager authority and its exact runner
association; it cannot substitute an older local-only authority for a registration
that requires manager checks. Existing delivered/backend/activation consent AND,
shared sequencing and permanent original-worker fencing remain intact.

The provider is an internal trusted resource-admission boundary, not a sandbox for
arbitrary providers. Production managed-SSH connection/key-reference handoff,
Homebrew report-to-resource admission and a real local runner/terminal provider
remain separate product wiring. No default discovers credentials, probes host
tools or creates an executable backend. All providers exercised here pin inert
fixture files and return fake process runners; constructing the concrete adapter
does not launch SSH, Ansible or any other program.

**IMPLEMENTED — independent authenticated authority:** bootstrap 4 binds
`sessionAuthorityVersion: 1` into the original registration and reserves inherited
fd 5 for a second private AF_UNIX stream. Frozen data remains on fd 4 and control
on fd 3. The anonymous capability is still handed over only after owned-child image
admission. Session frames use an independently derived HMAC key domain, separate
sequence counters and the existing bounded frame/payload/time limits. A correctly
MACed control packet cannot authenticate as session permission. Bootstrap 1–3
remain supported; a downgrade cannot silently discard the authority marker.

Before activation RPC, the coordinator has fsynced the activation identity/risk
and installed the active VM lease. Only then bind a one-shot manager callback to
the exact admitted registration/activation. The separate reverse-RPC loop awaits
that callback without acquiring the launcher's control transaction lock. Status,
cancel and shutdown remain serviceable while validation awaits another actor.
There is no listener path, reconnect, saved-PID lookup or automatic authority retry.

Fresh queries cover backend preparation, each command, adapter admission within
a command, each process invocation and command completion. Requests contain only
a challenge UUID, registration digest, original scope, mode, command/operation,
optional invocation/purpose and explicit cleanup classification. They carry no
owner name, credential, source, tool path, argv, environment or terminal bytes.
Strict schemas reject unknown/null fields, wrong modes/workers and impossible
operation/purpose or cleanup combinations. The server admits at most 4096 queries
on one channel. Responses echo the entire request and a fixed typed decision.
Lost, malformed, mismatched or replayed responses poison the channel; successful
decisions are never cached or reusable permission receipts.

The coordinator compares its current active generation, journaled activation,
original worker/helper/review/session/binding and mode. It checks the actual
VMManager lifecycle reservation and the injected dependency/binding authority,
then repeats actor-owned checks after every await. VM lease checks include current
running session, SSH owner/readiness, pending shutdown, power/execution and storage
operations. SSH host-key/owner proof cannot invent manager VM/session ownership.
Cancellation revokes body work; cleanup is admitted only for the explicit original
target and narrow cleanup operations while its lease/dependencies remain valid.
An expired/invalid target or missing authority never grants cleanup by assumption.

The fenced runner records ownership **before** requesting per-invocation permission
and rechecks its fence/cancellation after the reply, before calling the process
backend. Refusal truthfully returns not-started. An authenticated body-stop decision
is reported to the sequencer as cancellation without fabricating a process exit.
An uncertain local result still overrides apparent clean guest completion and
retains its exact runner for explicit original-worker reconciliation.

Failed journal writes revoke body admission but retain the known live lease and
reverse authority long enough to attempt original-target cleanup. Status polling
and cancellation continue; durable cleanup success is never claimed while storage
is failed. Package/source availability does not govern cleanup. Lost control or
authority channels fence local work, keep uncertainty and cannot provide remote
grant revocation proof. Hard stalls and full-process restart remain unproved.

**IMPLEMENTED — journal compatibility:** schema 6 persists the optional original
session-authority version alongside delivery/owner pins before spawn. Version 1
requires a genuine delivered-input receipt and helper owner. Unknown/null versions,
legacy-schema markers and missing delivery fail closed. Schemas 1–5 preserve their
original risk/owner/delivery data without inventing authority or replaying apply.
Reopen still requires explicit original-owner reconciliation and reviewed rebinding
where applicable; a new helper cannot recover authority from disk.

**PRIVATE COUPLING:** shared `ProvisioningSSHConnection.verify()` exposes stat-only
identity revalidation; `ProvisioningTransportTools.verify()` is now public and
`ProvisioningProcessPurpose` gains Codable for fixed metadata. Update the exact
82-file base-plus-patch export, inventory, engine hash and compiled lock pin together.
The base remains `bb3fae22be45b38035fac52aefa0eb270a9d0fea` plus the reviewed
`Patches/dev-vm-durable-state.patch`; this is a changed engine identity. Guest
resources, parser dependencies and C launcher bytes are unchanged.

**VERIFIED — fake/local checks:** `make test` passes 319 manager Swift functions
in 45 suites, 49 script tests and expanded relocated/read-only signed-helper
fixtures. New parameterized tests exercise concrete-adapter apply/check with fake
process runners, construction ordering/resource changes and no duplicate backend,
private challenge correlation/key domains/replay/malformed/missing replies,
one-shot binding, strict bootstrap/journal migration and local-authority bypass
refusal. Every recorded fake process invocation has a matching manager query.
Cancellation, ordinary shutdown, VM exit, readiness/dependency/package loss and
channel closure stop further body calls. A dependency-validation suspension test
proves cancellation is rechecked after the await. Failed journals still allow
original cleanup and retain risk; uncertain local ownership needs explicit proof
and recovery without constructing another backend.

The actual product helper acknowledges frozen inputs but refuses the new backend
activation without a provider. A separately sealed/ad-hoc-signed Debug fixture
helper constructs the concrete shared adapter with only inert fixture tools and a
fake process runner, asks the parent over the real inherited reverse channel,
completes one job and cancels another with cleanup. Its cancellation fixture holds
fake feature work until interruption so observation does not depend on a short
sleep. The owned child is reaped. The normal app/helper is never replaced or enabled.

Shared build/tests and development oracle checks pass 68 Swift functions, 18 parser
fixtures and 66 complete planning/error fixtures using the existing command:
`make build-provisioning test-provisioning test-provisioning-oracle test-provisioning-planning-oracle ORACLE_PYTHON=/opt/homebrew/opt/ansible/libexec/bin/python`.
The existing Python runtime serves only development comparisons, not Ansible or a
product fallback. Existing local socket/mock-auth/PTY sandbox exceptions and ad-hoc
fixture signing are used. No real credentials, auth UI, host installs, actual guest
transport, VM launch or installed-app change occurs.

**TO PROVE / REMAINING:** product connection/tool-resource admission and private
handoff, concrete manager construction, operational runner/terminal/input leases,
job UI/CLI attachment, full manager/helper restart/reconnect and reviewed rebinding,
release-signer acceptance, power-loss/retention UX and all real guest authorization,
echo, transport, remote quiescence/cleanup and crash/kernel behavior. Fresh RPC
checks are not an atomic transaction with remote execution or proof of guest
identity/liveness after a reply. The screenshot remains the live terminal target;
this slice does not complete milestone 3 or enable operational provisioning.
