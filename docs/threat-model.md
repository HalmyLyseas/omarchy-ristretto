# Threat model

Scope: `halmylyseas.ristretto`, an Omarchy shell plugin that suspends the
machine after an idle lock. See `CLAUDE.md` for the hard rules this model
assumes are enforced, and `docs/developers.md` for architecture detail.

## Assets

- **The machine must never suspend on a lock the user triggered
  themselves** — by a keybinding, the menu, or `omarchy lock` — however
  idle the user happens to be at that moment.
- **The machine must never suspend on a lock that is not secure** — a
  session-lock request with no real lock screen behind it yet.
- **The only things this plugin ever writes are:** its own `shell.json`
  bar-widget entry; the shared `idle.screensaver`/`idle.lock` keys, through
  the two delay sliders and the host's own config API; and the
  `screensaver-off` flag file, plus the one-time `mkdir -p` of its parent
  toggles directory.

## Trust boundaries and their guard

| Boundary | Guarded by |
|---|---|
| Host `lastEvent`/`locked`/`pendingSessionLock` (`omarchy.idle`/`omarchy.lock`) | The two-step latch on `lastEvent` (eligibility) plus `originIdleAtAnnounce` — `originIdleSource.isIdle` sampled synchronously at the `lock-system` announcement, before the lock's own spawn can touch the notifier (origin) — both must hold before `suspend()` is ever reachable. `pendingSessionLock` holds `secureLocked` false: a request with no real screen behind it can never arm. |
| `shell.json` values (`sleepAfterIdleLock`, `dryRun`, the idle entry) | `Model.normalizeSleepSeconds()`/`Model.normalizeDryRun()` and the `Array.isArray` guards in `Model.entryFor()` — a hostile or hand-edited value fails toward "never suspend", never toward a shorter or real one. |
| Tool binaries (`omarchy-toggle`, `omarchy-toggle-enabled`) | Resolved once via `bash -lc "type -P <bin>"`, accepted only as an absolute path; every spawn after that is a direct `Process` child (never a shell string) with its own watchdog/kill pair. |
| `systemctl suspend` | The plugin's one declared service-management capability — reachable only once the latch, origin, and secure-edge checks above all hold; `dryRun` swaps it for a log line and a notification. |
| `~/.local/state/omarchy/toggles/` (user-writable state) | `togglesWatch`'s `FileView` never preloads, so a large or symlinked file at that path is never read into shell memory; only its change events are used. |

## What the plugin cannot do

- It cannot suspend the machine without both an idle-originated lock and a
  confirmed secure edge; a lock triggered by the user's own input, however
  it happened, can never pass the origin check.
- It cannot modify anything under `/usr/share/omarchy/` (`CLAUDE.md` rule
  1). Every write it makes is one of the three named above, through
  `updateEntryInline`/`mutateShellConfig` or the resolved `omarchy-toggle`.
- It cannot run any tool through a shell string with variable content --
  every spawn is a fixed argv array.

## Residual risks

- **`lastEvent` is a free-form log mirror.** The eligibility latch reads
  two adjacent event strings off it; a host wording change would silently
  stop the latch from arming (no suspend on a real idle lock), but can
  never cause a manual lock to arm one, since the origin check does not
  depend on that wording.
- **A programmatic manual lock issued while the user genuinely is idle**
  (no keyboard/mouse input, but the lock was not idle-triggered) passes
  the origin check the same way a real idle lock would, because the check
  can only observe input, not intent. Accepted: the bias is toward never
  missing a real idle lock's origin at the cost of this narrow edge case.
- **A keypress-triggered manual lock landing in the sub-second window
  between an in-flight idle lock's `lock-system` announcement and its own
  edge could inherit that idle lock's sample.** Narrow: the announcement
  and the secure edge are normally milliseconds apart, and a bound user
  who wins this race still only gets the delay already configured, with
  every unlock cancelling the countdown outright — the 60s+ minimum gap
  to the next idle lock and the unlock-cancels rule bound the harm.
- **The screensaver switch's optimistic write can briefly disagree with
  the watcher.** A flip is applied to the UI before the write completes,
  and reconciled on exit if it failed; a rapid second click during that
  window is queued, not lost, but the switch may show a stale value for
  one write's duration. Cosmetic only — no security control depends on it.

## Out of scope

- Compromise of `omarchy.idle`/`omarchy.lock` themselves, the Omarchy
  shell process, or the user's session/login.
- Supply-chain integrity of the installed `omarchy` package or its
  `omarchy-toggle*` binaries — this plugin trusts what is already
  installed on the machine.
- Physical or local access, kernel-level attacks, or anything not
  reachable through this plugin's own settings, log-mirror reads, or
  process-argv surface.
