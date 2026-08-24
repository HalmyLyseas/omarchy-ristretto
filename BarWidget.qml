import QtQuick
import qs.Commons
import qs.Ui

// Bar entry point. Owns the button and defers the panel to a Loader, so the
// bar stays light until the panel is first needed.
BarWidget {
  id: root
  moduleName: "halmylyseas.ristretto"

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

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
    // Placeholder. The shipped mark is a Qt Quick Shape drawn in the bar's
    // foreground; this glyph only stands in until then.
    text: ""
    slotSize: Style.bar.statusSlot
    tooltipText: "Ristretto — screensaver, lock, and sleep delays"
    onPressed: function(b) { root.toggle() }
  }

}
