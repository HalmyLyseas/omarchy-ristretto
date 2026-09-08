import QtQuick
import Quickshell

ShellRoot {
  id: root
  property string mode: Quickshell.env("HOST_BRIDGE_MODE") || "eligible"
  property var checks: []
  property var bridge: null
  property string candidate: ""
  property bool done: false
  property int phase: 0
  property bool preflightResult: false
  property int callbackCount: 0
  QtObject { id: rawIdle; property bool isIdle: true }

  function check(name, value) { checks = checks.concat([{name:name, pass:!!value}]) }
  function event(source, body, stamp) {
    console.log("omarchy " + source + " " + new Date(stamp || Date.now()).toISOString() + " " + body)
  }
  function trace(stamp) {
    event("idle", "lock-system: lock-timeout", stamp)
    event("idle", "process-start: lock omarchy-system-lock")
    event("lock", "lock-requested")
    if (mode === "omitted-lock-state") event("idle", "process-exit: lock exitCode=0 status=0")
    if (mode !== "omitted-lock-state") event("lock", "session-locked=true")
    event("lock", "secure=true")
  }
  function finish() {
    if (done) return
    done = true
    var failed = checks.filter(function(c) { return !c.pass }).length
    console.log("HOST_BRIDGE_RESULT " + JSON.stringify({mode:mode, checks:checks, failed:failed}))
    loader.active = false
    Qt.quit()
  }
  Loader {
    id: loader
    active: false
    onLoaded: {
      root.bridge = item
      item.delayWriteFinished.connect(function(ok) {
        check("writer verified by effective host state", ok && bridge.idle.lockSeconds === 600 && bridge.idle.screensaverSeconds === 150)
        check("writer pending clears", !bridge.writePending)
        finish()
      })
      item.active = true
    }
  }
  Timer {
    interval: 50
    running: true
    repeat: true
    onTriggered: {
      if (!bridge || !bridge.available || phase !== 0) return
      phase = 1
      drive.start()
    }
  }
  Timer {
    id: drive
    interval: 80
    onTriggered: {
      check("own-process observer ready", bridge.available)
      if (mode === "writer") {
        check("writer starts from current host state", bridge.writeDelay("lock", 600))
        check("pending write rejects duplicate", !bridge.writeDelay("lock", 300))
      } else if (mode === "manual") {
        event("lock", "lock-requested")
        event("lock", "session-locked=true")
        event("lock", "secure=true")
        rejectCheck.start()
      } else if (mode === "activity") {
        rawIdle.isIdle = false
        activityTrace.start()
      } else if (mode === "ambiguous") {
        rawIdle.isIdle = false
        rawIdle.isIdle = true
        var history = bridge.state.history
        trace(history[history.length - 1].wallMs)
        rejectCheck.start()
      } else {
        trace()
        tokenWait.start()
      }
    }
  }
  Timer { id: activityTrace; interval: 50; onTriggered: { root.trace(); rejectCheck.start() } }
  Timer {
    id: rejectCheck
    interval: 400
    onTriggered: {
      check("manual or active origin rejected", !bridge.eligible && !bridge.token)
      finish()
    }
  }
  Timer {
    id: tokenWait
    interval: 20
    repeat: true
    onTriggered: {
      if (!bridge.eligible) return
      stop()
      candidate = bridge.token
      check("secure idle token from real log stream", !!candidate && bridge.locked && bridge.secure)
      bridge.preflight(candidate, function(ok) {
        callbackCount += 1
        preflightResult = ok
        if (mode === "unlock-pending") {
          check("intervening unlock rejects saved token", !ok)
          replacedCheck.start()
        } else {
          check("fresh two-barrier preflight succeeds", ok)
          check("single preflight callback", callbackCount === 1)
          finish()
        }
      })
      if (mode === "unlock-pending") unlockTimer.start()
    }
  }
  Timer {
    id: unlockTimer
    interval: 200
    onTriggered: {
      event("lock", "session-locked=false")
      event("lock", "secure=false")
      event("lock", "unlocked")
      trace()
    }
  }
  Timer {
    id: replacedCheck
    interval: 400
    onTriggered: {
      check("replacement lock gets distinct token", bridge.eligible && bridge.token !== candidate)
      check("old preflight never succeeds", !preflightResult && callbackCount === 1)
      finish()
    }
  }
  Timer { interval: 10000; running: true; onTriggered: { check("timeout", false); finish() } }
  Component.onCompleted: {
    loader.setSource("file://" + Quickshell.env("RISTRETTO_PLUGIN_DIR") + "/HostBridge.qml", {
      logBackend:"qs", qsExecutable:Quickshell.env("HOST_BRIDGE_QS"), originIdleSource:rawIdle,
      hostPid:Quickshell.processId, hostInstance:Quickshell.instanceId,
      configPath:Quickshell.env("HOST_BRIDGE_CONFIG")
    })
    loader.active = true
  }
}
