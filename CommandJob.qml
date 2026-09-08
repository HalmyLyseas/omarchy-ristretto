import QtQuick
import Quickshell.Io

Item {
  id: root
  property int timeoutMs: 2500
  property int maxChars: 16384
  readonly property bool busy: root._busy
  readonly property int childPid: root._pid
  signal finished(bool success, string output, string error)

  property bool _busy: false
  property bool _failed: false
  property int _serial: 0
  property int _doneSerial: -1
  property int _pid: 0
  property string _stdout: ""
  property string _stderr: ""
  property string _failure: ""

  function run(argv) {
    if (root._busy || child.running || !Array.isArray(argv) || !argv.length) return false
    root._serial += 1
    root._busy = true
    root._failed = false
    root._failure = ""
    root._stdout = ""
    root._stderr = ""
    root._pid = 0
    deadline.interval = root.timeoutMs
    deadline.restart()
    child.command = argv
    child.running = true
    return true
  }

  function stop(reason) {
    if (!root._busy || root._failed) return
    root._failed = true
    root._failure = reason || "cancelled"
    if (child.running) {
      child.signal(15)
      killDeadline.restart()
    } else root.complete(root._serial, false)
  }

  function append(line, errorStream) {
    if (!root._busy || root._failed) return
    var text = String(line || "") + "\n"
    var room = root.maxChars - root._stdout.length - root._stderr.length
    if (text.length > room) {
      root.stop("command output limit")
      return
    }
    if (errorStream) root._stderr += text
    else root._stdout += text
  }

  function complete(serial, success) {
    if (!root._busy || serial !== root._serial || serial === root._doneSerial) return
    root._doneSerial = serial
    deadline.stop()
    killDeadline.stop()
    var output = root._stdout.trim()
    var error = root._failure || root._stderr.trim()
    var ok = success && !root._failed
    root._busy = false
    root._pid = 0
    root._stdout = ""
    root._stderr = ""
    if (!ok && !error) error = "command failed"
    root.finished(ok, output, error)
  }

  Timer { id: deadline; repeat: false; onTriggered: root.stop("command timed out") }
  Timer {
    id: killDeadline
    interval: 1000
    repeat: false
    onTriggered: if (child.running && child.processId === root._pid) child.signal(9)
  }
  Process {
    id: child
    running: false
    onStarted: root._pid = processId
    onRunningChanged: if (!running) {
      var serial = root._serial
      Qt.callLater(function() { if (!child.running) root.complete(serial, false) })
    }
    onExited: function(code, status) { root.complete(root._serial, code === 0 && status === 0) }
    stdout: SplitParser { onRead: function(line) { root.append(line, false) } }
    stderr: SplitParser { onRead: function(line) { root.append(line, true) } }
  }
}
