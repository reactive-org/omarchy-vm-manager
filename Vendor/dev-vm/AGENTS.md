# Project guidance

This repository builds and customizes Omarchy ARM64 developer workstations managed by Omarchy VM Manager on Apple Silicon. Support the official Try Omarchy factory and the repository's lean factory. Ubuntu and Parallels workflows are out of scope.

- Target the official Omarchy VM Manager Mac app/CLI and its `aarch64` guest; do not silently broaden host, hypervisor, or architecture support.
- Let Omarchy VM Manager own virtualization, factory admission, storage, graphics, display scaling, clipboard, networking, SSH integration, persistence, and Mac app updates. This repository may build opt-in minimal factory artifacts through `make build-omarchy-image`; building must never operate a VM or replace the manager's factory/cache.
- Let Omarchy own Arch, Hyprland, applications, Docker, mise, language runtimes, and guest updates. Apply explicit workstation preferences and independently selected features through Omarchy's native commands and mise; never replace their update paths.
- Minimal-image provisioning compatibility changes must be narrow, source-hash checked, built as versioned guest packages, and recorded in the artifact. Never bypass package dependencies or silently treat an unbooted image as hardware/owner validated.
- Never download, build, or install host software without the user's explicit permission. The normal repository workflow may invoke an existing Omarchy VM Manager CLI build.
- Keep host controllers conservative: show the proposal before changing a VM, refuse to replace existing VMs, checksum downloaded images, and identify the exact guest disk before an unattended wipe.
- Keep guest configuration small, idempotent, and safe to reapply.
- Hardware rendering is required. Do not accept `llvmpipe`, `softpipe`, or forced software rendering.
- Use Omarchy VM Manager's native Retina and dynamic-resolution integration. Do not install repository-owned monitor, port-forwarding, SSH, shared-folder, or host-window controllers.
- Never commit real hostnames, IP addresses, usernames, passwords, tokens, private keys, or generated `cidata` media.
- Run `make test-omarchy` and the relevant shell/Python syntax checks documented in `README.md` after changing an Omarchy workflow.
- Keep features independently taggable, use `ansible.builtin` modules, and run `make syntax-check` after changing YAML. Playbooks use the manager's pinned SSH connection, leave unrelated installed software and configuration intact, and never copy personal credentials into a guest.

