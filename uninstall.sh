#!/bin/bash

# Remove Game Focus and everything it touched.

set -uo pipefail

PLUGIN_ID="pashadev.game-focus"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
HYPRLAND_LUA="$HOME/.config/hypr/hyprland.lua"
MENU="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
BIN_DIR="$HOME/.local/bin"

echo "==> 1. Disarming and disabling"
# While the module is still loaded it can undo its own changes; force_unpick in
# the CLI covers the case where it cannot.
"$PLUGIN_DIR/omarchy-game-focus" off >/dev/null 2>&1 || true
omarchy plugin disable "$PLUGIN_ID" >/dev/null 2>&1 || true
omarchy-toggle game-focus off 2>/dev/null || true
omarchy-toggle-enabled game-focus-hid-bar && omarchy-toggle-bar off
omarchy-toggle game-focus-hid-bar off 2>/dev/null || true
hyprctl dispatch 'hl.dsp.submap("reset")' >/dev/null 2>&1 || true

echo "==> 2. Removing the loader from $HYPRLAND_LUA"
if grep -q "omarchy-game-focus" "$HYPRLAND_LUA" 2>/dev/null; then
  cp "$HYPRLAND_LUA" "$HYPRLAND_LUA.bak.$(date +%s)"
  python3 - "$HYPRLAND_LUA" <<'PY'
import sys, pathlib, re
p = pathlib.Path(sys.argv[1])
# Drop the comment line, the local, and its guarded dofile.
text = re.sub(r"\n*-- Game Focus \(omarchy-game-focus\)\n"
              r"local game_focus = [^\n]*\n"
              r"if io\.open\(game_focus\) then dofile\(game_focus\) end\n",
              "\n", p.read_text())
p.write_text(text)
PY
  echo "    removed"
fi

echo "==> 3. Removing the menu row from $MENU"
if [[ -f $MENU ]] && grep -q "trigger.toggle.game-focus" "$MENU"; then
  cp "$MENU" "$MENU.bak.$(date +%s)"
  python3 - "$MENU" <<'PY'
import sys, pathlib, re
p = pathlib.Path(sys.argv[1])
text = p.read_text()
text = re.sub(r"\n*// Toggle > Game Focus row[^\n]*\n(?://[^\n]*\n)*", "\n", text)
text = re.sub(r'\n\s*"trigger\.toggle\.game-focus":[^\n]*\n', "\n", text)
p.write_text(text)
PY
  echo "    removed"
fi

echo "==> 4. Removing the CLI symlink and plugin directory"
rm -f "$BIN_DIR/omarchy-game-focus"
rm -rf "$PLUGIN_DIR"

echo "==> 5. Reloading"
rm -rf "$HOME/.cache/quickshell/qmlcache" 2>/dev/null || true
hyprctl reload >/dev/null 2>&1 || true
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
omarchy restart shell >/dev/null 2>&1 || true

echo
echo "Game Focus removed. Backups of edited files are alongside them as *.bak.*"
