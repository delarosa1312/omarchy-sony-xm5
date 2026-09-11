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

  readonly property string eqPreset: state.eq_preset !== undefined ? String(state.eq_preset) : ""
  readonly property var eqBands: state.eq_bands !== undefined ? state.eq_bands : []
  readonly property int eqBandLimit: state.eq_band_limit !== undefined ? Number(state.eq_band_limit) : 10
  readonly property int clearBass: state.eq_clear_bass !== undefined ? Number(state.eq_clear_bass) : 0
  readonly property bool dsee: state.dsee === true
  readonly property string dseeType: state.dsee_type !== undefined ? String(state.dsee_type) : ""
  readonly property string audioPriority: state.audio_priority !== undefined ? String(state.audio_priority) : ""
  readonly property string listening: state.listening !== undefined ? String(state.listening) : ""
  readonly property string roomSize: state.room_size !== undefined ? String(state.room_size) : ""
  readonly property int autoPowerOff: state.auto_power_off !== undefined ? Number(state.auto_power_off) : -1
  readonly property string wearingPower: state.wearing_power !== undefined ? String(state.wearing_power) : ""
  readonly property bool autoPause: state.auto_pause === true
  readonly property string powerOff: state.power_off !== undefined ? String(state.power_off) : ""

  // Only show what this device actually advertises. A control for something it
  // does not support is worse than no control: the write is accepted, committed
  // locally and never sent, so the button looks like it worked.
  readonly property var features: state.features !== undefined ? state.features : ({})
  function has(name) { return features[name] === "available" }

  // Fields we have written but the headphones have not echoed back. They are
  // almost certainly in effect; this API simply does not acknowledge a
  // session's own writes.
  readonly property var unconfirmed: state.unconfirmed !== undefined ? state.unconfirmed : []
  readonly property string unconfirmedText: {
    if (unconfirmed.length === 0) return ""
    var names = { mode: "noise mode", ambient_level: "ambient level",
                  eq_preset: "equaliser", eq_bands: "bands",
                  eq_clear_bass: "clear bass", dsee: "DSEE",
                  audio_priority: "connection", listening: "listening mode",
                  auto_power_off: "auto power off", wearing_power: "pause when removed",
                  auto_pause: "auto pause" }
    var out = []
    for (var i = 0; i < unconfirmed.length; i++)
      out.push(names[unconfirmed[i]] || unconfirmed[i])
    return "Set, but not echoed back yet: " + out.join(", ") + "."
  }

  readonly property var eqPresets: [
    "off", "rock", "pop", "jazz", "dance", "edm", "r&b/hip-hop", "acoustic",
    "bright", "excited", "mellow", "relaxed", "vocal", "treble", "bass",
    "speech", "heavy", "clear", "hard", "soft", "custom",
    "user-1", "user-2", "user-3", "user-4", "user-5"
  ]

  // Wearing detection and the timer are alternatives, not separate settings.
  readonly property var powerOffChoices: [
    "when removed", "never", "5 min", "15 min", "30 min", "60 min", "180 min"
  ]
  function powerOffLabel(value) {
    if (value === "when-removed") return "when removed"
    if (value === "never" || value === "") return "never"
    return value + " min"
  }
  function powerOffValue(label) {
    if (label === "when removed") return "when-removed"
    if (label === "never") return "never"
    return String(parseInt(label))
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color background: bar ? bar.background : Color.background
  // The bar has no accent of its own; the theme's is the one every other
  // panel's controls use.
  readonly property color accent: Color.accent
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

  function open() {
    snapshotTaken = false          // each opening gets its own undo point
    root.controller.show()
    stateFile.reload()
    syncLocal()
  }
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

  // Band frequencies for the five-band layout this family uses.
  readonly property var bandLabels: ["400", "1k", "2.5k", "6.3k", "16k"]

  property bool eqExpanded: false

  // The sliders read this, not the daemon's copy. Binding a slider straight to
  // polled state means that between releasing the knob and the daemon noticing,
  // the old value comes back and throws the knob somewhere else -- which is the
  // "jumps to a random number". So hold what the user chose, and take the
  // device's word again only once nothing is in flight.
  property var localBands: []
  property int localClearBass: 0
  property int inFlight: 0
  property var queued: null

  // What the equaliser looked like when the panel was opened, so a slip can be
  // undone. Captured on open rather than on first edit: by the time you know
  // you want it back, you have already moved something.
  property var snapshotBands: []
  property int snapshotClearBass: 0
  property bool snapshotTaken: false
  readonly property bool eqChanged: {
    if (!snapshotTaken || snapshotBands.length !== localBands.length) return false
    if (snapshotClearBass !== localClearBass) return true
    for (var i = 0; i < localBands.length; i++)
      if (Number(snapshotBands[i]) !== Number(localBands[i])) return true
    return false
  }

  function syncLocal() {
    if (inFlight > 0) return          // our own write is still on its way
    localBands = eqBands.slice()
    localClearBass = clearBass
    if (!snapshotTaken && eqBands.length > 0) {
      snapshotBands = eqBands.slice()
      snapshotClearBass = clearBass
      snapshotTaken = true
    }
  }

  onEqBandsChanged: syncLocal()
  onClearBassChanged: syncLocal()

  function sendEq() {
    if (!session || localBands.length === 0) return
    var args = ["bands", localBands.join(",")]
    if (cmd.running) { queued = args; return }
    inFlight++
    cmd.command = [root.mdrctl].concat(args)
    cmd.running = true
  }

  function sendClearBass(v) {
    if (!session) return
    var args = ["clear-bass", String(Math.round(v))]
    if (cmd.running) { queued = args; return }
    inFlight++
    cmd.command = [root.mdrctl].concat(args)
    cmd.running = true
  }

  function undoEq() {
    if (!snapshotTaken) return
    localBands = snapshotBands.slice()
    localClearBass = snapshotClearBass
    sendEq()
    sendClearBass(snapshotClearBass)
  }

  function setBand(index, value) {
    if (!session || index < 0 || index >= localBands.length) return
    var next = localBands.slice()
    next[index] = Math.round(value)
    localBands = next
    sendEq()
  }
  function setClearBass(v) { localClearBass = Math.round(v); sendClearBass(v) }
  function setDsee(on) { if (session) run(["dsee", on ? "on" : "off"]) }
  function setPriority(p) { if (session && p !== audioPriority) run(["priority", p]) }
  function setPowerOff(label) { if (session) run(["power-off", powerOffValue(label)]) }
  function setAutoPause(on) { if (session) run(["auto-pause", on ? "on" : "off"]) }
  function powerOff() { if (session) run(["shutdown"]) }

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
    onExited: {
      if (root.inFlight > 0) root.inFlight--
      stateFile.reload()
      if (root.queued) {
        var next = root.queued
        root.queued = null
        root.inFlight++
        cmd.command = [root.mdrctl].concat(next)
        cmd.running = true
      }
    }
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
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

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

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: column
        width: flick.width
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
            background: root.background
            accent: root.accent
            fontFamily: root.fontFamily
            options: [
              { value: "cancelling", label: "Cancelling", tooltip: "Block outside sound  (n)" },
              { value: "ambient", label: "Ambient", tooltip: "Let sound through  (a)" },
              { value: "off", label: "Off", tooltip: "Neither  (o)" }
            ]
            value: root.mode
            onChanged: function(v) { root.setMode(v) }
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
            WheelBlocker { anchors.fill: parent; scrollTarget: flick }
          }
        }

        // ---- sound --------------------------------------------------------
        Column {
          id: bandColumn
          width: parent.width
          spacing: Style.space(8)
          visible: root.session && root.eqPreset !== "" && root.has("equalizer")

          PanelSectionHeader {
            text: "SOUND"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          // The equaliser is the only thing here with enough controls to need
          // scrolling, and scrolling past a slider used to move it. Folded away
          // by default, the panel fits and there is nothing to scroll over.
          //
          // Preset is shown, not offered: writing one is accepted, sent, and
          // ignored by this device.
          Item {
            width: parent.width
            implicitHeight: Math.max(eqHeader.implicitHeight, eqValue.implicitHeight)

            Text {
              id: eqHeader
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: (root.eqExpanded ? "\u25be  " : "\u25b8  ") + "Equaliser"
              color: eqMouse.containsMouse ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              id: eqValue
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.eqPreset
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            MouseArea {
              id: eqMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.eqExpanded = !root.eqExpanded
            }
          }

          Column {
            width: parent.width
            visible: root.eqExpanded
            spacing: Style.space(6)

            Repeater {
              model: root.localBands.length

              Item {
                id: bandItem
                required property int index
                width: bandColumn.width
                implicitHeight: bandRow.implicitHeight + bandSlider.implicitHeight + Style.space(2)

                Item {
                  id: bandRow
                  width: parent.width
                  implicitHeight: bandName.implicitHeight

                  Text {
                    id: bandName
                    anchors.left: parent.left
                    text: root.bandLabels[bandItem.index] + " Hz"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Text {
                    anchors.right: parent.right
                    text: {
                      var v = Number(root.localBands[bandItem.index])
                      return (v > 0 ? "+" : "") + v
                    }
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                PanelSlider {
                  id: bandSlider
                  width: parent.width
                  anchors.top: bandRow.bottom
                  bar: root.bar
                  minimum: -root.eqBandLimit
                  maximum: root.eqBandLimit
                  step: 1
                  integer: true
                  value: Number(root.localBands[bandItem.index])
                  onReleased: function(v) { root.setBand(bandItem.index, v) }
                  WheelBlocker { anchors.fill: parent; scrollTarget: flick }
                }
              }
            }

            Item {
              width: parent.width
              implicitHeight: bassLabel.implicitHeight

              Text {
                id: bassLabel
                anchors.left: parent.left
                text: "Clear bass"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                anchors.right: parent.right
                text: (root.localClearBass > 0 ? "+" : "") + root.localClearBass
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            PanelSlider {
              width: parent.width
              bar: root.bar
              minimum: -root.eqBandLimit
              maximum: root.eqBandLimit
              step: 1
              integer: true
              value: root.localClearBass
              onReleased: function(v) { root.setClearBass(v) }
              WheelBlocker { anchors.fill: parent; scrollTarget: flick }
            }

            Button {
              text: "Undo"
              visible: root.eqChanged
              bordered: true
              foreground: root.foreground
              background: root.background
              accent: root.accent
              fontFamily: root.fontFamily
              tooltipText: "Back to the equaliser this panel opened with"
              onClicked: root.undoEq()
            }
          }

          Toggle {
            width: parent.width
            label: "DSEE"
            description: root.dseeType !== "" && root.dsee
              ? "Upscaling compressed audio (" + root.dseeType + ")"
              : "Upscale compressed audio"
            visible: root.has("dsee")
            checked: root.dsee
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.setDsee(!root.dsee)
          }
        }

        // ---- connection ----------------------------------------------------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.session && root.audioPriority !== "" && root.has("connection_mode")

          PanelSectionHeader {
            text: "CONNECTION"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          ButtonGroup {
            width: parent.width
            foreground: root.foreground
            background: root.background
            accent: root.accent
            fontFamily: root.fontFamily
            options: [
              { value: "quality", label: "Quality", tooltip: "Ask for LDAC's higher bitrate" },
              { value: "stability", label: "Stability", tooltip: "Drop the bitrate to keep the link" }
            ]
            value: root.audioPriority
            onChanged: function(v) { root.setPriority(v) }
          }
        }

        // ---- power ----------------------------------------------------------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.session && root.powerOff !== "" && root.has("auto_power_off")

          PanelSectionHeader {
            text: "POWER"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Dropdown {
            width: parent.width
            label: "Switch off"
            options: root.powerOffChoices
            value: root.powerOffLabel(root.powerOff)
            foreground: root.foreground
            fontFamily: root.fontFamily
            onChanged: function(v) { root.setPowerOff(v) }
          }

          Toggle {
            width: parent.width
            label: "Auto pause"
            description: "Follow the player automatically"
            checked: root.autoPause
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.setAutoPause(!root.autoPause)
          }

          Button {
            text: "Switch off"
            bordered: true
            foreground: root.foreground
            background: root.background
            accent: root.accent
            fontFamily: root.fontFamily
            tooltipText: "The link goes with them, so the panel loses its session"
            onClicked: root.powerOff()
          }
        }

        // One line covering every field, because the reason is always the same:
        // the headphones do not acknowledge a session's own writes.
        Text {
          visible: root.unconfirmedText !== ""
          width: parent.width
          text: root.unconfirmedText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
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
            background: root.background
            accent: root.accent
            fontFamily: root.fontFamily
            onClicked: root.startDaemon()
          }
        }
      }
      }
    }
  }

  // Sits over a slider and takes the wheel away from it, scrolling the list
  // instead. Without this, scrolling the panel commits every slider it passes.
  component WheelBlocker: MouseArea {
    // The Flickable to scroll instead, passed in: an inline component resolves
    // ids where it is declared, not where it is used, so it cannot reach one.
    property var scrollTarget: null
    acceptedButtons: Qt.NoButton
    onWheel: function(wheel) {
      wheel.accepted = true
      var f = scrollTarget
      if (!f || !f.interactive) return
      f.contentY = Math.max(0, Math.min(f.contentHeight - f.height,
                                        f.contentY - wheel.angleDelta.y))
    }
  }

  component InfoRow: Item {
    property string label: ""
    property string value: ""
    width: parent ? parent.width : 0
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
