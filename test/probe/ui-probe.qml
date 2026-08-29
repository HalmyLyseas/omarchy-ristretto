import QtQuick
import Quickshell
import Quickshell.Io

// Instantiates the REAL BarWidget.qml (which eagerly loads Panel.qml) and the
// REAL Service.qml against a stub bar/shell and the mock omarchy-toggle*
// tools. Drives one env-selected scenario and prints one PROBE_RESULT line.
ShellRoot {
  id: probeRoot

  property string pluginDir: Quickshell.env("RISTRETTO_PLUGIN_DIR")
  property string scenario: Quickshell.env("RISTRETTO_UI_SCENARIO") || ""
  property string mockLog: Quickshell.env("RISTRETTO_MOCK_LOG")
  property bool done: false

  property var barWidget: null
  property var svc: null

  function panel() { return barWidget ? barWidget._debugPanelItem : null }

  // Stay-awake and lock/idle timings a real omarchy.idle would derive --
  // scripted here since compositor idle state cannot be driven in a probe.
  QtObject {
    id: idleStub
    property string lastEvent: ""
    property bool stayAwake: false
    property int screensaverTimeoutSeconds: 150
    property int lockTimeoutSeconds: 300
    property var setIdleEnabledCalls: []
    function setIdleEnabled(enable) {
      idleStub.setIdleEnabledCalls = idleStub.setIdleEnabledCalls.concat([enable])
      idleStub.stayAwake = !enable
    }
  }

  QtObject {
    id: lockStub
    property bool locked: false
    property bool pendingSessionLock: false
  }

  QtObject {
    id: originStub
    property bool isIdle: true
  }

  // Shared between the real Service.qml (`item.shell`) and BarWidget/Panel's
  // `bar.shell`. mutateShellConfig models only the `idle` key (the only one
  // writeIdle() touches) as a diff against the last persisted value.
  QtObject {
    id: stubShell
    property var idleConfig: ({})
    property var mutateCalls: []
    property var updateEntryInlineCalls: []
    property var svcInstance: null
    function firstPartyServiceFor(id) {
      if (id === "omarchy.idle") return idleStub
      if (id === "omarchy.lock") return lockStub
      return null
    }
    function serviceFor(id) { return id === "halmylyseas.ristretto" ? stubShell.svcInstance : null }
    readonly property var shellConfig: ({
      bar: { layout: { left: [], center: [], right: [{ id: "halmylyseas.ristretto" }] } },
      plugins: []
    })
    function mutateShellConfig(mutator) {
      var config = { idle: JSON.parse(JSON.stringify(stubShell.idleConfig)) }
      mutator(config)
      var before = stubShell.idleConfig
      var patch = ({})
      for (var k in config.idle) {
        if (JSON.stringify(config.idle[k]) !== JSON.stringify(before[k])) patch[k] = config.idle[k]
      }
      stubShell.idleConfig = config.idle
      stubShell.mutateCalls = stubShell.mutateCalls.concat([patch])
    }
    function updateEntryInline(id, settings) {
      stubShell.updateEntryInlineCalls = stubShell.updateEntryInlineCalls.concat([{ id: id, settings: settings }])
    }
  }

  // Every property/method KeyboardPanel/PanelSlider/ToggleSwitch/BarIconButton
  // read off `bar` -- a name missing here is a TypeError the moment the real
  // widget touches it.
  QtObject {
    id: stubBar
    property color foreground: "#e6e6e6"
    property color background: "#101315"
    property color urgent: "#ff5555"
    property color barForeground: "#e6e6e6"
    property string fontFamily: "monospace"
    property string position: "top"
    property bool vertical: false
    property int barSize: 26
    property bool foregroundAnimationEnabled: true
    property var shell: stubShell
    property var activePopout: null
    property var clickTargets: []
    property var tooltipCalls: []
    function showTooltip(target, text) { stubBar.tooltipCalls = stubBar.tooltipCalls.concat([text]) }
    function hideTooltip(target) {}
    function requestPopout(owner) { stubBar.activePopout = owner }
    function releasePopout(owner) { if (stubBar.activePopout === owner) stubBar.activePopout = null }
    function moduleWidgets(name) { return probeRoot.barWidget ? [probeRoot.barWidget] : [] }
    function registerClickTarget(target) {}
    function unregisterClickTarget(target) {}
  }

  // Loaded eagerly except for the lifecycle scenario, which needs
  // serviceFor() to return null at first paint on purpose.
  Loader {
    id: svcLoader
    active: probeRoot.scenario !== "lifecycle"
    source: "file://" + probeRoot.pluginDir + "/Service.qml"
    onLoaded: {
      probeRoot.svc = item
      stubShell.svcInstance = item
      probeRoot._armService(item)
    }
  }

  function _armService(item) {
    item.shell = stubShell
    item.originIdleSource = originStub
    item.minSleepSeconds = 1
    item.toolTimeoutMs = 800
    item.suspendTimeoutMs = 800
    item.configEntryCheckMs = 20000
  }

  Loader {
    id: barLoader
    active: true
    source: "file://" + probeRoot.pluginDir + "/BarWidget.qml"
    onLoaded: {
      probeRoot.barWidget = item
      item.bar = stubBar
      item.settings = ({})
      settleTimer.start()
    }
  }

  // Generic poll-until helper: calls `check()` every 50ms until it returns
  // true or `timeoutMs` elapses, then calls `cb(timedOut)`.
  function waitUntil(check, timeoutMs, cb) {
    var waited = 0
    var timer = Qt.createQmlObject(
      'import QtQuick; Timer { interval: 50; repeat: true }', probeRoot)
    timer.triggered.connect(function() {
      waited += 50
      if (check()) {
        timer.stop(); timer.destroy()
        cb(false)
      } else if (waited > timeoutMs) {
        timer.stop(); timer.destroy()
        cb(true)
      }
    })
    timer.start()
  }

  property var _afterCb: null
  Timer {
    id: afterTimer
    repeat: false
    onTriggered: {
      var cb = probeRoot._afterCb
      probeRoot._afterCb = null
      if (cb) cb()
    }
  }
  function after(ms, cb) {
    probeRoot._afterCb = cb
    afterTimer.interval = ms
    afterTimer.restart()
  }

  // Depth-first search for a descendant whose `propName` matches `propValue`
  // -- how a section header or the conflict warning is identified from
  // outside, since a QML Item has no id reachable across files.
  function findByProp(item, propName, propValue) {
    if (!item) return null
    if (propName in item && item[propName] === propValue) return item
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) {
      var found = findByProp(kids[i], propName, propValue)
      if (found) return found
    }
    return null
  }

  // Reads the mock log file asynchronously (a Process, not a blocking
  // read) and hands the text to `cb`.
  Process {
    id: catLogProc
    running: false
    property var onDone: null
    command: ["cat", probeRoot.mockLog]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var cb = catLogProc.onDone
        catLogProc.onDone = null
        if (cb) cb(text)
      }
    }
  }
  function readMockLog(cb) {
    catLogProc.onDone = cb
    catLogProc.running = true
  }

  Timer {
    id: settleTimer
    interval: 200
    repeat: false
    onTriggered: probeRoot.runScenario()
  }

  function runScenario() {
    if (scenario === "render") return scenarioRender()
    if (scenario === "slider-commit") return scenarioSliderCommit()
    if (scenario === "conflict") return scenarioConflict()
    if (scenario === "keyboard") return scenarioKeyboard()
    if (scenario === "hero") return scenarioHero()
    if (scenario === "commit-sleep-merge") return scenarioCommitSleepMerge()
    if (scenario === "lifecycle") return scenarioLifecycle()
    if (scenario === "nospawn") return scenarioNoSpawn()
    finish("unknown RISTRETTO_UI_SCENARIO: " + scenario)
  }

  // (1) render: hero meta reads "sleep never" with the default entry;
  // sliders sit on the nearest stop of the host delays with no write.
  function scenarioRender() {
    var p = panel()
    if (!p) { finish("no panel instance"); return }
    var afterLoadLen = stubShell.mutateCalls.length
    p.open()
    finish("", {
      heroStatus: p.heroStatus,
      screensaverIndex: p.screensaverIndex,
      lockIndex: p.lockIndex,
      mutateCallsLenAfterLoad: afterLoadLen,
      mutateCallsLenAfterOpen: stubShell.mutateCalls.length
    })
  }

  // (2) slider commits write only the moved key, both directions, and a
  // clamp-forcing move writes both keys with the partner landing on the
  // clamp's chosen stop.
  function scenarioSliderCommit() {
    var p = panel()
    if (!p) { finish("no panel instance"); return }
    var patches = []

    idleStub.screensaverTimeoutSeconds = 60
    idleStub.lockTimeoutSeconds = 1800
    stubShell.idleConfig = ({})
    stubShell.mutateCalls = []
    p.commitScreensaver(1) // stop = 2min = 120s; lock (1800) is well above
    patches.push({ step: "ss-only", patch: stubShell.mutateCalls[stubShell.mutateCalls.length - 1] })

    idleStub.screensaverTimeoutSeconds = 60
    idleStub.lockTimeoutSeconds = 300
    stubShell.idleConfig = ({})
    stubShell.mutateCalls = []
    p.commitLock(2) // stop = 5min = 300s; screensaver (60) is well below
    patches.push({ step: "lock-only", patch: stubShell.mutateCalls[stubShell.mutateCalls.length - 1] })

    idleStub.screensaverTimeoutSeconds = 60
    idleStub.lockTimeoutSeconds = 120 // 2min stop
    stubShell.idleConfig = ({})
    stubShell.mutateCalls = []
    p.commitScreensaver(2) // stop = 3min = 180s >= stored lock -> clamps lock up
    patches.push({ step: "ss-clamp", patch: stubShell.mutateCalls[stubShell.mutateCalls.length - 1] })

    idleStub.screensaverTimeoutSeconds = 600 // 10min stop
    idleStub.lockTimeoutSeconds = 1800
    stubShell.idleConfig = ({})
    stubShell.mutateCalls = []
    p.commitLock(3) // stop = 10min = 600s <= stored screensaver -> clamps screensaver down
    patches.push({ step: "lock-clamp", patch: stubShell.mutateCalls[stubShell.mutateCalls.length - 1] })

    finish("", { patches: patches })
  }

  // (3) conflict: lock <= screensaver on the host -> the warning Text is
  // visible and nothing was written; moving either slider clears it once the
  // probe applies the recorded patch back onto the idle stub.
  function scenarioConflict() {
    var p = panel()
    if (!p) { finish("no panel instance"); return }
    idleStub.lockTimeoutSeconds = 120
    idleStub.screensaverTimeoutSeconds = 180
    var content = p._debugContentItem
    var warning = findByProp(content, "text",
      "Stored lock delay is not above the screensaver delay; moving either slider repairs it.")
    var before = { conflict: p.delaysConflict, visible: warning ? warning.visible : null, mutateLen: stubShell.mutateCalls.length }

    p.commitScreensaver(1) // any move; clamp logic repairs the pair
    var patch = stubShell.mutateCalls[stubShell.mutateCalls.length - 1]
    if (patch.screensaver !== undefined) idleStub.screensaverTimeoutSeconds = patch.screensaver
    if (patch.lock !== undefined) idleStub.lockTimeoutSeconds = patch.lock

    finish("", {
      delaysConflictBefore: before.conflict,
      warningVisibleBefore: before.visible,
      mutateLenBefore: before.mutateLen,
      delaysConflictAfter: p.delaysConflict,
      warningVisibleAfter: warning ? warning.visible : null
    })
  }

  // (4) keyboard model: moveCursor walks the five sections and clamps at
  // both ends; moveCursorH steps from the STORED value; sleep steps into
  // "never" only from the top stop; activateCursor drives stayawake/screensaver.
  function scenarioKeyboard() {
    var p = panel()
    if (!p) { finish("no panel instance"); return }

    p.cursorActive = true
    p.focusSection = "stayawake"
    var down = []
    for (var i = 0; i < 6; i++) { p.moveCursor(1); down.push(p.focusSection) }
    var up = []
    for (var j = 0; j < 6; j++) { p.moveCursor(-1); up.push(p.focusSection) }

    idleStub.screensaverTimeoutSeconds = 150 // 2.5min, between 2 and 3
    idleStub.lockTimeoutSeconds = 300
    p.focusSection = "ssdelay"
    stubShell.mutateCalls = []
    p.moveCursorH(-1)
    var ssDownPatch = stubShell.mutateCalls[stubShell.mutateCalls.length - 1]

    idleStub.screensaverTimeoutSeconds = 150
    idleStub.lockTimeoutSeconds = 1800
    stubShell.mutateCalls = []
    p.moveCursorH(1)
    var ssUpPatch = stubShell.mutateCalls[stubShell.mutateCalls.length - 1]

    barWidget.settings = ({ sleepAfterIdleLock: 600 })
    p.focusSection = "sleep"
    stubShell.updateEntryInlineCalls = []
    p.moveCursorH(1)
    var sleepPatch = stubShell.updateEntryInlineCalls.length > 0
      ? stubShell.updateEntryInlineCalls[stubShell.updateEntryInlineCalls.length - 1].settings : null

    idleStub.stayAwake = false
    idleStub.setIdleEnabledCalls = []
    p.focusSection = "stayawake"
    p.activateCursor()

    waitUntil(function() { return probeRoot.svc && probeRoot.svc.togglePath !== "" }, 5000, function(timedOut) {
      if (timedOut) { finish("service tool resolution did not settle within 5s"); return }
      p.focusSection = "screensaver"
      p.activateCursor()
      after(1200, function() {
        readMockLog(function(text) {
          finish("", {
            down: down,
            up: up,
            ssDownPatch: ssDownPatch,
            ssUpPatch: ssUpPatch,
            sleepPatch: sleepPatch,
            setIdleEnabledCalls: idleStub.setIdleEnabledCalls,
            screensaverToggleLogged: text.indexOf("omarchy-toggle screensaver-off") >= 0
          })
        })
      })
    })
  }

  // (5) hero truth: stay-awake dims the sections and overrides the status;
  // a stored sleep delay reads "after lock"; a string-form dryRun setting
  // is normalized the same way the service normalizes it.
  function scenarioHero() {
    var p = panel()
    if (!p) { finish("no panel instance"); return }

    idleStub.stayAwake = true
    var content = p._debugContentItem
    var ssHeader = findByProp(content, "text", "SCREENSAVER")
    var dimColumn = ssHeader && ssHeader.parent ? ssHeader.parent.parent : null
    var heroStayAwake = p.heroStatus
    var dimOpacity = dimColumn ? dimColumn.opacity : null

    idleStub.stayAwake = false
    barWidget.settings = ({ sleepAfterIdleLock: 300 })
    var heroSleep300 = p.heroStatus

    barWidget.settings = ({ sleepAfterIdleLock: 300, dryRun: "true" })
    var dryRunFromStringTrue = p.dryRun

    finish("", {
      heroStayAwake: heroStayAwake,
      dimOpacity: dimOpacity,
      heroSleep300: heroSleep300,
      dryRunFromStringTrue: dryRunFromStringTrue
    })
  }

  // (6) commitSleep merge: updateEntryInline gets every current key plus
  // the moved one -- a sibling setting (dryRun) must survive the write.
  function scenarioCommitSleepMerge() {
    var p = panel()
    if (!p) { finish("no panel instance"); return }
    barWidget.settings = ({ sleepAfterIdleLock: 60, dryRun: true })
    stubShell.updateEntryInlineCalls = []
    p.commitSleep(300)
    var call = stubShell.updateEntryInlineCalls[stubShell.updateEntryInlineCalls.length - 1]
    finish("", { call: call })
  }

  // (7) lifecycle: serviceFor returns null at first paint -> the panel
  // renders with screensaverEnabled=true and zero TypeErrors; then the real
  // service arrives and the binding follows screensaverOff.
  function scenarioLifecycle() {
    var p = panel()
    if (!p) { finish("no panel instance"); return }
    var screensaverEnabledWhileNull = p.screensaverEnabled

    svcLoader.active = true
    waitUntil(function() { return probeRoot.svc && probeRoot.svc.togglePath !== "" && probeRoot.svc.toggleEnabledPath !== "" },
      5000, function(timedOut) {
        if (timedOut) { finish("service did not resolve its tools within 5s"); return }
        probeRoot.svc.setScreensaverOff(true)
        waitUntil(function() { return p.screensaverOff === true }, 5000, function(timedOut2) {
          finish(timedOut2 ? "screensaverOff never followed the live service" : "", {
            screensaverEnabledWhileNull: screensaverEnabledWhileNull,
            screensaverOffAfterServiceArrives: p.screensaverOff
          })
        })
      })
  }

  // (8) no other Process is spawned by the UI: Panel/BarWidget own no
  // Process elements, so every mock-log line after settling must be one of
  // the service's own startup calls, never systemctl/notification-send/etc.
  function scenarioNoSpawn() {
    var p = panel()
    if (!p) { finish("no panel instance"); return }
    waitUntil(function() { return probeRoot.svc && probeRoot.svc.toggleEnabledPath !== "" }, 5000, function(timedOut) {
      after(500, function() {
        readMockLog(function(text) {
          var lines = text.split("\n").filter(function(l) { return l.length > 0 })
          var onlyServiceStartup = true
          for (var i = 0; i < lines.length; i++) if (lines[i].indexOf("omarchy-toggle") < 0) onlyServiceStartup = false
          finish("", { onlyServiceStartupLogged: onlyServiceStartup, mockLogLineCount: lines.length })
        })
      })
    })
  }

  function finish(note, extra) {
    if (done) return
    done = true
    var summary = { scenario: scenario, note: note }
    for (var key in (extra || {})) summary[key] = extra[key]
    console.log("PROBE_RESULT " + JSON.stringify(summary))
    Qt.quit()
  }

  Timer {
    interval: 25000
    running: true
    repeat: false
    onTriggered: probeRoot.finish("probe harness overall timeout (25s)")
  }
}
