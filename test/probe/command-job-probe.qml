import QtQuick
import Quickshell

ShellRoot {
  id: root
  property string mode: Quickshell.env("COMMAND_JOB_MODE") || "success"
  property string pluginDir: Quickshell.env("RISTRETTO_PLUGIN_DIR")
  property var checks: []
  property int phase: 0
  property bool done: false
  property string executable: Quickshell.env("COMMAND_JOB_EXECUTABLE")

  function check(name, value) { root.checks = root.checks.concat([{name: name, pass: !!value}]) }
  function finish() {
    if (root.done) return
    root.done = true
    var failed = 0
    for (var i = 0; i < root.checks.length; i++) if (!root.checks[i].pass) failed++
    print("COMMAND_JOB_RESULT " + JSON.stringify({mode: root.mode, failed: failed, checks: root.checks}))
    Qt.quit()
  }
  function start(argv) { phase++; return loader.item.run(argv) }

  Loader {
    id: loader
    source: "file://" + root.pluginDir + "/CommandJob.qml"
    onLoaded: {
      item.timeoutMs = root.mode === "timeout" ? 100 : 1000
      item.maxChars = root.mode === "flood" ? 100 : 4096
      item.finished.connect(function(success, output, error) {
        if (root.mode === "reentrant" && root.phase === 1) {
          root.check("first succeeds", success && output === "plain-result")
          root.check("second run accepted", root.start([root.executable]))
          return
        }
        if (root.mode === "success" || root.mode === "malformed") {
          root.check("success", success)
          root.check("raw output preserved", output === (root.mode === "malformed" ? "{not-json}" : "plain-result"))
          root.check("no error", error === "")
        } else if (root.mode === "fail") {
          root.check("failure", !success && error === "failure-detail")
        } else if (root.mode === "missing") {
          root.check("missing fails", !success && error.length > 0)
        } else if (root.mode === "timeout") {
          root.check("timeout fails", !success && error === "command timed out")
          root.check("not busy", !item.busy)
        } else if (root.mode === "flood") {
          root.check("output cap fails", !success && error === "command output limit")
        } else if (root.mode === "stop") {
          root.check("stop fails", !success && error === "test cancellation")
        } else if (root.mode === "reentrant") {
          root.check("second succeeds", success && output === "plain-result")
        }
        root.finish()
      })
      if (root.mode === "stop") {
        root.start([root.executable])
        cancelTimer.start()
      } else if (root.mode === "missing") root.start(["/definitely/missing/command-job"])
      else root.start([root.executable])
    }
  }
  Timer { id: cancelTimer; interval: 50; onTriggered: loader.item.stop("test cancellation") }
  Timer { interval: 5000; running: true; onTriggered: { root.check("probe timeout", false); root.finish() } }
}
