import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
  id: root
  property string mode: Quickshell.env("SCOPED_SUSPEND_MODE") || "success"
  property var service: null
  property var checks: []
  property int phase: 0
  property bool done: false
  QtObject { id: rawIdle; property bool isIdle: true }
  QtObject {
    id: host
    property var barConfig: ({layout:{left:[{id:"halmylyseas.ristretto",sleepAfterIdleLock:1,dryRun:true}],center:[],right:[]}})
    function firstPartyServiceFor(id) { return null }
  }
  FileView { id: ownConfigWriter; path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"; preload: false; atomicWrites: true }
  function check(name, result) { checks = checks.concat([{name:name,pass:!!result}]) }
  function event(source, body) { console.log("omarchy " + source + " " + new Date().toISOString() + " " + body) }
  function trace() {
    event("idle", "lock-system: lock-timeout")
    event("idle", "process-start: lock omarchy-system-lock")
    event("lock", "lock-requested")
    event("idle", "process-exit: lock exitCode=0 status=0")
    event("lock", "secure=true")
  }
  function finish() {
    if (done) return
    done = true
    console.log("SCOPED_SUSPEND_RESULT " + JSON.stringify({mode:mode,checks:checks,
      failed:checks.filter(function(c) { return !c.pass }).length}))
    service.destroy()
    Qt.quit()
  }
  Timer {
    interval: 50
    repeat: true
    running: true
    onTriggered: {
      if (!service || !service.hostBridge) return
      if (phase === 0 && service.hostBridge.available && service.sleepSeconds === 1) {
        phase = 1
        drive.start()
      } else if (phase === 2 && service._debugSuspendTimerRunning) {
        check("scoped service arms countdown", !!service._countdownToken)
        check("scoped service uses dry run", service.dryRun)
        phase = 3
        if (mode === "success") settled.start()
      } else if (phase === 3 && mode !== "success" && service._preflightPending) {
        phase = 4
        if (mode === "delay-change") {
          ownConfigWriter.setText(JSON.stringify({version:1,bar:{layout:{left:[{id:"halmylyseas.ristretto",sleepAfterIdleLock:2,dryRun:true}]}}}))
        } else if (mode === "stay-awake") {
          event("idle", "stay-awake: enabled ipc")
        } else {
          event("lock", "session-locked=false")
          event("lock", "secure=false")
          event("lock", "unlocked")
          event("lock", "lock-requested")
          event("lock", "session-locked=true")
          event("lock", "secure=true")
        }
        cancelled.start()
      }
    }
  }
  Timer { id: drive; interval: 80; onTriggered: { phase = 2; trace() } }
  Timer {
    id: settled
    interval: 2300
    onTriggered: {
      check("countdown and preflight completed", !service._debugSuspendTimerRunning && !service._preflightPending)
      check("verified idle lock retained", service.locked && service.secureLocked && !!service._countdownToken)
      finish()
    }
  }
  Timer {
    id: cancelled
    interval: 1300
    onTriggered: {
      check("cancellation during preflight clears token", !service._countdownToken)
      check("cancelled countdown does not rearm", !service._debugSuspendTimerRunning && !service._preflightPending)
      finish()
    }
  }
  Timer {
    interval: 10000
    running: true
    onTriggered: {
      console.log("SCOPED_STATE " + JSON.stringify({phase:phase,scoped:service.scopedHost,
        bridgeActive:service.hostBridge ? service.hostBridge.active : false,
        available:service.hostBridge ? service.hostBridge.available : false,
        error:service.hostBridge ? service.hostBridge.lastError : "missing"}))
      check("timeout", false)
      finish()
    }
  }
  Component.onCompleted: {
    var component = Qt.createComponent("file://" + Quickshell.env("RISTRETTO_PLUGIN_DIR") + "/Service.qml")
    service = component.createObject(root, {shell:host,minSleepSeconds:1,originIdleSource:rawIdle,
      bridgeLogBackend:"qs", bridgeQsExecutable:Quickshell.env("SCOPED_SUSPEND_QS")})
  }
}
