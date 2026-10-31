# Factory image downloads

The manager and CLI use the same cache at `~/Downloads/Omarchy VM Manager/Factory Images/`. It is created on the next launch that needs a new disk and an image download. No image is downloaded just by opening the manager or creating metadata.

Files use the pinned factory identity: `<identity>.img.zst` for a completed verified image, `<identity>.img.zst.download` for resumable partial data. Different guests share the download. The kit's existing exclusive directory lock serializes concurrent downloads, and a new guest verifies the cached image's full checksum before reuse. Corrupt cached bytes are replaced through the normal verified download path. The launcher still verifies the compressed image before decompression.

The current factory image is kept. Successful verified reuse refreshes its modification time. Cleanup runs when preparing a download or receiving VM readiness; it removes only obsolete image downloads unused for at least seven days and skips a locked cache. It preserves unknown files, symbolic links, hard links and unsafe entries. The active image is never removed by startup cleanup, even after a guest is ready. There is no daily forced redownload of an unchanged pinned image.

The cache uses private owned folders and files and refuses links or unsafe permissions for active image files. It does not silently fall back to a per-guest download if Downloads is unavailable. macOS may ask for Downloads access when the first download is needed; the app does not grant that permission itself.

Guest writable disks and decompressed factories stay in their original UUID roots. Deleting a guest does not delete the shared download. Existing disks need no migration and do not download again simply to boot. The personal/default Try Omarchy root retains upstream behavior.

You can remove this cache manually to reclaim space while no guest is being prepared. The next new guest downloads it again. Existing guests can still boot from their own disks.

## Validation

**VERIFIED — no-VM tests:** shared destination selection for distinct manager UUIDs; normal-root isolation; malformed/linked/mismatched markers; private directory preparation; refusal of unsafe folders and active image files; new-disk verifier admission; existing-disk bypass; seven-day retention including current-image preservation, recent obsolete images, resumable partials, unknown files, links and held locks. Existing downloader tests cover cache reuse without HTTP requests, corruption recovery, interrupted resumption, checksums and waiting on another downloader.

**VERIFIED — approved real CLI run:** fresh guest consumption and second-guest reuse passed in the follow-up below. The four retained disks and personal Try Omarchy VM stayed untouched.

App 0.5.1 (8): `make test` passes 92 Swift tests in 21 suites and nine artifact checks. The rebuilt helper passes 540 Swift tests in 105 suites, the full upstream no-VM `make test` suite, and kit validation. `make app verify-app` passes exact inventory, signature, layout, compatibility and preflight checks. The packaged CLI reports 0.5.1 and returns the same four retained guests as stopped. Source `c37420b963a7e6e6dd855deae6e2929783f90293`; kit SHA-256 `e003d864e83dbd1bf19946a8f7d52044b82bbb76294d20266e1e18420b14a9b4`. Only the helper, rebuilt guest-package archive metadata, kit manifest and signature changed in the kit inventory; QEMU, firmware and factory download metadata are unchanged.

## Real CLI cache acceptance — 31 October 2026

The user explicitly approved two new disposable guests, the factory download, and final stop/Trash cleanup. The cache initially contained neither the completed image nor a partial file. All four existing guests were stopped, with profile digests and complete disk-tree stat snapshots recorded before the run. Ownership markers and settings were also hashed; no retained disk contents or private keys were read.

Both new profiles were created through the packaged CLI with 4 GiB RAM, four CPUs, windowed mode, clipboard disabled, managed SSH and saved unattended defaults. A downloaded the 3,172,067,004-byte pinned factory image into Downloads, prepared its own disk, completed unattended setup, and authenticated through its generated pinned SSH configuration at `127.0.0.1:2224`.

B started from a distinct fresh UUID root while A remained running. Its progress entered `verifying-download 100%` with no `downloading` events. The completed cache file retained its device, inode, size and birth time, had no partial download, and advanced its last-use modification time. In the exact pinned helper, that timestamp refresh occurs only after the cached image passes its full SHA-256 check, before returning without HTTP requests. B then prepared its own disk and authenticated at the separate endpoint `127.0.0.1:2225`. Both authenticated identity reports matched their expected VM, current session and non-root owner. Both reported NAT guest IP `10.0.2.15`.

The kit's downloader and launcher performed checksum verification against the pinned image manifest. A separate direct checksum read by the test process was blocked by macOS Downloads privacy, so no independent external hash is claimed. No additional permission was granted. Reuse is established by the pinned verifier's successful branch, its last-use timestamp update, the unchanged file identity and the absence of download events in B's complete preparation history.

Each guest was stopped through `stop --wait`; matching `Exited (0)`, closed disk handles and no remaining test QEMU/launcher process were confirmed before CLI deletion. Both complete roots were moved to recoverable Trash and their profiles removed. The shared verified cache remained present with the same file identity and last-use timestamp after cleanup.

All four retained profiles exactly match their initial digests. Every recorded retained tree entry matches its baseline device/inode, ownership, mode, link count, size and modification/change timestamps, along with marker/settings hashes. They remain stopped. No personal Try Omarchy VM, host sleep/wake, guest UI or Accessibility permission was exercised. Graphics-startup behavior remains outside this cache check.

Private test journals are under the ignored `.build/cache-e2e/` directory. This acceptance run changed no production code.
