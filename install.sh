#!/bin/bash

# Install Game Focus.
#
# Usage: ./install.sh [left|center|right|none]   (where the bar indicator goes)
#
# Most of the plugin is just the plugin directory, which `omarchy plugin add`
# already puts in place. This script does the things that live outside it: the
# hyprland.lua loader line, the menu row, a CLI symlink on PATH, and the bar
# indicator, which is a plugin of its own.
#
# Safe to re-run; every step is idempotent.

set -euo pipefail

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID="pashadev.game-focus"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
HYPRLAND_LUA="$HOME/.config/hypr/hyprland.lua"
MENU="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
BIN_DIR="$HOME/.local/bin"
SHELL_JSON="$HOME/.config/omarchy/shell.json"
# Its own plugin, so moving or removing the icon never touches Game Focus.
INDICATOR_ID="pashadev.game-focus-indicator"
INDICATOR_DIR="$HOME/.config/omarchy/plugins/$INDICATOR_ID"

SECTION="${1:-}"
[[ $SECTION =~ ^(left|center|right|none)?$ ]] || {
  echo "Usage: $0 [left|center|right|none]" >&2
  exit 1
}

echo "==> 1. Validating the plugin"
omarchy plugin validate "$SRC"
omarchy plugin validate "$SRC/indicator"

echo "==> 2. Installing to $PLUGIN_DIR"
if [[ $SRC != "$PLUGIN_DIR" ]]; then
  # Copy, never symlink: omarchy-plugin-validate rejects symlinks inside a
  # plugin directory. When `omarchy plugin add` cloned us we are already here,
  # and this is skipped.
  mkdir -p "$PLUGIN_DIR/extensions" "$PLUGIN_DIR/indicator"
  cp -f "$SRC/manifest.json" "$SRC/Service.qml" "$SRC/hypr.lua" \
    "$SRC/omarchy-game-focus" "$SRC/install.sh" "$SRC/uninstall.sh" "$PLUGIN_DIR/"
  cp -f "$SRC/extensions/omarchy-menu.snippet.jsonc" "$PLUGIN_DIR/extensions/"
  cp -f "$SRC/indicator/manifest.json" "$SRC/indicator/BarWidget.qml" "$PLUGIN_DIR/indicator/"
  cp -f "$SRC/README.md" "$SRC/LICENSE" "$PLUGIN_DIR/" 2>/dev/null || true
  chmod +x "$PLUGIN_DIR/omarchy-game-focus" "$PLUGIN_DIR"/*.sh
fi
mkdir -p "$INDICATOR_DIR"
cp -f "$SRC/indicator/manifest.json" "$SRC/indicator/BarWidget.qml" "$INDICATOR_DIR/"

echo "==> 3. Adding the loader to $HYPRLAND_LUA"
if grep -qF "$PLUGIN_ID/hypr.lua" "$HYPRLAND_LUA"; then
  echo "    already present"
else
  cp "$HYPRLAND_LUA" "$HYPRLAND_LUA.bak.$(date +%s)"
  # Guarded on the file existing, so removing the plugin cannot break the
  # Hyprland config -- while a plugin that is present but broken still errors
  # loudly instead of failing silently.
  cat >>"$HYPRLAND_LUA" <<'LUA'

-- Game Focus (omarchy-game-focus)
local game_focus = os.getenv("HOME") .. "/.config/omarchy/plugins/pashadev.game-focus/hypr.lua"
if io.open(game_focus) then dofile(game_focus) end
LUA
  echo "    added"
fi

echo "==> 4. Adding the menu row to $MENU"
if [[ -f $MENU ]] && grep -q "trigger.toggle.game-focus" "$MENU"; then
  echo "    already present"
else
  mkdir -p "$(dirname "$MENU")"
  [[ -f $MENU ]] || printf '{\n}\n' >"$MENU"
  cp "$MENU" "$MENU.bak.$(date +%s)"
  # Splice in right after the opening brace. The row's own trailing comma is
  # fine there -- the menu parser drops trailing commas -- whereas before the
  # closing brace it would follow the user's last row, and a missing comma on
  # that row makes the whole file unparseable, which empties their menu.
  python3 - "$MENU" "$SRC/extensions/omarchy-menu.snippet.jsonc" <<'PY'
import sys, pathlib, re
menu, snippet = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]).read_text()
text = menu.read_text()
idx = re.search(r"^\s*\{", text, re.M).end()
menu.write_text(text[:idx] + "\n" + snippet.rstrip("\n") + text[idx:])
PY
  echo "    added"
fi

echo "==> 5. Linking the CLI into $BIN_DIR"
mkdir -p "$BIN_DIR"
ln -sf "$PLUGIN_DIR/omarchy-game-focus" "$BIN_DIR/omarchy-game-focus"

echo "==> 6. Reloading Hyprland and enabling"
# Hyprland watches its own config files, not hypr.lua, so a re-run only takes
# effect after a reload.
hyprctl reload >/dev/null
# rescanPlugins returns before the scan does, and enabling an id the shell hasn't
# seen yet fails; wait for it the way omarchy-plugin-add does.
omarchy-shell shell rescanPlugins >/dev/null
for _ in $(seq 1 40); do
  omarchy-plugin-list --json |
    jq -e --arg a "$PLUGIN_ID" --arg b "$INDICATOR_ID" '[.[].id] | index($a) and index($b)' >/dev/null && break
  sleep 0.05
done
"$PLUGIN_DIR/omarchy-game-focus" enable

echo "==> 7. Placing the indicator"
on_bar() {
  jq -e --arg id "$INDICATOR_ID" 'any(.bar.layout[]?[]?; .id? == $id)' "$SHELL_JSON" >/dev/null
}
# Asked only the first time; after that an argument moves it.
if [[ -z $SECTION ]] && ! on_bar; then
  SECTION=center
  if [[ -t 0 && -t 1 ]]; then
    SECTION=$(gum choose --header "Where should the Game Focus indicator go?" \
      --selected center left center right none) || SECTION=none
  fi
fi
case $SECTION in
"") echo "    already on the bar; move it with: ./install.sh left|center|right" ;;
none) omarchy plugin disable "$INDICATOR_ID" >/dev/null && echo "    not on the bar" ;;
*)
  if on_bar; then
    omarchy bar move "$INDICATOR_ID" --section "$SECTION" >/dev/null
  else
    omarchy plugin enable "$INDICATOR_ID" --section "$SECTION" >/dev/null
  fi
  echo "    $SECTION"
  ;;
esac

echo
echo "Game Focus installed."
echo "  Toggle the mode : SUPER + F12"
echo "  Turn it off     : omarchy-game-focus disable"
echo "  Check it        : omarchy-game-focus status"
[[ ":$PATH:" == *":$BIN_DIR:"* ]] || echo "  NOTE: $BIN_DIR is not on your PATH"
