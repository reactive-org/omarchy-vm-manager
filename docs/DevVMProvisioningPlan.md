# Shared Swift dev-vm provisioning implementation plan

Status: original milestone 1 committed as `62a4c62`; milestone 1A committed as `915642e`. Milestone 2 has started with the shared package structure and strict manifest parsing committed in dev-vm at `e86550e`. Feature/profile resolution, source snapshots and offline proposals are committed in dev-vm at `56dba82`. Adapter-only transport/authorization sequencing is committed in dev-vm at `f807104` and tested against fakes; concrete SSH/Ansible command adapters and private materialization are committed in dev-vm at `9ebaf17`, tested against fake process runners. The opt-in local runner/PTY is committed in dev-vm at `bb3fae2` with disposable-fixture coverage; the manager now links the pinned package and ships an offline-only helper/resource/launcher integration; the milestone-3 foundation includes durable inputs, admitted helper launch and helper-side sequencer activation/status/cancellation tested with fake adapters and signed local fixtures; subsequent milestone-3 service/backend coordination and milestone-4 terminal/input transport are now complete for fake/local acceptance (see the completion records below). Milestones 3/4 are committed in manager `6a71b06` and dev-vm `3d616f0`. Milestone 5 has started with the native Setup terminal, offline preset/folder previews and a separate observation/attachment CLI endpoint (see the milestone-5 record below). Product execution remains disabled.

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

Maintain a SwiftPM package at the dev-vm repository's root `Package.swift`, with a `DevVMProvisioningCore` library and a standalone `dev-vm` executable consuming that library. These products now exist in the milestone-2 foundation branch; the executable supports offline validation and planning only. The manager consumes the immutable `5770d0f` source export under `Vendor/dev-vm`, verified by `Config/DevVMProvisioning.lock.json`, and links the same library into manager core and an offline-only provisioning helper. This merged revision incorporates the four earlier manager integration patches; historical candidate copies retain their original `bb3fae2` base-plus-patch pins. Keep Swift 6 and macOS 15+ compatibility and a make-based build/test entry point.

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

Milestone 4 implements the helper/manager transport and attachment contract below. The native emulator, escape-action policy, Setup screen and external CLI endpoint are milestone 5; no host UI or terminal is activated by service composition.

The user-provided Setup-tab reference is the visual target: reviewed source/profile/features, readiness checks, stage strip, a large dark terminal with Follow output/expand, cancellation and job details. Its concept/sample output is illustration, not evidence of a configured guest. Keep actual terminal bytes separate from structured control messages; the authenticated ownership slice below adds no UI or stream rendering.

Use a native terminal emulator in a SwiftUI wrapper. The milestone-5 renderer pins SwiftTerm 1.99.0 at `2dad6a1e516f755bed77cf9bbd09455062f54758` as a library-only source export. It requires Swift tools 6.2 or newer; this slice is built with Swift 6.4 for macOS 15. The source export has one reviewed two-line grapheme bound; the reviewed local manifest and deterministic build-identity/display-configuration overlay replace upstream plugins and exclude process frontends and external dependencies. See [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).

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

`setup tools` implements schema 2 under milestone 1A. The milestone-5 record and CLI reference identify the implemented offline/observation/attachment commands; the broader creation/apply/check/recovery commands in this original proposal remain gated:

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
| 3. Job coordination — complete for fake/local acceptance | Manager-owned service and strict workflow journal; SSH wait/review, admitted helper jobs, explicit restart after matching exit, fresh session rebind/check review, authenticated recovery and bounded retention; product execution disabled | Fake runtimes, local processes and signed helpers cover lifecycle, concurrency, corruption, cleanup and no replay. A fresh manager process with no original helper capability preserves cleanup holds and refuses adoption. Live terminal/input (4), UI/CLI (5), real guests (6) and release acceptance (7) remain separate |
| 4. PTY and stream transport — complete for fake/local acceptance | Separate authenticated inherited stream; bounded byte frames, view attachments and one explicit input owner, resize, expiry/detach, visible-gap/reset contract and local TTY restoration | Disposable local processes/PTYs and signed helper fixtures prove byte fidelity, prompts, hidden input, resize, reclaim, limits and owned cleanup. Native rendering and external UI/CLI attachment commands are milestone 5; real nested SSH/guest behavior remains 6 |
| 5. UI and CLI — complete for fake/local acceptance | Setup selection, multi-profile cards, theme/layout example cards, preview, permissions, terminal and commands | Native and CLI share frozen review/job/dependency/recovery contracts; 100 offscreen checks pass. Physical interaction and guest behavior remain TO PROVE |
| 6. Guest acceptance — preparation only | Disposable scope admission, runbook and offline candidate preflight; no approved real scope or operational candidate | End-to-end setup, reapplication, authenticated restart, check and sudo revocation must be observed on explicitly approved guests; all real rows remain NOT RUN |
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

## Milestone 3 transport-resource admission and private handoff — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** continue milestone 3 using fake runtimes
and local fixtures only. No real SSH/SCP/SFTP/Ansible, host installs or VM launches.
This implements the resource admission/handoff foundation listed above. Product
execution gates remain disabled; no operational runner factory, UI or installed
app is enabled or changed.

**IMPLEMENTED — manager admission:** `VMManager.admitProvisioningTransport` requires
its current running session, ready SSH owner, managed SSH profile/port and no
conflicting shutdown, power/execution or storage operation. It obtains the root
and port from the retained manager session/profile, not a listening port or supplied
SSH command. Inside that explicit owned private root, read only the public managed
SSH manifest, bootstrap manifest and known-hosts metadata. Verify schema, VM/session
IDs, port, exact Ed25519 host-key binding, root device/inode and metadata hashes.
Derive the identity-file reference from `.manager-ssh/client`; stat it without
reading its contents. No credential generation, `ManagedSSHStorage.prepare`,
key-reading validation, SSH probe or guest command is part of this admission.
The reviewed owner/UID remains an expectation that real guest identity proof must
later corroborate; a metadata file does not prove the remote guest's identity.

Admission consumes an already checked schema-2 dependency report, never runs its
probes itself. Require unique available required tools, fixed macOS transport
entries, coherent Homebrew Ansible command/version/installation evidence and stable
Core 2.21.x. Revalidate report fingerprints, active installation, expected command
targets, entry names and canonical installation membership. Capture full executable
pins for SSH/SCP/SFTP and both Ansible commands, plus the original stat-only private
identity reference. Original Homebrew/report fingerprints are change detectors,
not new binary-signing provenance or a hash of every file in Homebrew's runtime.
The report must come from the trusted dependency-check boundary; arbitrary manifest
JSON cannot assert that probes passed.

The admission computes the dependency digest from its canonical endpoint/report/
original-reference selection. Build the reviewed request with that digest; an
unrelated caller-provided digest is rejected. Recheck the admission against the
actual VMManager root/port before publication and handoff, after helper acceptance,
at activation and around asynchronous session checks before commands/processes.
Changed keys, tools, wrappers, installation or public binding metadata cannot be
silently recaptured into the accepted job. A new selection needs a new review.
Cleanup also requires the original transport identities; changed transport resources
retain uncertainty rather than selecting replacement credentials or executables.

**IMPLEMENTED — private resource channel:** `ProvisioningTransportHandoff` is an
ephemeral in-memory descriptor binding the selection to the original challenge,
job/VM/session/payload/worker, review/checkpoint, source/engine and mode. Registration
binds its format, exact byte count, SHA-256 and dependency digest. Bootstrap 5
requires frozen delivery and manager session authority, and reserves inherited
fd 6 for the one-shot private resource stream. Control, frozen inputs and session
authority remain on their existing distinct channels. Only after owned-child image
and package admission send the anonymous bootstrap and resource bytes. Revalidate
the original admission immediately before that handoff.

The descriptor contains public host-key data, identity-file **path/stat proof**,
managed metadata hashes and tool/report references; it contains no private-key
contents, tokens, passwords or process invocation. No resource paths or descriptor
bytes enter argv, environment, control/status/terminal frames or the journal. No
`.transport` file is saved. The stream requires the authenticated receipt's exact
size/hash and EOF, uses the existing 16 KiB chunks/24 KiB frame ceiling and bounded
transfer deadlines, and is limited to 128 KiB. Explicit private reference metadata
inside it is limited to 64 KiB. Descriptions are redacted.

**IMPLEMENTED — helper import:** strict readers reject duplicate/unknown fields,
wrong formats, null/partial receipts, mismatched job/worker/mode/review/dependency
and damaged/truncated descriptors. Revalidate the managed public metadata, report
fingerprints and installation under a helper-local policy. Default host policy
requires the normal fixed system entries; it is never selected or weakened by the
wire document. Internal fixture policy is explicitly injected by test code and has
no product environment, manifest, CLI or RPC selector.

Shared `ProvisioningTransportReference` exports the original executable entry/
target/stamp/full-hash proofs and stat-only identity reference. Import compares
those proofs with current files and the independently admitted binding, identity
path and executable paths. It does not mint fresh pins for replaced files. Identity
references require one link; changed inode, mode, link count, timestamps, target or
bytes fail closed. Strict nested schemas and expected paths reject retargeting
before adopting resources. Import grants no execution or guest ownership by itself.

The helper acknowledges the resource digest only after validation. Missing or
mismatched resource acknowledgement cannot register the worker. A validated
handoff supplies the existing backend builder's transport provider, preserving the
same manager authority/fenced runner and repeat checks before work. A resource-bound
registration cannot substitute an older helper-local provider/context. Product
helper entry points supply **no process-runner factory**, so even admitted resources
cannot enable activation. Only the excluded Debug helper supplies a fake runner.

**IMPLEMENTED — compatibility and ownership:** schema 7 journals only the optional
resource receipt and original opaque identities, requiring matching dependency,
frozen delivery and manager authority. Schemas 1–6 retain risk/owner/delivery data
without invented resource receipts. Old bootstrap modes remain available within
their earlier disabled/injected boundaries; downgrading a resource-bearing bootstrap
is rejected. Accepted resource admissions remain in the live coordinator/launch
service, never reconstructed from journal paths. Reopen records interruption and
does not replay a queued resource-bound job or discover credentials. Existing
explicit cleanup/ownership reconciliation remains separate; no new manager/VM
restart adoption, automatic resource import or artifact deletion is introduced.

**PRIVATE COUPLING:** the shared package adds the explicit private-reference API
and original link-count proofs. Update its inventory and the manager's exact
base-plus-patch export together: 83 resulting files, immutable `bb3fae2` base plus
`Patches/dev-vm-durable-state.patch`, with a changed engine/snapshot/compiled pin.
Guest resources, parser dependencies and C launcher bytes remain unchanged.

**VERIFIED — fake/local checks:** `make test` passes 328 manager Swift functions
in 46 suites, 49 script tests and expanded relocated/read-only signed-helper
fixtures. New cases cover managed endpoint/report admission, private round trip,
original key/tool/alias/installation/public-metadata/root changes, wrong review/
scope/mode, strict formats/fields/hashes, acknowledgement refusal, host policy,
schema migration, fresh activation/invocation checks and no replay after reopen.
The manager-derived handoff supplies concrete adapter apply/check using only fake
process runners; provider-side resource reconstruction is bypassed.

The separately sealed/ad-hoc-signed Debug helper receives the actual inherited
resource stream and constructs the concrete adapter from its validated original
references, then completes/cancels with fake process replies. Changed resources
are refused and matching child exit is reaped. The actual product helper rejects
fixture tool paths under host policy; no fixture policy/runner is installed into
it. Earlier legacy cancellation fixtures retain their original manifest contract.

Shared build/tests and development oracles pass 70 Swift functions, 18 parser
fixtures and 66 complete planning/error fixtures with the existing command:
`make build-provisioning test-provisioning test-provisioning-oracle test-provisioning-planning-oracle ORACLE_PYTHON=/opt/homebrew/opt/ansible/libexec/bin/python`.
The two new shared functions cover private-reference round trip with an unreadable
synthetic identity file and changed/unsafe/unknown reference rejection. Python is
used solely for development comparisons. Only existing local socket/mock-auth/PTY
sandbox exceptions and ad-hoc fixture signing are used. No real credential, auth
UI, host install, actual guest transport, VM launch or installed-app change occurs.

**TO PROVE / REMAINING:** product coordinator/resource acquisition wiring, fresh
production report provenance/lifetime, real managed-SSH resource admission across
supported installations, operational runner/terminal/input leases, job UI/CLI,
full manager/helper restart/reconnect/rebinding, release signatures and retention/
power-loss UX. Real guest identity/auth/echo/transport/remote cleanup/quiescence and
crash/kernel behavior remain unproved. Stat/hash/RPC checks are not atomic remote
execution or proof of guest liveness after a reply. The screenshot remains the
later live terminal target; this does not complete milestone 3.


## Milestone 3 completion — 3 November 2026

**USER AUTHORIZATION / DESIGN DECISION:** complete milestone 3 using fake runtimes,
fake process runners and disposable local fixtures. No real SSH, SCP, SFTP or
Ansible execution, tool installs, authentication UI, VM launches or installed-app
changes are authorized by this milestone. The earlier milestone-3 sections record
incremental evidence; this section supersedes their incomplete status within this
explicit acceptance boundary.

**IMPLEMENTED — product composition:** `VMManager.installProvisioningService`
installs one manager-owned actor, shared by concurrent callers and retained by the
app model. Opening it admits the pinned package, reads private recovery metadata,
seeds lifecycle holds before package failure can hide risk, and constructs the
launcher/dependency provider without inspecting Homebrew, spawning a helper or
operating a VM. Product `executionEnabled` remains false, with no preference,
environment, command argument or journal field that can enable it. The packaged
helper still supplies no execution runner factory. A validated-input runtime
constructor admits the pinned local launcher and creates memory-only output with
no input grant; a disposable shell fixture exercises it. Operational terminal and
input delivery is milestone 4, and execution surfaces are milestone 5.

**IMPLEMENTED — durable workflow:** the new strict schema-1 workflow index records
only UUIDs, hashes, typed stages/failures, sequence and risk/acceptance markers.
Private `0700` directories and `0600` atomic/fsynced files use an exclusive writer
lock, retained directory/lock identities, strict fields and revision/fingerprint
checks. Unknown/duplicate/null fields, invalid marker combinations, symlinks,
hardlinks, replacement, corruption and quota failures preserve data and fail
closed. No terminal output, secrets, credentials, resource/source paths, PIDs or
helper capabilities are serialized. Schema-7 child jobs and original frozen
inputs/cleanup receipts remain authoritative at their existing boundary.

**IMPLEMENTED — SSH waiting and review:** a manager-owned task waits with a bounded
deadline for the exact managed VM/session and SSH owner. A preparation lease blocks
competing pause/configuration/delete operations. Explicit cancellation, shutdown,
wrong owner/session, changed source or resource pins stop admission; cancelling an
observing task does not cancel work. Dependency inspection and exact transport
admission create a review identity. Acceptance is persisted before suspension or
helper registration, so concurrent/duplicate approvals cannot dispatch a second
job. Cancelling an authenticated inert reservation fences it without activating
remote work. A clean engine result alone cannot clear the workflow hold: the
original helper's matching exit must also be observed.

**IMPLEMENTED — planned restart and explicit rebind:** a restart-required result
stops for a distinct review identity. Accepted restart intent is durable before
manager shutdown. The original session handle, root and reservations remain held
until its matching `.exited`; `.error`, timeout, cancellation and unrelated events
never count as exit. A private restart lease permits only that manager-owned
replacement session. Its managed endpoint and resources must be admitted afresh,
with the same VM, owner, UID and expected host key. A second, explicit rebind review
binds the new session and new dependency digest. The post-restart job uses frozen
inputs, a fresh job UUID and check mode, with opaque custom tasks excluded; it
cannot silently reapply or transfer a password-input lease. Duplicate approvals
return the recorded receipt. Preparation/restart failures never invent exit or
start an unreviewed replacement.

**DESIGN DECISION — process restart and recovery:** reopening never resumes a
review, accepted activation, restart or rebind. Unfinished records become typed
interrupted/cleanup-required states. Cleanup requires re-supplied original live
transport admission, exact checkpoint pins, independent original-worker
stopped-and-fenced proof and manager-owned current-session authority. A surviving
original authenticated launcher can provide that proof after service/coordinator
reopen. A genuinely new manager process has lost that capability and cannot adopt
an old worker or VM from disk. A saved PID, marker file, filesystem lock or apparent
absence is never substituted for that proof. The safe outcome is retained
cleanup-required state and blocked normal lifecycle/reapply, pending an authorized
recovery path. Positive adoption/remote recovery after full process loss is not
claimed by this milestone.

**IMPLEMENTED — retention:** no automatic eviction occurs. Immutable inputs,
cleanup checkpoints, delivery files and orphan/partial private metadata remain
available for review. The count/byte-only retention report reveals no contents or
paths. Existing artifact limits (512 files / 256 MiB by default), 128 workflow
records / 256 KiB workflow document, and retained rebind-source limits (128 trees,
16,384 entries, 256 MiB, bounded depth) refuse further admission instead of deleting
material. A rebind attempt is owned and single-use; a failed attempt cannot create
unbounded retries. Manual retention/power-loss recovery UX remains later work.

**VERIFIED — no-VM acceptance:** `make test` passes 347 Swift test functions in 48 suites, 49 script tests, and relocated/read-only ad-hoc-signed helper fixtures. The final `make test-provisioning-tools` run passes 141 functions in 13 suites after the last cancellation/recovery guard changes. Package/export validation and companion/vendor source/engine matching pass.
The separate-process fixture exits the original manager owner while its admitted,
ad-hoc-signed debug helper is doing fake work. EOF closes its authority channels;
the excluded helper's diagnostic confirms the fake loop finished. A fresh manager
process loads the interrupted journals, refuses cleanup ownership/adoption, keeps
its VM hold and launches nothing. That test diagnostic is never consumed as a
production proof. Other tests cover surviving-capability cleanup, uncertain local
work, lost helper-exit proof, inert cancellation, stale previews, duplicate and
concurrent approval, SSH timeout/owner/session changes, matching-exit restart,
rebind review, journal failures/corruption and quota preservation. The shared
package transport/export pin and its previously recorded 70 Swift / 18 parser /
66 planning-oracle checks are unchanged by the completion work.

**TO PROVE / NEXT:** milestone 4 terminal frames, backpressure, rendering,
reconnection and explicit input/resize leases; milestone 5 Setup UI/CLI actions;
milestone 6 approved disposable-guest identity/authentication/restart/check,
revocation, remote quiescence, crashes, host sleep/wake and process/kernel behavior;
milestone 7 release-signature and distribution acceptance. The supplied Setup
screenshot remains the visual target for the later live-terminal UI. Fake/local
completion establishes no real guest or full operational restart claim.


