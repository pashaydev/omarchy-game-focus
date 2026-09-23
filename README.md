# Game Focus

An [Omarchy](https://omarchy.org/) plugin that hands the keyboard and mouse back
to fullscreen games, then returns them to the desktop when you're done.

## Why

Hyprland claims input before the focused window ever sees it, and several
Omarchy defaults are hostile to games:

| Binding | Does | Mid-game effect |
|---|---|---|
| `SUPER` + right-click | `resizewindow` | Floats the window — **you lose fullscreen** |
| `SUPER` + scroll | workspace `e±1` | Super + weapon wheel throws you to another workspace |
| `SUPER + W` | `closewindow` | Closes the game |
| `ALT + TAB` | `cyclenext` | Never reaches the game |
| `SUPER + C/V/X` | universal clipboard | Injects *synthetic keystrokes* into the focused window |

Worse, `binds:drag_threshold` defaults to `0`, so a click with no mouse movement
still counts as a drag.

## What it does

Entering a Hyprland **submap** replaces the whole active bind set, so anything
not re-declared inside it falls through to the game. Nothing is permanently
unbound.

**Kept while armed:** media/volume/brightness keys, `PRINT` and `ALT + PRINT`,
`SUPER + 1…0` and `SUPER + [SHIFT +] TAB`, and `SUPER + CTRL + ALT + W` to close a hung
game. Everything else goes to the game, `ALT + TAB` included.

Animations, blur, shadows, rounding, dimming and cursor zoom are switched off
and the bar is hidden — each snapshotted on arm and restored exactly on disarm,
so your own `looknfeel.lua` values are honoured. A bar you had already hidden
stays hidden.

**Always on while installed:** `binds:drag_threshold = 12`, so a stationary
`SUPER` + click no longer moves or resizes anything, desktop-wide; and game
windows render opaque, without blur/shadow/rounding, with
`idle_inhibit = "fullscreen"` — Omarchy sets idle-inhibit for the Steam *client*
but not for `steam_app_*`, which is why the screen blanks in controller-only
sessions.

| | |
|---|---|
| `SUPER + F12` | Arm / disarm |
| `SUPER + SHIFT + F12` | Disarm (second exit, bound inside the submap) |
| automatic | Arms when a game goes fullscreen, disarms when you leave |

Auto-detection fires on a window matching `GAME_CLASSES` or reporting
`content_type = "game"` (SDL3 and Proton titles do). A mode you armed by hand is
never auto-disarmed, and one you switched off by hand stays off for that game
window until you arm it by hand again.

## Install

```bash
omarchy plugin add https://github.com/pashaydev/omarchy-game-focus.git
~/.config/omarchy/plugins/pashadev.game-focus/install.sh
```

Or from a clone:

```bash
git clone https://github.com/pashaydev/omarchy-game-focus.git
cd omarchy-game-focus && ./install.sh
```

`install.sh` copies the plugin into place, adds a guarded loader line to
`~/.config/hypr/hyprland.lua`, splices a **Toggle → Game Focus** row into the
Omarchy menu, links the CLI onto your `PATH`, and enables the plugin. It backs
up every file it edits and is safe to re-run. `./uninstall.sh` reverses all of it;
`omarchy plugin remove` only deletes the plugin directory.

Requires Omarchy 4 (tested on 4.0.4) and Hyprland 0.56+, for the Lua config API.

## Turning it on and off

It registers with the Omarchy shell as `pashadev.game-focus`, so these are all
one switch:

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
window rules, no event handlers, no drag-threshold change.

## Bar indicator

A small gamepad in the bar, styled like Omarchy's own status indicators: dimmed
while Game Focus is off, lit while it's watching for games. There's no "armed"
look — arming hides the bar, so the bar going away is that signal.

Click turns Game Focus on or off; right-click arms it now. It's a plugin of its
own, `pashadev.game-focus-indicator`, so moving or removing it never touches Game
Focus. `install.sh` asks where it goes the first time; after that:

```bash
./install.sh right                  # or left | center | none
omarchy bar move pashadev.game-focus-indicator --section left
omarchy bar set pashadev.game-focus-indicator icon 󰮂
omarchy bar set pashadev.game-focus-indicator hideWhenOff true --json
```

`icon` takes any Nerd Font glyph; `hideWhenOff` takes it off the bar while Game
Focus is disabled instead of dimming it.

## Configuring

Everything tunable is at the top of `hypr.lua`: `TOGGLE_KEY`, `AUTO_DETECT`,
`GAME_CLASSES`, `GAME_CONFIG`, `AUTO_DISARM_DELAY`, `REGISTRY_POLL`.

To add a game it doesn't recognise, run `hyprctl clients -j` while it's running,
copy its `class`, and add it to `GAME_CLASSES`. Those are **Hyprland regexes**,
matched in exactly one place — the window rules, which tag matching windows
`game`. The Lua never matches classes itself; it reads that tag.

Re-run `./install.sh` after editing: the plugin directory holds a copy, because
`omarchy-plugin-validate` rejects symlinks inside it, and Hyprland doesn't watch
`hypr.lua` — after `omarchy plugin update`, re-run `./install.sh` too.

## If it gets stuck

`SUPER + F12` → `SUPER + SHIFT + F12` → `omarchy-game-focus off` →
`omarchy-game-focus disable` (unpicks the state by hand if the module is wedged)
→ `CTRL + ALT + F2` for a TTY, which logind handles, not Hyprland.

## How the two halves fit

The behaviour must live in Hyprland — it needs the compositor's event hooks and
a submap. But `omarchy plugin list` is the *shell's* registry, so `Service.qml`
is a `service`-kind plugin that exists to be that entry. The registry is the
source of truth: a third-party plugin is enabled iff its id is in `shell.json`.

Because `omarchy plugin disable` fires no hooks, the two directions differ:
enabling starts the service, which reloads Hyprland; disabling can't notify
anything, so `hypr.lua` polls the registry every 10s and unloads itself.

## Notes for anyone editing this

- `omarchy-toggle-bar` reads backwards: its argument names a flag called
  `bar-off`, so `omarchy-toggle-bar on` **hides** the bar.
- Auto-disarm is debounced 600ms; without it a notification stealing focus for
  an instant drops the mode mid-game.
- `hypr.lua` runs on Hyprland's main thread, which is why it reads `shell.json`
  and the flags itself instead of shelling out: even `o.shell_succeeds` freezes
  the screen for as long as the command takes.
- `hyprctl reload` rebuilds the Lua state but keeps the active submap; a crash or
  reboot keeps neither, which is why the flags record the Hyprland instance.
- The service isn't `keepLoaded`, so an edited `Service.qml` applies on the next
  plugin hot-reload; check `journalctl --user | grep game-focus:`.

## License

[MIT](LICENSE)
