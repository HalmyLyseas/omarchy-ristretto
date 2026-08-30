.pragma library

// Curated stops, in minutes. LOCK stays strictly above SCREENSAVER, which
// lockIndexAbove/screensaverIndexBelow enforce, so the two arrays are
// asymmetric at both ends to make that clamp always reachable.
var SCREENSAVER_STOPS = [1, 2, 3, 5, 10, 15]
var LOCK_STOPS = [2, 3, 5, 10, 15, 30]

// Stored in seconds (the unit the service arms with), but the scale is
// minutes: 1, 2, 3, 5, 10, and "never" as the last stop. -1 means the
// suspend timer is simply not armed.
var SLEEP_STOPS = [60, 120, 180, 300, 600, -1]
var SLEEP_NEVER = -1

// Far under the int32-ms Timer.interval limit (2147483s): hand-edited
// garbage read as seconds must never survive a multiply-by-1000 that
// wraps the interval negative.
var SLEEP_MAX_SECONDS = 86400

// The lowest Omarchy version this plugin is tested against; test/host-contract.mjs
// checks the installed package meets it. Bump only after testing live.
var SUPPORTED_OMARCHY_MIN = "4.0.1"

// The origin IdleMonitor's window, read by Service.qml's IdleMonitor.timeout.
// Must stay well under the smallest reachable screensaver-to-lock gap --
// see the invariant test in test/model.test.js and docs/developers.md.
var ORIGIN_IDLE_TIMEOUT_SECONDS = 30

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

// One formatter for a sleep value, so the slider caption and the hero can
// never disagree; the short form fits the hero's width budget and renders
// an off-scale legacy value faithfully in seconds.
function sleepLabel(seconds, short) {
  if (!(seconds > 0)) return "never"
  if (short) return seconds % 60 === 0 ? (seconds / 60) + " min" : seconds + "s"
  return minutesLabel(seconds / 60)
}

// The stop the slider should sit on for an arbitrary stored value: the
// nearest positive stop, or the last ("never") stop for -1. Reuses
// nearestIndex on the positive stops alone -- the array minus its tail.
function sleepIndexFor(seconds) {
  if (!(seconds > 0)) return SLEEP_STOPS.length - 1
  return nearestIndex(SLEEP_STOPS.slice(0, -1), seconds)
}

// --------------------------------------------------------------- the clamp
// LOCK must sit strictly above SCREENSAVER: equal values make omarchy.idle
// derive both stage delays as 0. Detail: docs/developers.md.

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

// One keyboard step from the actual stored value, not its snapped index --
// a stored 2.5 must step down to 2, not skip to 1. Returns an index into
// stops, or -1 when there is no stop in that direction.
function stepFrom(stops, value, direction) {
  if (direction > 0) {
    for (var i = 0; i < stops.length; i++) if (stops[i] > value) return i
    return -1
  }
  for (var j = stops.length - 1; j >= 0; j--) if (stops[j] < value) return j
  return -1
}

// Same, for the sleep scale, where the last stop is "never" (-1) and orders
// as larger than every real delay. Returns seconds (or SLEEP_NEVER), or
// null when there is no step in that direction.
function sleepStepFrom(seconds, direction) {
  var maxPos = SLEEP_STOPS.length - 2
  if (!(seconds > 0)) return direction < 0 ? SLEEP_STOPS[maxPos] : null
  if (direction > 0) {
    for (var i = 0; i <= maxPos; i++) if (SLEEP_STOPS[i] > seconds) return SLEEP_STOPS[i]
    return SLEEP_NEVER
  }
  for (var j = maxPos; j >= 0; j--) if (SLEEP_STOPS[j] < seconds) return SLEEP_STOPS[j]
  return null
}

// ---------------------------------------------------------- config validation
// Raw config values are hand-editable JSON: a normalizer accepts only the
// shapes it can act on safely and fails toward the harmless outcome.

// Only typeof "number", or a trimmed numeric string, is ever converted --
// Number() alone accepts far more than that (an array like [300] coerces
// to 300), which would let a JSON typo arm a real delay.
function sleepRawToNumber(raw) {
  if (typeof raw === "number") return raw
  if (typeof raw === "string") {
    var trimmed = raw.replace(/^\s+|\s+$/g, "")
    return /^\d+(\.\d+)?$/.test(trimmed) ? Number(trimmed) : NaN
  }
  return NaN
}

// A finite number (or numeric string) at or above minSeconds is a real delay;
// everything else means "never" (minSeconds lets a probe lower the 60s floor).
// `rejected` flags a positive value that missed the floor, so a caller can log it.
function normalizeSleepSeconds(raw, minSeconds) {
  var floor = minSeconds > 0 ? minSeconds : 60
  var n = sleepRawToNumber(raw)
  if (!isFinite(n) || n < floor) return { seconds: SLEEP_NEVER, clamped: false, rejected: isFinite(n) && n > 0 }
  var capped = Math.min(n, SLEEP_MAX_SECONDS)
  return { seconds: capped, clamped: capped !== n, rejected: false }
}

// The last non-empty stdout line from a login-shell resolver, accepted only
// if it is absolute and actually names the requested binary -- an earlier
// line from a startup file (e.g. a wrong `.bash_profile` echo) is ignored.
function pickResolvedPath(out, name) {
  var lines = String(out || "").split("\n")
  var line = ""
  for (var i = lines.length - 1; i >= 0; i--) {
    var trimmed = lines[i].replace(/^\s+|\s+$/g, "")
    if (trimmed) { line = trimmed; break }
  }
  var suffix = "/" + name
  if (line.charAt(0) !== "/" || line.slice(-suffix.length) !== suffix) return ""
  return line
}

// Fail-safe direction: only an explicit truthy boolean/number/string means
// "really dry run" -- the danger is a string that LOOKS true reading as
// false and producing a real suspend, so everything else stays off.
function normalizeDryRun(raw) {
  return raw === true || raw === "true" || raw === 1 || raw === "1"
}

// ------------------------------------------------------- own settings entry
// A service gets only `shell`, not an injected `settings`, so it looks up
// its own entry: the bar layout for a bar-widget plugin, else plugins[].

// A hostile non-array "length" (e.g. 2e9) in place of one of these
// collections is refused: Array.isArray runs before the length is trusted.

function entryFor(config, id) {
  if (!config) return null
  var layout = config.bar && config.bar.layout ? config.bar.layout : null
  var sections = ["left", "center", "right"]
  if (layout) {
    for (var s = 0; s < sections.length; s++) {
      var raw = layout[sections[s]]
      var arr = Array.isArray(raw) ? raw : []
      for (var i = 0; i < arr.length; i++) if (arr[i] && arr[i].id === id) return arr[i]
    }
  }
  var pluginsRaw = config.plugins
  var plugins = Array.isArray(pluginsRaw) ? pluginsRaw : []
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
