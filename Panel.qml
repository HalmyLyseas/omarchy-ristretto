import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The control panel: every control is live and keyboard-reachable. The
// delay sliders write shell.json's idle keys; the switches drive the
// native state they mirror; the hero subtitle states the armed behaviour.
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

  // The displayed delays are omarchy.idle's own derived timeout properties,
  // never a re-parse of shell.json -- the host owns the parsing rules (0
  // means "immediately"; negatives fall back to its defaults).
  readonly property int screensaverSeconds:
    idleService ? Number(idleService.screensaverTimeoutSeconds) : 150
  readonly property int lockSeconds:
    idleService ? Number(idleService.lockTimeoutSeconds) : 300

  // A stored pair that violates the strict clamp (hand-edited config) is
  // surfaced, not silently repaired: opening a panel must never write.
  // Committing either slider repairs it through the clamp.
  readonly property bool delaysConflict: lockSeconds <= screensaverSeconds
  readonly property int screensaverIndex: Model.nearestIndex(Model.SCREENSAVER_STOPS, screensaverSeconds / 60)
  readonly property int lockIndex: Model.nearestIndex(Model.LOCK_STOPS, lockSeconds / 60)

  // The plugin's own settings, run through the same normalizers the service
  // applies to its shellConfig read -- a hand-edited or legacy value must
  // never look different from the bar than it behaves when it actually fires.
  readonly property int sleepSeconds: Model.normalizeSleepSeconds(
    setting("sleepAfterIdleLock", Model.SLEEP_NEVER),
    ristrettoService ? ristrettoService.minSleepSeconds : 60).seconds
  readonly property int sleepIndex: Model.sleepIndexFor(sleepSeconds)
  readonly property bool dryRun: Model.normalizeDryRun(setting("dryRun", false))

  // Stay awake is owned by omarchy.idle; bind, never cache.
  readonly property var idleService: bar && bar.shell ? bar.shell.firstPartyServiceFor("omarchy.idle") : null
  readonly property bool stayAwake: idleService ? idleService.stayAwake === true : false

  // The screensaver flag is owned by this plugin's own service -- one
  // watcher machine-wide, panels bind. Reading it as "enabled" keeps the
  // switch's sense the same as the label.
  readonly property var ristrettoService: shell ? shell.serviceFor("halmylyseas.ristretto") : null
  readonly property bool screensaverOff: ristrettoService ? ristrettoService.screensaverOff === true : false
  readonly property bool screensaverEnabled: !screensaverOff

  // What the machine will actually do, composed from the same bindings as
  // the controls so it can never disagree with them. Kept short: the hero
  // meta gets only the width left over after the stay-awake control.
  readonly property string heroStatus: {
    if (stayAwake) return "staying awake"
    return sleepSeconds > 0 ? "sleep " + Model.sleepLabel(sleepSeconds, true) + " after lock"
                            : "sleep never"
  }

  // ------------------------------------------------------ keyboard cursor
  // The same state machine as the first-party Display panel: a section
  // cursor revealed by the first arrow key and synced with mouse hover.

  property bool cursorActive: false
  property string focusSection: "stayawake"
  readonly property var sections: ["stayawake", "screensaver", "ssdelay", "lockdelay", "sleep"]

  function moveCursor(dy) {
    var i = sections.indexOf(focusSection)
    if (i < 0) { focusSection = sections[0]; return }
    focusSection = sections[Math.max(0, Math.min(sections.length - 1, i + dy))]
  }

  // Steps come from the actual stored value, not the snapped index -- an
  // off-scale 2.5 minutes steps down to 2, not 1, and a legacy above-scale
  // sleep value cannot jump to "never" from a single keystroke.
  function moveCursorH(dx) {
    if (focusSection === "ssdelay") {
      var s = Model.stepFrom(Model.SCREENSAVER_STOPS, root.screensaverSeconds / 60, dx)
      if (s >= 0) root.commitScreensaver(s)
    } else if (focusSection === "lockdelay") {
      var l = Model.stepFrom(Model.LOCK_STOPS, root.lockSeconds / 60, dx)
      if (l >= 0) root.commitLock(l)
    } else if (focusSection === "sleep") {
      var p = Model.sleepStepFrom(root.sleepSeconds, dx)
      if (p !== null) root.commitSleep(p)
    }
  }

  function activateCursor() {
    if (focusSection === "stayawake") root.toggleStayAwake()
    else if (focusSection === "screensaver") root.setScreensaverEnabled(!root.screensaverEnabled)
  }

  function pointCursor(section) {
    root.cursorActive = true
    root.focusSection = section
  }

  // -------------------------------------------------------------- writes

  // Writes only the keys named in the patch, so the untouched delay keeps
  // whatever value it already held. omarchy.idle binds its timeouts
  // reactively, so the write re-arms the cycle with no restart.
  function writeIdle(patch) {
    var host = root.shell
    if (!host || typeof host.mutateShellConfig !== "function") return
    host.mutateShellConfig(function(config) {
      // An array is typeof "object" too, but a named property set on one
      // (config.idle.screensaver = ...) vanishes under JSON serialization.
      if (!config.idle || typeof config.idle !== "object" || Array.isArray(config.idle))
        config.idle = ({})
      for (var key in patch) config.idle[key] = patch[key]
    })
  }

  // The strict clamp is checked against the ACTUAL stored partner value,
  // and the partner is written only when the clamp forces it to move --
  // one mutation either way, so shell.json never briefly disagrees.
  function commitScreensaver(sliderValue) {
    var ss = Model.SCREENSAVER_STOPS[Math.round(sliderValue)]
    var patch = ({ screensaver: ss * 60 })
    if (root.lockSeconds <= ss * 60)
      patch.lock = Model.LOCK_STOPS[Model.lockIndexAbove(ss, root.lockIndex)] * 60
    writeIdle(patch)
  }

  function commitLock(sliderValue) {
    var lk = Model.LOCK_STOPS[Math.round(sliderValue)]
    var patch = ({ lock: lk * 60 })
    if (root.screensaverSeconds >= lk * 60)
      patch.screensaver = Model.SCREENSAVER_STOPS[Model.screensaverIndexBelow(lk, root.screensaverIndex)] * 60
    writeIdle(patch)
  }

  // Hands the decision to the service rather than touching state directly.
  // setIdleEnabled(true) means "allow idle" (stay-awake off), so passing
  // the current stayAwake value flips it -- same call the first-party control makes.
  function toggleStayAwake() {
    if (idleService && typeof idleService.setIdleEnabled === "function")
      idleService.setIdleEnabled(root.stayAwake)
  }

  // The service owns the write too, with its optimistic set and its
  // lost-click reconciliation; the panel only states the intent.
  function setScreensaverEnabled(enabled) {
    if (ristrettoService && typeof ristrettoService.setScreensaverOff === "function")
      ristrettoService.setScreensaverOff(!enabled)
  }

  // updateEntryInline replaces the whole entry with what it is handed, so
  // merge onto current settings first or every sibling key is dropped --
  // dryRun included, the one guard between a bug and a real suspend.
  function commitSleep(seconds) {
    var host = root.shell
    if (!host || typeof host.updateEntryInline !== "function") return
    host.updateEntryInline(root.moduleName,
                           Model.mergedSettings(root.settings, "sleepAfterIdleLock", seconds))
  }

  onOpenedChanged: if (opened) {
    cursorActive = false
    focusSection = "stayawake"
  }

  // Debug-only, read by the UI probe harness -- production never reads this.
  readonly property var _debugContentItem: column

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
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.moveCursorH(dx)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
    }

    Column {
      id: column
      width: parent.width
      spacing: Style.space(10)

      // ---------- Hero: mark, title, live status, stay-awake switch ----------
      PanelHero {
        width: parent.width
        title: "Ristretto"
        meta: root.heroStatus
        // The one setting with no control below: surface it as a badge so a
        // machine that will not really suspend can never look armed.
        detail: root.dryRun ? "DRY RUN" : ""
        foreground: root.foreground
        fontFamily: root.fontFamily
        iconComponent: Component {
          RistrettoIcon {
            iconSize: Style.font.display
            color: root.foreground
            steam: root.stayAwake
          }
        }
        trailingControl: Component {
          Row {
            spacing: Style.space(8)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "STAY AWAKE"
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            ToggleSwitch {
              id: stayAwakeSwitch
              anchors.verticalCenter: parent.verticalCenter
              checked: root.stayAwake
              foreground: root.foreground
              hasCursor: root.cursorActive && root.focusSection === "stayawake"
              onToggled: root.toggleStayAwake()
              onContainsMouseChanged: if (containsMouse) root.pointCursor("stayawake")

              PanelToolTip {
                visible: stayAwakeSwitch.containsMouse
                text: "Pause all idle behaviour: no screensaver, no lock, no sleep"
              }
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
            hasCursor: root.cursorActive && root.focusSection === "screensaver"
            onToggled: root.setScreensaverEnabled(!root.screensaverEnabled)
            onContainsMouseChanged: if (containsMouse) root.pointCursor("screensaver")

            PanelToolTip {
              visible: screensaverSwitch.containsMouse
              text: "Launch the screensaver after the delay below"
            }
          }

          Text {
            text: Model.minutesLabel(Model.SCREENSAVER_STOPS[
              screensaverSlider.dragging ? Math.round(screensaverSlider.liveValue) : root.screensaverIndex])
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.right: parent.right
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        CursorSurface {
          width: parent.width
          height: screensaverSlider.implicitHeight + Style.spacing.controlGap
          hasCursor: root.cursorActive && root.focusSection === "ssdelay"
          foreground: root.foreground
          outline: true
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

          HoverHandler {
            onHoveredChanged: if (hovered) root.pointCursor("ssdelay")
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
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.right: parent.right
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        CursorSurface {
          width: parent.width
          height: lockSlider.implicitHeight + Style.spacing.controlGap
          hasCursor: root.cursorActive && root.focusSection === "lockdelay"
          foreground: root.foreground
          outline: true

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

          HoverHandler {
            onHoveredChanged: if (hovered) root.pointCursor("lockdelay")
          }
        }

        // A hand-edited config can hold lock <= screensaver, which makes the
        // host fire both stages in the same pass. Surface it rather than
        // silently repairing -- opening a panel must never write.
        Text {
          visible: root.delaysConflict
          width: parent.width
          text: "Stored lock delay is not above the screensaver delay; moving either slider repairs it."
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.italic: true
        }
      }

      PanelSeparator { foreground: root.foreground }

      // ---------- Sleep after idle lock ----------
      Column {
        width: parent.width
        spacing: Style.space(6)
        opacity: root.stayAwake ? 0.4 : 1.0

        Item {
          width: parent.width
          implicitHeight: Math.max(sleepHeader.implicitHeight, sleepValue.implicitHeight)

          PanelSectionHeader {
            id: sleepHeader
            text: "SLEEP AFTER IDLE LOCK"
            foreground: root.foreground
            fontFamily: root.fontFamily
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: sleepValue
            text: Model.sleepLabel(Model.SLEEP_STOPS[
              sleepSlider.dragging ? Math.round(sleepSlider.liveValue) : root.sleepIndex])
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.right: parent.right
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        CursorSurface {
          width: parent.width
          height: sleepSlider.implicitHeight + Style.spacing.controlGap
          hasCursor: root.cursorActive && root.focusSection === "sleep"
          foreground: root.foreground
          outline: true

          PanelSlider {
            id: sleepSlider
            bar: root.bar
            anchors.fill: parent
            anchors.leftMargin: Style.space(6)
            anchors.rightMargin: Style.space(6)
            minimum: 0
            maximum: Model.SLEEP_STOPS.length - 1
            step: 1
            integer: true
            tickCount: Model.SLEEP_STOPS.length
            value: root.sleepIndex
            onReleased: function(v) { root.commitSleep(Model.SLEEP_STOPS[Math.round(v)]) }
          }

          HoverHandler {
            onHoveredChanged: if (hovered) root.pointCursor("sleep")
          }
        }
      }
    }
  }
}
