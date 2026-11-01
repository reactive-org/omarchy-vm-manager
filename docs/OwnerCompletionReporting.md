# Completion reporting after host cleanup

**DESIGN DECISION:** the owner report timer remains active for the entire seeded boot. It starts after host configuration and repeats ten seconds after the report service becomes inactive. Successful host cleanup does not stop, mask or reset it. Each subsequent invocation must produce the same correctly bound completion without needing a password or the deleted setup manifest.

## Trusted inputs and ordering

1. The helper validates the private UUID root, full setup manifest/seed agreement and selected official or lean factory contract. It hashes the canonical public tuple `(schemaVersion, vmID, sessionToken, fingerprint, owner, ownerSetupContractSHA256)` and supplies it as `tryomarchy.managed_setup_report` through the existing SMBIOS/systemd `tryomarchy.host` credential. Public environment overrides cannot set it. The guest's root-owned host-config service publishes that boot credential in `/run/try-omarchy/cmdline`.
2. Before managed provisioning functions run, the guest checks the binding against that credential and performs the existing strict contract/program verification. The durable owner identity still binds VM, configuration fingerprint, owner and contract. Its file and directory are flushed before upstream cleanup.
3. The same commit boundary retains and flushes a root-private mode-0600 `/run/try-omarchy/managed-setup/report-session.json`. It contains only the public binding and current kernel boot ID. It contains no password, full configuration, email, full name, hostname or credential reference. A failed write/flush prevents cleanup and acknowledgement; retries must revalidate an existing receipt rather than overwrite damaged state.
4. After upstream pending/setup-user/authorized-keys/rekey markers and the finalization warning are gone, the guest checks the committed identity and owner account, then reports configured. A retained manifest must agree with the boot credential and receipt. Once the host has removed it, including an invocation racing the unlink, the guest uses only the validated receipt. Missing receipts, unsafe/damaged files, unknown contracts, mismatches and incomplete cleanup still fail closed.
5. Host `ManagedOwnerStorage.finish()` deliberately keeps its current behavior: durably record completion, then promptly unlink the temporary password seed, full manifest and launch marker. It retains none of those files to support the timer. The host still accepts a report only for its requested VM/session/configuration fingerprint/owner and fresh reception time; managed SSH still requires the current-session configured owner report and authenticated connection.

**PRIVATE COUPLING:** the immutable launch digest binds all public fields to this helper-authorized session. The volatile receipt additionally binds the current kernel boot. The guest rechecks the known contract, private file properties, committed identity, owner account and cleanup before each acknowledgement. A receipt or status from another session cannot acknowledge this launch. A missing manifest alone never implies success.

On a normal later cold boot with host completion already recorded, no setup seed or managed-setup flag is staged, so this timer is not activated and no owner setup repeats. If the host legitimately stages a fresh session after an interruption, a matching durable guest identity and current validated manifest may establish a fresh volatile receipt. An old boot's receipt cannot do so. Runtime handles and resource reservations remain owned until matching `.exited`, independently of owner completion.

Both Omarchy program contracts remain unchanged: official `d381667f407b5f82cfb9f9c391eccf2898ba8a064bc6b2f082e28f959e76aef8` and lean-e4fffc6 `1347cb16b831eb2c3a67344a5bbb68c9da776a55221ecab5ba90ce385078d310`. Unknown/mixed program sets remain rejected before execution. `ownerSetupReportVersion: 1` is required in the reviewed runtime and prepared factory descriptor; protocol 1 alone does not establish reporting support.

## Reviewed build and pins

| Component | Value |
| --- | --- |
| Integration source | `1ecd8499d271cd761e8b4be0e49747de96e57768` |
| Kit package | `try-omarchy 0.1.0-43` |
| dev-vm hardware-policy variant | `try-omarchy 0.1.0-43.1` |
| Patch SHA-256 | `02d9ff27a0e5861a07c383b5d115228d713f69890f8187b7b79e146cc15b8a6b` |
| Kit archive SHA-256 | `3c4a3ac1e7a6efc2200db67c65b8d44da2e65bfe459b49ffb44e1d10f274508f` |
| Runtime-lock SHA-256 / compiled pin | `37aeca15303be1d491b9ed39109e4d0fc273093fe88dc1ac9f0b56fa05822cfb` |
| Manager preview | `0.9.2 (15)`; not installed or opened |

