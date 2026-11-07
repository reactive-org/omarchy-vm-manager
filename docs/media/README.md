# Documentation media

[User guide](../README.md) · [MP4 tour](quick-tour.mp4) · [WebVTT captions](quick-tour.vtt)

These are actual window captures of Omarchy VM Manager **0.9.3 (16)** on macOS, captured through Computer Use on **1 November 2026, Australia/Melbourne**. Both existing guests, Omarchy Suspend POC and Dev Code, remained stopped. The New VM form contains an unsaved Development example with saved owner defaults turned off only in that form, which also excludes the inherited personal public key. Creation, configuration and factory import forms were cancelled; no bundle was chosen or imported. Saved defaults and guest settings were preserved.

The silent 48-second video is a captioned still-screen walkthrough assembled from these captures, not a continuous recording. It shows the current resource/factory controls and experimental suspend readiness panel. It does not demonstrate installation, boot, a running guest, suspend/restore, the guest desktop or a completed Spaces assignment. The SSH image shows the stopped state. No permission grants or guest lifecycle actions were taken for the documentation.

## Transcript

| Time | Screen | What to look for |
| --- | --- | --- |
| 00:00 | Library | Two stopped guests, resource summaries, Import Factory and New VM controls |
| 00:04 | New VM | Unsaved name, factory selection, resources, disk capacity, clipboard, manual owner setup and SSH |
| 00:08 | Guest Home | Launch readiness and the experimental suspend panel with capability unverified |
| 00:12 | Virtual Machine | CPU, memory, disk capacity, storage use and recorded factory |
| 00:16 | Configure | Stopped-guest resource, clipboard and immersive-mode fields; form cancelled |
| 00:20 | Network | NAT and the guest-specific localhost SSH forward |
| 00:24 | Startup | Immersive mode and manual guest launch |
| 00:28 | SSH | Stopped-guest endpoint and managed-key explanation; lower personal-key row excluded |
| 00:32 | Spaces | Native guest Dock assignment instructions |
| 00:36 | Import Factory | Prepared-bundle verification instructions; form cancelled |
| 00:40 | Permissions | The manager's own Accessibility setup action |
| 00:44 | Runtime | Host preflight and the known graphics startup issue |

## Size and format

The twelve WebP screenshots total **454,306 bytes**. The MP4 is **747,929 bytes**, bringing the combined media to **1,202,235 bytes** (about 1.2 MB). Screenshots are at most 1,280 pixels wide, with metadata removed. The video is 1,280 × 960, H.264, 5 fps, 48 seconds, no audio, with fast-start metadata for playback before the whole file is downloaded. No GIF or duplicate high-resolution PNGs are shipped.

[`manifest.json`](manifest.json) records dimensions, hashes, exact byte counts and privacy crops. The original captures stay in the ignored `.build/user-doc-captures-2026-11-01/` folder. The configuration image is cropped before the generated guest-hostname row; the SSH image is cropped before the personal public-key fingerprint row. These lower sections are omitted, not redrawn. Passwords, personal contact details, public-key fingerprints and private keys are absent from the shipped media. Other processing consists of resizing, compression and video captions outside the screenshots. The previous running-guest image was removed because no guest was running during this capture.

## Update the media

Use the `refresh-screenshots` project skill (`.claude/skills/refresh-screenshots/`) with the Dev app running. It finds every image the guides use, captures each screen through Computer Use, crops out personal rows by inspecting the content, converts the result to WebP in place and updates this README, the manifest and `docs/Validation.md`.

Whether done by the skill or by hand, the rules are the same. Use unsaved examples instead of showing personal defaults or keys, cancel open forms and preserve each guest's original lifecycle state. Do not launch a guest just to update the media. Keep each file's name and aspect ratio, strip metadata, review every image before replacing the old one and keep the combined screenshot/video size below 2 MB. The tour is rebuilt only when requested. If it is not rebuilt, note here that it shows an earlier version. If captions or screen order change, update the transcript as well.
