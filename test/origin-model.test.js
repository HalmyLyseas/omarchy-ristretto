const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')

const source = fs.readFileSync(require.resolve('../OriginModel.js'), 'utf8')
assert.equal(source.split('\n')[0], '.pragma library')
const context = { module: { exports: {} }, exports: {}, isFinite, Infinity }
vm.runInNewContext(source.replace('.pragma library', '"use strict";'), context)
const Model = context.module.exports

const cfg = { phaseTimeoutMs: 500, historyMs: 1000, maxHistory: 4, clockToleranceMs: 10 }
const raw = (s, wallMs, monoMs) => Model.recordIdle(s, { wallMs, monoMs, idle: true }, cfg)
function normal() {
  let s = Model.createState()
  s = Model.recordIdle(s, { wallMs: 0, monoMs: 0, idle: true }, cfg)
  s = Model.applyEvent(s, { type: 'idle-announcement', reason: 'lock-timeout', wallMs: 100 }, cfg)
  s = Model.applyEvent(s, { type: 'idle-process-start', wallMs: 110 }, cfg)
  s = Model.applyEvent(s, { type: 'lock-request', wallMs: 120 }, cfg)
  s = Model.applyEvent(s, { type: 'session-locked', value: true, wallMs: 121 }, cfg)
  s = Model.applyEvent(s, { type: 'secure', value: true, wallMs: 122 }, cfg)
  return s
}

test('parser pins the captured qs host grammar and exact event body', () => {
  const announcement = Model.parseHostLine(' DEBUG qml: omarchy idle 2026-09-08T21:33:41.743Z lock-system: lock-timeout')
  assert.equal(announcement.source, 'idle'); assert.equal(announcement.kind, 'lock-system')
  assert.equal(announcement.text, 'lock-timeout'); assert.equal(announcement.type, 'idle-announcement')
  assert.equal(announcement.reason, 'lock-timeout'); assert.equal(announcement.wallMs, Date.parse(announcement.timestamp))
  const secure = Model.parseHostLine(' DEBUG qml: omarchy lock 2026-09-08T21:33:42.743Z secure=true')
  assert.equal(secure.type, 'secure'); assert.equal(secure.value, true); assert.equal(secure.timestamp, '2026-09-08T21:33:42.743Z')
  assert.equal(Model.parseHostLine('DEBUG qml: omarchy idle 2026-09-08T21:33:41.743Z lock-system: lock-timeout').type, 'idle-announcement')
  assert.equal(Model.parseHostLine(' DEBUG qml: omarchy idle lock-system lock-timeout'), null)
  assert.equal(Model.parseHostLine(' DEBUG qml: omarchy idle 2026-09-08T21:33:41.743Z lock-system: lock-timeout\n'), null)
})

test('normal idle lock creates a token and is eligible', () => {
  const s = normal()
  assert.equal(Model.isEligible(s), true)
  assert.ok(s.token)
})

test('manual request, missing spawn, failed spawn, and duplicate request invalidate', () => {
  let s = Model.recordIdle(Model.createState(), { wallMs: 0, monoMs: 0, idle: true }, cfg)
  s = Model.applyEvent(s, { type: 'lock-request', wallMs: 1 }, cfg)
  assert.equal(Model.isEligible(s), false)
  s = normal()
  const token = s.token
  s = Model.applyEvent(s, { type: 'lock-request', wallMs: 130 }, cfg)
  assert.equal(s.token, null); assert.notEqual(s.token, token)
  s = Model.recordIdle(Model.createState(), { wallMs: 0, monoMs: 0, idle: true }, cfg)
  s = Model.applyEvent(s, { type: 'idle-announcement', reason: 'lock-timeout', wallMs: 1 }, cfg)
  s = Model.applyEvent(s, { type: 'idle-process-start', wallMs: 2 }, cfg)
  s = Model.applyEvent(s, { type: 'idle-process-exit', wallMs: 3 }, cfg)
  assert.equal(Model.isEligible(s), false)
})

