# Third-party notices

Omarchy VM Manager uses the MIT-licensed Try Omarchy client and embeds a private patched TryOmarchyKit.bundle based on Try Omarchy v1.3.0. The exact upstream source, clipboard/guest-identity runtime patch and binary provenance are recorded under Config/ and Patches/. The kit is an internal development build, not an official upstream release.

The kit includes QEMU, VirGL, libslirp, zstd, firmware and other runtime dependencies under their respective licenses. Preserve the complete upstream notice and embedded license files when distributing any build. The complete upstream notice is bundled as Contents/Resources/TryOmarchy-THIRD_PARTY_NOTICES.md (source: Vendor/try-omarchy/THIRD_PARTY_NOTICES.md). Also preserve the kit's firmware/networking license files and the upstream source license notices. No public distribution or trademark authorization is implied by this private build.

The manager's scoped Accessibility repair is adapted from Try Omarchy v1.3.0's `AccessibilityPermissionRepair` and `VMApplicationController` request flow, Copyright (c) 2026 Try Omarchy contributors, under the MIT License in `Vendor/try-omarchy/LICENSE` and the kit's `Contents/Resources/LICENSE`.

The manager's original stacked-frame artwork uses an Omarchy-inspired green palette and dark tile. Its SVG is in App/Assets. Icon rendering and packing reuse the MIT-licensed Try Omarchy tools from the pinned vendor source. The kit's existing assets remain part of the upstream runtime.

The guest icon uses the official Omarchy logo from https://omarchy.org/brand/omarchy-logo.svg. Its original SVG, source SHA-256 and derivation metadata are preserved in `App/Assets/OmarchyGuest-source.*`; the official path is unchanged and rendered white on a neutral dark tile. Omarchy is a pending trademark of the Omacom Foundation. All rights reserved. Brand and Foundation references: https://omarchy.org/brand/ and https://omarchy.org/foundation/.

Omarchy VM Manager is a project of reactive.org enterprises: https://www.reactive.org/. This project credit does not assign ownership of upstream names, marks or software to reactive.org enterprises.
