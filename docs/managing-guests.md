# Manage your guests

[User guide](README.md) · [Getting started](getting-started.md) · [CLI quick start](cli-quickstart.md)

## A guest's Home page

Select a guest in the sidebar to open its **Home** page. It shows the guest's resources, its developer setup, experimental suspend to disk and its home disk, with **Launch** or **Shut down** at the top. The tabs beside **Home** cover the virtual machine, networking, startup, SSH and Spaces. The suspend panel doesn't establish that a guest can hibernate; see [suspend requirements and limitations](Suspend.md).

![The stopped guest Home page with Launch, resources, setup, experimental suspend to disk and home disk sections](media/guest-home.webp)

## Back up a guest home

Select a running guest and choose **Home → Back up home…**. This requires authenticated managed SSH and a mounted read-write host folder. Close guest apps, review the unencrypted export (including hidden files and credentials), then confirm. A unique backup folder receives `home.tgz`; the app reports completion and its host path after checking the archive. Existing backups are preserved. See [backup contents, cancellation and limitations](HomeBackup.md).

## Change a guest's configuration

New guests can use independent system and home disks, enabled by default. Both capacities appear in Configure. **Replace system…** creates a new VM using a copy of a stopped source's home while preserving the original. See [separate home disks, defaults and CLI](HomeDisks.md).

Shut down the guest and wait for **Stopped**. Select it in the sidebar and open **Virtual machine**. It shows the guest's cores, memory, disks and recorded factory.

![The Virtual machine tab showing cores, memory, system and home disks and the recorded factory](media/resources.webp)

Click **Configure…**. **Rename or configure…** opens the same form.

![The Configure virtual machine form with its resources section open, showing name, factory, memory, cores, system disk, separate home and home disk](media/configure.webp)

Change its name; its memory, cores and grow-only disk capacities under **resources**; or clipboard integration and immersive mode under **access**. Then click **Save changes**. Changes apply the next time you launch it, with its existing disk preserved. Running guests cannot be edited. Entries marked **Retained POC** keep their original configuration and cannot be edited.

SSH enrollment and the owner setup snapshot are fixed at guest creation. Create another guest if you need a different enrollment choice.

## Connect over SSH

Choose the guest's **SSH** tab. A stopped guest shows **Available on next launch**. After launch and account setup, the manager verifies its host key, authenticates, and makes **Copy SSH command** available. Paste that command into a Mac terminal.

![The upper portion of the SSH tab for a stopped guest, showing its localhost endpoint and managed login key](media/ssh.webp)

Every SSH-enabled guest has an independent managed key and a distinct localhost port. The generated command selects the correct key and pinned host identity. An optional personal public key can be chosen when creating the guest; private keys are not imported.

The **Network** tab shows the mapping. In this screenshot, `127.0.0.1:49200` on the Mac forwards to TCP port 22 in this particular guest. Your port may differ.

![The Network tab showing shared NAT, a guest-specific localhost SSH forward and no host folder exposed](media/network.webp)

Use the generated command or localhost endpoint to connect from the Mac. The private guest IP reported by the CLI is informational: two NAT guests can both report `10.0.2.15`. General port-forward editing remains unavailable. Native [host-folder sharing](SharedFolders.md) is opt-in: Configure a stopped guest to share a dedicated host folder (default `~/Shared`) at `/mnt/mac`, with read-write access. The Network page reports the exposed path and mount status. In the screenshot, no host folder is exposed.

## Choose windowed or immersive mode

The **Startup** tab summarizes immersive mode. Click **Configure…** while stopped to change it. Windowed mode is recommended for assigning guests to existing Mission Control desktops.

![The Startup tab, showing immersive mode off and guest launch set to manual](media/startup.webp)

Guests start only when you choose **Launch** or issue a CLI start command. Reopening the manager does not automatically boot them.

## Assign a guest to a Mission Control Space

Each guest has its own Dock identity. Use its Dock icon to make the assignment:

1. Launch the guest in windowed mode.
2. Move its window to your preferred desktop using Mission Control.
3. Control-click the **guest's** Dock icon.
4. Choose **Options → Assign To → This Desktop**.

Choose **Assign To → None** to remove the assignment. The manager's **Spaces** tab keeps these instructions handy.

![The Spaces tab with the native Dock assignment instructions](media/spaces.webp)

macOS manages this assignment. Persistence across guest restarts remains a documented verification item for the current private build.

## Pause and resume a guest

Open the running guest’s ellipsis menu and choose **Pause**. Wait for **Paused**; its main action changes to **Resume**. Pausing freezes guest execution while keeping its memory and resources reserved. It does not save a suspend image or free RAM. SSH and guest applications cannot respond while paused.

A manual pause survives Mac sleep/wake. **Resume** continues that guest; another guest can keep running independently. Use the paused guest’s ellipsis menu → **Shut Down** to resume it only for graceful shutdown. Configuration and deletion require **Stopped**. See [Pause/Resume behavior](PauseResume.md).

## Shut down and remove a guest

Save guest work, click **Shut Down**, and wait for **Stopped**. The ellipsis menu's **Force Stop…** requests immediate power-off and asks for confirmation.

To remove a stopped guest, choose **Delete VM…** at the bottom of its detail page and confirm the reviewed guest. Its entire guest folder moves to macOS Trash, and its library entry is removed. The shared factory-image download remains cached for other guests. A guest that has never initialized storage has only its profile removed.

A running guest or a disk protected by an unresolved saved session cannot be deleted. Stopped retained POC guests use the same confirmed Trash flow as other guests. Trashed files can be recovered through the Mac's normal Trash workflow; automatic restoration into the manager is not implemented.

Quitting the manager with guests running follows its coordinated shutdown flow. Exiting the short-lived CLI leaves guests running under the manager.

## Experimental suspend-to-disk

This workflow is in the Dev build only. Stable shows no **Suspend…** action and doesn't check the guest's hibernation capability, but a guest that already has a saved session still gets its recovery panel and **Restore…**.

In Dev, the guest Home page shows kernel capability and any missing hibernation prerequisites. The official factory kernel lacks hibernation, so **Suspend…** is disabled. A prepared guest can opt into an experimental attempt after confirming the known failure risks. Suspended disks use **Restore / Recover…**, with ordinary launch/configuration/deletion blocked until recovery is verified. A detected cold boot requires a guest administrator to clear any stale resume image before **Accept Cold Boot…**; it is not a successful memory restore. Finish recovery while that guest is running. A stopped unresolved restore needs manual recovery. See [requirements, recovery and current failures](Suspend.md).