## Milestone 4 completion — 3 November 2026

**IMPLEMENTED / DESIGN DECISION — separate stream:** bootstrap version 6 binds
`terminalVersion: 1` into the original admitted worker registration. The launcher
inherits one additional anonymous same-user Unix socket at fd 7, alongside control
(3), frozen delivery (4), manager session authority (5) and transport admission (6).
Stream transactions use an independent HMAC domain, original helper/channel/job
identity, direction and monotonic frame sequence. Unknown/duplicate/null fields,
versions, invalid UUIDs, bounds and replay fail closed. No terminal bytes are added
to the ownership/control protocol, existing CLI JSON, argv, environment or journal.
Frozen-input and original transport admission precede terminal serving. A stream
registration cannot downgrade to an unrelated legacy process-runner factory.

`ProvisioningTerminalHub` owns a memory-only viewer registry over the shared local
runner's terminal. The helper retains the job task independently of viewers. The
manager service resolves a workflow to its original live helper and exposes an
internal UI/CLI-neutral attachment; public execution and external attach commands
remain disabled. Each attachment starts view-only. An explicit claim issues a new
opaque owner generation, bound to the reviewed input scope. One viewer controls
input and PTY dimensions; other viewers cannot type or resize. Input/resize also
bind the exact active invocation and strictly increasing owner sequence. Repeated
claims, stale generations, wrong jobs/invocations and replay are refused. Check
jobs without a reviewed input lease cannot acquire input.

**IMPLEMENTED — bounded delivery and discontinuity:** up to eight viewers share
one serial, bounded stream transaction channel. Each reply carries at most one
8 KiB byte frame; input is at most 4 KiB, with the shared runner retaining at most
64 KiB pending input. The output ring defaults to 256 KiB (configurable 8 KiB–1 MiB,
at most 1,024 frames). Polling and socket writes never run on the process drain
path. Slow or absent viewers cannot block a flood, cancellation or control/session
RPCs. ANSI, carriage returns and split UTF-8 are transported as original bytes;
structured results never infer success or authorization from output text.

An evicted frame produces an explicit `resetRequired` page with no partial replay.
Observed gaps revoke input ownership. The consumer must display a discontinuity,
reset its emulator/UTF-8/escape state, then explicitly acknowledge a jump to the
live tail; typing requires another deliberate claim. This provides future output,
not a reconstruction of the lost screen or a persistent transcript. Renderer-side
handling of a mid-sequence live tail and host-action escape filtering is a required
milestone-5 acceptance check. Completed helper exit/full manager restart loses
stream capability and helper memory; no attachment is adopted from disk. A future
UI retains only its own bounded in-memory screen and must report unavailable output.

**IMPLEMENTED — detach and lifecycle:** explicit detach/release suspends the
reviewed input scope and serializes clearing pending keystrokes/resizes against
actual PTY writes. A fresh attachment may explicitly reclaim the same reviewed
scope with a new owner token; it never inherits another viewer's token. Viewers
expire after 15 seconds without heartbeat/read/activity, checked every 40 ms.
Socket EOF or malformed stream traffic revokes all stream leases without cancelling
the job or poisoning its separate control channel. Explicit detach waits out a
bounded in-flight transaction and only retries the idempotent detach operation;
input/resize/claim mutations are never automatically retried. Completion,
cancellation and fencing revoke input permanently, including an inert registered
worker with no constructed runtime/context. Job cancellation continues
through coordinator cleanup and matching owned-process exit. Cancellation that
wins during invocation admission keeps its typed cancellation reason even if the
adapter reports a not-started failure; this changes classification only, while
retained local ownership and remote cleanup proof still determine the risk hold.

The shared terminal now distinguishes reserved reviewed scope from live input
permission. Reservation allows an interactive process to show its actual prompt
while unattached, but cannot deliver a keystroke. Resume/suspend preserves scope
and input sequence while discarding old queued bytes; permanent revoke cannot be
resumed. Transport workspaces are normalized at creation so their paths satisfy
the local runner's existing strict path contract. The immutable base plus reviewed
patch/export/engine inventory has been refreshed in both worktrees; no host Python
controller, guest playbook change or new third-party dependency is introduced.

`ProvisioningLocalTerminal.withRaw` is opt-in support for milestone-5 CLI attach.
It owns a duplicate of the original TTY descriptor and restores saved termios on
normal return, thrown error and cooperative cancellation. It never reads/logs
input or changes global stdio. Tests use newly allocated local PTYs only. Darwin's
transient `PENDIN` bit may be set when restoring canonical mode; all saved user
flags and control characters are verified. Hard process termination cannot run a
Swift restoration scope and is not claimed by these tests.

**VERIFIED — local acceptance:** `make test` passes 362 Swift test functions
in 49 suites, 49 script tests and the relocated/read-only/ad-hoc-signed helper
fixture suite, including actual separate-process stream delivery and the existing
lost-owner/reopen checks. The terminal suite covers 14 functions (with parameterized
malformed-document and restoration cases). `make test-provisioning-terminal` is the
focused build/test entry point. The shared package's final
`make build-provisioning test-provisioning test-provisioning-oracle
test-provisioning-planning-oracle
ORACLE_PYTHON=/opt/homebrew/opt/ansible/libexec/bin/python` passes 72 Swift functions,
18 parser oracle fixtures and 66 complete planning/error oracle fixtures. Python
is an existing development oracle only. Package/export validation, all seven changed
companion/vendor source/engine/test comparisons and both `git diff --check` runs
pass.

The excluded ad-hoc-signed debug helper uses original frozen/resource handoffs,
reverse session checks, engine activation and the new fd-7 channel. Its only real
process is a fixed local shell/printf/sleep fixture substituted for a fake feature
invocation; original SSH/Ansible argv never executes. Actual colored/UTF-8 output
crosses the admitted helper boundary while structured status proceeds independently.
The shipped helper still supplies no operational runner factory; synthetic resource
admission and ordinary execution remain refused. No real SSH/SCP/SFTP/Ansible,
credential/auth UI, host install, download, VM operation, permission grant or
installed-app/UI change occurs.

**PRIVATE COUPLING:** inherited descriptors, registration/bootstrap versions and
original session/resource proofs are a versioned private manager/helper contract.
The shared process runner owns PTY/process mechanics; this adds orchestration and
viewer ownership rather than a VM implementation.

**TO PROVE / NEXT:** milestone 5 selects/pins and embeds the native emulator,
implements host-action escape filtering and bounded rendering/scrollback, follows
the Setup screenshot, and adds the external streaming CLI endpoint with polling/
heartbeat, explicit transfer, detach and scoped raw-terminal restoration. Milestone
6 still requires approved real nested SSH/guest password/echo, resize, revocation,
restart/check, remote cleanup and crash/sleep/wake acceptance. Milestone 7 covers
release distribution/signatures. Full-process worker adoption remains unproven;
product execution remains disabled. Earlier TO PROVE labels remain unchanged.

## Milestone 5 UI/CLI terminal slice — 3 November 2026

**DESIGN DECISION:** this slice supplies offline selection/review and live observation
surfaces while preserving the product execution gate. Milestones 3/4 were committed
first in manager `6a71b06` and dev-vm `3d616f0`; that terminal/UI/CLI slice is now committed in manager `18feed5` and companion docs `f5d495c`. The following frozen review/submission slice is committed in manager `d6d9c64` and companion docs `09a099c`; the workflow-action slice below is committed in manager `c92c7ed` and companion docs `7e0bc4c`.
The native Setup tab and separate CLI socket consume `ProvisioningObserving`, backed
by the same manager-owned service, workflow status, child status, cancellation and
original helper attachment. Closing a view or CLI releases its viewer, not its job.
No saved PID or journal is converted into a new terminal capability.

The Setup tab follows the supplied screenshot's layout: source/preset selection,
offline proposal, stage strip, large dark terminal, Follow output, expand, font
size, literal search, jump to latest, explicit Take/Release input, reconnect,
cancellation confirmation and job details. Four bundled manifests select the
upstream developer, web, python and project-managed profiles; local folders use
`vm.yml`. Both paths use the admitted pinned planner without a VM connection.
Preview source/resource settings do not overwrite the manager's VM configuration.
There is no simulated output, prompt-text detection, fabricated percentage or
inferred completed-stage checkmark. Current phase comes from workflow/child state;
input availability comes from typed terminal metadata. Multiple workflows are
selected explicitly, without treating sequence numbers as timestamps. The Home
page links a concise setup state to the Setup tab.

**PRIVATE COUPLING — renderer:** SwiftTerm 1.99.0, revision
`2dad6a1e516f755bed77cf9bbd09455062f54758`, is vendored under `Vendor/SwiftTerm`.
Its sources/license are covered by an exact SHA-256 inventory; `Patches/swiftterm-bounded-graphemes.patch` adds one early-return guard limiting stored clusters to 16 scalars, including extensions across cursor/SGR sequences. All other upstream source/license bytes are unchanged.
Two manager integration files provide the library-only manifest and deterministic
build identity/empty query table plus a scoped display configuration method. No
upstream plugin, process frontend, new external package or host executable is built.
Swift 6.2+ is required; this Mac uses Swift 6.4. The earlier 1.5.1 candidate was
rejected during source review because its global character cache weakens isolation
and memory bounds. Version 1.99.0 uses bounded per-terminal cell storage instead.

The shared incremental display policy validates UTF-8 across chunks, caps a
combining cluster at 16 scalars, caps CSI storage at 64 bytes/16 parameters and
admits only presentation/cursor/erase/selected mode sequences. OSC (including
clipboard, titles, links and file transfers), DCS/sixel, APC/Kitty graphics, PM,
SOS, queries, window commands and C1 controls are discarded. Oversized strings
are discarded without retaining their contents. Links do not open automatically;
all link delegates are inert. Native manual selection/copy remains available.
Scrollback is 500 lines; renderer-owned bounded cell/intern tables are additional
to the helper's existing ring. Renderer diagnostics are silenced, no text mirror
is persisted, and literal search reads the bounded in-memory screen only. These
controls do not redact secrets deliberately printed by a trusted task.

A reported gap clears decoder/emulator state, visibly announces the discontinuity,
acknowledges the live-tail reset and releases input. It does not reconstruct the
prior screen. Input needs a new deliberate claim. Native input is queued only
transiently (16 KiB total, at most 4096 bytes per delivery), bound to the current
invocation/generation, removed before a single delivery attempt, and discarded on
scope change, release, gap or detach. Resize is coalesced and serialized with input;
a lost acknowledgement is never replayed.

**PRIVATE COUPLING — external protocol 1:** `setup-v1.sock` is separate from the
unchanged single-response `control.sock`. It uses the same private mode-0700
parent/mode-0600 Unix-socket and peer-UID admission model. Requests/replies are
length framed, versioned, strictly decoded, correlated by request UUID and
monotonically increasing per-connection sequence. A connection owns at most one
attachment; helper credentials/tokens stay in the manager. Eight connections,
9-KiB requests, 128-KiB replies, one byte frame per read and a 15-second activity
lease bound resources. EOF/malformed traffic/idle expiry detaches only that viewer.
The client poisons a connection after a lost reply and never reconnects/replays a
mutation automatically. Input/resize still require the original invocation and
helper-owned lease. Status/cancel travel independently of the helper byte stream.

