# Custom factories

For a step-by-step build, customisation and import walkthrough, start with
[Preparing and customising a factory image](preparing-factory-images.md).

Click **Import Factory** in the toolbar, or **Import Factory…** beside the image picker in **New VM**, and select a prepared factory bundle. The app verifies it, copies it into its private factory library and saves a local import record. No catalog JSON edit or app rebuild is required. Importing from New VM automatically selects the successfully imported image for that new profile.

The sheet shows verification/copy progress, supports cancellation before publication and displays validation errors for retry. After success, the factory is available in **New VM → Factory image** and remains available when the app reopens. Cancelling the folder picker changes nothing. Import creates no VM root and never starts a guest.

**Offical Try Omarchy** remains the default and an explicit selection. New guest profiles record the factory name, kind, manifest digest and source disk digest. That selection is fixed at creation. Older profiles retain their existing metadata and disks; an absent factory field remains absent. New roots also record the identity in a private `.omarchy-factory.json` marker, which must agree with the profile. Image selection never resets or replaces an existing disk.

## Prepared bundle

Prepare the image outside the manager. This feature does not build a kernel, customize a running guest or create a factory from an existing user's disk. The flat bundle directory contains:

- `factory.json`, using upstream format 1 `upstream-shell-factory`, `platform: "aarch64"` and `boot: "uefi-limine"`;
- the referenced `.img.zst`, with its compressed SHA-256 and the uncompressed disk SHA-256/byte count recorded in `factory.json`;
- provisioning evidence files containing the recipes, package hashes and build records for the image;
- `reviewed-factory.json`, the versioned bundle descriptor produced by the preparation tool.

For bundle producers, the existing tool describes the prepared directory against the matching pinned kit:

```sh
python3 Scripts/prepare_factory_bundle.py /absolute/path/Prepared.factory \
  --name 'Development factory' \
  --provisioning provisioning.json --provisioning build-record.json
```

This generates the descriptor without changing a manager catalog. It hashes the payloads and records the exact complete runtime inventory, integration package digest, owner-setup contract digest and version 1 factory/SSH/setup capabilities. It starts no guest. The filename `reviewed-factory.json` is retained for compatibility with the existing bundle format.

Preparation defaults to the preserved official owner contract. `--owner-contract lean-e4fffc6` explicitly selects the reviewed lean contract and requires `--compatibility` and `--image-build` evidence filenames, both included with `--provisioning`. This is a fixed allowlist, not a way to register arbitrary hashes or programs. The image's recorded program set, integration-source commit and hardware-policy package must agree with this kit. See [lean owner setup](LeanOwnerSetup.md) for the source review, integration rebuild and exact preparation/import commands.

Choose a source you trust. Verification establishes byte integrity and declared compatibility with the pinned kit; it cannot prove that the evidence produced the disk, that an image is credential-free or that it will boot. The image must support this kit's guest integration package and owner/SSH enrollment contracts. Provisioning inputs should establish the image's origin and contain no credentials or per-guest identities.

The manager rejects missing/unknown capabilities, other architectures or boot formats, a different runtime/integration package/provisioning contract, changed payloads or provisioning evidence, extra files, symlinks, directories and special files. Normal complete-kit verification and signature checks remain required. Release policy still rejects the private development kit.

## Local library and persistence

Imports are copied and reverified in a private staging directory before publication under `~/Library/Application Support/Omarchy VM Manager/Factories/<manifest SHA-256>/`. A matching private receipt under `Factories/.receipts/<manifest SHA-256>.json` binds that identity to the exact runtime lock and records the import time. Directory permissions are 0700; payload and receipt files are 0600. Receipt publication is atomic and flushed to disk. Listing, selection and launch revalidate the receipt and bundle; a directory copied into the library by hand does not become selectable.

A repeated intact import reuses its entry and receipt. The source stays independent, so changes to it afterward do not alter the imported factory. A damaged existing entry or receipt is refused and preserved. If an interrupted import published intact files without a receipt, selecting the original bundle again can verify and finish that import. Interrupted or cancelled staging files never make an image selectable.

A changed runtime inventory requires a matching newly prepared bundle. Ordinary manager updates with the same runtime lock retain imported factories. The former compiled review catalog remains supported for older preapproved entries, but is not required for imports made through the app or CLI. Its optional bundled resource remains bound to its compiled digest.

The `factories` listing reports damaged or unregistered entries separately as `factoryIssues`, preserving the official and other valid choices. Unused verified entries can be removed with `factory-delete`; there is no automatic pruning of imported factories. Deleting a guest does not delete its imported factory. The app refreshes its factory picker after CLI import or deletion.

## CLI

The CLI uses the same verification and local receipt path:

```sh
omarchy-vm factory-import /absolute/path/Prepared.factory
omarchy-vm factories
omarchy-vm create custom-dev --factory MANIFEST_SHA256
omarchy-vm create official-dev --factory official
```

