# Private local candidate signing

The developer command is `python3 Scripts/private_signing.py`. It maintains the
private acceptance-candidate workflow previously composed by one-off scripts.
It prepares a plan, checks frozen public inputs, and runs the existing bounded
build/sign/verify engine after fresh operator confirmation. It does not provide
general release signing or remove the disposable-VM scope restriction.

## Prerequisites

Use an existing reviewed source-input packet, a matching local signed runtime,
and a successful offline inspection receipt with complete cleanup evidence.
Keep the staged public provisioning profile and DER certificate with that receipt.
The selection names the existing isolated keychain, exact signing identity/team,
and pinned local client/parser checkouts. Selecting a different runtime, profile,
keychain or source requires matching reviewed evidence; the command does not
manufacture it, discover identities, import credentials or install dependencies.

The existing engine builds with the installed macOS/Swift toolchain, signs with
`codesign`, and verifies through bounded offline capability workers. An existing
keychain may need operator preparation outside this tool. macOS may display its
secure key UI; Touch ID depends on the key's existing access controls. This command
never asks for a keychain/P12 password or changes unlock, ACL or search-list policy.

## Prepare and check

Choose a new plan name beneath an existing owner-only directory (mode `0700`).
Supply absolute paths. Keep that directory outside source packets, inspection
outputs, dependency checkouts, signing-material folders and VM storage. For example:

```sh
python3 Scripts/private_signing.py prepare \
  --selection /absolute/private/review.json \
  --plan /absolute/private/plans/candidate-001

python3 Scripts/private_signing.py check \
  --plan /absolute/private/plans/candidate-001
```

For the initial selection, `--selection` accepts the earlier
`RECEIPT_BOUND_SIGNED_CANDIDATE_REVIEW` JSON. Only `sourceInputPacket`, `sourceReview`,
`historicalOfflineReview` and `stagedMaterial` are imported. Its former approval,
output and execution fields are ignored. A prepared plan emits `selection.json`
with the versioned `PRIVATE_SIGNING_SELECTION` schema. Reuse that private file as
the selection for later plans while its reviewed inputs remain appropriate.

Preparation writes mode-`0600` `plan.json`, `selection.json`, `README.txt` and
a blanket `.gitignore` in a
new mode-`0700` directory. Review `plan.json` and `selection.json` directly for the
exact source, runtime, identity, keychain path, disposable scope and proposed
`candidate/` output. They contain private paths/selectors and must stay outside Git.
The blanket ignore protects against ordinary accidental Git staging of the whole
plan/candidate directory; it is not filesystem privacy or permission to force-add
private files. Console summaries omit selectors, paths, certificates and raw output.

`prepare` and `check` read frozen source/runtime data, historical receipt/worker
cleanup facts and staged public profile/certificate bytes. They do not inspect the
live VM root, access/stat the keychain, load native APIs, invoke processes or make
network requests. They report **CHECKED_PUBLIC_INPUTS_ONLY**, not key availability,
native readiness, certificate revocation status or permission to execute.

The plan binds the exact source/scope, historical receipt, new candidate output,
current engine digest and this operator command's separate code hash. Historical
inspection and current signing code remain independent bindings. Any code/input
change requires a newly prepared and reviewed plan; do not edit an old plan's hashes.

## Run once

Run from a real interactive terminal:

```sh
python3 Scripts/private_signing.py run \
  --plan /absolute/private/plans/candidate-001
```

The command rechecks the plan, explains all five effects (local build, offline
inspection, selected private-key use, existing secure key UI and Apple timestamps),
and requires typing `SIGN` followed by the exact full plan digest into `/dev/tty`.
Blank/incorrect input, piped stdin, `--yes`, environment variables and saved approval
fields cannot supply consent. This is a deliberate operator action; an AI/automation
must separately obtain the user's explicit approval before performing a real run.

After confirmation it rechecks again and exclusively creates/fsyncs `consumed.json`
before constructing any execution backend. This fences concurrent runs and failures,
including a failure before the first worker starts. Every attempt is one-shot. A
new attempt requires a new plan/output and fresh confirmation; never remove the
consumed marker, reuse partial output or replay an earlier one-off script.

The existing engine retains its exact command/environment policy, pinned local
build, child/seal/outer signing order, shared deadline, live stream caps, held-group
cleanup, fixed safe failure diagnostics and no-network verification. Only the
selected `codesign` steps can use the signing key and request Apple timestamps.
The wrapper adds no credential export/import, automatic unlock, notarization,
publishing, install, SSH/Ansible or app/runtime/VM execution.

Ctrl-C/TERM after consent requests bounded cancellation. If cleanup is uncertain,
original unresolved handles remain held and the CLI stays alive with a STOP notice.
Do not force-exit it, adopt saved PIDs, clear risk or retry automatically; review the
private evidence and an explicit recovery procedure first.

## Provisioning resource admission

