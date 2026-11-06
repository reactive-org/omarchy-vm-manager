#!/usr/bin/env bash

# Omarchy owns installation and rendering; this wrapper avoids replacing a
# locally edited or unrelated theme and repairs incomplete generated settings.
set -euo pipefail
export LC_ALL=C

current_theme="$HOME/.local/state/omarchy/current/theme"

apply_native_theme() {
  if [[ -z ${OMARCHY_PATH:-} || ! -d "$OMARCHY_PATH/default/themed" ]]; then
    printf 'Omarchy theme templates are unavailable; run setup in an Omarchy login shell.\n' >&2
    return 1
  fi
  OMARCHY_THEME_HEADLESS=1 GIT_TERMINAL_PROMPT=0 omarchy theme "$@"
  if [[ ! -s "$current_theme/foot.ini" ]]; then
    printf 'Omarchy did not generate the active Foot theme configuration: %s/foot.ini\n' "$current_theme" >&2
    return 1
  fi
}

repo_url="${1:-}"
if [[ -z "$repo_url" ]]; then
  # Omitting a URL preserves the selection, but an earlier incomplete apply
  # still needs Omarchy to regenerate the active theme's terminal settings.
  [[ ! -s "$current_theme/foot.ini" ]] || exit 0
  theme_name=$(cat "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null || true)
  if [[ ! "$theme_name" =~ ^[a-z0-9_][a-z0-9._+-]*$ ]]; then
    printf 'Unable to identify the current Omarchy theme for repair.\n' >&2
    exit 1
  fi
  printf 'Regenerating missing settings for the current theme: %s\n' "$theme_name"
  apply_native_theme set "$theme_name"
  exit 0
fi

if [[ ! "$repo_url" =~ ^https://github\.com/[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_][A-Za-z0-9._+-]*/?$ ]]; then
  printf 'Theme must be an HTTPS GitHub repository URL.\n' >&2
  exit 1
fi
repo_url="${repo_url%/}"
repo_url="${repo_url%.git}"
repo_name="${repo_url##*/}"
if [[ "$repo_name" == *.git ]]; then
  printf 'Theme URL has an ambiguous repeated .git suffix.\n' >&2
  exit 1
fi
# Match Omarchy's own naming convention, including case-sensitive affix removal.
theme_name=$(printf '%s' "$repo_name" | sed -E 's/^omarchy-//; s/-theme$//' | tr '[:upper:]' '[:lower:]')
if [[ ! "$theme_name" =~ ^[a-z0-9_][a-z0-9._+-]*$ ]]; then
  printf 'The repository does not give a usable Omarchy theme name.\n' >&2
  exit 1
fi
theme_path="$HOME/.config/omarchy/themes/$theme_name"
if [[ -e "$theme_path" || -L "$theme_path" ]]; then
  if [[ -L "$theme_path" || ! -d "$theme_path/.git" ]]; then
    printf 'Refusing to replace an existing local theme: %s\n' "$theme_path" >&2
    exit 1
  fi
  origin=$(git -C "$theme_path" remote get-url origin)
  origin="${origin%/}"
  origin="${origin%.git}"
  if [[ $(printf '%s' "$origin" | tr '[:upper:]' '[:lower:]') != \
        $(printf '%s' "$repo_url" | tr '[:upper:]' '[:lower:]') ]]; then
    printf 'Refusing a theme name collision: %s\n' "$theme_name" >&2
    exit 1
  fi
  if [[ $(cat "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null || true) == "$theme_name" && \
        -s "$current_theme/foot.ini" ]]; then
    printf 'Theme already active: %s\n' "$theme_name"
    exit 0
  fi
  apply_native_theme set "$theme_name"
else
  apply_native_theme install "$repo_url"
fi
printf 'Theme selected: %s (%s)\n' "$theme_name" "$repo_url"
