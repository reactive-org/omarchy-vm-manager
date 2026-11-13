# Documentation media

[User guide](../README.md) · [Demo video](https://www.reactive.org/omarchy-vm)

The screenshots are actual window captures of a local Dev build, Omarchy VM Manager Dev **0.11.0 (27)**, made from `next` at `9991a69` with the title-bar fix from #45. They were captured through Computer Use on **14 November 2026, Australia/Melbourne**. Local builds aren't stamped with a release version, so the sidebar footer reads 0.11.0 (27). The window title, library header and sidebar footer show Dev branding. The title bar shows the app name beside its icon, followed by the Home, Import factory and New VM buttons. All five existing Dev guests (Rails web dev, Ops workspace, Python data science, Go services and Frontend · Next.js) remained stopped and unchanged. The configuration form was cancelled. Saved defaults and existing guest settings were preserved.

The ten `example-vm-*` images follow a real guest through the New VM flow for [Getting started](../getting-started.md). With the user's approval, **Example VM** was created from the **Lean Omarchy - stable** custom factory (Omarchy 4.5.0), with the Four terminals layout, the Developer setup profile and the default resources, access and 60-minute sudo settings. It was launched through first run to **Ready**. The user answered Omarchy's passwordless sudo prompt after it was captured. The 4.5.0 factory needed almost no updates, so the Installing image shows the setup playbook's recap rather than package downloads. The guest desktop was captured from the guest's own window after the user dismissed three of its four welcome notifications. Example VM was then shut down: it showed **Stopped** and its guest process was confirmed exited. At the user's request it was moved to the Mac Trash through the app's confirmed delete.

The Factory images library shows the official card, **Lean Omarchy - stable** (used by Example VM at capture) and **Lean Omarchy - edge**, an Omarchy development build marked manual account setup. The **Build lean factory** sheet (`factory-build.webp`) and the **Import factory** form (`import-factory.webp`) were not retaken: their contents are unchanged. They come from Dev 0.11.0 (27) on 8 November and 0.11.3 (187) respectively, as recorded in the manifest.

The guides link to the [demo video](https://www.reactive.org/omarchy-vm) on reactive.org. The earlier 48-second MP4 slideshow and its WebVTT captions were removed on 8 November 2026.

## Size and format

The 23 WebP screenshots total **1,190,234 bytes** (about 1.2 MB), below the 2 MB budget. Full-window screenshots are 1,261 × 952 at the capture's native width. The configuration form is cropped to the sheet and scaled to its earlier 1,040 width, and the guest desktop is scaled from 1,344 × 788 to 1,260 wide. The build and import sheets are unchanged. Metadata is removed.

[`manifest.json`](manifest.json) records dimensions, hashes, exact byte counts and privacy crops. The original JPEG captures stay in the ignored `.build/user-doc-captures-2026-11-14/` folder. The SSH image is cropped before the personal public-key fingerprint row; that section is omitted, not redrawn. The configuration image keeps its access section closed, so the generated guest hostname never appears. In the New VM access image, the selected public key's fingerprint sits below the visible area. The Needs you image shows the default account name `omarchy` in sudo's password prompt and nothing typed. The guest desktop's terminal prompts show no username or hostname. Small areas of desktop show at the rounded window corners. Passwords, personal contact details, public-key fingerprints and private keys are absent from the shipped media. Other processing consists of cropping, resizing and compression.

## Update the media

Use the `refresh-screenshots` project skill (`.claude/skills/refresh-screenshots/`) with the Dev app running. It finds every image the guides use, captures each screen through Computer Use, crops out personal rows by inspecting the content, converts the result to WebP in place and updates this README, the manifest and `docs/Validation.md`.

Whether done by the skill or by hand, the rules are the same. Use unsaved examples instead of showing personal defaults or keys, cancel open forms and preserve each existing guest's original lifecycle state. Launch only the dedicated Example VM, and only with explicit approval for that run. Keep each file's name and aspect ratio, strip metadata, review every image before replacing the old one and keep the combined screenshot size below 2 MB.
