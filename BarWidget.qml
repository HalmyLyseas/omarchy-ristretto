import QtQuick
import qs.Commons
import qs.Ui

// Bar entry point. Owns the button and hosts the panel through an eagerly
// active Loader -- the first-party pattern (clock, weather). The panel is
// NOT deferred: it is built once per monitor at bar startup, so keep panel
// startup work light and machine-wide watchers in the service.
BarWidget {
  id: root
  moduleName: "halmylyseas.ristretto"

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  // Debug-only, read by the UI probe harness -- production never reads this.
  readonly property var _debugPanelItem: panelLoader.item

  // Stay awake is owned by omarchy.idle; bind, never cache. The cup steams
  // only while stay-awake keeps it hot, so the bar shows the state at a
  // glance without a separate indicator.
  readonly property var idleService: bar && bar.shell ? bar.shell.firstPartyServiceFor("omarchy.idle") : null
  readonly property bool stayAwake: idleService ? idleService.stayAwake === true : false

  // The panel is loaded standalone, so the host has to hand it everything it
  // cannot reach on its own: the bar, this widget's settings, and the button
  // to anchor against.
  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  // Size the slot from the bar's own metrics rather than from the button:
  // the button fills this Item, so deriving the Item's implicit size from the
  // button's is a binding loop that resolves to zero and paints nothing.
  implicitWidth: vertical ? barSize : Style.bar.statusSlot
  implicitHeight: vertical ? Style.bar.statusSlot : barSize

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

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: Style.bar.statusSlot
    // The mark is a Shape, so it follows the button's colour states the same
    // way a glyph would. BarIconButton force-sizes it to its icon canvas.
    iconComponent: Component {
      RistrettoIcon {
        color: button.active && button.useActiveColor ? button.activeColor : button.foreground
        steam: root.stayAwake
      }
    }
    tooltipText: "Ristretto — screensaver, lock, and sleep delays"
    onPressed: function(b) { root.toggle() }
  }

}
