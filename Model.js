.pragma library

// Curated stops, in minutes. LOCK is always kept strictly above SCREENSAVER
// (see clampPair), so the two sets are deliberately asymmetric: SCREENSAVER
// starts one notch lower and LOCK reaches one notch higher, which is what
// makes a strict clamp reachable at both ends.
var SCREENSAVER_STOPS = [1, 2, 3, 5, 10, 15]
var LOCK_STOPS = [2, 3, 5, 10, 15, 30]

// Stored in seconds (the unit the service arms with), but the scale is
// minutes: 1, 2, 3, 5, 10, and "never" as the last stop. -1 means the
// suspend timer is simply not armed.
var SLEEP_STOPS = [60, 120, 180, 300, 600, -1]
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

function minutesLabel(minutes) {
  return minutes + (minutes === 1 ? " minute" : " minutes")
}

// Label for a value drawn from SLEEP_STOPS (always on-scale).
function sleepLabel(seconds) {
  return seconds > 0 ? minutesLabel(seconds / 60) : "never"
}

// Compact form for the hero status line, which also has to render legacy
// off-scale values (a config written before the scale changed) faithfully.
function sleepStatusShort(seconds) {
  if (!(seconds > 0)) return "never"
  return seconds % 60 === 0 ? (seconds / 60) + " min" : seconds + "s"
}

// Which stop the slider should sit on for an arbitrary stored value: the
// nearest positive stop, or the "never" stop for -1. Off-scale values snap
// the display only -- nothing is written until the user moves the slider.
function sleepIndexFor(seconds) {
  if (!(seconds > 0)) return SLEEP_STOPS.length - 1
  var best = 0
  var bestDelta = Infinity
  for (var i = 0; i < SLEEP_STOPS.length; i++) {
    if (SLEEP_STOPS[i] <= 0) continue
    var delta = Math.abs(SLEEP_STOPS[i] - seconds)
    if (delta < bestDelta) {
      bestDelta = delta
      best = i
    }
  }
  return best
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

// ------------------------------------------------------- own settings entry
//
// The shell injects `settings` into widgets and panels, but a service gets
// only `shell`, so it has to find its own entry in shellConfig. The entry
// lives in the bar layout for a bar-widget plugin and in plugins[] otherwise.

function entryFor(config, id) {
  if (!config) return null
  var layout = config.bar && config.bar.layout ? config.bar.layout : null
  var sections = ["left", "center", "right"]
  if (layout) {
    for (var s = 0; s < sections.length; s++) {
      var arr = layout[sections[s]] || []
      for (var i = 0; i < arr.length; i++) if (arr[i] && arr[i].id === id) return arr[i]
    }
  }
  var plugins = config.plugins || []
  for (var j = 0; j < plugins.length; j++) if (plugins[j] && plugins[j].id === id) return plugins[j]
  return null
}

function settingFromConfig(config, id, key, fallback) {
  var entry = entryFor(config, id)
  if (!entry) return fallback
  var value = entry[key]
  return value === undefined || value === null ? fallback : value
}

// updateEntryInline REPLACES the entry with { id } plus whatever it is given,
// so a caller that passes one key silently drops every other setting. Always
// merge onto the current settings first.
function mergedSettings(current, key, value) {
  var next = ({})
  for (var k in current) if (k !== "id") next[k] = current[k]
  next[key] = value
  return next
}
