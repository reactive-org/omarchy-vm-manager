# Guest home backup

On the guest's **Home** page, choose **Back Up Home…**, review the destination and confirm **Back Up Home**. The guest must already be running with authenticated managed SSH and a verified read-write [host folder](SharedFolders.md). If sharing is off, configure it while stopped and launch normally. The backup action never starts a guest, enables a share or mounts a folder.

Each backup creates a new directory, preserving existing archives and unrelated files:

```text
<configured host folder>/home-backup-<random operation UUID>/home.tgz
```

The UI shows the host destination, an activity indicator, **Cancel Backup**, and the compressed size after verified completion. Status is in memory for this manager session; archives remain on the host after quitting.

## Contents and consistency

This is an explicit, unencrypted export of the authenticated owner's home, including dotfiles and credentials the account can read. GNU tar preserves ACLs, extended attributes and sparse files. Symlinks are stored as links, without following the upstream home link into the host share. Other mounted filesystems are excluded. Runtime sockets are skipped by tar. No sudo, password retrieval, privilege grant or package installation occurs; unreadable files fail the operation.

Close applications and stop database writers first. This is a live file backup, not a filesystem/VM snapshot. A nonzero tar exit, including its changed-file status, fails the backup. Files can still change before or after tar reads them without detection; success cannot establish one consistent point in time.

Paths are relative to the home (`.`), without a `/home/<account>` wrapper. This feature does not restore files or migrate accounts. Keep the old VM until you have separately checked restoration of the files you need. Protect the shared folder and move the archive somewhere private when finished; another guest using that share can access it.

## Integrity and interrupted work

The action uses the existing managed SSH key, strict host-key pin and guest-specific loopback endpoint. A fixed Python supervisor rechecks VM/session/owner identity and the exact native `mac` 9p mount at `/mnt/mac`, including read-write access and the supported cache policy, before writing. It obtains the home from the account database. Guest/profile names and host paths do not become shell syntax. Host-folder safety validation is repeated before SSH.

The supervisor exclusively creates a mode-0700 operation directory and mode-0600 `home.tgz.partial`. Archive data goes directly to that file; neither contents nor file names appear in manager diagnostics. A successful tar exit, file flush and complete tar/gzip read precede publication through Linux `renameat2(RENAME_NOREPLACE)`. Linux 9p rejects rename flags with `EINVAL` (confirmed on a Dev guest's native share), so when `renameat2` is missing or refuses its flag (`EINVAL`, `ENOSYS` or `EOPNOTSUPP`), the supervisor instead hard-links `home.tgz` to the partial file and then removes the partial name. Linking never replaces an existing `home.tgz`; it fails with `EEXIST` instead. An interruption between the two steps leaves a doubly linked file that the host check refuses. A host-side check verifies a regular, private, owned, singly linked file with the reported size through the originally opened share directory. No cryptographic host/guest digest comparison is claimed.

Failure/cancellation preserves partial output for manual cleanup. A failure names the supervisor step that stopped (`prerequisites`, `archive`, `verification`, `publish` or `sync`) and, for a system error, its numeric errno. The Home card shows the step, and the status log records both, for example "Home backup did not complete (stage=publish errno=22)". The host accepts only these fixed step names and an errno from 1 to 4095; file names, archive listings and stderr never leave the guest. A lost connection around publication may leave an unconfirmed `home.tgz`; the manager reports failure instead of assuming completion. Operations are never automatically retried. Neither `.partial` nor an unconfirmed final file counts as a verified backup.

SSH stdin stays open as an operation lease. Cancellation, disconnect or manager process exit closes it; the supervisor stops its private tar/compressor process group, including remaining descendants after the group leader exits. Host SSH termination is bounded if unresponsive. SSH keepalives detect lost connections; the operation has a 24-hour limit. Shutdown, force-stop, pause and host sleep cancel/invalidate backup; late results cannot mark it successful. Work remains manager-owned until its worker returns, even after guest `.exited`; restart, deletion and application-idle completion wait for it. Runtime handles, memory and port reservations still follow matching `.exited`, never backup completion or `.error`. Experimental suspension cannot begin during backup.

**PRIVATE COUPLING:** the native mount policy and managed identity executable remain tied to the pinned integration. GNU tar, Python 3, Linux `/proc` and either `renameat2` no-replace rename or `linkat`/`unlinkat` on the share are guest prerequisites. Missing capabilities fail without installing anything.

**TO PROVE:** an end-to-end real Linux/9p publication with the link/unlink fallback (its primitives were probed on the native share, see [#36](https://github.com/reactive-org/omarchy-vm-manager/issues/36)), archive creation, metadata fidelity, sparse-file restoration, free-space exhaustion, live disconnect/process cleanup, UI interaction and restoration into a fresh guest. Portable fixture tests exercise control flow and archive handling, not Linux/9p acceptance.
