# Two-VM POC — Phase 1

The guarded launcher is implemented. The user approved downloading the factory image and running both disposable manager-owned VMs on 31 October 2026. They separately approved controlling only those guest windows and using temporary synthetic clipboard contents. The user will initiate whole-Mac sleep/wake when prompted; the agent must not initiate it.

## Approval gate

Obtain explicit approval before enabling the POC launch path, downloading the factory image or opening guest windows. Separately ask before granting macOS permissions, taking over UI, using a signing identity/notarization profile or touching an existing VM. Never use the personal/default Try Omarchy root.

The debug app uses `--poc-approved` to enable the fixed profiles. Admission verifies the compiled provenance lock, full kit file inventory, embedded signature and host preflight before creating a root. Roots use private modes, both ownership markers and seven explicit null inherited settings. Existing changed/unknown settings are refused without writes. The actor enforces aggregate memory/CPU limits and serializes cold starts until `.ready`. Kit storage helpers supply free-space requirements plus a 2 GiB margin. Handles and allocations stay retained until `.exited`. No arbitrary external root or inherited global setting can be selected by this POC path.

Both proposed profiles use 4096 MiB, two CPUs, NAT, no forwards/shared folders/USB, no authentication/camera, and explicit `[clipboard, battery, timezone]`. At least 34,294,967,296 bytes free are required for two new roots plus two 2 GiB margins; recheck immediately before the approved run. The recorded host has sufficient nominal memory/storage, but that is not launch admission.

## Evidence to record

Record model (without serial/UUID), macOS version, physical memory, kit manifest, exact runtime lock, steps, results and bounded stderr with no guest secrets/clipboard payloads.

- A reaches `.ready`, then B reaches `.ready` while A stays usable.
- Distinct disk/settings, Dock/window names, and keyboard focus.
- Host-to-guest and guest-to-host clipboard in each focused guest; no background delivery or background overwrite; focus gain synchronizes once; rapid A/B switching and focus loss during activity.
- Stop A independently; B stays usable. Restart A and confirm its own retained files.
- Same-root refusal, manager duplicate-command refusal and upstream `vm-already-open` lock behaviour.
- Simultaneous audio, load and sleep/wake with both guests usable afterward.
- Normal quit, cancelled quit, and force quit; both helpers begin shutdown and no orphan QEMU remains after the upstream timeout.
- Missing kit, low disk, same-port conflict and external bind races after the relevant policy exists.

Stop feature work and preserve a minimal reproduction if runtime singleton/focus/lifecycle problems appear. Do not hide a failed gate behind retries.

Gracefully shut down both guests. Confirm both `.exited` and no helper/QEMU remains for those roots, then offer to move the disposable roots to Trash. No permanent deletion.
