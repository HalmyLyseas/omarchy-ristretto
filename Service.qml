import QtQuick
import Quickshell.Io
import "Model.js" as Model

// P4: suspend the machine a chosen delay after an IDLE lock.
//
// Omarchy has no suspend-on-idle of any kind -- logind's IdleAction never
// fires here because nothing publishes Wayland idle state to logind, so the
// only workable place for this is plugin-side.
//
// Two guards mean an install can never change what the machine does until
// asked: the delay defaults to "never", and the real suspend is additionally
// gated behind dryRun being false.
Item {
  id: root

  // Injected by omarchy-shell's service loader.
  property var shell: null

  readonly property var idleService: shell ? shell.firstPartyServiceFor("omarchy.idle") : null
  readonly property var lockService: shell ? shell.firstPartyServiceFor("omarchy.lock") : null

  readonly property bool locked: lockService ? lockService.locked === true : false
  readonly property string idleEvent: idleService ? String(idleService.lastEvent || "") : ""

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
  // idle timers, and both log "lock-system: ...". Nothing else in the service
  // ever emits it, so a manual Super+Escape cannot set this.
  property bool idleLockPending: false

  onIdleEventChanged: {
    if (idleEvent.indexOf("lock-system") === 0) {
      root.idleLockPending = true
      log("idle lock announced (" + idleEvent + ")")
    }
  }

  onLockedChanged: {
    if (locked) {
      if (!root.idleLockPending) {
        log("locked, but not by idle -- not arming")
        return
      }
      if (!root.armable) {
        log("idle lock, but sleep delay is never -- not arming")
        return
      }
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
    interval: Math.max(1, root.sleepSeconds) * 1000
    repeat: false
    onTriggered: root.suspend()
  }

  // Re-check rather than trust the timer: the session may have been unlocked
  // between the timer firing and this running.
  function suspend() {
    if (!root.locked) {
      log("fired but no longer locked -- ignoring")
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

  Process { id: suspendProcess }
  Process { id: notifyProcess }

  // Config is reactive, so these confirm what the service is actually acting
  // on rather than what it read once at startup.
  // Derive from sleepSeconds directly rather than reading `armable`: a
  // property derived from the one that changed has not necessarily
  // re-evaluated yet when its change handler runs, so `armable` here can still
  // hold the previous value and print "-1s" instead of "never".
  onSleepSecondsChanged: log("sleep delay is now " + (sleepSeconds > 0 ? sleepSeconds + "s" : "never"))
  onDryRunChanged: log("dry run is now " + dryRun)

  Component.onCompleted: log("service ready (sleep=" + sleepSeconds + "s dryRun=" + dryRun + ")")
}
