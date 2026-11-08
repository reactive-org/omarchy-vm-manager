# Documentation media

[User guide](../README.md) · [Demo video](https://www.reactive.org/omarchy-vm)

The screenshots are actual window captures of the Dev build, Omarchy VM Manager Dev **0.11.3 (187)**, on macOS, captured through Computer Use on **8 November 2026, Australia/Melbourne**. The window title, library header and sidebar footer therefore show Dev branding. All five existing Dev guests (Rails web dev, Ops workspace, Python data science, Go services and Frontend · Next.js) remained stopped and unchanged. The configuration and factory import forms were cancelled; no bundle was chosen or imported. Saved defaults and existing guest settings were preserved.

The ten `example-vm-*` images follow a real guest through the New VM flow for [Getting started](../getting-started.md). With the user's approval, **Example VM** was created with the Lean Omarchy custom factory, the Four terminals layout and the Developer setup profile, using the default resources and access settings. It was then launched through first run to **Ready**. The user answered Omarchy's passwordless sudo prompt. The guest desktop was captured from the guest's own window after the user dismissed two of its four welcome notifications. Example VM was then shut down; its guest process was confirmed exited and the VM was kept. An earlier attempt on the official image failed during setup, because updating Omarchy fails there; the user deleted that VM. Its **Needs you** capture (`example-vm-07-needs-you.webp`) is reused, because that screen shows no factory and is otherwise identical to the second run.

The two Factory images screenshots (`factory-library.webp` and `factory-build.webp`) were added later the same day from the factory-channels branch build, Omarchy VM Manager Dev **0.11.0 (27)**, so its sidebar footer shows that version. The library shows the official card and two lean factories the user built (Stable with Omarchy 4.5.0, used by the guest **stable**, and Edge); all six Dev guests were stopped. The **Build lean factory** sheet was opened with Stable selected, captured after its read-only Docker readiness check, and cancelled; no build started. Its image-name field shows the focus and selection it has when the sheet opens.

The guides link to the [demo video](https://www.reactive.org/omarchy-vm) on reactive.org. The earlier 48-second MP4 slideshow and its WebVTT captions were removed on 8 November 2026.

## Size and format

The 23 WebP screenshots total **1,177,250 bytes** (about 1.2 MB), below the 2 MB budget. Full-window screenshots are 1,260 × 952 at the capture's native width; the configuration and import form screenshots are scaled to their earlier widths, the build sheet is scaled from 1,058 to 900 wide after trimming slivers of the window behind it, and the guest desktop is scaled from 1,344 × 788 to 1,260 wide. Metadata is removed.

[`manifest.json`](manifest.json) records dimensions, hashes, exact byte counts and privacy crops. The original JPEG captures stay in the ignored `.build/user-doc-captures-2026-11-08/` folder. The SSH image is cropped before the personal public-key fingerprint row; that section is omitted, not redrawn. The configuration image keeps its access section closed, so the generated guest hostname never appears. In the New VM access image, the selected public key's fingerprint sits below the visible area. The guest desktop's terminal prompts show no username or hostname. Small areas of desktop show at the rounded window corners. Passwords, personal contact details, public-key fingerprints and private keys are absent from the shipped media. Other processing consists of cropping, resizing and compression.

## Update the media

Use the `refresh-screenshots` project skill (`.claude/skills/refresh-screenshots/`) with the Dev app running. It finds every image the guides use, captures each screen through Computer Use, crops out personal rows by inspecting the content, converts the result to WebP in place and updates this README, the manifest and `docs/Validation.md`.

Whether done by the skill or by hand, the rules are the same. Use unsaved examples instead of showing personal defaults or keys, cancel open forms and preserve each existing guest's original lifecycle state. Launch only the dedicated Example VM, and only with explicit approval for that run. Keep each file's name and aspect ratio, strip metadata, review every image before replacing the old one and keep the combined screenshot size below 2 MB.
