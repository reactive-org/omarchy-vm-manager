#!/usr/bin/env bash

set -euo pipefail

foot_font_size="12"
idle_mode="host"
layout_mode="keep"
layout_file=""
theme_url=""

usage() {
  cat <<'EOF'
Usage: apply-workstation.sh [options]

Apply the repository-owned preferences to a managed Omarchy guest.

Options:
  --foot-font-size SIZE  Foot font size (default: 12)
  --idle-mode MODE       host, guest, or keep (default: host)
  --layout-file PATH     Install an optional Hyprland Lua layout
  --remove-layout        Remove the managed optional layout
  --theme-url URL        Install/select an optional HTTPS GitHub theme repository
  -h, --help             Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --foot-font-size)
      foot_font_size="$2"
      shift 2
      ;;
    --idle-mode)
      idle_mode="$2"
      shift 2
      ;;
    --layout-file)
      layout_mode="install"
      layout_file="$2"
      shift 2
      ;;
    --remove-layout)
      layout_mode="remove"
      shift
      ;;
    --theme-url)
      theme_url="${2:?--theme-url requires a repository URL}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ $EUID -ne 0 ]] || {
  printf 'Run this as the Omarchy desktop user, not root.\n' >&2
  exit 1
}
[[ $(uname -m) == aarch64 ]] || {
  printf 'This customization targets the managed Omarchy aarch64 guest.\n' >&2
  exit 1
}
command -v omarchy >/dev/null || {
  printf 'The omarchy command was not found; run this inside managed Omarchy.\n' >&2
  exit 1
}
command -v jq >/dev/null || {
  printf 'The Omarchy-provided jq command is required.\n' >&2
  exit 1
}
[[ "$foot_font_size" =~ ^([6-9]|[12][0-9]|3[0-2])([.][0-9]+)?$ ]] || {
  printf 'Foot font size must be between 6 and 32.\n' >&2
  exit 1
}
[[ "$idle_mode" == host || "$idle_mode" == guest || "$idle_mode" == keep ]] || {
  printf 'Idle mode must be host, guest, or keep.\n' >&2
  exit 1
}
if [[ "$layout_mode" == install && ! -f "$layout_file" ]]; then
  printf 'The requested layout file does not exist: %s\n' "$layout_file" >&2
  exit 1
fi

state_dir="$HOME/.local/state/dev-workstation"
hypr_dir="$HOME/.config/hypr"
hyprland_config="$hypr_dir/hyprland.lua"
managed_layout="$hypr_dir/dev-workstation-layout.lua"
foot_config="$HOME/.config/foot/foot.ini"
shell_config="$HOME/.config/omarchy/shell.json"
shell_default="/usr/share/omarchy/config/omarchy/shell.json"
shell_backup="$state_dir/shell.before-host-idle.json"

install -d -m 0755 "$state_dir" "$hypr_dir" "$(dirname "$foot_config")" \
  "$(dirname "$shell_config")"

bash "$(dirname "${BASH_SOURCE[0]}")/apply-theme.sh" "$theme_url"

if [[ -f "$foot_config" ]]; then
  if grep -Eq '^font=.*:size=[0-9.]+' "$foot_config"; then
    sed -i -E "s/(^font=.*:size=)[0-9.]+/\\1${foot_font_size}/" "$foot_config"
  else
    printf '\nfont=monospace:size=%s\n' "$foot_font_size" >> "$foot_config"
  fi
else
  printf 'font=monospace:size=%s\n' "$foot_font_size" > "$foot_config"
fi

case "$idle_mode" in
  host)
    shell_source="$shell_config"
    [[ -f "$shell_source" ]] || shell_source="$shell_default"
    [[ -f "$shell_source" ]] || {
      printf 'Unable to find the Omarchy shell configuration.\n' >&2
      exit 1
    }
    if [[ ! -f "$shell_backup" ]]; then
      install -m 0600 "$shell_source" "$shell_backup"
    fi
    shell_tmp=$(mktemp "${shell_config}.XXXXXX")
    jq '.idle = (.idle // {}) | .idle.screensaver = 0 | .idle.lock = 0' \
      "$shell_source" > "$shell_tmp"
    chmod 0600 "$shell_tmp"
    mv "$shell_tmp" "$shell_config"
    systemctl --user mask --now omarchy-sleep-lock.service >/dev/null 2>&1 || true
    ;;
  guest)
    if [[ -f "$shell_backup" ]]; then
      install -m 0600 "$shell_backup" "$shell_config"
    else
      shell_source="$shell_config"
      [[ -f "$shell_source" ]] || shell_source="$shell_default"
      [[ -f "$shell_source" ]] || {
        printf 'Unable to find the Omarchy shell configuration.\n' >&2
        exit 1
      }
      shell_tmp=$(mktemp "${shell_config}.XXXXXX")
      jq '.idle = {"screensaver": 150, "lock": 300}' \
        "$shell_source" > "$shell_tmp"
      chmod 0600 "$shell_tmp"
      mv "$shell_tmp" "$shell_config"
    fi
    systemctl --user unmask omarchy-sleep-lock.service >/dev/null 2>&1 || true
    systemctl --user enable --now omarchy-sleep-lock.service >/dev/null 2>&1 || true
    ;;
esac

case "$layout_mode" in
  install)
    install -m 0644 "$layout_file" "$managed_layout"
    if [[ -f "$hyprland_config" ]] && \
      ! grep -Fq 'require("hypr.dev-workstation-layout")' "$hyprland_config"; then
      printf '\n-- Optional workstation-specific app layout.\nrequire("hypr.dev-workstation-layout")\n' \
        >> "$hyprland_config"
    fi
    ;;
  remove)
    rm -f "$managed_layout"
    if [[ -f "$hyprland_config" ]]; then
      sed -i '/require("hypr\.dev-workstation-layout")/d' "$hyprland_config"
    fi
    ;;
esac

printf 'Managed Omarchy workstation preferences applied.\n'
printf 'Foot font size: %s\n' "$foot_font_size"
printf 'Guest idle policy: %s\n' "$idle_mode"
case "$layout_mode" in
  install) printf 'App layout: %s (takes effect at the next Hyprland login)\n' "$layout_file" ;;
  remove) printf 'App layout: native Omarchy (takes effect at the next Hyprland login)\n' ;;
  keep) printf 'App layout: unchanged\n' ;;
esac
