# Milestone 6 disposable-guest acceptance runbook

Status: **PREPARED / NOT RUN**. This document authorizes no operation.
Prepared 3 November 2026 for the native Swift provisioning integration.

The current product execution gate remains false. The full-screen UI acceptance
uses isolated fake services; it establishes neither real guest identity nor a
successful setup, cleanup, restart or check. Keep VERIFIED, DESIGN DECISION,
PRIVATE COUPLING and TO PROVE evidence distinct in the eventual results.

## Scope and prerequisites

**DESIGN DECISION:** test only newly created, manager-owned disposable UUID roots.
Use the manager's existing runtime, factory verification, registry, locks, NAT,
SSH enrollment and lifecycle. Do not target a personal/default, retained POC or
other existing VM. No bridge, host-folder sharing, personal public key, credential
client, coding-agent login or host tool installation is part of this run.

Before requesting approval, complete this worksheet with concrete values in a
private local acceptance record. Do not commit personal identifiers or credentials.

| Field | Required value before execution |
| --- | --- |
| Manager candidate | Exact commit, build mode, app path and binary/package/resource digests |
| Runtime | Exact runtime-lock digest, verified kit provenance and compatible factory/guest contract |
| Shared engine | Existing immutable export base plus patch, engine/resource/lock hashes |
| Factory | Already available, verified official/imported identity and image digest; a missing image is a stop condition |
| Profiles | New disposable UUID(s), names, manager-owned root paths and stopped metadata-only creation receipts |
| Resources | Explicit manager choices within the current host budget; suggested starting point 4 GiB, 4 cores, 64 GiB sparse disk, one guest at a time |
| Networking | NAT only, newly reserved unprivileged loopback SSH port per UUID |
| Account | Dedicated non-personal test account; UID must be observed through pinned authenticated SSH, never assumed to be 1000 |
| Inputs | Exact source snapshot, generated manifest if applicable, plan/input/engine hashes and all referenced files/modes |
| Consent | Exact apply review; persistent sudo grant until confirmed cleanup; separate Docker root-equivalent or custom-task trust only for opted-in subcases |
| Recovery | Original helper ownership/checkpoint capture, owned local-process exit criteria and a reviewed response if capabilities are lost |
| Cleanup | Matching `.exited`, no remaining owned processes; offer verified stopped-root Trash afterward |

**Execution blockers:** the current build cannot submit real work. A separately
reviewed acceptance candidate must admit only the approved disposable UUID/root
scope in both manager and helper before enabling an operational path. A blanket
`enabled = true`, environment switch, altered readiness report or saved receipt is
not a scoped acceptance mechanism. Implement and test that restriction with fakes
first; leave the ordinary product build disabled. Verify real helper signing and
loaded-child/package admission for the selected build; do not weaken provenance
to get a job to launch. Developer ID/notarization credentials, permission grants,
factory downloads and UI takeover require their own authorization when needed.

No host install is a fallback. Homebrew and a compatible, matching Homebrew
`ansible-playbook`/`ansible-inventory` pair must already satisfy the existing report
and pinned transport policy. A missing/wrapped/mismatched/replaced dependency stops
this run. Do not uninstall or replace tools to manufacture a failure case; use the
existing fake dependency suite for those cases.

## Explicit approval boundary

Present the completed worksheet, exact candidate and frozen proposal for review.
Obtain explicit consent for the named disposable guest creation/launch, real
SSH/Ansible execution and proposed guest changes. Source/custom-task trust,
persistent sudo and Docker access remain separate approvals in the actual flow.
Approval of this document, a general "proceed", tool readiness or an earlier VM
POC does not silently select a new disk, grant a new privilege or authorize a
factory download. The repository AGENTS.md requires explicit consent before real
guest operations and separate consent before permissions/real signing/UI takeover.

If multiple subcases need separate guests or a Mac sleep/crash test, list those
UUIDs and disruptive actions before that phase. Start with the clean happy path;
do not combine an unreviewed failure experiment with a live authorization grant.

## Baseline input and offline review

