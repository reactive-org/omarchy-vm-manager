# Reviewed custom factories

The manager accepts an already prepared Omarchy factory bundle after its exact review-manifest SHA-256 has been added to the app's reviewed catalog and the app has been rebuilt. Importing a bundle does not approve it. There is no trust-on-first-use switch, runtime override, image download or VM launch in the import command.

The official factory remains the default and an explicit selection. New guest profiles record the factory name, kind, review-manifest digest and source disk digest. That selection is fixed at creation. Older profiles retain their existing metadata and disks; an absent factory field remains absent. A new root also records the identity in a private `.omarchy-factory.json` marker, which must agree with its profile. Image selection never resets or replaces an existing disk.

## Prepare and review

Prepare the image outside the manager. This feature does not build a kernel, customize a running guest or create a factory from an existing user's disk. The prepared directory is flat and contains:

- `factory.json`, using the upstream format 1 `upstream-shell-factory` schema, `platform: "aarch64"` and `boot: "uefi-limine"`;
- the referenced `.img.zst`, with the compressed SHA-256 and uncompressed disk SHA-256/byte count recorded in `factory.json`;
- provisioning evidence files: the recipes, package hashes and build records needed to review how the image was produced and ensure that it contains no credentials or per-guest identities;
- `reviewed-factory.json`, produced by the preparation tool.

Build the matching helper first with `make patched-kit`, then describe the prepared directory:

```sh
python3 Scripts/prepare_factory_bundle.py /absolute/path/Prepared.factory \
  --name 'Reviewed development factory' \
  --provisioning provisioning.json --provisioning build-record.json
```

The tool preserves an existing review manifest, hashes every included payload and prints the new manifest's SHA-256. It records the exact complete runtime inventory, integration package digest, owner-setup contract digest and version 1 factory/SSH/setup capabilities. It starts no guest and grants no trust. Files must have simple basenames; symlinks, directories and special files are refused by import.

Review the image's origin, architecture, boot layout, provisioning inputs and their relationship to the resulting image. The `provisioning` hash map binds evidence bytes; it cannot itself prove that those recipes produced the disk or that the image is credential-free. Review must establish those claims. The image must work with the exact guest integration package shipped by this kit and the manager's owner/SSH enrollment contracts. Record that review with the bundle's provenance before adding its manifest digest to `Sources/OmarchyVMManagerCore/Resources/ReviewedFactories.json`. This file is an array of SHA-256 strings, packaged with the signed app. `make prepare-source` validates it and generates `FactoryReviewPin.swift`; the running manager requires the resource bytes to match that compiled digest. Editing an installed resource cannot approve an image. The catalog initially contains no approved custom images.

A runtime rebuild changes the bound inventory and requires a new manifest and review. The manager rejects missing/unknown capabilities, another runtime, another integration package, changed provisioning evidence, extra payloads, damaged files and unknown manifest pins. Normal app and complete-kit verification/signing checks still apply. Release policy continues to reject this private development kit.

## Import and create

Use the rebuilt manager's CLI:

```sh
omarchy-vm factory-import /absolute/path/Prepared.factory
omarchy-vm factories
omarchy-vm create custom-dev --factory MANIFEST_SHA256
omarchy-vm create official-dev --factory official
```

`factory-import` returns the imported identity in a `factories` array. Imports are copied and reverified in a private staging directory before publication under `~/Library/Application Support/Omarchy VM Manager/Factories/<manifest SHA-256>/`. A repeated intact import reuses that entry. The source stays independent. Changing the source afterward does not alter the imported factory. A damaged existing cache entry is refused and preserved. The `factories` command verifies imported entries and includes the official selection. A damaged or unreviewed entry is omitted from selectable `factories` and reported in `factoryIssues` with its selector; it does not hide other valid entries. The entry is preserved and remains refused at selection. The New VM sheet lists the same choices. The creation config JSON accepts `"factory":"official"` or the imported manifest digest. `get`, `list` and creation replies expose the profile's recorded `factory`, when present.

Factory scans, import copies and runtime preparation run outside the lifecycle actor. Resource/session admission happens before launch preparation, and a stop, force-stop or Quit received during preparation is applied when the runtime handle becomes available. Other sessions’ events remain processable; a returned handle and its reservations are retained until matching `.exited`. Import and metadata-only creation do not create a VM root. Creating a custom guest requires a selected capacity at least as large as the prepared disk. Update refuses image changes. There is no custom-factory removal or automatic pruning operation in this prerequisite; deleting a guest does not delete its imported factory.

## Runtime boundary

**PRIVATE COUPLING:** the digest-pinned client adds an optional `VMFactorySelection` to `VMRunConfiguration`. `customFactoryVersion: 1` in the verified runtime lock is required; run protocol 1 alone never implies support. Older helpers reject the new field. The helper checks the manifest digest, complete payload hashes, declared aarch64/UEFI format and matching runtime/package hashes, suppresses the official download for a custom selection and passes that verified directory to the existing launch script. No manager-side development environment override is used.

The existing kit still implements decompression, sparse disks, APFS cloning, growth, locking, lifecycle, NAT and guest integration under manager orchestration. Custom factory preparation additionally checks the uncompressed disk digest before cloning, including a previously decompressed custom cache. The compressed payload is verified at import and again before launch. The integration package remains part of the unchanged whole-kit signing/inventory boundary; a factory cannot replace it. SSH key generation, enrollment and readiness retain their existing per-guest and per-session checks.

**TO PROVE:** booting a particular reviewed custom image, its unattended provisioning, guest integration, accelerated desktop, real concurrent guests, focus, sleep/wake and crash behavior require separately authorized real-Mac checks. A matching declaration/hash is not a successful guest boot or hibernation result. This prerequisite does not authorize downloading an image or starting a real VM.

## No-VM validation

Run `make test`, `make test-factories`, `make patched-kit`, `make app-preview` and `make verify-preview`. The helper process test uses synthetic image files and a fake QMP launcher. It confirms that the selected directory reaches the helper without an official image download, then rejects changed image, provisioning and package files before starting the fake launcher. It never runs QEMU.
