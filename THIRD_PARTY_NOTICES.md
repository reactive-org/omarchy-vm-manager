# Third-party notices

Omarchy VM Manager's MIT license applies to its original code. Third-party components retain their own licenses and notices.

Omarchy VM Manager uses the MIT-licensed Try Omarchy client and embeds a private patched TryOmarchyKit.bundle based on Try Omarchy v1.3.0. The exact upstream source, clipboard/guest-identity runtime patch and binary provenance are recorded under Config/ and Patches/. The kit is an internal development build, not an official upstream release.

The kit includes QEMU, VirGL, libslirp, zstd, firmware and other runtime dependencies under their respective licenses. Preserve the complete upstream notice and embedded license files when distributing any build. The complete upstream notice is bundled as Contents/Resources/TryOmarchy-THIRD_PARTY_NOTICES.md (source: Vendor/try-omarchy/THIRD_PARTY_NOTICES.md). Also preserve the kit's firmware/networking license files and the upstream source license notices. No public distribution or trademark authorization is implied by this private build.

The manager's scoped Accessibility repair is adapted from Try Omarchy v1.3.0's `AccessibilityPermissionRepair` and `VMApplicationController` request flow, Copyright (c) 2026 Try Omarchy contributors, under the MIT License in `Vendor/try-omarchy/LICENSE` and the kit's `Contents/Resources/LICENSE`.

The manager's original stacked-frame artwork uses an Omarchy-inspired green palette and dark tile. Its SVG is in App/Assets. Icon rendering and packing reuse the MIT-licensed Try Omarchy tools from the pinned vendor source. The kit's existing assets remain part of the upstream runtime.

The guest icon uses the official Omarchy logo from https://omarchy.org/brand/omarchy-logo.svg. Its original SVG, source SHA-256 and derivation metadata are preserved in `App/Assets/OmarchyGuest-source.*`; the official path is unchanged and rendered white on a neutral dark tile. Omarchy is a pending trademark of the Omacom Foundation. All rights reserved. Brand and Foundation references: https://omarchy.org/brand/ and https://omarchy.org/foundation/.

Omarchy VM Manager is a project of reactive.org enterprises: https://www.reactive.org/. This project credit does not assign ownership of upstream names, marks or software to reactive.org enterprises.

## Try Omarchy upstream notice

The following notice body is reproduced unchanged from [Try Omarchy v1.3.0, commit `13d63df8da2947f833c04025ff5ade187d39ba81`](https://github.com/omacom/try-omarchy/blob/13d63df8da2947f833c04025ff5ade187d39ba81/THIRD_PARTY_NOTICES.md), matching this project's pinned vendor source. Paths in this section refer to the upstream repository or its artifacts. The original file is also retained in `Vendor/try-omarchy/THIRD_PARTY_NOTICES.md` and bundled separately as described above.

Try Omarchy builds and redistributes third-party components under their own
licenses. The repository's MIT license applies only to this project's original
code.

- **Omarchy** — MIT. The factory disk installs Omarchy's own packages
  (`omarchy-dev`, `omarchy-settings-dev` and their dependencies) from
  `pkgs.omarchy.org`; each package carries its license under
  `/usr/share/licenses`.
- **Arch Linux ARM and Omarchy repository packages** — each package retains its
  own license, including Omarchy's `linux-omarchy` kernel (GPL-2.0), Hyprland
  and its libraries (BSD-3-Clause), and Quickshell. The factory's complete
  package set and versions are recorded in `dist/guest/packages.txt`, and the
  `[omarchy]` database digest in `dist/guest/factory.json`.
- **QEMU** — GPL-2.0 and other component licenses. Release maintainers must
  provide the corresponding source and notices required by the exact bundled
  build.
- **edk2 UEFI firmware** — BSD-2-Clause-Patent and the other licenses listed in
  QEMU's `pc-bios/edk2-licenses.txt`, bundled beside the firmware as
  `Contents/Resources/firmware/edk2-licenses.txt`. It is extracted unchanged
  from the pinned QEMU source archive.
- **ANGLE, VirGLRenderer, libepoxy, SDL, libslirp, GLib, Pixman, and other QEMU
  dependencies** — retain their respective upstream licenses.
- **OmacVM** — MIT, Copyright (c) 2026 Gilles Goetsch,
  [github.com/gillesgoetsch/OmacVM](https://github.com/gillesgoetsch/OmacVM).
  The QEMU patches `qemu-hda-no-catch-up`, `qemu-sdl-audio-capture-thread`,
  `qemu-sdl-audio-playback-thread` and `qemu-darwin-main-loop-qos`, and the
  guest's RTKit drop-in, are adapted from OmacVM's; each says so in its
  header. The App Nap patch follows OmacVM's approach.
- **pacstrap-docker** (`guest/vendor/omarchy-pkgs/`) — from
  [omarchy-pkgs](https://github.com/omacom/omarchy-pkgs); used only inside the
  build container.
- **Software users install inside the VM** — packages installed through
  Omarchy's menus or `pacman`, such as Ghostty or 1Password, come from their
  own repositories under their own licenses and are not redistributed by Try
  Omarchy.

See `macos/build-qemu-gpu-runtime.sh` and `macos/stage-uefi-firmware.sh` for
exact host source identities and checksums. Before distributing a release,
follow `docs/releasing.md` and audit the assembled bundle's notices and
corresponding-source obligations.
