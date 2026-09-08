.pragma library

var ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/
var DEFAULTS = { maxHistory: 256, historyMs: 120000, clockToleranceMs: 100,
  phaseTimeoutMs: 3000, freshnessMs: 120000, maxEventText: 160 }

function optionsOf(input) {
  var result = {}, key, source = input || {}
  for (key in DEFAULTS)
    result[key] = source[key] === undefined ? DEFAULTS[key] : source[key]
  return result
}
function finite(value) { return typeof value === "number" && isFinite(value) }
function booleanValue(value) { return value === true || value === false }
function copyHistory(history) {
  var result = [], i, record
  for (i = 0; i < (history || []).length; i++) {
    record = history[i]
    result.push({ wallMs: record.wallMs, monoMs: record.monoMs,
      idle: record.idle, known: record.known === true })
  }
  return result
}
function copyCandidate(candidate) {
  if (!candidate) return null
  return { sequence: candidate.sequence, phase: candidate.phase,
    announcedAt: candidate.announcedAt, spawnedAt: candidate.spawnedAt,
    requestedAt: candidate.requestedAt, securedAt: candidate.securedAt,
    originIdle: candidate.originIdle === true }
}
function createState(generation, nextSequence) {
  return { generation: finite(generation) ? generation : 0,
    nextSequence: finite(nextSequence) && nextSequence > 0 ? nextSequence : 1, history: [], candidate: null,
    locked: false, secure: false, stayAwake: false, eligible: false,
    token: null, invalidReason: "" }
}
function cloneState(state) {
  var source = state || createState()
  return { generation: source.generation, nextSequence: source.nextSequence || 1,
    history: copyHistory(source.history), candidate: copyCandidate(source.candidate),
    locked: source.locked === true, secure: source.secure === true,
    stayAwake: source.stayAwake === true, eligible: source.eligible === true,
    token: source.token || null, invalidReason: source.invalidReason || "" }
}
function clearCandidate(state, reason) {
  state.candidate = null; state.eligible = false; state.token = null
  state.invalidReason = reason || "cancelled"
  return state
}
function invalidate(state, reason) {
  clearCandidate(state, reason); state.history = []
  state.locked = false; state.secure = false
  return state
}

function recordIdle(state, sample, options) {
  var config = optionsOf(options), next = cloneState(state)
  var history = copyHistory(next.history), last = history.length ? history[history.length - 1] : null
  var wallDelta, monoDelta, cutoff
  if (!sample || !finite(sample.wallMs) || !finite(sample.monoMs) || !booleanValue(sample.idle))
    return invalidate(next, "unknown history")
  if (last) {
    wallDelta = sample.wallMs - last.wallMs
    monoDelta = sample.monoMs - last.monoMs
    if (wallDelta < 0 || monoDelta < 0 ||
        Math.abs(wallDelta - monoDelta) > config.clockToleranceMs)
      return invalidate(next, "clock discontinuity")
  }
  history.push({ wallMs: sample.wallMs, monoMs: sample.monoMs,
    idle: sample.idle, known: true })
  cutoff = sample.wallMs - config.historyMs
  while (history.length > config.maxHistory ||
      (history.length > 1 && history[1].wallMs < cutoff)) history.shift()
  next.history = history
  return next
}
function reconstructIdle(history, wallMs) {
  var previous = null, i, record
  if (!finite(wallMs) || !Array.isArray(history) || !history.length) return null
  for (i = 0; i < history.length; i++) {
    record = history[i]
    if (!finite(record.wallMs) || !booleanValue(record.idle) || record.known !== true) return null
    if (record.wallMs === wallMs) return null
    if (record.wallMs > wallMs) break
    previous = record
  }
  return previous ? previous.idle : null
}

