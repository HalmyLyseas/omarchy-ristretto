import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property bool active: false
  property var originIdleSource: null
  property string qsExecutable: "/usr/bin/qs"
  property int hostPid: Quickshell.processId
  property string hostInstance: Quickshell.instanceId
  property int barrierTimeoutMs: 3000
  property int heartbeatMs: 1000
  property int reconnectMs: 500
  property int maxReconnectMs: 10000
  property int lineCap: 4096
  property int windowCap: 131072
  property int replayCap: 8388608
  property int clockToleranceMs: 100

  readonly property bool available: root.active && root._ready && root._started && !root._stopping
  readonly property int transportGeneration: root._generation
  readonly property var rawHistory: root._history
  readonly property string lastError: root._lastError
  readonly property int childPid: root._armedPid
  signal receivedHostLine(string line)
  signal rawIdleSample(var sample)
  signal invalidated(string reason)

  property bool _ready: false
  property bool _started: false
  property bool _launching: false
  property bool _stopping: false
  property bool _completed: false
  property int _generation: 0
  property int _launchSerial: 0
  property int _finishedSerial: -1
  property int _armedPid: 0
  property int _backoff: 500
  property string _lastError: ""
  property string _nonce: ""
  property int _markerSerial: 0
  property var _queue: []
  property var _history: []
  property double _lastWall: 0
  property double _lastMono: 0
  property double _windowAt: 0
  property int _windowBytes: 0
  property int _replayBytes: 0

  function clockSample() {
    var wall = Date.now()
    var mono = monotonic.elapsedMs()
    if (root._lastWall && Math.abs((wall - root._lastWall) - (mono - root._lastMono)) > root.clockToleranceMs) {
      root.fail("clock discontinuity")
      return null
    }
    root._lastWall = wall
    root._lastMono = mono
    return { wallMs: wall, monoMs: mono }
  }

  function noteIdle() {
    if (!root._started || root._stopping || !root.originIdleSource) return
    var sample = root.clockSample()
    if (!sample) return
    sample.idle = root.originIdleSource.isIdle === true
    sample.known = true
    root._history = root._history.concat([sample]).slice(-256)
    root.rawIdleSample(sample)
  }

  function requestBarrier(callback) {
    if (!root.active || !root._started || root._stopping) {
      if (callback) callback(false)
      return false
    }
    if (root._queue.length >= 16) {
      if (callback) callback(false)
      root.fail("marker queue overflow")
      return false
    }
    root._queue = root._queue.concat([{ callback: callback || null }])
    root.startMarker()
    return true
  }

  function startMarker() {
    if (root._nonce || !root._queue.length || root._stopping || !root._started) return
    if (!root.clockSample()) return
    root._markerSerial += 1
    root._nonce = root.hostInstance + ":" + root._launchSerial + ":" + root._markerSerial + ":" + Date.now()
    markerDeadline.interval = root.barrierTimeoutMs
    markerDeadline.restart()
    console.log("RISTRETTO_ORIGIN_MARKER " + root._nonce)
  }

  function finishMarker() {
    if (!root._nonce || !root._queue.length || root._stopping) return
    markerDeadline.stop()
    root._nonce = ""
    var entry = root._queue[0]
    root._queue = root._queue.slice(1)
    root._ready = true
    root._lastError = ""
    root._backoff = root.reconnectMs
    if (entry.callback) entry.callback(true)
    Qt.callLater(root.startMarker)
  }

  function flushCallbacks() {
    markerDeadline.stop()
    root._nonce = ""
    var pending = root._queue
    root._queue = []
    for (var i = 0; i < pending.length; i++)
      if (pending[i].callback) pending[i].callback(false)
  }

  function consume(line, errorStream) {
    if (!root._started || root._stopping) return
    var text = String(line || "")
    var now = monotonic.elapsedMs()
    if (text.length > root.lineCap) { root.fail("log line limit"); return }
    if (!root._ready) {
      root._replayBytes += text.length + 1
      if (root._replayBytes > root.replayCap) { root.fail("log replay limit"); return }
    } else {
      if (now - root._windowAt >= 1000) { root._windowAt = now; root._windowBytes = 0 }
      root._windowBytes += text.length + 1
      if (root._windowBytes > root.windowCap) { root.fail("log rate limit"); return }
    }
    if (errorStream) { root.fail("log reader error: " + text.slice(0, 160)); return }
    var marker = text.match(/^\s*(?:DEBUG|INFO) qml: RISTRETTO_ORIGIN_MARKER (\S+)$/)
    if (marker && marker[1] === root._nonce) {
      if (root.clockSample()) root.finishMarker()
      return
    }
    if (root._ready && /^\s*(?:DEBUG|INFO) qml: omarchy (?:idle|lock) /.test(text))
      root.receivedHostLine(text)
  }

  function invalidate(reason) {
    root._ready = false
    root._lastError = reason
    root._history = []
    root.invalidated(reason)
  }

  function fail(reason) {
    if (root._stopping) return
    root._stopping = true
    root.invalidate(reason)
    root.flushCallbacks()
    launchDeadline.stop()
    if (reader.running) {
      reader.signal(15)
      killDeadline.restart()
    } else {
      root.finishProcess(root._launchSerial)
    }
  }

  function finishProcess(serial) {
    if (serial !== root._launchSerial || root._finishedSerial === serial) return
    root._finishedSerial = serial
    launchDeadline.stop()
    killDeadline.stop()
    root._started = false
    root._launching = false
    root._stopping = true
    root._armedPid = 0
    root.invalidate(root._lastError || "log reader stopped")
    root.flushCallbacks()
    if (root.active) {
      reconnectTimer.interval = root._backoff
      root._backoff = Math.min(root.maxReconnectMs, Math.max(root.reconnectMs, root._backoff * 2))
      reconnectTimer.restart()
    }
  }

  function startReader() {
    if (!root.active || root._launching || root._started || reader.running) return
    reconnectTimer.stop()
    root._launchSerial += 1
    root._launching = true
    root._stopping = false
    root._ready = false
    root._replayBytes = 0
    root._windowBytes = 0
    root._lastWall = 0
    root._lastMono = 0
    root._history = []
    root._lastError = ""
    launchDeadline.interval = root.barrierTimeoutMs
    launchDeadline.restart()
    reader.command = [root.qsExecutable, "log", "--pid", String(root.hostPid), "--follow", "--no-color"]
    reader.running = true
  }

  function reconfigure() {
    if (!root._completed) return
    if (root._started || root._launching || reader.running) root.fail("host selection changed")
    else root.startReader()
  }

  onActiveChanged: {
    if (!root._completed) return
    if (root.active) root.startReader()
    else { reconnectTimer.stop(); root.fail("origin transport disabled") }
  }
  onHostPidChanged: root.reconfigure()
  onHostInstanceChanged: root.reconfigure()
  onQsExecutableChanged: root.reconfigure()
  onOriginIdleSourceChanged: {
    root._history = []
    if (root._started) { root.invalidated("raw idle source replaced"); root.noteIdle() }
  }

  Connections {
    target: root.originIdleSource
    function onIsIdleChanged() { root.noteIdle() }
  }
  ElapsedTimer { id: monotonic }
  Timer { id: markerDeadline; repeat: false; onTriggered: root.fail("log marker timeout") }
  Timer { id: launchDeadline; repeat: false; onTriggered: root.fail("log reader launch timeout") }
  Timer { id: reconnectTimer; repeat: false; onTriggered: root.startReader() }
  Timer {
    id: killDeadline
    interval: 1000
    repeat: false
    onTriggered: if (reader.running && reader.processId === root._armedPid) reader.signal(9)
  }
  Timer {
    interval: root.heartbeatMs
    repeat: true
    running: root.active
    onTriggered: if (root._started && !root._queue.length) root.requestBarrier(null)
  }
  Process {
    id: reader
    running: false
    onStarted: {
      launchDeadline.stop()
      root._armedPid = processId
      root._launching = false
      root._started = true
      root._generation += 1
      root.noteIdle()
      root.requestBarrier(null)
    }
    onRunningChanged: if (!running) {
      var serial = root._launchSerial
      Qt.callLater(function() { if (!reader.running) root.finishProcess(serial) })
    }
    onExited: function(exitCode, exitStatus) {
      if (!root._stopping) root._lastError = "log reader exit " + exitCode + "/" + exitStatus
      root.finishProcess(root._launchSerial)
    }
    stdout: SplitParser { onRead: function(line) { root.consume(line, false) } }
    stderr: SplitParser { onRead: function(line) { root.consume(line, true) } }
  }
  Component.onCompleted: { root._completed = true; if (root.active) root.startReader() }
}
