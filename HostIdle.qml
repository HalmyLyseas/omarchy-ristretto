import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root
  property string qsExecutable: "qs"
  property string hostShellPath: Quickshell.env("OMARCHY_PATH") + "/shell"
  property string hostTarget: "idle"
  property int hostPid: 0
  property bool autoStart: false
  property int watchdogMs: 2000
  property int freshnessMs: 10000
  property int refreshMs: 0
  property int outputCapChars: 16384
  property bool active: true
  readonly property string hostState: _hostState
  readonly property bool loaded: _loaded
  readonly property bool current: _hostState === "current" && _loaded
  readonly property bool failed: _hostState === "failed"
  readonly property int screensaverSeconds: _screensaver
  readonly property int lockSeconds: _lock
  readonly property bool stayAwake: _stayAwake
  readonly property bool idleEnabled: _idleEnabled
  readonly property bool stayAwakeStateLoaded: _stayLoaded
  readonly property string lastError: _lastError
  readonly property bool writePending: _writePending
  property string _hostState: "loading"
  property bool _loaded: false
  property double _lastSuccessAt: 0
  property double _lastSuccessMono: 0
  property int _screensaver: 0
  property int _lock: 0
  property bool _stayAwake: false
  property bool _idleEnabled: false
  property bool _stayLoaded: false
  property string _lastError: ""
  property bool _writePending: false
  property bool _awaitingVerification: false
  property bool _expectedStayAwake: false
  property bool _active: false
  property bool _sawExit: false
  property bool _timedOut: false
  property int _armedPid: 0
  property int _generation: 0
  property int _armedGeneration: 0
  property string _operation: ""
  property bool _desiredStayAwake: false
  property string _out: ""
  property string _err: ""
  signal statusUpdated()
  signal writeFinished(bool success)

  function refresh() {
    if (!active || _active || proc.running) return false
    _generation++
    _arm("status", _generation)
    return true
  }
  function setStayAwake(desired) {
    if (!active) return false
    _desiredStayAwake = !!desired
    _writePending = true
    if (!_active) _startWrite()
    return true
  }
  function _startWrite() {
    if (!active || !_writePending || _active || proc.running) return
    _expectedStayAwake = _desiredStayAwake
    _generation++
    _arm(_expectedStayAwake ? "disable" : "enable", _generation)
  }
  function _arm(operation, generation) {
    _operation = operation; _armedGeneration = generation; _active = true
    _sawExit = false; _timedOut = false; _out = ""; _err = ""
    watchdog.interval = watchdogMs; watchdog.restart()
    // Instance selection and config selection are mutually exclusive.
    proc.command = hostPid > 0
      ? [qsExecutable, "ipc", "--pid", String(hostPid), "call", "--", hostTarget, operation]
      : [qsExecutable, "ipc", "-n", "-p", hostShellPath, "call", "--", hostTarget, operation]
    proc.running = true
  }
  function _append(line, stderr) {
    var key = stderr ? "_err" : "_out"
    var total = _out.length + _err.length
    var text = String(line || "") + "\n"
    if (total + text.length > outputCapChars) {
      text = text.slice(0, Math.max(0, outputCapChars - total))
      _timedOut = true
      if (proc.running) { proc.signal(15); killTimer.restart() }
    }
    root[key] += text
  }
  function _finish(exitCode, exitStatus, missing, generation) {
    if (!_active || generation !== _armedGeneration || generation !== _generation) return
    _active = false; watchdog.stop(); killTimer.stop()
    var operation = _operation
    var code = missing ? 127 : exitCode
    if (!missing && exitStatus === 1 && code === 0) code = 1
    var out = _out.trim(); var error = missing ? "qs binary missing" : (_timedOut ? "timed out" : _err.trim())
    _out = ""; _err = ""
    if (code !== 0 || _timedOut || (operation === "status" && !out)) {
      _hostState = "failed"; _loaded = false; _lastError = error || ("qs exit " + code)
      if (operation === "status") { if (_awaitingVerification) { _awaitingVerification = false; _writePending = false; writeFinished(false) }; statusUpdated() } else {
        var failedExpected = _expectedStayAwake
        _awaitingVerification = false; _writePending = false; writeFinished(false)
        if (active && _desiredStayAwake !== failedExpected) { _writePending = true; Qt.callLater(_startWrite) }
      }
      return
    }
    if (operation !== "status" && out !== (_expectedStayAwake ? "disabled" : "enabled")) {
      _hostState = "failed"; _loaded = false; _lastError = "unexpected idle write response"
          var mismatchExpected = _expectedStayAwake
          _awaitingVerification = false; _writePending = false; writeFinished(false)
          if (active && _desiredStayAwake !== mismatchExpected) { _writePending = true; Qt.callLater(_startWrite) }
          return
    }
    if (operation === "status") {
      var value
      try { value = JSON.parse(out) } catch (e) { value = null }
      if (!value || typeof value !== "object" || typeof value.enabled !== "boolean" || typeof value.screensaver !== "number"
          || typeof value.lock !== "number" || !isFinite(value.screensaver)
          || !isFinite(value.lock) || value.screensaver < 0 || value.lock < 0
          || value.screensaver > 2147483 || value.lock > 2147483
          || typeof value.stayAwake !== "boolean" || typeof value.stayAwakeStateLoaded !== "boolean") {
        _hostState = "failed"; _loaded = false; _lastError = "invalid idle status fields"; if (_awaitingVerification) { _awaitingVerification = false; _writePending = false; writeFinished(false) }; statusUpdated(); return
      }
      if (value.enabled !== (value.stayAwakeStateLoaded && !value.stayAwake)) {
        _hostState = "failed"; _loaded = false; _lastError = "inconsistent idle status fields"
        if (_awaitingVerification) { _awaitingVerification = false; _writePending = false; writeFinished(false) }
        statusUpdated(); return
      }
      _screensaver = Math.floor(value.screensaver); _lock = Math.floor(value.lock)
      _stayAwake = value.stayAwake; _stayLoaded = value.stayAwakeStateLoaded; _idleEnabled = value.enabled
      _loaded = value.stayAwakeStateLoaded; _hostState = _loaded ? "current" : "loading"
      if (_loaded) { _lastSuccessAt = Date.now(); _lastSuccessMono = monotonic.elapsedMs() }
      _lastError = ""
      if (_awaitingVerification) {
        _awaitingVerification = false
        var verifiedExpected = _expectedStayAwake
        if (!_loaded || _stayAwake !== verifiedExpected) {
          _hostState = "failed"; _loaded = false; _lastError = "idle write not applied"; _writePending = false; writeFinished(false)
          if (active && _desiredStayAwake !== verifiedExpected) { _writePending = true; Qt.callLater(_startWrite) }
        } else {
          _writePending = false; writeFinished(true)
          if (active && _desiredStayAwake !== verifiedExpected) { _writePending = true; Qt.callLater(_startWrite) }
        }
      } else if (_writePending) Qt.callLater(_startWrite)
      statusUpdated(); return
    }
    _awaitingVerification = true; _hostState = "loading"
    var verifyGeneration = _generation
    Qt.callLater(function() {
      if (active && !_active && verifyGeneration === _generation && _awaitingVerification) {
        _generation++; _arm("status", _generation)
      }
    })
  }
  function _deactivate() {
    _generation++; _active = false; _writePending = false; _awaitingVerification = false
    watchdog.stop()
    _loaded = false; _hostState = "loading"; _lastError = "idle adapter inactive"
    if (proc.running) { proc.signal(15); killTimer.restart() }
  }
  onActiveChanged: if (!active) _deactivate(); else if (autoStart) refresh()
  ElapsedTimer { id: monotonic }
  Timer { id: freshness; interval: 250; repeat: true; running: root.active; onTriggered: if (_loaded && monotonic.elapsedMs() - _lastSuccessMono > freshnessMs) { _loaded = false; _hostState = "failed"; _lastError = "idle status expired"; statusUpdated() } }
  Timer { id: periodic; interval: root.refreshMs; repeat: true; running: root.active && root.refreshMs > 0; onTriggered: root.refresh() }
  Timer { id: watchdog; repeat: false; onTriggered: { if (!_active) return; _timedOut = true; if (proc.running) proc.signal(15); killTimer.restart() } }
  Timer { id: killTimer; interval: 1000; repeat: false; onTriggered: if (proc.running && proc.processId === _armedPid) proc.signal(9) }
  Process {
    id: proc
    onStarted: _armedPid = processId
    onRunningChanged: if (!running && _active && !_sawExit) {
      var generation = _armedGeneration
      Qt.callLater(function() { if (_active && !_sawExit && generation === _armedGeneration) _finish(127, 0, true, generation) })
    }
    stdout: SplitParser { onRead: function(line) { root._append(line, false) } }
    stderr: SplitParser { onRead: function(line) { root._append(line, true) } }
    onExited: function(exitCode, exitStatus) {
      var generation = _armedGeneration
      _sawExit = true
      if (generation === _generation) _finish(exitCode, exitStatus, false, generation)
      else {
        killTimer.stop()
        if (root.active && root.autoStart) Qt.callLater(root.refresh)
      }
    }
  }
  Component.onCompleted: if (autoStart) refresh()
}
