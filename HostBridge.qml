import QtQuick
import Quickshell
import "OriginModel.js" as Origin

Item {
  id: root
  property bool active: false
  property var originIdleSource: null
  property string qsExecutable: "/usr/bin/qs"
  property int hostPid: Quickshell.processId
  property string hostInstance: Quickshell.instanceId
  property string configPath: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
  property string writerPath: decodeURIComponent(Qt.resolvedUrl("tools/update-idle.py").toString().replace(/^file:\/\//, ""))
  readonly property var idle: idleReader
  readonly property bool available: active && origin.available && idleReader.current
  readonly property bool eligible: available && Origin.isEligible(state)
  readonly property string token: eligible ? state.token : ""
  readonly property bool locked: state.locked === true
  readonly property bool secure: state.secure === true
  readonly property bool writePending: writer.busy || verification.running
  readonly property string lastError: _lastError || idleReader.lastError || origin.lastError
  readonly property string delayError: _lastError
  property var state: Origin.createState()
  property string _lastError: ""
  property var _expectedPair: null
  property var _preflightCallback: null
  property string _preflightToken: ""
  property int _preflightGeneration: 0
  property int _preflightSerial: 0
  signal cancelled(string reason)
  signal delayWriteFinished(bool success)

  function reset(reason) {
    root.state = Origin.createState(root.state.generation + 1, root.state.nextSequence)
    root.cancelled(reason)
    root.finishPreflight(false)
  }
  function ingest(line) {
    var event = Origin.parseHostLine(line)
    if (!event) return
    var prior = root.state.token
    event.generation = root.state.generation
    root.state = Origin.applyEvent(root.state, event, { nowWallMs: Date.now(), freshnessMs: 3000 })
    if (prior && prior !== root.state.token) root.cancelled(root.state.invalidReason)
  }
  function recordIdleSample(sample) {
    root.state = Origin.recordIdle(root.state, sample)
  }
  function matchesToken() {
    return root.active && origin.available && root.state.token === root._preflightToken
      && Origin.isEligible(root.state) && origin.transportGeneration === root._preflightGeneration
  }
  function finishPreflight(success) {
    var callback = root._preflightCallback
    root._preflightCallback = null
    root._preflightToken = ""
    root._preflightSerial += 1
    preflightDeadline.stop()
    if (callback) callback(success)
  }
  function preflight(candidate, callback) {
    if (root._preflightCallback || idleCheck.busy || lockCheck.busy || !candidate || candidate !== root.token) {
      callback(false)
      return false
    }
    root._preflightCallback = callback
    root._preflightToken = candidate
    root._preflightGeneration = origin.transportGeneration
    var serial = ++root._preflightSerial
    preflightDeadline.restart()
    origin.requestBarrier(function(ok) {
      if (serial !== root._preflightSerial) return
      if (!ok || !root.matchesToken()) { root.finishPreflight(false); return }
      if (!idleCheck.run(root.statusCommand("idle"))) root.finishPreflight(false)
    })
    return true
  }
  function statusCommand(target) {
    return [root.qsExecutable, "ipc", "--pid", String(root.hostPid), "call", "--", target, "status"]
  }
  function parseStatus(output) {
    try {
      var value = JSON.parse(output)
      return value && typeof value === "object" && !Array.isArray(value) ? value : null
    } catch (e) { return null }
  }
  function writeDelay(kind, seconds) {
    if (!root.active || !idleReader.current || root.writePending) return false
    if (kind !== "screensaver" && kind !== "lock") return false
    root._lastError = ""
    root.cancelled("idle delay change")
    root.state = Origin.createState(root.state.generation + 1, root.state.nextSequence)
    return writer.run(["/usr/bin/python3", root.writerPath, "--config", root.configPath,
      "--kind", kind, "--seconds", String(seconds)])
  }
  function verifyDelay() {
    if (!root._expectedPair) return
    if (idleReader.current && idleReader.screensaverSeconds === root._expectedPair.screensaver
        && idleReader.lockSeconds === root._expectedPair.lock) {
      root._expectedPair = null
      verification.stop()
      root.delayWriteFinished(true)
    }
  }
  onActiveChanged: if (!active) {
    root.reset("host detached")
    writer.stop("host detached")
    idleCheck.stop("host detached")
    lockCheck.stop("host detached")
    verification.stop()
    root._expectedPair = null
  }
  onAvailableChanged: if (!available) root.cancelled("host observation unavailable")

  HostIdle {
    id: idleReader
    active: root.active
    qsExecutable: root.qsExecutable
    hostPid: root.hostPid
    autoStart: root.active
    refreshMs: root.active ? 2000 : 0
    onStatusUpdated: {
      root.verifyDelay()
      if (!current || stayAwake) root.reset("idle disabled or unavailable")
    }
  }
  HostOrigin {
    id: origin
    active: root.active
    originIdleSource: root.originIdleSource
    hostPid: root.hostPid
    hostInstance: root.hostInstance
    qsExecutable: root.qsExecutable
    onTransportGenerationChanged: root.state = Origin.applyEvent(Origin.createState(0, root.state.nextSequence), {
      type: "generation", generation: transportGeneration })
    onRawIdleSample: function(sample) { root.recordIdleSample(sample) }
    onReceivedHostLine: function(line) { root.ingest(line) }
    onInvalidated: function(reason) { root.reset(reason) }
  }
  CommandJob {
    id: idleCheck
    onFinished: function(success, output, error) {
      if (!root._preflightCallback) return
      var status = success ? root.parseStatus(output) : null
      if (!root.matchesToken() || !status || status.stayAwakeStateLoaded !== true
          || status.stayAwake !== false || status.enabled !== true) {
        root.finishPreflight(false); return
      }
      if (!lockCheck.run(root.statusCommand("lock"))) root.finishPreflight(false)
    }
  }
  CommandJob {
    id: lockCheck
    onFinished: function(success, output, error) {
      if (!root._preflightCallback) return
      var status = success ? root.parseStatus(output) : null
      if (!root.matchesToken() || !status || status.locked !== true || status.secure !== true
          || status.sessionLocked !== true || status.pending !== false) {
        root.finishPreflight(false); return
      }
      var serial = root._preflightSerial
      origin.requestBarrier(function(ok) {
        if (serial !== root._preflightSerial) return
        root.finishPreflight(ok && root.matchesToken())
      })
    }
  }
  CommandJob {
    id: writer
    onFinished: function(success, output, error) {
      if (!root.active) return
      var pair = success ? root.parseStatus(output) : null
      if (!pair || typeof pair.screensaver !== "number" || typeof pair.lock !== "number"
          || !isFinite(pair.screensaver) || !isFinite(pair.lock)
          || pair.screensaver < 0 || pair.lock < 0) {
        root._lastError = error || "idle delay update failed"
        root.delayWriteFinished(false)
        return
      }
      root._expectedPair = pair
      verification.restart()
      idleReader.refresh()
    }
  }
  Timer {
    id: verification
    interval: 6000
    onTriggered: {
      root._expectedPair = null
      root._lastError = "idle delay update was not observed by host"
      root.delayWriteFinished(false)
    }
  }
  Timer { id: preflightDeadline; interval: 10000; onTriggered: root.finishPreflight(false) }
}
