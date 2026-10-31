# Reviewed lean owner setup

The official contract remains byte-for-byte unchanged in `Sources/OmarchyVMManagerCore/Resources/OwnerSetupContract.json`. Its digest is `d381667f407b5f82cfb9f9c391eccf2898ba8a064bc6b2f082e28f959e76aef8`. Explicit `--owner-contract lean-e4fffc6` selects `LeanOwnerSetupContract.json`, digest `1347cb16b831eb2c3a67344a5bbb68c9da776a55221ecab5ba90ce385078d310`. The app's normal official choice remains **Offical Try Omarchy**.

## Source review

**VERIFIED — source inspection:** the supplied artifact's raw disk digest is `5d8e93f8c02fea92d534fce2d31bccfe8587c5a52eab3ed5dfcb695bced72d18`. Its compatibility record names Omarchy `4.0.0.r7481.ge4fffc6-1.1`, `try-omarchy 0.1.0-36.1` and four owner-program hashes. The extracted package programs match those hashes. The isolated image checks explicitly do not establish owner-account or hardware-rendering success.

| Interface | Reviewed result |
| --- | --- |
| `apply_keyboard(keymap)` and `omarchy_persist_input_selection()` | Same interfaces and identical 52-entry keyboard table. Console keymap persistence/readback, input method and XKB selection remain upstream-owned. Unknown keymaps and failed persistence fail setup. |
| `create_user()` | Both pin `setup-user`, create or resume the same account, set passwords through stdin and preserve upstream groups/policy. Lean removed full-name propagation. The lean adapter applies the saved GECOS name before cleanup. |
| `finalize_user()` | Both use `runuser`, the account's home and shell, `provision-owner`, and `--force --first-install`. Lean execution is bound to the checked `/usr/bin/omarchy-provision-user`, bypassing the separate Omarchy alias. Lean removed the name/email environment inputs. Its reviewed adapter preserves saved Git name/email before cleanup; empty fields remain unset. |
| `run_provisioning()` | Same account, login, hostname/timezone, finalization, boot and cleanup sequence. A failed finalizer sets a warning but upstream continues. The managed adapter guards cleanup so that warning preserves `pending` and `setup-user`, stops acknowledgement and blocks SSH until retry succeeds. |
| Top-level dependencies | Lean additionally sources `progress-icon.sh`. The lean contract pins that file and `omarchy-provision-user` alongside owner/setup-form/LUKS programs. Interactive localization/progress differences do not alter the managed function interface. |
| Failure and retry | Opted-in failures emit only a bounded code and return failure. Contract mismatches cannot launch an unverified interactive fallback. Unseeded setup still runs the normal interactive program. A retry may only resume the recorded owner; encrypted, wipe-pending and unrelated-account states remain refused. |
| Completion boundary | A root-only callback records and flushes the bound completion identity before upstream cleanup. A failed flush prevents cleanup and is retried even when the record exists. Matching committed identities can resume interrupted cleanup; other identities fail closed. Acknowledgement requires all cleanup markers gone. Seeded SSH waits for a configured owner report matching the current VM/session. |

**PRIVATE COUPLING:** the adapter loads only signed-package contracts with compiled known digests. Programs and parents must be root-owned, non-writable by group/other, regular and non-linked; hashes must exactly match one complete set. Source programs/dependencies are snapshotted privately before Bash loads them. The cleanup wrapper is derived from that verified function, never imported executable metadata. Secret answers remain NUL-delimited stdin data, outside arguments/status. Guest Defaults, profile fingerprints, per-guest SSH keys and matching `.exited` lifecycle ownership are unchanged.

## Integration boundary and required rebuild

**The supplied disk needs rebuilding for managed lean setup.** Its integration package lacks this adapter and managed SSH. Injecting the old manager package would also restore software-rendering policy. Do not patch the existing disk or alter an official cache.

