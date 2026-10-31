# Omarchy VM Manager

Read intent.md before changing architecture or policy. Preserve its VERIFIED, DESIGN DECISION, PRIVATE COUPLING and TO PROVE distinctions.

- Use Swift 6 and macOS 15+, SwiftPM, and `make` for builds and tests.
- Own orchestration, never duplicate the upstream VM implementation.
- Never launch, reset, delete, or modify a personal/default or existing user VM without explicit consent. Tests use manager-owned disposable UUID roots only.
- Do not download a factory image or launch real QEMU guests without explicit approval for the two-VM POC. Phase 0/0A and their tests must start no VM.
- Keep production launch disabled until the POC run is explicitly approved. Profiles may be prepared as in-memory fixtures without creating storage.
- Stop and ask before granting macOS permissions, using signing/notarization credentials or a real signing identity, or taking over the user's UI. Ad-hoc debug signing and opening only the manager window are authorized for Phase 0/0A.
- Keep client handles and resource/port reservations until matching `.exited`; `.error` is diagnostic, not a lifecycle boundary.
- Use explicit manager-owned roots and bridge lists; NAT only. Never pass development environment overrides to the production client.
- Reject unknown, damaged, incompatible or unproven kit provenance. Never infer focus-aware clipboard from protocol 1.
- Deletion must move one verified stopped UUID root to Trash under the runtime-compatible lock. Never recursively erase VM storage.
- Never log clipboard contents, credentials, guest secrets or personal machine identifiers.
- After an authorized real POC, shut down all test guests, confirm `.exited` and no remaining processes, then offer to Trash their roots.
- Record exact checks and limitations. Real two-VM, focus, sleep/wake and crash behaviour remain TO PROVE until observed on a real Mac.
