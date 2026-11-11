# Reviewed guest integration compatibility

**DESIGN DECISION — 12 November 2026: manual owner setup.** A lean factory built from Omarchy owner programs that match no reviewed contract names the manual marker `ce4c684e1a576eec068653a400451b6d70bb477275c73e4d7f25452a4d726553`, the SHA-256 of `omarchy-vm-manager/manual-owner-setup/v1`, instead of a contract. It pairs only with the reviewed `0.1.0-48.1` package, and its `compatibility.json` must carry the builder's `"owner_setup": "manual"` verdict. Reviewed lean evidence must not carry that verdict. The marker is never a supported seed contract, so such a guest always uses Omarchy's own first-run setup. Manual receipts hash that pairing in the same way. Existing pairings and receipts are unchanged. See `intent.md`, "Flexible Omarchy review".

**DESIGN DECISION — 8 November 2026: reviewed lean contract set.** The policy is schema 2. Its `leanContracts` list pairs each reviewed lean owner contract with the integration package its factory images carry:

| Contract | Owner contract SHA-256 | Image package |
| --- | --- | --- |
| `lean-e4fffc6` | `1347cb16b831eb2c3a67344a5bbb68c9da776a55221ecab5ba90ce385078d310` | `0.1.0-43.1` `9fc986521b67cfa9e891fd826453553f1e2e4a319e6edb1302c760f1e22a2211` |
| `lean-a948d8a` (Omarchy 4.5.0; edge from `9044b7e`) | `fb73e12e5ea4ad8c5bd4fbeee7b5d1d9029708342b6fa2f3a55c7ca9f14104c5` | `0.1.0-48.1` `876e05d829c3dbbb57991140c61563caeca990035a2ad01b9afb3b26d06bb5d3` |

The runtime supplies guest integration `0.1.0-48` (`5c09250244da58caff58fe25af359fa76277c5d441cbdd0331f523dd9b429b65`) and native-rendering `48.1`. A factory names one contract by digest; its evidence must match that contract's programs and image package, and crossed pairings are refused. Receipts hash the matched pairing over the schema-1 field set, so existing `lean-e4fffc6` receipts keep `c3cbd5eb1b061ada97f3951d91b3d21e1afeb508b8a367f6c308c0e87da56a55`. The sections below describe contract 1 and the earlier single-contract policy as recorded on their dates.

**DESIGN DECISION — 3 November 2026:** lean factory admission uses guest integration contract 1, independently of the manager repository revision and private runtime source commit. Source commits remain mandatory, syntactically validated provenance. `image-build.json` must still agree with the descriptor's recorded image source. It does not have to equal the current kit source.

## What is reviewed

`Config/GuestIntegrationCompatibility.json` is the reviewed policy. Its exact JSON is compiled into the private upstream client/helper as `VMGuestIntegrationContract.reviewedJSON`; tests and the runtime builder check agreement. Guest metadata cannot add supported identities. Changing the policy requires source review, an updated compiled helper, a complete verified runtime build and updated lock/pin.

Contract 1 supports guest status protocol 1 and managed SSH, managed setup, owner-contract selection and owner-report capabilities at version 1. These are guest contracts; host run protocol 1 alone establishes none of them. The package identity establishes the reviewed implementation of those capabilities; an image-supplied version declaration is not proof.

The policy pins:

| Component | Identity |
| --- | --- |
| Lean owner program set and dependencies | Unchanged `LeanOwnerSetupContract.json`, SHA-256 `1347cb16b831eb2c3a67344a5bbb68c9da776a55221ecab5ba90ce385078d310`; the guest adapter still checks the entire program contract before sourcing it |
| Lean guest integration | Complete `try-omarchy 0.1.0-43.1` archive SHA-256 `9fc986521b67cfa9e891fd826453553f1e2e4a319e6edb1302c760f1e22a2211` |
| Runtime-supplied guest integration (4 November extension) | Complete `try-omarchy 0.1.0-47` archive SHA-256 `a2912a97967d315439b4ec387bb6125912dc9db0568aee2408cdb524159fd59b` |

The separate-home extension adds a mount service, program, dependency drop-ins and versioned install-hook enablement. `Config/ReviewedGuestPackageSource.json` binds the complete 47 archive and native-rendering 47.1 variant (`8263e4db8c888da11ed490f7c09817767d723c2d78f1f63c8e8ca09661f9c740`) to the exact recipe, checked rendering transformation, builder and license Git objects. Lean factories select the pinned native variant; official factories select standard 47. Existing owner program contracts and the reviewed lean 43.1 image archive are unchanged. Historical format-2 runtime inventories may name the earlier 43 archive; their recorded integration hash must still match a historical package entry. Full current-runtime validation uses the current reviewed archives. Earlier validation records below describe the artifacts tested on their stated dates.

