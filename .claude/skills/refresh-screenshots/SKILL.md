---
name: refresh-screenshots
description: Refresh the Omarchy VM Manager user-guide screenshots in docs/media from the running Dev app after UI changes — find every image the docs use, recapture it through computer use, check it for privacy and accuracy, replace it in place and fix any doc wording that no longer matches the UI. Use this whenever the user asks to refresh, update, recapture or redo the screenshots, docs images, user-guide pictures or media, says the docs images are out of date, or is preparing a release and the UI has changed since the last capture, even if they don't name this skill.
---

# Refresh the docs screenshots

You do this by hand, with judgement, not by running a pipeline: find the shots, look at the app, capture each screen, decide the crop by looking at what's in it, convert, review, and write it up.

Read `AGENTS.md` and `docs/media/README.md` first. The media README describes how the last refresh was done and what it promised (unsaved examples, cancelled forms, guests left stopped, personal rows cropped out). Keep those promises.

## Ground rules

These exist because the user's real VMs, keys and stable install live on this Mac.

- **Read-only use of the manager.** Never create, launch, stop, restart, reset, suspend or delete a VM, never download or import a factory image, and never press Create, Save, Import or any other committing button. Opening a form to photograph it and then pressing Cancel is fine; that is how the New VM, Configure and Import Factory shots were made. Only act on a specific VM if the user explicitly asks for that VM.
- **Dev app only.** Target bundle id `dev.omarchy.vm-manager.dev` ("Omarchy VM Manager Dev"). It is also installed in `/Applications`, so identify it by bundle id, never by path or name alone. Never grant, drive or capture the stable app (`dev.omarchy.vm-manager`) or its VMs.
- **No rebuilds while Dev is running.** `make app-dev` (or anything that reassembles the Dev bundle) replaces the app under its running guests. Don't run it, even if the UI looks out of date; report it instead.
- **No macOS permission prompts.** Don't use `screencapture` or anything that needs Screen Recording, Accessibility or similar. Capture only through the computer-use tools. Approving computer-use full-screen control is a Claude approval, not a macOS permission, and is allowed for the capture step.
- **Privacy.** No credentials, saved passwords, clipboard contents, public-key fingerprints, real hostnames, usernames, email addresses or other personal identifiers may appear in a published image. Never read the clipboard.
- Don't commit, push or open a PR unless the user asks.
- Use sentence case and UK/AU spelling (customise, colour, licence as a noun) in anything you write.

## 1. Find the shot list

Work out which images the docs actually use:

- Start with `git status --short docs/`. If there are uncommitted changes in the guides or `docs/media/`, tell the user and don't overwrite them without asking.
- Search `README.md` and `docs/**/*.md` for image embeds (`![alt](path)`, `<img src=…>`) and for links to image files under `docs/media/`. Search only those paths: `.claude/worktrees/` and `.build/` hold copies of the docs that would double-count.
- **User-guide shots** are the ones embedded in the guides (today: twelve `.webp` files used by `docs/README.md`, `getting-started.md`, `managing-guests.md`, `troubleshooting.md` and `preparing-factory-images.md`). These are what you refresh.
- **Evidence captures** are everything else under `docs/media/`: the `setup-*` PNGs and their `report.json`/`evidence.json` files, linked from `DevVMUIAcceptance.md`, `DevVMProvisioningPlan.md`, `docs/README.md` and elsewhere, plus files that appear only as hashes in a folder's `evidence.json`. They record what an acceptance run observed at the time, and their hashes are part of that record. Don't recapture, replace or delete them. List them as "evidence, not refreshed" with a count (linked and hash-only), so the user can see they were considered.
- Also note any media file that no doc links and no `evidence.json` lists, and any doc link to a media file that doesn't exist. Report these; never delete anything.

For each user-guide shot record: path, pixel size (`sips -g pixelWidth -g pixelHeight`), aspect ratio, the docs and line numbers that embed it, its alt text, and the screen it shows. The alt text, the surrounding prose, `docs/media/README.md`'s transcript table and `quick-tour.vtt` all describe what each shot is meant to show. `docs/media/manifest.json` records whether a shot was cropped (`sourceCrop`) and the version it came from.

Then compare against the current UI. Request access to the Dev app only, with `request_access` for `["dev.omarchy.vm-manager.dev"]` (no Finder, no browsers, no clipboard flags). Use `app_list_windows` and `app_screenshot` on the main window, and click through the sidebar and tabs with the background `app_*` tools. This is look-only: open no forms and save nothing to disk; capturing waits until the user says "ready" in step 2. For each shot decide whether it is:

- **current**: the screen exists and looks the same;
- **stale**: the layout, labels or controls have changed;
- **renamed/moved**: the screen exists under another name or in another place;
- **gone**: the screen no longer exists.

