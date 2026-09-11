import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar chip for the headphones. All state lives in Panel.qml, which is loaded
// whether or not the popup is open -- the chip reads its label from there, the
// same arrangement omarchy.weather uses.
BarWidget {
  id: root
  moduleName: "io.github.delarosa1312.sony-xm5"

  readonly property var panel: panelLoader.item

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  // Shape contract for shell.summon/hide/toggle routing: Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity, as KeyboardPanel reads popoutSwitchClosing back off its owner.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  // Gone entirely when the headphones are, rather than sitting there dead --
  // but present when the daemon has never answered, because that is a missing
  // install rather than a headset in its case, and silence there reads as a
  // widget that did not work.
  visible: panelLoader.item
    ? (panelLoader.item.present || panelLoader.item.needsSetup) : false
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "io.github.delarosa1312.sony-xm5"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function cycle(): void { if (root.panel) root.panel.cycleMode() }
    function mode(name: string): void { if (root.panel) root.panel.setMode(name) }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.panel ? (root.vertical ? root.panel.glyph : root.panel.barLabel) : ""
    tooltipText: root.panel ? root.panel.barTooltip : ""
    // Without a control session only the battery is known, so say so by
    // fading rather than by hiding a widget that still carries a number.
    dimmed: root.panel ? !root.panel.session : false

    onPressed: function(b) {
      if (b === Qt.RightButton) root.panel.cycleMode()
      else root.togglePanel()
    }

    // Scrolling the chip nudges the ambient level, but only in ambient mode
    // where the number means something.
    onWheelMoved: function(delta) {
      if (root.panel && root.panel.mode === "ambient")
        root.panel.nudgeAmbient(delta > 0 ? 1 : -1)
    }
  }
}
