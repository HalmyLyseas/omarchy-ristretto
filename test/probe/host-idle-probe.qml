import QtQuick
import Quickshell

ShellRoot {
  id: root
  property string pluginDir: Quickshell.env("RISTRETTO_PLUGIN_DIR")
  property string mockMode: Quickshell.env("HOST_IDLE_MOCK_MODE") || "ok"
  property var checks: []
  property var writes: []
  property bool done: false
  property string phase: "initial"
  property bool queued: false

  function check(name, value) { root.checks = root.checks.concat([{name: name, pass: !!value}]) }
  function finish() {
    if (root.done) return
    root.done = true
    var failed = 0
    for (var i = 0; i < root.checks.length; i++) if (!root.checks[i].pass) failed++
    print("HOST_IDLE_RESULT " + JSON.stringify({checks: root.checks, failed: failed, mode: root.mockMode}))
    Qt.quit()
  }
  Loader {
    id: loader
    source: "file://" + root.pluginDir + "/HostIdle.qml"
    onLoaded: {
      item.qsExecutable = Quickshell.env("HOST_IDLE_QS")
      item.hostShellPath = "mock-shell"
      item.watchdogMs = 300
      item.freshnessMs = root.mockMode === "expiry" ? 100 : 5000
      item.hostPid = Number(Quickshell.env("HOST_IDLE_HOST_PID") || 0)
      if (root.mockMode === "deactivate") {
        item.active = false
        item.autoStart = true
        item.active = true
      }
      item.statusUpdated.connect(function() {
        if (item.failed) {
          if (root.mockMode === "expiry") root.check("freshness expires", !item.loaded)
          else root.check("status failed", ["fail", "verify-fail", "verify-json", "verify-unloaded", "wrong-state", "inconsistent", "missing-exec", "hang", "flood"].indexOf(root.mockMode) >= 0)
          root.finish(); return
        }
        if (root.mockMode === "expiry") return
        if (root.mockMode === "deactivate") {
          item.active = false
          root.check("inactive rejects writes", !item.setStayAwake(true))
          root.finish(); return
        }
        if (root.mockMode === "unloaded" && !item.stayAwakeStateLoaded) {
          root.check("unloaded state", !item.current && !item.loaded)
          Qt.callLater(item.refresh)
          return
        }
        if (root.phase !== "initial") return
        root.phase = "write"
        root.check("status current", item.current && item.loaded)
        root.check("effective screensaver", item.screensaverSeconds === 60)
        root.check("effective lock", item.lockSeconds === 180)
        root.check("stay awake loaded", item.stayAwakeStateLoaded === true)
        root.check("effective enabled", item.idleEnabled === (item.loaded && !item.stayAwake))
        if (!root.queued) item.setStayAwake(true)
      })
      item.writeFinished.connect(function(success) {
        root.writes = root.writes.concat([success])
        var shouldFail = root.mockMode === "fail" || root.mockMode === "verify-fail" || root.mockMode === "verify-json" || root.mockMode === "verify-unloaded" || root.mockMode === "wrong-state"
        root.check("write success", shouldFail ? !success : success)
        if (!success && root.mockMode === "fail") {
          root.check("failed write clears pending", !item.writePending)
          return
        }
        if (!success && (root.mockMode === "verify-fail" || root.mockMode === "verify-json" || root.mockMode === "verify-unloaded" || root.mockMode === "wrong-state")) {
          root.check("verification failure clears pending", !item.writePending)
          root.finish(); return
        }
        if (root.writes.length === 1) {
          root.check("write completed before callback", item.current && !item.writePending)
          if (root.mockMode === "reentrant") {
            item.setStayAwake(false)
          } else item.setStayAwake(false)
        } else root.finish()
      })
      item.refresh()
    }
  }
  Timer {
    interval: root.mockMode === "expiry" ? 700 : 60
    running: true
    onTriggered: {
      if (root.mockMode === "delayed-status" && !root.queued) {
        root.queued = true
        loader.item.setStayAwake(true)
      }
    }
  }
  Timer { interval: 350; running: true; onTriggered: if (!root.done && root.mockMode === "fail") root.finish() }
  Timer { interval: 5000; running: true; onTriggered: { root.check("probe timeout", false); root.finish() } }
}
