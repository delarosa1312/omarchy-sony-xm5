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
  // What we have asked for but not yet seen confirmed, per field. Every control
  // reads through this, so a click shows its effect at once rather than waiting
  // for the daemon to notice and the panel to hear about it. An entry clears as
  // soon as the device agrees, or after a few seconds if it never does.
  property var pending: ({})

  function eff(field, fallback) {
    if (pending[field] !== undefined) return pending[field]
    var v = state[field]
    return v === undefined || v === null ? fallback : v
  }

  function claimField(field, value) {
    var next = {}
    for (var k in pending) next[k] = pending[k]
    next[field] = value
    pending = next
    pendingSweep.restart()
  }

  function sameValue(a, b) {
    if (Array.isArray(a) && Array.isArray(b)) {
      if (a.length !== b.length) return false
      for (var i = 0; i < a.length; i++) if (Number(a[i]) !== Number(b[i])) return false
      return true
    }
    return a === b
  }

  // Once the device agrees, stop overriding: from then on the panel shows what
  // the headphones actually report, including changes made on the headset.
  function reconcile() {
    var next = {}, changed = false
    for (var k in pending) {
      if (sameValue(pending[k], state[k])) changed = true
      else next[k] = pending[k]
    }
    if (changed) pending = next
  }

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
  readonly property string mode: String(eff("mode", ""))
  readonly property bool modeConfirmed: pending["mode"] === undefined && state.mode_confirmed !== false
  // The headset's own figure when we have a session -- it is per-part and
  // finer-grained -- and BlueZ's otherwise.
  readonly property int battery: fresh && state.battery !== undefined && state.battery !== null
    ? Number(state.battery) : bluezBattery
  readonly property bool charging: String(state.charging) === "yes"
  readonly property int ambientLevel: Number(eff("ambient_level", 0))
  readonly property int ambientMax: state.ambient_level_max !== undefined ? Number(state.ambient_level_max) : 20
  readonly property string buttonMode: state.button_mode !== undefined ? String(state.button_mode) : ""
  readonly property bool adaptive: state.adaptive === true
  readonly property bool focusOnVoice: state.focus_on_voice === true
  readonly property string errorText: state.error && state.error !== "null" ? String(state.error) : ""

  readonly property string eqPreset: state.eq_preset !== undefined ? String(state.eq_preset) : ""
  readonly property var eqBands: eff("eq_bands", [])
  readonly property int eqBandLimit: state.eq_band_limit !== undefined ? Number(state.eq_band_limit) : 10
  readonly property int clearBass: Number(eff("eq_clear_bass", 0))
  readonly property bool dsee: eff("dsee", false) === true
  readonly property string dseeType: state.dsee_type !== undefined ? String(state.dsee_type) : ""
  readonly property string audioPriority: String(eff("audio_priority", ""))
  readonly property string listening: state.listening !== undefined ? String(state.listening) : ""
  readonly property string roomSize: state.room_size !== undefined ? String(state.room_size) : ""
  readonly property int autoPowerOff: state.auto_power_off !== undefined ? Number(state.auto_power_off) : -1
  readonly property string wearingPower: state.wearing_power !== undefined ? String(state.wearing_power) : ""
  readonly property bool autoPause: eff("auto_pause", false) === true
  readonly property string powerOff: String(eff("power_off", ""))
  readonly property bool multipoint: eff("multipoint", false) === true
  readonly property var devices: state.devices !== undefined ? state.devices : []
  readonly property var othersConnected: state.others_connected !== undefined ? state.others_connected : []
  property bool devicesExpanded: false

  // Device actions have no value to claim, so they get their own in-flight
  // map: MAC -> the action we asked for. An entry clears when the headset's
  // own list shows the action happened, which is the only honest signal.
  property var busyDevices: ({})
  property string removeMac: ""
  property string removeName: ""

  function waiting(field) { return pending[field] !== undefined }
  function deviceBusy(mac) { return busyDevices[mac] !== undefined }

  // This machine's own row. Disconnecting or unpairing it would cut the link
  // the panel itself talks over, so those two actions are withheld there.
  // From the daemon, which asks BlueZ. Quickshell's BluetoothAdapter does not
  // carry an address -- only its devices do.
  readonly property string selfMac:
    state.self_mac !== undefined ? String(state.self_mac).toUpperCase() : ""

  function reconcileDevices() {
    var next = {}, changed = false
    for (var mac in busyDevices) {
      var want = busyDevices[mac]
      var found = null
      for (var i = 0; i < devices.length; i++)
        if (devices[i].mac === mac) found = devices[i]
      var done = (want === "disconnect" && found && !found.connected)
              || (want === "unpair" && !found)
      if (done) changed = true
      else next[mac] = want
    }
    if (changed) busyDevices = next
  }

  onDevicesChanged: reconcileDevices()

  // Only show what this device actually advertises. A control for something it
  // does not support is worse than no control: the write is accepted, committed
  // locally and never sent, so the button looks like it worked.
  readonly property var features: state.features !== undefined ? state.features : ({})
  function has(name) { return features[name] === "available" }

  // Fields we have written but the headphones have not echoed back. They are
  // almost certainly in effect; this API simply does not acknowledge a
  // session's own writes.
  readonly property var unconfirmed: state.unconfirmed !== undefined ? state.unconfirmed : []
  // Stronger than "unconfirmed": the device did not even acknowledge the
  // command. The protocol does ACK every command, so silence here is a real
  // failure rather than the usual missing echo.
  readonly property var unacknowledged: state.unacknowledged !== undefined ? state.unacknowledged : []
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

  readonly property string unackedText: {
    if (unacknowledged.length === 0) return ""
    var names = { mode: "noise mode", ambient_level: "ambient level",
                  eq_bands: "bands", eq_clear_bass: "clear bass", dsee: "DSEE",
                  audio_priority: "connection", power_off: "switch off",
                  auto_pause: "auto pause" }
    var out = []
    for (var i = 0; i < unacknowledged.length; i++)
      out.push(names[unacknowledged[i]] || unacknowledged[i])
    return "No answer from the headphones for: " + out.join(", ") + "."
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
    takeSnapshot()
  }

  function close() { root.controller.hide() }
  function toggle() { opened ? close() : open() }

  function applyState(next) {
    state = next
    nowSec = Date.now() / 1000
    reconcile()
    takeSnapshot()
  }

  function parseState(text) {
    if (!text || text === "") { state = ({}); return }
    try {
      applyState(JSON.parse(text))
    } catch (e) {
      // A half-written file would land here, but the daemon renames into
      // place, so readers only ever see a whole one.
      return
    }
  }

  // One connection, held open, carrying commands out and state back. Spawning
  // a process per click cost 22 ms and, worse, gave the daemon no way to tell
  // the panel about a change -- which is why this used to poll a file.
  function send(args, field, value) {
    if (field !== undefined) claimField(field, value)
    if (!link.connected) return false
    link.write(args.join(" ") + "\n")
    link.flush()
    return true
  }

  function setMode(name) {
    if (!session || name === "" || name === mode) return
    send(["mode", name], "mode", name)
  }

  function cycleMode() {
    if (!session) return
    var order = ["cancelling", "ambient", "off"]
    var at = order.indexOf(mode)
    setMode(order[at < 0 ? 0 : (at + 1) % order.length])
  }

  function setAmbient(level) {
    if (!session) return
    var clamped = Math.max(0, Math.min(ambientMax, Math.round(level)))
    claimField("mode", "ambient")
    send(["ambient", String(clamped)], "ambient_level", clamped)
  }

  function nudgeAmbient(step) { setAmbient(ambientLevel + step) }

  property bool eqExpanded: false

  // Band frequencies for the five-band layout this family uses.
  readonly property var bandLabels: ["400", "1k", "2.5k", "6.3k", "16k"]

  // What the equaliser looked like when the panel was opened, so a slip can be
  // undone. Captured on open rather than on first edit: by the time you know
  // you want it back, you have already moved something.
  property var snapshotBands: []
  property int snapshotClearBass: 0
  property bool snapshotTaken: false

  function takeSnapshot() {
    if (snapshotTaken || eqBands.length === 0) return
    snapshotBands = eqBands.slice()
    snapshotClearBass = clearBass
    snapshotTaken = true
  }

  readonly property bool eqChanged: {
    if (!snapshotTaken || snapshotBands.length !== eqBands.length) return false
    if (snapshotClearBass !== clearBass) return true
    for (var i = 0; i < eqBands.length; i++)
      if (Number(snapshotBands[i]) !== Number(eqBands[i])) return true
    return false
  }

  function setBands(values) {
    if (!session || values.length === 0) return
    send(["bands", values.join(",")], "eq_bands", values)
  }

  function setBand(index, value) {
    if (!session || index < 0 || index >= eqBands.length) return
    var next = eqBands.slice()
    next[index] = Math.round(value)
    setBands(next)
  }

  function setClearBass(v) {
    if (!session) return
    send(["clear-bass", String(Math.round(v))], "eq_clear_bass", Math.round(v))
  }

  function undoEq() {
    if (!snapshotTaken) return
    setBands(snapshotBands.slice())
    setClearBass(snapshotClearBass)
  }

  function setDsee(on) { if (session) send(["dsee", on ? "on" : "off"], "dsee", on) }
  function setPriority(p) { if (session && p !== audioPriority) send(["priority", p], "audio_priority", p) }
  function setPowerOff(label) {
    if (session) send(["power-off", powerOffValue(label)], "power_off", powerOffValue(label))
  }
  function setAutoPause(on) { if (session) send(["auto-pause", on ? "on" : "off"], "auto_pause", on) }
  function setMultipoint(on) { if (session) send(["multipoint", on ? "on" : "off"], "multipoint", on) }
  function deviceAction(action, mac) {
    if (!session) return
    var next = {}
    for (var k in busyDevices) next[k] = busyDevices[k]
    next[mac] = action
    busyDevices = next
    deviceSweep.restart()
    send(["device", action, mac])
  }

  function askRemove(mac, name) {
    removeMac = mac
    removeName = name
    removeConfirm.opened = true
  }

  function startDaemon() {
    daemonCmd.command = ["systemctl", "--user", "start", "mdrctld"]
    daemonCmd.running = true
  }

  // The daemon pushes every change down this socket, so there is nothing to
  // poll and a click shows up as fast as the device answers.
  Socket {
    id: link
    path: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/mdrctl/sock"
    connected: true
    onConnectedChanged: if (connected) write("subscribe\n")

    parser: SplitParser {
      splitMarker: "\n"
      onRead: function(line) {
        try {
          var msg = JSON.parse(line)
          if (msg.state) root.applyState(msg.state)
        } catch (e) {
          return
        }
      }
    }
  }

  // The socket is the fast path; this is the safety net for when the daemon is
  // not there to connect to, and the only source of truth about its absence.
  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onLoaded: if (!link.connected) root.parseState(text())
    onFileChanged: if (!link.connected) reload()
    onLoadFailed: root.state = ({})
  }

  Timer {
    // Only has to notice that the daemon went away, and reconnect when it is
    // back; everything else arrives by push.
    interval: 2000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      root.nowSec = Date.now() / 1000
      if (!link.connected) {
        link.connected = true
        stateFile.reload()
      }
    }
  }

  Timer {
    // An action the headset never reflects would otherwise spin forever.
    id: deviceSweep
    interval: 10000
    onTriggered: root.busyDevices = ({})
  }

  Timer {
    // A claim the device never contradicts would otherwise stick forever.
    id: pendingSweep
    interval: 5000
    onTriggered: root.pending = ({})
  }

  Process {
    id: daemonCmd
    onExited: { link.connected = true; stateFile.reload() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(780))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: {
        if (removeConfirm.opened) removeConfirm.opened = false
        else root.close()
      }
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
            opacity: root.waiting("mode") ? 0.55 : 1.0
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
              model: root.eqBands.length

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
                      var v = Number(root.eqBands[bandItem.index])
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
                  value: Number(root.eqBands[bandItem.index])
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
                text: (root.clearBass > 0 ? "+" : "") + root.clearBass
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
              value: root.clearBass
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
        // Shown, not offered. The command is sent and the device acknowledges
        // it within 25 ms, then keeps the old value -- same as the equaliser
        // presets. Two controls now known to be accepted and discarded.
        Item {
          width: parent.width
          visible: root.session && root.audioPriority !== "" && root.has("connection_mode")
          implicitHeight: connLabel.implicitHeight

          Text {
            id: connLabel
            anchors.left: parent.left
            text: "Connection"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            anchors.right: parent.right
            text: root.audioPriority === "quality" ? "sound quality" : root.audioPriority
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
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

          // Shown, not offered: the write is acknowledged and discarded, like
          // the equaliser presets and connection priority. Verified twice by
          // reconnecting -- what looked like it working was our own optimism
          // being read back.
          Item {
            width: parent.width
            implicitHeight: powerOffLabelText.implicitHeight

            Text {
              id: powerOffLabelText
              anchors.left: parent.left
              text: "Switch off"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              anchors.right: parent.right
              text: root.powerOffLabel(root.powerOff)
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
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

        }

        // ---- devices -------------------------------------------------------
        // The headset's own view of who it is talking to. BlueZ cannot see
        // this: it knows about our link and nothing about the headset's
        // others, so the phone is invisible from that side.
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.session && root.devices.length > 0

          Item {
            width: parent.width
            implicitHeight: Math.max(devHeader.implicitHeight, devValue.implicitHeight)

            Text {
              id: devHeader
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: (root.devicesExpanded ? "\u25be  " : "\u25b8  ") + "Devices"
              color: devMouse.containsMouse ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              id: devValue
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.othersConnected.length === 0
                ? "this PC only"
                : "also " + root.othersConnected.join(", ")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
              width: Math.min(implicitWidth, parent.width - devHeader.implicitWidth - Style.space(12))
              horizontalAlignment: Text.AlignRight
            }

            MouseArea {
              id: devMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.devicesExpanded = !root.devicesExpanded
            }
          }

          Column {
            width: parent.width
            visible: root.devicesExpanded
            spacing: Style.space(6)

            Toggle {
              width: parent.width
              opacity: root.waiting("multipoint") ? 0.55 : 1.0
              label: "Multipoint"
              description: "Stay connected to two devices at once"
              checked: root.multipoint
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.setMultipoint(!root.multipoint)
            }

            Repeater {
              model: root.devices

              Item {
                id: deviceRow
                required property var modelData
                readonly property bool busy: root.deviceBusy(modelData.mac)
                readonly property bool isPlaying: modelData.playback === true
                readonly property bool isSelf:
                  root.selfMac !== "" && String(modelData.mac).toUpperCase() === root.selfMac
                readonly property bool canDisconnect: modelData.connected && !isSelf
                readonly property string label:
                  modelData.name && modelData.name !== "" ? modelData.name : modelData.mac
                width: parent.width
                implicitHeight: Math.max(devName.implicitHeight, actions.implicitHeight)

                // Three states in one glyph rather than a word that has to be
                // truncated: hollow for not connected, filled for connected,
                // ringed for the one actually carrying audio.
                Text {
                  id: statusDot
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(16)
                  text: deviceRow.isPlaying ? "\u25c9" : (deviceRow.modelData.connected ? "\u25cf" : "\u25cb")
                  color: deviceRow.modelData.connected ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  id: devName
                  anchors.left: statusDot.right
                  anchors.right: actions.left
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  text: deviceRow.label
                  color: deviceRow.modelData.connected ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }

                MouseArea {
                  id: rowHover
                  anchors.left: parent.left
                  anchors.right: actions.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  hoverEnabled: true
                  acceptedButtons: Qt.NoButton

                  PanelToolTip {
                    visible: rowHover.containsMouse
                    text: deviceRow.isSelf ? "This computer"
                          : deviceRow.isPlaying ? "Connected, and playing"
                          : deviceRow.modelData.connected ? "Connected to the headphones"
                          : "Not connected -- start the connection from the device itself"
                    fontFamily: root.fontFamily
                  }
                }

                Row {
                  id: actions
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)

                  // No Connect: the headset cannot dial out to a paired device,
                  // here or in Sony's own app. Both actions are icons of the
                  // same size, so the column stays straight whatever the row.
                  PanelActionButton {
                    iconText: deviceRow.busy ? "󰑐" : "󰂲"
                    tooltipText: deviceRow.isSelf
                      ? "This computer -- disconnect it from Bluetooth instead"
                      : "Disconnect from the headphones"
                    opacity: deviceRow.canDisconnect ? 1 : 0
                    enabled: deviceRow.canDisconnect && !deviceRow.busy
                    foreground: root.foreground
                    hoverColor: root.accent
                    fontFamily: root.fontFamily
                    onClicked: root.deviceAction("disconnect", deviceRow.modelData.mac)

                    RotationAnimation on rotation {
                      from: 0
                      to: 360
                      duration: 900
                      loops: Animation.Infinite
                      alwaysRunToEnd: true
                      running: deviceRow.busy
                    }
                  }

                  // Kept in the layout even when it cannot be used, so every
                  // row is the same width and the column stays straight.
                  PanelActionButton {
                    iconText: "󰅙"
                    tooltipText: deviceRow.isSelf
                      ? "This computer -- unpair it from Bluetooth instead"
                      : deviceRow.isPlaying
                        ? "The device playing cannot be removed from here"
                        : "Remove this pairing from the headphones"
                    opacity: (deviceRow.isPlaying || deviceRow.isSelf) ? 0 : 1
                    enabled: !deviceRow.isPlaying && !deviceRow.isSelf && !deviceRow.busy
                    foreground: root.foreground
                    hoverColor: root.urgent
                    fontFamily: root.fontFamily
                    onClicked: root.askRemove(deviceRow.modelData.mac, deviceRow.label)
                  }
                }
              }
            }
          }
        }

        // One line covering every field, because the reason is always the same:
        // the headphones do not acknowledge a session's own writes.
        Text {
          visible: root.unackedText !== "" || root.unconfirmedText !== ""
          width: parent.width
          text: root.unackedText !== "" ? root.unackedText : root.unconfirmedText
          color: root.unackedText !== "" ? root.urgent : root.dim
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

      // Unpairing is the one thing here that cannot be undone from this panel:
      // the device has to be paired again from the other end.
      ConfirmDialog {
        id: removeConfirm
        anchors.fill: parent
        z: 10
        message: "Remove " + root.removeName + " from the headphones?"
        confirmText: "Remove"
        background: root.background
        foreground: root.foreground
        fontFamily: root.fontFamily
        onConfirmed: {
          removeConfirm.opened = false
          root.deviceAction("unpair", root.removeMac)
        }
        onCanceled: removeConfirm.opened = false
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
