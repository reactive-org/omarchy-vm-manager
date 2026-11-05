# Separate home disks

New VMs default to a **64 GiB system disk** and a **64 GiB home disk**. Choose **New VM → Separate home disk** to turn this off and keep `/home` on the system disk. Existing VMs retain their recorded layout; this feature does not split or migrate an existing single disk.

Both sizes are configurable. The system disk supports 64–8192 GiB and the home disk 16–8192 GiB. Disks are sparse: these are maximum logical capacities, not immediate allocations. A stopped VM's disks can grow independently; shrinking and changing an existing VM's layout are refused. Filesystem growth happens on the next normal launch. Growth is not a backup or a guarantee of sufficient host free space.

Separate disks and APFS clones do not replace an external backup.

Before increasing ext4 capacity, the guest runs a full automatic filesystem check (`e2fsck -p -f`) and then `resize2fs`. Normal boots use the quick check and skip resizing when the filesystem already fills the device. An unsuccessful check or resize blocks login and preserves the volume.

In **Guest Defaults → New guest disks**, set the system capacity, separate-home preference and home capacity, then choose **Save Disk Defaults**. These non-secret settings are stored separately from owner/password defaults. New GUI and CLI profiles inherit them; changing defaults leaves existing profiles unchanged.

## Replace the system and reuse home data

Shut down the source VM and wait for its runtime to exit. Choose **Replace System…** on its Home page. This opens New VM with the source selected under **Home data**. Give the replacement a unique name, select its factory image and system capacity, then create it. The same choice is available from the ordinary New VM form.

On the replacement's first launch, the manager takes the source's runtime-compatible storage lock and makes an APFS copy-on-write clone of its home disk. The source must still be stopped then. The original VM and its system/home disks are preserved. The replacement gets a distinct writable file; later writes do not update the source. This is data reuse by cloning, not simultaneous writable attachment of one disk to two guests. Keep the original until the replacement has been checked.

The replacement retains the source's owner setup snapshot, with a new hostname suffix. Its saved password may need authorization again to provision the fresh system. Manual sources require manual setup with the same username and uid/gid 1000. A mismatched owner is refused by the guest. Root/system configuration and installed packages are not transferred. Managed SSH keys and the SSH host identity are freshly prepared for the new VM; personal files and credentials inside the home are copied with it.

Copying preserves the source's configured home capacity. Grow the replacement afterward if needed. The source cannot be deleted through the manager while a replacement still needs its first-launch copy, or if the replacement's recorded copy is incomplete or damaged. Once copied, the replacement can run independently. Deleting a VM moves its entire verified UUID root, including both disks, to Trash under the normal lock; no disk is recursively erased.

## CLI

```sh
# Defaults: separate home on, 64 GiB each (unless changed in Guest Defaults).
omarchy-vm create dev --system-disk 64GiB --home-disk 128GiB

# One disk containing both the system and home.
omarchy-vm create compact --separate-home off --disk 128GiB

# A fresh system with a copy of a stopped source's home. Substitute its UUID.
omarchy-vm create replacement --reuse-home-from SOURCE_UUID --system-disk 64GiB

# Stopped guests only; applies filesystem growth at the next launch.
omarchy-vm update GUEST_UUID --system-disk 128GiB --home-disk 256GiB
```

`--disk` and `--disk-gib` remain aliases for the system capacity. `--home-disk-gib` accepts a plain GiB integer. Specifying a home capacity or reuse source opts into a separate disk unless `--separate-home off` is explicit; that contradictory combination is refused. Creation JSON adds `separateHome`, `homeDiskGiB` and `reuseHomeFrom` (UUID). The existing `diskGiB` key remains the system capacity. `get`/`list` report `diskGiB` and optional `homeDisk` identity, capacity and copy-source UUID. `--wait running` observes runtime readiness; use `--wait ssh` for authenticated guest readiness.

## Storage and guest behavior

Manager storage remains under the VM's UUID root:

```text
shell/disk.img          system disk, managed by the upstream launcher
home/disk.img           optional persistent ext4 home disk
home/state.json         file identity and last prepared capacity
.omarchy-home.json      immutable home identity and initial/copy plan
```

The manager creates/clones/grows only explicit manager-owned files under the runtime-compatible lock. It refuses linked, foreign, public, missing, unexpectedly replaced or truncated disks. Interrupted creation/growth with inconsistent metadata is preserved for explicit recovery. It never silently replaces a recorded home with an empty disk. Registry schema 6 protects the new layout from older manager versions; the runtime writes storage format 2 so older launchers refuse prepared two-disk guests. No automatic downgrade is supported.

**PRIVATE COUPLING:** the client has an optional `homeDisk` configuration field and the verified runtime lock requires `homeDiskVersion: 1`; protocol 1 alone is insufficient. The helper derives the disk path from the explicit root and validates its private plan, file identity and size. QEMU attaches one `virtio-blk` disk with serial `omarchy-home`, alongside the existing system disk. No production client environment override or alternative VM implementation is used.

