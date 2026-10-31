# Factory image downloads

The manager and CLI use the same cache at `~/Downloads/Omarchy VM Manager/Factory Images/`. It is created on the next launch that needs a new disk and an image download. No image is downloaded just by opening the manager or creating metadata.

Files use the pinned factory identity: `<identity>.img.zst` for a completed verified image, `<identity>.img.zst.download` for resumable partial data. Different guests share the download. The kit's existing exclusive directory lock serializes concurrent downloads, and a new guest verifies the cached image's full checksum before reuse. Corrupt cached bytes are replaced through the normal verified download path. The launcher still verifies the compressed image before decompression.

The current factory image is kept. Successful verified reuse refreshes its modification time. Cleanup runs when preparing a download or receiving VM readiness; it removes only obsolete image downloads unused for at least seven days and skips a locked cache. It preserves unknown files, symbolic links, hard links and unsafe entries. The active image is never removed by startup cleanup, even after a guest is ready. There is no daily forced redownload of an unchanged pinned image.

The cache uses private owned folders and files and refuses links or unsafe permissions for active image files. It does not silently fall back to a per-guest download if Downloads is unavailable. macOS may ask for Downloads access when the first download is needed; the app does not grant that permission itself.

Guest writable disks and decompressed factories stay in their original UUID roots. Deleting a guest does not delete the shared download. Existing disks need no migration and do not download again simply to boot. The personal/default Try Omarchy root retains upstream behavior.

You can remove this cache manually to reclaim space while no guest is being prepared. The next new guest downloads it again. Existing guests can still boot from their own disks.

## Validation

**VERIFIED — no-VM tests:** shared destination selection for distinct manager UUIDs; normal-root isolation; malformed/linked/mismatched markers; private directory preparation; refusal of unsafe folders and active image files; new-disk verifier admission; existing-disk bypass; seven-day retention including current-image preservation, recent obsolete images, resumable partials, unknown files, links and held locks. Existing downloader tests cover cache reuse without HTTP requests, corruption recovery, interrupted resumption, checksums and waiting on another downloader.

**TO PROVE:** a real fresh guest consuming this cache and a second real guest reusing it. This change does not download the factory image or launch any guest. The four retained disks and personal Try Omarchy VM are untouched.

App 0.5.1 (8): `make test` passes 92 Swift tests in 21 suites and nine artifact checks. The rebuilt helper passes 540 Swift tests in 105 suites, the full upstream no-VM `make test` suite, and kit validation. `make app verify-app` passes exact inventory, signature, layout, compatibility and preflight checks. The packaged CLI reports 0.5.1 and returns the same four retained guests as stopped. Source `c37420b963a7e6e6dd855deae6e2929783f90293`; kit SHA-256 `e003d864e83dbd1bf19946a8f7d52044b82bbb76294d20266e1e18420b14a9b4`. Only the helper, rebuilt guest-package archive metadata, kit manifest and signature changed in the kit inventory; QEMU, firmware and factory download metadata are unchanged.
