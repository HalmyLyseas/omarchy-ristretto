.pragma library

// Curated stops, in minutes. LOCK is always kept strictly above SCREENSAVER
// (see clampPair), so the two sets are deliberately asymmetric: SCREENSAVER
// starts one notch lower and LOCK reaches one notch higher, which is what
// makes a strict clamp reachable at both ends.
var SCREENSAVER_STOPS = [1, 2, 3, 5, 10, 15]
var LOCK_STOPS = [2, 3, 5, 10, 15, 30]

// Seconds. -1 is the "never" option rendered as the infinity glyph: the
// suspend timer is simply not armed.
var SLEEP_STOPS = [30, 60, 90, 120, 150, -1]
var SLEEP_NEVER = -1

// Nearest stop to an arbitrary value. Omarchy's defaults (screensaver 150s =
// 2.5min) do not sit on our scale, so the panel snaps the *display* without
// writing anything back.
function nearestIndex(stops, value) {
  var best = 0
  var bestDelta = Infinity
  for (var i = 0; i < stops.length; i++) {
    var delta = Math.abs(stops[i] - value)
    if (delta < bestDelta) {
      bestDelta = delta
      best = i
    }
  }
  return best
}

function indexOfExact(stops, value) {
  for (var i = 0; i < stops.length; i++) if (stops[i] === value) return i
  return -1
}

function minutesLabel(minutes) {
  return minutes + (minutes === 1 ? " minute" : " minutes")
}

function sleepLabel(seconds) {
  return seconds === SLEEP_NEVER ? "∞" : seconds + "s"
}

// --------------------------------------------------------------- the clamp
//
// LOCK must sit STRICTLY above SCREENSAVER. Equal values are not merely
// redundant, they are broken: omarchy.idle derives both stage delays from
// min(screensaver, lock), so equal values make both 0 and startIdleCycle
// launches the screensaver and fires the lock in the same pass. The
// screensaver's "skip if already locked" guard is a subprocess that runs
// before the lock has even been requested, so it passes and the screensaver
// flashes up underneath the lock.
//
// Both directions always land on a real stop, which is why the two scales are
// asymmetric: SCREENSAVER's maximum (15) is below LOCK's maximum (30), so
// there is always a lock above; LOCK's minimum (2) is above SCREENSAVER's
// minimum (1), so there is always a screensaver below.

function lockIndexAbove(screensaverMinutes, currentLockIndex) {
  if (LOCK_STOPS[currentLockIndex] > screensaverMinutes) return currentLockIndex
  for (var i = 0; i < LOCK_STOPS.length; i++) {
    if (LOCK_STOPS[i] > screensaverMinutes) return i
  }
  return LOCK_STOPS.length - 1
}

function screensaverIndexBelow(lockMinutes, currentScreensaverIndex) {
  if (SCREENSAVER_STOPS[currentScreensaverIndex] < lockMinutes) return currentScreensaverIndex
  for (var i = SCREENSAVER_STOPS.length - 1; i >= 0; i--) {
    if (SCREENSAVER_STOPS[i] < lockMinutes) return i
  }
  return 0
}

// The pair that should be persisted when one slider moves. Returns minutes,
// not indices: the caller converts to the seconds omarchy.idle stores.
function pairFromScreensaver(screensaverIndex, currentLockIndex) {
  var ss = SCREENSAVER_STOPS[screensaverIndex]
  return { screensaver: ss, lock: LOCK_STOPS[lockIndexAbove(ss, currentLockIndex)] }
}

function pairFromLock(lockIndex, currentScreensaverIndex) {
  var lk = LOCK_STOPS[lockIndex]
  return { screensaver: SCREENSAVER_STOPS[screensaverIndexBelow(lk, currentScreensaverIndex)], lock: lk }
}
