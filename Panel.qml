import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// P4: every control is live. The delay sliders write shell.json's idle keys,
// both switches drive the native state they mirror, and the sleep row stores
// the delay the service arms on an idle lock.
Panel {
  id: root

  moduleName: "halmylyseas.ristretto"
  ipcTarget: "halmylyseas.ristretto"

  // Handed over by BarWidget.injectPanel().
  property var anchorItem: null
  property var hostWidget: null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---------------------------------------------------------------- state

  readonly property var shell: bar && bar.shell ? bar.shell : null
  readonly property var idleConfig: shell && shell.shellConfig && shell.shellConfig.idle
    ? shell.shellConfig.idle : ({})

  // omarchy.idle stores seconds; this panel works in minutes.
  readonly property int screensaverSeconds: Number(idleConfig.screensaver) > 0 ? Number(idleConfig.screensaver) : 150
  readonly property int lockSeconds: Number(idleConfig.lock) > 0 ? Number(idleConfig.lock) : 300
  readonly property int screensaverIndex: Model.nearestIndex(Model.SCREENSAVER_STOPS, screensaverSeconds / 60)
  readonly property int lockIndex: Model.nearestIndex(Model.LOCK_STOPS, lockSeconds / 60)

  // The plugin's own setting. Default is "never", so installing the plugin
  // cannot change what the machine does until the user asks for it.
  readonly property int sleepSeconds: Number(setting("sleepAfterIdleLock", Model.SLEEP_NEVER))
  readonly property int sleepIndex: Model.indexOfExact(Model.SLEEP_STOPS, sleepSeconds)

  // Stay awake is owned by omarchy.idle; bind, never cache.
  readonly property var idleService: bar && bar.shell ? bar.shell.firstPartyServiceFor("omarchy.idle") : null
  readonly property bool stayAwake: idleService ? idleService.stayAwake === true : false

  // Ristretto owns timing; `omarchy toggle screensaver` owns on/off. Reading
  // the flag as "enabled" keeps the switch's sense the same as the label.
  readonly property bool screensaverEnabled: !screensaverOff

  // The screensaver flag has no QML reader anywhere in Omarchy, so probe the
  // flag file the way omarchy.idle probes its own: a process for the answer,
  // a directory watch to know when to re-ask.
  property bool screensaverOff: false

  // Persist both delays together. Either slider can move the other via the
  // clamp, so writing the pair keeps shell.json internally consistent in one
  // mutation instead of two that briefly disagree. omarchy.idle binds its
  // timeouts reactively, so this re-arms the cycle with no restart.
  function writeDelays(screensaverMinutes, lockMinutes) {
    var host = root.shell
    if (!host || typeof host.mutateShellConfig !== "function") return
    host.mutateShellConfig(function(config) {
      if (!config.idle || typeof config.idle !== "object") config.idle = ({})
      config.idle.screensaver = Math.round(screensaverMinutes * 60)
      config.idle.lock = Math.round(lockMinutes * 60)
    })
  }

  function commitScreensaver(sliderValue) {
    var pair = Model.pairFromScreensaver(Math.round(sliderValue), root.lockIndex)
    writeDelays(pair.screensaver, pair.lock)
  }

  function commitLock(sliderValue) {
    var pair = Model.pairFromLock(Math.round(sliderValue), root.screensaverIndex)
    writeDelays(pair.screensaver, pair.lock)
  }

  // The service owns the flag file and its persistence, so hand the decision
  // over rather than touching ~/.local/state directly. setIdleEnabled(true)
  // means "allow idle", i.e. stay-awake off -- so passing the *current*
  // stayAwake value flips it. Same call the first-party StayAwake indicator
  // makes, which is why the two controls can never disagree.
  function toggleStayAwake() {
    if (idleService && typeof idleService.setIdleEnabled === "function")
      idleService.setIdleEnabled(root.stayAwake)
  }

  // Use the explicit on/off action, never the bare flip: a panel that already
  // shows the state must not depend on what the state happened to be. This is
  // also why `omarchy-toggle` is called rather than `omarchy toggle
  // screensaver`, whose wrapper fires a desktop notification that would be
  // redundant next to a visible switch.
  function setScreensaverEnabled(enabled) {
    root.screensaverOff = !enabled
    screensaverWriter.command = ["omarchy-toggle", "screensaver-off", enabled ? "off" : "on"]
    screensaverWriter.running = true
  }

  Process {
    id: screensaverWriter
    onExited: root.refreshScreensaverFlag()
  }

  // updateEntryInline replaces the entry with { id } plus what it is handed,
  // so merge onto the current settings or every sibling key is dropped --
  // including dryRun, which is the guard standing between a bug and the
  // machine actually suspending.
  function commitSleep(seconds) {
    var host = root.shell
    if (!host || typeof host.updateEntryInline !== "function") return
    host.updateEntryInline(root.moduleName,
                           Model.mergedSettings(root.settings, "sleepAfterIdleLock", seconds))
  }

  function refreshScreensaverFlag() {
    if (!screensaverFlagProbe.running) screensaverFlagProbe.running = true
  }

  Process {
    id: screensaverFlagProbe
    command: ["bash", "-c", "if omarchy-toggle-enabled screensaver-off; then echo yes; else echo no; fi"]
    stdout: SplitParser {
      onRead: function(line) { root.screensaverOff = String(line).trim() === "yes" }
    }
  }

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/toggles"
    watchChanges: true
    printErrors: false
    onFileChanged: root.refreshScreensaverFlag()
  }

  Component.onCompleted: refreshScreensaverFlag()
  onOpenedChanged: if (opened) refreshScreensaverFlag()

  // ------------------------------------------------------------------ UI

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

      // ---------- Hero: mark, title, stay-awake master switch ----------
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
        trailingControl: Component {
          Row {
            spacing: Style.space(8)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "STAY AWAKE"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            ToggleSwitch {
              anchors.verticalCenter: parent.verticalCenter
              checked: root.stayAwake
              foreground: root.foreground
              onToggled: root.toggleStayAwake()
            }
          }
        }
      }

      PanelSeparator { foreground: root.foreground }

      // ---------- Screensaver: own on/off switch, then its delay ----------
      Column {
        width: parent.width
        spacing: Style.space(6)
        opacity: root.stayAwake ? 0.4 : 1.0

        Item {
          width: parent.width
          implicitHeight: Math.max(screensaverHeader.implicitHeight, screensaverSwitch.implicitHeight)

          PanelSectionHeader {
            id: screensaverHeader
            text: "SCREENSAVER"
            foreground: root.foreground
            fontFamily: root.fontFamily
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          ToggleSwitch {
            id: screensaverSwitch
            anchors.left: screensaverHeader.right
            anchors.leftMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            checked: root.screensaverEnabled
            foreground: root.foreground
            onToggled: root.setScreensaverEnabled(!root.screensaverEnabled)
          }

          Text {
            text: Model.minutesLabel(Model.SCREENSAVER_STOPS[
              screensaverSlider.dragging ? Math.round(screensaverSlider.liveValue) : root.screensaverIndex])
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.right: parent.right
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Item {
          width: parent.width
          height: screensaverSlider.implicitHeight + Style.spacing.controlGap
          opacity: root.screensaverOff ? 0.4 : 1.0

          PanelSlider {
            id: screensaverSlider
            bar: root.bar
            anchors.fill: parent
            anchors.leftMargin: Style.space(6)
            anchors.rightMargin: Style.space(6)
            minimum: 0
            maximum: Model.SCREENSAVER_STOPS.length - 1
            step: 1
            integer: true
            tickCount: Model.SCREENSAVER_STOPS.length
            value: root.screensaverIndex
            onReleased: function(v) { root.commitScreensaver(v) }
          }
        }
      }

      // ---------- Lockscreen delay ----------
      Column {
        width: parent.width
        spacing: Style.space(6)
        opacity: root.stayAwake ? 0.4 : 1.0

        Item {
          width: parent.width
          implicitHeight: Math.max(lockHeader.implicitHeight, lockValue.implicitHeight)

          PanelSectionHeader {
            id: lockHeader
            text: "LOCKSCREEN"
            foreground: root.foreground
            fontFamily: root.fontFamily
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: lockValue
            text: Model.minutesLabel(Model.LOCK_STOPS[
              lockSlider.dragging ? Math.round(lockSlider.liveValue) : root.lockIndex])
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.right: parent.right
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Item {
          width: parent.width
          height: lockSlider.implicitHeight + Style.spacing.controlGap

          PanelSlider {
            id: lockSlider
            bar: root.bar
            anchors.fill: parent
            anchors.leftMargin: Style.space(6)
            anchors.rightMargin: Style.space(6)
            minimum: 0
            maximum: Model.LOCK_STOPS.length - 1
            step: 1
            integer: true
            tickCount: Model.LOCK_STOPS.length
            value: root.lockIndex
            onReleased: function(v) { root.commitLock(v) }
          }
        }
      }

      PanelSeparator { foreground: root.foreground }

      // ---------- Sleep after idle lock ----------
      Column {
        width: parent.width
        spacing: Style.space(10)
        opacity: root.stayAwake ? 0.4 : 1.0

        PanelSectionHeader {
          text: "SLEEP AFTER IDLE LOCK"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Row {
          id: sleepRow
          width: parent.width
          spacing: Style.space(6)

          readonly property real cellWidth:
            Math.floor((width - spacing * (Model.SLEEP_STOPS.length - 1)) / Model.SLEEP_STOPS.length)

          Repeater {
            model: Model.SLEEP_STOPS

            Button {
              required property var modelData
              required property int index

              width: sleepRow.cellWidth
              text: Model.sleepLabel(modelData)
              fontSize: Style.font.caption
              foreground: root.foreground
              fontFamily: root.fontFamily
              verticalPadding: Style.spacing.controlPaddingY
              bordered: true
              active: root.sleepIndex === index
              onClicked: root.commitSleep(modelData)
            }
          }
        }
      }
    }
  }
}
