import QtQuick
import Quickshell
import Quickshell.Io

// Loads the real Service.qml under a stub shell/idle/lock, drives one
// RISTRETTO_SCENARIO end to end, and prints a single "PROBE_RESULT {...}"
// line. systemctl is PATH-shadowed by a mock that only records the call.
ShellRoot {
  id: probeRoot

  property string pluginDir: Quickshell.env("RISTRETTO_PLUGIN_DIR")
  property string scenario: Quickshell.env("RISTRETTO_SCENARIO") || ""
  property bool done: false
  property var service: null
  property var sleepNormChecks: []
  property bool reconcileMidState: false

  property var shellConfigObj: ({
    bar: { layout: { left: [], center: [], right: [{ id: "halmylyseas.ristretto" }] } },
    plugins: []
  })

  function buildConfig(entryPatch) {
    var entry = { id: "halmylyseas.ristretto" }
    for (var k in entryPatch) entry[k] = entryPatch[k]
    return { bar: { layout: { left: [], center: [], right: [entry] } }, plugins: [] }
  }

  function setConfig(entryPatch) {
    probeRoot.shellConfigObj = buildConfig(entryPatch)
  }

  // A plain-string bar-layout entry: renders fine host-side, but
  // Model.entryFor can never match it -- exercises the delayed warning.
  function setStringEntryConfig() {
    probeRoot.shellConfigObj = { bar: { layout: { left: [], center: [], right: ["halmylyseas.ristretto"] } }, plugins: [] }
  }

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

  // Probe seam for Service.qml's originIdleSource -- real compositor idle
  // state cannot be scripted.
  QtObject {
    id: originStub
    property bool isIdle: true
  }

  // firstPartyServiceFor reads these two properties, not just `shell`
  // itself, so reassigning either one is a real, tracked QML dependency --
  // Service.qml's idleService/lockService bindings re-evaluate on a change.
  QtObject {
    id: shellStub
    property var shellConfig: probeRoot.shellConfigObj
    property var idleServiceRef: idleStub
    property var lockServiceRef: lockStub
    function firstPartyServiceFor(id) {
      if (id === "omarchy.idle") return shellStub.idleServiceRef
      if (id === "omarchy.lock") return shellStub.lockServiceRef
      return null
    }
    function serviceFor(id) { return null }
    function updateEntryInline(id, settings) {}
  }

  Loader {
    id: loader
    source: "file://" + probeRoot.pluginDir + "/Service.qml"
    active: true
    onLoaded: {
      probeRoot.service = item
      item.shell = shellStub
      item.originIdleSource = originStub
      // sleep-normalize validates the real 60s production floor; every
      // other scenario needs sub-minute countdowns to stay fast.
      item.minSleepSeconds = probeRoot.scenario === "sleep-normalize" ? 60 : 1
      item.toolTimeoutMs = 800
      item.suspendTimeoutMs = 800
      item.configEntryCheckMs = 300
      settleTimer.start()
    }
  }

  Timer {
    id: settleTimer
    interval: 200
    repeat: false
    onTriggered: probeRoot.runScenario()
  }

  // -------------------------------------------------------------- helpers

  property var _afterCb: null
  Timer {
    id: delayTimer
    repeat: false
    onTriggered: {
      var cb = probeRoot._afterCb
      probeRoot._afterCb = null
      if (cb) cb()
    }
  }
  function after(ms, cb) {
    probeRoot._afterCb = cb
    delayTimer.interval = ms
    delayTimer.restart()
  }

  Timer {
    id: waitTimer
    interval: 50
    repeat: true
    property var predicate: null
    property var cb: null
    property int remaining: 5000
    onTriggered: {
      remaining -= interval
      if (predicate()) {
        stop()
        var f = cb; cb = null
        if (f) f()
      } else if (remaining <= 0) {
        stop()
        var f2 = cb; cb = null
        if (f2) f2()
      }
    }
  }
  function waitUntil(maxMs, predicate, cb) {
    waitTimer.predicate = predicate
    waitTimer.cb = cb
    waitTimer.remaining = maxMs
    waitTimer.restart()
  }

  property int _seq: 0
  function fireLockSystem(reason) {
    probeRoot._seq++
    idleStub.lastEvent = "lock-system: " + (reason || "idle") + " #" + probeRoot._seq
  }
  function fireProcessStartLock() {
    probeRoot._seq++
    idleStub.lastEvent = "process-start: lock omarchy-system-lock #" + probeRoot._seq
  }
  function fireProcessSkipLock() {
    probeRoot._seq++
    idleStub.lastEvent = "process-skip: lock already running #" + probeRoot._seq
  }
  function fireProcessExitLock() {
    probeRoot._seq++
    idleStub.lastEvent = "process-exit: lock exitCode=0 status=0 #" + probeRoot._seq
  }

  // Announce, spawn, raise `locked` (not yet secure), then secure it --
  // the sequence a real idle lock takes. 150ms stands in for the host's
  // own ~500ms stabilize timer; the exact figure is not load-bearing.
  function driveSecureIdleLock(cb) {
    fireLockSystem("idle-timeout")
    fireProcessStartLock()
    lockStub.pendingSessionLock = true
    lockStub.locked = true
    after(150, function () {
      lockStub.pendingSessionLock = false
      if (cb) cb()
    })
  }

  function unlock() {
    lockStub.locked = false
    lockStub.pendingSessionLock = false
  }

  Process {
    id: modeFileProc
    running: false
    property var onDone: null
    onExited: function () {
      var cb = modeFileProc.onDone
      modeFileProc.onDone = null
      if (cb) cb()
    }
  }
  // which: "toggle" or "toggleEnabled". mode: "ok" | "hang" | "fail".
  function writeMode(which, mode, cb) {
    var path = which === "toggleEnabled"
      ? Quickshell.env("RISTRETTO_TOGGLE_ENABLED_MODE_FILE")
      : Quickshell.env("RISTRETTO_TOGGLE_MODE_FILE")
    modeFileProc.onDone = cb
    modeFileProc.command = ["bash", "-c", "printf %s \"$1\" > \"$2\"", "_", mode, path]
    modeFileProc.running = true
  }

  // -------------------------------------------------------------- scenarios

  function runScenario() {
    if (scenario === "armed-fire") return scenarioArmedFire()
    if (scenario === "dryrun-fire") return scenarioDryrunFire()
    if (scenario === "manual-lock") return scenarioManualLock()
    if (scenario === "lock-no-spawn") return scenarioLockNoSpawn()
    if (scenario === "spawn-exit-before-lock") return scenarioSpawnExitBeforeLock()
    if (scenario === "latch-expiry") return scenarioLatchExpiry()
    if (scenario === "never-secure") return scenarioNeverSecure()
    if (scenario === "unlock-mid-countdown") return scenarioUnlockMidCountdown()
    if (scenario === "delay-change-mid-countdown") return scenarioDelayChangeMidCountdown()
    if (scenario === "stayawake-settle-and-fire") return scenarioStayAwakeSettleAndFire()
    if (scenario === "idle-service-lost") return scenarioIdleServiceLost()
    if (scenario === "sleep-normalize") return scenarioSleepNormalize()
    if (scenario === "string-entry-warning") return scenarioStringEntryWarning()
    if (scenario === "screensaver-reconcile") return scenarioScreensaverReconcile()
    if (scenario === "toggle-hang") return scenarioToggleHang()
    if (scenario === "tools-removed") return scenarioToolsRemoved()
    finishNow()
  }

  function scenarioArmedFire() {
    setConfig({ sleepAfterIdleLock: 1, dryRun: false })
    after(50, function () {
      driveSecureIdleLock(function () {
        after(2600, finishNow)
      })
    })
  }

  function scenarioDryrunFire() {
    setConfig({ sleepAfterIdleLock: 1, dryRun: true })
    after(50, function () {
      driveSecureIdleLock(function () {
        after(2600, finishNow)
      })
    })
  }

  function scenarioManualLock() {
    originStub.isIdle = false
    setConfig({ sleepAfterIdleLock: 5 })
    after(50, function () {
      driveSecureIdleLock(function () {
        after(1300, finishNow)
      })
    })
  }

  function scenarioLockNoSpawn() {
    fireLockSystem("idle-timeout")
    after(50, function () {
      fireProcessSkipLock()
      after(300, finishNow)
    })
  }

  function scenarioSpawnExitBeforeLock() {
    fireLockSystem("idle-timeout")
    after(50, function () {
      fireProcessStartLock()
      after(50, function () {
        fireProcessExitLock()
        after(300, finishNow)
      })
    })
  }

  function scenarioLatchExpiry() {
    fireLockSystem("idle-timeout")
    after(50, function () {
      fireProcessStartLock()
      after(3400, finishNow)
    })
  }

  function scenarioNeverSecure() {
    setConfig({ sleepAfterIdleLock: 5 })
    fireLockSystem("idle-timeout")
    after(50, function () {
      fireProcessStartLock()
      lockStub.pendingSessionLock = true
      lockStub.locked = true
      // pendingSessionLock is never cleared -- requested but never secured.
      after(2000, finishNow)
    })
  }

  function scenarioUnlockMidCountdown() {
    setConfig({ sleepAfterIdleLock: 5 })
    after(50, function () {
      driveSecureIdleLock(function () {
        after(1300, function () {
          probeRoot.unlock()
          after(500, finishNow)
        })
      })
    })
  }

  function scenarioDelayChangeMidCountdown() {
    setConfig({ sleepAfterIdleLock: 5 })
    after(50, function () {
      driveSecureIdleLock(function () {
        after(1300, function () {
          setConfig({ sleepAfterIdleLock: 8 })
          after(300, finishNow)
        })
      })
    })
  }

  function scenarioStayAwakeSettleAndFire() {
    setConfig({ sleepAfterIdleLock: 5 })
    after(50, function () {
      driveSecureIdleLock(function () {
        // Inside the 1000ms origin-settle window -- must cancel outright.
        after(300, function () {
          idleStub.stayAwake = true
          after(1000, function () {
            // Fire-time check: refuses regardless of how the countdown
            // would have gotten there.
            service.suspend()
            after(300, finishNow)
          })
        })
      })
    })
  }

  function scenarioIdleServiceLost() {
    setConfig({ sleepAfterIdleLock: 5 })
    after(50, function () {
      driveSecureIdleLock(function () {
        after(300, function () {
          shellStub.idleServiceRef = null
          after(500, finishNow)
        })
      })
    })
  }

  function scenarioSleepNormalize() {
    var checks = []
    var samples = [4294968, true, "300", 5]
    var i = 0
    function step() {
      if (i >= samples.length) { finishNow(); return }
      var raw = samples[i]
      setConfig({ sleepAfterIdleLock: raw })
      after(200, function () {
        checks.push({ raw: String(raw), seconds: service.sleepSeconds })
        probeRoot.sleepNormChecks = checks.slice()
        i++
        step()
      })
    }
    step()
  }

  function scenarioStringEntryWarning() {
    probeRoot.setStringEntryConfig()
    after(600, finishNow)
  }

  function scenarioScreensaverReconcile() {
    waitUntil(3000, function () {
      return service.togglePath !== "" && service.toggleEnabledPath !== ""
    }, function () {
      service.setScreensaverOff(true)
      after(30, function () { service.setScreensaverOff(false) })
      after(60, function () { service.setScreensaverOff(true) })
      after(2000, function () {
        probeRoot.reconcileMidState = service.screensaverOff
        writeMode("toggleEnabled", "fail", function () {
          service.refreshScreensaverFlag()
          after(1200, finishNow)
        })
      })
    })
  }

  function scenarioToggleHang() {
    waitUntil(3000, function () {
      return service.togglePath !== ""
    }, function () {
      writeMode("toggle", "hang", function () {
        service.setScreensaverOff(true)
        after(3000, function () {
          // Watchdog (800ms) + kill (1000ms) should long since have
          // brought the hung mock down; a fresh write must land normally.
          writeMode("toggle", "ok", function () {
            service.setScreensaverOff(false)
            after(1500, finishNow)
          })
        })
      })
    })
  }

  property string toggleLinkPath: Quickshell.env("RISTRETTO_TOGGLE_LINK")
  property string toggleEnabledLinkPath: Quickshell.env("RISTRETTO_TOGGLE_ENABLED_LINK")
  property string toggleMockPath: Quickshell.env("RISTRETTO_TOGGLE_MOCK")
  property string toggleEnabledMockPath: Quickshell.env("RISTRETTO_TOGGLE_ENABLED_MOCK")

  Process {
    id: linkProc
    running: false
    property var onDone: null
    onExited: function () {
      var cb = linkProc.onDone
      linkProc.onDone = null
      if (cb) cb()
    }
  }
  // The link-creation is a probe-side fixture step (not part of Service.qml's
  // own retry) -- it makes the two mocks appear on PATH the way a package
  // update or a PATH fix mid-session would.
  function createRemovedLinks(cb) {
    linkProc.onDone = cb
    linkProc.command = ["bash", "-c", "ln -sfn \"$1\" \"$2\"; ln -sfn \"$3\" \"$4\"", "_",
      probeRoot.toggleMockPath, probeRoot.toggleLinkPath,
      probeRoot.toggleEnabledMockPath, probeRoot.toggleEnabledLinkPath]
    linkProc.running = true
  }

  property var _toolsRemovedFirstAttempt: null
  function scenarioToolsRemoved() {
    // linkdir has no omarchy-toggle*/ symlinks at startup (test/probe/run
    // arranges this) -- resolution must fail loudly, not crash, and retry.
    after(1000, function () {
      probeRoot._toolsRemovedFirstAttempt = {
        togglePath: service.togglePath,
        toggleEnabledPath: service.toggleEnabledPath
      }
      createRemovedLinks(function () {
        waitUntil(17000, function () {
          return service.togglePath !== "" && service.toggleEnabledPath !== ""
        }, finishNow)
      })
    })
  }

  function finishNow() { finish("") }

  function finish(note) {
    if (done) return
    done = true
    var summary = {
      scenario: probeRoot.scenario,
      note: note,
      idleLockPending: service.idleLockPending,
      secureLocked: service.secureLocked,
      locked: service.locked,
      armable: service.armable,
      sleepSeconds: service.sleepSeconds,
      dryRun: service.dryRun,
      suspendTimerRunning: service._debugSuspendTimerRunning,
      originSettleRunning: service._debugOriginSettleRunning,
      togglePath: service.togglePath,
      toggleEnabledPath: service.toggleEnabledPath,
      screensaverOff: service.screensaverOff,
      reconcileMidState: probeRoot.reconcileMidState,
      sleepNormChecks: probeRoot.sleepNormChecks,
      toolsRemovedFirstAttempt: probeRoot._toolsRemovedFirstAttempt,
      writeWatchdogFiredCount: service._writeWatchdogFiredCount
    }
    console.log("PROBE_RESULT " + JSON.stringify(summary))
    Qt.quit()
  }

  // Whole-probe-run backstop.
  Timer {
    interval: 22000
    running: true
    repeat: false
    onTriggered: probeRoot.finish("probe harness overall timeout (22s)")
  }
}