Note new screens or tabs the guide doesn't cover, and propose them as additions, but don't add them unless the user agrees. Note doc wording that no longer matches the UI (a renamed button, a removed option); you'll fix that in step 5.

Also gather:

- **The Dev app version.** Get the running Dev bundle's path with `lsappinfo info -only bundlepath "$(lsappinfo find bundleid=dev.omarchy.vm-manager.dev)" | sed -n 's/.*bundle path="\(.*\)"/\1/p'`, then `defaults read "<path>/Contents/Info" CFBundleShortVersionString` and `CFBundleVersion`. Don't use `lsappinfo list`: it prints every running app's details, which can include personal account names and email addresses. Format it like `0.9.3 (16)`.
- **Guest states.** List each guest in the Dev library and say whether it is stopped. Several shots say the guests stayed stopped. If a guest is running, that's the user's business: don't stop it, just note it and take the stopped-state shots from a stopped guest.
- **Dev branding.** The Dev app shows Dev titles, a purple DEV icon and `[Dev]` guest name prefixes, while the guide describes the everyday app. Point this out once, in the step 2 summary, so the user can decide whether Dev branding in published images is acceptable.

## 2. Confirm with the user

Show the shot list as a compact table with these columns: file, current size and aspect ratio, screen, status (current / stale / renamed / gone / new) and the docs that use it (file:line). Below it, list the evidence captures you are leaving alone, any guide wording you already know is wrong, and the Dev branding note.

Then ask, in one message:

1. Is the shot list right? Should any shots be dropped, added or renamed?
2. The MP4 tour (`quick-tour.mp4` and `quick-tour.vtt`) is a captioned slideshow of these same screens. Should it be rebuilt this time, or left as it is and marked as older than the screenshots?
3. Which display is the window on? Ask this **only if** you can't tell. Display names come from the note on the first full-screen screenshot. Ask once.
4. Please say **"ready"** once the Dev window is arranged.

Wait for "ready". Don't capture before it.

## 3. Capture

### Keep each shot's shape

Keep every existing file name and aspect ratio, so the guides lay out the same. The full-window shots are 1280 × 891 (aspect ≈ 1.437), which came from a main window of about **1120 × 780 points** captured at 2×. Before capturing, check the main window's `bounds` with `app_list_windows`. If its aspect ratio is noticeably different, tell the user the size you need and let them resize the window; don't resize it yourself. Sheets (New VM, Configure, Import Factory) have their own sizes; compare each one's aspect ratio with its existing image.

A cropped shot (for example `configure` and `ssh`, which keep only the upper part of the page to leave out personal rows) should keep the same width and roughly the same height as before. If the UI has grown so that the same content no longer fits that shape, tell the user rather than squashing or padding the image.

### Driving versus capturing

- **Drive** with the background `app_*` tools. Use `app_click` for sidebar items, tabs and buttons, `app_scroll` to return to the top of a page, and `app_menu` for menu commands. Take an `app_screenshot` after each step to confirm you're on the right screen.
- **Capture to disk** with `computer_batch`, using `screenshot` or `zoom` with `save_to_disk: true`. `app_screenshot` and `app_zoom` only return images to you; they don't write files. `computer_batch` needs full-screen control, so call `request_full_control` and say why ("to save the Dev window captures to disk"). Call `switch_display` to the target display first, so nothing from another display is captured. Keep each full-control batch short, and call `release_full_control` after each capture or small group, so the user gets their screen back.
- Take one full-screen `screenshot` (scaled is fine) to find the Dev window. Then `zoom` exactly to the window's rectangle, or the sheet's, at `scale: 1` with `save_to_disk: true`. Zoom regions use the full-screen screenshot's coordinate frame, not window coordinates.
- Keep the raw captures in `.build/user-doc-captures-<YYYY-MM-DD>/`, named after the output file (for example `configure.png`). `.build/` is ignored by git, so originals stay out of the repo but are available for review.
- After the **first** capture, check its pixel size. A full-window raw capture should be at least 1280 pixels wide (2240 at 2×). If it's smaller, stop and sort it out with the user before capturing the rest. Never upscale.

### Per-shot notes

- **New VM**: open it and type an unsaved example. The last refresh used a guest named "Development", 4 cores, 4 GiB and SSH on. If the form shows saved owner defaults that carry a personal public key or username, turn them off **in this unsaved form only**. Capture, then Cancel. Never press Create, and never save defaults.
- **Configure**: open it for a stopped guest, capture, then Cancel. Crop above the generated hostname row (see step 4).
- **SSH**: capture the page for a stopped guest. Crop above the personal public-key fingerprint row (see step 4).
- **Import Factory**: open it, capture before any bundle is chosen, then Cancel. Never pick a file in the open panel.
- **Spaces**, **Permissions**, **Runtime**: capture as shown. Don't click Enable, Grant, Open System Settings or anything similar.