The reviewed `try-omarchy 0.1.0-47` package supplies `try-omarchy-home.service`. It runs after owner provisioning and before graphical, tty and SSH login. This ordering follows the [upstream account-setup unit](https://raw.githubusercontent.com/omacom/omarchy/quattro/install/provisioning/omarchy-provision-owner.service); vendor [systemd drop-ins also apply to aliases](https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html#Description). It formats only a disk carrying the exact new-blank token and requested UUID, consumes that token before formatting, and copies the newly provisioned `/home` on first initialization. Subsequent boots/reuse require the matching ext4 UUID and root-owned owner marker; they never copy the new system's home over existing home data. The filesystem is checked/grown in a staging mount, then bind-mounted over `/home` before staging is unmounted. This supports systemd guests whose `/run` parent is shared; moving a mount from there is refused by Linux. No `/etc/fstab` or Omarchy-owned program is rewritten. Missing prerequisites, a mismatched owner, an unrecognized disk or failed initialization blocks login and preserves the disk for recovery.

For a two-disk boot, the runtime also supplies that same unit and its required-login drop-ins as [systemd boot credentials](https://www.freedesktop.org/software/systemd/man/latest/systemd-debug-generator.html#System%20Credentials). They are available before the package update, so a missing/failed update cannot silently bypass the home service. This requires systemd 256+ with its credential generator, as used by the supported contemporary Omarchy images; older/custom systems without that mechanism are unsupported for separate-home mode. The unit is conditioned out of the initrd. The kit seals both boot-gate resources alongside its scripts and archives.

The current reviewed lean image's complete 43.1 archive remains image evidence. The newer runtime supplies the reviewed 47 package to official guests and its separately reviewed native-rendering 47.1 variant to lean guests through the existing offline integration-update mechanism. The native variant preserves the prior checked rendering transformation, including the VirGL alpha-format quirk and removal of forced-software wrappers. Both archives are pinned; there is no fallback from a missing or damaged lean archive to the standard one. Historical format-2 runtime package filenames remain internally consistent provenance, without being confused with the current runtime archive. Legacy schema-1 exact-runtime receipts retain their existing restrictions. New schema-2 receipt hashes bind the guest/image contract independently of the host package; the exact prior reviewed schema-2 digest is accepted only while that guest/image contract is unchanged, without rewriting receipts.

Experimental hibernation is disabled for separate-home guests until its saved-session contract protects and verifies both disks. Normal shutdown, manual pause and host sleep remain owned by the upstream runtime; handles and resource/port reservations are retained until matching `.exited`.

## Disposable acceptance — 4 November 2026

**VERIFIED — real Mac, reviewed lean factory:** an explicitly authorized run uses a private test registry, newly generated VM UUIDs, synthetic in-memory owner credentials, NAT, background launch intent, disabled clipboard/authentication and no host share. Runtime source `b5a9599ad4d67632e9957419432bfccbdb39ba39` supplies native package `0.1.0-47.1`.

| Check | Observed result |
| --- | --- |
| New separate-home defaults | 64 GiB system + 64 GiB ext4 home; owner setup and pinned authenticated SSH succeed |
| Fresh system replacement | New 80 GiB system with an APFS clone of the 64 GiB home; the old system-only marker is absent |
| Home preservation | File hashes, hidden/nested files, symlink/hardlink relationships, permissions, uid/gid, user xattrs and a sparse file survive |
| Independent writes and growth | Replacement-only mutations survive reboot after growth to 96 GiB system + 80 GiB home; filesystem and block-device capacities are checked |
| Original rollback | Original 64/64 GiB guest boots with its original fixture contents and without replacement-only changes |
| Single-disk option | One 64 GiB system disk, no extra home block device; home shares the root Btrfs volume and retains fixtures across reboot |
| Shutdown | Six matching clean exits across three guests; the successful run has no open files or remaining captured runtime processes |

The live run found and fixed three issues before passing: moving a mount from beneath shared `/run`, identifying the visible filesystem when `/home` has stacked mounts, and the full ext4 check required before offline growth. Failed attempts blocked managed SSH and preserved the test disks; the serial-console requirement was also added after the initial attempt. A container-only regression verifies shared-parent bind mounting and checksum preservation after forced-check growth.

The final host audit finds all 224 captured process identities from all attempts absent, all seven disposable VM roots stopped with runtime-compatible locks available, and the existing three-profile registry hash and recorded VM-file metadata unchanged. The successful run's three roots have no open files. Two older diagnostic roots retain read-only filesystem-sharing cache handles in an unrelated virtualization process; it was left running. After explicit cleanup approval, all seven roots were moved to Trash through the guarded deletion path. Each Trash destination retains the captured directory device/inode identity; original paths and test-registry entries are absent. Trash was not emptied, and existing registry/disk metadata still matches the baseline. Nothing was installed or published, and no personal VM or real credential was used.

Normal no-VM validation passes 248 Swift tests in 41 suites (the live test disabled), 82 script tests, 564 upstream Swift tests, guest-package fixtures, and both optimized policy checks in normal release and `SIGNED_PRERELEASE`. The managed SSH container integration checks also pass. The separately staged review app passes signature, inventory, macOS compatibility and bundle-only checks. The opt-in `make test-home-disks` harness requires an explicit private approval file; ordinary `make test` starts no VM. Exact private run receipts are indexed by `.build/home-disk-poc-current`, including `final-host-audit.json`, guest check results and matching lifecycle events. No credentials or home-file contents are logged.

**TO PROVE:** separate-home operation on the official factory or other custom images, simultaneous home-volume guests, native UI flows, focus/sleep/wake/crash behavior, live disk-full/interrupted-format recovery, metadata beyond the synthetic fixtures (including ACLs), and a two-disk hibernation restore contract. These live results establish the listed cases on the reviewed lean factory, not every guest or failure condition. Hibernation remains disabled for separate-home guests.