CLI commands now include `setup presets`, `setup plan --preset NAME`,
`setup plan --from /folder`, `setup capabilities`, `setup list`,
`setup status UUID [--events]`, `setup attach UUID [--input]` and `setup cancel UUID`.
Offline planning starts no manager/helper/VM. Setup observation requires the
running manager; it does not auto-open it. Default attachment is view-only;
`--input` deliberately claims the prompt. Ctrl-] detaches (Return is also needed
in unchanged canonical view-only mode). Input mode duplicates and restores the
original TTY, handles cooperative cancellation and scoped INT/TERM/HUP, restores
complete signal dispositions (including nil/default handlers, masks and flags),
restores open-file flags through a duplicate with bounded nonblocking writes,
and leaves the alternate screen. Darwin’s kernel-only written-status bit is
excluded from the file-flag equality check; see [XNU fcntl.h](https://github.com/apple/darwin-xnu/blob/main/bsd/sys/fcntl.h). SIGKILL, a crashed process or a broken terminal device cannot promise
restoration. `--events` emits structured changed workflow status only, never raw
terminal bytes; `setup status` includes typed child status when available. Existing
VM commands and JSON replies are unchanged. No password flag or stdin-secret
automation contract exists.

**VERIFIED — local fixtures:** `make test` passed 376 manager Swift test functions in 50 suites, 52 script tests, and the relocated/read-only/ad-hoc-signed helper fixtures (including original owner-loss/reopen and terminal streaming). The focused UI/CLI coverage contains 13 functions plus the four-case bundled-preset test: split Unicode/ANSI, cursor/colour/CR rendering, blocked host actions, oversized/malformed streams, storage bounds across cursor/style changes, native viewer ownership/search/reset, strict correlated protocol refusal, cross-view input ownership, EOF/gap/reclaim, distinct cancellation and disposable PTY termios/signal/open-file-flag restoration on detach, connection loss and task cancellation. Vendor inventory, the reviewed two-line source patch, exact upstream export comparison, unchanged shared-package export checks and `git diff --check` passed. No user window was opened or real transport executed.

**TO PROVE / REMAINING:** this delivers the milestone-5 terminal/observation slice,
not the complete setup workflow acceptance. New VM currently records None for
developer setup and points to offline preview after creation; automatic selection
and creation/apply coupling remain gated. Native common-feature editing, frozen
preview-to-apply submission, explicit hash-bound custom-task trust, reviewed
restart/check/recovery actions and their execution CLI contracts still need a
follow-up slice. The UI Apply button is disabled and execution commands return
`setup-execution-disabled`; Homebrew readiness cannot enable them. No operational
runner factory is installed. Real guest/native echo/nested SSH, crash/sleep/wake,
visual acceptance of the complete screen and signed distribution remain separate
acceptance. No real SSH/SCP/SFTP/Ansible, host installs, downloads of factory images,
VM operations, personal credentials, installed-app updates or user UI takeover
occurred. SwiftTerm source retrieval was source-only dependency work.

## Milestone 5 frozen preview, apply submission and task trust — 3 November 2026

**DESIGN DECISION:** `ProvisioningReviewing` extends the existing shared UI/CLI
observation service with manager-owned frozen previews, explicit task-source reads,
apply preparation and consent-bound submission. It uses the existing coordinator,
private input trees, source archive and helper admission; it adds no VM owner,
host controller, guest transport implementation or Python runtime.

A preview names an existing VM UUID and either one bundled preset or an explicitly
selected absolute local folder. Capture runs the pinned planner, archives its
selected files, materializes a fresh private UUID tree, replans there and compares
plan/input/engine hashes. The returned proposal and task receipts describe that
private snapshot. Subsequent source-folder edits do not change it; Refresh preview
creates a new identifier. Reusing an identifier is a lookup of the original
snapshot and rejects a different target/selection. Capture does not inspect tools,
contact a guest, create VM storage, reserve an input owner or authorize execution.
The current session is recorded when present; a changed session needs a fresh
preview. A stopped-guest preview can acquire its exact session only at apply review.
VM name/resources/factory declarations remain a proposal, never configuration edits.

At most 16 previews/captures live in one service instance, with the existing
128-tree/256-MiB private-source retention limits. Proposals are at most 48 KiB;
there are at most 64 task receipts, with names at most 64 bytes and paths at most
256 bytes. Larger previews fail closed rather than truncating a review. Failed,
expired-by-restart and orphaned private trees are preserved and counted; no
recursive deletion or automatic eviction is introduced. Preview handles, consent
and apply-review authority are memory-only. Reopening cannot reconstruct them
from a UUID or source tree, resume an apply, or infer previous task trust. Once a
workflow is prepared/submitted, the existing strict workflow/job journals and
cleanup holds govern restart/loss as before.

Apply preparation is a separate gated operation. It resolves the exact VM/session
through trusted manager-side target evidence, waits for matching managed SSH,
admits package/resources/Homebrew dependencies and returns the existing request
review identity. This binds plan/input hashes, target/session/owner/UID/host key,
dependency digest, mode, task selection and reserved interactive scope. It creates
no helper. Product composition remains `executionEnabled: false` and supplies no
target resolver. This avoids guessing a guest UID from a username or assuming
UID 1000; real manager-owned owner/UID/key evidence is still required before an
operational resolver is installed. Tests inject synthetic bindings only.

Custom-task trust is independent of general Apply, persistent sudo and Docker
root-equivalent access. Its digest covers `custom-task-trust-v1`, the exact request
review identity, frozen input digest and selected task names. A boolean or an old
snapshot's trust digest is insufficient. The scope includes the complete frozen
snapshot (including referenced assets), not just entrypoint text. The UI explains
that custom Ansible can execute on the controller Mac, use controller credentials
and delegate work. Each task has an explicit plain-text inspection action; normal
preview/status/terminal replies contain no task-source bytes. A separate explicit
task-source operation returns at most 4096 bytes bound to preview/name/hash/offset.
The native sheet assembles only a complete UTF-8 task up to 64 KiB before allowing
its inspection prerequisite; the CLI can explicitly request larger files in chunks.
No source is fed to the terminal renderer, executed for review, or logged. Merely
opening text does not grant task trust; the checkbox/CLI digest remains deliberate.
This is consent, not a code audit or sandbox.

Submission verifies exact review/task-trust digests and separate sudo/Docker
acknowledgements before helper creation. It checks the retained private tree,
repeats package admission and dependency discovery, validates original transport
stamps/current manager session, compares the new dependency digest, then invokes
the existing approval path. Duplicate preparation/submission shares one owned
operation. Exact repeated consent returns the same acceptance result; changed
consent is refused. Failed/uncertain submissions are cached, not silently retried
or recreated. The workflow status remains the authoritative evolving result.
Cancellation during the final dependency await cannot activate a helper. Existing
helper-side identity/resource checks still apply after acceptance and at operation
boundaries. An error alone remains no proof of process exit or cleanup.

**PRIVATE COUPLING — external protocol 1:** additive operations `previewCreate`,
`preview`, `taskSource`, `prepareApply` and `apply` use the separate same-user
`setup-v1.sock`; `control.sock` and existing guest command JSON are unchanged.
`previewID` is distinct from `workflowID`; the former becomes the workflow UUID
on preparation. Nested source/consent and responses reject unknown/duplicate/null
fields, oversized or invalid offsets, wrong scopes and legacy boolean task trust.
The existing request/reply bounds, peer UID checks, sequence/correlation, poison-on-
lost-reply and detach semantics remain. No helper credential, input token, raw
terminal byte, private archive or guest credential is added to the review wire.
Only an explicit `taskSource` response carries requested source-file bytes.

The UI now freezes its Preview button through this service, can open a CLI-created
preview UUID for the selected guest, inspects frozen task text, prepares target
review and presents independent consent controls. Apply remains disabled in the
product. A submission attempt disables implicit UI resubmission and directs the
user to workflow status. Source selection cannot edit an already prepared native
review. The supplied Setup screenshot remains the visual reference.

CLI additions (manager must already be running):

```sh
omarchy-vm setup preview VM_UUID --preset developer --preview-id PREVIEW_UUID
omarchy-vm setup preview VM_UUID --from /absolute/folder --preview-id PREVIEW_UUID
omarchy-vm setup preview PREVIEW_UUID
omarchy-vm setup task-source PREVIEW_UUID TASK_NAME --offset 0
omarchy-vm setup prepare-apply PREVIEW_UUID
omarchy-vm setup apply PREVIEW_UUID --review REVIEW_DIGEST --ack-sudo
# Only when deliberately approved for this exact review:
omarchy-vm setup apply PREVIEW_UUID --review REVIEW_DIGEST --ack-sudo --trust-tasks TASK_TRUST_DIGEST --ack-docker-root
```

The caller chooses/retains `--preview-id` so a lost capture reply can be inspected
without recapturing mutable input. CLI parsing never infers acknowledgements,
accepts a password flag or automatically supplies task trust. Ordinary review
commands return one correlated JSON reply, not terminal output. Well-formed
prepare/apply commands return `failure: "disabled"` in the current product before
target/dependency probes or helper launch. Existing check/recover commands still
return `setup-execution-disabled`. Pure `setup plan` remains an offline proposal;
it is not a frozen manager preview or an apply receipt.

**VERIFIED — fake/local acceptance:** `make test` passed 390 manager Swift test functions in 52 suites, 52 script tests and the relocated/read-only/ad-hoc-signed helper fixture suite (including original-owner loss/reopen and terminal streaming). `make test-provisioning-review` passed 28 functions in three suites: frozen previews, original-source edits, explicit task-source chunking, preview quotas, no authority after reopen, separate task/sudo/Docker consent, exact duplicate submission, changed source/tool/session admission, cancellation during a gated final recheck, stale task trust, strict nested protocol cases and CLI/native service interoperability. Tests call the native service API and actual private CLI socket, without opening the form or claiming visual acceptance. Package/export and both diff checks pass; shared package sources/resources/pins are unchanged.

**TO PROVE / NEXT:** native common-feature editing and New VM setup handoff,
reviewed restart/check/recovery UI/CLI actions, operational guest binding/runner
construction, complete visual acceptance and all real-guest echo/nested SSH,
remote cleanup, crash/sleep/wake and signed distribution checks remain. Product
execution is still disabled. No actual SSH/SCP/SFTP/Ansible, host installs, factory
image downloads, VM launches/changes, real credentials or user UI takeover occurred.
Only fake runtimes, original fake process adapters and disposable private fixtures
were exercised. Shared package sources/resources/pins are unchanged.

## Milestone 5 reviewed restart, check and cleanup recovery — 3 November 2026

**DESIGN DECISION:** native Setup and CLI expose one `ProvisioningWorkflowActing`
service for existing workflow actions. This delegates to milestone 3’s restart,
rebind/check and cleanup coordinator rather than adding a second lifecycle owner.
Each action has a caller-retained review UUID, exact workflow/VM/session/job IDs,
workflow sequence, plan/input/dependency hashes and a domain-separated review
digest. Consent carries that review UUID, action, digest and an explicit
acknowledgement; general Apply, task trust or a prior action does not imply it.
Action reviews/consent are memory-only and cannot be restored from a journal or
PID. Existing strict journals record the underlying admitted workflow operations.

Preparation and submission are separate. Exact duplicates share one owned task
and retrieve its original acceptance. A review UUID cannot change workflow/action.
At most 128 review preparations are retained per service; operations for one
workflow serialize. Failed preparation/submission is cached, never automatically
replayed; a deliberate fresh review needs a new UUID. State/hash/session/resource
changes invalidate an unused review. Closing a viewer does not cancel the owned
operation. Service reopen is refused while action admission/execution is in flight;
a reopened service cannot use an old action consent. The existing process-loss
and cleanup-hold rules remain unchanged.

**Restart:** offered only for a clean `restartRequired` workflow with its original
live service context and verified old transport. Review does not stop a VM.
Submission revalidates the package, old session/resources and workflow sequence,
then calls the existing reviewed graceful-restart path. One matching VM `.exited`
is required before a replacement session starts; `.error` remains diagnostic and
does not release the client or authorize another launch. Duplicate consent cannot
cause another shutdown/restart. A replacement session stops at `waitingForRebind`;
no check or setup reapplication is automatic.

**Post-restart check:** this is a check of the workflow’s frozen setup after its
reviewed restart, not an arbitrary existing-guest check command. Preparation
resolves the manager-recorded replacement session through trusted evidence,
requires the same owner/UID/host key, admits fresh dependencies, and uses the
existing immutable archive reconstruction/rebind path. Its review identifies the
new check job/session. It excludes declared custom tasks and grants no interactive
authorization lease. Submission performs a final dependency/resource/state check
before the existing check activation. Ansible receives `--check`; this is not a
promise that arbitrary trusted controller code is a sandbox. A previous Apply or
restart digest cannot approve the new check. A failed/stale check action cannot
launch another helper when repeated.

**Cleanup recovery:** offered only after an unfinished cleanup risk becomes a
terminal/uncertain workflow state, never merely because an active apply/check has
its provisional cleanup-risk flag set. Preparation is metadata/admission work;
it does not fence a worker, create an adapter, touch the guest or read setup
sources. It binds the selected original child/checkpoint record, including its
sequence/attempt state, to the exact original session/owner/UID/host key and
dependency pins. Submission checks the record and fresh dependencies again, then
calls the existing coordinator recovery. The coordinator must obtain the original
authenticated `stoppedAndFenced` proof and matching checkpoint before admitting
any cleanup command.

The new recovery adapter factory is lazy: construction happens only when that
admitted cleanup path reaches its first command. Its wrapper permits only exact
job/target/dependency-bound identity, quiescence, revocation/cache-clear, inactive
verification and payload removal commands, with no plan or input lease. It cannot
stage/reapply setup, execute custom tasks, request a grant or restart a guest.
No factory is called when original ownership is missing. Even valid saved metadata
and a new same-user process cannot manufacture a surviving capability. Failed
revocation keeps cleanup required and the VM hold; it does not produce success or
clear risk. A later explicit review binds the changed checkpoint/attempt state;
previously prepared stale cleanup reviews are refused. Source removal does not
prevent the source-free cleanup path. Matching helper exit remains required before
a clean workflow result clears its hold.

**PRIVATE COUPLING:** additive `prepareAction` / `performAction` operations use the
same strict separate setup socket. Preparation requires `workflowID`, action and
`actionReviewID`; submission requires the workflow and a strict typed action consent.
Unknown/duplicate/null fields, cross-preview scopes, unsupported actions, bad
digests and secret/force overrides are refused. Replies correlate request/sequence,
review UUID, workflow and action. `ownership-unverified` is a fixed failure code;
no private error string, credential, worker token, helper PID, source or terminal
byte enters action review/status. Old guest commands and their JSON protocol are
unchanged. Product prepare/perform operations return `failure: "disabled"` before
any target/tool/adapter work, including when a review UUID is unknown.

The Setup tab offers stage-appropriate review buttons, action explanations,
explicit acknowledgement and a submit control. Restart describes shutdown/exit/
replacement semantics; check explains its frozen inputs and excluded tasks; recovery
explains original ownership and cleanup-only scope. State changes are validated by
the service. A submission attempt is never silently repeated. Native buttons stay
disabled in product composition, and the complete screen has not been opened for
visual acceptance in this slice.

CLI follows the same two-step contract (retain the review UUID):

```sh
omarchy-vm setup prepare-restart WORKFLOW_UUID --review-id REVIEW_UUID
omarchy-vm setup restart WORKFLOW_UUID --review-id REVIEW_UUID --review REVIEW_DIGEST --ack
# After matching exit, replacement session and managed SSH admission:
omarchy-vm setup prepare-check WORKFLOW_UUID --review-id NEW_REVIEW_UUID
omarchy-vm setup check WORKFLOW_UUID --review-id NEW_REVIEW_UUID --review CHECK_DIGEST --ack
# Only for an unresolved original cleanup obligation:
omarchy-vm setup prepare-recover WORKFLOW_UUID --review-id RECOVERY_REVIEW_UUID
omarchy-vm setup recover WORKFLOW_UUID --review-id RECOVERY_REVIEW_UUID --review RECOVERY_DIGEST --ack
```

Missing `--ack` is never inferred. There is no force, password, source/VM replacement
or task-trust override for workflow actions. Commands require the existing manager;
they do not auto-open it. Acceptance and current workflow status are distinct;
inspect `setup status` after a lost reply rather than inferring an outcome or
silently starting another action. A new review UUID is required for a deliberate
new attempt after failure.

**VERIFIED — fake/local acceptance:** `make test` passed 403 manager Swift test functions in 54 suites, 52 script tests and the relocated/read-only/ad-hoc-signed helper fixtures, including original-owner loss/reopen and terminal streaming. `make test-provisioning-actions` passed 13 functions in two suites (including ten malformed-wire variants and three final-check admission/cancellation variants). Fake fixtures cover explicit consent, shared CLI/native action lookup, duplicate restart/check, diagnostic-vs-exit boundaries, fresh-session frozen checks with custom tasks excluded and no authorization input, active-risk recovery refusal, lazy factory ordering, missing original capability after reopen, source-free cleanup, failed revocation/retained holds, stale sibling recovery reviews, failed-operation non-replay and lost in-memory consent. Product endpoint tests prove disabled refusal before probes/factories. UI controls compile; complete interactive/visual acceptance was not performed. Package/export checks and both diff checks pass. Shared package sources/resources/pins are unchanged.

**TO PROVE / NEXT:** native common-feature editing and New VM setup handoff remain
milestone-5 work. Real owner/UID/key evidence, operational runner/recovery factories,
whole-screen interaction/visual acceptance, actual nested SSH/guest echo and cleanup,
crash/sleep/wake and signed distribution retain their separate gates. Product
execution, target resolution and recovery adapter construction stay disabled.
No real SSH/SCP/SFTP/Ansible, host installs, factory downloads, VM launches/changes,
real credentials or user UI takeover occurred. Fake runtimes use only disposable
manager-owned UUID roots. No shared package source/resource/pin change was needed.

## Milestone 5 native features and New VM handoff — 3 November 2026

**DESIGN DECISION:** native Setup and New VM share typed common-feature choices:
Use source, Enable or Disable. The controls cover workstation, CLI, VCS, editors,
Docker, build, toolchain, languages, browsers, databases, API and quality. Advanced
profiles, custom catalogues, feature options, assets, variables, dotfiles and tasks
remain in the selected manifest. The pinned shared planner still resolves all
profiles, dependencies, ordering, options and conflicts. Disable does not mean
uninstall. Missing Homebrew tools do not prevent an offline review; they continue
to block admitted application, and readiness cannot enable product execution.

Changing a choice creates a new reviewed input, rather than mutating the selected
folder or treating an old digest as current. The manager first freezes the valid
source through the shared planner, then writes an exclusive private
`.omarchy-manager-selection.json` derived from that frozen manifest. Native choices
replace only the corresponding built-in enable/disable entries (including
`builtin.` aliases). The original manifest stays byte-for-byte intact, with its
mode retained as an explicit asset. The shared planner replans the private tree;
the exact generated bytes, original manifest, selected files and modes enter the
input/plan hashes. No-edit reviews keep their original shared-plan identity.
A conflicting reserved file is refused. Newly enabled file references must already
be in the frozen source (declare otherwise-unselected files in `assets`); the
manager never goes back to capture extra live files after freezing. Generated
bytes/entries count against the existing private retention quotas. Failed/partial
trees are preserved without eviction or VM-storage deletion.

New VM offers None, a bundled preset or an explicitly selected local setup folder,
common-feature controls, exact frozen proposal/hashes and an acknowledgment to
**save the selection**. That acknowledgment grants no task trust, sudo authority
or execution. The source's VM declaration is visible in the proposal, but creation
uses only the existing manager form/CLI resources, factory, SSH, owner and sharing
choices. Create saves metadata and opens the new guest's Setup tab with the same
frozen review; it does not start the VM, helper or setup. Later apply still requires
the existing separate target/dependency, custom-task and persistent-grant review.

**PRIVATE COUPLING — creation receipt:** `ProvisioningCreationPlanning` adds
prepare/lookup before a target exists. An acknowledged creation review is reserved
for one VM UUID and a digest of the explicit manager creation arguments. After the
service hop, creation rechecks shutdown/resource/SSH-port admission before the
registry save, without another suspension. A concurrent use of the same selection
is refused while in flight. Once saved, exact duplicate consent/configuration
returns the original VM UUID without mutation or launch; changed settings are
refused. An uncertain/failed save after reservation retains the consumed binding
rather than silently retrying a second UUID. Inspect the registry outcome before
a deliberate fresh review. Public-key cleanup on failure remains in place.

Registry schema 6 carries an optional, validated `developerSetup` receipt: review
UUID, VM UUID, review/plan/input/engine hashes and creation-configuration hash. It
contains no source path, original bytes, credentials, task trust or executable
consent. Review IDs are unique across profiles; retained POC profiles cannot gain
one, and configuration cannot replace it. Older schemas still load; a schema-6
registry is rejected by older builds instead of dropping the receipt. The normal
preview is bound lazily only after the manager observes the matching saved receipt.
It uses the original private inputs and binds no guest session during creation.
After manager restart, the receipt supports metadata lookup/deduplication only;
private files and saved IDs cannot reconstruct a preview or apply authority.
A new review is required. A changed original folder cannot alter a live review.

**PRIVATE COUPLING — CLI:** strict setup protocol 1 adds `prepareCreation` and
`creation`, using `previewID` and source without a VM/workflow scope. The former
returns `creationReview`, including the proposal and review identity. Native
choices are typed `source.features.enable/disable` lists. Duplicate, unknown,
overlapping, null and extraneous fields/scopes fail closed. Existing request/reply
bounds and correlation still apply. Guest command protocol 1 accepts an optional
strict creation-only `setupConsent`; responses expose the optional non-secret
receipt. Absent fields preserve existing command behavior. Selection handoff
rejects start, wait and connection-detail probes; a separate lifecycle command is
required. There is no credential or automatic-execution flag.

```sh
# The manager must already be running. Choose and retain the UUID yourself.
omarchy-vm setup prepare-create REVIEW_UUID --preset developer --disable docker
omarchy-vm setup creation REVIEW_UUID
omarchy-vm create work --memory 8GiB --cpus 4 --disk 128GiB --factory official \
  --setup-review-id REVIEW_UUID --setup-review REVIEW_DIGEST --ack-setup-selection
omarchy-vm setup preview REVIEW_UUID
# Native overrides also work on an existing guest's new preview:
omarchy-vm setup preview VM_UUID --from /absolute/folder --preview-id NEW_UUID \
  --enable cli --disable docker
```

Repeated distinct `--enable FEATURE` / `--disable FEATURE` choices are accepted;
one feature may occur once. Standalone `setup plan` remains unchanged and supplies
no reusable creation/apply authority. Setup capture/lookup does not auto-open the
manager or invoke dependency probes. General guest-command manager discovery
keeps its existing behavior.

**VERIFIED — fake/local acceptance:** `make test` passed 419 manager Swift test
functions in 55 suites, 52 script tests and the relocated/read-only/ad-hoc-signed
helper fixtures (including original-owner loss/reopen and terminal streaming).
`make test-provisioning-selection` passed 16 Swift test functions in one suite.
Fixtures cover original bytes/modes and no-edit identity, every presented built-in,
shared custom-catalogue dependency refusal, preserved profiles/options/tasks,
manager resource/factory precedence, exact frozen handoff, protocol/guest-command
round trips, duplicate create, concurrent port admission, separate acknowledgement,
unknown/duplicate/null/overlapping fields, changed private inputs, reserved-file
collision, quota, uncertain-save non-replay, and metadata-only reopen. Fixtures
assert zero VM starts, dependency inspections, helper launches and VM storage
roots. The actual Swift Testing runner was executed outside the sandbox; build-only
sandbox invocations are not counted as passing tests. `python3 Scripts/provisioning_package.py`
and both worktrees’ `git diff --check` pass; shared sources/resources/pins have no
diff. Complete native interaction/visual acceptance was not performed.

**TO PROVE / NEXT:** complete Setup/New VM interaction and visual acceptance,
operational owner/UID/SSH-key evidence and runner/recovery factories, approved
milestone-6 guest/echo/revocation/restart/check/crash/sleep/wake acceptance and
milestone-7 signed distribution. Product execution remains false, with no target
resolver or operational cleanup factory installed. No real SSH/SCP/SFTP/Ansible,
host installs, factory downloads, VM launches/changes, personal credentials,
installed-app changes or user UI takeover occurred. Shared package sources,
resources, export base/patch and engine pins are unchanged.

## Milestone 6 preparation: authenticated identity and dormant backends — 3 November 2026

**DESIGN DECISION:** preserve the owner UID already authenticated by managed SSH,
instead of inventing one from a username, guest-status file, manifest or creation
receipt. `SSHReadinessChecking` adds a source-compatible authenticated-observation
method. Its default forwards readiness with no evidence; legacy/fake readiness
alone cannot resolve a product provisioning target. The manager's normal SSH probe
now captures endpoint/key references before authenticating, strictly parses the
bounded result and checks the same pins after authentication. Raw replies are
neither journaled nor returned on the setup socket. Evidence/challenge/observation
reflection is redacted; client key bytes are not copied into the evidence.

**PRIVATE COUPLING:** the admitted runtime's existing guest command
`/usr/lib/try-omarchy/managed-ssh-identity` emits exactly `vmID`, `sessionToken`,
`user`, `uid`. Source inspection confirms that the IDs come from the current guest
managed-SSH status and user/UID from the executing account. The new JSON grammar
requires exactly those fields, the expected VM/session and selected owner, and an
integer UID in 1000..<60000. Duplicate/unknown/null, boolean/string/fractional UID,
oversized output, SSH failure or host-key mismatch is refused. An enrolled owner
snapshot must match the selected account. This is source verification of the
contract, not evidence from a real running guest.

Ephemeral evidence binds the authenticated owner/UID, exact runtime session,
manager-owned UUID-root inode/device, configured port, manifest/bootstrap/known-host
hashes, Ed25519 host key and stat-pinned client identity. A monotonic 45-second
freshness window covers the normal 30-second authenticated refresh plus its
bounded connection attempt. Future, expired or changed evidence cannot resolve a
target. A successful refresh of the same binding does not briefly emit Connecting
and cancel a running setup; failed authentication clears readiness/evidence before
retry. Evidence changes invalidate active provisioning, and retry, pause, shutdown,
exit or probe-generation change clears it. Late callbacks cannot restore it.
An `.error` remains diagnostic; only matching `.exited` ends lifecycle ownership.
Reopening cannot recover evidence from disk.

Product target resolution uses this manager-owned evidence, not a caller-supplied
UID or the native/CLI display state. Host transport admission and every manager
transport revalidation additionally require the matching fresh evidence. The
internal fixture policy remains available only through trusted test injection and
is not selectable on a wire, manifest, flag or environment variable. The shared
adapter still independently verifies the remote owner/UID and platform before work.

**DESIGN DECISION — dormant composition:** `ProvisioningProductExecution.enabled`
is a fixed false build-time acceptance gate shared by manager/helper composition.
There is no user/environment/tool-readiness bypass. Product service construction
now supplies the inert authenticated resolver and lazy recovery constructor, but
prepare/apply/actions still fail at the existing gate before probes, factories or
a worker launch. The public inherited helper channel still supplies no engine or
process runner while the gate is false. Its dormant enabled branch requires the
existing frozen input, original inherited ownership, delivered transport, manager
session authority and terminal hub before constructing the existing local runner.
No independently supplied command/path/UID can request that constructor.

The worker constructor reuses bundled package/resource/engine admission and the
pinned process host through `BundledProvisioning.localRuntime`. The helper backend
still fences the runner and authorizes every invocation through the original
manager channel. The lazy recovery constructor rechecks package and exact transport
pins before constructing the shared adapter/local runner. Existing deferred scope
allows only original identity/quiescence/revocation/cache/inactive/payload cleanup,
with no plan, task or authorization input; original-worker fencing and cleanup
checkpoint admission precede construction. Recovery authority revalidates the exact
binding/dependency scope and current manager transport before each operation. A
new runner/adapter, saved journal or PID cannot prove the original worker stopped.
No execution gate is enabled by this preparatory work.

**VERIFIED — fake/local:** `make test` passed 428 manager Swift test functions in
56 suites, 52 script tests and the relocated/read-only/ad-hoc-signed helper fixtures
(including original-owner loss/reopen and terminal streaming).
`make test-provisioning-identity` passed 43 functions across nine suites.
`make build`, package/export verification and both diff checks pass.
Focused identity/backend tests include strict fake authentication replies, changed
pins and private-key references, exact-session/generation lookup, freshness,
same-binding refresh vs changed UID, readiness-only refusal, manager-aware recovery
with fake process runners and package re-admission. Existing cleanup/fencing tests
remain in the focused run. The normal monitor also runs against fake SSH replies
and fixture sleeps to check two authenticated refreshes without a readiness drop.
No test in this slice invokes real SSH/SCP/SFTP/Ansible or starts a real guest.

**VERIFIED — offscreen component rendering:** the debug-only
`--render-setup-component-fixture /private/tmp/NEW_FILE.png` mode runs before
AppModel, instance-lock, registry and service construction, with application
activation prohibited and no ordered window. It writes one new temporary PNG.
It uses the actual native feature controls and terminal emulator with explicitly
labelled synthetic bytes. The inspected [component image](media/setup-components-offscreen.png)
shows all 12 feature rows, explanatory text and correctly oriented Unicode/ANSI
terminal output without clipping. The embedded layer-backed terminal needs its
own Core Graphics draw in the offscreen bitmap; a plain SwiftUI cache omitted it.
This is a renderer fixture, not a captured live job or full Setup/New VM screen.
No user window was opened, controlled or captured. Whole-screen interaction,
accessibility, focus, scrolling and real prompt/echo acceptance remain TO PROVE.

**TO PROVE:** actual guest identity/UID/key provenance, nested SSH/TTY echo,
end-to-end setup and revocation, restart/check, remote process quiescence,
crash/sleep/wake and signed distribution still require their recorded separate
acceptance. Whole-screen native interaction is not established by a component
snapshot. No host tool install, factory download, VM launch/change, personal
credentials or user desktop takeover occurred. Shared package sources/resources,
immutable export base/patch and engine pins remain unchanged. This prepares
milestone 6; it does not record a real-guest pass or enable production execution.

## Full Setup/New VM acceptance and milestone 6 runbook — 3 November 2026

**VERIFIED — isolated fake/local:** the actual `VMEditor`, native selection view,
manager sidebar/settings and Setup screen now have a debug-only acceptance harness.
It runs before normal AppModel/instance-lock/registry/service construction with
an injected in-memory service, FakeRuntime and absent temporary support root.
A scoped environment object drives real bindings/shared actions; no global bus,
OS input injector, environment override or product gate bypass is added. App
activation is prohibited; backing windows cannot become key/main, ignore input
and are checked to lie outside every display. No desktop window is controlled.

`make test-provisioning-screens` passed 56 checks: None/empty-name creation,
independent frozen review acknowledgment, feature/source invalidation, delayed/
failed replies, manager resource/factory precedence, duplicate same-UUID creation,
exact Setup handoff, complete chunked UTF-8 task inspection, cross-guest/lost preview
refusal, disabled product preparation, independent sudo/Docker/task/inspection
consent, single fake submission, terminal search/expand and explicit cancel.
Synthetic terminal bytes grant no connection/input authority; disappearance only
detaches. See the [acceptance matrix, eight inspected images and reports](DevVMUIAcceptance.md).
The new target is part of `make test`. Full validation passed 428 manager Swift
functions in 56 suites, 52 script tests and relocated/read-only/ad-hoc-signed helper
fixtures, plus the screen checks. The final focused screen run passes. Release
compilation (`make build-signed`, without signing credentials) passes; binary
inspection confirms the debug fixture entry point and markers are omitted.
Package/export verification and diff checks pass.

**DESIGN DECISION:** Save/Apply handlers share their button enablement guards,
including complete required-task inspection, so actions cannot bypass that state.
A loaded frozen selection now explains why it remains available when the source
picker is None. DEBUG seams are available only through explicit local injection.
No installed app, personal registry, permission, credential, host installation,
real transport or guest operation is involved. Shared sources/resources/export
base/patch, engine pins and the fixed-false product execution gate are unchanged.

**TO PROVE:** this establishes whole-screen layout and view/action behavior with
fakes; it does not establish physical clicks/keyboard, focus, VoiceOver, native
file/task/confirmation dialogs, real terminal input/echo or a real guest pass.
The [milestone-6 disposable-guest runbook](DevVMMilestone6Runbook.md) is prepared,
not executed. It records a concrete approval worksheet, scoped operational-build
prerequisites, real identity/apply/TTY/cleanup/reapply/restart/check/failure matrix,
abort rules and matching-exit/owned-process/Trash cleanup. A separately reviewed,
fake-tested candidate restricted to approved disposable UUID roots is required
before real execution; a blanket gate change is not acceptance admission. No real
run, tool install or image download is authorized by this documentation. Signed
distribution remains milestone 7; a release compile is not distribution acceptance.

## Milestone 6 disposable admission foundation — 3 November 2026

**DESIGN DECISION:** product execution is derived from an optional, trusted
`ProvisioningDisposableAdmission`, currently `nil`. The ordinary build remains
disabled; there is no independent Boolean enablement switch. A future private
candidate must embed the same originally reviewed UUID/root/device/inode/ownership-
marker hashes in manager and helper. The internal fixture policy is not a public
option. No manifest, source name, CLI/environment flag, dependency report, registry,
journal or received packet can create an approval. An owned UUID marker alone does
not establish that an existing VM is disposable: that requires the explicit trusted
approval record for newly prepared disposable roots. No actual roots are approved
or prepared by this change.

The approval admits one to eight exact UUID roots under the manager namespace,
rejects retained POC IDs, and holds directory descriptors to prevent approved inode
reuse. Each check verifies private owner/mode, root device/inode and original
ownership/storage markers. Replaced roots, unsafe paths/symlinks, changed marker
bytes and unrelated UUIDs fail. Filesystem identity handles macOS temporary-directory
aliases without treating arbitrary symlinks as approved roots. Scope/reflection
strings redact identifiers and paths. The constructor only reads metadata and pins;
it never creates storage, probes tools, constructs a runner or operates a guest.

The manager installs admission with its coordinator and enforces its own profile/
root/session namespace at preparation, transport and lifecycle lease boundaries,
including cleanup. Restart checks both before shutdown and after old matching
`.exited`, before replacement start. A compiled candidate's scope also applies to
initial start before service installation and after coordinator close. The helper
independently checks its local approval against delivered validated transport before
runner construction, and before/after manager RPC at preparation, command and
invocation boundaries. Terminal claim/input/resize recheck the same approval;
failure revokes input ownership while preserving read-only output. Recovery checks
scope before constructing an adapter and uses the existing original-worker/session
fences for every operation; cleanup is not a scope bypass. Final apply/check/recover
transport admission also precedes fresh dependency inspection when an existing
review's scope has become invalid.

**VERIFIED — fake/local:** `make test-provisioning-admission` passes 12 Swift test
functions in one suite (including seven invalid-record and eight changed-storage
cases). Coverage includes an admitted fake workflow, manager refusal before tool
inspection/helper launch, independent helper refusal despite manager approval,
helper refusal after an allowed manager RPC, same UUID under a different manager
root, refusal before restart shutdown and before replacement start, cleanup adapter/
command refusal, and input revocation across viewers. Test runtimes/process runners
are fake; all marker/transport files are disposable synthetic local fixtures. No
real SSH/Ansible, host tool installation, image download or VM launch occurred.

Full `make test` passed 440 Swift functions in 57 suites, 52 script tests,
relocated/read-only/ad-hoc-signed helper fixtures and all 56 isolated screen checks.
The final focused admission target also passed after the cross-viewer input check.
`make build-signed` passed as release compilation only, without real signing
credentials or notarization. Package/export verification and both diff checks pass.

**TO PROVE:** a real signed candidate containing the specific reviewed original
pins, actual guest identity/TTY/apply/cleanup/restart/check and crash/sleep/wake. The
[runbook](DevVMMilestone6Runbook.md#implemented-admission-boundary--fakelocal-evidence-only)
now records implemented scope semantics, root preparation/approval prerequisites
and the remaining operational blockers. Existing signature/package/resource/engine
admission, authenticated owner/UID/key evidence, independent consent and original
worker cleanup proofs remain required. Shared package sources/resources, immutable
export base/patch and engine pins are unchanged; signed distribution is milestone 7.

## Native Source and multi-profile cards — 3 November 2026

**DESIGN DECISION:** Source selects the configuration location (bundled or local),
while a separate card grid selects one or more bundled profiles. Native feature
overrides are hidden for now. Cards have colored native icons/monograms and
human-readable inclusions derived from the existing shared resolver, including
inherited base features, language tools and database clients. No parallel catalogue
or profile dependency resolver is introduced. Saved-preview profile names are
visible; raw proposal data, fingerprints/UUIDs and CLI lookup remain under Details.

The source DTO adds optional `bundled` and `profiles` fields. Exactly one of the
legacy preset, local directory or explicit bundled source is accepted. Profile
additions are bounded, unique and restricted to the four bundled IDs; bundled
source requires a nonempty selection. Legacy preset/CLI requests remain compatible.
A neutral manager-owned bundled manifest supplies no selected profile. The existing
private generated-manifest mechanism adds the selected profiles to frozen inputs;
it preserves local declared profiles, options, custom features/tasks/assets and VM
fields, deduplicating builtin aliases. Local cards are explicitly additional
profiles, not a replacement of the manifest's own list. The source tree is never
rewritten. Profile changes invalidate review acknowledgment and generate a new
frozen selection. Metadata-only creation and separate task/sudo/Docker approvals
are unchanged.

**PRIVATE COUPLING:** profile resolution/merge/conflict semantics stay in the
pinned shared Swift planner. A sibling conflict is refused and surfaced as
`conflictingProfiles` / setup-socket `profile-conflict`, rather than silently taking
the last profile. Local explicit options can resolve it. The four legacy resource
presets and CLI `--preset` remain available; the new native card selection uses
explicit bundled source/profile fields over the same strict local protocol.

**VERIFIED — fake/local:** eight new test functions cover bundled combinations,
neutral/frozen inputs, local profiles/aliases/tasks/settings, source immutability,
conflict refusal and explicit resolution, strict malformed profile wire input,
review identity changes, native/external agreement and resolver-derived card
summaries. Focused selection validation passed 24 functions in two suites. Full
`make test` passed 448 Swift functions in 58 suites, 52 script tests, local signed
helper fixtures and 62 isolated screen checks. Eight inspected screenshots and the
report are linked in the [UI acceptance record](DevVMUIAcceptance.md#separate-source-and-multiple-profiles--3-november-2026).
Release compilation passed without signing credentials; package/export and both
diff checks pass.

**TO PROVE:** physical desktop input/focus/accessibility and native file dialogs,
real signed-candidate/guest identity/TTY/apply/cleanup/restart/check/crash/sleep/wake
and distribution retain their separate gates. Product disposable approval remains
nil, with no real transport, host installs, VM launches or downloads performed.
Shared package sources/resources, immutable export base/patch and engine pins are
unchanged. Native cards cover bundled profiles; custom catalogue profiles remain
editable in a local manifest. An icon/summary or selected card is no execution grant.

## Optional-app trim selection — 3 November 2026

**DESIGN DECISION:** New VM and Setup show **Trim optional apps** only for the
selected/recorded official Try Omarchy factory. Setup uses the exact admitted
factory identity, including both hashes, rather than a display name. Unknown,
legacy and custom factories hide the control. It defaults off. Changing the trim
choice invalidates the preview and acknowledgments; changing the New VM factory
also resets the choice. Returning to official does not re-enable trimming.
The tooltip explains the official image's broad app collection and the more
sensible development base. Trimming affects the guest derived from the image,
not the reusable factory/cache. The reviewed selection shows a visible trim notice;
Details contains the candidate packages and dependency-check limitations.

**PRIVATE COUPLING:** optional Boolean `ProvisioningSetupSource.trimOptionalApps`
projects to the existing `vm.lean_developer` field in a private frozen manifest.
Native controls explicitly pass on/off, overriding a local manifest's trim flag;
legacy CLI/manifests with no override retain their declared behavior. Original
source bytes are unchanged. Creation reservation and workflow preparation reject
trimmed plans for a non-official or missing recorded factory, independently of UI
visibility. An offline creation preview alone does not establish factory admission.

**IMPLEMENTED:** the shared Swift planner now describes allowlisted removal
candidates instead of silently reporting no removals for `lean_developer`. The
adapter reuses upstream `apply-lean-developer.py` and `lean-developer.packages`,
now included in the pinned resources. Apply runs it after explicit manifest
package installation and before feature configuration, under the authenticated
job supervisor and reviewed interactive terminal lease; output uses the existing
live stream. Empty manifest package lists still run an opted-in trim. Check mode
never invokes it. Manifest selections and resolved feature package names are
passed as protected `--keep` choices. The existing helper verifies the guest,
previews recursive transactions, retains protected components and selected
software, uses Omarchy's native removal command and stops on unexpected failures.
The existing supervisor/quiescence/revocation/payload cleanup path covers failures.
No host Python/PyYAML prerequisite is introduced: the reused helper runs in the
guest, which already supplies Python for the provisioning payload.

**PRIVATE COUPLING:** the immutable base revision and durable-state patch remain;
`Patches/dev-vm-optional-app-trim.patch` records this additional source, test and
resource export. Lock, engine, snapshot and compiled admission pins change together.
Product disposable approval remains nil and execution disabled. Real guest trim,
package closure, idempotence and terminal behavior remain **TO PROVE** in an
explicitly approved disposable run; offline candidates are not observed removals.

**VERIFIED — fake/local:** 28 focused manager selection functions (four new trim
functions, including five strict wire cases) pass. The manager suite passes 452
Swift functions in 59 suites and 52 script tests. Final package admission passes
seven Swift functions, six package script tests, reverse integration-patch/export
verification, and relocated/read-only/ad-hoc-signed local helper fixtures. Final
shared Swift tests pass 77 functions, including streamed supervised trim command
construction, guest login-shell lookup, no-packages opt-in, check/default exclusion,
failure cleanup, whitespace/repository-selector normalization and selected-package
retention. Twelve upstream trim tests pass with mocked subprocess results; Python
syntax checks parse the helper/resource sync script without executing the helper.
Final offscreen acceptance passes 74 checks, creates twelve synthetic PNGs and
starts zero runtimes or on-display windows. The four new scrolled trim captures
were visually inspected; [retained evidence](media/setup-trim/evidence.json) links
them to the fixture report. None establishes actual guest removals or hover input.

**VERIFICATION EXCEPTION:** the companion `make test-omarchy` target was run before
its full test implementation was inspected. It invoked installed Ansible against
temporary local-connection inventories and synthetic helper files, contrary to the
requested no-real-Ansible restriction. It finished with 10 failures, 44 errors and
one skipped test among 235 tests (including missing Python TOML support). This is
not a passing acceptance result. It contacted no guest and installed no host tools;
remaining trim verification used fake runners/mocked helpers only. No SSH/VM or
factory operation occurred. The earlier transient package admission failures while
finalizing the export pin were resolved by re-pinning and rerunning package checks;
no admission guard was weakened.

Final `make build-signed` passes as release compilation only, without signing
credentials or notarization. Final pins: engine
`83061c59cd7f1c4f87f0762183eaa6a4b61bc85592366874cd86e1654a9d8ff7`,
source snapshot `f910c84274813f9b3c1b303ffd8336e79452f05b4a7dc752dcbe554a3b2e1f7e`,
lock `e4ace86b924249c8e08889c9c2eb443029fc475eb10011ece052614b9eda808a`.
Both worktree diff checks pass. Changes remain uncommitted.

## Theme and layout selection — 3 November 2026

**DESIGN DECISION:** New VM and Setup expose a **Theme & layout** disclosure,
collapsed initially, independently of Source and Profiles. Theme accepts an HTTPS
GitHub repository root, `random`, or `most-starred`. Blank keeps the source/current
choice. Random defaults to an inclusive minimum of ten GitHub stars; zero disables
the star lookup. `most-starred` uses the highest count with a stable URL tie-break.
The native path uses an existing authenticated `gh` for star-based selection; it
never installs tools, initiates sign-in, imports tokens or logs metadata/errors.
A direct URL and unfiltered random need no GitHub CLI. Existing Homebrew/Ansible
feature gates and the disabled product execution gate remain unchanged.

**IMPLEMENTED — review-time validation:** Review setup/Update preview validates
the field, resolves a marker once against dev-vm's public Omarchy theme catalogue,
then performs an unauthenticated **GET** of the resulting repository page. This
checks repository shape, TLS/HTTP accessibility and status, not whether a repository
contains a working/safe theme. It does not clone or execute the repository or pin a
Git commit. The resolved canonical URL is frozen in the workstation options; lost
reply lookup does not reroll or re-fetch it. Subsequent explicit previews may choose
a different theme. Failure prevents a usable review; UI errors are fixed messages
and CLI/socket failures are bounded codes, without server output or credentials.

**PRIVATE COUPLING:** shared Swift `ThemeSelection`/`ThemeResolver` owns selector
normalization, catalogue figure extraction/deduplication, threshold/ranking/random
semantics and final accessibility requirements behind injected HTTP/star providers.
The manager supplies fresh ephemeral GET sessions (no cookies, credential storage,
cache or browser sign-in), fixed GitHub/catalogue destinations and same-host
validated redirects, limited to five. Requests have 15-second request/30-second
resource timeouts; catalogue responses are capped at 2 MiB/1,024 repositories.
Repository validation stops after response headers rather than downloading a
repository. Star metadata uses the existing bounded, noninteractive read-only tool
runner and `gh api` GraphQL in batches of fifty with a thirty-second timeout and
256 KiB output budget. Only explicitly missing repositories may be omitted;
malformed/incomplete/unexpected error data fails selection. No raw response is
logged. Source/package admission precedes these reads; final planning re-admits it.

**DESIGN DECISION — layout:** use the configuration/current layout, select a Lua
file, or remove the managed layout. Selection/removal are mutually exclusive. The
file picker shows the selected basename and explains that Lua runs in the guest
and changes take effect at the next desktop login. The manager captures a regular
UTF-8 file without NULs, up to 256 KiB, through no-follow descriptor traversal and
checks its size/inode/timestamps across the read. It does not execute or claim to
validate Lua syntax. The bytes are copied as a fixed private snapshot file, not an
absolute host path in the proposal. Hashes remain under Details. Changing the
original file after review does not alter the reviewed input; a new preview captures
new bytes. Source files are never edited. Theme/layout edits clear existing review,
task inspection and acknowledgments, as other selection edits do.

**PRIVATE COUPLING — handoff:** optional strict `ProvisioningSetupSource.appearance`
fields carry the selector/star threshold and layout selection over native/CLI/socket
review APIs. CLI review commands accept `--theme`, `--theme-min-stars`,
`--layout-file` and `--remove-layout`. The generated private manifest overlays
workstation theme/layout options while preserving other options, aliases, profiles,
tasks and assets; it explicitly includes the workstation feature. An explicit
workstation disable is refused instead of silently ignoring customization. Private
quota accounting admits at most the generated manifest plus one bounded layout file.
The existing shared planner snapshots the layout, and the adapter's existing
workstation variables/Ansible staging/native Omarchy helpers own application.
Check-mode arguments stay intact; no separate theme/layout executor or VM lifecycle
owner is introduced. Saved preview summaries show the concrete theme and layout
intent outside Details. Appearance selection does not authorize execution or tasks.

**PRIVATE COUPLING:** `Patches/dev-vm-theme-selection.patch` adds the shared selector,
resolver and fake tests over the previous immutable base/durable/trim integration
patches. The package/resource inventory and compiled lock/engine/snapshot pins
change together. No host Python/PyYAML requirement, YAML workflow change or new
runtime dependency is introduced.

**TO PROVE:** live catalogue format/accessibility and GitHub authentication/rate
limits, actual theme compatibility/content, native file dialogs/hover/focus/input,
and application/reapply/check/layout login behavior in an explicitly approved
disposable guest. A GET is not semantic verification or a content pin. Existing
signature/provenance/transport/consent/cleanup/admission requirements remain, and
product approval stays nil. The broad companion Ansible test target is intentionally
not run for this slice: its implementation invokes real Ansible, which the user's
fixture-only constraint overrides. No real HTTP/gh/SSH/Ansible, host installation,
factory change/download or VM launch is used in this slice's verification.

**VERIFIED — fake/local:** `make test` passes **463 manager Swift functions in 61
suites, 52 script tests**, relocated/read-only/ad-hoc-signed helper fixtures and
**82 offscreen UI checks with sixteen PNGs**. The focused appearance target passes
eleven functions in two suites, including five unsafe-layout, eight malformed-wire
and eight invalid-star-reply variants. URLProtocol proves the real HTTP adapter
uses GET without opening a socket; fake tool runners verify the exact gh query,
noninteractive environment and error handling. Core tests verify frozen bytes,
lookup without reselection, source preservation, strict CLI/socket behavior,
rejected repositories/layouts and inactive-workstation refusal.

Shared `make test-provisioning` passes **84 functions**, including six selector/
resolver functions and the frozen theme/layout transport test in both apply/check
modes using fake process runners. Nine selected upstream controller tests pass
under guards that forbid real network, subprocess or manager access; nine upstream
theme-helper tests pass with disposable HOME and stub Omarchy/git commands.
Shell syntax checks for the unchanged theme/workstation helpers and Python AST
parsing for the resource-sync script pass. No broad companion/Ansible syntax target
is invoked. Final release compilation passes without real signing credentials or
notarization. Reverse patch/export verification and both worktree diff checks pass.

The four new light/dark appearance captures were inspected and retained with
[evidence hashes/report](media/setup-appearance/evidence.json). They show actual
native view hierarchy and synthetic reviews; they do not exercise physical input,
hover, a file dialog, live GitHub or real guest behavior. Final engine pin is
`f51a1b3d9f0432b613b67b014ca6abd5d18794f2edae11b5b5eacbc9508b00a0`,
source snapshot `c044d29456af01c1f1bb7e0fa26054c940638f9cd0d560a5ffca96bb1a460c7d`,
and lock `60373a8c011f31ba1c73d75b3022c09d966a5020a8a124efda3b381d3adfc82a`.
Changes remain uncommitted in both worktrees.

Example review-only CLI selections (use a fresh review UUID and an existing local
layout file; these do not launch or apply setup):

```sh
omarchy-vm setup prepare-create REVIEW_UUID --preset developer --theme random --theme-min-stars 10
omarchy-vm setup prepare-create REVIEW_UUID --preset developer --theme https://github.com/OWNER/THEME --layout-file /absolute/path/layout.lua
omarchy-vm setup prepare-create REVIEW_UUID --preset developer --remove-layout
```

### Theme/layout presentation refinement — 3 November 2026

The initial native section is superseded by responsive theme/layout panels and
explicit theme-choice controls. Keep/GitHub/Random/Most starred still map to the
same strict source DTO and shared resolver; the GitHub choice requires a URL. The
native draft retains a repository while another choice is selected. Trim help is
now adjacent to its toggle; the frozen review keeps only a short inclusion status.
No shared package, network/transport implementation or execution admission changes.
The [UI evidence](DevVMUIAcceptance.md#themelayout-visual-refinement-and-adjacent-trim-help--3-november-2026)
records 92 isolated screen checks, current light/dark captures and limitations.

## Bundled dev-vm layout example cards — 3 November 2026

**IMPLEMENTED:** Desktop layout has an Examples choice in both native forms.
Four selectable cards show maintained wireframes, a description and prerequisite
apps: four Foot terminals in a 2×2 grid; terminal left 40%/Chromium right 60%; VS Code
left 60%/Chromium right 40%; and two terminals left/Claude right with an overlapping
browser. The gallery uses the full available width (four columns in the wide
fixture, two in New VM). Keep, Custom file and Remove remain available. Choosing
Examples without choosing a card cannot produce a preview; card edits invalidate
review and acknowledgment. These are illustrative intended arrangements, not live
guest captures. The Lua uses floating placement rules and can preserve manual size
changes; the raised browser in the wireframe denotes its overlapping position.

**DESIGN DECISION:** cards list the apps they expect and explain that they must be
installed. Selecting a layout does not silently add app/package installation
choices. Applications may already exist or be selected separately in the setup
configuration. The original Lua files are unchanged and include startup behavior
at the next guest desktop login. Selecting/reviewing a card does not execute Lua,
start apps, authorize a job or launch a VM.

**PRIVATE COUPLING:** a shared `LayoutExamples` API and bounded catalogue bind the
four IDs, titles, prerequisite apps, normalized preview windows and exact source
SHA-256 values to the maintained original files. Resource sync copies the original
four Lua files and catalogue into the admitted package; engine/resource admission
and catalogue-to-source hash checks precede use. A new optional strict
`ProvisioningAppearanceSelection.layoutExample` field carries only one of four
fixed identifiers, never an arbitrary path or URL. It is mutually exclusive with
custom-file/removal choices. CLI review accepts `--layout-example` with the same
identifier. Frozen input creation copies the exact bundled bytes through the
existing private layout path and shared planner; it retains the same source/input/
plan/consent/cleanup checks. The preview recognizes the example by its frozen input
hash and displays its title. A new choice gets a new review; old frozen inputs stay
unchanged. No separate layout executor or virtualization implementation is added.

**PRIVATE COUPLING:** `Patches/dev-vm-layout-examples.patch` exports the shared API,
resources and tests over the existing base/durable/trim/theme patches. Lock,
resource, source snapshot and compiled engine pins are updated together. Product
approval remains nil and provisioning execution disabled.

**TO PROVE:** physical card interaction/VoiceOver/native dialogs and actual guest
startup, prerequisite app availability, placement at current display sizes/scales,
manual resizing, reapplication and next-login behavior under explicit disposable
approval. Historical dev-vm guest captures do not prove this manager integration.
No host install, actual HTTP/gh/SSH/Ansible/Lua execution, factory operation or VM
launch is used in this slice's tests. The companion broad Ansible test target is
skipped under the user's fake/local constraint; the original layout resources are
compared byte-for-byte and resource-sync Python syntax is checked without execution.

**VERIFIED — fake/local:** full manager `make test` passes **468 Swift functions in
62 suites, 52 script tests**, relocated/read-only/ad-hoc-signed helper fixtures and
**100 offscreen checks with twenty PNGs**. Five new manager test functions (including
all four example choices and six strict-wire variants) cover exact frozen bytes,
no implicit package additions, stable old reviews, exclusivity, legacy compatibility
and CLI/socket identity. Shared `make test-provisioning` passes **86 functions**,
including the new catalogue/source/geometry and invalid-identifier fixtures. All
four original Lua files and the catalogue compare byte-for-byte to packaged copies;
Python resource-sync syntax parsing passes. No Lua interpreter or guest command is
run. Four current light/dark gallery captures were inspected and retained with
[evidence/report](media/setup-layout-cards/evidence.json).

Final pins: engine `818e5ba3267d14f0d08453118fb3b962d25afef2a90a9810dda043e07d9cb369`,
source snapshot `ccfc138e9d67b434c3a90e6e2577460889331cb2053d75612e9189d525b702e4`,
lock `c8f8d2e48b17584a6bdb57a7007986820736106c4153c2e396421e81f30d1472`.
Reverse integration-patch/export and both worktree diff checks pass. Changes remain
uncommitted. Actual guest placement and physical interaction remain TO PROVE.

Final `make build-signed` passes as release compilation only, without signing
credentials or notarization. Product execution stays disabled.

## Milestone 6 offline candidate preflight — 3 November 2026

**IMPLEMENTED:** `make provisioning-preflight` reads existing debug products and
emits a JSON evidence report. Alternate output directories and optional static app
inspection are available. It has no build/install/sign/run prerequisites and never
launches a candidate or probes a guest/tool. A read-only `verify_source` extraction
reuses the existing pinned-export/reverse-patch validation without regenerating
pins or launcher inputs. `prepare` continues to generate them through the same
verified source path. No shared-package or product execution policy changes.

**DESIGN DECISION:** offline evidence is separate from execution readiness. The
report records hashes, repository state and remaining approval/admission steps;
`executionAuthorized` is always false and real guest acceptance stays NOT_RUN.
Neither an offline PASS nor a hash establishes loaded-code identity, signing,
factory readiness or a binary's relationship to HEAD. Optional assembled-app
inspection checks provisioning resources/seal and runtime-lock equality, not a
complete kit/signature or release verification. Signed-byte differences are visible
without stripping signatures or inventing a build correspondence. This developer
script uses existing build tooling; there is no new shipped Python prerequisite.

**VERIFIED — offline/local:** ten checks pass against existing debug products.
Eight new preflight fixture functions and one read-only export regression pass;
the complete script suite passes **61 tests** and a fresh `make build` passes.
Fixture candidates are never
executed. Source export, generated pins and resource identities remain unchanged.
The preceding 468 Swift functions/62 suites, 100 offscreen checks and 86 shared
functions remain the recorded acceptance for unchanged Swift/package sources.
The [runbook](DevVMMilestone6Runbook.md#offline-candidate-preflight) describes the
command, limits and concrete prerequisites. No real HTTP/gh/SSH/Ansible, dependency
probe, signing credential, host install, factory/registry/VM operation or UI
takeover is used. Product approval remains nil.

**TO PROVE:** committed-source/candidate binding, explicitly approved new stopped
disposable root preparation and original identity pins, operational candidate
composition, authorized code/signature admission, live factory/dependency evidence
and every real guest/TTY/cleanup/restart/check/failure row. The next approval is
for concrete new disposable metadata preparation; it does not authorize boot or
real provisioning. This checkpoint includes the previously uncommitted admission,
native Source/profile/permission/trim/theme/layout work and related docs in both
worktrees. Earlier "uncommitted" notes describe their original slice handoffs.

## Milestone 6 private scoped candidate preparation — 3 November 2026

**IMPLEMENTED — private artifact only:** the explicitly approved new stopped
profile/root was prepared separately, then a candidate was built from commit
`1cb2bdd929ac147f15b4a682291418fa699372ba` with a recorded six-file private overlay.
Original UUID/root/device/inode/marker pins are constants in the Core linked into
both manager and helper. The main worktree's product gate remains nil. The private
composition fails closed on unavailable original pins, with no nil fallback and no
new approval file, environment, CLI or IPC loader. A private inspection command
runs before AppModel/registry/worker dispatch. All actual identifiers/pins, the
source archive/overlay, app, signatures, digests and reports remain ignored/private.
No manager/helper runtime implementation or shared package source was changed.

**VERIFIED — offline/local:** the isolated SwiftPM/make debug build succeeds using
cached dependencies with automatic resolution disabled. Existing pinned kit
archive/inventory hashes match; its original signatures survive packaging unchanged.
Manager/helper/CLI/storage/launcher and app use ad-hoc signing only, without signing
credentials. Strict/deep local signature and static layout/package/resource checks
pass. The retained app is byte-identical to the assembly and both relocated manager/
helper inspection reports match: identical original scope, wrong UUID/root and
wrong device/inode/marker refusal, unchanged production signing refusal. Thirteen
offline checks are recorded in its private manifest. A probe against the actual
candidate Core confirms scope before coordinator installation, despite a permissive
fixture coordinator and after its close; another UUID, the same UUID in a different
namespace and retained POC IDs all refuse with zero fake runtime starts. The ordinary
admission suite passes twelve functions. Real root/metadata and full registry hashes
are unchanged. No real guest, transport, installed-tool probe, host install, credential
operation, normal app entrypoint or worker body ran.

**DESIGN DECISION / TO PROVE:** this is an offline preparation candidate. Production
helper admission still requires a non-ad-hoc same-team app/helper and correctly
blocks this artifact; its fixture policy is not substituted. Operational loaded-
child admission remains unproven. The stopped profile has SSH/owner setup disabled;
configuring those, selecting an actual available factory, fresh Homebrew tool
readiness, exact frozen-input/privilege/task consent and real execution still need
their own scoped approval/evidence. No launch or real provisioning is authorized by
candidate preparation. Every guest acceptance row remains NOT_RUN; milestone 6 is
not complete. See the [runbook](DevVMMilestone6Runbook.md#private-scoped-candidate-preparation).

## Milestone 6 offline signing/readiness audit — 3 November 2026

**VERIFIED — static/local:** nineteen checks confirm retained artifacts and evidence,
deep/strict signature integrity, exact kit/package/resource inventories, original
scope and unchanged root/registry, private-overlay reconstruction and an independent
base archive match to its Git commit. No candidate process or installed provisioning
tool runs. Static Homebrew observations find both Ansible commands in the same
formula directory and distribution metadata for Core 2.21.5; no readiness status is
inferred from that data. The expected compressed factory's metadata exists in the
managed cache, but OS access refuses its bytes even outside the tool sandbox. Its
checksum is NOT_VERIFIED, not a factory acceptance pass. No permissions are granted
and no image/disk is created or transformed. Private reports, fingerprints and
source evidence remain outside Git. This audit changes no product/shared source.

**SOURCE FINDINGS:** the debug candidate remains ad-hoc, without same-team identity,
hardened runtime/timestamp or its protected-Keychain profile. The supported signing
path rebuilds with `SIGNED_PRERELEASE`, signed kit origin/lock, `RuntimePin` and
`SignedBuildPin`, approved profile/entitlements and a post-sign distribution seal.
The existing tag workflow uses ordinary checkout and publishes release and failure
archives; source inspection shows it cannot carry this ignored private overlay or
meet private artifact handling unchanged. A reviewed nonpublishing signing handoff
must retain the original constants and verify scope on the approved Mac. It must
not manufacture new pins on a remote signer. No workflow, signing credentials,
identity enumeration, Keychain, signing or notarization request is used here.

**TO PROVE / REMAINING:** same-team/loaded-child admission; signed rebuild/profile
composition; the private signing handoff; separately approved SSH/owner/frozen-input
configuration; fresh bounded actual CLI checks; all real guest rows; factory-byte
verification. Seven gates are recorded in the private audit. The next safe slice
is private-handoff design and fake/local checks, with actual credential/permission/
tool/guest operations still separately authorized. Ordinary product approval stays
nil and guest acceptance stays NOT_RUN. The
[runbook](DevVMMilestone6Runbook.md#offline-signing-and-readiness-audit) distinguishes
static passes, access refusal, source inference and live evidence still missing.

## Milestone 6 private handoff and packaging path — fake/local, 3 November 2026

**IMPLEMENTED:** a developer-only `prepare` CLI captures a reviewed candidate's
original scope/receipt/source archive/overlay, runtime and provisioning resources,
locks and profile pin into a new private handoff. It requires explicit private
candidate/scope digest bindings, validates strict JSON and original file identities,
and emits a frozen request plus digest. It never reads the root named in the scope,
recaptures identity pins, runs a child process or touches credentials. The actual
retained candidate produces a private 101-file handoff; its original input bytes
stay unchanged. The public product source remains nil/disabled and the existing
tag/publishing workflow is untouched. These build tools add no shipped Python.

**DESIGN DECISION:** the CLI offers no real signing command. A trusted fake-only
packaging runner exercises the entire sequence using synthetic runtime/profile/
app bytes and checked build/scope receipts: profile validation, signed-runtime
provenance, signed-prerelease rebuild, child signing, post-sign executable seal,
outer signing, verification, private ZIP, extraction and verification again. It
reuses existing runtime/payload, profile-entitlement and provisioning validators.
The real request cannot enter this runner. All fake artifacts are non-executable
simulation evidence, with `productionSigningVerified: false`; no simulated receipt
establishes real compilation, signing, loaded-child identity or guest authority.

**PRIVATE COUPLING:** request digests bind inputs independently of a mutable checksum
sidecar. Original constants must match both component build receipts and synthetic
code bodies. Inputs are re-admitted across callbacks; immutable runtime/resource/
profile/pin checks, post-sign seals and read-only verification preserve that binding
through archive roundtrip. New owned/private destinations, source-overlap and
case-insensitive VM/release namespace guards, tag/release refusal and no publishing
interface keep outputs out of ordinary release paths. Changed/failed requests,
unsafe links/archives and disk payloads fail closed. Partial outputs remain private,
diagnostics omit backend errors and existing outputs are never overwritten/replayed.

**VERIFIED — fake/local:** eighteen new unit functions, including 22 signer/build/
profile/runtime/scope/entitlement tamper cases, and all **79 script tests** pass.
Process/network/credential hooks are prohibited in the fixture runner and record
zero calls in the retained synthetic demonstration. The actual candidate's frozen
request is independently loaded and refused by the fake runner before a callback.
Original candidate/evidence/root/registry remain unchanged; private identities and
artifacts stay ignored. Source changes are limited to developer scripts, Make
targets, tests and docs; shared/package/runtime/signature policies are unchanged.

**TO PROVE:** an authorized real-signer adapter and actual private signed-prerelease
build/sign verification, notarization, loaded-child admission and final original-
Mac scope observation. Real credential/signing and guest operations remain separate
authorizations. Factory bytes still lack access, installed tools remain unprobed,
SSH/owner/frozen setup configuration is pending and all real rows remain NOT_RUN.
See the [runbook](DevVMMilestone6Runbook.md#private-signing-and-packaging-handoff--fakelocal-path)
for command inputs, privacy guards and current limitations.

## Milestone 6 private signer adapter — fake processes, 4 November 2026

**IMPLEMENTED:** a developer-only adapter consumes the frozen private handoff and
explicit local signing material. It reconstructs the recorded archive/overlay,
retains the original scope-definition/operational composition, projects signed
runtime/team/origin pins and the signed inspection branch, prepares pinned local
dependencies, and calls the existing signed-prerelease build. It assembles fresh
private components, signs children, seals their final hashes, signs the app, checks
signature/profile/bundle contracts and verifies the private archive after extraction.
Runtime signing remains upstream; a local signed kit with the exact original
development-kit origin is required. No runtime fetch, virtualization fork or shipped
Python runtime is added. Source and dependency drift fail closed.

**DESIGN DECISION:** no signing CLI, workflow/publisher, credential importer,
keychain unlock/search change or notary submission. The system runner denies by
default before material IO and requires separate trusted in-memory authorization
for exact request/scope/material bindings and build/inspect/sign-with-timestamp
effects. File/environment contents confer no signing or guest consent. The source
inspector projection can check same-team signatures in signed builds, while final
scope/loaded-child validation remains on the original Mac. Main approval stays nil;
real candidate/pins remain private and unchanged.

**VERIFIED — fake processes/local:** twelve new tests, 33 command/sign/verification
failure variants and four runtime origin/payload variants; all **91 script tests**
pass. Fake SDK output exercises Developer ID chain parsing, team/hardened-runtime/
timestamp requirements, profile/certificate/entitlement checks, post-sign seals and
exact roundtrip. Mocked system dispatch checks explicit environment and timeout
group cleanup without spawning a process. Private outputs clearly record test
doubles and no production cryptography, loaded child, original-Mac validation or
guest execution. No actual signing, credentials, Apple request, installed tool,
transport, VM launch, disk operation or UI takeover occurs.

**TO PROVE:** actual local signed-runtime availability and authorized SDK/build/
signing behavior, SwiftPM offline reconstruction, cryptographic/profile admission,
notarization, final original-Mac scope and loaded-child checks. Prior factory/tool/
SSH/owner gates and all real guest rows remain pending. This implements the adapter
only; the [runbook](DevVMMilestone6Runbook.md#private-signer-adapter--fake-process-runners-4-november-2026)
records the exact authorization boundary before any real operation.

## Milestone 6 real signed-candidate gate preparation — 4 November 2026

**PREPARED / DESIGN DECISION:** an ignored private review packet binds the actual
candidate/request/original scope, archived source/overlay and committed adapter.
It records exact runtime-origin/inventory/profile requirements, clean pinned local
source observations, unresolved real material selectors and distinct NOT_GRANTED
approvals. It is neither executable authorization nor a product approval loader.
Actual pins and canonical paths stay private; no credential bytes are collected.

**VERIFIED — read-only local:** retained candidate inventory/reviewed digest and
frozen request independently re-admit; canonical patched-client/parser checkouts
are clean and match the archived revisions. Local Git alone observes them, without
fetch, hooks/fsmonitor or optional index updates. No original VM root/registry is
visited, no pins recaptured and no SDK, signing, credential, Apple/network,
transport, install, UI, disk or guest operation occurs. The existing 91-test signer
evidence remains applicable; adapter/product/shared source is unchanged.

**BLOCKED ON SELECTION / TO PROVE:** no accepted real signed runtime is selected;
team, Developer ID identity, isolated keychain and exact pinned profile path remain
unselected/uninspected. The required runtime is the signed variant of the frozen
development kit, with the same origin/capabilities/payload and the selected app's
team. The ad-hoc candidate and synthetic fixtures cannot satisfy this gate. If a
runtime must be produced, review a separate upstream signing-only route and its
isolated-keychain handling; the ordinary release wrapper combines credential
imports, notarization and publication, and is unsuitable here.

The [gate runbook](DevVMMilestone6Runbook.md#real-signed-candidate-gate-preparation--4-november-2026)
identifies exact material relationships and approval stages: named material
inspection/preparation, optional upstream runtime production, private app build/
key use/secure timestamps, original-Mac scope and non-activating loaded-child
validation, optional notarization and later real guest acceptance. No approval is
requested or granted by preparing the record. A trusted one-shot caller and real
material binding must be reviewed after selection; there is no signing CLI. All
real compiler/signature/profile/notary/guest outcomes remain TO PROVE/NOT_RUN.

## Milestone 6 matching local signed runtime found — 4 November 2026

**VERIFIED — local artifact data:** the primary checkout retains a published
`v0.9.4-dev.1` runtime whose source-lock/kit/patch and payload match this candidate's
frozen origin. ZIP digest/inventory and three extracted bundle copies match its
signed lock. Newer local candidate directories have a different origin and are
ineligible. Exact bundle/ZIP/lock copies are privately staged in the adapter's
required layout, with validation repeated and originals unchanged. Paths, hashes,
identity/team selectors and rejection details stay in an ignored discovery addendum.

**PRIVATE COUPLING / LIMIT:** the identity comes from the existing helper's public
CMS certificate, parsed locally without a Keychain/signing/trust operation. It does
not establish private-key availability or fresh signature admission. Profile paths
are located/stat-ed only, without opening their bytes; a matching public source
pin does not validate those files. The isolated-keychain selector remains absent.
Prior gate/request/scope and every approval remain unchanged/NOT_GRANTED.

**NEXT / TO PROVE:** select the isolated keychain privately and separately approve
bounded named runtime/profile validation plus private profile staging. If admitted,
the existing runtime avoids a new upstream runtime-signing job. App signing/key
use/timestamps and later gates remain separate approvals. No credential access,
signing/SDK execution, Apple/network, SSH/Ansible, install, UI, image or VM operation
occurs; product approval stays nil. See the
[discovery record](DevVMMilestone6Runbook.md#local-signed-runtime-discovery--4-november-2026).

## Main integration and offline acceptance — 4 November 2026

Latest main `741be20` is confirmed by credential-free public HTTPS and merged into
the provisioning branch. Seven content conflicts are resolved by retaining both
histories and combining Setup with guest Touch ID across profile persistence, CLI
options, native save and packaging. Loading/cancellation behavior is preserved;
isolated fake models bypass the loading screen. Provisioning's creation review,
helper staging/seals and disabled product execution remain intact.

**VERIFIED — offline/fake:** debug build; 300 selected Swift tests, including a new
combined Touch ID/Setup creation and Codable regression; 109 Python passes with
five software-signing/PKCS12 cases explicitly skipped; 100 offscreen UI checks
with zero runtime starts or visible windows. Eleven local socket test functions
initially fail under the tool sandbox and pass on scoped retry outside it. Python
process auditing records no forbidden tool invocation. Native SSH, signed-bundle
fixtures and real signing/credential checks are not run. This is selected offline
coverage, not every CI/native test or real guest acceptance.
Release and `SIGNED_PRERELEASE` policy checks pass two tests per mode, confirming
compiled launch/credential gating without signing. SDK dSYM generation initially
hits the tool sandbox and succeeds on scoped retry outside it.

**PRIVATE COUPLING / TO PROVE:** the 930 private artifact entries are unchanged in
bytes, mode and link targets; actual scope pins stay ignored. Ordinary source pins
adopt main, while the retained candidate/gate/runtime still belong to their original
pre-merge source. A new integrated candidate requires separate source/runtime
freezing and review; no previous request is rewritten or silently promoted. The
companion worktree is unchanged. No credentials, signing, Apple request, real
SSH/Ansible, install, normal UI, image or VM operation occurs. See the
[integration boundary](DevVMMilestone6Runbook.md#after-merging-main--4-november-2026).

## Integrated source inputs and signing gate — 4 November 2026

**PREPARED:** exact `7e46241` source archive, reviewed six-file private overlay,
current package/runtime/profile pins, original scope/receipt lineage and a matching
existing signed runtime are frozen into a new ignored private input packet. The
retained dev.3 artifact reuses the exact runtime declared dev.2; its source origin,
capabilities, immutable payload and ZIP/extracted inventories match. No signature
bytes are changed and no app is built or signed. Ordinary product approval stays nil.

**DESIGN DECISION / PRIVATE COUPLING:** preserve original scope JSON, including its
historical `sourceCommit`, all identity/hash pins and complete scope-definition
source verbatim. Bind `7e46241` independently. The prior app-based handoff cannot
express that separation without changing a frozen pin, so this is an explicitly
distinct source-only record, refused by the existing signer. No fake app receipt,
legacy request or executable authorization is created. A reviewed source-only
admission/caller update remains necessary; no loader/policy change is included here.

**VERIFIED — offline/fake:** 22 actual-packet integrity/refusal checks and all 12
fake signer process-runner tests pass. Reapplying the overlay to a second fresh
archive reproduces the scoped source inventory. The original private artifacts,
scope pins and requests remain unchanged; the gate keeps every approval ungranted.
No profile bytes, credentials, signing, Apple/network, SSH/Ansible, installs, image,
UI or guest operation occurs. Actual app compilation, material selection/admission,
cryptographic/loaded-child and real guest evidence remain TO PROVE/NOT_RUN. See the
[input gate](DevVMMilestone6Runbook.md#integrated-candidate-inputs-for-7e46241--4-november-2026).

## Source-only admission and trusted caller — 4 November 2026

**IMPLEMENTED:** an explicit version-2 admission API consumes the frozen source-only
packet without changing its version-1 data format, historical scope/source commit,
pins or gate. A typed trusted review independently binds source commit/archive/
overlay, original scope bytes/semantic digest/definition, lineage, packet digest,
team and fixture mode. Normalized request digests are separated from legacy and
packet digests. The old app-based signer path remains explicit and unchanged.

Strict immutable inventories, safe archives, exact config/package/resources,
reviewed source reconstruction and runtime-origin/payload/ZIP checks precede use.
The adapter readmits across callbacks, requires the reviewed runtime selector and
preserves existing signed-pipeline policies. The one-shot caller requires typed
review/material objects, defaults to denial before credential IO/output, and
consumes use before admission under a lock. Gate files, sidecars and environments
cannot create signing authority; no CLI, publication or credential importer is added.

**VERIFIED — fake/local:** eighteen new tests include full fake adapter/ZIP
roundtrip, scope preservation, version/authority/runtime tampering, callback/source
mutation and concurrent one-shot refusal. The allowed full Python run has 127 passes
and five signing/PKCS12 skips (132 discovered), with no forbidden process attempt.
The actual `7e46241` packet admits as file data only, under prohibited process/
network hooks. All 1,161 existing private artifact entries remain unchanged; exact
identities and new evidence stay private. Production/shared code and pins are
unchanged and provisioning approval stays nil.

**TO PROVE:** selected profile/keychain validation and separately authorized real
compiler/SDK/signing/loaded-child/original-Mac evidence. No actual signing,
credentials/profile bytes, Apple request, SSH/Ansible, install, UI, image or VM
operation occurs. Guest acceptance stays NOT_RUN. See the
[versioned caller](DevVMMilestone6Runbook.md#version-2-source-only-admission-and-caller--4-november-2026).

## Named material inspection and staging — 4 November 2026

**IMPLEMENTED — developer tooling:** a typed, one-shot material-inspection caller
binds the admitted source request, named selectors, independent public-certificate
and runtime-inspector hashes, and private output in its own authorization domain.
Default execution refuses before material IO/output; native authorization must
grant only inspection. Fake source reviews cannot run native inspectors. No CLI,
credential discovery/import/unlock, automatic signing or publication is added.

After separately authorized inspection, exact profile/public-certificate bytes are
staged privately. Profile team/App ID/distribution/expiry, authorized public leaf,
certificate common name/dates, local dependency revisions/cleanliness and frozen
runtime inspection are checked. Source/runtime/staged-file hashes and named
keychain metadata are rechecked across callbacks. Keychain contents are never
read; key availability/unlocked state remain explicitly unknown. Public-certificate
parsing does not prove trust. Returned material names the staged profile and
requires a distinct later signing approval; no receipt grants execution authority.

**VERIFIED — fake/local:** 19 new tests pass; the allowed full Python suite has
146 passes and five deliberately skipped signing/PKCS12 tests (151 discovered).
Auditing observes only local Git/Python processes, with no forbidden-tool attempt.
All 1,161 retained private entries and frozen pins stay unchanged. Shared/product
source and pins are unchanged; ordinary provisioning approval stays nil.

**TO PROVE:** actual named material selection and separately approved inspection,
private-key availability, real compilation/signatures/profile trust/loaded-child,
original-Mac and guest evidence. No actual profile/certificate parser, SDK/CMS,
keychain, signing, Apple request, SSH/Ansible, install, UI, image or VM operation
occurs. See the [inspection gate](DevVMMilestone6Runbook.md#named-material-inspection-and-private-staging--4-november-2026).

## Bounded native inspection — source preparation, 4 November 2026

**VERIFIED — source only:** upstream `verify --signature-only` still runs the
bundled daemon's exact `check` branch. That branch locates its own payloads, checks
helper access, hashes the server/supervisor and validates the client's pinned
CDHash before returning. Listener creation, privileged session setup, subprocess
launch and network changes are in the other branch. The client's XPC `check`
is a different operation. Native signature validation uses default flags; source
absence of socket calls does not prove system-wide network silence.

**DESIGN DECISION — proposed:** prepare a distinct offline inspection adapter with
explicit `kSecCSNoNetworkAccess`, CMS content decoding without signer trust
evaluation, locked keychain status only, and static runtime signature/metadata
validation. Keep the daemon unexecuted and all frozen runtime bytes unchanged.
Bind source/scope/selection/inventories, implementation and private output in a
new request domain. Require a 300-second job deadline, 120-second stage cap, live
2 MiB stream caps, bounded inputs and process-group kill/reap on refusal. Current
runner output checks happen after capture, so they are not a live disk bound.

**TO PROVE / NOT RUN:** implementation/fake API and runner checks, followed by
separately approved native inspection. Existing caller/request must not be silently
promoted to this stricter contract. No native verifier/daemon, profile/signature/trust API,
build, signing, Apple request, SSH/Ansible, install or VM execution occurs in this
review. Private source evidence/contract stay outside Git; source-only review is
not signed-binary, revocation, notarization, key-possession or guest proof. See the
[bounded inspection preparation](DevVMMilestone6Runbook.md#bounded-native-inspection-preparation--source-review-4-november-2026).

## Offline inspection adapter — fake boundaries, 4 November 2026

**IMPLEMENTED — developer tooling:** a separate typed one-shot offline review/
authorization domain binds source/scope/selection, certificate, implementation,
entitlement sources and output. Default denial precedes IO; fixtures and fake API/
factory classifications cannot become native proof. The API worker guards CMS
envelopes before decoding, keeps the keychain locked and releases references,
and statically validates every Mach-O/bundle with explicit no-network flags and
exact Developer ID/team/runtime/timestamp/entitlement requirements. There is no
daemon or runtime execution, signing or network fallback.

The injected process supervisor enforces a shared 300-second budget, 120-second
worker limit, live 2 MiB stream caps, group kill/reap/close and refusal when
descendants or cleanup uncertainty remain. Callback/input/implementation mutations,
bad responses and concurrent/replayed use refuse. Staged files/receipts remain
private; no receipt supplies signing/guest authority. Native OS bindings and the
real factory/activation path are absent, with their contracts explicitly documented.

**VERIFIED — fake/local:** 32 new tests pass. The full allowed Python suite has
178 passes/five deliberate signing/PKCS12 skips (183 discovered), observing only
local Git/Python processes and no forbidden-tool attempt. Private artifacts,
frozen pins and shared/product code are unchanged; ordinary approval stays nil.

**TO PROVE:** concrete API/launch bindings with fake FFI/process tests, then
separately approved native inspection and real OS behavior. Filesystem IO is
budget-checked at callbacks; virtual process tests do not prove native scheduling
or cleanup. No actual materials/keychain/native inspection, signing, Apple
requests, SSH/Ansible, installs, UI, image or VM operation occurs. See the
[adapter contract](DevVMMilestone6Runbook.md#offline-inspection-adapter--fake-apisworkers-4-november-2026).

## Concrete offline bindings and launcher — 4 November 2026

**IMPLEMENTED — not activated:** lazy closed-symbol Security/CoreFoundation
bindings provide content-only CMS, public certificate parsing, locked keychain
status and explicit no-network static validation. Type/size/string/flags checks,
certified timestamp selection, validity-before-metadata and owned/error reference
release are enforced. An explicit factory binds trusted authorization and current
implementation, launches an isolated Python worker through anonymous bounded
capability/task pipes, verifies parent/task/code/mode and supplies nonblocking IO
to the existing deadline/output supervisor. No default caller activation is added.

The root remains unreaped until its group is quiescent; a Darwin waitid ABI binding
supports system Python without `os.waitid`. Bounded group queries fail closed on
missing root ownership; no signal follows PID release. Failed startup/cleanup
retains unresolved handles and blocks more launches. Fixed filter-free Git
metadata/raw worktree checks replace potentially executable clean-filter checks.
All new modules join the implementation digest; frozen runtime/pins stay exact.

**VERIFIED — fake FFI/process only:** 33 new tests include a full synthetic adapter
roundtrip through the concrete wrappers/launcher. The allowed Python suite has
211 passes/five signing skips (216 discovered), only local Git/Python programs,
and no forbidden-tool or inspection-library attempt. No actual native worker,
API, signing material or keychain is inspected; all 1,161 private entries and
historical reviews stay unchanged. Shared package/product code remains unchanged.

**TO PROVE:** fresh final-implementation review and separate native approval,
then real ABI/API value shapes, wait/group semantics, scheduling/cleanup/crash and
inspection results. No real inspection, signing, Apple requests, SSH/Ansible,
installs, UI, image or VM operation occurs. See the
[binding boundary](DevVMMilestone6Runbook.md#macos-bindings-and-bounded-launcher--fake-ffiprocesses-4-november-2026).

## Fresh private inspection review — ddf5451, 4 November 2026

**PREPARED / NOT EXECUTED:** a separate ignored 0700/0600 packet binds committed
`ddf5451`, its 14-file implementation digest, existing source/scope/selection and
runtime, public leaf/entitlement hashes and an uncreated private output path.
Historical records and pins are unchanged. Typed review data is not authority:
all approvals remain false and no authorization, caller, worker/factory or native
API is constructed.

Stored fake evidence, source admission, dependency HEADs and entitlement files
match; external signing materials/keychain and whole dependency cleanliness are
not rechecked. Prior material/lock observations remain historical. All 1,161 old
entries stay in place; a credential-named retained artifact is left unopened with
stored digest/metadata evidence, not a fresh content check. Exact values stay
private. No test rerun, native inspection, signing, Apple request, SSH/Ansible,
install, UI, VM-root observation or VM operation occurs. Separate exact-scope
native approval and execution-time revalidation are next; product approval stays
nil. See the [fresh review](DevVMMilestone6Runbook.md#fresh-private-inspection-review-for-ddf5451--4-november-2026).

## Approved inspection attempt — pre-native stop, 5 November 2026

The user approved the exact `ddf5451` read-only review. The private one-off
composition's extra audit guard incorrectly refused Python's `/dev/null`
`O_RDWR` open for disabled Git stdin. It stopped before any subprocess, worker,
native authorization/caller or native API was constructed. There is no actual
profile, keychain or runtime validation result, and no inspection output exists.

Review checksums and original noncredential artifact bytes/modes/links match;
all 1,161 old entries remain present. The retained credential-named artifact stays
unopened, without a fresh content claim. Frozen pins and ordinary approval are
unchanged. Ten fake audit-event cases cover the proposed narrow guard correction,
which remains unused. The request is consumed without retry; a corrected fresh
review and separate approval are next. No signing, private-key access, Apple
request, SSH/Ansible, install, UI or VM operation occurs. See the
[attempt record](DevVMMilestone6Runbook.md#approved-inspection-attempt-stopped-before-native-work--5-november-2026).

## Corrected fresh inspection review — 5 November 2026

A new ignored private packet binds a distinct request/output, the unchanged
`ddf5451` implementation and frozen source/scope/selection/runtime, plus exact
corrected guard source and review-file hashes. The only guard exception is a
literal `/dev/null` `O_RDWR` open with optional `O_CLOEXEC`. Twenty-two fake
audit/helper cases pass; no real guard, authority, caller, worker or native API
is activated. Source admission, 14 committed files, dependency HEADs and
entitlements match stored pins. Whole dependency cleanliness remains deferred.

All 1,170 preexisting artifact entries, the original review, failed attempt and
consumed marker are preserved. Retained credential-named content remains unopened;
stable metadata is not fresh content validation. External material/keychain
observations remain historical. Both outputs are absent and all new approvals
are false. Separate exact-review approval is next; no inspection, signing,
private-key access, Apple requests, SSH/Ansible, installs, UI or VM operation
occurs. Product approval remains nil. See the
[corrected review](DevVMMilestone6Runbook.md#corrected-fresh-private-inspection-review--5-november-2026).

## Corrected native inspection — partial result, 5 November 2026

The explicitly approved corrected caller runs once against unchanged `ddf5451`
code/review/guard bindings. Both dependency checks, native locked-state check and
profile content/policy/public-leaf membership pass. The fifth worker exits at
public-certificate parsing with a fixed generic error after about 12 seconds;
its native cause is unknown. Runtime signatures and final checks are not reached.
No success receipt or trusted certificate/signing result is accepted.

The runner's cleanup flag remains false, with zero factory-held unresolved
handles. An authorized bounded exact-parent/worker snapshot finds no survivors;
that observation does not rewrite the failed cleanup receipt or prove every past
descendant. The sandbox initially blocks only this cleanup snapshot; it completes
outside the sandbox without retrying inspection. All 1,182 old artifact entries
and frozen pins are preserved; credential-named content stays unopened. New
staged profile/public certificate and failure evidence remain private in the
planned output. Ordinary approval remains nil.

Five fake diagnostic cases reproduce possible certificate type and cleanup-error
shapes without establishing the actual native cause. Next, combine fixed worker
diagnostics, per-handle cleanup evidence and typed certificate dates into one
fake-only implementation/validation/fresh-review chunk. Another native attempt
requires separate approval. No signing, private-key access, Apple request,
SSH/Ansible, install, UI or VM operation occurs. See the
[result and limitations](DevVMMilestone6Runbook.md#corrected-native-inspection-result--5-november-2026).

## Diagnostics, cleanup evidence and typed dates — 5 November 2026

Implemented together: mode-proven closed failure code/phase envelopes; private
per-worker exit and categorized cleanup evidence; held-root/reap/quiet/descriptor
snapshots including failed handoffs; no redundant signal after observed group
quietness; and macOS 15 retained typed certificate date getters with strict
validation/releases. Intermediate cleanup failures stay false; live/unproven
groups retain kill/reap behavior. No generic certificate-values fallback is allowed.

Twelve new fake FFI/process tests and the full 223-pass/five-skip allowed Python
suite pass (228 discovered), with only Git/Python and no native-library attempt.
A fresh private review binds all 14 implementation files, a 17-file source/test
snapshot plus patch, corrected guard and new request/output. Code is explicitly
uncommitted; no new native execution authority is created. All 1,191 old artifact
entries, pins and failed receipts remain unchanged; credential contents stay
unopened and external material/lock observations stay historical. The fresh output
is absent. Prior native failure causes remain unknown. Separate exact-review
approval is next; no real inspection, signing, private-key access, Apple request,
SSH/Ansible, install, UI or VM operation occurs. See the
[hardening and fresh review](DevVMMilestone6Runbook.md#diagnostic-and-date-hardening--fake-validation-and-fresh-review-5-november-2026).

## Native offline inspection passed — 5 November 2026

After manager `df8b75e` / companion docs `a8a8ba4`, the user-approved fresh run
verifies all 17 source/test snapshot files against committed/current bytes and
preserves the original review unchanged. The attempt completes in 64.18 seconds:
dependency checks before/after, locked keychain before/after, guarded profile/
public-leaf policy, certificate name/dates and all 23 static runtime checks pass.
The receipt is OFFLINE_STATIC_INSPECTION_ONLY, with explicit no-network policy and
no runtime code execution or signing.

All 31 worker roots are reaped after observed group quietness, descriptors closed,
no diagnostics/cleanup errors or unresolved handles. A bounded snapshot of only
the recorded worker PIDs finds none remaining. All 1,204 old artifact entries,
pins, prior reviews and failure records remain unchanged; retained credential
content stays unopened with stable metadata. Product approval stays nil. Key
availability, CMS signer authenticity, standalone certificate trust, online
revocation/notarization, daemon behavior, candidate signing/loaded-child and guest
acceptance remain outside this result. Earlier failure causes remain unknown.
No prohibited operation occurs. Milestone 6 remains incomplete; signing and guest
actions need separate approval. See the
[observed result](DevVMMilestone6Runbook.md#native-offline-inspection-passed--5-november-2026).

## Signed-candidate review — 5 November 2026

Following result-doc commits `740fd81` / `7d8d907`, a private review binds the
passed offline receipt/audit, matching staged material/public files, frozen
source/scope/runtime, committed tooling and unused private app/ZIP output. Its
domain digest is review-only, distinct from source/inspection authority. All
approvals remain NOT_GRANTED; no build, signer or output is activated.

The review is explicitly not executable: current signing authority lacks receipt/
implementation/output binding; the signer needs live caps/shared budget/owned
cleanup evidence; and its legacy profile/verifier dispatch must be replaced or
separately reviewed. The locked selected keychain's key availability remains
unqueried. Actual key use/necessary secure UI and Apple secure-timestamp requests
require explicit approval; Touch ID is preferred only where already supported.
Notarization, original-Mac/loaded-child and guest acceptance remain separate.

All 1,239 old artifact entries and pins are preserved. External signing materials
and keychain are not reopened or stat-checked, retained credential content stays
unopened, and prior observations remain historical. Pure admission, receipt/
staged bindings and source hashes match; no native inspection or tests are rerun.
Next consolidate receipt-bound admission, bounded supervision, replacement of
legacy inspection, fake validation and fresh review. No signing, private-key
access, Apple request, SSH/Ansible, install, UI or VM operation occurs. See the
[signed-candidate review](DevVMMilestone6Runbook.md#signed-candidate-review-after-offline-inspection--5-november-2026).

## Receipt-bound candidate path — 5 November 2026

Implemented the three review gaps together: typed one-shot receipt/current-code/
material/output admission; shared-budget live-capped command/native supervision
with held-group cleanup evidence; and no-network worker verification replacing
legacy profile/daemon/app dispatch. Older real signer entry points are disabled.
Candidate signatures require exact IDs/team/entitlements, hardened runtime and
timestamps, CDHash and the exact public leaf. Existing source/scope/runtime,
child-sign/seal/outer-sign and roundtrip contracts remain enforced.

Twenty new fake tests cover complete concrete-supervisor/FFI/capability-worker
composition and refusals/cleanup; full allowed Python suite: 243 pass/five signing
skips (248 discovered), only Git/Python, no native-library attempt. A fresh private
review binds sixteen code files and a 24-file source/test/Makefile snapshot/patch.
Code is uncommitted; historical offline implementation and current signing
implementation are bound independently. All 1,251 original artifact entries,
pins and old receipts/reviews remain unchanged, with interim drafts retained.
Credential contents stay unopened and external material/lock state is not refreshed.

Output is absent; no real authority or signer is activated. Build/inspect,
selected-key use, necessary secure key UI and Apple timestamp effects all remain
NOT_GRANTED. Operator keychain preparation/relock may be needed; no automatic
unlock/ACL changes are added. Parent IO is budget-checked at callbacks. Real native/
signing behavior, original-Mac/loaded-child, notarization and guest acceptance
remain TO PROVE. No prohibited operation occurs. See the
[implemented path and fresh review](DevVMMilestone6Runbook.md#receipt-bound-signing-path--fake-tests-and-fresh-review-5-november-2026).

## Reviewed candidate attempt — preparation stop, 5 November 2026

The user approves the committed `27c672f` receipt-bound run, selected-key/secure-UI
and Apple timestamps, excluding notarization, SSH/Ansible, installs and VM launch.
Exact snapshot/code/receipt/input bindings pass. The attempt completes overlay and
pinned local dependency preparation but stops at the frozen provisioning-source
helper with exit 1 after 125.283 seconds. Its exact cause is unknown: stream counts
(0 stdout / 278 stderr bytes) are retained, not raw error text. Read-only source
hash/mode/patch/syntax checks pass without replaying preparation.

Nine supervised command roots and three validation workers are reaped after group
quietness with descriptors closed, no unresolved handles and no recorded-PID
survivors in a bounded snapshot. All 1,279 old artifact entries and pins remain
unchanged; credential content stays unopened. No compiler, app/archive assembly,
runtime-validation phase, signing/key use/UI or timestamp stage is reached. No
notarization or prohibited guest/install action occurs; product approval stays nil.

The consumed request is not retried. Next combine a fake/local-fixture regression
for the actual frozen preparation path, fixed bounded command-failure diagnosis
and a fresh review. Real signing/OS/key/candidate and later acceptance remain
unproven; prior approval is not promoted to a different request. See the
[attempt and limitations](DevVMMilestone6Runbook.md#first-reviewed-candidate-attempt--preparation-stop-5-november-2026).

## Frozen-helper regression and fresh review — 5 November 2026

Prior failed-run docs are committed (`d3d70ab`, companion `09b396b`). A byte-exact
frozen-helper fixture now covers actual preparation with the unchanged public
package inputs. Local Python/Git reproduces a patch-base mismatch beneath an
ignored nested Git checkout; an exact private-output `GIT_CEILING_DIRECTORIES`
boundary fixes that case without changing pins or dependency repositories. This
does not establish the historical failure's cause because its stderr was discarded.

Failed quiet roots drain bounded pipes through EOF before recording fixed command
codes. No raw traceback/path/error text or raw-output hash is persisted. Partial
or capped output remains incomplete; deadlines, group ownership and cleanup
retention remain enforced. Thirteen new cases pass; the audited full Python suite
has 256 passes and five signing/PKCS12 skips, Git/Python processes only and no
native-library attempts. No Swift/shared provisioning code changes.

A new unexecuted private review binds seventeen implementation files and a 28-file
exact uncommitted snapshot against `d3d70ab`, the independent historical inspection
receipt and unchanged frozen pins. All five execution effects remain NOT_GRANTED;
new output is absent. All 3,987 earlier artifact entries/failed outputs are retained,
credential content is unopened and external keychain state is unqueried. No real
inspection, build, signing, key access, Apple request, SSH/Ansible, install, UI or
VM operation occurs. Commit before separately reviewing a fresh candidate attempt;
real signing/candidate and guest acceptance remain TO PROVE. See the
[fixtures, diagnostics and review](DevVMMilestone6Runbook.md#frozen-helper-and-safe-failure-diagnostics--5-november-2026).

## Fresh reviewed candidate — resource assembly stop, 5 November 2026

The explicitly approved `31f0bd7` / companion `3a7285b` attempt passes the exact
frozen-helper preparation, all 23 runtime static checks, public certificate and
dependency validation, release compilation and binary/scope-marker checks.
Twelve commands and thirty validation workers succeed. At 447.472 seconds,
assembly refuses `input-inventory-changed`: the compiled provisioning bundle's
payload matches the frozen reference, whose four `_CodeSignature` records are
absent from fresh build output. The core resource copy matches. This parent
inventory refusal has no failed-command stderr; retained files establish the
specific mismatch without rerunning anything or changing pins.

All 42 recorded roots/workers have confirmed group/reap/descriptor cleanup and
are absent in a bounded PID snapshot. All 4,002 prior private artifact entries and
pins remain unchanged; credential content is unopened, external keychain admission
is metadata-only and lock state unqueried. Partial assembly/build output is kept.
No signing/key/UI/timestamp stage, success receipt or signed archive is reached.
No notarization, SSH/Ansible, install, app/runtime or VM operation occurs.

The request is consumed. Next consolidate exact fixtures for compiled payload vs
inherited resource signatures, narrow assembly admission/final seal validation
and a fresh review; never relax generic inventories or modify frozen inputs.
Real signing/candidate and guest acceptance remain TO PROVE. Concurrent unrelated
CLI edits are left intact. See the
[result and retained-file diagnosis](DevVMMilestone6Runbook.md#fresh-candidate-attempt--compiled-resource-assembly-stop-5-november-2026).

## Resource payload/signature admission — 5 November 2026

After committing result docs (`12247e2`, companion `ff2c82d`), assembly admits the
exact frozen wrapper/resource payload independently of its complete known inherited
signature block. Only those four reference records can be excluded; fresh build
output must contain the exact remaining payload, with no inherited signatures.
Reference resource bytes also match the package lock. Partial/unknown blocks,
changed/extra/missing payload or wrapper files and unsafe types refuse. Generic
inventory checks and frozen pins are unchanged. Exact admitted payload is rechecked
before outer signing and during staged/roundtrip verification; child digest seal,
outer seal/static validation and archive equality remain required.

Fourteen new fake/local cases and full audited Python suite pass: 291 passes,
five signing/PKCS12 skips (296 discovered), Git/Python only, no native-library
attempts. Signed-reference/unsigned-build fixtures cover the actual boundary;
retained public bytes compare as 45 exact payload files plus four old signature
records without copying output or rerunning a build.

Fresh private review binds seventeen engine files, separate operator code and a
32-file exact uncommitted snapshot against `12247e2`. Maintained operator
prepare/check emits a new public-input-only plan; candidate output and consumed
marker are absent, all execution approvals ungranted and old authority untransferred.
All 8,691 old artifact entries/pins and failed attempts remain intact. No original
signing material/keychain or VM root is inspected, stat-checked or changed here.
No real inspection, signing, key access, Apple request, SSH/Ansible, install, UI,
app/runtime or VM execution occurs. Commit before a separately approved fresh run;
real resource-seal/signing/candidate/guest evidence remains TO PROVE. See the
[policy, fixtures and fresh review](DevVMMilestone6Runbook.md#resource-payload-admission--fake-fixtures-and-fresh-review-5-november-2026).

## Maintained operator attempt — selected signing timeout, 5 November 2026

**LATEST USER CLARIFICATION:** the operator says “I missed the prompt.” This
supports a missed secure-UI response as the explanation for the signing timeout;
it does not independently prove key use or timestamp success/failure. Keep the
earlier completed-dialog report and automated evidence as historical records;
exact dialog type/timing is not reconstructed. The plan remains consumed.

**USER-REPORTED FOLLOW-UP:** the operator reports completing a macOS secure-key/
keychain dialog. UI presence/response is now reported by the operator, while the
exact dialog type/timing, selected-key use and timestamp outcome remain unproven.
The consumed request is not retried; no new inspection/key operation is authorized.

The user approves the fresh plan after `b3171b0` / companion `9d3b4b6`, including
selected key, secure UI and Apple timestamps. All 32 snapshot files and engine/
operator/plan bindings match; the maintained CLI obtains exact-plan confirmation
through a real terminal and durably consumes the plan before backend construction.
Frozen preparation, 23 runtime static checks, public certificate/dependency
validation, release build and binary/scope checks pass. Resource assembly now
succeeds with 45 exact payload files and the unchanged 49-file frozen reference.

The first child signing command reaches its 120-second limit; it is killed/reaped
with confirmed group/descriptor cleanup. Total audited elapsed time is 715.494
seconds, CLI exit 1. Storage-helper bytes remain equal to compiled input. Observed
stderr is 274 bytes/incomplete and retained only as a fixed sign/incomplete-output
code; it cannot distinguish secure UI/key access from timestamp waiting. Actual
key use, UI display/response and Apple timestamp outcome remain unestablished.
No remaining signing/final app validation/seal/archive or success receipt is reached.

All 43 recorded command/worker roots are reaped with no unresolved handles and
absent in a bounded snapshot. All 8,713 previous artifact entries/pins remain
unchanged; failed output and new consumed/attempt records stay private. Retained
credential content is unopened, keychain state unqueried, no automatic unlock or
scope recapture. No notarization, SSH/Ansible, install, app/runtime or VM action.
Next collect operator UI observations and review key readiness versus timestamp
connectivity, then prepare a distinct plan with fresh approval. No retry or further
native/key operation is performed here. See the
[operator result and limits](DevVMMilestone6Runbook.md#first-maintained-operator-run--signing-timeout-5-november-2026).

## Read-only readiness after missed prompt — 5 November 2026

Prior result/observation docs are committed as `f67c5e4` / companion `b260d8f`.
The user reports missing the prompt. Source review confirms the signing deadline
is 120 elapsed seconds and includes secure-UI waiting; that is a supported, likely
explanation for the prior timeout/unchanged helper, not proof of an Apple failure.
No network/timestamp-service diagnostic is run.

A 15-second, 4-KiB-per-stream worker sandboxed against network/file writes finishes
in 0.218 seconds. With optional UI disabled, it opens only the named keychain
reference and checks status twice: 7/unlocked, unchanged. Staged public-certificate
selector/digest/date validity and reviewed-profile membership/policy match. No
identity/item/private-key or trust/signing/timestamp API is called. All native
references release; the owned worker is group-quiet/reaped/closed and absent in a
bounded recorded-PID snapshot. Keychain metadata remains identical, state left as
found. All 13,565 prior artifact entries/pins and consumed/attempt data are intact;
implementation, VM scope and product approval remain unchanged.

This establishes current container/public readiness, not private-key presence,
association, ACL/Touch-ID usability, signing or timestamp success. No new signing,
private-key access, Apple request, SSH/Ansible, install, UI or app/runtime/VM action.
The old plan stays consumed. Next prepare a distinct plan for a separately approved
attended signing attempt; no timeout change or automatic retry is justified here.
See the [bounded diagnosis](DevVMMilestone6Runbook.md#read-only-signing-readiness-diagnosis--5-november-2026).

## Attended signing candidate passed — 5 November 2026

The approved fresh attended plan runs after `b72eadf` / companion `90e2459` through
maintained CLI terminal confirmation and durable consumption. The exact 32-file
committed snapshot and frozen source/runtime/scope/receipt/material bindings match.
All seventeen commands and 46 native workers succeed in 926.436 audited seconds.
Four child signatures and outer app signature use the selected key with Apple
timestamps; offline native checks verify team/IDs, hardened runtime, entitlements,
timestamps, exact public leaf and six code identities on staged and extracted apps.
The 172,869,773-byte private ZIP's digest, complete roundtrip bytes and identities,
post-child-sign executable seal and 45-file resource payload all match. The
49-file frozen reference stays unchanged. Result: SIGNED_OFFLINE_STATIC_CHECKS_ONLY.

All 63 owned command/worker roots clean up and are absent in a bounded PID snapshot;
all 13,570 old artifact entries/pins/failed outputs/audits are preserved. No pending
handles, automatic retry, orchestrator keychain changes, scope recapture or product
approval change. The plan stays consumed. No notarization, publishing, SSH/Ansible,
install, app/daemon/runtime execution or VM launch occurs. UI method/prompt count
is unrecorded. Original-Mac scope, loaded-child and real guest acceptance remain
TO PROVE and need separate review/consent. See the
[signed candidate result](DevVMMilestone6Runbook.md#attended-private-signing-passed--5-november-2026).

## Integration with next — 5 November 2026

The eventual merge target is `next`. This branch integrates fetched `origin/next`
`1258851`, which was eleven commits ahead of the previous common history; the
provisioning branch had 52 unique commits. The merge retains its separate-home
disks, home backup, Stable/Dev isolation and branch-release tooling together with
Setup, New VM selection and the authenticated live terminal. The companion Swift
package has no `next` branch and is unchanged.

Setup state/control sockets and disposable-root admission follow the compiled app
channel. The Swift provisioning helper uses the same channel as manager/CLI/storage
helper; its inherited ownership endpoint rejects a mismatched enclosing app. Dev
assembly includes the pinned package/resources and the channel-neutral C launcher.
Home backup and Setup cannot hold the same guest concurrently. New VM consent
retry identity includes the home choices and guest Touch ID. Schema 6 existed
independently on both branches: older records still load, home-only records retain
schema 6, and saving Setup metadata requires schema 7 so an older next reader fails
closed instead of silently discarding it. No storage or approval is auto-migrated.

The earlier signed candidate remains historical evidence for its original frozen
inputs (`7e46241` source and `b72eadf` signing implementation). It is not a signed
candidate for the merged source or newly pinned runtime. Private artifacts, old
reviews/consumed plans and all frozen pins remain unchanged. A candidate for the
merged branch needs fresh source/runtime/channel/material review before any signing
or real acceptance. This merge grants no further native inspection, key use,
Apple request, install, SSH/Ansible or VM execution. Product execution stays disabled.

Offline merge validation passes 521 Swift tests in 69 suites in each of Stable
and Dev, plus 327 script tests with five signing/PKCS12-generation cases explicitly
excluded. A process/API audit permits only Git, Python and bounded disposable
shell/recorded-PID fixtures, with no external network or real native inspection.
Temporary app fixtures verify CLI/storage/provisioning helper channel diagnostics
and mismatched-app refusal without running the manager. The full signed bundle
assembly and offscreen app-acceptance targets are not run during this merge.
Initial sandbox runs fail local socket/authentication-context fixtures; outside
that sandbox the final fake/local runs pass after correcting schema/channel
integration. All 18,625 existing private artifact entries match their pre-merge
content/modes/link targets; credential content remains unopened and metadata is
unchanged. The historical signed archive retains its exact original digest/size.

`make test-build-policies` also passes both launch/credential policy cases in all three optimized modes: ordinary release, Stable signed-prerelease and Dev signed-prerelease. No signing runs. The first dSYM generation attempt is sandbox-blocked; the outside-sandbox rerun passes. Changed packaging/channel scripts parse and diff whitespace checks pass.

## Fresh merged-source candidate review — 5 November 2026

A new private review freezes committed `4a0f30a`, the updated `d6dd3dbe860f` runtime
and its matching existing signed artifact, while retaining the original Stable
disposable scope verbatim. Source-only admission and independent private-overlay
reconstruction pass; the ordinary product gate, shared package and historical
pins are unchanged. The 32 committed tooling files, seventeen engine files, operator,
corrected inspection guard and named public-material copies bind a new request.
Twenty-five packet/refusal checks and 170 fake API/process tests pass, including
refusal to transfer the old native receipt. This is file-data preparation only.

A fresh bounded native inspection is prepared but needs separate exact-review
approval. Keychain state/availability, native validation and trust are unqueried;
no native output, signing operator plan, authority or candidate build is created.
A new successful source/runtime-bound inspection receipt must precede signing-plan
preparation. All proposed execution effects remain NOT_GRANTED. No signing, key
access, Apple request, SSH/Ansible, install, app/runtime or VM launch occurs.
See the [fresh review and limits](DevVMMilestone6Runbook.md#fresh-private-candidate-review-for-4a0f30a--5-november-2026).

## Fresh merged-source native inspection passed — 5 November 2026

After preparation commits `e04f20a` / companion `f51fc47`, the explicitly approved
`4a0f30a` review succeeds as OFFLINE_STATIC_INSPECTION_ONLY in 77.816 seconds.
All 31 workers, pinned dependency checks, locked-before/after named-keychain status,
public profile/certificate policy and 23 no-network static code checks pass. Every
owned root is group-quiet/reaped/closed with zero unresolved handles and absent in
a bounded PID-only snapshot. All 18,881 old private entries, frozen review/pins and
prior candidates remain unchanged; 173 sealed review files and source admission
revalidate. The ordinary product and shared package remain unchanged.

The request is consumed without retry. No signing plan/candidate build, private-key
query, Apple request, SSH/Ansible, install, app/runtime or VM launch occurs. This
receipt can support preparing a fresh attended signing plan; it does not authorize
signing or establish key availability, CMS signer authenticity, certificate trust,
current revocation/notarization or original-Mac/loaded-child/guest acceptance.
See the [exact result and limits](DevVMMilestone6Runbook.md#fresh-4a0f30a-native-inspection-passed--5-november-2026).

## Fresh 4a0f30a attended plan prepared — 5 November 2026

The maintained private operator prepares/checks a new attended plan against the
new successful inspection receipt, exact `4a0f30a` source, updated runtime and
original Stable disposable scope. Source/runtime/receipt/material/engine/operator
bindings pass; 32 committed tooling files and 173 sealed review files remain exact.
The plan is CHECKED_PUBLIC_INPUTS_ONLY, unconsumed and not execution-authorized; all
five proposed effects remain NOT_GRANTED. No candidate output, authority or backend is created.

Fourteen actual-plan data/refusal checks and 44 fake API/process tests pass. All
18,916 old private entries/pins remain unchanged; current key state/availability
and original signing-material metadata/content are unqueried. Private attendance
notes include quoted real-terminal confirmation, prompt/deadline handling, bounded
cleanup and no retry. Separate approval must name the new plan and proposed key/UI/
timestamp effects before execution. No build, native inspection, signing, private-key
access, Apple request, SSH/Ansible, install, app/runtime or VM launch occurs. See
the [attended plan and limits](DevVMMilestone6Runbook.md#fresh-4a0f30a-attended-signing-plan--5-november-2026).

## Attended 4a0f30a attempt stopped at signing — 5 November 2026

After preparation commits `5a902cd` / companion `292da85`, the explicitly approved
new plan runs through maintained real-terminal exact-plan confirmation and durable
consumption. Its sealed review/plan, fresh receipt and 32 committed tooling files
match. All twelve preparation/build/location commands and thirty pre-sign native
workers pass; the 45-file resource payload matches. The first child signing command
reaches its 120-second deadline, is killed/reaped with confirmed cleanup and produces
no completed signed-candidate/archive/success receipt. Total audited elapsed is
752.079 seconds, CLI exit 1. Staged storage-helper bytes equal compiled input.

Incomplete 248-byte stderr permits only a fixed sign/incomplete-output diagnosis;
key/UI/timestamp wait cause is undetermined and prompt observation is pending.
No automatic retry, keychain/native/network diagnosis or new plan is performed.
All 43 owned roots are quiet/reaped/closed, zero handles remain and a bounded PID
snapshot finds them absent. All 18,928 prior private entries/reviews/plans/pins are
unchanged. The plan remains consumed; the ordinary product and shared package are
unchanged. No notarization, SSH/Ansible, installs, normal app/runtime or VM launch
occurs. See the [attempt, cleanup and limits](DevVMMilestone6Runbook.md#attended-4a0f30a-run--first-signing-timeout-5-november-2026).

**Operator follow-up:** the user reports completing the macOS dialog. Exact dialog
type and completion time relative to the timeout are unknown; key use/timestamp
outcome and timeout cause remain unestablished. Preserve the stopped/consumed plan
and automated evidence; no retry or new native/key/network operation occurs. See
the runbook's Operator observation after the 4a0f30a timeout.

## Manager pin follows merged dev-vm — 5 November 2026

**DESIGN DECISION:** consume the exact 95-file package export from dev-vm
`5770d0fde0355be6dade6b306d03661a5b8e616a`, the merge of `main` at `c30f213`
into `codex/swift-provisioning-package`. This replaces the active `bb3fae2`
base-plus-four-patches provenance. All four integrations are already committed in
the new source revision; active `integrationPatches` is empty and `baseFiles`
equals the exported inventory. Retain the historical patch files unchanged.

**VERIFIED — source data:** all 95 exported files independently match that Git
commit. Only the package README differs from the previous effective export;
Swift code, launcher, parser dependencies, engine identity, provisioning resources
and the four bundled layout cards are byte-identical. The lock, source snapshot
and generated Swift admission pin change together. The newer repository-only
factory controller and Lua examples are outside this package export; this update
does not add native layout cards or invoke those controllers.

**IMPLEMENTED:** unpatched source admission also requires an identical base
inventory. Package admission tests expect the new revision. Historical reverse-
patch and frozen-helper tests use disposable synthetic patches, independently of
the product's current pin, and retain the exact frozen helper bytes. The added-file
fixture continues to reproduce the ignored-parent Git failure and its private
ceiling workaround; the initial edit-only fixture did not reproduce that case.

**PRIVATE CANDIDATES:** the product pin update does not rebind any existing review,
scope, receipt, candidate, consumed signing plan or artifact. Their original
frozen source/package/runtime pins remain authoritative for those historical
inputs. No new private candidate or native/signing review is prepared, and ordinary
product execution approval remains unchanged. Any future candidate from the new
source needs its own review rather than reusing an old receipt.

**VERIFIED — offline/fake:** make-based serial Swift coverage passes all 518
selected tests in 67 suites in each of Stable and Dev. Exclude the real managed
SSH and home-disk acceptance suites and the test invoking `ssh -G`; no acceptance
environment variable is supplied. The guarded script suite discovers 333 tests:
328 pass and five software-signing/key-generation/PKCS12 cases skip. Its process,
native-library, credential-path and external-network guards report no prohibited
attempts. Focused package/frozen-helper checks pass after correcting the synthetic
fixture. `make prepare-source`, independent exact-commit export comparison, all
five edited/new Python syntax checks and Git whitespace checks pass. SwiftPM
updates and automatic dependency resolution are disabled; dependencies already
exist locally. Signed/relocated bundle fixtures are not run under this scope.

**VERIFIED — preservation / limits:** all 23,951 entries in the captured private
inventory remain unchanged, as do the runtime lock and generated runtime pin.
Credential/disk-image contents are not opened by the inventory. Existing frozen
candidate copies and pins remain unchanged; only the current product's provisioning
lock/generated pin are refreshed. The companion worktree is unchanged and clean.
No signing, key access, native inspection, Apple request, real SSH/Ansible, install,
normal app/runtime action or VM launch occurs. Signed distribution, native UI and
real guest acceptance remain **TO PROVE** for any future candidate from this source.

## Fresh private review after package pin update — 5 November 2026

**DESIGN DECISION:** prepare exact committed `007bc66` with package `5770d0f` and
the unchanged matching local signed runtime. Preserve the original Stable
disposable UUID/root, scope JSON, receipt and Swift definition verbatim. Earlier
candidate artifacts and frozen source/package/runtime pins remain unchanged; no
root observation, scope recapture or ordinary product approval change occurs.

**VERIFIED — file data/fake only:** source-only admission and independent six-file
overlay reconstruction pass. A new request binds 32 committed tooling files,
seventeen engine files, operator, corrected guard and staged public material
copies. All 25 actual-packet checks and 170 fake tests pass. The new source,
implementation and inspection hashes differ from the previous review; an old or
relabeled receipt cannot transfer. The 173-file sealed review uses owner-only
paths, and all 23,951 prior private entries plus four current pin files are
preserved. Documentation changes in both worktrees describe preparation only.

**TO PROVE / NOT GRANTED:** fresh native inspection, current keychain state/key
availability, trust, signing and original-Mac/loaded-child/guest acceptance.
No authority, inspection output, signing plan, candidate build/output, signing,
key access, Apple request, real SSH/Ansible, install, normal app/runtime action or
VM launch occurs. All effects remain NOT_GRANTED; a successful exact-input native
receipt and separate approval must precede any attended signing plan. See the
[fresh 007bc66 review runbook](DevVMMilestone6Runbook.md#fresh-private-candidate-review-for-007bc66--5-november-2026).

## Fresh 007bc66 native inspection result — 5 November 2026

**USER AUTHORIZATION / VERIFIED:** after manager `467f979` / companion `8cf7f8d`
commit the preparation docs, the exact new review's bounded read-only inspection
is approved. The 173 sealed files, corrected guard/composition, 32 committed
tooling files and seventeen-file engine match. The typed in-memory inspection
effect consumes the request once; prepared review files remain unchanged.

**VERIFIED — native offline static only:** all 31 workers pass in 76.504 seconds,
including dependency checks, interaction-disabled locked-before/after named
keychain status, public profile/certificate checks and 23 no-network runtime
static checks. Every group is quiet before root reaping, descriptors are closed
and unresolved handles are zero. All 31 recorded PIDs are absent in a separate
bounded PID-only snapshot. All 24,204 pre-run private entries, 173 sealed files
and four current pin files remain unchanged. Source admission/frozen overlay
reconstruction pass again. No disposable root is observed or pin recaptured;
ordinary approval, shared package and product code/pins remain unchanged.

**TO PROVE / NEXT:** CMS signer authenticity, certificate trust, online revocation,
fresh notarization/Gatekeeper, key availability and original-Mac/loaded-child/guest
acceptance. The new receipt can support preparation of a fresh attended signing
plan; it grants no signing/key/Apple/guest authority. No such plan, candidate build,
signing, private-key access, Apple request, real SSH/Ansible, install, normal app/
runtime action or VM launch occurs. The request remains consumed without retry.
See the [inspection result and limits](DevVMMilestone6Runbook.md#fresh-007bc66-native-inspection-passed--5-november-2026).
