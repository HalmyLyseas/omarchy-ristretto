import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Suspend the machine a chosen delay after an IDLE lock.
//
// Omarchy has no suspend-on-idle of any kind -- logind's IdleAction never
// fires here because nothing publishes Wayland idle state to logind, so the
// only workable place for this is plugin-side.
//
// A fresh install can never change what the machine does: the delay
// defaults to "never", so the timer is never armed until the user picks a
// value. dryRun (config-only, off by default) is a testing valve that
// replaces the real suspend with a log line and a notification.
Item {
  id: root

  // Injected by omarchy-shell's service loader.
  property var shell: null

  readonly property var idleService: shell ? shell.firstPartyServiceFor("omarchy.idle") : null
  readonly property var lockService: shell ? shell.firstPartyServiceFor("omarchy.lock") : null

  readonly property bool locked: lockService ? lockService.locked === true : false
  readonly property string idleEvent: idleService ? String(idleService.lastEvent || "") : ""
  readonly property bool stayAwake: idleService ? idleService.stayAwake === true : false

  readonly property var shellConfig: shell ? shell.shellConfig : null
  readonly property int sleepSeconds:
    Number(Model.settingFromConfig(shellConfig, "halmylyseas.ristretto", "sleepAfterIdleLock", Model.SLEEP_NEVER))
  readonly property bool dryRun:
    Model.settingFromConfig(shellConfig, "halmylyseas.ristretto", "dryRun", false) === true

  readonly property bool armable: sleepSeconds > 0

  // True once an idle-driven lock has been announced and until the session
  // unlocks again. This latch is the whole trick.
  //
  // Neither obvious discriminator works. lockRequested is set by beginLock()
  // for EVERY lock, manual ones included, so it carries no origin. And
  // idledThisCycle is already false by the time the lock lands, because
  // lockSystem() clears it before spawning omarchy-system-lock -- binding
  // "locked && idledThisCycle" never arms, and fails silently.
  //
  // lastEvent works: lockSystem() is called from exactly two places, both
  // idle-driven -- the lock timer, and the immediate branch that runs when
  // the derived lock delay is zero. Nothing else in the service ever emits
  // it, so a manual Super+Escape cannot set this.
  //
  // Accepted risk: lastEvent is a free-form log mirror, and the same
  // synchronous call overwrites it with "process-start: lock ..." moments
  // later -- this latch works because QML delivers one change signal per
  // assignment. A host rewording of the event would disable the feature
  // silently; the wording-independent replacement, should that happen, is a
  // plugin-owned IdleMonitor consulted at the locked rising edge.
  //
  // A lock-system event that lands while the session is ALREADY manually
  // locked sets the latch but never arms, because locked has no rising edge
  // left to fire on. That is intended, not incidental: the session was locked
  // by the user's own hand, and a deliberate lock never leads to suspend.
  property bool idleLockPending: false

  onIdleEventChanged: {
    if (idleEvent.indexOf("lock-system") === 0) {
      root.idleLockPending = true
      latchExpiry.restart()
      log("idle lock announced (" + idleEvent + ")")
    }
  }

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
      // The interval is assigned here, not bound: a live binding on a
      // running Timer restarts the countdown on any config change, and a
      // change to "never" (-1) would clamp to a one-second fuse instead of
      // the cancellation the edit meant.
      suspendTimer.interval = root.sleepSeconds * 1000
      suspendTimer.restart()
      log("armed: suspend in " + root.sleepSeconds + "s" + (root.dryRun ? " (dry run)" : ""))
    } else {
      // Log unconditionally: a clean unlock after the timer already fired left
      // no trace at all, so there was no way to confirm the latch cleared.
      log(suspendTimer.running ? "unlocked -- countdown cancelled"
                               : "unlocked -- latch cleared")
      suspendTimer.stop()
      root.idleLockPending = false
    }
  }

  Timer {
    id: suspendTimer
    repeat: false
    onTriggered: root.suspend()
  }

  // An idle lock is announced before the lock process spawns, and that
  // spawn can be skipped or fail -- in which case locked never rises and
  // nothing else would ever clear the latch. A real lock lands within a
  // second; if none has after this window, the announcement is dead and a
  // later manual lock must not inherit it.
  Timer {
    id: latchExpiry
    interval: 10000
    repeat: false
    onTriggered: {
      if (root.idleLockPending && !root.locked) {
        root.idleLockPending = false
        log("idle lock announced but nothing locked -- latch dropped")
      }
    }
  }

  // Re-check rather than trust the timer: the session may have been unlocked
  // between the timer firing and this running.
  function suspend() {
    if (!root.locked) {
      log("fired but no longer locked -- ignoring")
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
      notifyProcess.running = true
      return
    }
    log("suspending")
    suspendProcess.command = ["systemctl", "suspend"]
    suspendProcess.running = true
  }

  function log(message) {
    console.log("ristretto " + message)
  }

  // ------------------------------------------------- the screensaver flag
  //
  // The screensaver-off flag has no QML reader anywhere in Omarchy, so this
  // service owns the machine's one watcher for it and panels bind. The
  // pattern is the host's own stay-awake watcher: an exit-code probe that
  // mkdirs the watched directory (a FileView cannot attach to a path that
  // does not exist yet, and on a fresh machine it does not), and a reload
  // of the directory watch after every probe so it attaches once possible.

  property bool screensaverOff: false
  property bool screensaverDesiredOff: false

  function refreshScreensaverFlag() {
    if (!screensaverFlagProbe.running) screensaverFlagProbe.running = true
  }

  // The switch's write path. Optimistic so the switch answers instantly;
  // the probe corrects it if the write fails. A flip arriving while the
  // writer is still running is reconciled on exit rather than lost -- a
  // Process ignores running=true while already running, so a rapid second
  // click would otherwise silently never land.
  function setScreensaverOff(off) {
    root.screensaverDesiredOff = off === true
    root.screensaverOff = root.screensaverDesiredOff
    maybeWriteScreensaverFlag()
  }

  function maybeWriteScreensaverFlag() {
    if (screensaverWriter.running) return
    screensaverWriter.wrote = root.screensaverDesiredOff
    // The explicit on/off action, never the bare flip: a caller that knows
    // the state it wants must not depend on what the state happened to be.
    screensaverWriter.command = ["bash", "-lc",
      root.screensaverDesiredOff ? "omarchy-toggle screensaver-off on"
                                 : "omarchy-toggle screensaver-off off"]
    screensaverWriter.running = true
  }

  Process {
    id: screensaverWriter
    property bool wrote: false
    onExited: {
      if (root.screensaverDesiredOff !== wrote) {
        root.maybeWriteScreensaverFlag()
        return
      }
      root.refreshScreensaverFlag()
    }
  }

  Process {
    id: screensaverFlagProbe
    // bash -lc, as the host spawns its own CLIs: a login shell rebuilds
    // PATH in sessions where the compositor environment lacks the omarchy
    // bin directory. The tool's exit code is the whole answer.
    command: ["bash", "-lc",
      "mkdir -p \"$HOME/.local/state/omarchy/toggles\"; omarchy-toggle-enabled screensaver-off"]
    onExited: function(exitCode, exitStatus) {
      root.screensaverOff = exitCode === 0
      togglesWatch.reload()
    }
  }

  FileView {
    id: togglesWatch
    path: Quickshell.env("HOME") + "/.local/state/omarchy/toggles"
    watchChanges: true
    printErrors: false
    onFileChanged: root.refreshScreensaverFlag()
  }


  Process {
    id: suspendProcess
    // Success is evidenced by the machine actually suspending; a refusal
    // is the case that must not pass silently in a service that logs every
    // other decision.
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) log("systemctl suspend failed (exit " + exitCode + ")")
    }
  }
  Process { id: notifyProcess }

  // Config is reactive, so these confirm what the service is actually acting
  // on rather than what it read once at startup.
  // Derive from sleepSeconds directly rather than reading `armable`: a
  // property derived from the one that changed has not necessarily
  // re-evaluated yet when its change handler runs, so `armable` here can still
  // hold the previous value and print "-1s" instead of "never".
  onSleepSecondsChanged: {
    // A delay change while a countdown runs means "not that countdown":
    // cancel rather than guess. The next idle lock arms with the new value.
    if (suspendTimer.running) {
      suspendTimer.stop()
      log("sleep delay changed while counting down -- countdown cancelled")
    }
    log("sleep delay is now " + (sleepSeconds > 0 ? sleepSeconds + "s" : "never"))
  }
  onDryRunChanged: log("dry run is now " + dryRun)

  // The panel promises "no screensaver, no lock, no sleep" under
  // stay-awake; a countdown armed before the flag flipped must honour it.
  onStayAwakeChanged: {
    if (stayAwake && suspendTimer.running) {
      suspendTimer.stop()
      log("stay-awake enabled -- countdown cancelled")
    }
  }

  // The host accepts plain-string bar-layout entries ("some.id"), renders
  // them fine, but can neither read settings from nor write settings into
  // one -- updateEntryInline matches only object entries. The feature then
  // fails safe but silently; one delayed check gives it a voice. Delayed,
  // because at startup shellConfig briefly holds built-in defaults with no
  // plugin entries at all.
  Timer {
    interval: 15000
    running: true
    repeat: false
    onTriggered: {
      if (Model.entryFor(root.shellConfig, "halmylyseas.ristretto") === null)
        log("no config entry found -- settings cannot persist and defaults are in effect " +
            "(a string-form bar-layout entry has this effect; make it an object with an id key)")
    }
  }

  Component.onCompleted: {
    refreshScreensaverFlag()
    log("service ready (sleep=" + sleepSeconds + "s dryRun=" + dryRun + ")")
  }
}