Prepare a tiny, inspectable source folder. For example, the initial scenario may
select only `cli`, a harmless synthetic configuration file and no custom tasks:

```yaml
schema_version: 1
id: milestone6-smoke
setup:
  features:
    enable: [cli]
dotfiles:
  - source: acceptance.conf
    target: .config/manager-acceptance/acceptance.conf
```

`acceptance.conf` contains only a synthetic marker. Inspect the resolved proposal:
`cli` includes its pinned catalogue's tools, so approve their actual package/tool
selection rather than treating the example as a promise of no guest changes.
Keep unrelated synthetic sentinels outside the target paths to detect collateral
changes. Explicitly review dotfile conflicts/backups before Apply. Do not use
credential directories, personal dotfiles, shell secrets or an automatic update of
unrelated guest software.

Use the existing offline preview and New VM handoff first, with a caller-retained
review UUID. Review exact generated/original manifests and receipts. Confirm the
manager's resource/factory/SSH/sharing choices prevail over any source VM fields.
Saving the setup selection must create stopped metadata only. Editing the source
or native choices must require a fresh capture; an existing receipt must retain its
original frozen bytes. Repeating identical creation consent/settings must return
the same VM UUID. Conflicting settings or uncertain registry outcomes must stop
without creating a second guest. These behaviors already have fake/local tests;
record the actual candidate's results independently.

Do not use `create --start` with a setup selection. Start is a separate authorized
lifecycle action after its exact UUID/root and factory are reviewed.

## Execution and evidence matrix

All entries below are **TO PROVE** until observed on an approved disposable guest.
Record PASS, FAIL, BLOCKED or NOT RUN for each row, with the exact build and scope.
A fake/local pass may be linked as supporting evidence but cannot fill a real row.

| ID | Action on approved scope | Required observations / stop conditions |
| --- | --- | --- |
| M6-01 | Launch the new disposable UUID through the manager | Correct verified factory/root, NAT and resources; one retained client; no unrelated guest/root/port mutation. Image missing or provenance changed: stop before download/launch. |
| M6-02 | Complete the dedicated owner setup and managed SSH | Pinned Ed25519 identity and manager session nonce; strict authenticated owner/UID reply; host/client-key references and current root/port match. A username or guest-status file alone is insufficient. Unknown/mismatched evidence: refuse provisioning. |
| M6-03 | Prepare exact Apply review in UI and CLI | Same frozen hashes/target scope; fresh dependency admission; no helper application during preview/preparation. Refuse stale session, source, key or tool evidence. Store only redacted receipts. |
| M6-04 | Give explicit persistent-grant consent and Apply once | Original admitted helper registers/activates once, exact frozen delivery and transport admitted; live output is actual process output; stages follow typed state. A lost reply is status/lookup, never automatic replay. |
| M6-05 | Answer authorization manually in the live terminal | Deliberate Take input, one owner, exact invocation; hidden input stays hidden, nested SSH/TTY echo is correct, resize and Unicode/ANSI work. Never type secrets into logs, scripts, CLI flags, screenshots or the acceptance record. |
| M6-06 | Observe successful configuration and cleanup | Desired file/tools present, unrelated sentinels intact; owned work quiescent, persistent grant revoked, authentication cache cleared, noninteractive inactive proof, payload absent and matching local helper exit. A successful Ansible exit alone is not cleanup proof. |
| M6-07 | Review and reapply the same frozen configuration | Desired state remains correct; no implicit unrelated removal/update; record actual changes. New review/authorization is explicit. Separate task trust if the inputs/tasks change. |
| M6-08 | Detach/return, scroll/search/follow/resize, use a second viewer | Leaving UI/CLI does not cancel; original live tail and discontinuity/reset contract are visible; only one deliberate input owner; no stale input replay or reconstructed PID capability. |
| M6-09 | Cancel a deliberately bounded long-running guest operation | Explicit cancellation confirmation; stop body work, quiesce original owned work, revoke/clear/verify inactive, remove original payload and observe matching local exit. Unknown exit retains risk and reservations. Do not kill arbitrary PIDs. |
| M6-10 | Separately approve a Docker-owner-access case if needed | Review `docker.access: sudoless` and root-equivalent consent, use a new frozen review. No automatic restart; exact old `.exited` before replacement, new session/key/account evidence before explicit check. |
| M6-11 | Explicit post-restart check | Original frozen inputs, admitted replacement session/owner/UID/key, Ansible check mode, custom tasks excluded and no authorization input/grant. Record actual limitations; check mode is not a sandbox guarantee. |
| M6-12 | Separately review a tiny custom-task case | Inspect complete frozen task plus assets; independent hash-bound trust. Confirm task has exactly the reviewed effects. Ansible can execute on the Mac: no controller-side action, secret access, login or delegated host command is approved by this baseline run. |
| M6-13 | Controlled owned-helper/channel failure, only after happy-path cleanup | Diagnostic `.error` does not release handles/reservations; surviving original proof/checkpoint may authorize cleanup only. Missing proof preserves Cleanup required and blocks replay/replacement. Scope each interruption to the owned child/channel. |
| M6-14 | Manager close/reopen/capability-loss experiment, separately approved | Reopened metadata cannot restore apply/task/terminal authority or adopt a PID. Persistent risk/holds remain if original ownership cannot be proved. Full manager restart may not retain the VM session; do not claim recovery merely because the guest is reachable. |
| M6-15 | Mac sleep/wake and crash scenarios, separately approved | Record exact lifecycle, session, helper, input-lease and cleanup outcomes. These are disruptive and remain NOT RUN without separate consent and a reviewed recovery path. No success inferred from the fake suite. |

