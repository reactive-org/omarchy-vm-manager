# Documentation media

[User guide](../README.md) · [MP4 tour](quick-tour.mp4) · [WebVTT captions](quick-tour.vtt)

These are actual window captures of Omarchy VM Manager **0.5.1 (8)** on macOS, captured through Computer Use on **31 October 2026, Australia/Melbourne**. The four retained guests remained stopped; the later library and running-guest captures show a separately added Dev Omarchy guest already in use. It was left running. The New VM form contains an unsaved example; its optional inherited public key was removed from that unsaved form before capture. Both creation and configuration forms were cancelled. Passwords, personal contact details, public-key fingerprints and private keys are not shown.

The silent 44-second video is a captioned still-screen walkthrough assembled from these captures, not a continuous recording. It does not show installation, guest boot, the guest desktop or a completed Spaces assignment. The SSH capture intentionally shows the current stopped state. No permission grants or guest changes were made for the documentation.

## Transcript

| Time | Screen | What to look for |
| --- | --- | --- |
| 00:00 | Library | Guest names, current states, allocated memory and the toolbar's New VM button |
| 00:04 | New VM | Name, CPU, memory, clipboard, owner defaults and default-on SSH |
| 00:08 | Guest Home | The selected guest's launch controls and Quick Settings |
| 00:12 | Running guest | Current Shut Down controls and configuration disabled while running |
| 00:16 | Configure | Settings editable while stopped; changes apply at next launch |
| 00:20 | Network | NAT and the guest-specific localhost SSH forward |
| 00:24 | Startup | Immersive mode and manual guest launch |
| 00:28 | SSH | A stopped guest's endpoint and managed-key information |
| 00:32 | Spaces | Native guest Dock assignment instructions |
| 00:36 | Permissions | The manager's own Accessibility setup action |
| 00:40 | Runtime | Host preflight and the known graphics startup issue |

## Size and format

The eleven WebP screenshots total **500,322 bytes**. The MP4 is **663,272 bytes**, bringing the combined media to **1,163,594 bytes** (about 1.2 MB). Screenshots are at most 1,280 pixels wide, with metadata removed. The video is 1,280 × 960, H.264, 5 fps, 44 seconds, no audio, with fast-start metadata for playback before the whole file is downloaded. No GIF or duplicate high-resolution PNGs are shipped.

[`manifest.json`](manifest.json) records dimensions, hashes and exact byte counts. The original captures stay in the ignored `.build/user-doc-captures/` folder. UI content was not composited or redrawn; only resizing, compression and video captions outside the screenshots were applied.

## Update the media

Capture the same screens from the current app with Computer Use, preserving the original PNG names expected by the script. Use unsaved examples instead of displaying personal defaults or keys, cancel open forms and preserve each guest's original lifecycle state. Do not launch a guest just to update this tour.

With ImageMagick and FFmpeg available, run from the repository root:

```sh
python3 Scripts/build_doc_media.py .build/user-doc-captures
```

Update the script's capture date and app version when making new captures, then review the optimized images and sample video frames. The script enforces a combined screenshot/video budget below 2 MB. If captions or screen order change, update this transcript as well.
