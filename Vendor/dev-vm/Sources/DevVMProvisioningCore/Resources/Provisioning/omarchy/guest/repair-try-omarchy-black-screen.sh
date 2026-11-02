#!/usr/bin/env bash

set -euo pipefail

# Try Omarchy issue #429: Hyprland 0.57 defaults this quirk to true. On
# virtio-gpu/VirGL that leaves Quickshell without an alpha-capable DMA-BUF
# format, so its full-screen layers become opaque and hide application windows.
# Keep the compositor and shell on the GPU by disabling only that quirk.
workaround='hl.config({ quirks = { skip_non_kms_dmabuf_formats = false } })'
state_dir="$HOME/.local/state/dev-workstation/try-omarchy-black-screen"
hypr_dir="$HOME/.config/hypr"

[[ $EUID -ne 0 ]] || {
  printf 'Run this as the Omarchy desktop user, not root.\n' >&2
  exit 1
}
[[ $(uname -m) == aarch64 ]] || {
  printf 'This repair targets the Try Omarchy aarch64 guest.\n' >&2
  exit 1
}
command -v hyprctl >/dev/null || {
  printf 'Hyprland is unavailable; run this from an Omarchy desktop terminal.\n' >&2
  exit 1
}

hyprland_version=$(pacman -Q hyprland 2>/dev/null | awk '{print $2}')
version_core=${hyprland_version%%-*}
if [[ "$version_core" =~ ^0\.([0-9]+)\. ]] && (( BASH_REMATCH[1] < 57 )); then
  printf 'Hyprland %s does not require the Try Omarchy 0.57 repair.\n' \
    "$hyprland_version"
  exit 0
fi
if [[ ! "$version_core" =~ ^(0\.[0-9]+\.|[1-9][0-9]*\.) ]]; then
  printf 'Unable to determine whether Hyprland %s needs the repair.\n' \
    "$hyprland_version" >&2
  exit 1
fi
if grep -Eq 'skip_non_kms_dmabuf_formats[[:space:]]*=[[:space:]]*false' \
  /usr/share/try-omarchy/hyprland.lua 2>/dev/null; then
  printf 'Try Omarchy already supplies the Hyprland/VirGL compatibility setting.\n'
  exit 0
fi

install -d -m 0700 "$state_dir"
changed=0

for name in hyprland.lua looknfeel.lua; do
  config="$hypr_dir/$name"
  [[ -f "$config" ]] || {
    printf 'Expected Hyprland configuration is missing: %s\n' "$config" >&2
    exit 1
  }

  if grep -Fqx "$workaround" "$config"; then
    printf 'Already repaired: %s\n' "$config"
    continue
  fi

  backup="$state_dir/$name.before-repair"
  [[ -f "$backup" ]] || install -m 0600 "$config" "$backup"
  printf '\n-- Try Omarchy issue #429: preserve alpha formats on virtio-gpu.\n%s\n' \
    "$workaround" >> "$config"
  printf 'Repaired: %s\n' "$config"
  changed=1
done

if (( changed )); then
  printf '\nThe GPU-preserving Hyprland workaround is installed.\n'
  printf 'Restart the VM now; a Hyprland reload alone is not sufficient.\n'
else
  printf '\nThe Hyprland/VirGL compatibility setting is already present.\n'
fi
