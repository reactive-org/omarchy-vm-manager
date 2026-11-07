---
name: refresh-screenshots
description: Refresh the Omarchy VM Manager user-guide screenshots in docs/media from the running Dev app after UI changes — find every image the docs use, recapture it through computer use, check it for privacy and accuracy, replace it in place and fix any doc wording that no longer matches the UI. Use this whenever the user asks to refresh, update, recapture or redo the screenshots, docs images, user-guide pictures or media, says the docs images are out of date, or is preparing a release and the UI has changed since the last capture, even if they don't name this skill.
---

# Refresh the docs screenshots

You do this by hand, with judgement, not by running a pipeline: find the shots, look at the app, capture each screen, decide the crop by looking at what's in it, convert, review, and write it up.

Read `AGENTS.md` and `docs/media/README.md` first. The media README describes how the last refresh was done and what it promised (unsaved examples, cancelled forms, guests left stopped, personal rows cropped out). Keep those promises.

## Ground rules

These exist because the user's real VMs, keys and stable install live on this Mac.

- **Read-only use of the manager.** Never create, launch, stop, restart, reset, suspend or delete a VM, never download or import a factory image, and never press Create, Save, Import or any other committing button. Opening a form to photograph it and then pressing Cancel is fine; that is how the New VM, Configure and Import Factory shots were made. Only act on a specific VM if the user explicitly asks for that VM. The one planned exception is the **New VM flow** below: it creates and launches a dedicated "Example VM", and only after the user agrees to that in the current run.
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

- **The Dev app version.** Run `lsappinfo find bundleid=dev.omarchy.vm-manager.dev` to get its ASN, then `lsappinfo info -only bundlepath '<ASN>'` and read the `bundle path=` line. Keep these as two separate commands: a worktree-isolated session refuses command substitution. Then run `defaults read "<path>/Contents/Info" CFBundleShortVersionString` and `CFBundleVersion`. Don't use `lsappinfo list`: it prints every running app's details, which can include personal account names and email addresses. Format it like `0.9.3 (16)`.
- **Guest states.** List each guest in the Dev library and say whether it is stopped. Several shots say the guests stayed stopped. If a guest is running, that's the user's business: don't stop it, just note it and take the stopped-state shots from a stopped guest.
- **Dev branding.** The Dev app shows "Omarchy VM Manager Dev" in the title bar, a purple DEV badge on the library header and "Omarchy VM Manager Dev <version>" in the sidebar footer, while the guide describes the everyday app. Guest names in the manager carry no Dev prefix, but a guest's own window title does (for example "[Dev] Example VM"). Point this out once, in the step 2 summary, so the user can decide whether Dev branding in published images is acceptable.

## 2. Confirm with the user

Show the shot list as a compact table with these columns: file, current size and aspect ratio, screen, status (current / stale / renamed / gone / new) and the docs that use it (file:line). Below it, list the evidence captures you are leaving alone, any guide wording you already know is wrong, and the Dev branding note.

Then ask, in one message:

1. Is the shot list right? Should any shots be dropped, added or renamed?
2. The MP4 tour (`quick-tour.mp4` and `quick-tour.vtt`) is a captioned slideshow of these same screens. Should it be rebuilt this time, or left as it is and marked as older than the screenshots?
3. The `example-vm-*` shots in Getting started walk through creating and launching a VM. Should this run recapture them? That means creating and launching a new **Example VM**, so ask for the specifics: who approves setup steps, whether to capture its guest desktop, and what to do with it afterwards. Skip this question if the user has already scoped the run to the stopped-guest shots.
4. Which display is the window on? Ask this **only if** you can't tell. Display names come from the note on the first full-screen screenshot. Ask once.
5. Please say **"ready"** once the Dev window is arranged.

Wait for "ready". Don't capture before it.

## 3. Capture

### Keep each shot's shape

Keep every existing file name and aspect ratio, so the guides lay out the same. The full-window shots are 1280 × 891 (aspect ≈ 1.437), which came from a main window of about **1120 × 780 points** captured at 2×. Before capturing, check the main window's `bounds` with `app_list_windows`. If its aspect ratio is noticeably different, tell the user the size you need and let them resize the window; don't resize it yourself. An exact size is hard to set by hand. If the user says to use the current size, do so, and record in the media README and Validation entry that the images' height changed. Sheets (New VM, Configure, Import Factory) have their own sizes; compare each one's aspect ratio with its existing image.

A cropped shot (for example `configure` and `ssh`, which keep only the upper part of the page to leave out personal rows) should keep the same width and roughly the same height as before. If the UI has grown so that the same content no longer fits that shape, tell the user rather than squashing or padding the image.

### Driving versus capturing

