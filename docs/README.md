# Omarchy VM Manager user guide

Create independent Omarchy guests, configure their resources, and connect from your Mac over SSH. This guide describes the current private macOS build, **0.5.1 (8)**.

![The manager library with four stopped guests, one running guest and the New VM button in the toolbar](media/library.webp)

## Start here

- [Getting started](getting-started.md): open the app, set up reusable defaults, create a guest and launch it.
- [Manage your guests](managing-guests.md): change resources, use SSH, assign a Space, shut down and delete guests.
- [Use the CLI](cli-quickstart.md): create, wait for SSH, inspect, stop and reconfigure from a terminal.
- [Troubleshooting](troubleshooting.md): Super shortcuts, clipboard, startup and SSH readiness.

## A quick look

[Watch or download the 44-second MP4 tour](media/quick-tour.mp4) · approximately **663 KB**.

The silent tour is assembled from real screenshots of the running manager. It shows stopped-guest settings and the manager controls for an already-running guest; it is not a continuous recording of installation or guest startup. The eleven screenshots and video together are approximately **1.2 MB**. [Captions and a text transcript](media/README.md) are included.

Screenshots were captured on 31 October 2026. Guest names and the illustrated SSH port belong to this installation; yours will differ. The New VM example was cancelled. No guest was launched, changed, shut down or deleted for these captures. The separately added Dev Omarchy guest was already running and was left running.

## Current capabilities

| Task | Current behavior |
| --- | --- |
| Create guests | Independent disks; optional saved owner setup; SSH on by default |
| Configure | Name, CPU, memory, grow-only disk capacity, clipboard and immersive mode while stopped |
| Connect | NAT networking and a separate localhost SSH port for each enabled guest |
| Organize windows | Native Dock assignment to Mission Control Spaces |
| Remove a guest | Move its stopped guest folder to macOS Trash |
| Reuse downloads | Shared verified factory-image cache in Downloads |

Shared folders, USB, camera, authentication bridges, general port-forward editing, snapshots and importing existing VMs are unavailable in this build. The library's retained POC entries are protected from editing and deletion.

## Further reference

[CLI reference](CLI.md) · [Factory image cache](FactoryCache.md) · [Guest Defaults details](UnattendedDefaults.md) · [Managed SSH](ManagedSSH.md) · [Validation record](Validation.md)

This is a project of [reactive.org enterprises](https://www.reactive.org/). Omarchy is a pending trademark of the [Omacom Foundation](https://omarchy.org/foundation/).

[Pause and resume](PauseResume.md) explains manual execution control, host sleep/wake and shutdown.

[Suspend-to-disk investigation](Suspend.md) records the clarified RAM-release requirement, pinned graphics blocker and proposed disposable hibernation POC.
