import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth
import qs.Commons
import qs.Ui

// Sony WH-1000XM5 panel.
//
// Every fact here comes from mdrctld's state file, and every change goes out
// through the mdrctl CLI. The daemon owns the Bluetooth session because the
// device allows exactly one and the handshake costs seconds -- this panel must
// never try to open its own.
Panel {
  id: root
  moduleName: "delarosa.headphones"
  ipcTarget: ""            // the bar widget owns the IPC target
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string home: Quickshell.env("HOME")
  readonly property string mdrctl: home + "/Documents/Projects/Personal/Utils/mdrctl/bin/mdrctl"
  readonly property string statePath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/mdrctl/state.json"

  property var state: ({})
  property real nowSec: 0
  // What we just asked for, held only long enough to cover the round trip to
  // the daemon. The daemon does its own, longer-lived version of this: the
  // headphones do not echo a session's own writes back to it.
  property string pendingMode: ""

  readonly property string mac: setting("mac", "00:00:5E:00:53:01")

  // BlueZ knows whether the headphones are connected and roughly how full they
  // are without any control session, so the widget survives a stopped daemon
  // instead of vanishing with it.
  readonly property var device: {
    var list = Bluetooth.devices ? Bluetooth.devices.values : []
    for (var i = 0; i < list.length; i++)
      if (String(list[i].address).toUpperCase() === root.mac.toUpperCase()) return list[i]
    return null
  }
  readonly property bool linked: device ? device.connected === true : false
  readonly property int bluezBattery: device && device.batteryAvailable ? Math.round(device.battery * 100) : -1

  // The daemon rewrites the state file at least every two seconds, so a file
  // that has stopped moving means the daemon has. Without this a stale file
  // reads exactly like a healthy one and the controls below would sit there
  // offering to do something nobody is listening for.
  readonly property bool fresh: state.updated !== undefined && (nowSec - Number(state.updated)) < 6

  readonly property bool present: linked || (fresh && state.present === true)
  readonly property bool session: fresh && state.session === true
  readonly property string reportedMode: state.mode !== undefined ? String(state.mode) : ""
  readonly property string mode: pendingMode !== "" ? pendingMode : reportedMode
  readonly property bool modeConfirmed: pendingMode === "" && state.mode_confirmed !== false
  // The headset's own figure when we have a session -- it is per-part and
  // finer-grained -- and BlueZ's otherwise.
  readonly property int battery: fresh && state.battery !== undefined && state.battery !== null
    ? Number(state.battery) : bluezBattery
  readonly property bool charging: String(state.charging) === "yes"
  readonly property int ambientLevel: state.ambient_level !== undefined ? Number(state.ambient_level) : 0
  readonly property int ambientMax: state.ambient_level_max !== undefined ? Number(state.ambient_level_max) : 20
  readonly property string buttonMode: state.button_mode !== undefined ? String(state.button_mode) : ""
  readonly property bool adaptive: state.adaptive === true
  readonly property bool focusOnVoice: state.focus_on_voice === true
  readonly property string errorText: state.error && state.error !== "null" ? String(state.error) : ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string glyph: "󰋋"
  readonly property string modeTag: mode === "cancelling" ? "NC"
    : mode === "ambient" ? "AMB"
    : mode === "off" ? "OFF" : ""
  readonly property string modeName: mode === "cancelling" ? "Noise cancelling"
    : mode === "ambient" ? "Ambient sound"
    : mode === "off" ? "Noise control off" : "Unknown"

  readonly property string barLabel: {
    var parts = [glyph]
    if (modeTag !== "") parts.push(modeTag + (modeConfirmed ? "" : "?"))
    if (battery >= 0) parts.push(battery + "%" + (charging ? "+" : ""))
    return parts.join("  ")
  }

  readonly property string barTooltip: {
    if (!present) return ""
    if (!session) return "WH-1000XM5 — battery only, no control session"
    return "WH-1000XM5 — " + modeName + (battery >= 0 ? ", " + battery + "%" : "")
  }

  function open() { root.controller.show(); stateFile.reload() }
  function close() { root.controller.hide() }
  function toggle() { opened ? close() : open() }

  function parseState(text) {
    if (!text || text === "") { root.state = ({}); return }
    try {
      root.state = JSON.parse(text)
    } catch (e) {
      // A half-written file would land here, but the daemon renames into
      // place, so readers only ever see a whole one.
      return
    }
    if (pendingMode !== "" && reportedMode === pendingMode) pendingMode = ""
  }

  function run(args) {
    cmd.command = [root.mdrctl].concat(args)
    cmd.running = true
  }

  function setMode(name) {
    if (!session || name === "" || name === mode) return
    pendingMode = name
    pendingClear.restart()
    run(["mode", name])
  }

  function cycleMode() {
    if (!session) return
    var order = ["cancelling", "ambient", "off"]
    var at = order.indexOf(mode)
    setMode(order[(at < 0 ? -1 : at) + 1 >= order.length ? 0 : (at < 0 ? 0 : at + 1)])
  }

  function setAmbient(level) {
    if (!session) return
    var clamped = Math.max(0, Math.min(ambientMax, Math.round(level)))
    pendingMode = "ambient"
    pendingClear.restart()
    run(["ambient", String(clamped)])
  }

  function nudgeAmbient(step) {
    setAmbient(ambientLevel + step)
  }

  function startDaemon() {
    daemonCmd.command = ["systemctl", "--user", "start", "mdrctld"]
    daemonCmd.running = true
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onLoaded: root.parseState(text())
    onFileChanged: reload()
    onLoadFailed: root.state = ({})
  }

  // The daemon replaces the state file by rename, which a path watcher can
  // lose track of, so the watch is a bonus and this timer is the guarantee.
  // Slow when nobody is looking at it.
  Timer {
    interval: root.opened ? 700 : 3000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      root.nowSec = Date.now() / 1000
      stateFile.reload()
    }
  }

  Timer {
    id: pendingClear
    interval: 4000
    onTriggered: root.pendingMode = ""
  }

  Process {
    id: cmd
    onExited: stateFile.reload()
  }

  Process {
    id: daemonCmd
    onExited: stateFile.reload()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(330))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var k = String(t).toLowerCase()
        if (k === "n") root.setMode("cancelling")
        else if (k === "a") root.setMode("ambient")
        else if (k === "o") root.setMode("off")
        else if (k === "c") root.cycleMode()
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(14)

        PanelHero {
          width: parent.width
          title: "WH-1000XM5"
          meta: {
            if (root.battery < 0) return root.session ? "Connected" : "No control session"
            var t = root.battery + "%"
            if (root.charging) t += "  ·  charging"
            if (!root.session) t += "  ·  battery only"
            return t
          }
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: root.session ? 1.0 : 0.5
          iconComponent: Component {
            Text {
              text: root.glyph
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        // ---- noise mode -------------------------------------------------
        Column {
          width: parent.width
          spacing: Style.space(8)
          opacity: root.session ? 1.0 : 0.4

          PanelSectionHeader {
            text: "NOISE CONTROL"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          ButtonGroup {
            id: modeGroup
            width: parent.width
            enabled: root.session
            foreground: root.foreground
            background: root.bar ? root.bar.background : Color.background
            accent: root.bar ? root.bar.accent : Color.accent
            fontFamily: root.fontFamily
            options: [
              { value: "cancelling", label: "Cancelling", tooltip: "Block outside sound  (n)" },
              { value: "ambient", label: "Ambient", tooltip: "Let sound through  (a)" },
              { value: "off", label: "Off", tooltip: "Neither  (o)" }
            ]
            value: root.mode
            onChanged: function(v) { root.setMode(v) }
          }

          // The device does not tell a session about its own writes, so a mode
          // we set reads back as the old one for a while. Saying so is better
          // than a widget that looks broken.
          Text {
            visible: root.session && !root.modeConfirmed
            width: parent.width
            text: "Set, but not yet echoed back by the headphones."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }
        }

        // ---- ambient level ----------------------------------------------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.session && root.mode === "ambient"

          Item {
            width: parent.width
            implicitHeight: ambientLabel.implicitHeight

            PanelSectionHeader {
              id: ambientLabel
              text: "AMBIENT LEVEL"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: ambientLabel.verticalCenter
              text: root.ambientLevel + " / " + root.ambientMax
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          PanelSlider {
            width: parent.width
            bar: root.bar
            minimum: 0
            maximum: root.ambientMax
            step: 1
            integer: true
            tickCount: root.ambientMax + 1
            value: root.ambientLevel
            onReleased: function(v) { root.setAmbient(v) }
          }
        }

        PanelSeparator { foreground: root.foreground }

        // ---- detail ------------------------------------------------------
        Column {
          width: parent.width
          spacing: Style.spacing.labelGap

          InfoRow {
            visible: root.buttonMode !== ""
            label: "Button"
            value: root.buttonMode
          }
          InfoRow {
            visible: root.adaptive
            label: "Adaptive"
            value: "on"
          }
          InfoRow {
            visible: root.session && root.mode === "ambient"
            label: "Focus on voice"
            value: root.focusOnVoice ? "yes" : "no"
          }
        }

        // ---- no session --------------------------------------------------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: !root.session

          Text {
            width: parent.width
            text: root.errorText !== ""
              ? root.errorText
              : "No control session. BlueZ still reports the battery, but noise control needs mdrctld."
            color: root.errorText !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Button {
            text: "Start mdrctld"
            bordered: true
            foreground: root.foreground
            background: root.bar ? root.bar.background : Color.background
            accent: root.bar ? root.bar.accent : Color.accent
            fontFamily: root.fontFamily
            onClicked: root.startDaemon()
          }
        }
      }
    }
  }

  component InfoRow: Item {
    property string label: ""
    property string value: ""
    width: column.width
    implicitHeight: visible ? Math.max(labelText.implicitHeight, valueText.implicitHeight) : 0

    Text {
      id: labelText
      anchors.left: parent.left
      text: parent.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      id: valueText
      anchors.right: parent.right
      text: parent.value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
  }
}
