# Pinned developer provisioning source

**Current pin (8 November 2026, issues #27/#29):** `dev-vm/` is the unpatched
export of merged dev-vm commit `2ab37fc39cef5b75dac66449dc83f84d0460d83f`
(reactive-org/dev-vm#16), which builds factories from the selected Omarchy
channel with that channel's Arch Linux ARM mirror and fails closed on
unreviewed releases.

**Previous pin (7 November 2026, issue #18):** `dev-vm/` is the unpatched export of
the dev-vm commit named by `revision` in `Config/DevVMProvisioning.lock.json`
(107 files: the paths listed below). `integrationPatches` is empty and `baseFiles`
equals `files`; the four former patches are part of that commit. The export adds
the list-merge rule, the three multi-workspace layout examples and layout needs.
The history below describes earlier pins and is kept as a record.

Originally, `dev-vm/` used an immutable base export from
`https://github.com/reactive-org/dev-vm`, commit
`bb3fae22be45b38035fac52aefa0eb270a9d0fea`, plus the exact content-hashed
`Patches/dev-vm-durable-state.patch`. This is explicit private coupling to the
shared-engine continuation, not a claim that the patched engine is the unchanged
base commit or that either branch has been published.

The base has 79 files: `Package.swift`, `Package.resolved`, `README.md`, `AGENTS.md`,
`Sources/**`, `ThirdParty/**`, `tests/DevVMProvisioningCoreTests/**` and
`tests/ProcessFixture/**`. The durable-state extension adds three core source files
and one fixture test (83 resulting files). It changes snapshot/checkpoint APIs,
preallocated payload identity, cleanup helper retention, public read-only reviewed
manifest path, explicit connection/tool verification and fixed process-purpose
serialization, private original-transport references and link-count proofs, with
the engine inventory.
Baseline README/AGENTS/license bytes are retained; current consumer behavior is
recorded here and in the manager plan. Guest resources, parser code and C launcher
are unchanged.

`Config/DevVMProvisioning.lock.json` records the base inventory, integration patch
hash, resulting exact inventory, source-snapshot digest and engine identity hash.
Preparation checks the resulting bytes, reverse-applies the patch in a disposable
local directory, and compares the reconstructed base against its inventory. A
changed/missing patch, wrong base, changed source or snapshot digest is refused.
The compiled pin binds the entire lock. Package status reports both base revision
and resulting source-snapshot SHA-256. Builds never refresh these pins or use the
separate dev-vm working tree. Included upstream tests are not shipped in the app
or run as part of the manager dependency build.

Root `Package.resolved` pins TOMLDecoder to the package's exact revision. The
upstream package's own lock remains unchanged because its engine inventory binds
those bytes. Normal SwiftPM source resolution may need network/cache access for
TOMLDecoder on a fresh developer machine; runtime planning needs no checkout,
Swift toolchain, Python, Ansible or Homebrew. Current validation reused already
available Git objects and used repository-local SwiftPM caches with update
checks disabled. Optional TOMLDecoder doc/benchmark/formatting plugin build flags
are rejected by source preparation.

Git whitespace checks exempt only this hash-verified export: the upstream LibYAML
header has three pre-existing trailing-space lines. Preserve those bytes and use
the exact source-hash check rather than reformatting third-party code.

To update: prefer a reviewed immutable dev-vm commit exported from Git objects,
then replace the exact inventories/revision and remove patches absorbed by that
commit. Until that handoff, any integration extension needs its exact patch, base
and resulting inventories, snapshot digest and engine hash reviewed together.
Never label a patched snapshot as an unmodified upstream revision. Preserve upstream parser/license
notices. `make prepare-source` validates the export and regenerates the compiled
pin; it does not bless changed sources by rewriting their hashes. Run
`make test-provisioning-package` and `make test` before accepting the new pin.

The library is linked into manager core and its offline-planning/ownership-only
provisioning helper. Its inherited control mode reserves a worker from an admitted private bootstrap.
Manager core can dispatch the pinned sequencer through an injected helper-local
context factory. The product helper independently validates private delivered
inputs and rebuilds the reviewed context, but provides no backend and rejects
activation. The internal helper backend can construct the shared adapter with a
manager-backed session authority and fenced process runner, but product entry
points supply no process-runner factory. Original managed-SSH/Homebrew resources
are now admitted and delivered privately; only their receipt enters the journal. Delivery/context/authority policy
remains manager-owned.
The separate debug fixture contains synthetic backends; none are staged into the
product helper. Manager launch/activation policy is outside the shared source pin;
see the milestone-3 transport-resource admission/private-handoff record in the plan.
The pinned C PTY launcher is built unchanged in a generated standalone SwiftPM
package because an executable product of a dependency is not a manager root
product. Only its exact entry-point source and generated manifest are admitted.
App assembly copies the library's resource bundle, helper and launcher, signs
nested code, then records their final binary hashes in the app-sealed distribution
manifest. Real Developer ID/notarization and execution admission remain separate.