The frozen resource reference can contain its former detached signature block.
The engine admits that complete known four-file block (or none), verifies resource
bytes against the unchanged package lock, and requires every remaining payload and
wrapper file to match the fresh build exactly. It excludes those records only from
the reference comparison; built signatures are rejected rather than filtered.
Generic inventory rules and frozen inputs are unchanged. Before outer signing and
at staged/archive-roundtrip verification, the resource tree must still match the
admitted payload. Child digest sealing, outer signature/static checks and exact
archive comparison remain required. Old signature records provide no new execution
or cryptographic authority. See the [fake fixtures and fresh review](DevVMMilestone6Runbook.md#resource-payload-admission--fake-fixtures-and-fresh-review-5-november-2026).

## Results and limitations

`attempt.json` records a fixed result/status and bounded command/native cleanup
evidence even on failure. It never includes raw exception/child-output text.
The engine retains more detailed fixed failure evidence under `candidate/`.
A success also creates `candidate/signer-result.json`, the private app and
`Private-Candidate-SIGNED-NOT-NOTARIZED.zip`, with archive roundtrip/static signature
verification. A public-input check or successful signing alone does not complete
original-Mac, loaded-child or disposable-guest acceptance. Product approval remains
unchanged; signing, notarization and guest execution are separate decisions.

The operator script's independent binding leaves the engine's implementation-file
list unchanged, so adding this command does not invalidate a concurrent historical
reviewed run. Existing private reviews, consumed markers, artifacts and frozen pins
are never migrated or rewritten automatically.

## Validation

**VERIFIED — fake/local:** `make test-private-signing-cli` covers preparation/check,
private modes, approval-data exclusion, strict confirmation, tampered code/inputs,
old cleanup rejection, credential-content denial, consumed/concurrent attempts,
safe errors, cancellation and a complete injected fake engine roundtrip. Native
composition is tested with mocked constructors; no signing/key/native API runs.
The test also verifies that the operator binding does not change the engine digest.

**TO PROVE:** the new terminal entry point's real key/UI/timestamp behavior and any
real candidate acceptance. Implementation/testing of this command does not execute
it on existing real selections or transfer an earlier approval to a new plan.

The implementation passes **21 new operator tests** and the full audited script
suite: **277 passed, five signing/PKCS12 cases skipped (282 discovered)**. The audit
records only local Git/Python child processes and no native-library attempts.
An initial full-suite run inherited umask `077`, which invalidated an existing
fixture's intended `0755` directory. Rerunning with the fixture suite's expected
umask `022` passes; both attempts' local test evidence is retained. `git diff
--check` and the operator's `--help` also pass. The running engine's seventeen-file
digest is unchanged. No real selection, inspection, signing, key access, Apple
request, install or VM action is performed for this implementation task.

### First real maintained run — 5 November 2026

**LATEST USER CLARIFICATION:** the operator says “I missed the prompt.” This
supports a missed secure-UI response as the explanation for the signing timeout;
it does not independently prove key use or timestamp success/failure. Keep the
earlier completed-dialog report and automated evidence as historical records;
exact dialog type/timing is not reconstructed. The plan remains consumed.

**USER-REPORTED FOLLOW-UP:** the operator reports completing a macOS secure-key/
keychain dialog. The exact dialog type and timing relative to the timeout are
unknown; this establishes neither selected-key use nor timestamp success or the
wait cause. Historical automated evidence stays unchanged, with the report saved
separately. No additional run, native check or key operation follows this reply.

The explicitly approved `b3171b0` / companion `9d3b4b6` plan runs through this
CLI's real exact-plan terminal confirmation, recheck, durable consumption and
default backend. Frozen preparation, 23 runtime static checks, public inputs/
dependencies, release build, compiled scope and corrected resource assembly pass.
The first selected-key child signing command reaches its 120-second limit; the
supervisor kills/reaps it, with no pending handles. Total audited elapsed is
715.494 seconds, CLI exit 1; `attempt.json` is STOPPED_NO_RETRY. All 43 recorded
command/native roots are absent in a bounded cleanup snapshot. All 8,713 prior
artifact entries/pins remain unchanged; consumed/attempt/output evidence is private.

The storage-helper bytes equal their compiled input. Observed stderr (274 bytes)
is incomplete and not retained raw. Actual private-key use, secure UI display/
response and Apple timestamp outcome are unestablished; no specific wait cause is
inferred. No other signing/final app validation/seal/archive or success receipt is
reached. No automatic unlock/relock, key import/export/enumeration, ACL/search-list
change, scope recapture, notarization, SSH/Ansible, install, app/runtime or VM action.
Lock state is not re-queried. Preserve this consumed plan and failed output; collect
operator UI observations and review key readiness/timestamp connectivity before a
new plan/output with fresh approval. See the [full result](DevVMMilestone6Runbook.md#first-maintained-operator-run--signing-timeout-5-november-2026).

### Bounded read-only follow-up — 5 November 2026

The operator clarifies that the prompt was missed. The 120-second signing timer
includes secure-UI waiting; this supports a missed-prompt explanation without
establishing an Apple timestamp fault. Under separate read-only authorization,
one network/file-write-denied worker checks only the named keychain's status and
staged public certificate metadata, with optional UI disabled. It reports status
7/unlocked twice, matching public selector/digest/date validity and reviewed-profile
membership/policy. It completes in 0.218 seconds under a 15-second/4-KiB-stream
limit; all references/owned process handles clean up and the recorded PID is absent.

All 13,565 prior artifact entries/pins and failed/consumed records are preserved;
keychain metadata and unlocked state stay as found. No private-key/identity/item
query, trust/signing/timestamp call, automatic unlock/relock or permission change
occurs. This proves container/public readiness only; private-key presence, matching
association/ACL, Touch ID and signing/timestamps remain untested. No new plan or
retry is created; any new run requires a new plan/output, fresh approval and an
attended prompt. See the [read-only diagnosis](DevVMMilestone6Runbook.md#read-only-signing-readiness-diagnosis--5-november-2026).
