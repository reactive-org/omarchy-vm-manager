# Milestone 6 disposable-guest acceptance runbook

Status: **PREPARED / NOT RUN**. This document authorizes no operation.
Prepared 3 November 2026 for the native Swift provisioning integration.

The ordinary product execution gate remains false. A separate private scoped
candidate has been prepared offline; see [its evidence and limits](#private-scoped-candidate-preparation).
The full-screen UI acceptance
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
| Profiles | New disposable UUID(s), names, manager-owned root paths and stopped metadata-only creation receipts; original root device/inode and ownership-marker SHA-256 |
| Approval | Concrete authorization identifying these newly created disposable roots; same reviewed identity pins in the manager/helper candidate, never fresh observations on each process launch |
| Resources | Explicit manager choices within the current host budget; suggested starting point 4 GiB, 4 cores, 64 GiB sparse disk, one guest at a time |
| Networking | NAT only, newly reserved unprivileged loopback SSH port per UUID |
| Account | Dedicated non-personal test account; UID must be observed through pinned authenticated SSH, never assumed to be 1000 |
| Inputs | Exact source snapshot, generated manifest if applicable, plan/input/engine hashes and all referenced files/modes |
| Consent | Exact apply review; persistent sudo grant until confirmed cleanup; separate Docker root-equivalent or custom-task trust only for opted-in subcases |
| Recovery | Original helper ownership/checkpoint capture, owned local-process exit criteria and a reviewed response if capabilities are lost |
| Cleanup | Matching `.exited`, no remaining owned processes; offer verified stopped-root Trash afterward |

**Execution blockers:** the current build cannot submit real work. The scoped
admission mechanism below is implemented and tested with fakes, but no actual
approval or operational candidate is installed. A separately reviewed acceptance
candidate must admit only the approved disposable UUID/root scope in both manager
and helper before enabling an operational path. A blanket
`enabled = true`, environment switch, altered readiness report or saved receipt is
not a scoped acceptance mechanism. Keep that restriction covered by fake tests;
leave the ordinary product build disabled. Verify real helper signing and
loaded-child/package admission for the selected build; do not weaken provenance
to get a job to launch. Developer ID/notarization credentials, permission grants,
factory downloads and UI takeover require their own authorization when needed.

### Implemented admission boundary — fake/local evidence only

`ProvisioningProductExecution.disposableApproval` is currently `nil`, so product
execution is false and its policy is disabled. There is no independent Boolean to
flip. A future private candidate must embed the original reviewed pins through
trusted composition in both manager and helper; no CLI flag, environment variable,
manifest, registry/journal entry, readiness report or received IPC field supplies
an approval. The fixture policy is available only to trusted internal test code.

The approval contains a bounded explicit set of UUID/root/device/inode/marker-hash
tuples. It requires private owned directories in the manager UUID namespace and
strict ownership/storage markers, refuses retained POC IDs, symlinks, replaced
roots, changed markers or unsafe modes, and retains directory descriptors against
inode reuse. Filesystem identity handles macOS's `/tmp` and `/private/tmp` aliases;
an arbitrary symbolic link is still refused. The manager additionally verifies
the root against its own profile namespace and live session. The helper checks
its own local approval against delivered, validated transport, before constructing
a runner and before/after reverse RPC at preparation/command/invocation boundaries.
Input claim/send/resize also recheck approval; loss releases input ownership while
read-only output can remain available. Cleanup/recovery never bypasses root scope.

The manager rechecks preparation, transport, lifecycle leases and restart, including
the interval after old `.exited` and before replacement start. A compiled scoped
candidate also checks ordinary start before runtime work, even before service
installation or after coordinator close. These checks add no guest capability:
package/signature admission, fresh authenticated session/key/owner/UID, original
worker fencing, task/sudo/Docker consent and cleanup proofs remain required.

The constructor does not create roots or determine whether an existing VM is
disposable. Before an operational candidate, separately authorize a new disposable
profile/root preparation without booting, review its original identity values and
record the explicit approval. An owned marker/name alone is not that approval.
Do not recapture a replacement directory's identity to make an old review pass.
No real root or approval values have been installed by these tests. Actual
cross-process signed-candidate/guest operation remains TO PROVE.

The dedicated fake/local admission suite passes 12 Swift test functions, including
invalid/stale root matrices, independent helper refusal, RPC races, restart,
recovery and cross-viewer input revocation. The full manager run passes 440 Swift
functions in 57 suites, 52 script tests, local signed-helper fixtures and 56 isolated
screen checks. Release compilation passes without real signing credentials; these
are implementation checks, not results for any real row below.

No host install is a fallback. Homebrew and a compatible, matching Homebrew
`ansible-playbook`/`ansible-inventory` pair must already satisfy the existing report
and pinned transport policy. A missing/wrapped/mismatched/replaced dependency stops
this run. Do not uninstall or replace tools to manufacture a failure case; use the
existing fake dependency suite for those cases.

## Private scoped candidate preparation

**VERIFIED — offline/local, 3 November 2026:** a private debug candidate was built
from commit `1cb2bdd929ac147f15b4a682291418fa699372ba` plus an exact six-file overlay.
The new stopped disposable profile/root has an original preparation receipt. Its
UUID, absolute root, device/inode and ownership-marker hash are compiled into the
same Core composition in manager and helper. The private scope, receipts, overlay,
base source archive, app inventory, binary/signature hashes and reports remain in
an ignored private artifact directory, not this repository's tracked sources.
No private identifiers or approval pins are recorded in this tracked documentation.

**DESIGN DECISION:** candidate preparation is distinct from guest-run approval.
The main worktree keeps `disposableApproval = nil`. Only the separate snapshot
references the original constants; it adds no file/environment/CLI/IPC approval
loader. A missing/changed original scope terminates private scope initialization
instead of returning nil and falling back to ordinary composition. The actual root
was not modified for fault tests. Fail-closed initialization is reviewed source;
read-only constructor probes independently refuse wrong device/inode/marker pins.

The private read-only inspection entrypoint runs before AppModel, registry and
worker dispatch. Both packaged components validate identical scope digests and
original pins, refuse wrong UUID/path/pins and admit their exact package/resources.
Their production same-application-team helper signing check correctly refuses the
ad-hoc app/helper. That policy is unchanged; no fixture signing policy substitutes
for it. Existing kit signatures are preserved byte-for-byte, the runtime archive
and inventory match the lock, and local app signatures pass deep/strict verification.
This establishes package integrity, not operational or loaded-child acceptance.

The candidate was copied into its private retained location, compared byte-for-byte
and inspected again there. Thirteen offline checks are recorded. A probe linked
against its actual Core library uses only fake runtimes and temporary metadata:
other UUIDs, a same-UUID different namespace and retained POC IDs are refused before
runtime start, including before coordinator installation, with a permissive fixture
coordinator and after coordinator close. All fake runtime start counts remain zero.
The ordinary admission suite also passes twelve fake/local tests. The real root,
its five metadata files and the complete registry remain unchanged.

**TO PROVE / BLOCKED:** production signing and loaded-child admission; independently
approved managed SSH/owner configuration (currently disabled in the stopped profile);
an actual available factory and fresh Homebrew Ansible readiness; exact frozen
inputs and relevant privilege/task consent; all guest execution/TTY/cleanup/restart/
check/failure rows. No VM launch, real transport, tool install, credentials, normal
UI entrypoint or operational worker activation occurred. Real acceptance stays
NOT_RUN. The package verifier's `executionEnabled: false` describes its offline
command contract; the private inspection separately reports `scopeConfigured: true`.
Neither report supplies guest-run consent or bypasses signing/session/tool checks.

## Offline signing and readiness audit

**VERIFIED — static/local, 3 November 2026:** nineteen checks pass; one factory-byte
check remains NOT_VERIFIED because OS file access was refused. Candidate/evidence
hashes, exact package/kit inventories, deep/strict local signatures, original
scope/root/registry and reconstructed private overlay remain consistent. The base
archive also matches an independent Git archive of its recorded source commit.
Only static `codesign` display/verification and local Git archive/temporary patch
reconstruction run; no candidate binary or installed provisioning tool is executed.
The audit and its detailed observations remain private/ignored.

**SIGNING BLOCKERS:** the app/helper are ad-hoc signed, lack a Team ID, hardened
runtime/timestamp and the embedded protected-Keychain profile required by the
supported signed-prerelease path. The production same-team gate remains intact.
Promotion requires a signed-prerelease rebuild carrying the original scope, signed
runtime lock/origin, `RuntimePin`/`SignedBuildPin`, approved profile/entitlements and
post-sign executable seal. Child helpers must retain their restricted credential
scope. Static signature integrity establishes none of those release capabilities.

**PRIVATE COUPLING / SOURCE INFERENCE:** the existing tag workflow checks out the
ordinary repository, then publishes prerelease and failure-diagnostic archives.
It neither carries the ignored scope overlay nor provides the required private
artifact handling. A reviewed nonpublishing signing handoff is needed before using
credentials; no signing workflow was invoked or implemented by this audit. A
remote signer must retain the original constants, not recapture substitute root
identities. Final scope checks belong against the original root on the approved Mac.

**READINESS:** both Homebrew Ansible paths resolve to the same formula directory.
Static distribution metadata reports Core 2.21.5, consistent with the required
2.21.x family. CLI versions, inventory/syntax self-checks and fresh transport
admission remain UNPROVEN; no brew/Ansible/SSH/gh command ran. The expected compressed
factory has file metadata in the managed cache, but its contents could not be read,
including outside the tool sandbox. Its checksum is NOT_VERIFIED. No macOS
permission was granted, no image downloaded/copied/decompressed and no guest disk
created. SSH/owner/setup selection are still absent from the disposable profile.

**TO PROVE:** seven signing/readiness gates remain: same-team code admission;
signed runtime/profile/rebuild composition; private signing handoff; SSH/owner/input
configuration; fresh actual CLI readiness; loaded-child and real guest results;
and verified factory bytes. No signing identity enumeration, Keychain access,
credential use, signing, notarization/Gatekeeper request, network request, release
publication, normal UI or VM operation occurred. Ordinary execution remains disabled
and all real guest rows remain NOT_RUN. The next safe development task is to prepare
the private handoff and its checks using fake/local fixtures; actual signing,
permission grants, metadata/account changes, tool execution and guest runs need
their own explicit authorization.

## Private signing and packaging handoff — fake/local path

**IMPLEMENTED — 3 November 2026:** `Scripts/private_provisioning_package.py` freezes
a reviewed private candidate into a self-contained signing request. The CLI exposes
`prepare` only. It never signs, compiles, uploads, starts an app/guest, probes tools,
reads credentials or visits the root named by the scope. No real-signer adapter,
credential entrypoint or CI workflow is installed by this slice. This is developer
packaging tooling using existing Python build tools, not a manager Python runtime.

The caller supplies a private mode-0600 identity file with `candidateSHA256` and
`scopeSHA256`, taken from the reviewed audit. These are build-input bindings, not
guest/signing consent or an application approval loader. Candidate/receipt/scope,
source archive/overlay, exact runtime/resource inventories and expected profile pin
must match before copying. Original constants are copied from the recorded inputs;
they are never recaptured from a replacement filesystem root. The real handoff
contains 101 frozen input files and an independently retainable request digest.

```sh
make private-provisioning-handoff \
  PRIVATE_CANDIDATE=/absolute/private/candidate \
  PRIVATE_OUTPUT=/absolute/private/new-handoff \
  PRIVATE_IDENTITY=/absolute/private/reviewed-identity.json
make test-private-provisioning-package
```

The destination must be new, below an owned mode-0700 parent, outside the source,
manager UUID storage and standard release/upload directories. Checks include
case-insensitive namespace aliases. Tag/release contexts are refused. Inputs,
request and copied runtime/resources stay private; links, changed data, unsafe
archives, duplicate JSON keys and guest disk-image payloads are refused. Partial
captures remain private with a failure marker. Failed or changed requests cannot
be reused; there is no automatic resume/replay or source/output overwrite.

**VERIFIED — fake/local:** the complete simulation orders profile validation,
signed-runtime provenance, signed-prerelease rebuild with the same manager/helper
scope, child signatures, post-sign helper seal, outer signature, verification,
private ZIP, extraction and verification again. It reuses existing signed-runtime
origin/payload, protected-profile entitlement and provisioning seal validators.
Frozen inputs are revalidated across callbacks; signature checks may not mutate
signed bytes. Late runtime/profile/resource/child/scope changes, wrong team/origin/
build pins, child Keychain entitlements and archive tampering are refused.

The runner accepts synthetic fixtures and an injected fake signer only. Its code
and signatures are explicitly non-Mach-O/simulated; outputs are named and labelled
SIMULATION_ONLY, with `productionSigningVerified: false` and no launch authority.
It refuses the actual candidate's request before invoking a fake signer. There is
no plugin/shell/publisher backend or environment switch to select real signing.
The checked fake build receipt is not proof of a real Swift compilation/signature.

Eighteen new test functions (including a 22-case rejection matrix) and the complete
79-test script suite pass. A synthetic ZIP roundtrip is retained privately; guarded
process/network/credential hooks report zero calls. The actual handoff, prior
candidate and original root/registry remain private and unchanged. No shared Swift
source, product approval gate, signature policy or public release workflow changes.

**TO PROVE:** a separately authorized real-signer/private execution adapter,
reconstruction and actual signed-prerelease compilation, certificate/profile/code
verification, notarization/loaded-child admission and original-Mac scope checks.
Production signing remains unavailable here. The prior OS-denied factory checksum,
actual CLI checks, SSH/owner/input configuration and all real guest rows remain
pending. Guest acceptance remains NOT_RUN. Keep the real credential/signing step
and all guest operations behind their existing separate authorization.

## Private signer adapter — fake process runners, 4 November 2026

The developer-only [adapter](../Scripts/private_provisioning_signer.py) connects
the frozen request to the signed-prerelease build and SDK signing commands. This
section extends the earlier synthetic packaging path; it does not authorize its
execution with real tools or credentials. There is no signing CLI, publishing
method, workflow upload, credential importer, keychain unlock or identity search.
The default system runner refuses before reading signing material or creating a
job. An explicitly authorized trusted caller must bind the exact request, original
scope and material selection in memory and admit each effect. Neither a request
file nor environment variable can provide that authorization. Signing includes
secure timestamp requests and therefore needs separate approval before real use.

Required future local inputs are the pinned provisioning profile, a named identity
in an already prepared isolated keychain, a signed runtime bundle/archive/lock with
the reviewed development-kit origin, and clean local client/parser checkouts at
their recorded commits. No runtime download or QEMU rebuild is introduced. Runtime
signing stays with the upstream kit pipeline. The adapter checks its signed origin,
payload inventory and archive digest, then requests upstream signature-only
verification; it never requests notarization. Private keychain bytes are not read
by the adapter, and it never changes the user's keychain search list.

The adapter reconstructs the source archive and exact six-file overlay in a fresh
private job. Its only source projections are the signed runtime/team/origin pins
and an inspection branch for the signed build. The original scope-definition
prefix and operational composition stay byte-for-byte intact; invalid scope keeps
its fail-closed behavior. Existing tracked source plus newly added source files
are checked for drift. Private local clones, pinned SwiftPM workspace state and
`--disable-automatic-resolution` supply build inputs. The existing
`make build-signed` recipe runs with only its global `prepare-source` prerequisite
skipped; the pinned provisioning source is prepared locally first. Source and local
dependency revision/cleanliness checks surround the build. No remote clone/fetch
command is generated. Actual compiler/SwiftPM offline behavior remains TO PROVE.

Fresh app assembly copies checked resources, the signed kit, profile and built
components. Child signatures precede the provisioning distribution seal; outer
signing follows it. Verification requires deep/strict signatures, matching team,
Developer ID leaf authority, hardened runtime, secure timestamps, exact profile
and entitlement scope, the profile-authorized public leaf certificate, retained
scope markers and the app's bundle-only diagnostic contract. Verification may not
change the app or source. ZIP extraction must retain the full inventory and code
identities, and verification runs again. The adapter never starts a helper worker
or invokes the original-Mac scope inspector on a remote signing host.

Run the safe fixture suite with:

```sh
make test-private-provisioning-signer
```

**VERIFIED — fake processes/local fixtures:** twelve new test functions include
33 SDK/build/sign/verification failure variants, four runtime origin/payload cases,
authorization and effect refusal, source/dependency drift, immutable handoff checks,
private failures and archive roundtrip. SDK metadata includes the actual
`CodeDirectory ... flags=...` form and multiple Authority chain lines. Mocked system
dispatch verifies explicit environment, separate process group and timeout kill/
wait behavior; no real child or process group is used. All **91 script tests** pass.
Fixture bytes have a Mach-O header solely to exercise classification and are not
executable programs or genuine signatures. Results say `FAKE_RUNNER_ONLY`,
`productionCryptographyObserved: false`, original-Mac validation pending, loaded
child NOT_RUN, guest authority false and publication forbidden. Private fixture
artifacts do not replace the actual frozen candidate or its pins.

**TO PROVE / NEXT GATE:** approved real signing material and a local signed runtime,
actual SDK/compiler/profile validation, notarization, unchanged original-Mac root
and scope observation, and loaded-child admission. The system adapter has not been
run on the actual handoff. No real signing, credentials, Apple-service request,
host install, SSH/Ansible, normal UI, VM launch or disk operation occurred. Product
approval remains nil; factory access, fresh tool readiness, SSH/owner setup and
every real guest row remain pending. Actual signing and guest execution require
their separate explicit approvals.

## Real signed-candidate gate preparation — 4 November 2026

**PREPARED, NOT READY, NOT AUTHORIZED:** a private review packet now binds the
actual retained candidate, frozen request, original scope, source archive/overlay
and committed signer adapter. Exact digests and canonical local source paths stay
in the ignored mode-0700 packet; its JSON files are mode 0600. This is a review
record, not `ExecutionAuthorization`, a material loader or a guest approval. It
contains no credential bytes. All approvals are explicitly NOT_GRANTED; unselected
material fields are null. No credential locations were searched or opened.

**VERIFIED — read-only local:** the actual candidate inventory and reviewed digest
match; the frozen request re-admits with its previously recorded independent
digest. The existing patched client and TOMLDecoder checkouts are clean at the
exact revisions required by the archived source. These observations use local Git
only, with hooks/fsmonitor/global configuration disabled and optional index locks
off. They are observations to repeat before execution, not signing readiness.
No target VM root/registry is visited and no original identity pin is recaptured.
No accepted signed runtime is selected; the reviewed Config/build/artifact locations
establish no eligible real signed lock. This is not a whole-machine search.

The gate requires these exact input relationships:

| Input | Required selection and evidence | Current state |
| --- | --- | --- |
| Frozen candidate | Previously reviewed candidate/request/scope digests and six-file overlay; preserve original UUID/root/device/inode/marker constants | Re-admitted privately; no scope change |
| Runtime | Local `TryOmarchyKit.bundle`, `TryOmarchyKit.zip`, `TryOmarchySignedRuntime.lock.json` together in one owned private directory | No real signed artifact selected; ad-hoc candidate and fake fixtures are ineligible |
| Runtime origin | `sourceLockSHA256` equals the exact frozen development-lock bytes; `sourceKitSHA256` equals that lock's kit digest; capabilities, patched commit and immutable payload remain exact | Required origin/inventory copied into private packet; signed digests remain null |
| Runtime signatures | Selected app team, valid Developer ID signatures, hardened runtime/timestamps and upstream signature-only validation; valid versioned prerelease artifact tag | Not inspected; not established |
| Client/parser sources | Canonical nonsymlink paths resolving to the exact archived patch/parser revisions; clean before/after build | Both observed clean and matching; revalidation required |
| Signing identity | Explicit `Developer ID Application: … (TEAMID)` identity, ten-character team shared by runtime/app/children, available in the explicitly selected isolated keychain | Team and identity unselected; no identity enumeration |
| Isolated keychain | Explicit canonical absolute path; owned regular mode-0600 single-link file below an owned mode-0700 parent; already prepared/unlocked only after separate authorization | Path unselected; no Keychain access |
| Provisioning profile | Explicit canonical local file matching the profile digest frozen from `Config/TouchIDProfile.lock.json`; valid macOS Developer ID distribution profile for the exact selected team and `dev.omarchy.vm-manager`; unexpired and authorizes the actual signing leaf certificate | Path unselected; profile bytes/expiry/certificates not read or decoded |
| Entitlements | Only the exact App ID/team restricted entitlements on the manager; no shared Keychain groups/debug entitlement; children retain empty app entitlements | Repository contract reviewed; real signatures unproven |
| Build/output | Existing Swift 6/macOS 15+ build toolchain; exact source projections; fresh private output outside VM/release/source namespaces | Tool execution not probed; proposed unused output recorded privately |

The required runtime is the **signed variant of the frozen patched development
kit**, not a newer kit, the stock reference, the current ad-hoc bundle or a fake
artifact. The packet records the exact original lock/kit/patch/parser bindings,
capabilities and inventory without putting their pins in Git. The signed runtime's
new archive/lock hashes, team and artifact tag can only be recorded after a real
local artifact is explicitly selected and admitted. No replacement root or new
origin is inferred to fill a missing field.

**Runtime acquisition boundary:** the adapter consumes an already signed local
runtime; it does not create one. If none is available, prepare a separate reviewed
upstream signing-only job against the exact source kit, with a new private output.
The inspected upstream kit builder accepts an identity but exposes no explicit
keychain selector; its isolated-keychain handling must be resolved before that job
is approved. Do not substitute global keychain search-list changes. The ordinary
`make signed-prerelease`/tag workflow imports credentials, performs notarization
and publishes/retains archives, so it is not this private gate. The upstream
builder also expects fresh output and rebuilds its pinned networking components;
its execution needs a separate review, not an assumption that app-signing approval
covers it. No upstream build/sign/download occurred during gate preparation.

Approvals must describe concrete selected inputs, rather than grant blanket
permission to use whatever signing assets are found:

1. **Select and inspect materials:** supply nonsecret local artifact/profile/
   isolated-keychain paths and team/identity selectors privately. Then separately
   approve bounded validation of those named inputs. No system-wide identity search,
   private-key extraction, credential import, unlock or password collection is
   implied. If isolated-keychain preparation is required, approve it separately
   or have the operator prepare it. Do not paste P12 data, passwords or API keys
   into a request, shell history, repository, transcript or gate packet.
2. **Produce a runtime, only if missing:** separately approve the reviewed upstream
   operation and its exact local source, identity/keychain handling, timestamps and
   fresh private output. No notarization, publication, host install, guest launch
   or modification of the retained source kit is included.
3. **Build/sign the private app:** once real material selections and validation
   evidence are complete, freeze their exact binding and review a trusted one-shot
   caller for `Adapter.run`. Explicitly approve the request/scope/material binding,
   local build/inspect effects, selected signing key use and **Apple secure timestamp
   requests**. The adapter has no signing CLI and the packet must never mint an
   authorization object. The proposed output must still be new. Keep all outputs
   and fixed failure records private; do not replay or fall back after failure.
4. **Validate on the original Mac:** separately approve read-only original-scope
   inspection of the signed result. Static same-team checks do not establish the
   loaded child's code identity. A concrete non-activating owned-helper validation
   harness must be reviewed before a loaded-child experiment; bundle-only
   diagnostics must not be represented as that experiment.
5. **Notarize, only when requested:** approve the exact archive digest, Apple
   submission and separate notary credentials. The current adapter stops at
   `SIGNED_STATIC_CHECKS_ONLY` and a signed/not-notarized ZIP. It neither needs nor
   accepts an Apple API key, notary credential profile or P12 import password for
   app signing. Notarization/upload is not included in timestamp approval.
6. **Run guest acceptance later:** separately approve disposable-only factory-byte
   access/verification, fresh tool checks, owner/managed SSH and exact setup inputs/
   consents, followed by scoped launches and the acceptance matrix. Signing approval
   grants none of these operations or host installs. Factory access remains
   unresolved and every real guest row remains NOT_RUN.

**NEXT ACTION:** choose the real local signed-runtime artifact and nonsecret
team/identity/profile/isolated-keychain selectors. Those missing selections prevent
a concrete request to execute signing today. This preparation requests no approval
and performs no signing, credential access, Apple/network request, SDK command,
SSH/Ansible, install, normal UI, VM launch or disk operation. Product approval stays
nil. Actual compiler/profile/cryptographic/notarization/original-Mac/loaded-child
behavior remains TO PROVE. Documentation changes are separate from executable
policy; the committed adapter and its existing 91-test evidence are unchanged.

## Local signed-runtime discovery — 4 November 2026

**VERIFIED — local files/public metadata:** extending the search to the primary
checkout finds the existing published `v0.9.4-dev.1` signed runtime. Its lock matches
the frozen source-lock bytes, source-kit digest, patch/capability and immutable
payload requirements. Its ZIP digest/inventory pass the existing pure archive
validator, and three existing extracted bundle copies match the signed inventory.
The inspected pre-stapling extraction differs and is not selected. Both local
`v0.10.0` candidate directories carry a different origin and are refused for this
frozen candidate; changing the ordinary Config pin would not make them eligible.

The matching bundle, exact lock and ZIP are copied into a new ignored mode-0700
runtime directory, with the archive named `TryOmarchyKit.zip` as the adapter expects.
The staged archive/inventory are checked again. No original artifact, VM root,
registry, frozen gate/request or compiled product source is modified. Actual
paths/digests and per-candidate dispositions remain in the private discovery
addendum; this does not mint an execution authorization or material binding.

The helper's existing embedded CMS public certificate supplies the nonsecret
Developer ID Application identity and matching team. Local OpenSSL only parses
supplied public certificates; no signing, identity/keychain query, private-key
operation, trust/network check or Apple request is made. The published verification
receipt also refers to the same archive digest. These are public metadata and
historical evidence, not fresh SDK signature/notarization admission or proof that
the signing private key exists on this Mac.

Two embedded provisioning-profile file candidates are located in existing signed
app extractions. Only names and file metadata are observed; contents, digest,
expiry, authorized certificates and entitlements remain uninspected. The primary
source's public profile pin matches the frozen pin, which does not prove that a
located profile's bytes match it. Those source paths are not directly suitable
for the adapter's private material directory: bounded validation and private
staging still need authorization. No isolated keychain is selected, searched or
queried, and neither local key availability nor unlocked state is established.
Do not substitute login/system keychains or infer key access from a public cert.

**NEXT / TO PROVE:** choose an explicit isolated-keychain path privately, then
review bounded validation of the named runtime/profile material and private
profile staging. Runtime signature/team/hardened/timestamp/network-pin checks and
profile pin/expiry/certificate admission remain unrun. No new runtime signing is
needed if this existing artifact passes that admission. App build/key use/secure
timestamps, original-Mac/loaded-child validation, optional notarization and guest
acceptance retain their separate approvals. The original gate remains unchanged
with all approvals NOT_GRANTED; the addendum records discovery only. Downloads
listing is OS-denied and skipped without permission grants or escalation. No
credentials, signing/SDK tools, Apple/network requests, SSH/Ansible, installs,
normal UI, VM launch or disk-image operation occurs. Product approval stays nil
and real guest acceptance stays NOT_RUN.

## After merging main — 4 November 2026

The provisioning branch now integrates latest main `741be20`, confirmed using
credential-free HTTPS. Ordinary source/runtime pins and guest Touch ID integration
follow main. Seven content conflicts are reconciled without dropping Setup review,
helper packaging, native loading behavior, Touch ID configuration or either
validation history. A new fake regression creates metadata with Touch ID and the
same frozen Setup review, then roundtrips both profile fields together.

Offline debug build, 300 selected Swift tests and 109 Python tests pass; five
software-signing/PKCS12 Python cases are deliberately skipped. Eleven local socket
functions need a retry outside the tool sandbox; all pass with disposable fixture
channels. Offscreen Setup/New VM acceptance passes 100 checks without a visible
window or runtime start. No native SSH, ad-hoc signed-bundle fixture or real
credential/signing check is run. These are selected offline/fake checks only.
Release and `SIGNED_PRERELEASE` compile-policy checks also pass two tests per mode
without an identity or signing command; SDK dSYM generation needs a retry outside
the tool sandbox. This does not establish a real signed candidate.

**Frozen inputs remain historical and unchanged:** a before/after inventory proves
all 930 private artifact entries retain exact bytes, modes and link targets. This
includes original scope pins, source archive/overlay, candidate, frozen request/
gate and discovered/staged runtime. No original VM root or registry is read or
modified. Existing approvals stay ungranted and product provisioning approval nil.

The existing candidate and its matching discovered runtime continue to describe
their **pre-merge source**. They are not a signed candidate for this integrated
tree. Preserve them as evidence; prepare a fresh reviewed source/runtime binding
before any integrated signing attempt. Do not rewrite a frozen request, relabel
an old archive, repin its runtime, or recapture VM identity to imply compatibility.
Any new candidate or signing/material/guest operation retains its separate scope
and approval requirements. No signing, credential access, Apple requests,
SSH/Ansible, installs, normal UI, image operation or VM launch occurs in this merge.

## Integrated candidate inputs for 7e46241 — 4 November 2026

**PREPARED INPUTS ONLY:** a fresh private packet freezes the exact Git archive of
`7e46241`, its runtime/package/profile requirements and a reviewed six-file scoped
overlay. The overlay preserves the existing inspection hooks, offline package
flags and private composition while keeping main's integrated code and metadata.
Applying it to a second fresh archive produces the exact same source inventory.
No application is built, assembled, signed, installed or run for this preparation.
The ordinary repository's provisioning approval remains nil.

**Pins preserved:** original scope JSON, historical scope `sourceCommit`, UUID/root/
device/inode/marker pins, receipt and the complete scope-definition Swift source
are copied byte-for-byte. New source identity is independently bound to `7e46241`.
Do not rewrite the old scope hash to make its historical source commit equal this
new source. The prior candidate, request, signing gate, discovery and staged runtime
remain unchanged; no target root/registry is observed or recaptured. Exact hashes,
selectors, source paths and the new packet remain ignored/private.

**Matching local runtime:** the retained `v0.11.0-dev.3` release directory contains
the exact reused runtime whose lock still declares `v0.11.0-dev.2`. Its original
source-lock bytes, source-kit digest, patched revision, capabilities and immutable
payload match this integrated source. The development archive/bundle, signed ZIP
digest/inventory and extracted signed bundle are checked locally. Exact signed
bundle/ZIP/lock copies are staged in the adapter's expected runtime layout, without
relabelling the lock or changing any signature bytes. These are file/provenance
checks; fresh SDK signature/notarization/network-pin admission is not performed.

The gate is a **source-only review record**, with no fabricated app inventory,
legacy `request.json` or execution authorization. The older app-based preparation
API requires its source commit to equal the historical scope commit, which would
change a preserved pin here. Therefore the packet uses an explicit distinct input
kind and binds the two identities separately. The existing signer refuses it
before runner authorization or material IO. A reviewed source-only admission/
caller update is needed before real consumption; this preparation changes no
executable admission policy. Missing app/profile/keychain/loaded-child evidence is
recorded rather than simulated into a real receipt.

**VERIFIED — offline/fake:** 22 input consistency and mutation-refusal checks pass,
including wrong source/scope/archive/runtime hashes, authorization flags, legacy
mis-admission and preservation of the original request. Process and network hooks
are forbidden in those checks. All 12 existing fake process-runner signer tests
also pass. Original private artifact entries retain exact bytes, modes and links;
new packet permissions are private. No shared or product code changes are made.

**NEXT / TO PROVE:** explicit source-only input admission binding the new source to
the unchanged historical scope; named profile/isolated-keychain selection and
separately approved validation; actual compilation and signed app/profile/loaded-
child evidence. A compatible signed runtime is now available locally, so new
runtime signing is unnecessary if it passes later admission. All signing/key-use/
timestamp and later guest approvals remain NOT_GRANTED. No credential/profile
bytes, signing, Apple/network request, SSH/Ansible, install, image, UI or VM operation
occurs, and every real guest acceptance row stays NOT_RUN.

## Version 2 source-only admission and caller — 4 November 2026

**IMPLEMENTED — developer tooling:** `Scripts/private_provisioning_inputs.py`
admits the existing version-1 `PRIVATE_INTEGRATED_CANDIDATE_INPUTS` data through a
distinct version-2 signing-input contract. No packet, scope pin or historical gate
is rewritten. The legacy app-based `Adapter.run` remains separate and does not
auto-detect source inputs. `Adapter.run_source_inputs` and `SourceInputCaller`
are explicit APIs; there is no signing CLI or file/environment approval loader.

The trusted caller supplies a typed `ReviewedSourceInputs` in memory. It binds
the independently reviewed packet digest, new source commit/archive/overlay, exact
original scope semantic and byte digests, original request lineage, preserved
scope-definition source digest and selected signing team. Fixture mode is also
bound. The version-2 request digest has its own domain; neither an old request
digest nor the packet/checksum sidecar digest can authorize its dispatch. The
gate JSON's approval claims are not read as authority.

Admission verifies strict version/kind/fields, explicit non-authority flags,
immutable input/runtime/lineage inventories, receipt and prior-request bindings,
safe source archive, archive/config equality, six overlay paths, original scope
definition, full expected scoped-source inventory, exported package/resource
hashes and runtime origin/payload/ZIP inventories. Runtime/team/material selectors
must match the review. The VM-root namespace is refused before observing its
directory, and scope root strings are never used to read or recapture a real root.

An admitted value supplies data for the existing adapter sequence. The actual
applied overlay must reproduce the full reviewed source inventory before signed
pin/inspection projections, and the original scope-definition bytes must match.
Inputs are readmitted across process callbacks. The selected runtime lock/archive
stay exact; child signing, post-sign seal, outer signing, strict verification and
private extraction checks retain their existing policies. Legacy inputs continue
through their original version-1 path.

`SourceInputCaller` takes typed review and material objects with an optional
injected runner. Its default `SystemRunner` still refuses before profile/keychain
IO or output creation without separately approved in-memory authorization for the
version-2 request, scope, material and effects. Caller use is consumed atomically
before admission; failure or concurrent invocation cannot replay it. No retry,
publisher, keychain import/unlock or notary operation is added.

```sh
make test-private-provisioning-inputs
make test-private-provisioning-signer
```

**VERIFIED — offline/fake:** eighteen new test functions cover full fake adapter/
archive roundtrip, independent source/scope preservation, default denial, malicious
gate/sidecar claims, version confusion, duplicate/unsafe data, resealed runtime/
scope changes, callback mutation, unexpected source files and concurrent one-shot
use. The full allowed Python run discovers 132 tests: 127 pass and five software-
signing/PKCS12 cases are deliberately skipped. Auditing records only local Git and
Python processes, with no forbidden-tool attempt. The actual frozen `7e46241`
packet also admits as version-2 file data with process/network hooks prohibited;
no runner/material authorization is constructed for that packet.

All 1,161 previously retained private artifact entries remain unchanged, including
the gate's preparation-time compatibility/status fields. New admission evidence
is retained separately. Those historical fields do not grant execution or claim
fresh signatures. Product provisioning approval stays nil; shared Swift/package
source and pins are unchanged. No real signing, profile bytes, credentials, Apple
requests, SSH/Ansible, installs, app/UI, image or VM operation occurs.

**NEXT / TO PROVE:** named profile/isolated-keychain selection and separately
approved bounded validation, reviewed real execution authorization, actual source
compilation/signature/profile/loaded-child and original-Mac scope evidence. No
real build/signing caller is invoked here. Notarization and every real guest row
retain their separate approvals and NOT_RUN status.

## Named material inspection and private staging — 4 November 2026

**IMPLEMENTED — developer tooling, fake execution only:**
`Scripts/private_provisioning_materials.py` adds an explicit one-shot
`MaterialInspectionCaller`. This step can check selected material files and stage
the exact pinned profile; its result is data, never signing or guest authority.
There is no command-line entrypoint, selector discovery, key export/import,
keychain unlock, search-list change or automatic signing continuation.

The trusted composition must supply a typed `MaterialSelection` with the named
source profile, isolated-keychain path, identity/team, frozen runtime, local client
and parser checkouts, plus a separately supplied DER **public** leaf certificate.
`ReviewedMaterialInspection` independently binds the version-2 source request,
selection, public-certificate and trusted runtime-inspector hashes, and new private
output path. Its request digest has a distinct version/domain. The native runner
requires a matching in-memory authorization with **only** the `inspect` effect
before any material IO or output. Source-signing authority, gate JSON, sidecars
and environment flags cannot authorize this step. Fixture reviews refuse native
execution even with matching authorization.

After separately approved inspection, the implementation checks named keychain
**metadata only**, without opening its contents or querying identities, locked
state or private-key availability. Profile/certificate/inspector hashes must match
review. Local client/parser revisions and cleanliness are checked before/after.
The profile and public certificate are copied into a fresh owned 0700 directory
as 0600 files. Bounded CMS decoding validates profile team, macOS distribution,
expiry and exact manager App ID/entitlements. The selected public leaf must appear
in the profile, match the identity's common name and be within its validity dates.
Local public-certificate parsing does not establish certificate trust or key
possession; OS validation remains required. A hash-bound upstream verifier checks
the exact admitted runtime through an inspect-only command. No runtime is rebuilt
or signed. Inputs, staged files, runtime inventory and named-keychain metadata are
rechecked across process callbacks; failures retain fixed private diagnostics and
consume the caller without automatic retry.

The receipt reports `privateKeyAvailability: NOT_QUERIED`,
`keychainUnlocked: NOT_CHECKED`, and `signingAuthorized: false`. The returned
`InspectedMaterial` names the privately staged profile; that changes the material
binding. Any later app build/signing caller still needs separate approval for the
source request, scope, **staged** material binding and its build/inspection/signing
effects, including secure timestamp requests. An inspection authorization cannot
authorize that caller. Notarization and real guest rows remain separate.

```sh
make test-private-provisioning-materials
```

**VERIFIED — fake/local:** 19 new tests cover staging, no keychain-content reads,
default denial before material IO, effect/domain separation, fixture isolation,
profile/certificate mismatches, expiry, unsafe files, dependency drift, callback
mutation, bounded command failure, private diagnostics and concurrent replay.
The allowed full Python suite discovers 151 tests: 146 pass and five signing/
PKCS12 cases are deliberately skipped. Auditing observes only local Git/Python
processes and no forbidden-tool attempt. No real profile/certificate parser,
SDK/CMS verifier or keychain is exercised by this work.

All 1,161 retained private artifact entries and frozen pins remain unchanged;
evidence stays separately private. Ordinary product approval remains nil and shared
Swift/package source and pins are unchanged. No signing, credential access,
Apple request, SSH/Ansible, install, app/UI, disk image or VM operation occurs.

**NEXT / TO PROVE:** select the actual isolated-keychain/profile/public-certificate
paths and independent hashes, then separately approve a bounded real inspection
of those named files/runtime. None is selected or inspected here. Private-key
availability, actual app compilation/signatures/profile trust/loaded-child checks,
original-Mac scope evidence and all real guest behavior remain TO PROVE/NOT_RUN.
The historical frozen gate remains a preparation record, not an authorization.

## Bounded native inspection preparation — source review, 4 November 2026

**VERIFIED — pinned source only:** `kit_signature.py verify --signature-only`
skips the notarization/stapler branch but still runs the bundled daemon with the
exact argument `check` after signature checks pass. In `daemon.c`, `main` returns
through `locate` and `check` before the root-only listener/session branch.
`check` tests helper executability, reads/hashes the bundled server and supervisor,
and statically validates the bundled client's build-time CDHash requirement. It
does not call the client, register a service, start XPC listening, create a session,
spawn the supervisor/server, change networking or access a VM root. The **client's**
`check` is different: it contacts the privileged Mach service and is excluded.
Build source compiles this daemon from one C translation unit and generated pins;
no project constructor is present before `main`. This is source reasoning, not a
fresh proof of the signed binary's behavior.

**PRIVATE COUPLING:** build-time relative resources, two signed-payload SHA-256
values and the signed client's CDHash bind this check to its bundle. The frozen
origin/inventory evidence stays exact. Payload hashing itself has no internal size
or time limit; outer inventory admission and a monitored worker must bound it.
The verifier's nested commands have no individual timeout, and the current runner
checks captured-output size after completion rather than enforcing a live disk
limit. An `inspect` label does not constrain descendant effects.

**DESIGN DECISION — proposed, not implemented:** use a distinct offline native
inspection adapter and request domain for this no-Apple-request run. The daemon
uses `SecStaticCodeCheckValidity` with default flags. Those flags do not explicitly
enable the SDK's `kSecCSAllowNetworkAccess`, but the call does not explicitly set
`kSecCSNoNetworkAccess` either. Do not promote source absence of socket calls or
`--signature-only` into a system-wide network-silence guarantee. Local SDK headers
document `kSecCSNoNetworkAccess` as preventing validation work requiring network,
including online revocation/notarization. A child network sandbox alone does not
establish what an out-of-process trust service may do.

The prepared contract binds the existing source/scope/selection, exact input
inventories, public certificate, reviewed sources/entitlements and a fresh private
output. Before execution, implement/fake-test an adapter that:

1. Readmits immutable inputs, checks named keychain status with interaction disabled
   and leaves it locked; never queries identities or private keys.
2. Stages the pinned profile/public certificate as 0600 files in a fresh 0700 root.
   Requires a bounded DER `signedData` envelope with embedded `data` content before
   native CMS decoding; rejects encrypted/unknown/nested-CMS/detached content so
   the decoder cannot select a private key.
   Uses content decoding without invoking signer trust evaluation;
   validates the decoded profile policy, public-leaf membership and certificate
   identity/dates. CMS signer trust/authenticity remains explicitly unestablished.
3. Checks every admitted Mach-O and the enclosing bundle through static Security
   APIs with explicit `kSecCSNoNetworkAccess`, strict/all-architecture checks and
   appropriate nested-code checks. Preserves expected identifier/team, hardened
   runtime, existing timestamp and entitlement requirements. No code is signed,
   timestamp requested or runtime executable launched. The daemon's own `check`
   remains NOT_RUN, with no claim of behavioral equivalence or loaded-child proof.
4. Uses a monitored worker: 300-second whole-job deadline, 120-second maximum
   stage, live 2 MiB cap per output stream, input inventories at most 4,096 files /
   1 GiB and profile/certificate at most 1 MiB each. On timeout, overflow, mutation
   or cancellation, kill/reap the owned process group, preserve fixed private
   failure evidence and consume the one-shot request without retry.

No `security cms` CLI, upstream verifier invocation, `codesign` CLI, privileged
client, daemon/server/supervisor/QEMU, service registration, notarization, trust
network-fetch opt-in, keychain unlock/import or signing is allowed in this proposed
adapter. Static offline success does not prove current revocation, Gatekeeper,
notarization, private-key availability or guest acceptance. The current material
caller remains unchanged and is **not ready for execution under this stricter
contract**; changing the frozen daemon or silently reusing its prior request is
not a substitute. Its future implementation hash and separate approval are still
required.

**PREPARED / NOT RUN:** exact local source/SDK evidence and the bounded contract
are retained privately, separate from historical selection/import/gate records.
No native verifier, daemon, profile/signature/trust API, compiler or signing test
was run for this source review. Frozen artifacts/pins and product approval remain
unchanged. The next task is the offline adapter with fake APIs/processes, before
separate approval for any real inspection.

## Offline inspection adapter — fake APIs/workers, 4 November 2026

**IMPLEMENTED — developer tooling:** `private_provisioning_offline.py` adds a
separate typed `OfflineReview` and atomically one-shot `OfflineInspectionCaller`.
Its versioned request binds source/scope/selection, public certificate, exact
implementation inventory, helper/QEMU entitlement sources and private output.
`OfflineAuthorization` is a distinct trusted in-memory type, with exactly the
`offline-native-inspect` effect. Legacy signing/material-inspection approvals,
packets, sidecars and environment claims cannot authorize it. Default denial
precedes source/material IO and output creation. Fixtures cannot use a nonfake
factory, and API/factory test-double classifications must agree.

`offline_inspection_worker.py` implements the policy against an **injected API
facade**. It disables interaction, obtains/releases only the named keychain
reference and refuses unlocked status. Before any CMS API, strict bounded DER
preflight requires `signedData` with embedded plist `data`, refusing encrypted,
detached, nested CMS, malformed/noncanonical or excessive-depth/node/size inputs.
The facade may decode content only; returned bytes must equal the guarded payload.
The parent applies existing exact profile policy, public-leaf membership and
certificate identity/dates. Signer authenticity/trust is explicitly unestablished.

Every admitted Mach-O, including unusual resource locations, and the enclosing
bundle receives static validation with explicit `kSecCSNoNetworkAccess`, strict /
all-architecture and appropriate nested-code flags. The requirement names the
expected identifier, Apple Developer ID certificate policy and selected team.
After validation, metadata must show the expected identity/team, hardened runtime,
existing certified timestamp and exact entitlements. Ad-hoc/missing/mismatched
data refuses; there is no network/default-flags fallback. Opaque API references
release on success and failure. No daemon, client, server, supervisor, QEMU,
signing command or native CLI is invoked by this engine.

`offline_inspection_runner.py` supervises **injected process handles**. A shared
300-second monotonic budget begins before source admission and is checked around
input/revalidation callbacks; each worker has at most 120 seconds. Bounded reads
actively enforce 2 MiB per stdout/stderr stream before retaining additional bytes;
stderr is not retained as raw diagnostics. Root exit is insufficient while a
descendant remains. Failure/cancellation/overflow kills the owned group, waits /
reaps and closes handles. Cleanup waits have a five-second bound each, including
one fallback kill/wait when cleanup itself fails. Unconfirmed cleanup remains an
actionable failure, never success; no request is replayed. Dispatch overlap,
unknown tasks, oversized/duplicate JSON and failed process handoff refuse.

Private profile/certificate staging and receipts retain 0700/0600 modes. Source,
runtime, implementation, selected/staged files and named keychain metadata are
revalidated across callbacks; dependency revisions/cleanliness and locked state
are checked before/after. Existing admission bounds inventories to 4,096 files /
1 GiB, with profile/certificate at most 1 MiB each. Failure reports contain fixed
stages and cleanup status, not backend errors. Fake receipts explicitly state no
native validation was observed and grant no signing or guest authority.

```sh
make test-private-provisioning-offline
```

**VERIFIED — fake/local:** 32 tests cover the full synthetic roundtrip, independent
authorization domains/implementation binding, no-network flags and static policy,
CMS guards, locked status/reference release, callback mutation, virtual deadlines,
live stream overflow, interruption, live descendants, failed cleanup and replay /
concurrent-dispatch refusal. The allowed full Python run discovers 183 tests:
178 pass and five signing/PKCS12 cases are skipped. Auditing records only local
Git/Python processes and no forbidden-tool attempt. Native APIs, libraries,
process launches and external sockets are blocked in the new test fixtures.

**LIMIT / TO PROVE:** no concrete native API facade, real process factory,
authorization loader or activation CLI is provided. A future factory must return
an owned handle promptly, perform native work only in the child and honor bounded
nonblocking reads/waits; these are interface contracts tested with virtual
processes here. Parent filesystem reads are budget-checked at callback boundaries.
Real OS process/IO behavior and native API correctness remain unobserved. Concrete
bindings/launch composition must be added to the reviewed implementation inventory
and tested with fake FFI/process boundaries before separate real-inspection
approval. The historical private proposal is not rewritten or promoted. Frozen
artifacts/pins, shared package/product source and ordinary approval remain
unchanged. No real inspection, keychain access, signing, Apple requests,
SSH/Ansible, install, UI, disk image or VM operation occurs.

## macOS bindings and bounded launcher — fake FFI/processes, 4 November 2026

**IMPLEMENTED — developer tooling, not activated:** `offline_macos_api.py` now
provides concrete lazy ctypes bindings for the injected offline API. A closed
symbol/constant table excludes explicit SecTrust and CMS signer-status APIs,
identity/private-key queries, unlocking and signing. Constructors/imports load
no inspection framework. After interaction is disabled, only the named keychain
reference/status is available. CMS APIs create/update/finalize/copy content after
the existing signedData/plist guard. Public certificate fields are copied without
trust evaluation. Static code checks enforce the exact offline flags/Developer ID
requirement with no fallback; metadata access requires successful validation.
Only the certified timestamp field is accepted. CF types, sizes, unsigned flags
and full string lengths are checked, including embedded-NUL truncation refusal.
Owned outputs, partial/error references and temporary CF objects are released.

`offline_native_process.py` provides an explicit `MacOSWorkerFactory` and handle
for the existing supervisor. It requires the exact typed in-memory authorization,
review/scope/selection/implementation and source-fixture mode before pipe/process
effects. Neither the default caller nor imported modules select it automatically.
All new sources join the implementation digest, invalidating stale reviews rather
than modifying frozen pins or historical proposals.

Each worker uses the current resolved Python with `-I -B`, a fresh 0700 scratch
directory, a small environment allowlist, piped stdio, a new session and exactly
one inherited capability FD. No passwords/approval selectors appear in argv or
environment. The internal `offline_native_worker.py` entry rejects stdio/regular
files as capabilities. Anonymous parent-pipe data binds a per-launch token, parent
PID, task digest, implementation digest and fake/native classification. Task input
arrives on a separate bounded pipe and must match before API initialization.
Files, environments and gate JSON cannot substitute for the trusted parent
composition. This is same-user workflow/task isolation, not protection against a
compromised parent capable of directly invoking macOS APIs. The response carries
the worker API mode; a fake result cannot become a native receipt.

Nonblocking partial input writes and simultaneous bounded stdout/stderr reads
use selectors. The concrete handle enforces the live stream caps too. Root exit
is observed without reaping (`WNOWAIT`), reserving its process-group identity until
descendants are quiescent. System Python 3.9 lacks `os.waitid`; a lazy Darwin libc
binding supplies the SDK's 64-bit `siginfo_t` layout and non-reaping semantics.
The group query uses `proc_listpids(PROC_PGRP_ONLY)` byte counts with a fixed PID
bound and requires the held root to remain visible. Missing ownership/query proof
refuses; no signal is sent after reaping or losing the owned root. Startup failures
kill/reap and close streams/FDs; unresolved handles remain retained and block more
launches. Deadlines, live caps and cancellation remain with the shared supervisor.

Dependency checks use four fixed local Git **metadata** reads and bounded raw
worktree/index comparison. They avoid `git status`/clean filters, disable hooks,
fsmonitor, global config, replacement objects and interactive/SSH behavior, and
reject unsupported/linked/credential paths. Nested Git stays in the worker's group
with live stream caps and ten-second command bounds. No runtime executable,
privileged service, shell, download or installer is dispatched.

```sh
make test-private-provisioning-native
```

**VERIFIED — fake FFI/process only:** 33 new tests cover ABI out-pointers and
CF ownership on errors, exact no-network flags, content-only CMS, certificate/
timestamp/type policy, authenticated/bounded framing, default denial, fake/native
classification, partial IO, overflow/hang/cancellation cleanup, failed startup/
reap, descendants, root identity release, Darwin wait/group ABI and filter-free
Git checks. A full synthetic adapter roundtrip uses the concrete launcher and
ctypes wrappers with fake symbols/process primitives throughout. The full allowed
Python run discovers 216 tests: 211 pass/five signing cases are skipped. Its audit
observes only local Git/Python and zero forbidden tools or attempts to load
Security/CoreFoundation/libproc/libSystem inspection bindings. No real worker or
selected material is inspected. All 1,161 retained private entries and historical
review packets remain unchanged; shared package/product code and approval stay
unchanged.

**NEXT / TO PROVE:** after committing, bind the final implementation and exact
private selection/output into a fresh review, then separately approve bounded
native inspection. Do not replay old authorizations or rewrite their preparation
status. Real API/ABI behavior, CF value shapes, kernel group enumeration of the
held exited root, scheduling, cleanup/parent-crash behavior and native results are
unobserved. Static offline success will not prove signer trust, online revocation,
notarization, key possession, daemon execution or guest behavior. No real
inspection, keychain/credential access, signing, Apple request, SSH/Ansible,
install, UI, image or VM operation occurs in this implementation work.

## Fresh private inspection review for ddf5451 — 4 November 2026

**PREPARED / NOT EXECUTED:** a new ignored private packet binds committed tooling
`ddf5451`, all 14 implementation-file digests, existing typed source/scope/material
selection, public-certificate and entitlement-source hashes, exact frozen runtime
and a fresh private output path. The candidate source and original scope-source
lineage remain independently unchanged. No historical request, gate, observation,
approval or pin is rewritten or promoted.

The packet contains the typed review data/request digest, implementation manifest,
frozen-input references, prior evidence links, bounded action/cleanup plan and a
plain-English review. Files are 0600 under an owned 0700 root. The proposed
inspection output is absent. All inspection/signing/guest approvals are false;
no typed authorization, caller, runner, factory, pipe capability or native API is
constructed. It is data for separate human review, not an execution/approval loader.

**VERIFIED — stored evidence/data integrity only:** committed source bytes and
implementation digest match the retained 211-pass/five-skip fake-test evidence.
Pure source admission preserves source/runtime/lineage bindings. Selected
dependency HEADs and the two reviewed entitlement files match their stored pins;
whole-worktree cleanliness is deferred to execution guards. Original signing
materials/keychain are not reopened or stat-checked, and no current certificate,
profile or locked-state claim is inferred from the prior observations. A fresh
approved run must revalidate these inputs and locked status before proceeding.

All 1,161 original artifact entries remain in place with changes prohibited during
preparation. Noncredential artifact hashes and historical review checksums match;
one credential-named historical artifact remains unopened, with its prior digest
retained and metadata stable. This is not a fresh content validation of that file.
Exact selectors, digests and evidence stay private. No tests or native inspection
are rerun for this packet preparation; no signing, Apple request, SSH/Ansible,
install, UI, VM root observation or VM operation occurs.

**NEXT / TO PROVE:** review the exact packet, then separately approve only its
bounded read-only native action. Trusted composition must create the exact typed
`OfflineAuthorization` in memory; editing approval JSON cannot grant it. The
300-second job/120-second worker and live 2 MiB stream limits, original scope,
one-shot refusal and unresolved-cleanup holds remain required. Any changed
binding stops, without recapture/replay. Native ABI/results/cleanup, profile signer
trust, key possession, online revocation/notarization, daemon behavior and all real
guest rows remain unproven or outside scope. Ordinary product approval stays nil.

## Approved inspection attempt stopped before native work — 5 November 2026

**AUTHORIZED / STOPPED / NOT INSPECTED:** the user explicitly approved the bounded
read-only native action for the fresh `ddf5451` review. A private one-off caller
bound the exact review-file, request and implementation digests. Its additional
Python audit guard stopped the preliminary committed-source Git read: Python
opens `/dev/null` with `O_RDWR` to disable subprocess stdin, and the guard refused
that open before the first subprocess was created. This was a composition-guard
error, not an observed material, keychain, signature or runtime validation result.

**VERIFIED — source/data only:** zero subprocesses/workers and no native API or
external signing-material access occurred. No typed native authorization or caller
was constructed; failure preceded that point. Cleanup has no unresolved handles.
The inspection output remains absent and the review packet checksums match.
All 1,161 original artifact entries remain present, with noncredential bytes,
modes and symlink targets matching retained evidence. The credential-named
historical artifact remains unopened; its contents are not freshly validated.
Frozen source/scope/runtime pins and ordinary product approval are unchanged.

The failed composition, consumed-request marker and preservation evidence remain
private. Source reproduction confirms the guard failure. Ten fake audit-event
cases validate a proposed narrow exception for `/dev/null` opened only with
`O_RDWR` and optional `O_CLOEXEC`; credential opens and other out-of-scope writes
remain denied. That correction has not been used for any real attempt and does
not modify the 14-file implementation or frozen inputs.

**NEXT / TO PROVE:** this attempt is consumed and is not automatically retried.
Prepare a corrected composition and fresh digest-bound review/output, then seek
separate approval before another attempt. Real locked-state, profile/public-leaf,
static-signature and worker cleanup behavior remain unobserved. No signing,
private-key access, Apple request, SSH/Ansible, install, UI or VM operation occurs.

## Corrected fresh private inspection review — 5 November 2026

**PREPARED / NOT EXECUTED:** a separate ignored 0700/0600 packet retains `ddf5451`
tooling and the exact 14-file implementation, source/material selection and frozen
scope/runtime bindings. A new output path produces a distinct typed request
digest. The original review, consumed request, failed composition and failure
evidence remain unchanged; no previous approval is carried forward.

The private correction permits only a literal `/dev/null` open with `O_RDWR` and
optional `O_CLOEXEC` for Python's disabled subprocess stdin. Credential opens and
other writes remain denied. The guard module only defines functions and installs
nothing on import. A separate composition manifest binds its exact source hash,
the new review-file hash, request, implementation and output. There is no approval
loader or native activation entrypoint. Twenty-two fake audit/helper cases pass,
including the current Python DEVNULL helper with fake `os.open` and descriptor
caching. These cases launch no process or native inspection.

**VERIFIED — local data/fake guard only:** all 14 implementation files match the
committed source. Pure admission revalidates frozen source/runtime/lineage;
dependency HEADs and entitlement files match their pins. All 1,170 preexisting
private artifact entries remain unchanged, including the original review packet.
Noncredential bytes, modes and links match; one credential-named retained file
stays unopened, with metadata stable during preparation rather than a fresh
content claim. Prior failure checksums and consumed marker also match. External
original signing materials/keychain are not reopened or stat-checked; historical
certificate/profile/lock observations are not promoted to current evidence.

**NEXT / TO PROVE:** separate approval must name this fresh review and corrected
guard before trusted in-memory authority is constructed. Both inspection outputs
remain absent; every new inspection/signing/guest approval is false. No guard is
installed and no authorization, caller, runner, factory, capability or native API
is constructed. The existing 300-second job, 120-second worker, live 2 MiB stream,
owned cleanup and no-retry limits remain. Whole dependency cleanliness and actual
native validation/cleanup remain execution-time checks. No real inspection,
signing, private-key access, Apple request, SSH/Ansible, install, UI, VM-root
observation or VM operation occurs. Frozen pins and product approval stay unchanged.

## Corrected native inspection result — 5 November 2026

**AUTHORIZED / PARTIAL / NOT ACCEPTED:** the corrected fresh review was explicitly
approved together with result analysis, cleanup checks and documentation. Exact
review/guard/composition hashes and all 14 `ddf5451` implementation files matched
before the one-shot native caller ran. Five workers were created; the attempt
stopped after about 12 seconds at `public-certificate` with `offline-worker-failed`.
The corrected guard blocked no action. The consumed request is not retried.

**VERIFIED — observed native stages:** both pinned dependency HEAD/index/worktree
checks passed. The selected keychain was observed locked with interaction disabled.
The guarded profile's native CMS content matched the embedded bytes; profile
scope/expiry policy and exact public-certificate membership passed. These checks
do not authenticate the CMS signer or establish trust/private-key availability.
The certificate worker returned a nonzero exit without a detailed cause. No
certificate name/date result was accepted, no runtime static-signature check was
reached, and final source/locked-state checks were not reached. There is no success
receipt and no claim that the keychain was reobserved after the failure.

**CLEANUP — observed limits:** the runner records `cleanupConfirmed: false`; the
factory reports zero unresolved handles. A separate bounded exact-parent/worker
process snapshot finds no matching survivors, and the snapshot process is reaped.
Raw host command arguments are discarded. The tool sandbox initially denied this
cleanup snapshot; the same cleanup-only analysis completed outside that sandbox.
This was not a second inspection attempt. The snapshot is not a retrospective
audit of every short-lived descendant and does not override the failed cleanup
receipt. No existing process was signalled by the snapshot.

**VERIFIED — preservation and fake analysis:** all 1,182 preexisting artifact
entries, including both review packets, retain their noncredential bytes, modes
and links. The retained credential-named file remains unopened with stable
metadata, without a fresh content claim. Only the planned private inspection
output is added; staged profile/public certificate and fixed failure evidence are
private. Original pins, historical failure/consumption records and product approval
remain unchanged. Five additional fake cases exercise certificate CFDate/Number/
String values and two cleanup-error/final-reap paths. They reproduce possible
failure shapes, not the actual native cause. Generic certificate property values
are not guaranteed to be CFDate; the installed SDK provides typed certificate date
getters on macOS 15. This is source evidence, not a new native API observation.

**NEXT / TO PROVE:** one consolidated fake-only change should add fixed worker
failure diagnostics, per-handle cleanup evidence and typed certificate date
bindings, validate those together, then prepare a fresh review. The actual
certificate/cleanup failure causes remain unknown; a new native attempt needs a
new reviewed implementation/request and separate approval. Runtime signature,
post-checks, profile signer trust and all signing/guest acceptance remain unproven.
No signing, private-key access, Apple request, SSH/Ansible, install, UI, VM-root
observation or VM operation occurs.

## Diagnostic and date hardening — fake validation and fresh review, 5 November 2026

**IMPLEMENTED / FAKE-VALIDATED:** authenticated workers now return a closed,
versioned failure code/phase envelope with mode proof. The supervisor rejects
extra fields, unknown codes/phases and invalid mode proof before storing a
diagnostic. Raw exceptions, stderr, certificate names, task contents and paths
are not copied into diagnostics. Startup/fatal worker exits retain their bounded
exit status instead of masquerading as a structured API failure.

Private success/failure records include per-worker task/exit/diagnostic and
categorized kill/wait/fallback/close results. Concrete handles snapshot held PID,
reap/quiet-before-reap/descriptor state and stream counts without polling a
released process group. Factory records also retain cleanup facts for failed
handoffs. Intermediate cleanup errors remain latched false even when fallback
ultimately leaves no retained handle. An exited root is not signalled after its
held group is observed quiet; wait and group recheck still precede reap. Live or
unproven groups retain kill/reap behavior. A 4,112-worker ceiling bounds evidence.

Certificate dates now use macOS 15's retained
`SecCertificateCopyNotValidBeforeDate` / `SecCertificateCopyNotValidAfterDate`
references, with null/type/finite/order checks and release on every path. Generic
`SecCertificateCopyValues` and its date-property constants are removed from the
allowed binding surface; there is no legacy, trust-evaluation or network fallback.

**VERIFIED — fake/local only:** twelve new fake FFI/process tests cover exact date
ABI, missing/null/wrong/nonfinite/reversed values, reference cleanup, framed and
unframed errors, malformed diagnostics, permission/timeout cleanup evidence,
fallback completion, retained unresolved handles and worker bounds. The full
allowed Python suite discovers 228 tests: 223 pass, five signing/PKCS12 cases are
deliberately skipped. Only local Git/Python processes are observed; no forbidden
process or native-library attempt occurs. Existing lifecycle tests distinguish
killing active groups from reaping already quiet roots.

**PREPARED / NOT EXECUTED:** a new ignored 0700/0600 packet binds the changed
14-file implementation, a 17-file source/test archive and patch against the
recorded base, unchanged corrected guard, frozen inputs and fresh request/output.
The new code is an exact **uncommitted source snapshot**, not falsely attributed
to `ddf5451` or a new code commit. A later commit must retain these exact bytes.
All 1,191 previous private artifact entries and prior failure/cleanup/consumption
records remain unchanged. Credential-named retained content stays unopened, with
stable metadata rather than fresh content validation. External signing-material
and keychain observations remain historical. The new output is absent and all
new approvals are false; no selected native caller/authority/factory is activated.

**TO PROVE:** the earlier certificate and cleanup failure causes remain unknown.
The changes improve diagnostics and remove an unproven date-shape assumption;
fake results do not demonstrate that either observed failure is fixed. Separate
approval of this exact implementation snapshot, corrected guard and fresh review
precedes native work. Existing job/worker/output limits, no retry, scope and
ordinary product denial remain. No real inspection, signing, private-key access,
Apple request, SSH/Ansible, install, UI, VM-root observation or VM operation occurs.

## Native offline inspection passed — 5 November 2026

**AUTHORIZED / VERIFIED — bounded native inspection:** diagnostics/date changes
are committed as manager `df8b75e` and companion documentation `a8a8ba4`. The user
explicitly approved the fresh inspection and result documentation. All 17 reviewed
source/test files match the exact committed and current bytes; the 14-file
implementation, corrected guard, review/composition and frozen input bindings
match. The original review retains its preparation-time uncommitted-snapshot
record; separate private execution evidence binds the new commit without rewriting
the packet or any old pin.

The one-shot attempt completes in 64.18 seconds with
`OFFLINE_STATIC_INSPECTION_ONLY`: both dependency checks pass before and after;
the named keychain is observed locked before and after, with interaction disabled;
guarded CMS content/profile policy and public-leaf membership pass; the public
certificate name/dates pass; and all 23 Mach-O/enclosing-bundle static validations
pass with explicit no-network flags, required signing policy and entitlements.
No runtime/daemon code executes and no new signature or timestamp is created.

**VERIFIED — cleanup:** all 31 workers exit successfully, with no diagnostics or
categorized cleanup errors. Every handle records its root reaped only after group
quietness, closed descriptors and no open streams; no unresolved handle remains.
A bounded read-only snapshot restricted to these recorded worker PIDs finds none
remaining. The snapshot process is itself reaped; raw process commands are not
retained. All observed stream counts respect the 2 MiB live bounds. This confirms
this run's cleanup, not arbitrary crash or scheduling scenarios.

**VERIFIED — preservation:** all 1,204 preexisting private artifact entries retain
their noncredential bytes, modes and links. The retained credential-named file
stays unopened with stable metadata, not freshly validated contents. Both earlier
reviews and their failed receipts/consumption evidence remain unchanged. Only the
approved fresh output and separate private execution/analysis evidence are added
under private permissions. Original disposable scope/root pins are not recaptured;
ordinary product approval remains nil. No private-key query/access, signing,
Apple request, SSH/Ansible, install, UI or VM operation occurs.

**LIMITS / NEXT:** this establishes offline static inspection only. Private-key
availability remains NOT_QUERIED; profile CMS signer authenticity is NOT_ESTABLISHED;
standalone certificate trust is NOT_EVALUATED; online revocation is NOT_CHECKED;
notarization is NOT_REQUESTED; daemon check is NOT_RUN. The earlier failure causes
remain unknown: this success does not retrospectively diagnose them. Real app
build/signing/timestamps, loaded-child/original-Mac admission and guest acceptance
remain separate gates. The consumed inspection request grants no signing or
guest authority and triggers no automatic continuation; milestone 6 is incomplete.

## Signed-candidate review after offline inspection — 5 November 2026

**PREPARED / NOT EXECUTABLE:** after result-doc commits `740fd81` (manager) and
`7d8d907` (companion), a new ignored 0700/0600 packet binds the successful native
receipt/audit, exact staged profile/public certificate, selected material paths,
frozen source/scope/runtime and current 14-file tooling implementation. The staged
material binding matches the inspected receipt. Candidate source, tooling and
historical scope-source commits remain independent. A separate review-domain
digest also binds the proposed unused private app/ZIP output; it is neither the
existing signer's source-request digest nor an execution/approval loader.

The concrete proposed flow is exact source reconstruction and signed-build pin/
inspection projections, pinned local build, private assembly, child signing,
post-sign sealing, outer signing, bounded static checks and private archive/
roundtrip. Any built-app bundle diagnostic is an explicit executable effect;
it is not loaded provisioning-helper admission or a guest launch. Runtime bytes
are consumed unchanged, without runtime rebuild/resign or downloads.

**EXECUTION GAPS — source reviewed, not run:**

- Existing signing authority binds source/scope/material/effects, but does not
  bind the offline receipt, current implementation and exact output. A trusted
  one-shot receipt-bound signing caller is required.
- Existing signer output caps are checked after capture and its process lifecycle
  lacks the inspected worker runner's shared budget/live-cap/group-cleanup evidence.
  The review proposes a 2,400-second job, 1,200-second build, 120-second other-stage,
  live 2 MiB stream and bounded cleanup contract; these are not implemented yet.
- The signer still invokes `security cms` and the upstream signature-only verifier
  that executes daemon `check`. Offline inspection approval does not cover that
  route. Replace it with exact receipt consumption/revalidation and explicit
  no-network checks, or separately review/authorize the additional effects.
- The selected keychain was locked at the successful inspection; availability of
  its private key remains unqueried. Any necessary secure unlock/dialog and actual
  selected-key use require separate approval. Touch ID is preferred only if the
  existing keychain/ACL supports it; no ACL, permission or search-list change is
  inferred, and no password/P12/P8 is requested by this review.
- Required Developer ID signing uses secure timestamps. Explicit key-use/signing
  **and Apple timestamp-request** approval is necessary; removing timestamps to
  manufacture an offline-only candidate is not an alternative. Notarization,
  Apple API-key use and publication remain separate and excluded.

**VERIFIED — local data/source only:** pure source admission, the receipt/staged
bindings, 14 committed source files and dependency HEADs match. All 1,239 prior
private artifact entries, inspection results, failure records and pins remain
unchanged. Retained credential-named content stays unopened with stable metadata,
not fresh content validation. External original signing materials/keychain are
not reopened or stat-checked; prior locked-state/certificate observations stay
historical. No native validation or tests are rerun, no build/source projection is
generated and no signer/caller/runner/authorization is constructed. All new
approvals are NOT_GRANTED, output is absent and product approval remains nil.

**NEXT:** combine receipt-bound admission, bounded signer supervision, replacement
of legacy inspection dispatch, fake tests and a fresh exact-code review in one
implementation chunk. This packet is a concrete review with explicit readiness
gaps, not permission to execute the current signer. Real signing/key/timestamp,
original-Mac/loaded-child, notarization and guest acceptance remain separate.
No signing, private-key access, Apple request, SSH/Ansible, install, UI, VM-root
observation/recapture or VM operation occurs during this preparation.

## Receipt-bound signing path — fake tests and fresh review, 5 November 2026

**IMPLEMENTED / FAKE-VALIDATED:** after review-doc commits `e8c6c1c` (manager) and
`0bc6f31` (companion), the private developer tooling adds `ReceiptBoundCaller`.
Its typed, one-shot review/authority binds the source/scope, exact historical
offline request/implementation/receipt, staged material/public certificate,
current signing implementation, output and fixture/native mode. Authorization
precedes material/output IO. Historical receipt code and new signing code are
independent bindings; changing the signer does not relabel or regenerate the
successful inspection. Incomplete, fake/native-mismatched or unclean receipts
are refused, as are changed inputs, output reuse and replay.

`SigningRunner` and its explicit command factory reuse held-root process
supervision: a 2,400-second shared deadline, at most 1,200 seconds per build and
120 seconds per signing/native stage, live 2 MiB per stream, bounded waits and
per-command cleanup evidence. Native workers share the remaining job budget.
Unconfirmed cleanup retains handles and blocks reuse; intermediate errors stay
latched false. Parent filesystem/archive IO remains checked at callbacks, not
hard-preemptible. Commands use a closed environment, no inherited descriptors,
and exact reviewed argv. Original-source checkouts, extra build flags, credential
tools, arbitrary Python/programs and app execution are rejected.

**LEGACY REPLACEMENT:** real dispatch through `SystemRunner` and the older adapter
is disabled, including old typed signing authority. Their existing fake tests
remain. The new route uses guarded profile content/policy/public-leaf membership,
bounded filter-free dependency checks, and capability workers with explicit
no-network code validation. Closed candidate identifiers and exact team,
entitlements, hardened-runtime/timestamp, CDHash and public-certificate checks
cover the private app/children and archive roundtrip. Public certificate array/
data bindings add no key, trust-evaluation or unlock APIs. No `security cms`,
upstream daemon verifier, default-network `codesign --verify`, built-app diagnostic
or runtime execution is used by this route. Child-sign/seal/outer-sign ordering
and original scope-definition/resource/runtime checks remain intact.

**VERIFIED — fake/local only:** twenty new cases bring the full allowed Python
suite to 248 discovered: 243 pass, five signing/PKCS12 cases are skipped. Only
local Git/Python processes are observed; no forbidden program or native-library
attempt occurs. Complete fixture build/package/roundtrip uses concrete command
supervision and fake FFI, including the capability worker factory. Denial/mode/
domain/replay, mutation, code/receipt separation, forbidden argv, stdout/stderr
overflow, deadlines/cancellation, descendants, failed cleanup and fixed errors
when private evidence IO fails are covered. These are not real signing results.

**FRESH REVIEW / NOT EXECUTED:** a new private 0700/0600 review binds all sixteen
implementation files and a 24-file source/test/Makefile archive plus base patch.
The code is explicitly an uncommitted exact snapshot; a later commit must preserve
its bytes. All 1,251 original private entries, earlier reviews, successful/failed
receipts and frozen pins remain unchanged; interim preparation evidence is also
retained. Credential-named content stays unopened with stable metadata, not a
fresh content claim. External original signing materials/keychain are not reopened
or stat-checked, no VM-root identity is observed or recaptured, and product approval
remains nil. Candidate output is absent and no real selected authority/caller/
runner/factory is activated.

**TO PROVE / APPROVALS:** exact future authority requires all five effects:
local build, inspection, selected-key use, necessary existing secure key UI and
Apple secure timestamps. Every grant remains NOT_GRANTED. No orchestration
unlock/import/search-list/ACL workflow is supplied; operator keychain preparation
and restoration to locked state may be needed. Touch ID remains a preference
only where supported by existing ACLs. Real compiler/signing/public-cert-chain/
OS cleanup behavior is unobserved for this new path. Notarization, original-Mac/
loaded-child and disposable-guest acceptance stay separate. No real inspection,
signing, private-key access, Apple request, SSH/Ansible, install, UI or VM operation
occurs in this implementation/preparation chunk.

## First reviewed candidate attempt — preparation stop, 5 November 2026

**AUTHORIZED / STOPPED BEFORE BUILD OR SIGNING:** after commits `27c672f` (manager)
and `92593c9` (companion), the user explicitly approved the exact reviewed private
build/sign/verify run, including selected-key use, existing secure key UI and Apple
timestamps. The 24 source/test/Makefile snapshot files and sixteen-file code digest
match the commit/current tree. A separate private execution record grants this
one-shot request; the preparation packet and historical approval fields remain
unchanged and do not become an approval loader.

The attempt stops after 125.283 seconds at `prepare-pinned-provisioning-source`:
the frozen Python helper exits 1. Source/receipt/material admission, public
certificate validation, original overlay check/apply and both pinned local
dependency copy/checkout/revision checks complete. No Swift compilation, runtime
static-validation phase, app assembly, signing command, selected-key use, secure
key UI or Apple timestamp request is reached. There is no candidate app/archive
or success receipt. Partial source/runtime/dependency staging and fixed failure
records remain private under the approved output.

**DIAGNOSIS LIMIT:** the last command produces zero stdout bytes and 278 stderr
bytes. The reviewed supervisor retains stream counts and a fixed process-exit
failure, not raw stderr; the exact cause is therefore unknown. Read-only source
analysis confirms that the 95 staged package files (853,039 bytes), source map/
snapshot digest and all four integration-patch file hashes match; modes/types
are acceptable and the frozen helper parses with the current interpreter. These
facts do not reproduce its execution or prove why it failed. No preparation step,
reverse patch, native validation, build or signing command is rerun for diagnosis.

**VERIFIED — cleanup/preservation:** all nine supervised command roots and three
native validation workers record successful cleanup, root reap after group
quietness and closed descriptors; no unresolved handles remain. A bounded
read-only snapshot restricted to their twelve recorded PIDs finds none remaining,
and the snapshot process is reaped. All 1,279 preexisting private artifact entries,
frozen pins, prior reviews and successful/failed receipts remain unchanged.
Retained credential-named content stays unopened with stable metadata rather than
fresh content validation. Keychain lock status is not re-queried or changed;
the run never reaches key use, unlock or relock. No original VM root is observed
or recaptured, and ordinary product approval remains nil.

**NEXT / TO PROVE:** this request is consumed and is not automatically retried.
The next consolidated fake/local-fixture change should cover the actual frozen
preparation helper path (the old build-command double treats it as a no-op), add
bounded fixed command-failure classification without raw path/secret logging,
then prepare a fresh reviewed attempt. Real compiler/signing/key/UI/timestamps,
output-chain validation, notarization/original-Mac/loaded-child and guest evidence
remain unproven. The signing approval was not exercised and is not carried to a
different request. No notarization, SSH/Ansible, install, app/runtime execution
or VM operation occurs.

## Frozen helper and safe failure diagnostics — 5 November 2026

**IMPLEMENTED / VERIFIED — local fixtures only:** prior failure-result docs are
committed as manager `d3d70ab` and companion `09b396b`. The exact frozen helper from
the retained failed candidate is now a byte-checked fixture, with unchanged public
package source, lock, four integration patches and generated pin. It remains a
fixture; neither the historical helper nor frozen candidate inputs are edited.

`make test-frozen-provisioning-helper` executes installed Python/local Git in
disposable directories. Outside a repository preparation passes. Inside an ignored
candidate directory beneath a Git checkout, preparation reproduces a patch-base
mismatch: reverse-patch Git discovers the surrounding repository. Setting
`GIT_CEILING_DIRECTORIES` to the exact private candidate output makes that case
pass; privately cloned dependencies still have their own Git metadata. The command
factory requires that exact environment value, rejecting missing/changed ceilings.
Source/patch mutation, unexpected launcher inputs and optional plugins still
refuse; repeated preparation remains idempotent. No compiler or guest is involved.

**DIAGNOSIS LIMIT:** this establishes a reproducible fixture failure and correction,
not the earlier attempt's exact cause. Its unretained stderr cannot be recovered;
278 bytes is the observed count, potentially partial under the previous drain
behavior. Do not relabel the historical failure or replay its consumed request.

**DESIGN DECISION:** an exited, quiet failed command root remains held while its
bounded pipes drain to EOF. Existing job/stage deadlines, live stream caps, group
checks, reap/descriptor evidence and cleanup retention still apply. A complete
failed helper stream can select a fixed phase/code from its exact final allowlisted
line. Persist no raw stderr, paths, exception text or raw-output hash. Other stages,
signals, unknown output and incomplete/capped streams have fixed generic codes;
partial output cannot assert a complete helper diagnosis. Cleanup uncertainty
continues to block reuse. The new diagnostic module joins the implementation digest.

**VERIFIED — tests:** thirteen new cases; 261 discovered, 256 passed and five
signing/PKCS12 cases skipped in the audited full Python suite. Focused make targets
for frozen helper, receipt-bound signing, native bindings and offline inspection
also pass. Actual child programs are local Git/Python only, with no native-library
attempts. Safe-code tests include fragmented failed-root output through EOF and
live-cap overflow. Swift/product/companion implementation is unchanged.

**PREPARED / NOT AUTHORIZED:** a fresh private review binds the historical passed
inspection independently, the unchanged source/runtime/disposable pins, seventeen
current implementation files and an exact 28-file source/test/Makefile snapshot.
Code is explicitly uncommitted; its archive/patch binds base `d3d70ab`. The new
request/output is distinct, all five execution effects are NOT_GRANTED, and output
is absent. All 3,987 existing private artifact entries, including partial failed
output, remain unchanged. Retained credential content stays unopened with stable
metadata; external signing materials/keychain are neither opened nor stat-checked.
No scope pin is recaptured, root observed or product approval changed.

**TO PROVE / NEXT:** commit the reviewed bytes before considering a separately
approved new candidate attempt. This task performs no real inspection, build,
signing, key access, Apple request, SSH/Ansible, install, UI or VM operation.
Real compiler/native/signing/key/UI/timestamp and candidate-chain behavior remain
unproven; notarization, loaded-child and guest acceptance are separate.

## Offline candidate preflight

`make provisioning-preflight` reports existing debug build artifacts without
building, assembling, signing or running them. Missing inputs fail the offline
check; there is no automatic fetch, install or build fallback. To inspect another
build configuration, set `PROVISIONING_PREFLIGHT_BINARIES` and
`PROVISIONING_PREFLIGHT_LAUNCHER_BINARIES` to its existing output directories.

```sh
make provisioning-preflight
# Optional assembled app: static provisioning inventory and binary fingerprints only.
python3 Scripts/provisioning_preflight.py --binaries .build/debug --launcher-binaries .build/provisioning-launcher/debug --app /absolute/path/to/candidate.app
```

**VERIFIED — offline/local:** ten checks pass against the current debug products.
The report records HEAD/dirty state, verifies the pinned export and reconstructed
base, checks the generated package pin, fingerprints runtime-lock/catalogue and
five build products, and compares bundled provisioning resources with the lock.
`verify_source` performs export validation without generating source or build
inputs. Its reverse-patch check uses a temporary copy and git; repository status
disables filesystem-monitor hooks. Candidate binaries and dependency/signing tools
are never executed. The report omits absolute paths and raw tool errors; keep any
saved candidate record private. This is repository development tooling using the
existing build-script Python, not a shipped Python runtime.

**DESIGN DECISION:** an offline PASS means those observations succeeded. It never
means launch-ready: `executionAuthorized` stays false and `guestAcceptance` stays
NOT_RUN. Dirty source, absent assembled app, unapproved scope, operational candidate,
code/signature admission, live factory/tool evidence and exact run/privilege consent
are separately visible. Optional app inspection verifies provisioning inventory
and the embedded runtime-lock bytes, not kit contents, signatures, notarization or
loaded-code identity. Signing can change executable bytes; differences from the
supplied build products are recorded without claiming a source/build relationship.
File fingerprints are not atomic admission or evidence that a binary came from HEAD.
No VM registry, guest root, factory image, credential store or desktop is inspected.

Eight new preflight fixtures cover missing/tampered artifacts, stale pins, bounded
reads, concurrent replacement, symlinks/FIFOs, dirty source, altered app seals and
signed-byte differences. A ninth regression verifies read-only export validation.
All 61 script tests pass. Earlier full Swift/UI acceptance remains the evidence
for unchanged Swift sources; this slice does not rerun or extend real guest rows.

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

### Optional-app trim acceptance (not run)

If explicitly included in an approved disposable run, use a guest derived from the
admitted official Try Omarchy factory and opt into **Trim optional apps** in a new
review. Inspect candidate removals under Details; actual installed candidates and
safe recursive transactions are determined in the guest. Verify native Omarchy
removal output, retention of required VM/development components and explicitly
selected software, clean reapply, failure cleanup, and no trimming in check mode.
This changes the disposable guest only. Do not modify the factory/cache or reuse
personal/default VM roots. Custom/unknown factories must hide/reset the native
option and refuse a trimmed creation handoff or workflow preparation. Existing
approval, owned-process/matching-exit and cleanup requirements still apply.

### Theme and layout acceptance (not run)

With explicit disposable-guest approval, review a chosen theme repository URL and
confirm its GET result; separately exercise random (including the default ten-star
threshold and zero-star mode) and most-starred with an existing authenticated gh.
Record the concrete resolved URL before apply and prove lookup/apply never reselects
it. Confirm inaccessible repositories and unavailable/rate-limited metadata cannot
produce an approved review. GET accessibility does not establish theme correctness,
safety or a fixed Git commit. Do not authenticate/install tools as part of this run
without separate authorization.

Select a disposable Lua layout, inspect its frozen fingerprint, edit the original
and prove the reviewed bytes remain unchanged. Observe native Omarchy theme
application/reapplication and layout behavior at the next desktop login, plus
explicit removal and preservation of unrelated settings. Do not execute a selected
Lua file on the host. Check mode must retain its read-only native behavior; do not
infer it solely from fake command construction. Existing guest/root scope,
authorization, terminal, cleanup and matching-exit requirements still apply.

### Bundled layout card acceptance (not run)

For an explicitly approved disposable guest, separately review each bundled card
(four-terminals, terminal-browser, vscode-browser, claude-two-terminals-browser).
Confirm the frozen layout fingerprint matches its admitted catalogue entry, and
review/install any required apps through a separate explicit setup selection.
Observe next-desktop-login startup and geometry on workspace 1, including the
browser overlap and retained manual resizing. All examples use floating placement;
the wireframes are illustrations. Confirm reapplication, switching layouts, Keep,
custom-file selection and managed-layout removal preserve unrelated settings.
Selecting/reviewing a card alone must never launch apps/VMs or install packages.