For M6-09/13, prepare the bounded operation and interruption point in advance; its
purpose is testing cancellation, not leaving arbitrary remote descendants. Do not
begin M6-14/15 with an unresolved grant unless a concrete cleanup response has been
reviewed and approved. If safety/ownership proof is lost, stop automation, retain
the journal/hold and obtain explicit recovery instructions. A replacement worker,
new SSH connection or saved PID cannot establish original quiescence.

## Failure and abort rules

- A changed UUID/root/factory/session/owner/UID/host key, incompatible provenance or
  mismatched dependency is a refusal, not a request to regenerate credentials.
- A source edit never modifies the already frozen request. A new source selection
  gets a new preview and fresh consent. Do not replay after an unknown outcome.
- A failed or missing cleanup proof keeps Cleanup required and its lifecycle hold.
  Preserve private artifacts; do not clear risk because a window closed, a process
  printed an error or a port stopped listening.
- No real credential echo investigation by recording passwords. Use typed terminal
  state and a synthetic non-secret marker for display checks; verify hidden secret
  input manually without retaining its bytes.
- Do not forcibly delete storage, recursively erase a UUID root, edit host SSH
  defaults, accept a changed host key, or install a host dependency to continue.

## End of run

Reconcile each attempted job, including failures and cancellations. Record original
worker fencing/exit, guest-side quiescence, revoke/cache/inactive and payload proofs
separately. Where a proof is absent, record that limit and keep the risk state.

Gracefully shut down every test guest. Confirm matching `.exited` for each retained
client and no remaining owned helper/QEMU processes. Only then offer to move the
verified stopped disposable UUID roots to Trash through the manager's reviewed,
locked deletion flow. Do not recursively erase VM storage. Retaining the stopped
fixtures is also an explicit user choice.

Publish a redacted result matrix with exact source/build/runtime/package/engine
hashes, factory identity, frozen review hashes, case results and limitations. Do
not publish terminal transcripts, credentials, personal usernames/hostnames/IPs,
private keys or input contents. Keep any necessary raw diagnostic evidence local
and protected, and avoid collecting secret output at all. A source/log claim is
not a real observation; failed/unrun cases remain TO PROVE.

Milestone 6 completes only when the approved scope's required real rows and cleanup
have observed evidence and the user accepts the documented limitations. Milestone
7 signing, notarization, distribution and complete extracted-app verification are
separate. This runbook changes neither gate nor permission.
