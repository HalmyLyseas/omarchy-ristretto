import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The control panel: every control is live and reachable from the keyboard.
// The delay sliders write shell.json's idle keys, both switches drive the
// native state they mirror, and the sleep slider stores the delay the
// service arms on an idle lock. The hero subtitle carries the armed
// behaviour -- the one thing the controls below do not show at a glance.
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

  // The delays displayed are the ones omarchy.idle actually acts on: its
  // derived timeout properties, not a re-parse of shell.json. The service
  // owns the parsing rules (0 is valid and means "immediately"; negatives
  // fall back to its defaults), so binding it keeps this panel honest even
  // if those rules change.
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

  // The plugin's own settings. The delay defaults to "never", so installing
  // the plugin cannot change what the machine does until the user asks for it.
  readonly property int sleepSeconds: Number(setting("sleepAfterIdleLock", Model.SLEEP_NEVER))
  readonly property int sleepIndex: Model.sleepIndexFor(sleepSeconds)
  readonly property bool dryRun: setting("dryRun", false) === true

  // Stay awake is owned by omarchy.idle; bind, never cache.
  readonly property var idleService: bar && bar.shell ? bar.shell.firstPartyServiceFor("omarchy.idle") : null
  readonly property bool stayAwake: idleService ? idleService.stayAwake === true : false

  // The screensaver flag is owned by this plugin's own service -- one
  // watcher machine-wide, panels bind. Reading it as "enabled" keeps the
  // switch's sense the same as the label.
  readonly property var ristrettoService: shell ? shell.serviceFor("halmylyseas.ristretto") : null
  readonly property bool screensaverOff: ristrettoService ? ristrettoService.screensaverOff === true : false
  readonly property bool screensaverEnabled: !screensaverOff

  // What the machine will actually do, for the hero subtitle. Composed from
  // the same bindings as the controls, so it can never disagree with them.
  // Kept short deliberately: the hero meta gets the width left over after the
  // stay-awake control, about two dozen caption characters before it elides.
  readonly property string heroStatus: {
    if (stayAwake) return "staying awake"
    return sleepSeconds > 0 ? "sleep " + Model.sleepStatusShort(sleepSeconds) + " after lock"
                            : "sleep never"
  }

  // ------------------------------------------------------ keyboard cursor
  //
  // Same state machine as the first-party Display panel: a section cursor
  // driven by PanelKeyCatcher, revealed by the first arrow key, and kept in
  // sync with the mouse through hover. Up/Down walk the sections; Left/Right
  // nudge a slider or move along the sleep row; Space/Enter activate.

  property bool cursorActive: false
  property string focusSection: "stayawake"
  readonly property var sections: ["stayawake", "screensaver", "ssdelay", "lockdelay", "sleep"]

  function moveCursor(dy) {
    var i = sections.indexOf(focusSection)
    if (i < 0) { focusSection = sections[0]; return }
    focusSection = sections[Math.max(0, Math.min(sections.length - 1, i + dy))]
  }

  // Steps are computed from the ACTUAL stored value, not the snapped index:
  // an off-scale 2.5 minutes steps down to 2 rather than skipping to 1, and
  // a legacy above-scale sleep value cannot jump to "never" from a single
  // "make it longer" keystroke.
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

  // Write only the keys named in the patch: the untouched delay keeps
  // whatever the user (or their hand-edited config) holds, even off-scale
  // values this panel can only approximate. omarchy.idle binds its timeouts
  // reactively, so a write re-arms the cycle with no restart.
  function writeIdle(patch) {
    var host = root.shell
    if (!host || typeof host.mutateShellConfig !== "function") return
    host.mutateShellConfig(function(config) {
      if (!config.idle || typeof config.idle !== "object") config.idle = ({})
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

  // The service owns the flag file and its persistence, so hand the decision
  // over rather than touching ~/.local/state directly. setIdleEnabled(true)
  // means "allow idle", i.e. stay-awake off -- so passing the *current*
  // stayAwake value flips it. Same call the first-party StayAwake indicator
  // makes, which is why the two controls can never disagree.
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

  onOpenedChanged: if (opened) {
    cursorActive = false
    focusSection = "stayawake"
  }

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