**DESIGN DECISION — 4 November receipt continuity:** new schema-2 receipt digests exclude `runtimePackageSHA256`, while every use still verifies the current runtime package. The guest/image contract digest is `c3cbd5eb1b061ada97f3951d91b3d21e1afeb508b8a367f6c308c0e87da56a55`. Only that exact unchanged guest/image policy also accepts the previously reviewed runtime-bound digest `9c430c34e68e720d0a0368983a1cd1bd58ccad6877a42c2d19c8777e0072dade`. This is explicit compatibility review of the retained image, not a general fallback or implicit receipt rewrite. Unknown digests, changed guest contracts and legacy schema-1 runtime mismatches are refused.

The full archive hash covers every component, including bridges, owner adapter, SSH enrollment, status reporter, shared-folder integration, service/timer/drop-in files, contracts, package installer, install hook, configuration, modes, symlinks and package metadata. There is no partial list that silently omits a service or dependency. Repacking an archive changes its identity even if its version is unchanged; that new archive needs explicit review and support, not an automatic allowance.

**VERIFIED — static package review:** the lean identity above is the package retained by the previously recorded `af93b5f10d206637-7816326733d14d53` build, image source `80156396a5daa795487c0f4a8308eee53f6ea68b`. Read-only extraction in disposable scratch space found 105 regular payloads including the install hook, two expected symlinks and exactly `.PKGINFO`, `.BUILDINFO`, `.MTREE` metadata. All payload bytes matched the current integration recipe after the existing lean builder's checked hardware-policy transformation; package name, architecture and version matched. Archive entries have root ownership and the expected modes, including sudoers restrictions; 107 mtree regular-file checksums match, with no duplicate or special members. The complete guest package source tree and license are unchanged from the previous runtime source `85f5e561e5a277ccec08d7725c8714cb090c9011`. The runtime preserves the newer 43.1 variant through its existing version comparison. No image was mounted, changed or booted for this review.

## Format 2 preparation and verification

In a **new flat bundle**, include the original factory image, its existing build/provisioning evidence, and its complete reviewed integration package archive. Add both options to the lean preparation command:

```sh
--integration-package try-omarchy-0.1.0-43.1-aarch64.pkg.tar.zst \
--provisioning try-omarchy-0.1.0-43.1-aarch64.pkg.tar.zst
```

The helper rejects a missing or unreviewed archive, mismatched owner hashes, wrong package version, malformed source provenance or unsupported runtime capability/package. It emits format 2 with a `guestIntegration` object containing `contractVersion`, exact `capabilities`, `packageFile` and `packageSHA256`. These fields describe the policy that the archive actually matched. They cannot authorize a new package hash or capability.

The manager and helper revalidate the same compiled contract, actual package bytes, owner evidence, image-build provenance, metadata checksums and all bundle payload checksums. Unknown manifest/contract/protocol versions, missing/malformed evidence, unsafe paths, symlinks and extra files fail closed. Payload errors identify the failed basename; package version, package identity, source evidence, owner programs and capability errors have separate messages. The runtime's owner provenance must still identify the supported contracts and report version. Guest-side owner program checks and decompressed disk size/hash verification remain in force.

## Runtime integrity versus image compatibility

Full current kit inventory, signatures, archive digest, compiled runtime-lock pin, source patch provenance, host run protocol and launch capability checks remain execution requirements. Every helper, QEMU, firmware, host script and signed resource still has to match the current reviewed runtime. Format 2 does not let factory metadata approve a runtime.

Format-2 `runtimeFiles` and `integrationPackageSHA256` retain the preparation-time inventory as provenance. Their paths/hashes must remain structurally valid, but their host executable/signature bytes are not compared with a later kit. Compatibility instead checks the current runtime's guest package against the reviewed policy and requires its factory/SSH/setup/owner-report capabilities. A host helper, signing resource, UI or unrelated source change therefore does not invalidate a compatible format-2 factory. A changed runtime guest package still needs a compatibility review; a host run protocol change still needs client/runtime support.

## Existing manifests and import receipts

| Existing evidence | Behavior |
| --- | --- |
| Format-1 lean manifest | Refused, even if its commit matches. It lacks the complete verified guest archive. Preserve it; prepare a separate format-2 bundle and explicitly import that bundle. Reuse the original disk when its original archive matches the reviewed identity. |
| Format-1 official-contract custom manifest | Keeps its existing full runtime-inventory and package checks. This change does not claim new evidence for that legacy path. The built-in official factory is unchanged. |
| Schema-1 receipt | Keeps exact runtime-lock binding and original factory identity. A different runtime fails with preparation/import instructions. No implicit migration or overwrite. |
| Schema-2 receipt | Binds exact factory identity to the canonical reviewed guest contract digest. The original runtime-lock digest remains provenance. Every selection revalidates the factory against the current contract and current verified kit; unrelated runtime-lock changes do not rewrite or invalidate the receipt. |
| Unknown, damaged, unsafe or incomplete receipt | Refused and preserved, including during repeated import. There is no fallback from a bad receipt to a compiled factory pin. |

