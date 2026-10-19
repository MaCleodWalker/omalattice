import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Bar menu for editing the Omalattice settings.
//
// The values come from the layout, which publishes its effective settings and
// defaults to $XDG_RUNTIME_DIR/omalattice-config. Edits are saved as a small
// Lua table in the user's config directory (only the values that differ from
// the defaults) and the layout is then told to reload it, so most settings
// apply immediately.
BarWidget {
  id: root
  moduleName: "io.github.macleodwalker.omalattice"

  property bool popupOpen: false
  property var effective: ({})
  property var defaults: ({})
  property string configPath: ""
  property bool pendingWrite: false
  property bool pendingApply: false

  readonly property bool ready: configPath !== ""
  readonly property bool saving: saveTimer.running || writer.running || applier.running
  readonly property string statusPath: Quickshell.env("XDG_RUNTIME_DIR") + "/omalattice-config"
  readonly property string bootstrapPath: decodeURIComponent(
    Qt.resolvedUrl("integration/plugin.lua").toString().replace(/^file:\/\//, "")
  )
  readonly property int widthStepCount: effective.width_steps ? effective.width_steps.length : 4
  readonly property int heightStepCount: effective.height_steps ? effective.height_steps.length : 4

  function close() { popupOpen = false }

  function luaQuote(value) {
    return "\"" + value
      .replace(/\\/g, "\\\\")
      .replace(/\"/g, "\\\"")
      .replace(/\n/g, "\\n")
      .replace(/\r/g, "\\r") + "\""
  }

  function luaValue(value) {
    if (Array.isArray(value)) return "{ " + value.map(luaValue).join(", ") + " }"
    return String(value)
  }

  function overridesText() {
    var lines = []
    var keys = Object.keys(root.effective).sort()
    for (var index = 0; index < keys.length; index++) {
      var key = keys[index]
      if (JSON.stringify(root.effective[key]) !== JSON.stringify(root.defaults[key])) {
        lines.push("    " + key + " = " + root.luaValue(root.effective[key]) + ",")
      }
    }
    return "-- Written by the Omalattice menu. Only values that differ from the defaults in\n"
      + "-- layout/config.lua are kept here, so it survives plugin updates.\n"
      + "return {\n" + lines.join("\n") + (lines.length ? "\n" : "") + "}\n"
  }

  function parseStatus(text) {
    try {
      var status = JSON.parse(text)
      if (!status || !status.values || !status.defaults) return
      root.effective = status.values
      root.defaults = status.defaults
      root.configPath = status.path || ""
    } catch (error) {
      console.warn("Omalattice: unreadable settings status")
    }
  }

  function setValue(key, value) {
    var next = Object.assign({}, root.effective)
    next[key] = value
    root.effective = next
    saveTimer.restart()
  }

  function resetAll() {
    root.effective = Object.assign({}, root.defaults)
    saveTimer.restart()
  }

  function flush() {
    if (!root.ready) return
    if (writer.running) {
      root.pendingWrite = true
      return
    }
    writer.command = ["sh", "-c", "mkdir -p \"$(dirname \"$1\")\" && printf '%s' \"$2\" > \"$1\"",
      "sh", root.configPath, root.overridesText()]
    writer.running = true
  }

  function applyToLayout() {
    if (applier.running) {
      root.pendingApply = true
      return
    }
    applier.command = ["hyprctl", "eval", "dofile(" + root.luaQuote(root.bootstrapPath) + ")"]
    applier.running = true
  }

  Timer {
    id: saveTimer
    interval: 250
    onTriggered: root.flush()
  }

  Process {
    id: writer
    onRunningChanged: {
      if (running) return
      if (root.pendingWrite) {
        root.pendingWrite = false
        root.flush()
      } else {
        root.applyToLayout()
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim()) console.warn("Omalattice:", text.trim())
    }
  }

  Process {
    id: applier
    onRunningChanged: {
      if (running) return
      if (root.pendingApply) {
        root.pendingApply = false
        root.applyToLayout()
      } else {
        status.reload()
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim()) console.warn("Omalattice:", text.trim())
    }
  }

  FileView {
    id: status
    path: root.statusPath
    watchChanges: true
    onLoaded: if (!root.saving) root.parseStatus(text())
    onFileChanged: reload()
  }

  readonly property var sections: [
    {
      title: "Layout",
      rows: [
        { key: "peek_x", label: "Horizontal peek", to: 200, step: 4, suffix: " px" },
        { key: "peek_y", label: "Vertical peek", to: 200, step: 4, suffix: " px" },
        { key: "gap_x", label: "Horizontal gap", to: 100, step: 2, suffix: " px" },
        { key: "gap_y", label: "Vertical gap", to: 100, step: 2, suffix: " px" },
        { key: "default_width_step", label: "Default width preset", from: 1, toKey: "widthStepCount", step: 1 },
        { key: "default_height_step", label: "Default height preset", from: 1, toKey: "heightStepCount", step: 1 },
        { key: "swipe_distance", label: "Swipe distance", note: "Touchpad travel per window; lower is faster", from: 50, to: 1000, step: 25 }
      ]
    },
    {
      title: "Overview",
      rows: [
        { key: "overview_thumbnails", label: "Live thumbnails", toggle: true },
        { key: "overview_autoscroll_speed", label: "Edge autoscroll speed", note: "0 scrolls only with wheel and keys", to: 3000, step: 100, suffix: " px/s" },
        { key: "overview_min_width", label: "Minimum window width", from: 0.05, to: 0.5, step: 5, scale: 100, suffix: "%" },
        { key: "overview_min_height", label: "Minimum window height", from: 0.05, to: 0.5, step: 5, scale: 100, suffix: "%" }
      ]
    },
    {
      title: "Input (restart Hyprland to apply)",
      rows: [
        { key: "hover_focus_delay", label: "Hover focus delay", note: "0 keeps follow-mouse immediate", to: 1000, step: 25, suffix: " ms" },
        { key: "gesture_fingers", label: "Swipe fingers", from: 3, to: 5, step: 1 },
        { key: "three_finger_pan", label: "Continuous 2D pan", note: "Pan freely; diagonals snap to the nearest window, straight flicks go to the next", toggle: true },
        { key: "overview_gesture_fingers", label: "Overview swipe fingers", note: "Swipe up opens, down closes; 0 is off", from: 0, to: 5, step: 1 },
        { key: "workspace_swipe", label: "Workspace swipe configured", toggle: true }
      ]
    }
  ]

  visible: true
  implicitWidth: glyph.implicitWidth + Style.space(14)
  implicitHeight: barSize

  Text {
    id: glyph
    anchors.centerIn: parent
    text: "󰕰"
    color: root.popupOpen ? root.bar.foreground : root.bar.barForeground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.body
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.popupOpen = !root.popupOpen
    onEntered: if (root.bar) root.bar.showTooltip(root, "Omalattice settings")
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(340))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Flickable {
      anchors.fill: parent
      contentHeight: column.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: column
        width: parent.width
        spacing: Style.space(6)

        Text {
          width: parent.width
          text: "Omalattice"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Text {
          width: parent.width
          visible: !root.ready
          wrapMode: Text.WordWrap
          text: "Waiting for Hyprland to load Omalattice…"
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Repeater {
          model: root.ready ? root.sections : []

          delegate: Column {
            id: section
            required property var modelData
            width: column.width
            spacing: Style.space(4)

            PanelSectionHeader {
              text: section.modelData.title
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Repeater {
              model: section.modelData.rows

              delegate: SettingRow {
                id: row
                required property var modelData
                readonly property var shown: root.effective[modelData.key]

                width: section.width
                label: modelData.label
                note: modelData.note || ""
                isToggle: modelData.toggle === true
                checked: shown === true
                value: typeof shown === "number" ? shown : 0
                from: modelData.from !== undefined ? modelData.from : 0
                to: modelData.toKey ? root[modelData.toKey] : (modelData.to !== undefined ? modelData.to : 100)
                step: modelData.step || 1
                displayScale: modelData.scale || 1
                suffix: modelData.suffix || ""
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                onEdited: newValue => root.setValue(modelData.key, newValue)
              }
            }
          }
        }

        Item {
          width: parent.width
          height: Style.space(32)
          visible: root.ready

          Button {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Reset to defaults"
            fontFamily: root.bar.fontFamily
            onClicked: root.resetAll()
          }
        }
      }
    }
  }
}
