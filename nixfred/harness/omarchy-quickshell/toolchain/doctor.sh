#!/usr/bin/env bash
# Versions of everything the harness leans on, for the doctor pane.
set -eu
v() { printf '%-12s ' "$1"; shift; "$@" 2>&1 | head -1 || echo "n/a"; }
v quickshell qs --version
v qmllint qmllint --version
v python3 python3 --version
v hyprland hyprctl version
v test-drive test-drive list
[ -f "$HOME/.local/state/omarchy/current/theme/colors.toml" ] && echo "theme        $(readlink -f "$HOME/.local/state/omarchy/current/theme" 2>/dev/null || echo present)"
exit 0
