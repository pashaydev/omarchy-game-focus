import QtQuick
import Quickshell.Io

// Registry entry for Game Focus.
//
// The behaviour is Hyprland-side Lua (hypr.lua) because it needs the
// compositor's event hooks and a keybind submap, neither of which the shell can
// provide. This service exists so the feature appears in `omarchy plugin list`
// and can be switched with `omarchy plugin enable|disable pashadev.game-focus`.
//
// Enabling is what this file handles. A third-party plugin is enabled iff its id
// is in shell.json, so this component running at all *means* enabled -- and
// checking would be wrong: the shell instantiates it in the same instant it
// writes shell.json, so a read from here loses the race and sees "disabled"
// every time. ensure-loaded waits for that write, then loads the Hyprland side.
//
// Disabling is handled in hypr.lua instead: `omarchy plugin disable` only
// rewrites shell.json and fires no hooks, and by then this component is gone.
// Component.onDestruction is deliberately not used for it -- that also fires on
// shell shutdown and on `omarchy restart shell`, which would tear down game mode
// on every logout.
Item {
  id: root

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")

  Component.onCompleted: ensureLoaded.running = true

  Process {
    id: ensureLoaded
    running: false
    command: [root.pluginDir + "omarchy-game-focus", "ensure-loaded"]
    stdout: StdioCollector { onStreamFinished: if (text) console.log("game-focus:", text.trim()) }
    stderr: StdioCollector { onStreamFinished: if (text) console.warn("game-focus:", text.trim()) }
  }
}