function parseHostLine(line) {
  var outer, timestamp, body, match, text, result
  if (typeof line !== "string" || line.length > 4096 || /[\r\n]$/.test(line)) return null
  outer = line.match(/^\s*(?:DEBUG|INFO) qml: omarchy (idle|lock) (.*)$/)
  if (!outer) return null
  timestamp = outer[2].match(/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z) (.*)$/)
  if (!timestamp || !ISO_RE.test(timestamp[1])) return null
  body = timestamp[2]
  if (outer[1] === "idle")
    match = body.match(/^(lock-system|process-start|process-exit|process-skip|stay-awake): ?(.*)$/) ||
      body.match(/^(service-ready)$/)
  else
    match = body.match(/^(lock-requested|unlocked)$/) ||
      body.match(/^(session-locked|secure)=(true|false)$/)
  if (!match) return null
  text = match[2] === undefined ? "" : match[2]
  if (text.length > DEFAULTS.maxEventText) text = text.slice(0, DEFAULTS.maxEventText)
  result = { source: outer[1], kind: match[1], text: text,
    timestamp: timestamp[1], wallMs: Date.parse(timestamp[1]) }
  if (outer[1] === "idle" && match[1] === "lock-system" &&
      (text === "lock-timeout" || text === "lock-timeout-immediate")) {
    result.type = "idle-announcement"; result.reason = text
  } else if (outer[1] === "idle" && match[1] === "process-start" && /^lock(?:\s|$)/.test(text)) {
    result.type = "idle-process-start"
  } else if (outer[1] === "idle" && match[1] === "process-exit" && /^lock(?:\s|$)/.test(text)) {
    result.type = "idle-process-exit"
    var exit = text.match(/^lock exitCode=(\d+) status=(\d+)$/)
    if (exit) {
      result.exitCode = Number(exit[1])
      result.exitStatus = Number(exit[2])
    }
  } else if (outer[1] === "idle" && match[1] === "process-skip" && /^lock(?:\s|$)/.test(text)) {
    result.type = "idle-process-skip"
  } else if (outer[1] === "idle" && match[1] === "stay-awake") {
    result.type = "stay-awake"; result.enabled = /^enabled(?:\s|$)/.test(text)
  } else if (outer[1] === "idle" && match[1] === "service-ready") {
    result.type = "service-ready"
  } else if (outer[1] === "lock" && match[1] === "lock-requested") {
    result.type = "lock-request"
  } else if (outer[1] === "lock" && match[1] === "session-locked") {
    result.type = "session-locked"; result.value = text === "true"
  } else if (outer[1] === "lock" && match[1] === "secure") {
    result.type = "secure"; result.value = text === "true"
  } else if (outer[1] === "lock" && match[1] === "unlocked") {
    result.type = "unlocked"
  } else return null
  return result
}
function eventTime(event) {
  if (finite(event.wallMs)) return event.wallMs
  return typeof event.timestamp === "string" && ISO_RE.test(event.timestamp) ? Date.parse(event.timestamp) : NaN
}
function within(now, then, limit) { return finite(now) && finite(then) && now >= then && now - then <= limit }
function applyEvent(state, event, options) {
  var config = optionsOf(options), next = cloneState(state), time, candidate, verdict
  if (!event || typeof event !== "object") return invalidate(next, "unknown event")
  if (event.type === "generation") {
    if (!finite(event.generation) || event.generation <= next.generation) return invalidate(next, "generation")
    next.generation = event.generation; next.history = []; next.locked = false; next.secure = false
    return clearCandidate(next, "reconnect")
  }
  if (event.generation !== undefined && (!finite(event.generation) || event.generation !== next.generation))
    return invalidate(next, "old generation")
  time = eventTime(event)
  if (!finite(time)) return invalidate(next, "invalid event clock")
  if (options && options.nowWallMs !== undefined &&
      (!finite(options.nowWallMs) || time > options.nowWallMs ||
       options.nowWallMs - time > config.freshnessMs))
    return invalidate(next, "stale event")
  if (event.type === "raw-idle") return recordIdle(next, event, config)
  if (event.type === "service-ready") return invalidate(next, "service recreation")
  if (event.type === "stay-awake") {
    if (!booleanValue(event.enabled)) return invalidate(next, "invalid stay-awake")
    next.stayAwake = event.enabled
    return event.enabled ? clearCandidate(next, "stay-awake") : next
  }
  if (event.type === "unlocked") { next.locked = false; next.secure = false; return clearCandidate(next, "unlocked") }
  if (event.type === "session-locked") {
    if (!booleanValue(event.value)) return invalidate(next, "invalid lock state")
    if (event.value === false) { next.locked = false; next.secure = false; return clearCandidate(next, "unlocked") }
    next.locked = true; return next
  }
  if (event.type === "secure") {
    if (!booleanValue(event.value)) return invalidate(next, "invalid secure state")
    next.secure = event.value
    if (event.value === false) return clearCandidate(next, "insecure")
    candidate = next.candidate
    if (candidate && candidate.phase === "requested" &&
        within(time, candidate.requestedAt, config.phaseTimeoutMs) && !next.stayAwake) {
      // Some 4.0.3 sessions do not emit session-locked=true. The secure edge
      // is authoritative only after the complete origin request chain.
      next.locked = true
      candidate.phase = "secure"; candidate.securedAt = time; next.candidate = candidate
      next.eligible = true; next.token = "g" + next.generation + "-" + candidate.sequence
    }
    return next
  }
  if (event.type === "idle-announcement") {
    if (event.reason !== "lock-timeout" && event.reason !== "lock-timeout-immediate")
      return clearCandidate(next, "unrelated announcement")
    verdict = reconstructIdle(next.history, time)
    if (next.locked || next.stayAwake || verdict !== true) return clearCandidate(next, "origin unknown")
    next.candidate = { sequence: next.nextSequence++, phase: "announced",
      announcedAt: time, originIdle: true }
    next.eligible = false; next.token = null; next.invalidReason = ""
    return next
  }
  if (event.type === "idle-process-start") {
    candidate = next.candidate
    if (!candidate || candidate.phase !== "announced" ||
        !within(time, candidate.announcedAt, config.phaseTimeoutMs)) return clearCandidate(next, "spawn mismatch")
    candidate.phase = "spawned"; candidate.spawnedAt = time; next.candidate = candidate; return next
  }
  if (event.type === "lock-request") {
    candidate = next.candidate
    if (!candidate || candidate.phase !== "spawned" ||
        !within(time, candidate.spawnedAt, config.phaseTimeoutMs)) return clearCandidate(next, "manual or duplicate request")
    candidate.phase = "requested"; candidate.requestedAt = time; next.candidate = candidate; return next
  }
  if (event.type === "idle-process-exit" || event.type === "idle-process-skip") {
    if (event.type === "idle-process-exit" && next.candidate &&
        next.candidate.phase === "requested" && event.exitCode === 0 && event.exitStatus === 0)
      return next
    if (next.candidate && next.candidate.phase !== "secure") return clearCandidate(next, "spawn failed")
    return next
  }
  return next
}
function isEligible(state, options) {
  var candidate = state && state.candidate
  if (!state || !state.eligible || !state.token || !state.locked || !state.secure ||
      state.stayAwake || !candidate || !candidate.originIdle) return false
  if (options && options.nowWallMs !== undefined &&
      (!finite(options.nowWallMs) || options.nowWallMs < candidate.securedAt)) return false
  return true
}
var exported = { createState: createState, recordIdle: recordIdle,
  reconstructIdle: reconstructIdle, parseHostLine: parseHostLine,
  applyEvent: applyEvent, isEligible: isEligible }
if (typeof module !== "undefined") module.exports = exported
