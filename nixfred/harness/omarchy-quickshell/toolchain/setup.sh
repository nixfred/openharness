#!/usr/bin/env bash
# Toolchain check for the Omarchy Quickshell harness. Installs nothing by itself; says what is missing.
set -eu

missing=0
need() {
  if command -v "$1" >/dev/null 2>&1; then
    printf '  ok  %-12s %s\n' "$1" "$(command -v "$1")"
  else
    printf '  MISSING %-8s %s\n' "$1" "$2"; missing=1
  fi
}

echo "Omarchy Quickshell harness: toolchain"
need qs         "quickshell (pacman -S quickshell)"
need qmllint    "qt6-declarative (pacman -S qt6-declarative)"
need python3    "python (pacman -S python)"
need test-drive "Test Drive VM lab (~/.local/bin/test-drive)"
need hyprctl    "hyprland"

if [ "$missing" -ne 0 ]; then
  echo "install the missing tools with pacman, then run setup again" >&2
  exit 1
fi
echo "toolchain ready"