test('recent input rejects origin, while long unchanged idle remains known', () => {
  let s = Model.createState()
  s = Model.recordIdle(s, { wallMs: 0, monoMs: 0, idle: true }, cfg)
  s = Model.recordIdle(s, { wallMs: 90, monoMs: 90, idle: false }, cfg)
  s = Model.applyEvent(s, { type: 'idle-announcement', reason: 'lock-timeout', wallMs: 100 }, cfg)
  assert.equal(Model.isEligible(s), false)
  s = Model.createState()
  s = Model.recordIdle(s, { wallMs: 0, monoMs: 0, idle: true }, cfg)
  s = Model.recordIdle(s, { wallMs: 500, monoMs: 500, idle: true }, cfg)
  assert.equal(Model.reconstructIdle(s.history, 600, cfg), true)
})

test('announcement uses state strictly before its timestamp and rejects equal milliseconds', () => {
  let s = Model.recordIdle(Model.createState(), { wallMs: 100, monoMs: 100, idle: true }, cfg)
  s = Model.applyEvent(s, { type: 'idle-announcement', reason: 'lock-timeout', wallMs: 100 }, cfg)
  assert.equal(s.candidate, null)
})

test('delayed raw reset after announcement cannot change the recorded origin', () => {
  let s = Model.recordIdle(Model.createState(), { wallMs: 0, monoMs: 0, idle: true }, cfg)
  s = Model.applyEvent(s, { type: 'idle-announcement', reason: 'lock-timeout', wallMs: 100 }, cfg)
  s = Model.recordIdle(s, { wallMs: 101, monoMs: 101, idle: false }, cfg)
  assert.equal(s.candidate.originIdle, true)
})

test('secure alone never qualifies; post-secure process exit preserves token', () => {
  let s = Model.recordIdle(Model.createState(), { wallMs: 0, monoMs: 0, idle: true }, cfg)
  s = Model.applyEvent(s, { type: 'session-locked', value: true, wallMs: 121 }, cfg)
  s = Model.applyEvent(s, { type: 'secure', value: true, wallMs: 122 }, cfg)
  assert.equal(Model.isEligible(s), false)
  s = normal(); const token = s.token
  s = Model.applyEvent(s, { type: 'idle-process-exit', wallMs: 200 }, cfg)
  assert.equal(s.token, token); assert.equal(Model.isEligible(s), true)
})

test('unlock, stay-awake, duplicate request, and relock cannot revive a token', () => {
  let s = normal(); const token = s.token
  s = Model.applyEvent(s, { type: 'unlocked' }, cfg)
  assert.equal(s.token, null); assert.equal(Model.isEligible(s), false)
  s = Model.applyEvent(s, { type: 'stay-awake', enabled: true }, cfg)
  assert.equal(s.token, null)
  s = normal(); s = Model.applyEvent(s, { type: 'stay-awake', enabled: true }, cfg)
  assert.equal(s.token, null); assert.equal(Model.isEligible(s), false)
  assert.notEqual(s.token, token)
})

test('generation change, stale/future events, and clock jump invalidate state', () => {
  let s = normal(); s = Model.applyEvent(s, { type: 'generation', generation: 2 }, cfg)
  assert.equal(s.token, null); assert.equal(s.locked, false)
  s = Model.applyEvent(s, { type: 'idle-announcement', generation: 1, reason: 'lock-timeout', wallMs: 10 }, cfg)
  assert.equal(s.candidate, null)
  let h = raw(Model.createState(), 0, 0)
  h = Model.recordIdle(h, { wallMs: 100, monoMs: 200, idle: true }, cfg)
  assert.equal(h.invalidReason, 'clock discontinuity')
  assert.equal(Model.reconstructIdle(h.history, 50, cfg), null)
})

test('history is bounded and preserves a baseline; unknown future records reject', () => {
  let s = Model.createState()
  for (let i = 0; i < 10; i++) s = Model.recordIdle(s, { wallMs: i * 100, monoMs: i * 100, idle: true }, cfg)
  assert.ok(s.history.length <= cfg.maxHistory)
  assert.equal(Model.reconstructIdle(s.history, 950, cfg), true)
  assert.equal(Model.reconstructIdle(s.history, 10000, cfg), true)
})

