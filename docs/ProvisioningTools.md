# Provisioning dependency checks

Milestone 1 of the [dev-vm implementation plan](DevVMProvisioningPlan.md) checks host tools and calculates prerequisite gates. The native manager has a **Provisioning tools** page. The CLI has a local **setup tools** command that does not open the app, access the registry or connect to a guest.

The dev-vm engine, setup execution, provisioning jobs and interactive terminal are not integrated yet. Every feature reports `implemented: false` and `enabled: false`, even when `toolsReady` is true. Normal VM management does not depend on these checks.

## Native and CLI reports

Select **Manager → Provisioning tools** to check tools or refresh a previous report. Version and executable/interpreter paths are displayed with Available, Missing, Incompatible, Needs authentication or Check failed. Installation commands are selectable text to run manually in a separate Terminal; the manager never invokes them.

After building with `make build`, run the worktree binary directly:

```sh
.build/debug/omarchy-vm setup tools
.build/debug/omarchy-vm setup tools --tool python=/absolute/path/to/python3
.build/debug/omarchy-vm setup tools \
  --tool ansible-playbook=/absolute/path/to/ansible-playbook \
  --tool ansible-inventory=/absolute/path/to/ansible-inventory
```

The packaged CLI supports the same command after a separate authorized app assembly/installation. The repository's `bin/omarchy-vm` wrapper selects an app bundle; building this worktree alone does not replace that bundle.

The command returns one JSON report with `schemaVersion: 1`, `policy`, `tools` and `features`. Exit 0 means discovery completed, not that all dependencies are ready. Missing and incompatible tools are normal report results; invalid arguments or a report-level failure return an error and exit 1. Existing guest-command JSON and command protocol 1 remain unchanged.

Each tool records its status, bounded reason, detected version when available, provider, executable identity, selected interpreter when relevant, and optional manual `installCommand`. The command identifies the associated formula; it does not promise to fix a version conflict or authentication failure. The native page shows installation guidance for missing or incompatible tools only. Executable fingerprints detect changes; they are not a claim of cryptographic provenance or a persistent authorization to run a later setup job.

Each feature records required-tool blockers, `toolsReady`, `implemented`, `enabled` and a reason. These are host prerequisites only. They do not establish guest compatibility, setup task trust or authorization to change a guest.

## Discovery and compatibility policy

Search explicit per-command overrides, known Homebrew directories, a validated Homebrew prefix and bounded absolute PATH directories. A GUI does not need a terminal's PATH. Invalid explicit overrides fail without falling back. System Bash/SSH/SCP/SFTP use their fixed macOS locations. Relative paths, parent traversal and control characters are refused. Do not launch login shells or evaluate shell configuration or `brew shellenv`.

Supported override keys are `brew`, `python`, `ansible-playbook`, `ansible-inventory` and `gh`. Overrides are command-scoped and do not persist settings. The native report uses normal discovery; there is no persistent override editor in this milestone.

| Component | Admission policy | Probe |
| --- | --- | --- |
| Homebrew | Recognized numeric version and valid absolute prefix | `--version`, `--prefix`; disable auto-update and analytics |
| Python | Stable 3.11 through 3.14 | Isolated, no-bytecode structured runtime report |
| PyYAML | 6.x in the selected Python runtime | Import and version check through that interpreter |
| Ansible Core | Stable 2.21.x on Python 3.12 through 3.14 | Matching launcher/interpreter/package versions and required module imports |
| Bash and SSH | Recognized version from the fixed macOS executables | Bash `--noprofile --norc --version`; SSH `-V` |
| SCP and SFTP | Fixed executable is present and executable | File identity check only; no connection and no unsupported version flag |
| GitHub CLI | Recognized version; authentication remains unverified | `--version` only |

