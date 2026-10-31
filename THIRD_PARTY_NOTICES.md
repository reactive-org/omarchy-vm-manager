# Third-party notices

Omarchy VM Manager uses the MIT-licensed Try Omarchy client and embeds a private patched TryOmarchyKit.bundle based on Try Omarchy v1.3.0. The exact upstream source, clipboard patch and binary provenance are recorded under Config/ and Patches/. The kit is an internal development build, not an official upstream release.

The kit includes QEMU, VirGL, libslirp, zstd, firmware and other runtime dependencies under their respective licenses. Preserve the complete upstream notice and embedded license files when distributing any build. The complete upstream notice is bundled as Contents/Resources/TryOmarchy-THIRD_PARTY_NOTICES.md (source: Vendor/try-omarchy/THIRD_PARTY_NOTICES.md). Also preserve the kit's firmware/networking license files and the upstream source license notices. No public distribution or trademark authorization is implied by this private build.

The manager's scoped Accessibility repair is adapted from Try Omarchy v1.3.0's `AccessibilityPermissionRepair` and `VMApplicationController` request flow, Copyright (c) 2026 Try Omarchy contributors, under the MIT License in `Vendor/try-omarchy/LICENSE` and the kit's `Contents/Resources/LICENSE`.

The manager does not use upstream's icon for its own application identity. The kit's existing assets and guest package remain part of the upstream runtime.