The reviewed integration source is commit **`aab6bd82b279cc81c2627be73f7b206ae6dadfc0`**, reproduced by `make prepare-source` at `.build/runtime-source`. It retains the exact stock factory builder and descends from Try Omarchy v1.3.0. The complete kit offers `try-omarchy 0.1.0-42`. The dev-vm builder's existing, checked hardware-policy transformation produces **0.1.0-42.1** from the same source, retaining the managed adapter/SSH/contracts while removing its documented software-rendering wrappers. The existing installer compares package versions and preserves this newer variant rather than overwriting it with 42. Factory admission requires evidence of that source/version; the evidence remains a declaration until live validation.

Use the existing builder and tools; these commands do not install host tools:

```sh
cd '/Users/danwas/Development/Projects/Omarchy VM Manager'
make prepare-source
integration_source=$(cd .build/runtime-source && pwd -P)
git -C "$integration_source" rev-parse HEAD

cd /Users/danwas/Development/Projects/dev-vm
make build-omarchy-image \
  OMARCHY_IMAGE_TRY_SOURCE="$integration_source" \
  OMARCHY_IMAGE_TRY_COMMIT=aab6bd82b279cc81c2627be73f7b206ae6dadfc0 \
  OMARCHY_IMAGE_SIZE_GIB=20
```

The output directory and disk digest will change. Keep the original artifact. Future source/package changes require another review and matched runtime lock; do not substitute a newer hash into an old descriptor.

Use the resolved checkout path as shown: the image builder deliberately rejects a symlink as its source directory. Its `--plan` option can check these inputs without Docker, downloads or an image build.

## Prepare and import the rebuilt artifact

Set `artifact` to the new successful output directory. A separate flat bundle preserves the builder's complete provenance tree:

```sh
artifact='/absolute/path/to/NEW-successful-artifact'
bundle="${artifact}.Manager.factory"
mkdir "$bundle"
cp "$artifact/factory.json" "$artifact/omarchy-workstation-aarch64-edge.img.zst" \
  "$artifact/compatibility.json" "$artifact/image-build.json" \
  "$artifact/source-compatibility.json" "$artifact/provisioning-check.json" \
  "$artifact/user-provisioning-check.json" "$bundle/"

cd '/Users/danwas/Development/Projects/Omarchy VM Manager'
python3 Scripts/prepare_factory_bundle.py "$bundle" \
  --name 'Lean Omarchy e4fffc6' --owner-contract lean-e4fffc6 \
  --compatibility compatibility.json --image-build image-build.json \
  --provisioning compatibility.json --provisioning image-build.json \
  --provisioning source-compatibility.json --provisioning provisioning-check.json \
  --provisioning user-provisioning-check.json
```

Use the CLI from the matching reviewed 0.9.1 app with its matching manager running; an older running manager will not acquire the new contract from a newer CLI. Installation does not open the app or issue guest commands. After the operator has opened the matching manager, run:

```sh
cli='/absolute/path/to/matching/Omarchy VM Manager.app/Contents/MacOS/omarchy-vm'
"$cli" factory-import "$bundle"
"$cli" factories
manifest_sha=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$bundle/reviewed-factory.json")
"$cli" create lean-owner-validation --factory "$manifest_sha" \
  --memory 4GiB --cpus 4 --disk 64GiB --owner-defaults on --ssh on
```

Creation records metadata only and requires previously saved Guest Defaults. It does not boot the disposable guest. Record the returned UUID; live start/SSH/playbook/rendering/idempotence checks belong to the separately authorized dev-vm session. No existing guest should be reused.

## Validation limits

**VERIFIED:** source/hash/interface review and synthetic tests exercise both adapter paths, keyboard failures, same-owner retry, warning-marker protection, secret transport, contract/evidence tampering and SSH gating. Complete-kit inventories, pins, package contents and ad-hoc signatures are checked by the normal pipeline.

**TO PROVE:** live lean unattended setup and retry, successful first boot, authenticated SSH with this rebuilt disk, hardware rendering, dynamic display/clipboard, playbook execution/idempotence, reboot and crash/sleep behavior. No image was booted or rebuilt during this manager work. A provenance record does not independently prove the raw disk's contents or a publisher's identity.
