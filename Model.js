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
