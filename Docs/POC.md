# Two-VM POC — prepared, not run

The current app cannot launch real VMs. No factory image has been downloaded, no VM root has been created, and no QEMU guest has been started by this implementation.

## Approval gate

Obtain explicit approval before enabling the POC launch path, downloading the factory image or opening guest windows. Separately ask before granting macOS permissions, taking over UI, using a signing identity/notarization profile or touching an existing VM. Never use the personal/default Try Omarchy root.

Before launch, implement the guarded POC runner: verify the compiled provenance lock and embedded signatures; create only the two profile UUID roots with private modes and both ownership markers; initialize v1 settings with all inherited keys explicitly null; check aggregate effective memory, CPUs, storage and NAT; retain each client and allocation until `.exited`. The first cold start must reach `.ready` before the second cold start begins. Production `TryOmarchyRuntime.start` is deliberately refused until this admission path is implemented and approved.

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
