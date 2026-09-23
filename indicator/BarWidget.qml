import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar icon for Game Focus, in the look of Omarchy's status indicators: dimmed
// while the plugin is off, lit while it is watching for games. There is no
// "armed" look on purpose -- arming hides the bar, so the bar going away is
// that signal.
BarWidget {
  id: root

  readonly property string cli: Quickshell.env("HOME") + "/.config/omarchy/plugins/pashadev.game-focus/omarchy-game-focus"
  property bool ready: false

  visible: ready || !setting("hideWhenOff", false)
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.setting("icon", "󰊴")
    dimmed: !root.ready
    useActiveColor: false
    fontSize: Style.font.caption
    horizontalMargin: 5
    verticalPadding: 5
    fixedWidth: root.vertical ? -1 : Style.bar.statusSlot
    fixedHeight: root.vertical ? Style.bar.statusSlot : -1
    tooltipText: root.ready
      ? "Game Focus: on, arms when a game goes fullscreen\nClick to turn off · right-click to arm now"
      : "Game Focus: off\nClick to turn on"
    onPressed: function(pressedButton) {
      root.bar.run(root.cli + (pressedButton === Qt.RightButton ? " toggle" : " toggle-enabled"))
    }
  }

  // The same answer as the menu's checkmark, so "enabled" stays defined in one
  // place: the CLI. Asked again whenever the registry (shell.json) changes.
  Process {
    id: probe
    command: [root.cli, "is-enabled"]
    onExited: function(exitCode) { root.ready = exitCode === 0 }
  }

  FileView {
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onFileChanged: {
      reload() // re-arms the watch after the shell's atomic rewrite
      probe.running = true
    }
  }

  Component.onCompleted: probe.running = true
}
