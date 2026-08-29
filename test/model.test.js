// test/model.test.js -- plain-assert Node tests over Model.js. Run:
// node test/model.test.js (exits 0/1). Model.js is `.pragma library` QML,
// so this loads it through a strip-and-eval shim; see docs/developers.md ("Testing").
"use strict"

var assert = require("assert")
var fs = require("fs")
var path = require("path")
var vm = require("vm")

// Beyond-ES5 syntax Node parses fine but the QML engine's baseline does
// not -- a heuristic, not a real parser. Comments are stripped first, so
// a mention inside one can't trip it; see docs/developers.md.
var ES5_TRIPWIRES = [
  ["arrow function (=>)", /=>/],
  ["template literal (`)", /`/],
  ["let", /\blet\b/],
  ["const", /\bconst\b/],
  ["async", /\basync\b/],
  ["class", /\bclass\b/],
  ["spread/rest (...)", /\.\.\./]
]

function loadModel() {
  var file = path.join(__dirname, "..", "Model.js")
  var source = fs.readFileSync(file, "utf8")

  // The pragma is a production requirement (QML shared-library semantics
  // across three importers), not an artifact of this loader -- a missing or
  // edited line 1 must fail loudly, not quietly load as if nothing changed.
  var firstLine = source.split("\n", 1)[0]
  if (!/^\.pragma library[ \t]*$/.test(firstLine)) {
    throw new Error(
      "Model.js loader: expected line 1 to be exactly '.pragma library' " +
      "(trailing whitespace tolerated), found " + JSON.stringify(firstLine) +
      ". Refusing to load: either the pragma was edited or removed from " +
      "Model.js (a real regression -- it loses its shared, read-only " +
      "semantics across QML importers), or this loader's check needs " +
      "updating to match a legitimate change."
    )
  }

  var withoutComments = source.replace(/\/\/.*$/gm, "").replace(/\/\*[\s\S]*?\*\//g, "")
  ES5_TRIPWIRES.forEach(function (t) {
    if (t[1].test(withoutComments)) {
      throw new Error(
        "Model.js loader: source looks like it uses " + t[0] + ", which is " +
        "beyond the QML engine's ES5 baseline -- Node would parse and run " +
        "it fine, then it would fail inside the shell. See the ES5 note in " +
        "docs/developers.md."
      )
    }
  })

  // Same position, so every later line keeps its original line number.
  var stripped = source.replace(/^\.pragma library[ \t]*$/m, "\"use strict\";")
  var sandbox = {}
  vm.createContext(sandbox)
  vm.runInContext(stripped, sandbox, { filename: file })
  return sandbox
}

var Model = loadModel()

// vm-sandbox objects/arrays have a different realm's prototype, so
// assert.deepStrictEqual sees them as unequal even when every value
// matches. A JSON round-trip rehomes plain data into this realm first.
function toPlainObject(value) {
  return JSON.parse(JSON.stringify(value))
}

var passed = 0
var failed = 0
var failures = []

function test(name, fn) {
  try {
    fn()
    passed++
  } catch (e) {
    failed++
    failures.push({ name: name, error: e })
  }
}

// ------------------------------------------------------------ table invariants

// These invariants derive their expectations from the arrays under test,
// so a curated-value edit that preserves ordering passes silently -- the
// next test pins the exact curated values too.
test("SCREENSAVER_STOPS, LOCK_STOPS, SLEEP_STOPS are pinned to their exact curated values", function () {
  assert.deepStrictEqual(toPlainObject(Model.SCREENSAVER_STOPS), [1, 2, 3, 5, 10, 15])
  assert.deepStrictEqual(toPlainObject(Model.LOCK_STOPS), [2, 3, 5, 10, 15, 30])
  assert.deepStrictEqual(toPlainObject(Model.SLEEP_STOPS), [60, 120, 180, 300, 600, -1])
})

test("SCREENSAVER_STOPS is strictly increasing", function () {
  var stops = Model.SCREENSAVER_STOPS
  for (var i = 1; i < stops.length; i++) assert.ok(stops[i] > stops[i - 1], "index " + i + " not strictly greater")
})

test("LOCK_STOPS is strictly increasing", function () {
  var stops = Model.LOCK_STOPS
  for (var i = 1; i < stops.length; i++) assert.ok(stops[i] > stops[i - 1], "index " + i + " not strictly greater")
})

test("LOCK_STOPS max (30) is above SCREENSAVER_STOPS max (15) -- lockIndexAbove always has a stop to land on", function () {
  var lockMax = Model.LOCK_STOPS[Model.LOCK_STOPS.length - 1]
  var ssMax = Model.SCREENSAVER_STOPS[Model.SCREENSAVER_STOPS.length - 1]
  assert.strictEqual(lockMax, 30)
  assert.strictEqual(ssMax, 15)
  assert.ok(lockMax > ssMax)
})

test("LOCK_STOPS min (2) is above SCREENSAVER_STOPS min (1) -- screensaverIndexBelow always has a stop to land on", function () {
  var lockMin = Model.LOCK_STOPS[0]
  var ssMin = Model.SCREENSAVER_STOPS[0]
  assert.strictEqual(lockMin, 2)
  assert.strictEqual(ssMin, 1)
  assert.ok(lockMin > ssMin)
})

test("SLEEP_STOPS: positive stops strictly increasing, last element is SLEEP_NEVER", function () {
  var stops = Model.SLEEP_STOPS
  var positive = stops.slice(0, -1)
  for (var i = 1; i < positive.length; i++) assert.ok(positive[i] > positive[i - 1], "index " + i + " not strictly greater")
  positive.forEach(function (s) { assert.ok(s > 0, "positive stop " + s + " must be > 0") })
  assert.strictEqual(stops[stops.length - 1], Model.SLEEP_NEVER)
  assert.strictEqual(Model.SLEEP_NEVER, -1)
})

// ------------------------------------------------------------------ nearestIndex

test("nearestIndex: exact hit returns that index", function () {
  assert.strictEqual(Model.nearestIndex(Model.SCREENSAVER_STOPS, 5), Model.SCREENSAVER_STOPS.indexOf(5))
  assert.strictEqual(Model.nearestIndex(Model.SCREENSAVER_STOPS, 15), Model.SCREENSAVER_STOPS.indexOf(15))
})

test("nearestIndex: off-scale value on a tie keeps the FIRST best (strict '<', never '<=')", function () {
  // 2.5 is equidistant from 2 (index 1) and 3 (index 2). The loop only
  // replaces `best` on a strictly smaller delta, so the earlier index wins.
  assert.strictEqual(Model.nearestIndex(Model.SCREENSAVER_STOPS, 2.5), 1)
})

test("nearestIndex: value below the minimum snaps to index 0", function () {
  assert.strictEqual(Model.nearestIndex(Model.SCREENSAVER_STOPS, -100), 0)
  assert.strictEqual(Model.nearestIndex(Model.SCREENSAVER_STOPS, 0), 0)
})

test("nearestIndex: value above the maximum snaps to the last index", function () {
  assert.strictEqual(Model.nearestIndex(Model.SCREENSAVER_STOPS, 1000), Model.SCREENSAVER_STOPS.length - 1)
})

// ------------------------------------------------------------------ minutesLabel

test("minutesLabel: singular at 1, plural otherwise", function () {
  assert.strictEqual(Model.minutesLabel(1), "1 minute")
  assert.strictEqual(Model.minutesLabel(2), "2 minutes")
})

// --------------------------------------------------------------------- sleepLabel

test("sleepLabel: never-ish values (-1/0/undefined/NaN) render 'never' in both forms", function () {
  ;[-1, 0, undefined, NaN].forEach(function (v) {
    assert.strictEqual(Model.sleepLabel(v, true), "never")
    assert.strictEqual(Model.sleepLabel(v, false), "never")
  })
})

test("sleepLabel: short form -- whole minutes render as 'N min', off-scale seconds render as 'Ns'", function () {
  assert.strictEqual(Model.sleepLabel(60, true), "1 min")
  assert.strictEqual(Model.sleepLabel(90, true), "90s")
  assert.strictEqual(Model.sleepLabel(600, true), "10 min")
})

test("sleepLabel: long form uses minutesLabel", function () {
  assert.strictEqual(Model.sleepLabel(60, false), "1 minute")
  assert.strictEqual(Model.sleepLabel(120, false), "2 minutes")
})

// ------------------------------------------------------------------- sleepIndexFor

test("sleepIndexFor: -1 and 0 both resolve to the last index (the 'never' stop)", function () {
  var neverIndex = Model.SLEEP_STOPS.length - 1
  assert.strictEqual(Model.sleepIndexFor(-1), neverIndex)
  assert.strictEqual(Model.sleepIndexFor(0), neverIndex)
})

test("sleepIndexFor: each exact positive stop maps to its own index", function () {
  Model.SLEEP_STOPS.slice(0, -1).forEach(function (stop, i) {
    assert.strictEqual(Model.sleepIndexFor(stop), i)
  })
})

test("sleepIndexFor: legacy off-scale value 900 snaps to the nearest positive stop (600), not 'never'", function () {
  var indexOf600 = Model.SLEEP_STOPS.indexOf(600)
  assert.strictEqual(Model.sleepIndexFor(900), indexOf600)
})

test("sleepIndexFor: tiny value 10 snaps to index 0", function () {
  assert.strictEqual(Model.sleepIndexFor(10), 0)
})

test("sleepIndexFor: the 'never' stop can NEVER be returned for a positive value, however far off-scale", function () {
  var neverIndex = Model.SLEEP_STOPS.length - 1
  var indexOf600 = Model.SLEEP_STOPS.indexOf(600)
  assert.strictEqual(Model.sleepIndexFor(10000), indexOf600)
  assert.notStrictEqual(Model.sleepIndexFor(10000), neverIndex)
})

// ------------------------------------------------------- lockIndexAbove / screensaverIndexBelow

test("lockIndexAbove: an already-satisfying current index is returned unchanged", function () {
  // screensaver 2, lock already at index 4 (15) -- satisfied and unchanged.
  // Index 4 is deliberately not the first stop above 2 (index 1, value 3),
  // so an implementation ignoring currentLockIndex would return 1, not 4.
  assert.strictEqual(Model.lockIndexAbove(2, 4), 4)
})

test("lockIndexAbove: equal values are NOT accepted -- lock must move strictly above", function () {
  var lockIndexAt5 = Model.LOCK_STOPS.indexOf(5)
  var moved = Model.lockIndexAbove(5, lockIndexAt5)
  assert.notStrictEqual(moved, lockIndexAt5)
  assert.ok(Model.LOCK_STOPS[moved] > 5)
})

test("screensaverIndexBelow: an already-satisfying current index is returned unchanged", function () {
  // lock 30, screensaver already at index 1 (2) -- satisfied and unchanged.
  // Index 1 is deliberately not what a top-down scan would find (index 5,
  // 15), so ignoring currentScreensaverIndex would return 5, not 1.
  assert.strictEqual(Model.screensaverIndexBelow(30, 1), 1)
})

test("screensaverIndexBelow: equal values are NOT accepted -- screensaver must move strictly below", function () {
  var ssIndexAt5 = Model.SCREENSAVER_STOPS.indexOf(5)
  var moved = Model.screensaverIndexBelow(5, ssIndexAt5)
  assert.notStrictEqual(moved, ssIndexAt5)
  assert.ok(Model.SCREENSAVER_STOPS[moved] < 5)
})

test("lockIndexAbove: exhaustive sweep -- every screensaver stop x every current lock index lands strictly above", function () {
  Model.SCREENSAVER_STOPS.forEach(function (ss) {
    for (var i = 0; i < Model.LOCK_STOPS.length; i++) {
      var idx = Model.lockIndexAbove(ss, i)
      assert.ok(Model.LOCK_STOPS[idx] > ss, "lockIndexAbove(" + ss + ", " + i + ") = " + idx + " (" + Model.LOCK_STOPS[idx] + ") not > " + ss)
    }
  })
})

test("screensaverIndexBelow: exhaustive sweep -- every lock stop x every current screensaver index lands strictly below", function () {
  Model.LOCK_STOPS.forEach(function (lock) {
    for (var i = 0; i < Model.SCREENSAVER_STOPS.length; i++) {
      var idx = Model.screensaverIndexBelow(lock, i)
      assert.ok(Model.SCREENSAVER_STOPS[idx] < lock, "screensaverIndexBelow(" + lock + ", " + i + ") = " + idx + " (" + Model.SCREENSAVER_STOPS[idx] + ") not < " + lock)
    }
  })
})

// -------------------------------------------------------------------- stepFrom

test("stepFrom: steps from the ACTUAL stored value, not a snapped index -- 2.5 on the screensaver scale", function () {
  // Down from 2.5 lands on 2 (index 1), not 1 (index 0) -- a snapped index
  // of 2.5 (which is 2, the nearest stop) would still step down to 1;
  // stepping from the real value 2.5 must not skip over 2 itself.
  assert.strictEqual(Model.stepFrom(Model.SCREENSAVER_STOPS, 2.5, -1), Model.SCREENSAVER_STOPS.indexOf(2))
  assert.strictEqual(Model.stepFrom(Model.SCREENSAVER_STOPS, 2.5, 1), Model.SCREENSAVER_STOPS.indexOf(3))
})

test("stepFrom: from a value equal to a stop (5), up and down skip past 5 itself", function () {
  assert.strictEqual(Model.stepFrom(Model.SCREENSAVER_STOPS, 5, 1), Model.SCREENSAVER_STOPS.indexOf(10))
  assert.strictEqual(Model.stepFrom(Model.SCREENSAVER_STOPS, 5, -1), Model.SCREENSAVER_STOPS.indexOf(3))
})

test("stepFrom: from the top stop, up returns -1 (no stop above)", function () {
  var top = Model.SCREENSAVER_STOPS[Model.SCREENSAVER_STOPS.length - 1]
  assert.strictEqual(Model.stepFrom(Model.SCREENSAVER_STOPS, top, 1), -1)
})

test("stepFrom: from the bottom stop, down returns -1 (no stop below)", function () {
  var bottom = Model.SCREENSAVER_STOPS[0]
  assert.strictEqual(Model.stepFrom(Model.SCREENSAVER_STOPS, bottom, -1), -1)
})

// --------------------------------------------------------------- sleepStepFrom

test("sleepStepFrom: from never (-1 or 0), down lands on 600, up returns null", function () {
  assert.strictEqual(Model.sleepStepFrom(-1, -1), 600)
  assert.strictEqual(Model.sleepStepFrom(0, -1), 600)
  assert.strictEqual(Model.sleepStepFrom(-1, 1), null)
  assert.strictEqual(Model.sleepStepFrom(0, 1), null)
})

test("sleepStepFrom: from 600 (the top positive stop), up rolls over to SLEEP_NEVER", function () {
  assert.strictEqual(Model.sleepStepFrom(600, 1), Model.SLEEP_NEVER)
})

test("sleepStepFrom: from 60 (the bottom positive stop), down returns null", function () {
  assert.strictEqual(Model.sleepStepFrom(60, -1), null)
})

test("sleepStepFrom: legacy off-scale 900 -- up rolls to SLEEP_NEVER, down lands on 600", function () {
  assert.strictEqual(Model.sleepStepFrom(900, 1), Model.SLEEP_NEVER)
  assert.strictEqual(Model.sleepStepFrom(900, -1), 600)
})

test("sleepStepFrom: off-scale 90 -- up lands on 120, down lands on 60", function () {
  assert.strictEqual(Model.sleepStepFrom(90, 1), 120)
  assert.strictEqual(Model.sleepStepFrom(90, -1), 60)
})

// ---------------------------------------------------------- normalizeSleepSeconds

test("normalizeSleepSeconds: SLEEP_MAX_SECONDS is pinned to 86400 (24h, far under the int32-ms limit)", function () {
  assert.strictEqual(Model.SLEEP_MAX_SECONDS, 86400)
})

test("normalizeSleepSeconds: overflow-prone 4294968 clamps to SLEEP_MAX_SECONDS with clamped=true", function () {
  var r = Model.normalizeSleepSeconds(4294968, 60)
  assert.strictEqual(r.seconds, 86400)
  assert.strictEqual(r.clamped, true)
})

test("normalizeSleepSeconds: true (Number(true)===1) is below the floor -- SLEEP_NEVER, not clamped", function () {
  var r = Model.normalizeSleepSeconds(true, 60)
  assert.strictEqual(r.seconds, Model.SLEEP_NEVER)
  assert.strictEqual(r.clamped, false)
})

test("normalizeSleepSeconds: the string \"true\" is not a number -- SLEEP_NEVER", function () {
  var r = Model.normalizeSleepSeconds("true", 60)
  assert.strictEqual(r.seconds, Model.SLEEP_NEVER)
  assert.strictEqual(r.clamped, false)
})

test("normalizeSleepSeconds: 5 is below the 60s floor -- SLEEP_NEVER", function () {
  var r = Model.normalizeSleepSeconds(5, 60)
  assert.strictEqual(r.seconds, Model.SLEEP_NEVER)
  assert.strictEqual(r.clamped, false)
})

test("normalizeSleepSeconds: numeric string \"300\" is accepted at face value", function () {
  var r = Model.normalizeSleepSeconds("300", 60)
  assert.strictEqual(r.seconds, 300)
  assert.strictEqual(r.clamped, false)
})

test("normalizeSleepSeconds: NaN -- SLEEP_NEVER", function () {
  var r = Model.normalizeSleepSeconds(NaN, 60)
  assert.strictEqual(r.seconds, Model.SLEEP_NEVER)
  assert.strictEqual(r.clamped, false)
})

test("normalizeSleepSeconds: a plain object -- SLEEP_NEVER (Number({}) is NaN)", function () {
  var r = Model.normalizeSleepSeconds({}, 60)
  assert.strictEqual(r.seconds, Model.SLEEP_NEVER)
  assert.strictEqual(r.clamped, false)
})

test("normalizeSleepSeconds: -1 (the stored 'never' value) -- SLEEP_NEVER, not clamped", function () {
  var r = Model.normalizeSleepSeconds(-1, 60)
  assert.strictEqual(r.seconds, Model.SLEEP_NEVER)
  assert.strictEqual(r.clamped, false)
})

test("normalizeSleepSeconds: exactly at the floor is accepted", function () {
  var r = Model.normalizeSleepSeconds(60, 60)
  assert.strictEqual(r.seconds, 60)
  assert.strictEqual(r.clamped, false)
})

test("normalizeSleepSeconds: a lower probe-supplied floor accepts a short delay", function () {
  var r = Model.normalizeSleepSeconds(2, 1)
  assert.strictEqual(r.seconds, 2)
  assert.strictEqual(r.clamped, false)
})

test("normalizeSleepSeconds: exactly SLEEP_MAX_SECONDS is accepted, not clamped", function () {
  var r = Model.normalizeSleepSeconds(86400, 60)
  assert.strictEqual(r.seconds, 86400)
  assert.strictEqual(r.clamped, false)
})

test("normalizeSleepSeconds: rejected=true only for a positive value that missed the floor", function () {
  assert.strictEqual(Model.normalizeSleepSeconds(5, 60).rejected, true)
  assert.strictEqual(Model.normalizeSleepSeconds(59, 60).rejected, true)
})

test("normalizeSleepSeconds: rejected=false for an explicit never, zero, non-numeric, or an accepted delay", function () {
  ;[-1, 0, NaN, {}, null, undefined, "true", true, [300]].forEach(function (v) {
    assert.strictEqual(Model.normalizeSleepSeconds(v, 60).rejected, false, "expected rejected=false for " + JSON.stringify(v))
  })
  assert.strictEqual(Model.normalizeSleepSeconds(60, 60).rejected, false)
  assert.strictEqual(Model.normalizeSleepSeconds(300, 60).rejected, false)
})

test("normalizeSleepSeconds: an array raw value is never coerced by Number() -- treated as never, not armed", function () {
  assert.strictEqual(Model.normalizeSleepSeconds([300], 60).seconds, Model.SLEEP_NEVER)
  assert.strictEqual(Model.normalizeSleepSeconds(["300"], 60).seconds, Model.SLEEP_NEVER)
})

test("normalizeSleepSeconds: a plain object or null raw value is never armed", function () {
  assert.strictEqual(Model.normalizeSleepSeconds({}, 60).seconds, Model.SLEEP_NEVER)
  assert.strictEqual(Model.normalizeSleepSeconds(null, 60).seconds, Model.SLEEP_NEVER)
})

test("normalizeSleepSeconds: a numeric string with surrounding whitespace is trimmed and accepted", function () {
  var r = Model.normalizeSleepSeconds(" 300 ", 60)
  assert.strictEqual(r.seconds, 300)
  assert.strictEqual(r.clamped, false)
  assert.strictEqual(r.rejected, false)
})

// ------------------------------------------------------------------ pickResolvedPath

test("pickResolvedPath: a single-line absolute path matching the name is accepted", function () {
  assert.strictEqual(Model.pickResolvedPath("/usr/bin/omarchy-toggle\n", "omarchy-toggle"), "/usr/bin/omarchy-toggle")
})

test("pickResolvedPath: takes the LAST non-empty line, ignoring earlier login-shell output", function () {
  var out = "/bin/false\n/usr/bin/omarchy-toggle\n"
  assert.strictEqual(Model.pickResolvedPath(out, "omarchy-toggle"), "/usr/bin/omarchy-toggle")
})

test("pickResolvedPath: a resolved path for the wrong binary name is rejected", function () {
  assert.strictEqual(Model.pickResolvedPath("/bin/false\n", "omarchy-toggle"), "")
})

test("pickResolvedPath: a relative or empty result is rejected", function () {
  assert.strictEqual(Model.pickResolvedPath("omarchy-toggle\n", "omarchy-toggle"), "")
  assert.strictEqual(Model.pickResolvedPath("", "omarchy-toggle"), "")
  assert.strictEqual(Model.pickResolvedPath("\n\n", "omarchy-toggle"), "")
})

test("pickResolvedPath: trailing whitespace on the last line is trimmed", function () {
  assert.strictEqual(Model.pickResolvedPath("/usr/bin/omarchy-toggle  \n", "omarchy-toggle"), "/usr/bin/omarchy-toggle")
})

test("pickResolvedPath: the longer 'omarchy-toggle-enabled' suffix is not satisfied by the shorter name", function () {
  assert.strictEqual(Model.pickResolvedPath("/usr/bin/omarchy-toggle\n", "omarchy-toggle-enabled"), "")
  assert.strictEqual(Model.pickResolvedPath("/usr/bin/omarchy-toggle-enabled\n", "omarchy-toggle-enabled"), "/usr/bin/omarchy-toggle-enabled")
})

// --------------------------------------------------------------- normalizeDryRun

test("normalizeDryRun: true, \"true\", 1, \"1\" all normalize to true", function () {
  ;[true, "true", 1, "1"].forEach(function (v) {
    assert.strictEqual(Model.normalizeDryRun(v), true, "expected true for " + JSON.stringify(v))
  })
})

test("normalizeDryRun: false, \"false\", 0, \"\", null, undefined, {} all normalize to false", function () {
  ;[false, "false", 0, "", null, undefined, {}].forEach(function (v) {
    assert.strictEqual(Model.normalizeDryRun(v), false, "expected false for " + JSON.stringify(v))
  })
})

// ------------------------------------------------------------------------ entryFor

test("entryFor: hostile non-array collections (a fake 'length') are refused, never trusted", function () {
  var id = "halmylyseas.ristretto"
  var hostile = { length: 2000000000 }
  assert.strictEqual(Model.entryFor({ bar: { layout: { left: hostile, center: [], right: [] } } }, id), null)
  assert.strictEqual(Model.entryFor({ plugins: hostile }, id), null)
})

test("entryFor: null/undefined config returns null", function () {
  assert.strictEqual(Model.entryFor(null, "halmylyseas.ristretto"), null)
  assert.strictEqual(Model.entryFor(undefined, "halmylyseas.ristretto"), null)
})

test("entryFor: finds the entry in bar.layout.left / .center / .right", function () {
  var id = "halmylyseas.ristretto"
  ;["left", "center", "right"].forEach(function (section) {
    var layout = { left: [], center: [], right: [] }
    layout[section] = [{ id: id, sleepAfterIdleLock: 300 }]
    var config = { bar: { layout: layout } }
    var entry = Model.entryFor(config, id)
    assert.ok(entry, "expected an entry in section " + section)
    assert.strictEqual(entry.sleepAfterIdleLock, 300)
  })
})

test("entryFor: falls back to plugins[] when absent from the layout", function () {
  var id = "halmylyseas.ristretto"
  var config = {
    bar: { layout: { left: [], center: [], right: [] } },
    plugins: [{ id: id, dryRun: true }]
  }
  var entry = Model.entryFor(config, id)
  assert.ok(entry)
  assert.strictEqual(entry.dryRun, true)
})

test("entryFor: string-form layout entries do not crash and never match", function () {
  var id = "halmylyseas.ristretto"
  var config = { bar: { layout: { left: [id], center: [], right: [] } } }
  assert.strictEqual(Model.entryFor(config, id), null)
})

test("entryFor: null entries in layout arrays are tolerated", function () {
  var id = "halmylyseas.ristretto"
  var config = { bar: { layout: { left: [null, { id: id, x: 1 }], center: [null], right: [null] } } }
  var entry = Model.entryFor(config, id)
  assert.ok(entry)
  assert.strictEqual(entry.x, 1)
})

test("entryFor: missing bar/layout keys are tolerated, falls through to plugins[]", function () {
  var id = "halmylyseas.ristretto"
  assert.strictEqual(Model.entryFor({}, id), null)
  assert.strictEqual(Model.entryFor({ bar: {} }, id), null)
  assert.strictEqual(Model.entryFor({ bar: { layout: {} } }, id), null)
  var withPlugins = Model.entryFor({ plugins: [{ id: id, y: 2 }] }, id)
  assert.ok(withPlugins)
  assert.strictEqual(withPlugins.y, 2)
})

// ------------------------------------------------------------------ settingFromConfig

test("settingFromConfig: no entry -- returns the fallback", function () {
  assert.strictEqual(Model.settingFromConfig({}, "halmylyseas.ristretto", "dryRun", "FALLBACK"), "FALLBACK")
})

test("settingFromConfig: key absent on the entry -- returns the fallback", function () {
  var config = { plugins: [{ id: "halmylyseas.ristretto" }] }
  assert.strictEqual(Model.settingFromConfig(config, "halmylyseas.ristretto", "dryRun", "FALLBACK"), "FALLBACK")
})

test("settingFromConfig: key explicitly null on the entry -- returns the fallback", function () {
  var config = { plugins: [{ id: "halmylyseas.ristretto", dryRun: null }] }
  assert.strictEqual(Model.settingFromConfig(config, "halmylyseas.ristretto", "dryRun", "FALLBACK"), "FALLBACK")
})

test("settingFromConfig: key explicitly false -- returns false, NOT the fallback (matters for dryRun)", function () {
  var config = { plugins: [{ id: "halmylyseas.ristretto", dryRun: false }] }
  assert.strictEqual(Model.settingFromConfig(config, "halmylyseas.ristretto", "dryRun", true), false)
})

// -------------------------------------------------------------------- mergedSettings

test("mergedSettings: drops the incoming 'id' key", function () {
  var next = Model.mergedSettings({ id: "halmylyseas.ristretto", dryRun: true }, "sleepAfterIdleLock", 300)
  assert.strictEqual(next.id, undefined)
})

test("mergedSettings: preserves sibling keys and sets the new key", function () {
  var current = { id: "halmylyseas.ristretto", dryRun: true, sleepAfterIdleLock: -1 }
  var next = Model.mergedSettings(current, "sleepAfterIdleLock", 300)
  assert.deepStrictEqual(toPlainObject(next), { dryRun: true, sleepAfterIdleLock: 300 })
})

test("mergedSettings: does not mutate the input object", function () {
  var current = { id: "halmylyseas.ristretto", dryRun: true }
  Model.mergedSettings(current, "sleepAfterIdleLock", 300)
  assert.deepStrictEqual(current, { id: "halmylyseas.ristretto", dryRun: true })
})

test("mergedSettings: works with an empty current", function () {
  assert.deepStrictEqual(toPlainObject(Model.mergedSettings({}, "sleepAfterIdleLock", 300)), { sleepAfterIdleLock: 300 })
})

test("mergedSettings: defensive on missing current, never throws", function () {
  assert.deepStrictEqual(toPlainObject(Model.mergedSettings(null, "sleepAfterIdleLock", 300)), { sleepAfterIdleLock: 300 })
  assert.deepStrictEqual(toPlainObject(Model.mergedSettings(undefined, "sleepAfterIdleLock", 300)), { sleepAfterIdleLock: 300 })
})

// ------------------------------------------------------------------------ summary

console.log("")
console.log(passed + " passed, " + failed + " failed")
if (failed > 0) {
  failures.forEach(function (f) {
    console.log("")
    console.log("FAIL: " + f.name)
    console.log(f.error && f.error.stack ? f.error.stack : String(f.error))
  })
  process.exit(1)
}
process.exit(0)