test('parsed host trace reduces to an eligible idle origin', () => {
  let s = Model.recordIdle(Model.createState(), { wallMs: 1000, monoMs: 1000, idle: true }, cfg)
  const lines = [
    ' DEBUG qml: omarchy idle 1970-01-01T00:00:01.100Z lock-system: lock-timeout',
    ' DEBUG qml: omarchy idle 1970-01-01T00:00:01.110Z process-start: lock',
    ' DEBUG qml: omarchy lock 1970-01-01T00:00:01.120Z lock-requested',
    ' DEBUG qml: omarchy lock 1970-01-01T00:00:01.121Z session-locked=true',
    ' DEBUG qml: omarchy lock 1970-01-01T00:00:01.122Z secure=true'
  ]
  for (const line of lines) s = Model.applyEvent(s, Model.parseHostLine(line), cfg)
  assert.equal(Model.isEligible(s), true)
})

test('secure edge supplies locked evidence when host omits session-locked event', () => {
  let s = Model.recordIdle(Model.createState(), { wallMs: 1000, monoMs: 1000, idle: true }, cfg)
  const lines = [
    ' DEBUG qml: omarchy idle 1970-01-01T00:00:01.100Z lock-system: lock-timeout',
    ' DEBUG qml: omarchy idle 1970-01-01T00:00:01.110Z process-start: lock',
    ' DEBUG qml: omarchy lock 1970-01-01T00:00:01.120Z lock-requested',
    ' DEBUG qml: omarchy lock 1970-01-01T00:00:01.122Z secure=true'
  ]
  for (const line of lines) s = Model.applyEvent(s, Model.parseHostLine(line), cfg)
  assert.equal(s.locked, true)
  assert.equal(Model.isEligible(s), true)
})

test('successful lock helper exit before secure does not cancel the origin attempt', () => {
  let s = Model.recordIdle(Model.createState(), { wallMs: 1000, monoMs: 1000, idle: true }, cfg)
  const lines = [
    ' DEBUG qml: omarchy idle 1970-01-01T00:00:01.100Z lock-system: lock-timeout',
    ' DEBUG qml: omarchy idle 1970-01-01T00:00:01.110Z process-start: lock omarchy-system-lock',
    ' DEBUG qml: omarchy lock 1970-01-01T00:00:01.120Z lock-requested',
    ' DEBUG qml: omarchy idle 1970-01-01T00:00:01.130Z process-exit: lock exitCode=0 status=0',
    ' DEBUG qml: omarchy lock 1970-01-01T00:00:01.158Z secure=true'
  ]
  for (const line of lines) s = Model.applyEvent(s, Model.parseHostLine(line), cfg)
  assert.equal(Model.isEligible(s), true)
  const parsed = Model.parseHostLine(lines[3])
  assert.equal(parsed.exitCode, 0); assert.equal(parsed.exitStatus, 0)
})

test('requested-phase failed or malformed process exit cancels before secure', () => {
  function setup() {
    let s = Model.recordIdle(Model.createState(), { wallMs: 1000, monoMs: 1000, idle: true }, cfg)
    s = Model.applyEvent(s, Model.parseHostLine(' DEBUG qml: omarchy idle 1970-01-01T00:00:01.100Z lock-system: lock-timeout'), cfg)
    s = Model.applyEvent(s, Model.parseHostLine(' DEBUG qml: omarchy idle 1970-01-01T00:00:01.110Z process-start: lock'), cfg)
    return Model.applyEvent(s, Model.parseHostLine(' DEBUG qml: omarchy lock 1970-01-01T00:00:01.120Z lock-requested'), cfg)
  }
  let failed = Model.applyEvent(setup(), Model.parseHostLine(' DEBUG qml: omarchy idle 1970-01-01T00:00:01.130Z process-exit: lock exitCode=1 status=0'), cfg)
  failed = Model.applyEvent(failed, Model.parseHostLine(' DEBUG qml: omarchy lock 1970-01-01T00:00:01.140Z secure=true'), cfg)
  assert.equal(Model.isEligible(failed), false)
  let malformed = Model.applyEvent(setup(), Model.parseHostLine(' DEBUG qml: omarchy idle 1970-01-01T00:00:01.130Z process-exit: lock exitCode=0'), cfg)
  malformed = Model.applyEvent(malformed, Model.parseHostLine(' DEBUG qml: omarchy lock 1970-01-01T00:00:01.140Z secure=true'), cfg)
  assert.equal(Model.isEligible(malformed), false)
  let badStatus = Model.applyEvent(setup(), Model.parseHostLine(' DEBUG qml: omarchy idle 1970-01-01T00:00:01.130Z process-exit: lock exitCode=0 status=1'), cfg)
  badStatus = Model.applyEvent(badStatus, Model.parseHostLine(' DEBUG qml: omarchy lock 1970-01-01T00:00:01.140Z secure=true'), cfg)
  assert.equal(Model.isEligible(badStatus), false)

  let late = Model.applyEvent(setup(), Model.parseHostLine(' DEBUG qml: omarchy idle 1970-01-01T00:00:01.130Z process-exit: lock exitCode=0 status=0'), cfg)
  late = Model.applyEvent(late, Model.parseHostLine(' DEBUG qml: omarchy lock 1970-01-01T00:00:04.200Z secure=true'), cfg)
  assert.equal(Model.isEligible(late), false)
})