A manifest and receipt must use matching policy generations. Review-list approval cannot bypass compatibility checks. Existing profile identities, imported bundles, receipts, factory/cache contents and writable disks are never relabeled or migrated automatically. A newly prepared descriptor has a new manifest identity; existing profiles retain their recorded identity.

## When a disk rebuild is necessary

An unrelated manager/source/host-runtime revision does **not** require rebuilding a supported lean disk. A legacy descriptor may need a separate preparation and explicit import with the original package archive. A different source commit with the same reviewed package is accepted and preserved in provenance.

A changed package, provisioning program or protocol requires explicit review and support. If the existing disk already contains that newly supported integration, a separately prepared descriptor can establish its evidence without rebuilding the disk. If its installed integration is unsupported, missing required functions or cannot be established from retained build evidence, build a new image through the normal builder. Do not change a version string, replace an archive or edit provenance to claim an old disk contains new code.

**PRIVATE COUPLING / limitation:** these are locally trusted build records and cryptographically verified package/payload identities, not a signed builder attestation or independent filesystem measurement of the raw disk. Import expresses operator trust in the association between the disk and its retained build evidence. Providing a reviewed archive next to an unrelated disk cannot establish what that disk contains. Static validation cannot prove a successful boot, dependency availability, guest setup, focus, sleep/wake or crash behavior; those remain **TO PROVE** for each artifact until separately authorized and observed.


## Validation — 3 November 2026

**VERIFIED — no VM:** `make test` passes 213 Swift tests in 36 suites and 46 script tests. Focused cases cover different source commits, changed verified host inventories, receipt continuity across runtime revisions, component/archive tampering even after descriptor rehashing, trusted policy review, unsupported contract/protocol versions, missing/malformed evidence, legacy refusal, receipt generation mismatch/damage, exact kit tampering and unchanged image/payload/path protections. A separate production-client smoke check used the real reviewed archive with image source `80156396a5daa795487c0f4a8308eee53f6ea68b` against the new kit and accepted it under the default compiled policy; its image payload was deliberately synthetic and nonbootable.

`make test-build-policies` passes two compiled checks in each optimized mode. `make build` passes. `make test-upstream` passes 554 Swift tests in 109 suites plus its contract, guest-script, shell, compatibility and relocation fixtures. The optional virtio-pinch guest ABI test remains skipped because `QEMU_PINCH_TEST_BINARY` is unset. The separate Docker/OpenSSH integration and real guest/e2e tests were not run; guest sources and package bytes are unchanged. One runtime-build attempt ended with SIGPIPE in the upstream Swift test process without an assertion report; the retry and final complete upstream run passed. Its failed-attempt log is retained.

Built the complete separate ad-hoc runtime with `make patched-kit REUSE_GUEST_PACKAGE_KIT=…`, comparing exact guest package/license Git tree identities, full previous kit inventory/signatures and the copied archive checksum. Runtime source: `033d2460dc44796afeb6d08b6a32aaf51febf8be`; patch SHA-256: `236447a6c44429c857b9fbba1d30fc78b1f5900eb64523aa33a841bc09fb8e6d`; runtime ZIP SHA-256: `7f04725a26aa665e30ffc4a7ba6901a4735fd7eb621611811c8ee1a60236b801`; runtime-lock/compiled pin: `da0bcbe9fada6fcee46e815007829fb0d6d1f53d8d21f510e18e9da7196a1c0a`. Only the helper, kit metadata, owner-contract provenance and signature seal differ from the previous runtime; all guest package, QEMU, firmware and host launcher bytes are unchanged. `make fetch-runtime-kit` verifies the existing local archive without network acquisition.

`python3 Scripts/assemble_app.py --output-directory .build/factory-compatibility-review --preserve-runtime-signatures` and `Scripts/verify-app.sh --bundle-only "$PWD/.build/factory-compatibility-review/Omarchy VM Manager.app"` pass the uninstalled candidate's complete signatures, 22 kit Mach-O signatures, macOS 15 compatibility for 25 Mach-O images, exact locked inventory and NAT/no-image layout. Diagnostics confirm `hostPreflightPerformed: false` and `vmLaunchEnabled: false`. The initial verification invocation used a relative path and stopped at the checker's absolute-path requirement; the corrected invocation passed. `git diff --check` passes.

Logs and the static package audit are retained in this worktree's ignored `.build/factory-*` paths. The original checkout remains clean. No existing factory/cache, imported bundle/receipt, profile, registry, guest disk or installed app was changed; no guest lifecycle action, host software installation, real signing identity, credential operation, permission grant or app window was used. The new runtime archive is local and uninstalled, and has not been published as the digest-named CI dependency; release/fetch from a clean machine needs that separately authorized publication. No compatibility result establishes live boot, dependency availability, owner/SSH setup, focus, sleep/wake or crash acceptance for a real image.