`factory-import` returns the imported identity in a `factories` array. The creation config accepts `"factory":"official"` or an imported manifest digest. `get`, `list` and creation replies expose the recorded `factory`, when present. Creation requires a capacity at least as large as the prepared disk. Capacity checks recheck the descriptor digest and image-metadata hash against the recorded identity. Update refuses image changes. The example creates metadata only; it does not start a VM.

## Delete an unused factory

Copy the exact lowercase manifest digest from `factories`, then run:

```sh
omarchy-vm factory-delete MANIFEST_SHA256
```

Success returns `ok: true` and `deletedFactory` with the removed identity. The command waits for Trash to complete. It refuses the official factory (`factory-protected`) and any custom factory referenced by a guest profile or pending creation (`factory-in-use`). Stopping a guest does not release its reference: metadata-only, stopped, running and suspended profiles all protect their recorded factory. There is no `--force`, path selector or automatic profile reassignment. Concurrent import/deletion returns `factory-busy`; an unknown digest returns `unknown-factory`.

Deletion requires the same valid identity, runtime compatibility and receipt or legacy pin used for selection. Damaged or unregistered entries stay preserved for manual review. After verification, the manager rechecks the files and registry before moving the bundle and receipt together into one folder in Trash. It never launches a guest, rewrites a profile or touches guest disks. The original prepared source and the official image's Downloads cache stay unchanged.

The Trash folder is named `Omarchy Factory <manifest digest>-<transaction UUID>`, and contains `Factory.bundle`, its `Import receipt.json` when present, and `Factory deletion.json` recording the identity. To reuse a removed image, restore the folder from Trash and import its `Factory.bundle` through the normal verification flow. No automatic restore is provided.

`factory-trash-failed` restores the library paths when possible. `factory-delete-recovery-required` means a recovery folder remains under the private `Factories` library; preserve it and inspect both its files and the original library paths before proceeding. A process crash can also leave that transaction folder for manual recovery. `factory-delete-outcome-unknown` or a lost CLI reply requires checking both Trash and `factories` before retrying. Already admitted deletion remains owned by the manager if the CLI disconnects; Quit waits for it. Recovery never overwrites a newly appeared library path or recursively erases factory files.

## Runtime boundary and validation

**PRIVATE COUPLING:** the digest-pinned client supplies optional `VMFactorySelection` through `VMRunConfiguration`; `customFactoryVersion: 1` must be present in verified runtime provenance. Protocol 1 alone never implies support. The helper rechecks the manifest digest, payloads, aarch64/UEFI format and matching runtime/package hashes before passing the selected directory to the existing launcher. It suppresses the official download for that selection and receives no manager-side development environment override.

The existing kit implements decompression, sparse disks, APFS cloning, growth, locking, lifecycle, NAT and guest integration under manager orchestration. Before cloning, custom factory preparation additionally checks the uncompressed disk digest, including a previously decompressed custom cache. The integration package remains inside the whole-kit signing/inventory boundary; a factory cannot replace it. SSH enrollment and readiness retain their per-guest and per-session checks.

**PRIVATE COUPLING — reviewed owner contracts:** `ownerSetupContractsVersion: 1` and a hashed `owner-setup-provenance.json` inside the complete signed kit bind the supported contract digests to the reviewed integration-source commit. The factory's `ownerSetupContractSHA256` must be a compiled supported digest. For lean, hashed compatibility/build evidence must also match the compiled program set, source commit and integration version. The helper binds the setup share's selected digest to that verified factory; absent selection means official. Guest-side ownership, permissions, regular-file and exact-hash checks precede managed functions. Managed errors stop without executing an unverified interactive fallback. The guest does not accept a program list supplied through the share.

Large scans and copy/preparation work run outside the lifecycle actor. Cancellation before publication removes the staging copy and creates no receipt. Final publication completes as one commit phase. Quit cancels an uncommitted import and waits for its worker to stop; if publication has begun, it waits for the verified files and receipt to finish. An import counts as active work until that boundary. Older library refreshes cannot remove a newly imported picker choice or replace a newer refresh with stale results/errors. Session/resource admission, pending stop/force-stop and matching `.exited` ownership remain unchanged.

Run `make test`, `make test-factories` and `make app-preview verify-preview` for no-VM validation. Synthetic fixtures cover local import/reopen without compiled pins, receipt corruption/runtime mismatch/permissions/symlinks, cancellation and retry, image/provisioning tampering, metadata-only creation and legacy identity/disk continuity. The helper process test uses synthetic image files and a QMP stub, never QEMU.

**TO PROVE:** a particular custom image's real boot, owner/SSH provisioning, integrations, accelerated desktop, concurrency, focus, sleep/wake, crash behavior and hibernation require separately authorized real-Mac checks. This feature grants no real-guest launch or image-download approval.
