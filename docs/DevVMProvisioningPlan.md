# Shared Swift dev-vm provisioning implementation plan

Status: original milestone 1 committed as `62a4c62`; milestone 1A committed as `915642e`. Milestone 2 has started with the shared package structure and strict manifest parsing committed in dev-vm at `e86550e`. Feature/profile resolution, source snapshots and offline proposals are committed in dev-vm at `56dba82`; execution and manager integration remain pending.

Date: 2 November 2026 (Australia/Melbourne).

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

Maintain a SwiftPM package at the dev-vm repository's root `Package.swift`, with a `DevVMProvisioningCore` library and a standalone `dev-vm` executable consuming that library. These products now exist in the milestone-2 foundation branch; the executable currently supports structure validation only. The manager will pin the package by immutable revision and link the same library into its provisioning helper after the relevant migration steps. Keep Swift 6 and macOS 15+ compatibility and a make-based build/test entry point.

Move host-side manifest parsing, feature/profile resolution, plan generation, input freezing/hashing, source validation, inventory/argument generation, guest payload staging, native-command sequencing and authorization cleanup coordination into this package. Manager-specific transports and lifecycle actions are injected adapters; the package must not import the manager or create dependency cycles. In the app, all lifecycle actions still pass through VMManager. The standalone executable calls the same package and uses the manager's public CLI for authorized VM lifecycle operations.

Keep Ansible playbooks, roles, feature catalogues/schemas, presets and guest-side Python/shell helpers as versioned package resources wherever behavior is compatible. Port the host driver rather than reimplement Ansible in Swift or rewrite Python helpers as Linux Swift programs. Build the compiled package into the app; users do not need Swift, Xcode or a source checkout at runtime.

Proposed app layout:

```text
Contents/
  MacOS/
    OmarchyVMManager
    omarchy-vm
    OmarchyVMProvisioningHelper
      [links DevVMProvisioningCore]
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
| 2. Shared Swift controller and packaging — foundation and offline planning implemented; remaining port pending | SwiftPM library, offline validation/planning executable, strict data/manifest parser and schema/catalogue resources in dev-vm; offline resolution, snapshots and proposals now implemented; execution, full guest resources, manager adapters and pinned packaging remain pending | Foundation tests, 18 plain-data and 66 complete proposal/error Python-oracle fixtures pass without a guest; complete plan parity, manager pin and relocated app acceptance remain pending |
| 3. Job coordination | Journal, admission, lifecycle interlocks, cancellation and recovery | Fake-runtime tests cover session changes, duplicates, failure retention, interrupted work and .exited ownership |
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
