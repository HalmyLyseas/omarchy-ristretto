import QtQuick
import qs.Commons
import qs.Ui

// P0 scaffold: the panel opens, anchors to the bar button, closes on Escape,
// and shows nothing but the hero. Sliders, toggles and the sleep row follow.
Panel {
  id: root

  moduleName: "halmylyseas.ristretto"
  ipcTarget: "halmylyseas.ristretto"

  // Handed over by BarWidget.injectPanel().
  property var anchorItem: null
  property var hostWidget: null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
    }

    Column {
      id: column
      width: parent.width
      spacing: Style.space(10)

      PanelHero {
        width: parent.width
        title: "Ristretto"
        foreground: root.foreground
        fontFamily: root.fontFamily
        iconComponent: Component {
          Text {
            text: ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
          }
        }
      }
    }
  }
}