test('typed parser rejects screensaver spawn and handles false lock state', () => {
  assert.equal(Model.parseHostLine(' DEBUG qml: omarchy idle 1970-01-01T00:00:01.110Z process-start: screensaver'), null)
  const unlocked = Model.parseHostLine(' DEBUG qml: omarchy lock 1970-01-01T00:00:01.121Z session-locked=false')
  assert.equal(unlocked.type, 'session-locked'); assert.equal(unlocked.value, false)
  const request = Model.parseHostLine(' DEBUG qml: omarchy lock 1970-01-01T00:00:01.120Z lock-requested')
  assert.equal(request.type, 'lock-request'); assert.equal(request.text, '')
})

test('stale announcements are rejected at application time and secure phase times out', () => {
  let s = Model.recordIdle(Model.createState(), { wallMs: 1000, monoMs: 1000, idle: true }, cfg)
  const announcement = { type: 'idle-announcement', reason: 'lock-timeout', wallMs: 1100 }
  s = Model.applyEvent(s, announcement, { phaseTimeoutMs: 500, freshnessMs: 50, nowWallMs: 1200 })
  assert.equal(s.candidate, null)
  s = Model.applyEvent(Model.recordIdle(Model.createState(), { wallMs: 1000, monoMs: 1000, idle: true }, cfg), announcement, cfg)
  s = Model.applyEvent(s, { type: 'idle-process-start', wallMs: 1110 }, cfg)
  s = Model.applyEvent(s, { type: 'lock-request', wallMs: 1120 }, cfg)
  s = Model.applyEvent(s, { type: 'session-locked', value: true, wallMs: 1121 }, cfg)
  s = Model.applyEvent(s, { type: 'secure', value: true, wallMs: 2000 }, { phaseTimeoutMs: 500 })
  assert.equal(Model.isEligible(s), false)
})

test('a secure token remains valid during a long countdown with fresh stream evidence', () => {
  let s = normal()
  s = Model.applyEvent(s, { type: 'raw-idle', wallMs: 10000, monoMs: 10000, idle: true }, cfg)
  assert.equal(Model.isEligible(s, { nowWallMs: 1000000 }), true)
})

test('parsed session-locked=false immediately invalidates a secure token', () => {
  let s = normal()
  const token = s.token
  const line = ' DEBUG qml: omarchy lock 1970-01-01T00:00:01.123Z session-locked=false'
  const event = Model.parseHostLine(line)
  assert.equal(event.type, 'session-locked')
  assert.equal(event.value, false)
  s = Model.applyEvent(s, event, cfg)
  assert.equal(s.locked, false)
  assert.equal(s.secure, false)
  assert.equal(s.token, null)
  assert.notEqual(s.token, token)
  assert.equal(Model.isEligible(s), false)
})

test('stay-awake suffix and service recreation are parsed as invalidating events', () => {
  const stay = Model.parseHostLine(' DEBUG qml: omarchy idle 1970-01-01T00:00:01.200Z stay-awake: enabled ipc')
  assert.equal(stay.type, 'stay-awake'); assert.equal(stay.enabled, true)
  const ready = Model.parseHostLine(' DEBUG qml: omarchy idle 1970-01-01T00:00:01.201Z service-ready')
  assert.equal(ready.type, 'service-ready')
  assert.equal(Model.applyEvent(normal(), ready, cfg).token, null)
})
