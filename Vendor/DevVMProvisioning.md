# Pinned developer provisioning source

`dev-vm/` is an unmodified export from
`https://github.com/reactive-org/dev-vm`, commit
`bb3fae22be45b38035fac52aefa0eb270a9d0fea`. A source snapshot makes this unpublished
milestone branch usable without a second checkout or a mutable path dependency
outside this repository. It does not imply that the commit is on a public branch.

The 79 exported files are `Package.swift`, `Package.resolved`, `README.md`,
`AGENTS.md`, `Sources/**`, `ThirdParty/**`, `tests/DevVMProvisioningCoreTests/**`
and `tests/ProcessFixture/**`. Source bytes are unchanged; the exact SHA-256
inventory and engine identity are in `Config/DevVMProvisioning.lock.json`.
Builds verify that inventory before compiling; they never refresh it or fetch a
new dev-vm revision automatically. Tests included in the source snapshot are not
copied into the app or run as part of the manager dependency's build.

Root `Package.resolved` pins TOMLDecoder to the package's exact revision. The
upstream package's own lock remains unchanged because its engine inventory binds
those bytes. Normal SwiftPM source resolution may need network/cache access for
TOMLDecoder on a fresh developer machine; runtime planning needs no checkout,
Swift toolchain, Python, Ansible or Homebrew. Current validation reused already
available Git objects and used repository-local SwiftPM caches with update
checks disabled. Optional TOMLDecoder doc/benchmark/formatting plugin build flags
are rejected by source preparation.

Git whitespace checks exempt only this immutable export: the upstream LibYAML
header has three pre-existing trailing-space lines. Preserve those bytes and use
the exact source-hash check rather than reformatting third-party code.

To update: review a full immutable dev-vm commit, export the same path set from
Git objects (not working-tree files), replace the source snapshot and regenerate
the lock's exact inventory/engine hash/revision. Preserve upstream parser/license
notices. `make prepare-source` validates the export and regenerates the compiled
pin; it does not bless changed sources by rewriting their hashes. Run
`make test-provisioning-package` and `make test` before accepting the new pin.

The library is linked into manager core and its offline-only provisioning helper.
The pinned C PTY launcher is built unchanged in a generated standalone SwiftPM
package because an executable product of a dependency is not a manager root
product. Only its exact entry-point source and generated manifest are admitted.
App assembly copies the library's resource bundle, helper and launcher, signs
nested code, then records their final binary hashes in the app-sealed distribution
manifest. Real Developer ID/notarization and execution admission remain separate.