- **Drive** with the background `app_*` tools. Use `app_click` for sidebar items, tabs and buttons, `app_scroll` to return to the top of a page, and `app_menu` for menu commands. Take an `app_screenshot` after each step to confirm you're on the right screen.
- **Capture to disk** with `computer_batch`, using `screenshot` or `zoom` with `save_to_disk: true`. `app_screenshot` and `app_zoom` only return images to you; they don't write files. `computer_batch` needs full-screen control, so call `request_full_control` and say why ("to save the Dev window captures to disk"). Call `switch_display` to the target display first, so nothing from another display is captured. Keep each full-control batch short, and call `release_full_control` after each capture or small group, so the user gets their screen back.
- **The two kinds of tool can't hold the app at the same time.** While an `app_*` call holds the Dev window, `computer_batch` is refused, so call `app_release` before each capture batch. `app_release` also forgets the last window capture, so start the next `app_batch` with a `screenshot` action (scale 0.2 is enough) before any `click` by coordinate or `element_index`. A working rhythm for each shot is: `app_batch` [screenshot, click], then `app_release`, then `computer_batch` [zoom].
- Take one full-screen `screenshot` (scaled is fine) to find the Dev window. Then `zoom` exactly to the window's rectangle, or the sheet's, at `scale: 1` with `save_to_disk: true`. Zoom regions use the full-screen screenshot's coordinate frame, not window coordinates. To find the edges precisely, zoom at `scale: 1` into small regions around two opposite corners. The window stays put between shots, so you can reuse the same region for every full-window capture. Re-measure each sheet.
- **What gets saved:** the tool result's `[Image: source: …/tool-results/mcp-computer-use-blob-….jpg]` line is the saved file. It is a JPEG, scaled to about 1.2 megapixels (a full window comes out about 1,260 pixels wide), not a full-resolution PNG. Copy it straight away to `.build/user-doc-captures-<YYYY-MM-DD>/<name>.jpg`, named after the output file (for example `configure.jpg`). `.build/` is ignored by git, so originals stay out of the repo but are available for review.
- After the **first** capture, check its pixel size with `sips`. If it's narrower than the existing image, stop and agree with the user how to proceed: accept the native width, or capture tiles at full resolution and join them. Never upscale.

### Per-shot notes

The New VM and Configure forms use collapsible sections, and only one section is open at a time. Opening a section to photograph it is fine. Prefer an arrangement that shows nothing personal over one that needs a privacy crop.

- **New VM**: covered by the `example-vm-*` walkthrough (see "The New VM flow" below). There is no separate cancelled-form shot any more.
- **Configure** (the **Configure…** button on Home or the Virtual machine tab, for a stopped guest): open **resources** and keep **access** closed. Access shows an "owner defaults" line containing the generated hostname. Capture, then Cancel.
- **SSH**: capture the tab for a stopped guest. The personal key fingerprint ("your key") is the third row, so crop above it (see step 4).
- **Import factory** (the toolbar import button, or the **Factory images** page): capture before any bundle is chosen, then Cancel. Never press Choose bundle….
- **Spaces**, **Permissions**, **Runtime**: capture as shown. Don't click Enable, Grant, Open System Settings or anything similar.

Ask the user instead of working around it when a shot needs any of these:

- a menu, pop-up, context menu or open panel that `app_click` refuses (the background tools won't open these);
- a running guest, a guest in a particular state, or anything that would change a VM;
- a setting changed in a way that would persist.

Mark that shot "skipped — waiting on you" and carry on with the rest.

When you've finished, restore what you changed: the originally selected guest and tab, scroll positions, and any open sheets (Cancel them). Then call `release_full_control` and `app_release`.

### The New VM flow (Example VM)

Getting started walks through creating a VM, with one `example-vm-NN-<step>` image per major step. These are the only shots that change the user's machine: they create and launch a real VM, which downloads and installs software and takes 10–20 minutes. Do them only when the user agrees in this run (step 2), and settle these points first:

- **Name and layout:** name the VM **Example VM** and choose the **Four terminals** layout. Choosing a layout turns on developer setup (customise shows **Developer**, and the main button becomes **Create, launch & set up**).
- **Factory:** use a lean **custom** factory with a generic name, such as **Lean Omarchy**. Setup fails on the official Try Omarchy image, because updating it fails. Avoid factories whose names identify a person or organisation. The factory pop-up can't be opened by background tools, so either start from **Factory images → Use for new VM** on the right factory, or ask the user to select it. Check the factory row before the first capture.
- **Existing Example VM:** if one already exists, the name clashes. Ask the user to delete it, or ask permission to Trash it through the app's confirmed delete. Don't rename or reuse it.
- **Approvals:** setup can stop at **Needs you**, for example Omarchy asking to enable passwordless sudo in the live terminal. Ask the user who answers. By default the user does; capture the prompt first, then wait for them.
- **Guest desktop:** ask whether to capture the guest's own window. Each guest has its own window app, with a bundle id like `dev.tryomarchy.guest.<hash>` and a withheld display name, and Stable guests use the same pattern. Find the right one with `list_apps`, then match its pid to Example VM by start time (`ps -o pid=,lstart= -p <pids>`; Example VM's started minutes ago, around its Restart step). Request access to that bundle id only; the grant's display name should read "[Dev] Example VM". The window is usually hidden behind other apps, so capture it with `app_screenshot` at `scale: 1`. Its saved blob is the window at native size (about 1344 × 788), with nothing overlapping. Omarchy's welcome notifications stay until dismissed, and one of them is "Update System", so never click them; ask the user to dismiss any they don't want shown.
- **Afterwards:** ask whether to shut it down and keep it, shut it down and Trash it, or leave it running. After shutting it down, confirm it shows **Stopped** before releasing control.

