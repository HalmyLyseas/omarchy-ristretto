import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "Model.js" as Model

// Suspends the machine a chosen delay after an idle lock -- the shell is
// the only workable layer, since logind's IdleAction never fires with
// nothing publishing Wayland idle state to it. See docs/developers.md.
Item {
  id: root

  // Injected by omarchy-shell's service loader.
  property var shell: null

  readonly property var idleService: shell ? shell.firstPartyServiceFor("omarchy.idle") : null
  readonly property var lockService: shell ? shell.firstPartyServiceFor("omarchy.lock") : null

  readonly property bool locked: lockService ? lockService.locked === true : false
  // `locked` rises as soon as a lock is REQUESTED, before any secure lock
  // screen exists; with no real output the request can stay pending forever.
  // secureLocked is the one that actually means the screen is locked.
  readonly property bool secureLocked:
    locked && !(lockService && lockService.pendingSessionLock === true)
  readonly property string idleEvent: idleService ? String(idleService.lastEvent || "") : ""
  readonly property bool stayAwake: idleService ? idleService.stayAwake === true : false

  readonly property var shellConfig: shell ? shell.shellConfig : null

  // Production never assigns this; a probe lowers it to arm short countdowns
  // without waiting real minutes for the normal 60s floor.
  property int minSleepSeconds: 60

  readonly property var _sleepNormalized: Model.normalizeSleepSeconds(
    Model.settingFromConfig(shellConfig, "halmylyseas.ristretto", "sleepAfterIdleLock", Model.SLEEP_NEVER),
    root.minSleepSeconds)
  readonly property int sleepSeconds: _sleepNormalized.seconds
  readonly property bool dryRun: Model.normalizeDryRun(
    Model.settingFromConfig(shellConfig, "halmylyseas.ristretto", "dryRun", false))

  readonly property bool armable: sleepSeconds > 0

  // Debug-only, read by the probe harness -- production never reads these.
  readonly property bool _debugSuspendTimerRunning: suspendTimer.running
  readonly property bool _debugOriginSettleRunning: originSettle.running
  readonly property bool _debugLatchExpiryRunning: latchExpiry.running

  // True once an idle-driven lock is confirmed in flight, until the session
  // unlocks again -- this latch is the whole eligibility check for arming
  // suspend. See docs/developers.md ("A manual lock never leads to suspend").
  property bool idleLockPending: false
  property bool idleLockAnnounced: false

  onIdleEventChanged: {
    if (idleEvent.indexOf("lock-system") === 0) {
      root.idleLockAnnounced = true
      return
    }
    if (root.idleLockAnnounced) {
      root.idleLockAnnounced = false
      if (idleEvent.indexOf("process-start: lock") === 0) {
        root.idleLockPending = true
        latchExpiry.restart()
        log("idle lock spawn confirmed (" + idleEvent + ")")
      } else {
        log("idle lock announced but no spawn (" + idleEvent + ") -- not latching")
      }
      return
    }
    // The confirmed lock process ended and the session still is not locked:
    // that attempt failed, and a lock that lands later cannot be its result.
    if (idleEvent.indexOf("process-exit: lock") === 0
        && root.idleLockPending && !root.locked) {
      root.idleLockPending = false
      latchExpiry.stop()
      log("idle lock process exited without locking -- latch dropped")
    }
  }

  // Only the eligibility check happens here; arming waits for the secure
  // edge (onSecureLockedChanged below). Unlock is decided on `locked`
  // alone -- a never-secured lock still needs its latch and countdown cleared.
  onLockedChanged: {
    if (locked) {
      latchExpiry.stop()
      if (!root.idleLockPending) {
        log("locked, but not by idle -- not arming")
        return
      }
      if (!root.armable) {
        log("idle lock, but sleep delay is never -- not arming")
        return
      }
      if (root.secureLocked) {
        maybeArmForSecureLock()
      } else {
        log("lock requested but not secure -- waiting")
      }
    } else {
      // Log unconditionally: a clean unlock after the timer already fired left
      // no trace at all, so there was no way to confirm the latch cleared.
      log(suspendTimer.running || originSettle.running ? "unlocked -- countdown cancelled"
                                                        : "unlocked -- latch cleared")
      originSettle.stop()
      suspendTimer.stop()
      root.idleLockPending = false
    }
  }

  // The secure rising edge is the real arming trigger: a request with no
  // real screen leaves pendingSessionLock true forever and must never arm.
  // Calling this twice in one tick (if both edges land together) is harmless.
  onSecureLockedChanged: {
    if (secureLocked) maybeArmForSecureLock()
  }

  function maybeArmForSecureLock() {
    if (!root.secureLocked || !root.idleLockPending || !root.armable) return
    originSettle.restart()
    log("idle-eligible lock secured -- verifying origin")
  }

  // Origin check: recent raw input means the lock was not idle-driven, so
  // respectInhibitors is false (an inhibitor blocks idling, not hands).
  // Always enabled and fail-safe if the binding ever breaks -- see docs/developers.md.
  IdleMonitor {
    id: originMonitor
    enabled: true
    timeout: 30
    respectInhibitors: false
  }

  // Probe seam: scenario tests replace this with a stub, because real
  // compositor idle state cannot be scripted. Production never assigns it.
  property var originIdleSource: originMonitor

  // Judged a beat after the edge, not at it, since the resume event behind
  // a manual lock's own keypress can still be in flight when the lock
  // itself lands. Detail: docs/developers.md.
  Timer {
    id: originSettle
    interval: 1000
    repeat: false
    onTriggered: {
      if (root.stayAwake) {
        root.idleLockPending = false
        log("stay-awake enabled during origin settle -- not arming")
        return
      }
      if (!root.locked || !root.secureLocked || !root.idleLockPending) return
      if (!(root.originIdleSource && root.originIdleSource.isIdle === true)) {
        root.idleLockPending = false
        log("input seen at the lock edge -- treating as manual, not arming")
        return
      }
      if (!root.armable) {
        log("origin verified, but sleep delay is never -- not arming")
        return
      }
      // Interval is assigned here, not bound: a live binding on a running
      // Timer restarts the countdown on any config change, and "never"
      // (-1) would clamp into a one-second fuse instead of a cancellation.
      suspendTimer.interval = root.sleepSeconds * 1000
      suspendTimer.restart()
      log("armed: suspend in " + root.sleepSeconds + "s" + (root.dryRun ? " (dry run)" : ""))
    }
  }

  Timer {
    id: suspendTimer
    repeat: false
    onTriggered: root.suspend()
  }

  // Backstop for a spawn that dies silently: a real lock lands within a
  // second over IPC, so if none has after this window the attempt is dead
  // and a later manual lock must not inherit its latch.
  Timer {
    id: latchExpiry
    interval: 3000
    repeat: false
    onTriggered: {
      if (root.idleLockPending && !root.locked) {
        root.idleLockPending = false
        log("idle lock announced but nothing locked -- latch dropped")
      }
    }
  }

  // Re-check rather than trust the timer: the session may have been unlocked
  // (or lost its secure lock, or lost the latch) between the timer firing
  // and this running.
  function suspend() {
    if (!root.locked) {
      log("fired but no longer locked -- ignoring")
      return
    }
    if (!root.secureLocked) {
      log("fired but the lock is not secure -- ignoring")
      return
    }
    if (!root.idleLockPending) {
      log("fired but the idle latch is gone -- ignoring")
      return
    }
    if (root.stayAwake) {
      log("fired but stay-awake is on -- ignoring")
      return
    }
    if (!root.armable) {
      log("fired but sleep delay is never -- ignoring")
      return
    }
    if (root.dryRun) {
      log("DRY RUN -- would suspend now")
      // Critical, because this fires while the session is locked and blanked:
      // a low-urgency toast expires on its own timeout and is gone by the time
      // anyone unlocks to look for it.
      notifyProcess.command = ["omarchy-notification-send", "-u", "critical", "-g", "󰒲",
                               "Ristretto (dry run)", "would suspend now"]
      root._armProcess("notify")
      return
    }
    log("suspending")
    suspendProcess.command = ["systemctl", "suspend"]
    root._armProcess("suspend")
  }

  function log(message) {
    console.log("ristretto " + message)
  }

  readonly property string home: Quickshell.env("HOME")

  // Every external tool is a direct Quickshell Process child, never a bash
  // wrapper -- a wrapped grandchild is invisible to Quickshell's own
  // kill/orphan handling. `type -P` alone needs a login shell to rebuild PATH.

  // Plain, not readonly, so a probe can shorten them; production never does.
  property int toolTimeoutMs: 5000
  property int suspendTimeoutMs: 15000
  property int outputCapChars: 4096

  property string togglePath: ""
  property string toggleEnabledPath: ""

  property string _resolveToggleOut: ""
  property string _resolveToggleErr: ""
  property bool _resolveToggleOverflowed: false
  property bool _resolveToggleWatchdogFired: false
  property int _resolveToggleWatchdogFiredCount: 0
  property int _resolveToggleFailedStartCount: 0
  property int _resolveToggleArmedPid: 0
  property int _resolveToggleGen: 0
  property int _resolveToggleExitedGen: -1

  property string _resolveToggleEnabledOut: ""
  property string _resolveToggleEnabledErr: ""
  property bool _resolveToggleEnabledOverflowed: false
  property bool _resolveToggleEnabledWatchdogFired: false
  property int _resolveToggleEnabledWatchdogFiredCount: 0
  property int _resolveToggleEnabledFailedStartCount: 0
  property int _resolveToggleEnabledArmedPid: 0
  property int _resolveToggleEnabledGen: 0
  property int _resolveToggleEnabledExitedGen: -1

  property string _mkdirTogglesOut: ""
  property string _mkdirTogglesErr: ""
  property bool _mkdirTogglesOverflowed: false
  property bool _mkdirTogglesWatchdogFired: false
  property int _mkdirTogglesWatchdogFiredCount: 0
  property int _mkdirTogglesFailedStartCount: 0
  property int _mkdirTogglesArmedPid: 0
  property int _mkdirTogglesGen: 0
  property int _mkdirTogglesExitedGen: -1

  property string _writeOut: ""
  property string _writeErr: ""
  property bool _writeOverflowed: false
  property bool _writeWatchdogFired: false
  property int _writeWatchdogFiredCount: 0
  property int _writeFailedStartCount: 0
  property int _writeArmedPid: 0
  property int _writeGen: 0
  property int _writeExitedGen: -1

  property string _probeOut: ""
  property string _probeErr: ""
  property bool _probeOverflowed: false
  property bool _probeWatchdogFired: false
  property int _probeWatchdogFiredCount: 0
  property int _probeFailedStartCount: 0
  property int _probeArmedPid: 0
  property int _probeGen: 0
  property int _probeExitedGen: -1

  property string _suspendOut: ""
  property string _suspendErr: ""
  property bool _suspendOverflowed: false
  property bool _suspendWatchdogFired: false
  property int _suspendWatchdogFiredCount: 0
  property int _suspendFailedStartCount: 0
  property int _suspendArmedPid: 0
  property int _suspendGen: 0
  property int _suspendExitedGen: -1

  property string _notifyOut: ""
  property string _notifyErr: ""
  property bool _notifyOverflowed: false
  property bool _notifyWatchdogFired: false
  property int _notifyWatchdogFiredCount: 0
  property int _notifyFailedStartCount: 0
  property int _notifyArmedPid: 0
  property int _notifyGen: 0
  property int _notifyExitedGen: -1

  function _procForKind(kind) {
    if (kind === "resolveToggle") return resolveToggleProc
    if (kind === "resolveToggleEnabled") return resolveToggleEnabledProc
    if (kind === "mkdirToggles") return mkdirTogglesProc
    if (kind === "write") return screensaverWriter
    if (kind === "probe") return screensaverFlagProbe
    if (kind === "suspend") return suspendProcess
    return notifyProcess
  }

  function _watchdogFor(kind) {
    if (kind === "resolveToggle") return resolveToggleWatchdog
    if (kind === "resolveToggleEnabled") return resolveToggleEnabledWatchdog
    if (kind === "mkdirToggles") return mkdirTogglesWatchdog
    if (kind === "write") return writeWatchdog
    if (kind === "probe") return probeWatchdog
    if (kind === "suspend") return suspendWatchdog
    return notifyWatchdog
  }

  function _killTimerFor(kind) {
    if (kind === "resolveToggle") return resolveToggleKillTimer
    if (kind === "resolveToggleEnabled") return resolveToggleEnabledKillTimer
    if (kind === "mkdirToggles") return mkdirTogglesKillTimer
    if (kind === "write") return writeKillTimer
    if (kind === "probe") return probeKillTimer
    if (kind === "suspend") return suspendKillTimer
    return notifyKillTimer
  }

  function _timeoutMsFor(kind) {
    return kind === "suspend" ? root.suspendTimeoutMs : root.toolTimeoutMs
  }

  // Bounded to outputCapChars total (stdout+stderr collected only for
  // logging on failure, never parsed beyond the resolve kinds' first line).
  // A breach caps the buffer and SIGTERMs the child.
  function _appendBoundedOutput(kind, line, errorStream) {
    var overflowKey = "_" + kind + "Overflowed"
    if (root[overflowKey]) return
    var key = errorStream ? ("_" + kind + "Err") : ("_" + kind + "Out")
    var next = root[key] + String(line || "") + "\n"
    if (next.length > root.outputCapChars) {
      next = next.slice(0, root.outputCapChars)
      root[overflowKey] = true
    }
    root[key] = next
    if (root[overflowKey]) {
      var proc = root._procForKind(kind)
      if (proc && proc.running) proc.signal(15)
    }
  }

  function _armProcess(kind) {
    root["_" + kind + "Gen"] = root["_" + kind + "Gen"] + 1
    root["_" + kind + "Out"] = ""
    root["_" + kind + "Err"] = ""
    root["_" + kind + "Overflowed"] = false
    var wd = root._watchdogFor(kind)
    wd.interval = root._timeoutMsFor(kind)
    wd.restart()
    root._procForKind(kind).running = true
  }

  // Shared by every process's real onExited and its synthetic failed-start
  // path (a missing binary flips `running` false but never emits `exited`).
  // exitStatus === 1 (killed by signal) always folds into a nonzero exit.
  function _finalizeProcess(kind, exitCode, exitStatus, missingBinary) {
    root._watchdogFor(kind).stop()
    root._killTimerFor(kind).stop()
    var effExitCode, out, err
    if (missingBinary) {
      root["_" + kind + "FailedStartCount"] = root["_" + kind + "FailedStartCount"] + 1
      effExitCode = 127
      out = ""
      err = "binary missing"
    } else if (root["_" + kind + "WatchdogFired"]) {
      root["_" + kind + "WatchdogFired"] = false
      effExitCode = 124
      out = root["_" + kind + "Out"]
      err = "timed out"
    } else {
      out = root["_" + kind + "Out"]
      err = root["_" + kind + "Err"]
      effExitCode = (exitStatus === 1 && exitCode === 0) ? 1 : exitCode
    }
    root["_" + kind + "Out"] = ""
    root["_" + kind + "Err"] = ""
    root._dispatchExit(kind, effExitCode, out, err)
  }

  function _dispatchExit(kind, exitCode, out, err) {
    if (kind === "resolveToggle") { root.handleResolveToggleExit(exitCode, out, err); return }
    if (kind === "resolveToggleEnabled") { root.handleResolveToggleEnabledExit(exitCode, out, err); return }
    if (kind === "mkdirToggles") { root.handleMkdirTogglesExit(exitCode, err); return }
    if (kind === "write") { root.handleWriteExit(exitCode, err); return }
    if (kind === "probe") { root.handleProbeExit(exitCode, err); return }
    if (kind === "suspend") { root.handleSuspendExit(exitCode, err); return }
    root.handleNotifyExit(exitCode, err)
  }

  // ------------------------------------------------------- tool resolution

  function resolveToggle() {
    if (resolveToggleProc.running) return
    resolveToggleProc.command = ["bash", "-lc", "type -P omarchy-toggle"]
    root._armProcess("resolveToggle")
  }

  function resolveToggleEnabled() {
    if (resolveToggleEnabledProc.running) return
    resolveToggleEnabledProc.command = ["bash", "-lc", "type -P omarchy-toggle-enabled"]
    root._armProcess("resolveToggleEnabled")
  }

  function handleResolveToggleExit(exitCode, out, err) {
    if (exitCode === 0) {
      var resolved = String(out || "").split("\n")[0].replace(/^\s+|\s+$/g, "")
      if (resolved && resolved.charAt(0) === "/") {
        root.togglePath = resolved
        log("omarchy-toggle resolved at " + resolved)
        root.maybeWriteScreensaverFlag()
        return
      }
    }
    log("omarchy-toggle not found on PATH -- screensaver switch stays disabled-safe")
    toolRetryTimer.restart()
  }

  function handleResolveToggleEnabledExit(exitCode, out, err) {
    if (exitCode === 0) {
      var resolved = String(out || "").split("\n")[0].replace(/^\s+|\s+$/g, "")
      if (resolved && resolved.charAt(0) === "/") {
        root.toggleEnabledPath = resolved
        log("omarchy-toggle-enabled resolved at " + resolved)
        root.refreshScreensaverFlag()
        return
      }
    }
    log("omarchy-toggle-enabled not found on PATH -- screensaver flag unknown, defaulting off")
    toolRetryTimer.restart()
  }

  // One retry, 15s after the last resolution failure -- a session whose
  // compositor environment lacked the omarchy bin directory at startup may
  // still gain it shortly after.
  Timer {
    id: toolRetryTimer
    interval: 15000
    repeat: false
    onTriggered: {
      if (!root.togglePath) root.resolveToggle()
      if (!root.toggleEnabledPath) root.resolveToggleEnabled()
    }
  }

  function handleMkdirTogglesExit(exitCode, err) {
    if (exitCode !== 0) log("mkdir toggles dir failed (exit " + exitCode + ")")
    togglesWatch.reload()
  }

  // ------------------------------------------------------- the screensaver flag
  // No QML reader exists for this flag anywhere in Omarchy: this service
  // owns the one watcher (an exit-code probe, reloaded on directory change).

  property bool screensaverOff: false
  property bool screensaverDesiredOff: false

  function refreshScreensaverFlag() {
    if (!root.toggleEnabledPath) return
    if (screensaverFlagProbe.running) return
    screensaverFlagProbe.command = [root.toggleEnabledPath, "screensaver-off"]
    root._armProcess("probe")
  }

  // Optimistic write: the switch answers instantly, and the probe corrects
  // it if the write fails. A flip mid-write is reconciled on exit, not
  // lost -- a Process ignores running=true while already running.
  function setScreensaverOff(off) {
    root.screensaverDesiredOff = off === true
    root.screensaverOff = root.screensaverDesiredOff
    maybeWriteScreensaverFlag()
  }

  function maybeWriteScreensaverFlag() {
    if (!root.togglePath) return
    if (screensaverWriter.running) return
    screensaverWriter.wrote = root.screensaverDesiredOff
    // The explicit on/off action, never the bare flip: a caller that knows
    // the state it wants must not depend on what the state happened to be.
    screensaverWriter.command = [root.togglePath, "screensaver-off", root.screensaverDesiredOff ? "on" : "off"]
    root._armProcess("write")
  }

  function handleWriteExit(exitCode, err) {
    if (exitCode !== 0) log("omarchy-toggle screensaver-off failed (exit " + exitCode + ")")
    if (root.screensaverDesiredOff !== screensaverWriter.wrote) {
      root.maybeWriteScreensaverFlag()
      return
    }
    root.refreshScreensaverFlag()
  }

  function handleProbeExit(exitCode, err) {
    root.screensaverOff = exitCode === 0
    togglesWatch.reload()
  }

  function handleSuspendExit(exitCode, err) {
    // Success is evidenced by the machine actually suspending; a refusal
    // is the case that must not pass silently in a service that logs every
    // other decision.
    if (exitCode !== 0) log("systemctl suspend failed (exit " + exitCode + ")")
  }

  function handleNotifyExit(exitCode, err) {
    if (exitCode !== 0) log("notification send failed (exit " + exitCode + ")")
  }

  FileView {
    id: togglesWatch
    path: root.home + "/.local/state/omarchy/toggles"
    // Watch-only: preload stays false, so a large or symlinked file at
    // this user-writable path is never read into shell memory --
    // reload() re-attaches the watch without reading it. See docs/threat-model.md.
    preload: false
    watchChanges: true
    printErrors: false
    onFileChanged: root.refreshScreensaverFlag()
  }

  // Each Process below gets a watchdog Timer (TERM, then a PID-guarded
  // KILL a second later) and the generation-counter failed-start finalize
  // (onRunningChanged + Qt.callLater) so a missing binary is never lost.

  Timer {
    id: resolveToggleWatchdog
    repeat: false
    onTriggered: {
      if (resolveToggleProc.running) {
        root.log("omarchy-toggle resolution watchdog: exceeded " + resolveToggleWatchdog.interval + "ms, killing")
        root._resolveToggleWatchdogFired = true
        root._resolveToggleWatchdogFiredCount = root._resolveToggleWatchdogFiredCount + 1
        resolveToggleProc.signal(15)
        resolveToggleKillTimer.restart()
      }
    }
  }
  Timer {
    id: resolveToggleKillTimer
    interval: 1000
    repeat: false
    onTriggered: {
      if (resolveToggleProc.running && resolveToggleProc.processId === root._resolveToggleArmedPid) resolveToggleProc.signal(9)
    }
  }
  Process {
    id: resolveToggleProc
    command: []
    running: false
    onStarted: { root._resolveToggleArmedPid = processId }
    onRunningChanged: {
      if (!running) {
        var gen = root._resolveToggleGen
        Qt.callLater(function () {
          if (root._resolveToggleGen === gen && root._resolveToggleExitedGen !== gen) {
            root._resolveToggleExitedGen = gen
            root._finalizeProcess("resolveToggle", 127, 0, true)
          }
        })
      }
    }
    stdout: SplitParser { onRead: function (line) { root._appendBoundedOutput("resolveToggle", line, false) } }
    stderr: SplitParser { onRead: function (line) { root._appendBoundedOutput("resolveToggle", line, true) } }
    onExited: function (exitCode, exitStatus) {
      root._resolveToggleExitedGen = root._resolveToggleGen
      root._finalizeProcess("resolveToggle", exitCode, exitStatus, false)
    }
  }

  Timer {
    id: resolveToggleEnabledWatchdog
    repeat: false
    onTriggered: {
      if (resolveToggleEnabledProc.running) {
        root.log("omarchy-toggle-enabled resolution watchdog: exceeded " + resolveToggleEnabledWatchdog.interval + "ms, killing")
        root._resolveToggleEnabledWatchdogFired = true
        root._resolveToggleEnabledWatchdogFiredCount = root._resolveToggleEnabledWatchdogFiredCount + 1
        resolveToggleEnabledProc.signal(15)
        resolveToggleEnabledKillTimer.restart()
      }
    }
  }
  Timer {
    id: resolveToggleEnabledKillTimer
    interval: 1000
    repeat: false
    onTriggered: {
      if (resolveToggleEnabledProc.running && resolveToggleEnabledProc.processId === root._resolveToggleEnabledArmedPid) resolveToggleEnabledProc.signal(9)
    }
  }
  Process {
    id: resolveToggleEnabledProc
    command: []
    running: false
    onStarted: { root._resolveToggleEnabledArmedPid = processId }
    onRunningChanged: {
      if (!running) {
        var gen = root._resolveToggleEnabledGen
        Qt.callLater(function () {
          if (root._resolveToggleEnabledGen === gen && root._resolveToggleEnabledExitedGen !== gen) {
            root._resolveToggleEnabledExitedGen = gen
            root._finalizeProcess("resolveToggleEnabled", 127, 0, true)
          }
        })
      }
    }
    stdout: SplitParser { onRead: function (line) { root._appendBoundedOutput("resolveToggleEnabled", line, false) } }
    stderr: SplitParser { onRead: function (line) { root._appendBoundedOutput("resolveToggleEnabled", line, true) } }
    onExited: function (exitCode, exitStatus) {
      root._resolveToggleEnabledExitedGen = root._resolveToggleEnabledGen
      root._finalizeProcess("resolveToggleEnabled", exitCode, exitStatus, false)
    }
  }

  Timer {
    id: mkdirTogglesWatchdog
    repeat: false
    onTriggered: {
      if (mkdirTogglesProc.running) {
        root.log("mkdir toggles dir watchdog: exceeded " + mkdirTogglesWatchdog.interval + "ms, killing")
        root._mkdirTogglesWatchdogFired = true
        root._mkdirTogglesWatchdogFiredCount = root._mkdirTogglesWatchdogFiredCount + 1
        mkdirTogglesProc.signal(15)
        mkdirTogglesKillTimer.restart()
      }
    }
  }
  Timer {
    id: mkdirTogglesKillTimer
    interval: 1000
    repeat: false
    onTriggered: {
      if (mkdirTogglesProc.running && mkdirTogglesProc.processId === root._mkdirTogglesArmedPid) mkdirTogglesProc.signal(9)
    }
  }
  Process {
    id: mkdirTogglesProc
    command: []
    running: false
    onStarted: { root._mkdirTogglesArmedPid = processId }
    onRunningChanged: {
      if (!running) {
        var gen = root._mkdirTogglesGen
        Qt.callLater(function () {
          if (root._mkdirTogglesGen === gen && root._mkdirTogglesExitedGen !== gen) {
            root._mkdirTogglesExitedGen = gen
            root._finalizeProcess("mkdirToggles", 127, 0, true)
          }
        })
      }
    }
    stdout: SplitParser { onRead: function (line) { root._appendBoundedOutput("mkdirToggles", line, false) } }
    stderr: SplitParser { onRead: function (line) { root._appendBoundedOutput("mkdirToggles", line, true) } }
    onExited: function (exitCode, exitStatus) {
      root._mkdirTogglesExitedGen = root._mkdirTogglesGen
      root._finalizeProcess("mkdirToggles", exitCode, exitStatus, false)
    }
  }

  Timer {
    id: writeWatchdog
    repeat: false
    onTriggered: {
      if (screensaverWriter.running) {
        root.log("omarchy-toggle write watchdog: exceeded " + writeWatchdog.interval + "ms, killing")
        root._writeWatchdogFired = true
        root._writeWatchdogFiredCount = root._writeWatchdogFiredCount + 1
        screensaverWriter.signal(15)
        writeKillTimer.restart()
      }
    }
  }
  Timer {
    id: writeKillTimer
    interval: 1000
    repeat: false
    onTriggered: {
      if (screensaverWriter.running && screensaverWriter.processId === root._writeArmedPid) screensaverWriter.signal(9)
    }
  }
  Process {
    id: screensaverWriter
    property bool wrote: false
    command: []
    running: false
    onStarted: { root._writeArmedPid = processId }
    onRunningChanged: {
      if (!running) {
        var gen = root._writeGen
        Qt.callLater(function () {
          if (root._writeGen === gen && root._writeExitedGen !== gen) {
            root._writeExitedGen = gen
            root._finalizeProcess("write", 127, 0, true)
          }
        })
      }
    }
    stdout: SplitParser { onRead: function (line) { root._appendBoundedOutput("write", line, false) } }
    stderr: SplitParser { onRead: function (line) { root._appendBoundedOutput("write", line, true) } }
    onExited: function (exitCode, exitStatus) {
      root._writeExitedGen = root._writeGen
      root._finalizeProcess("write", exitCode, exitStatus, false)
    }
  }

  Timer {
    id: probeWatchdog
    repeat: false
    onTriggered: {
      if (screensaverFlagProbe.running) {
        root.log("screensaver flag probe watchdog: exceeded " + probeWatchdog.interval + "ms, killing")
        root._probeWatchdogFired = true
        root._probeWatchdogFiredCount = root._probeWatchdogFiredCount + 1
        screensaverFlagProbe.signal(15)
        probeKillTimer.restart()
      }
    }
  }
  Timer {
    id: probeKillTimer
    interval: 1000
    repeat: false
    onTriggered: {
      if (screensaverFlagProbe.running && screensaverFlagProbe.processId === root._probeArmedPid) screensaverFlagProbe.signal(9)
    }
  }
  Process {
    id: screensaverFlagProbe
    command: []
    running: false
    onStarted: { root._probeArmedPid = processId }
    onRunningChanged: {
      if (!running) {
        var gen = root._probeGen
        Qt.callLater(function () {
          if (root._probeGen === gen && root._probeExitedGen !== gen) {
            root._probeExitedGen = gen
            root._finalizeProcess("probe", 127, 0, true)
          }
        })
      }
    }
    stdout: SplitParser { onRead: function (line) { root._appendBoundedOutput("probe", line, false) } }
    stderr: SplitParser { onRead: function (line) { root._appendBoundedOutput("probe", line, true) } }
    onExited: function (exitCode, exitStatus) {
      root._probeExitedGen = root._probeGen
      root._finalizeProcess("probe", exitCode, exitStatus, false)
    }
  }

  Timer {
    id: suspendWatchdog
    repeat: false
    onTriggered: {
      if (suspendProcess.running) {
        root.log("systemctl suspend watchdog: exceeded " + suspendWatchdog.interval + "ms, killing")
        root._suspendWatchdogFired = true
        root._suspendWatchdogFiredCount = root._suspendWatchdogFiredCount + 1
        suspendProcess.signal(15)
        suspendKillTimer.restart()
      }
    }
  }
  Timer {
    id: suspendKillTimer
    interval: 1000
    repeat: false
    onTriggered: {
      if (suspendProcess.running && suspendProcess.processId === root._suspendArmedPid) suspendProcess.signal(9)
    }
  }
  Process {
    id: suspendProcess
    command: []
    running: false
    onStarted: { root._suspendArmedPid = processId }
    onRunningChanged: {
      if (!running) {
        var gen = root._suspendGen
        Qt.callLater(function () {
          if (root._suspendGen === gen && root._suspendExitedGen !== gen) {
            root._suspendExitedGen = gen
            root._finalizeProcess("suspend", 127, 0, true)
          }
        })
      }
    }
    stdout: SplitParser { onRead: function (line) { root._appendBoundedOutput("suspend", line, false) } }
    stderr: SplitParser { onRead: function (line) { root._appendBoundedOutput("suspend", line, true) } }
    onExited: function (exitCode, exitStatus) {
      root._suspendExitedGen = root._suspendGen
      root._finalizeProcess("suspend", exitCode, exitStatus, false)
    }
  }

  Timer {
    id: notifyWatchdog
    repeat: false
    onTriggered: {
      if (notifyProcess.running) {
        root.log("notification send watchdog: exceeded " + notifyWatchdog.interval + "ms, killing")
        root._notifyWatchdogFired = true
        root._notifyWatchdogFiredCount = root._notifyWatchdogFiredCount + 1
        notifyProcess.signal(15)
        notifyKillTimer.restart()
      }
    }
  }
  Timer {
    id: notifyKillTimer
    interval: 1000
    repeat: false
    onTriggered: {
      if (notifyProcess.running && notifyProcess.processId === root._notifyArmedPid) notifyProcess.signal(9)
    }
  }
  Process {
    id: notifyProcess
    command: []
    running: false
    onStarted: { root._notifyArmedPid = processId }
    onRunningChanged: {
      if (!running) {
        var gen = root._notifyGen
        Qt.callLater(function () {
          if (root._notifyGen === gen && root._notifyExitedGen !== gen) {
            root._notifyExitedGen = gen
            root._finalizeProcess("notify", 127, 0, true)
          }
        })
      }
    }
    stdout: SplitParser { onRead: function (line) { root._appendBoundedOutput("notify", line, false) } }
    stderr: SplitParser { onRead: function (line) { root._appendBoundedOutput("notify", line, true) } }
    onExited: function (exitCode, exitStatus) {
      root._notifyExitedGen = root._notifyGen
      root._finalizeProcess("notify", exitCode, exitStatus, false)
    }
  }

  // Reads sleepSeconds directly rather than `armable`: a property derived
  // from the one that just changed may not have re-evaluated yet inside
  // this handler, so `armable` could still print the previous value.
  onSleepSecondsChanged: {
    // A delay change while a countdown runs means "not that countdown":
    // cancel rather than guess. The next idle lock arms with the new value.
    if (suspendTimer.running) {
      suspendTimer.stop()
      log("sleep delay changed while counting down -- countdown cancelled")
    }
    if (root._sleepNormalized.clamped)
      log("sleepAfterIdleLock exceeded the cap -- clamped to " + root._sleepNormalized.seconds + "s")
    log("sleep delay is now " + (sleepSeconds > 0 ? sleepSeconds + "s" : "never"))
  }
  onDryRunChanged: log("dry run is now " + dryRun)

  // The panel promises "no screensaver, no lock, no sleep" under
  // stay-awake; a countdown (or a settle still verifying origin) armed
  // before the flag flipped must honour it outright.
  onStayAwakeChanged: {
    if (stayAwake) {
      var wasCounting = suspendTimer.running || originSettle.running
      if (suspendTimer.running) suspendTimer.stop()
      if (originSettle.running) originSettle.stop()
      if (wasCounting) log("stay-awake enabled -- countdown cancelled")
    }
  }

  // A host service can disappear mid-countdown (the shell recreates
  // singletons); the derived properties above just read as false/absent,
  // which is not the same as "safe to keep counting down".
  onIdleServiceChanged: {
    if (!idleService) {
      var hadState = originSettle.running || suspendTimer.running || root.idleLockPending
      originSettle.stop()
      suspendTimer.stop()
      latchExpiry.stop()
      root.idleLockPending = false
      root.idleLockAnnounced = false
      if (hadState) log("omarchy.idle service lost -- countdown cancelled, latch cleared")
    }
  }
  onLockServiceChanged: {
    if (!lockService) {
      var hadState2 = originSettle.running || suspendTimer.running || root.idleLockPending
      originSettle.stop()
      suspendTimer.stop()
      latchExpiry.stop()
      root.idleLockPending = false
      root.idleLockAnnounced = false
      if (hadState2) log("omarchy.lock service lost -- countdown cancelled, latch cleared")
    }
  }

  // A string-form bar-layout entry ("some.id") has no object for
  // updateEntryInline to read/write, so settings silently never persist;
  // this delayed check gives that failure a voice. Plain: a probe shortens the wait.
  property int configEntryCheckMs: 15000

  Timer {
    interval: root.configEntryCheckMs
    running: true
    repeat: false
    onTriggered: {
      if (Model.entryFor(root.shellConfig, "halmylyseas.ristretto") === null)
        log("no config entry found -- settings cannot persist and defaults are in effect " +
            "(a string-form bar-layout entry has this effect; make it an object with an id key)")
    }
  }

  Component.onCompleted: {
    mkdirTogglesProc.command = ["mkdir", "-p", root.home + "/.local/state/omarchy/toggles"]
    root._armProcess("mkdirToggles")
    root.resolveToggle()
    root.resolveToggleEnabled()
    log("service ready (sleep=" + sleepSeconds + "s dryRun=" + dryRun + ")")
  }
}
