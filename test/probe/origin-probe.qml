import QtQuick
import Quickshell

ShellRoot {
  id: root
  property string scenario: Quickshell.env("ORIGIN_SCENARIO") || "flow"
  property var checks: []
  property var seen: []
  property bool done: false
  property bool drove: false
  property int callbacks: 0
  property int invalidations: 0
  property int originalGeneration: 0
  property int firstPid: 0
  property int readyCount: 0

  QtObject { id: rawIdleStub; property bool isIdle: false }
  QtObject { id: replacementIdleStub; property bool isIdle: false }
  function check(name, result) { checks = checks.concat([{name:name, pass:!!result}]) }
  function finish() {
    if (done) return
    done = true
    var failures = checks.filter(function(c) { return !c.pass }).length
    console.log("ORIGIN_RESULT " + JSON.stringify({checks:checks, failures:failures, childPid:firstPid, scenario:scenario}))
    loader.active = false
    Qt.quit()
  }
  function hostEvent(body) {
    var text = "omarchy idle " + new Date().toISOString() + " " + body
    console.log(Quickshell.env("ORIGIN_LOG_BACKEND") === "journal" ? "\x1b[34m" + text + "\x1b[0m" : text)
  }
  function driveFlow() {
    var transport = loader.item
    check("initial raw state recorded", transport.rawHistory.length === 1 && transport.rawHistory[0].idle === false)
    check("replay discarded", seen.length === 0)
    rawIdleStub.isIdle = true
    check("raw transition synchronous", transport.rawHistory.length === 2 && transport.rawHistory[1].idle === true)
    hostEvent("lock-system: lock-timeout")
    transport.requestBarrier(function(ok) {
      callbacks += 1
      check("first barrier catches earlier event", ok && seen.length >= 1)
    })
    hostEvent("process-start: lock omarchy-system-lock")
    transport.requestBarrier(function(ok) {
      callbacks += 1
      check("later barrier covers later event", ok && seen.length === 2)
      check("FIFO callback count", callbacks === 2)
      rawIdleStub.isIdle = false
      check("raw reset recorded", transport.rawHistory[2].idle === false)
      stableTimer.start()
    })
  }
  function ready() {
    var transport = loader.item
    if (!transport || !transport.available || done) return
    readyCount += 1
    if (drove) {
      if (scenario === "reconnect") {
        check("new generation after reconnect", transport.transportGeneration > originalGeneration)
        check("replay rejected after reconnect", seen.length === 0)
        check("reconnect cancelled callback once", callbacks === 1)
        finish()
      }
      return
    }
    drove = true
    firstPid = transport.childPid
    originalGeneration = transport.transportGeneration
    if (scenario === "flow") driveTimer.start()
    else if (scenario === "reconnect") {
      hostEvent("lock-system: stale-before-reconnect")
      transport.requestBarrier(function(ok) { callbacks += 1; check("reconnect callback cancelled", !ok) })
      transport.fail("synthetic connection failure")
    } else if (scenario === "clock") {
      var beforeClock = invalidations
      var pidBeforeClock = transport.childPid
      transport._lastWall = Date.now() - 100000
      rawIdleStub.isIdle = true
      check("clock step invalidates evidence", invalidations > beforeClock)
      check("clock step keeps transport available", transport.available)
      check("clock step rebases history", transport.rawHistory.length === 1 && transport.rawHistory[0].idle === true)
      check("clock step keeps the reader", transport.childPid === pidBeforeClock)
      transport.active = false
      cleanupTimer.start()
    } else if (scenario === "source") {
      var before = invalidations
      transport.originIdleSource = replacementIdleStub
      check("source replacement invalidates", invalidations > before)
      transport.active = false
      cleanupTimer.start()
    } else if (scenario === "disable") {
      transport.requestBarrier(function(ok) { check("pending barrier fails on disable", !ok); callbacks += 1 })
      transport.active = false
      check("unavailable synchronously after disable", !transport.available)
      cleanupTimer.start()
    } else if (scenario === "overflow") {
      transport.consume(new Array(transport.lineCap + 2).join("x"), false)
      check("overflow invalidates", !transport.available && transport.lastError === "log line limit")
      transport.active = false
      cleanupTimer.start()
    }
  }
  Loader {
    id: loader
    active: false
    onLoaded: {
      item.availableChanged.connect(function() { Qt.callLater(root.ready) })
      item.receivedHostLine.connect(function(line) { root.seen = root.seen.concat([line]) })
      item.invalidated.connect(function(reason) {
        root.invalidations += 1
        if ((scenario === "timeout" || scenario === "missing") && !root.drove) {
          root.drove = true
          root.firstPid = item.childPid
          check("failed transport remains unavailable", !item.available)
          check("failure has reason", reason.length > 0)
          item.active = false
          cleanupTimer.start()
        }
      })
      item.active = true
    }
  }
  Timer { id: driveTimer; interval: 30; onTriggered: root.driveFlow() }
  Timer {
    id: stableTimer
    interval: 500
    onTriggered: {
      check("heartbeats preserve availability", loader.item.available)
      check("completed markers do not time out", invalidations === 0)
      loader.item.active = false
      cleanupTimer.start()
    }
  }
  Timer {
    id: cleanupTimer
    interval: 1200
    onTriggered: {
      check("child stopped after disable", loader.item.childPid === 0)
      if (scenario === "disable") check("one failed callback", callbacks === 1)
      finish()
    }
  }
  Timer {
    interval: 7000
    running: true
    onTriggered: { check("probe timeout", false); finish() }
  }
  Component.onCompleted: {
    hostEvent("lock-system: replay-must-be-ignored")
    loader.setSource(Quickshell.env("RISTRETTO_PLUGIN_DIR") + "/HostOrigin.qml", {
      logBackend: Quickshell.env("ORIGIN_LOG_BACKEND") || "qs",
      originIdleSource:rawIdleStub, barrierTimeoutMs: Quickshell.env("ORIGIN_LOG_BACKEND") === "journal" ? 3000 : 300, heartbeatMs:100,
      reconnectMs:100, maxReconnectMs:200,
      qsExecutable: scenario === "missing" ? "/nonexistent/ristretto-qs" :
        (scenario === "timeout" ? Quickshell.env("RISTRETTO_PLUGIN_DIR") + "/test/mocks/origin-stall" : "/usr/bin/qs")
    })
    loader.active = true
  }
}
