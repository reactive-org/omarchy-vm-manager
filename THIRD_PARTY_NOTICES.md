# Third-party notices

Omarchy VM Manager uses the MIT-licensed Try Omarchy client and embeds a private patched TryOmarchyKit.bundle based on Try Omarchy v1.3.0. The exact upstream source, clipboard/guest-identity runtime patch and binary provenance are recorded under Config/ and Patches/. The kit is an internal development build, not an official upstream release.

The kit includes QEMU, VirGL, libslirp, zstd, firmware and other runtime dependencies under their respective licenses. Preserve the complete upstream notice and embedded license files when distributing any build. The complete upstream notice is bundled as Contents/Resources/TryOmarchy-THIRD_PARTY_NOTICES.md (source: Vendor/try-omarchy/THIRD_PARTY_NOTICES.md). Also preserve the kit's firmware/networking license files and the upstream source license notices. No public distribution or trademark authorization is implied by this private build.

The manager's scoped Accessibility repair is adapted from Try Omarchy v1.3.0's `AccessibilityPermissionRepair` and `VMApplicationController` request flow, Copyright (c) 2026 Try Omarchy contributors, under the MIT License in `Vendor/try-omarchy/LICENSE` and the kit's `Contents/Resources/LICENSE`.

The manager's original stacked-frame artwork uses an Omarchy-inspired green palette and dark tile. Its SVG is in App/Assets. Icon rendering and packing reuse the MIT-licensed Try Omarchy tools from the pinned vendor source. The kit's existing assets remain part of the upstream runtime.

The guest icon uses the official Omarchy logo from https://omarchy.org/brand/omarchy-logo.svg. Its original SVG, source SHA-256 and derivation metadata are preserved in `App/Assets/OmarchyGuest-source.*`; the official path is unchanged and rendered white on a neutral dark tile. Omarchy is a pending trademark of the Omacom Foundation. All rights reserved. Brand and Foundation references: https://omarchy.org/brand/ and https://omarchy.org/foundation/.

Omarchy VM Manager is a project of reactive.org enterprises: https://www.reactive.org/. This project credit does not assign ownership of upstream names, marks or software to reactive.org enterprises.


The developer provisioning library uses the source snapshot from reactive-org/dev-vm
at `bb3fae22be45b38035fac52aefa0eb270a9d0fea` plus the exact durable-state integration
patch (including reviewed manifest metadata, explicit transport verification and private original-resource references) in
`Patches/dev-vm-durable-state.patch`. Guest resources/parser dependencies
and the C launcher retain their upstream bytes.
`Config/DevVMProvisioning.lock.json` inventories the exported source and
`Vendor/DevVMProvisioning.md` records the integration boundary. This adds no host
Python/Ansible runtime distribution. The engine retains guest-side Python/shell
helpers as data.

The shared library compiles the CYaml/LibYAML subset from Yams 6.2.2 and uses
TOMLDecoder 0.4.5 at `a2bbd2796fe3064e107de18cb56031052c4fa899`. Preserve the
Yams, LibYAML and TOMLDecoder license files in the provisioning resource bundle
(`Resources/Yams-LICENSE.txt`, `LibYAML-LICENSE.txt`, `TOMLDecoder-LICENSE.txt`).
Exact parser revisions/hashes and license sources remain in the pinned package's
`ThirdParty/ParserInventory.json`. TOMLDecoder remains an exactly resolved SwiftPM
source dependency, not an installed host program.

## SwiftTerm 1.99.0

Native provisioning terminal: https://github.com/migueldeicaza/SwiftTerm, revision `2dad6a1e516f755bed77cf9bbd09455062f54758`. Library-only export in Vendor/SwiftTerm; one reviewed grapheme-length guard is recorded in Patches/swiftterm-bounded-graphemes.patch; other source and license bytes are unchanged. The manager supplies a deterministic build-identity/terminfo and display-configuration overlay and a local package manifest. Process frontends, build plugins and external dependencies are excluded.

Copyright (c) 2019-2026 Miguel de Icaza (https://github.com/migueldeicaza)
Copyright (c) 2017-2019, The xterm.js authors (https://github.com/xtermjs/xterm.js)
Copyright (c) 2014-2016, SourceLair Private Company (https://www.sourcelair.com)
Copyright (c) 2012-2013, Christopher Jeffrey (https://github.com/chjj/)

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
