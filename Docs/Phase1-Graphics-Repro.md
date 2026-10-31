# Intermittent guest graphical startup failure

Status: open; observed on 31 October 2026. This is a reduced observation report, not a deterministic reproduction or a proven upstream defect. Do not proceed to manager MVP work on the assumption that restarting the guest or shell fixes launch reliability.

## Smallest observed configuration

- Apple Silicon M5 Max, macOS 27.0.1; one manager-owned guest running alone is sufficient for the observed failure.
- Try Omarchy v1.3.0, upstream commit `13d63df8da2947f833c04025ff5ade187d39ba81`.
- Focus-aware clipboard helper patch `9341b7a35f8d90eb76eae8478c0f641dfe386009`; kit archive SHA-256 `f5e097993ad396b27e34a729cf080e5b364f4d1d9290d3dd1a46f950c01cae24`.
- Official factory image with Omarchy `4.0.0.r7235.g967bbdd-1`, Qt base `6.12.0-3`, Qt declarative `6.12.0-2`, Quickshell `0.3.2.r7.g2b4501a-3`, Hyprland `0.56.2-7`, Mesa `1:26.2.5-1`.
- Retained installed guest, NAT, 4096 MiB, four CPUs, clipboard/battery/timezone bridges. No shared folders, USB, camera or authentication bridge. A temporary loopback SSH diagnostic forward was added only after the failure, and removed afterward.
- Monitor observed inside the affected guest: Virtual-1, 6720×3780 at approximately 120 Hz, scale 2, DPMS on. No resolution/backend change was tested.
- The manager and kit use the supplied QEMU executable. Its executable text matches the locally installed Try Omarchy 1.3 application. No QEMU fork or guest package patch was introduced.

## Observed sequence

1. Start installed guest A alone from its retained disk using one `VMRunClient`. Manager Accessibility trust is effective; QEMU has an enabled keyboard HID event tap.
2. The runtime emits `.ready`, QMP reports running, but the user reports a black/incomplete desktop. A text console is reachable with Control+Option+F2.
3. The user logs in locally. No failed user units are reported. The desktop subsequently looks mostly normal except for missing wallpaper; Command+Space has no visible menu and the welcome notification flickers. The steps that changed a fully black display into the incomplete desktop were not captured precisely.
4. Guest SSH inspection finds one stable Quickshell process, around 1.4 GiB available memory, no matching OOM event, no Hyprland configuration errors, a readable wallpaper file and registered wallpaper/bar/menu layers. This does not establish a healthy rendered scene.
5. A user-approved reduced-size `grim` capture stalls without image data. The session is unlocked and the graphical VT active. The exact stalled capture is stopped.
6. Running the guest's installed `omarchy-restart-shell` once changes the Quickshell PID; IPC responds and the approved capture then completes with a normal wallpaper/bar. The user confirms wallpaper and Command+Space menu work on the Mac. This is a controlled recovery, not a permanent fix.

The kernel journal records virtio GPU response `0x1200` for command `0x106` at boot time 3.75409 seconds, before capture. The installed Linux UAPI header maps these to an unspecified error for `RESOURCE_ATTACH_BACKING`. This is a lead; its causal relation to the visual failure is unproven. Sampled Quickshell logs show no fatal rendering error. A Qt palette-error hypothesis was not reproduced in the installed guest's inspected menu code.

Earlier observations included Foot/pointer-hover corruption with two guests, persisting after the second guest stopped and disappearing after restarting the affected guest. These may be related, but that has not been established. Another black-window report had ambiguous human A/B identification; it should not be used as an unambiguous profile-specific reproduction.

## Evidence and boundaries

Private ignored evidence includes `.build/poc/isolated-A-black*`, `.build/poc/A-event-tap-after-manager-repair.json`, `.build/poc/qemu-executable-text-comparison.json`, and `.build/poc/ssh-A-debug/`. The guest frame and raw private diagnostics are not committed or published. Temporary SSH service shutdown was requested and acknowledged; the loopback listener and disposable client key pair were removed. Final shutdown left no guest/helper process running.

The recovered two-guest comparison passed both desktops/menus, all four focused clipboard paths, background clipboard suppression for each guest, user-initiated sleep/wake and lifecycle cleanup. Those passes do not close this intermittent startup finding. Both stopped disks are retained unless the user chooses Trash. Further investigation should distinguish shell scene initialization from virtio GPU resource allocation using a reviewed, controlled experiment; do not add automatic restart loops or silently change guest packages/rendering settings.