## Matching lean rebuild

The corrected adapter requires a new matching factory rebuild. Do not patch or relabel the retained 42.1 disk or substitute its package/version/metadata. Preserve that artifact and all current guests.

```sh
cd '/Users/danwas/Development/Projects/Omarchy VM Manager'
make prepare-source
integration_source=$(cd .build/runtime-source && pwd -P)
git -C "$integration_source" rev-parse HEAD
# Must be 1ecd8499d271cd761e8b4be0e49747de96e57768

make -C /Users/danwas/Development/Projects/dev-vm build-omarchy-image \
  OMARCHY_IMAGE_TRY_SOURCE="$integration_source" \
  OMARCHY_IMAGE_TRY_COMMIT=1ecd8499d271cd761e8b4be0e49747de96e57768 \
  OMARCHY_IMAGE_SIZE_GIB=20
```

Use the resolved checkout path; the builder rejects a symlink source. The existing dev-vm transformation must yield 43.1, preserve the reviewed managed owner/SSH scripts and contracts, and retain its checked hardware-rendering policy, including the native VirGL quirk. The kit offers 43, so its version comparison preserves the newer 43.1 hardware-policy package. Do not downgrade it or restore forced software-rendering wrappers.

Verify the new artifact's full checksums, package/provisioning audits, source commit and new raw/compressed disk identities. Prepare a separate flat bundle using [LeanOwnerSetup.md](LeanOwnerSetup.md#prepare-and-import-the-rebuilt-artifact), `--owner-contract lean-e4fffc6`, and the new compatibility/build evidence. The preparer and importer reject old/missing report capability and unmatched runtime/source/package provenance. Import/create/live validation requires an explicitly authorized matching manager update; this task does not install the app or operate any VM.

## Isolated validation and remaining live acceptance

**VERIFIED — isolated:** Swift host tests execute the actual `ManagedOwnerStorage.finish()` between fresh Python reporter processes for both contracts, proving password/manifest/launch-marker removal and repeated matching reports. Guest tests cover both contracts, the unlink race, wrong VM/session/owner/fingerprint/contract, malformed identity/receipt, old boot/session credentials, unsafe files, incomplete cleanup/warnings and interrupted durable commits. Helper and guest share a canonical digest golden vector. The normal complete-kit/inventory/ad-hoc-signature and manager/upstream test pipelines run without a VM.

**REPORTED LIVE — 42.1, not this corrected build:** the supplied dev-vm acceptance record observed successful owner provisioning, cleanup, authenticated SSH and hardware VirGL, followed by the failed report timer. It does not establish acceptance of 43/43.1. No retained guest or disk was inspected, restarted or modified for this fix.

**TO PROVE — separately authorized fresh disposable official and lean guests:**

1. Use the matching reviewed manager/kit and a new 43.1 lean artifact. Keep all retained guests untouched.
2. Confirm unattended setup, expected saved settings through redacted comparisons, committed identity and prompt absence of all three host setup files without inspecting password contents.
3. Observe at least three subsequent timer activations after host cleanup. The timer should remain active and each service result should succeed, with no failed unit masking/resetting. Verify the private receipt and current-session reports, and authenticated pinned SSH before and after those activations.
4. Gracefully cold-restart only each new validation UUID. Completed owner setup must not repeat; no new seed should be staged, and SSH must authenticate for the new runtime session. Interruption/recovery injection needs separate explicit approval and remains unobserved here.
5. Recheck actual hardware rendering and native desktop health on the rebuilt lean image, then the intended playbook, identical reapplication and post-restart idempotence. Earlier 42.1 results do not substitute for this acceptance.
6. Shut down the new guests, confirm matching exits and no remaining helper/QEMU processes or disk handles, and offer Trash cleanup. Do not operate any retained guest.

Real timer behavior, boot, crash/interruption, sleep/wake and hibernation behavior remain **TO PROVE** for this build. Isolated fixtures do not establish those results.
