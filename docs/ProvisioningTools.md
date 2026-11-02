# Provisioning dependency checks

Milestone 1A implements the Homebrew Ansible CLI dependency contract from the [shared Swift provisioning plan](DevVMProvisioningPlan.md). The native **Provisioning tools** page and local **setup tools** command report schema 2. The CLI does not open the app, access the registry or connect to a guest.

The shared Swift package, parsers, dev-vm controller port, setup execution, provisioning jobs and interactive terminal are not integrated yet. Every feature reports `implemented: false` and `enabled: false`, even when `toolsReady` is true. Normal VM management does not depend on these checks.

The [milestone-2 foundation](DevVMProvisioningPlan.md#milestone-2-foundation-handoff--2-november-2026) now supplies a validation-only Swift package/parser in the companion dev-vm worktree. It does not change manager dependencies, reports or feature gates. The continuation now adds offline feature/profile resolution, source snapshots and proposals in dev-vm. The immutable package integration is still pending; manager gates stay disabled.

## Native and CLI reports

Select **Manager → Provisioning tools** to check or refresh tools. Reports show Available, Missing, Incompatible, Needs authentication or Check failed, with detected versions and executable/Homebrew installation identities. Missing or incompatible tools can show a selectable manual Homebrew command. The manager never runs installation or upgrade commands.

After `make build`, use the worktree binary directly:

```sh
.build/debug/omarchy-vm setup tools
.build/debug/omarchy-vm setup tools \
  --tool ansible-playbook=/absolute/path/to/ansible-playbook \
  --tool ansible-inventory=/absolute/path/to/ansible-inventory
```

Overrides are command-scoped, absolute paths. Supported keys are `brew`, `ansible-playbook`, `ansible-inventory` and `gh`. An Ansible override must resolve to the same command target as Homebrew's active installation; an arbitrary external wrapper or a different keg is refused without execution or fallback. There is no persistent override editor in this milestone.

The packaged CLI gains this behavior only after separate authorized assembly/installation. The repository's `bin/omarchy-vm` wrapper selects an app bundle; building this worktree alone does not replace that bundle.

The CLI returns one JSON object with `schemaVersion: 2`, `policy`, `tools` and `features`. Exit 0 means discovery completed, not that all dependencies are ready. Missing/incompatible tools are normal report results. Invalid arguments or report-level failure exit 1. Existing guest-command JSON and command protocol 1 remain unchanged.

Each tool records its status, fixed bounded reason, version when recognized, provider, executable identity, optional `installation` identity and optional manual `installCommand`. The installation command identifies a formula; it does not promise to fix authentication or version incompatibility. Fingerprints detect replacement and symlink retargeting; they do not establish cryptographic provenance of host software or authorize a later setup job.

## Migration from schema 1

The original milestone 1 implementation is preserved in commit `62a4c62`. Schema 2 makes these deliberate changes:

| Schema 1 | Schema 2 |
| --- | --- |
| Independent `python` and `yaml` tool records | Removed; eight tool records remain |
| Python interpreter version/import probes and Ansible shebang parsing | Removed; the manager invokes Ansible's installed CLI entry points |
| Per-tool `interpreter` identity | Replaced by Ansible's Homebrew `installation` identity |
| `--tool python=...` and independent runtime selection | Rejected before any probe with `retired-tool-override` and Ansible override guidance; YAML/PyYAML override names receive the same guidance |
| Planning gated by external Python/PyYAML | No external tool blockers for JSON/YAML planning; actual planning remains disabled until the shared package/parsers exist |
| Matching Python package/launcher versions | Matching supported Ansible Core command versions plus installation membership and local CLI self-checks |

Consumers must check `schemaVersion` before interpreting tool IDs or feature requirements. The manager has no separate host Python/PyYAML requirement and does not select, inspect or invoke an interpreter. Ansible's Homebrew launchers still use their own Python and dependencies internally. Python remains in existing development/build tooling; the guest may also require Python. None of those are a new manager-controlled runtime.

## Homebrew discovery and Ansible admission

Search command-scoped overrides, known Homebrew directories, a validated Homebrew prefix and bounded absolute PATH directories. A GUI does not need a terminal's PATH. Invalid overrides fail without falling back. Relative paths, parent traversal and control characters are refused. Never launch a login shell, source shell configuration or evaluate `brew shellenv`.

Homebrew is queried only with `--version`, `--prefix` and `--prefix --installed ansible`. The last command reports the installed formula's active prefix; no install/update/build command runs. The reported directory and command targets must exist. Default Ansible discovery uses that installation's `bin` directory rather than an unrelated executable on PATH.

Both Ansible entry points must resolve to Homebrew's expected targets within the same active installation and report the identical stable **Ansible Core 2.21.x** version. Keep this original Core admission line until other versions are reviewed; Homebrew providing a newer line does not automatically establish compatibility. Python version details in Ansible's output do not become a separate admission gate. Shell wrappers supplied by the installation are supported without parsing their shebangs.

After matching versions, run these fixed local self-checks in a private temporary directory:

1. `ansible-inventory -i INVENTORY.ini --list` must return the expected JSON groups and single synthetic `fixture.invalid` host with no unexpected hosts or variables. Core 2.21's empty `ansible_local` namespace is accepted; nonempty facts or other variables are refused.
2. `ansible-playbook --syntax-check -i INVENTORY.ini SYNTAX.yml` must succeed and identify only the fixed syntax fixture. The playbook disables fact gathering and contains one built-in debug task that is never executed.

The inventory is a non-executable mode-0600 INI file. Inputs are generated from fixed manager literals, not user manifests, dynamic inventory, roles, lookups or custom tasks. The private config enables only the INI inventory plugin and disables variable plugins. Neither check runs a playbook, uses check-mode task execution, connects to SSH, gathers facts, touches a guest or downloads a package. Syntax/inventory behavior follows the [Ansible inventory CLI](https://docs.ansible.com/projects/ansible/latest/cli/ansible-inventory.html) and the installed supported command contract.

A missing formula, broken wrapper/runtime, unsupported/prerelease/mismatched Core, foreign command target, bad self-check output, timeout or executable/installation replacement prevents pair readiness. Success proves this local CLI contract, not arbitrary playbook or real-guest compatibility.

## Capability gates

Each feature records `blockers`, `toolsReady`, `implemented`, `enabled` and a reason. `toolsReady` describes external prerequisites only; it does not indicate the presence of the shared package, authorization or guest compatibility.

| Capability | External prerequisites |
| --- | --- |
| JSON and YAML planning | None; shared Swift package/parsers remain unimplemented |
| Basic native provisioning | Fixed macOS Bash, SSH, SCP and SFTP |
| Developer features and external setups | Basic transport set, verified Homebrew and both Ansible commands passing local checks |
| GitHub-star theme selection | Relevant system transports and GitHub CLI; authentication remains unverified |
| Remote setup retrieval and custom image building | Deferred; gates unavailable and Git/Docker not probed |

Bash and SSH use version-only probes at fixed system paths. SCP and SFTP have no stable version-only option and receive executable identity checks only. GitHub CLI runs `--version` only and remains Needs authentication; no token, credential configuration or Keychain item is read. No Git, Docker, container, image or real-guest probe runs.

## Isolation and limits

Each inspection uses a disposable mode-0700 directory for HOME, working directory, Ansible config/inventory/playbook and caches. Fixture files are mode 0600 and the directory is removed after inspection. It is separate from manager metadata and VM storage. The explicit environment retains `en_US.UTF-8`, disables Python bytecode writes inside Ansible, disables Homebrew auto-update/analytics and excludes inherited tokens, SSH agents, Python package overrides and Ansible config/plugin overrides. Disabling bytecode writes does not involve invoking Python directly.

Each subprocess has null stdin, a five-second timeout and a combined **32 KiB stdout plus stderr** budget. Streams stay separate: prefix, Ansible version and structured inventory output are validated on stdout. OpenSSH intentionally emits its version on stderr, so its bounded version text is parsed there as well. Other diagnostic stderr is discarded without logging or inclusion in the report. A warning on stderr does not contaminate a valid prefix or JSON response. Nonzero exits still fail even when stdout appears valid.

The runner uses direct argument arrays and a private process group. Completion, cancellation, timeout and output overflow dispose of that group and reap the direct child. It does not wait indefinitely for a descendant holding an output pipe. Error reports use fixed categories and exit codes, never raw output or personal machine identifiers.

Check entry identities before/after probes and again at the end, including the active Homebrew Ansible directory. Replacing Homebrew, either command or the active keg invalidates the whole pair. A future apply job must perform its own revalidation; a dependency report is not reusable execution authorization.

## Validation and limits

Run `make test-provisioning-tools` for focused coverage and `make test build` for manager regression checks. The focused suite uses fake tool inventories, controlled command responses and disposable real shell processes. It covers the schema transition, retired overrides, healthy/broken command pairs, Homebrew membership, static input isolation, warning streams, version mismatches, output limits, timeout, cancellation and replacement. Requests are recorded to prove the manager does not discover or launch Python, run tasks or invoke installation commands. A real local shell-wrapper fixture exercises the complete provider without a host Ansible or Python probe.

**VERIFIED — original milestone 1:** commit `62a4c62` passed 224 Swift tests/37 suites and 43 script tests. Its minimal-PATH discovery admitted Python 3.14.9/PyYAML 6.0.3/Ansible Core 2.21.5 and established the UTF-8 locale requirement. Those results describe schema 1 and remain historical evidence, not schema 2 acceptance.

**VERIFIED — milestone 1A, 2 November 2026:** `make test build` passes 224 Swift tests in 37 suites and 43 script tests. The 18 focused provisioning tests include parameterized failure cases and the full real local shell-wrapper fixture. Coverage validates schema 2, retired overrides, independent planning prerequisites, no direct Python discovery/invocation, warning streams, fixed inputs, command-pair mismatch, replacement and bounded process cleanup.

**VERIFIED — existing-host CLI checks:** with only `/usr/bin:/bin` in PATH, the rebuilt worktree CLI discovers Homebrew 7.0.11, system Bash 3.2.57/OpenSSH 10.3p1 and the installed Ansible Core 2.21.5 command pair. Both commands pass the fixed inventory and syntax checks. The response contains eight tool records, no Python/PyYAML/interpreter fields, and only disabled execution gates. Retired Python/YAML overrides return the documented error; help/version and guest-command protocol 1 remain valid; an installation flag is rejected. GitHub CLI 2.103.3 remains authentication-unverified. The host check established the supported empty `ansible_local` inventory shape and separate stderr handling for Homebrew warnings and OpenSSH's version. No host software was installed/upgraded, app opened/installed, credential accessed, task executed or guest contacted.

**USER CONFIRMED — isolated UI preview, 2 November 2026:** the user reviewed and accepted the page's appearance in a temporary native SwiftUI app using an unchanged copy of ProvisioningToolsView and the current core library. The preview was ad-hoc signed, opened with live dependency checks, and closed on request. It contained no manager initialization, registry access, command server, VM runtime kit or VM controls. The installed manager and guests were untouched; no tracked preview source or shared package was added. This confirms the isolated presentation, not installed-manager integration or every control interaction.

**TO PROVE:** full manager page interaction, packaged/signed discovery, other Homebrew installations and Core versions, the shared Swift package and parsers, real provisioning/terminal/guest behavior and crash/sleep recovery. This milestone starts no controller port and establishes no real-VM evidence.
