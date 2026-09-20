# Game Focus

An Omarchy plugin that hands the keyboard and mouse back to fullscreen games,
then gives them straight back to the desktop when you're done.

## Why

Hyprland claims keys and mouse buttons before the focused window ever sees them.
Several Omarchy defaults are actively hostile to games:

| Binding | Does | Mid-game effect |
|---|---|---|
| `SUPER` + right-click | `resizewindow` | Floats the window — **you lose fullscreen** |
| `SUPER` + left-click | `movewindow` | Same, with the other button |
| `SUPER` + scroll | workspace `e±1` | Super + weapon wheel throws you to another workspace |
| `SUPER + W` | `closewindow` | Closes the game |
| `ALT + TAB` | `cyclenext` | Never reaches the game |
| `SUPER + C/V/X` | universal clipboard | Injects *synthetic keystrokes* into the focused window |

It's made worse by `binds:drag_threshold` defaulting to `0`, which makes a click
with no mouse movement count as a drag.

## What it does

Entering a Hyprland **submap** replaces the whole active bind set, so anything
not re-declared inside it falls through to the game. Nothing is permanently
unbound — leaving the submap restores every binding untouched.

**Kept alive while armed:** media/volume/brightness keys, `PRINT` and
`ALT + PRINT` for capture, `SUPER + 1…9` and `SUPER + TAB` for workspaces, and
`SUPER + CTRL + ALT + W` to close a hung game without leaving the mode.
Everything else goes to the game, `ALT + TAB` included.

**Also while armed:** animations, blur, shadows, rounding, inactive-dimming and
cursor zoom are switched off and the bar is hidden. Each is snapshotted at arm
time and restored exactly on exit, so your own `looknfeel.lua` values are
honoured. If the bar was already hidden, it stays hidden.

**Always on while installed:**

- `binds:drag_threshold = 12` — a stationary `SUPER` + click no longer moves or
  resizes anything, desktop-wide.
- Game windows render fully opaque, without blur/shadow/rounding, and with
  `idle_inhibit = "fullscreen"`. Omarchy sets idle-inhibit for the Steam
  *client*, RetroArch and Moonlight, but not for `steam_app_*` — i.e. not for
  actual games, which is why the screen blanks in controller-only sessions.

## Using it

| | |
|---|---|
| `SUPER + F12` | Arm / disarm |
| `SUPER + SHIFT + F12` | Disarm (second exit, bound inside the submap) |
| automatic | Arms when a game goes fullscreen, disarms when you leave |

Auto-detection fires on a window whose class matches `GAME_CLASSES` **or** that
reports `content_type = "game"` (SDL3 and Proton titles do). A mode you armed by
hand is never auto-disarmed.

## Install

```bash
omarchy plugin add https://github.com/USER/omarchy-game-focus.git
~/.config/omarchy/plugins/pashadev.game-focus/install.sh
```

Or from a clone:

```bash
git clone https://github.com/USER/omarchy-game-focus.git
cd omarchy-game-focus && ./install.sh
```

`install.sh` copies the plugin into place, adds a guarded loader line to
`~/.config/hypr/hyprland.lua`, splices a **Toggle → Game Focus** row into the
Omarchy menu, links the CLI onto your `PATH`, and enables the plugin. It backs
up every file it edits and is safe to re-run.

Remove it with `./uninstall.sh`.

## Turning it on and off

It registers with the Omarchy shell as `pashadev.game-focus`, so these are all
the same switch:

```bash
omarchy plugin disable pashadev.game-focus
omarchy-game-focus disable
# or SUPER + CTRL + O → Game Focus
```

```bash
omarchy-game-focus status          # enabled / loaded / armed
omarchy-game-focus on|off|toggle   # arm now, without unloading anything
```

Disabled means `hypr.lua` returns on its first lines: no submap, no bindings, no
window rules, no event handlers, and no drag-threshold change.

## Configuring

Everything tunable is at the top of `hypr.lua`: `TOGGLE_KEY`, `AUTO_DETECT`,
`GAME_CLASSES`, `GAME_CONFIG` (what gets switched off while armed),
`AUTO_DISARM_DELAY` and `REGISTRY_POLL`.

To teach it a game it doesn't recognise, run `hyprctl clients -j` while the game
is running, copy its `class`, and add it to `GAME_CLASSES`. Those are **Hyprland
regexes**, and they are matched in exactly one place — the window rules, which
tag matching windows `game`. The Lua never matches classes itself; it reads that
tag. One list, one matcher, one syntax.

## If it ever gets stuck

1. `SUPER + F12`
2. `SUPER + SHIFT + F12`
3. `omarchy-game-focus off`, or `hyprctl dispatch submap reset`
4. `omarchy-game-focus disable` — unpicks the state by hand if the module is wedged
5. `CTRL + ALT + F2` for a TTY — logind handles that, never Hyprland

## How the two halves fit together

The behaviour has to live in Hyprland: it needs the compositor's event hooks and
a keybind submap. But `omarchy plugin list` is the *shell's* component registry,
so a Hyprland module can't appear there on its own. `Service.qml` is a
`service`-kind shell plugin that exists to be that registry entry, and the
registry is the single source of truth — a third-party plugin is enabled iff its
id is in `shell.json`, which is what `omarchy plugin enable|disable` writes.

Keeping the halves in step is asymmetric, because `omarchy plugin disable` fires
no hooks:

| Direction | How it propagates |
|---|---|
| enabled | The shell starts the service, which runs `omarchy-game-focus ensure-loaded` and reloads Hyprland |
| disabled | The service is already gone, so `hypr.lua` polls the registry every 10 s and unloads itself |

`ensure-loaded` doesn't re-read the registry to decide whether to act — the
service running already means enabled, and the shell writes `shell.json` in the
same instant it starts the component, so a read from there loses the race. It
does wait for that write before reloading, because `hypr.lua` reads the same file.

## Notes for anyone editing this

- Hyprland 0.56 can't use one key to both enter and leave a submap unless the
  bind is `submap_universal` ([Hyprland#14733][1]). `SUPER + F12` uses it;
  `SUPER + SHIFT + F12` is a guaranteed fallback, because a submap-only bind
  can't be verified without physically pressing it.
- `omarchy-toggle-bar` reads backwards: its argument names the state of a flag
  called `bar-off`, so `omarchy-toggle-bar on` **hides** the bar.
- Auto-disarm is debounced by 600 ms. Without it, a notification stealing focus
  for an instant drops the mode mid-game.
- The armed state is mirrored to a flag file so the mode survives
  `hyprctl reload`.
- Quickshell caches compiled QML. After editing `Service.qml`, `rescanPlugins`
  is not enough — clear `~/.cache/quickshell/qmlcache` and
  `omarchy restart shell`, then check `journalctl --user | grep game-focus:`.

## Requirements

Omarchy 4 (tested on 4.0.4) and Hyprland 0.56+, for the Lua config API
(`hl.define_submap`, `submap_universal`, `hl.timer`).

## License

MIT

[1]: https://github.com/hyprwm/Hyprland/discussions/14733
