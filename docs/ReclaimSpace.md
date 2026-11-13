# Reclaim space

[User guide](README.md) · [Manage your guests](managing-guests.md) · [CLI](CLI.md)

A guest's disks are sparse files on the Mac. They grow as the guest writes, but deleting files inside the guest doesn't shrink them by itself. **Reclaim space** asks a running guest to trim its own free space, so blocks it no longer uses are returned to macOS.

## Use it

Select a running guest and choose **Home → space → Reclaim space**. The guest needs authenticated managed SSH; no confirmation is needed because trimming never changes guest files. You can keep using the guest while it runs. When it finishes, the panel shows how much space was returned and what the guest now uses on this Mac.

From the CLI:

```bash
./bin/omarchy-vm reclaim "Guest Name"
```

The reply's `reclaim` object has `beforeBytes`, `afterBytes`, `reclaimedBytes` and the trimmed `filesystems` (`root`, plus `home` for a separate home disk). See [CLI → Reclaim space](CLI.md#reclaim-space).

## What can't be reclaimed

- **Guest snapshots.** Omarchy keeps a read-only factory reset snapshot, and may take others. Space held by a snapshot stays allocated until the snapshot is removed inside the guest.
- **Shared blocks.** A new guest's system disk is an APFS clone of its factory image, and a replacement system can reuse a cloned home disk. Blocks still shared with the original are released from this guest's file but stay in use by the original.
- **Time Machine local snapshots.** macOS can keep freed blocks until its local snapshots expire, so the Mac's free space may rise later than the guest's figure falls.

The first reclaim on a long-lived guest returns the most, because it recovers everything freed while earlier runtimes ignored trims.

## How it works

The runtime attaches the system and home disks with QEMU's `discard=unmap`, so a guest TRIM punches a hole in the disk file (`F_PUNCHHOLE` on APFS). The guest integration package (0.1.0-49) ships one fixed helper, `/usr/bin/try-omarchy-reclaim`, and a sudoers rule that lets the guest owner run exactly that helper with no arguments. The helper trims `/` (the btrfs root, covering every subvolume) and `/home` only when it is the separate home disk. The manager runs it over the guest's pinned managed SSH and measures the guest folder's allocation before and after, using the same clone-aware figure shown as **used**.

The action is offered only when the bundled runtime records this capability (`discardVersion` 1). A guest that hasn't yet installed the 0.1.0-49 package reports `reclaim-unsupported-guest`; restart it so the runtime installs the current package, then try again.

## Errors

| Code | Meaning |
|---|---|
| `reclaim-not-ready` | The guest isn't running with authenticated managed SSH, or another lifecycle change is in progress. |
| `reclaim-busy` | A home backup or another Reclaim space request is already running for this guest. |
| `reclaim-unsupported-runtime` | The bundled runtime doesn't record guest TRIM pass-through. |
| `reclaim-unsupported-guest` | The guest refused the helper or doesn't have it yet. |
| `reclaim-failed` | The trim or its confirmation failed. Only a fixed stage (`prerequisites` or `trim`) is reported. |
| `reclaim-interrupted` | The guest paused, shut down or exited first. Nothing was lost; a trim already under way may still finish inside the guest. |

A failure never stops the guest or releases its resources. A CLI that disconnects doesn't cancel a trim already under way.