The Ansible line follows the dev-vm CI reference and [Ansible's controller Python matrix](https://docs.ansible.com/projects/ansible-core/devel/reference_appendices/release_and_maintenance.html). These are conservative admission rules covered by synthetic version fixtures, not a claim that every patch version has passed a real workstation setup. Future Python/Ansible/PyYAML lines fail closed until reviewed. A Homebrew install command can provide a newer unsupported line; always recheck rather than promise that installation alone enables a feature.

Prefer the discovered Ansible launcher's Python when no Python override was supplied. Preserve its virtualenv entry path: resolving the Python symlink before execution can bypass `pyvenv.cfg`. Both Ansible launchers must name the same selected interpreter. Accept direct absolute Python shebangs and exactly `/usr/bin/env python3` under the controlled PATH. Refuse shell wrappers, extra shebang arguments and ambiguous environments. An explicit unrelated Python does not satisfy Ansible's dependencies.

Apple's `/usr/bin/python3` entry is not executed, including through an explicit override or discovered Ansible interpreter, because it can request developer-tool installation. Use a compatible Homebrew runtime. Git is also not probed in this milestone; no developer-tool installation UI is requested.

## Capabilities and deferred checks

JSON planning needs Python. YAML planning additionally needs PyYAML. Basic provisioning also requires system Bash, SSH, SCP and SFTP. Developer features and external setup application require that basic set, coherent Ansible launchers and PyYAML. A missing optional dependency does not disable unrelated prerequisites or ordinary VM management.

GitHub-star theme selection remains blocked by unverified authentication even when `gh` is present. No `gh auth` command is run; no token environment variables, credential files or Keychain items are read. Explicit authentication checking and token configuration belong to a later integration step. Direct theme selection does not need this optional selector.

Remote setup retrieval and custom image building are explicitly deferred. Their feature gates remain unavailable and no Git or Docker engine probes run. This milestone neither starts containers nor builds or downloads images.

## Probe isolation and limits

Each inspection uses a private disposable temporary directory for HOME, working directory, Ansible configuration and caches. It is separate from manager metadata and VM storage and is removed after inspection. Python disables bytecode writes. The controller locale is explicitly `en_US.UTF-8`, as required by Ansible. Only an explicit minimal environment is passed; inherited Python/Ansible configuration, tokens, SSH agents and dynamic-loader overrides are excluded.

Each executed probe has null stdin, a five-second timeout and a combined 32 KiB stdout/stderr limit. The runner uses direct argument arrays and a private process group; completion, cancellation, timeout and excessive output dispose of the group and reap the direct child. Slow descendants cannot keep a probe waiting indefinitely on an inherited output pipe. Raw output is parsed in memory and discarded; failures use fixed categories instead of including stderr or personal machine identifiers.

Recheck executable entry identities before and after execution and at the end of discovery. Reject changes rather than produce a report from mixed tool versions. Future apply jobs must revalidate capabilities and bind their own approved executable identities; a tools report is not reusable execution admission.

## Validation

Use `make test-provisioning-tools` for the focused suite and `make test build` for manager regression checks. Tests use fake executable inventories and structured fake probe responses, plus disposable local shell fixture processes for I/O limits, timeout, cancellation and symlink behavior. They install no software, download no images, start no VM and access no existing guest.

**VERIFIED — 2 November 2026:** `make test build` passes 224 Swift tests in 37 suites and 43 script tests. This includes 18 focused provisioning tests in two suites, with parameterized compatibility cases and real disposable local process fixtures. A direct CLI smoke check with deliberately unavailable external-tool overrides returns the expected report, leaves execution disabled, preserves help/version and command protocol 1, and rejects an installation flag without opening the manager.

**VERIFIED — read-only host discovery:** the worktree CLI, launched with only `/usr/bin:/bin` in PATH, discovers Homebrew 7.0.11, system Bash 3.2.57, OpenSSH 10.3p1 and the fixed SCP/SFTP executables. It admits the coherent existing Python 3.14.9, PyYAML 6.0.3 and Ansible Core 2.21.5 runtime. GitHub CLI 2.103.3 is detected with authentication explicitly unverified. All execution gates remain disabled. This check exposed and corrected the UTF-8 locale requirement; no host tool was installed/upgraded, credential accessed, app opened or guest contacted.

**TO PROVE:** native page layout and interaction, other Homebrew/Ansible installations and supported host versions, signed packaged tool discovery and every real provisioning/terminal/guest behavior. Future engine integration must validate the admitted host combinations against dev-vm itself.
