# Factory preparation progress

The runtime measures unpacking by the output disk's logical size. With sparse images, trailing zero ranges may not extend that size until the decompressor closes the file. The last sampled percentage can therefore be 49% even when unpacking has completed. The launcher previously never emitted a final 100%, and kept the Preparing phase throughout the additional full disk checksum for a custom factory.

Successful decompression followed by the expected disk-size check now emits Preparing 100%. The runtime immediately enters Finishing before checking a custom disk's digest and compacting the file. The helper calls this “Finishing disk preparation”. Percentages apply to their named phase, not the whole boot; finishing has no measured percentage. A decompression failure or wrong disk size never reports Preparing 100%. A custom digest failure still prevents cloning and startup.

The change uses the existing upstream launcher, progress markers and protocol. It adds no timer estimates, manager disk operations or guest implementation.

## Compatibility

The user approved rebuilding and pinning this runtime, accepting custom factory incompatibility. Existing bundles, import receipts, profiles and guest disks are preserved. Old custom bundles cannot be relabeled for the new runtime; rebuild/reprepare them with matching source and runtime provenance, then explicitly import them. The current lean build instructions are in [Lean owner setup](LeanOwnerSetup.md).

No installed app replacement, guest launch, image download or real signing credentials are authorized by this change. Live progress rendering and real guest behavior remain **TO PROVE** until separately observed.

## Verified no-VM checks — 1 November 2026

- `make build` and `make build icon` pass.
- `make test` passes 162 Swift tests across 31 suites and 34 Python tests. The manager regression checks 49%, 100%, Finishing with no stale percentage, Ready and terminal exit.
- `make test-upstream` passes 551 Swift tests across 107 suites and the full contract, guest-package, shell, networking, compatibility and relocation fixtures. The launcher tests simulate sparse output stalled at 49% for official and reviewed factories, then require 100% before Finishing. Failed decompression, wrong size and wrong custom digest retain their rejection behavior. Parser tests split the completion/phase markers at every byte boundary.
- `GUEST_BUILDER_IMAGE=try-omarchy-guest-builder make patched-kit` passes with the existing local package builder, complete inventory checks and ad-hoc verification of all 22 kit Mach-O files. The initial sandboxed attempt could not verify the stock signature; rebuilding with macOS trust-service access passed. An initial sandboxed upstream test run also lacked local socket and notification access; the complete permitted rerun passed.
- An isolated app assembled with `Scripts/build-app.sh --output-directory "$PWD/dist/preparation-progress-80156396a5da"` passes `Scripts/verify-app.sh` for that app, including signatures, 25-image macOS 15 compatibility, host preflight, exact inventory, NAT-only and no-factory-image layout. No manager session or app window was opened.
- `git diff --check` passes.

| Pin | SHA / commit |
| --- | --- |
| Reproducible source | `80156396a5daa795487c0f4a8308eee53f6ea68b` |
| Patch SHA-256 | `751d75e9ccd1e0e64681a3fa539872a356e8859310fea79e3763f59d25101be2` |
| Kit ZIP SHA-256 | `cb08789aaaac352c888ed8b0c67cb8e018df4855ce015231c9c69c0dc92b34c7` |
| Runtime lock / compiled pin SHA-256 | `cac1444e48e0413f37cb0b97d196b5cad3034782b8c8245f500fc323004f77a0` |

The guest package remains 0.1.0-43 and the reviewed official/lean owner contracts are unchanged. Lean factory evidence must name the new exact source with its matching 43.1 hardware-policy variant. The candidate app is `dist/preparation-progress-80156396a5da/Omarchy VM Manager.app`; it was neither installed nor opened. Existing real-guest, focus, sleep/wake, crash and signed-release acceptance limits remain unchanged.

## Authorized installation — 1 November 2026

The user subsequently requested installation with a backup and no VM launch. Installed the verified candidate at `~/Applications/Omarchy VM Manager.app`, preserving the previous bundle at `~/Applications/.Omarchy VM Manager.backup-28e6f532f5a84184840df50395317f79.app`. Both bundles retain version 0.9.3 (build 16); the installed runtime-lock digest is the new pin above.

Before replacement, checked exact executable paths and open bundle files immediately before the rename. A manager was running from the separate project `dist/Omarchy VM Manager.app`; it was left untouched. The installed destination was inactive. Copied to a private sibling stage, verified signatures/layout and all file hashes/modes, moved the old bundle to its unique backup, and renamed the verified stage into place. Post-install verification passes for both installed and backup bundles against their respective embedded runtime locks. All 64 installed files and directory/file modes match the candidate, and the backup inventory matches the previous bundle. Evidence is retained under `.build/preparation-progress-install/28e6f532f5a84184840df50395317f79/`, including its `summary.json` and verification logs.

No application window was opened, process stopped, VM launched, guest/factory/registry data changed, permission granted or real signing credential used. The running project copy must be closed before opening the installed update because the manager permits one active instance. Live progress acceptance remains **TO PROVE**.

## Authorized reopening — 1 November 2026

The user then explicitly requested closing the running project copy and opening the installed update without launching VMs. The project manager showed zero active guests and zero allocated memory; quit it normally through its UI. Process inspection confirmed it exited and no VM helper/QEMU process was present before opening the installed app. The installed window then showed all five registered guests stopped, zero active guests and zero allocated memory. Process inspection confirmed the sole manager executable was `~/Applications/Omarchy VM Manager.app/Contents/MacOS/OmarchyVMManager`, with no VM helper/QEMU processes. No Launch control or permission prompt was used. This verifies opening the installed update only; real preparation progress remains **TO PROVE**.