Capture the whole manager window at each step, in this order:

1. **01-new-vm:** the form named Example VM, with the custom factory selected and all sections closed.
2. **02-layout:** **layout** open, with **Four terminals** selected.
3. **03-customise:** **customise** open (Bundled configuration, Developer profile).
4. **04-resources:** **resources** open with the defaults.
5. **05-access:** **access** open. Check that the selected public key's fingerprint is below the visible area; crop or skip the shot if it isn't. Then press **Create, launch & set up**.
6. **06-starting:** Home with the **first run** tracker at **Starting**.
7. **07-needs-you:** the live terminal prompt and the **Needs you** badge in the sidebar, before the user answers. Omarchy's sudo prompt arrives a minute or two after Starting, often before your next check. Tell the user up front to wait for your capture before answering it.
8. **08-installing:** **Installing**, with package output in the live terminal.
9. **09-ready:** Home once the tracker reaches **Ready**.
10. **10-desktop:** the guest window showing the four terminals, if agreed. Scale it to 1260 wide. Check the terminal prompts for a username or hostname; with the default Omarchy prompt they show only `~ ❯`.

Afterwards, shut Example VM down from its Home page (if that's what the user chose), wait for **Stopped**, and confirm its guest window process has exited (`ps -p <pid>`). Release both apps. In the docs, record the factory, layout, profile, who answered prompts, any reused capture and the final state in `docs/media/README.md` and the Validation entry. Adding the flow images brings the media close to the 2 MB budget, so report the total.

Waiting is long and uneventful. Run `sleep` in the background (2–4 minutes at a time) between checks rather than repeatedly taking screenshots, and check with a scaled `app_screenshot`. If setup fails, capture nothing more, report what the app shows, and ask the user how to proceed. Don't retry on your own. Builds that include **Run setup again** in Change setup make a fresh plan, but a retry on a real guest is still unproven. Older builds silently re-run the old saved plan. Usually the cleaner route is for the user to delete the failed VM and start the flow again.

## 4. Review, crop and convert each image

Open every raw capture at full size with `Read`, and zoom into anything small. Decide each crop by **looking at the content**, not by reusing old pixel offsets. The goal is to remove anything personal while keeping the shape of the old image.

Check every image for:

- **Privacy.** No credentials, passwords, tokens, clipboard text, key fingerprints, real hostnames, IP addresses other than localhost, usernames, email addresses, home-directory paths containing a real username, or personal machine names. Guest names and `localhost` ports are fine. For Configure and SSH, find the first personal row (generated hostname or key fingerprint) and crop above it with a small margin. Check that nothing personal sits above the crop line. Crop rows out entirely; never blur, redraw or paint over them, because the published images claim to be real pixels.
- **A clean frame.** Only the Dev window should be visible: no other windows, notifications, menus, cursor, tooltips, stray focus rings or Dock overlap.
- **The right screen.** It must match the alt text and prose: the right page and tab, scrolled to the top, the guest in the stated state, and the form unsaved.

Recapture anything that fails. If a shot can't be made clean without breaking the ground rules, skip it and say why.

A little desktop at the rounded window corners, and a sliver of the window behind a sheet, are acceptable. Crop a sheet capture only to remove distracting background (for example a strip of ghosted text above the sheet).

**Shell commands in a worktree.** A worktree-isolated session refuses shell commands it can't verify, such as loops, variables, command substitution or inline heredoc scripts. Write one plain `magick` command per image. For anything longer, such as updating `manifest.json` or applying several doc edits, write a small Python script to the scratchpad and run it with `python3 <script>`. Have doc-edit scripts check that each old string matches exactly once.

Convert each passing capture over the existing file. Keep the name, scale to the old width, and strip metadata. For example:

```bash
magick .build/user-doc-captures-<date>/<name>.jpg [-crop WxH+X+Y +repage] [-resize <old width>x] -colorspace sRGB -strip -quality 90 -define webp:method=6 docs/media/<name>.webp
```

Scale down to the old image's width when the capture is wider; leave it at its native width when it's narrower. Then open the WebP output again with `Read`. Confirm the size and aspect ratio are what you agreed, and that the scaling hasn't made text unreadable.

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