Ask the user instead of working around it when a shot needs any of these:

- a menu, pop-up, context menu or open panel that `app_click` refuses (the background tools won't open these);
- a running guest, a guest in a particular state, or anything that would change a VM;
- a setting changed in a way that would persist.

Mark that shot "skipped — waiting on you" and carry on with the rest.

When you've finished, restore what you changed: the originally selected guest and tab, scroll positions, and any open sheets (Cancel them). Then call `release_full_control` and `app_release`.

## 4. Review, crop and convert each image

Open every raw capture at full size with `Read`, and zoom into anything small. Decide each crop by **looking at the content**, not by reusing old pixel offsets. The goal is to remove anything personal while keeping the shape of the old image.

Check every image for:

- **Privacy.** No credentials, passwords, tokens, clipboard text, key fingerprints, real hostnames, IP addresses other than localhost, usernames, email addresses, home-directory paths containing a real username, or personal machine names. Guest names and `localhost` ports are fine. For Configure and SSH, find the first personal row (generated hostname or key fingerprint) and crop above it with a small margin. Check that nothing personal sits above the crop line. Crop rows out entirely; never blur, redraw or paint over them, because the published images claim to be real pixels.
- **A clean frame.** Only the Dev window should be visible: no other windows, notifications, menus, cursor, tooltips, stray focus rings or Dock overlap.
- **The right screen.** It must match the alt text and prose: the right page and tab, scrolled to the top, the guest in the stated state, and the form unsaved.

Recapture anything that fails. If a shot can't be made clean without breaking the ground rules, skip it and say why.

Convert each passing capture over the existing file. Keep the name, scale to the old width, and strip metadata. For example:

```bash
magick <raw>.png [-crop WxH+0+0 +repage] -colorspace sRGB -resize 1280x\> -strip -quality 90 -define webp:method=6 docs/media/<name>.webp
```

Use the old image's width instead of 1280 for the narrower sheet shots. Then open the WebP output again with `Read`, and confirm the size and aspect ratio match the old file and that the scaling hasn't made text unreadable.

If the user asked for the tour to be rebuilt, make it from the new WebPs in the same style as the existing one: 1280 × 960, 4 seconds per screen, a title and caption per screen, silent H.264, matching WebVTT cues. Check a frame from each segment. If they didn't ask, leave both files alone.

Keep the combined size of the screenshots and video under about 2 MB. If it grows a lot, mention it.

## 5. Update the docs

- **Alt text and prose** in the guides, wherever the UI wording changed (button labels, tab names, option names). Match the UI exactly, in sentence case and UK/AU spelling.
- **`docs/media/manifest.json`**: for each replaced file, update `dimensions`, `bytes`, `sha256` (`shasum -a 256`), `sourceSHA256` (of the raw capture), and `sourceCrop` if you cropped. Record `sourceCrop` as `WxH+X+Y` in the raw capture's pixels, before resizing. Older entries mix raw and resized units, so replace them rather than copying their format. Update `appVersion`, `captureDate` (`YYYY-MM-DD`, Australia/Melbourne) and `screenshotsAndVideoBytes`. Update the `video` entry only if you rebuilt the tour.
- **`docs/media/README.md`**: the version, the capture date, the description of the guests and forms, which rows were cropped out and why, the transcript table (if you rebuilt the tour), and the byte totals. If the tour wasn't rebuilt, say it shows the earlier version.
- **`docs/Validation.md`**: add a new dated section, like the earlier "User documentation media refresh" entries. Record what was captured, from which app and version, the guest states before and after, what was cancelled, which crops were applied and why, the checks you ran, and what was not shown (for example no running guest). Keep the VERIFIED / TO PROVE language intact.
- If shots were added, removed or renamed with the user's agreement, update the manifest's `screens` list and the media README transcript to match.

Then check that every media link in the changed docs resolves with exact filename case, and run `git diff --check`.

## 6. Report

End with a short report:

- **Refreshed**: each shot, old → new dimensions, and one line on what changed visibly.
- **Skipped**: each shot and why (needs a running guest, needs a menu the tools can't open, privacy, the user declined).
- **Possibly a UI bug**: anything that looked wrong in the app itself, such as truncated labels, overlapping controls, stale state or misspelt text. Name the screen. Don't fix app code as part of this skill.
- **Docs text changed**: the files, with a few words on each.
- **Left alone**: the evidence captures, the tour (if not rebuilt), and anything else deliberately not touched.
- Confirm that no VM was created, launched, stopped or changed, nothing was committed, and the stable app wasn't touched.

Leave the changes uncommitted unless the user asks.
