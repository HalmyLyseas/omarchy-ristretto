# Developer notes

The distilled why and how of this plugin, for a contributor starting from
a bare clone. The README covers using it; `CLAUDE.md` carries the project
rules; `docs/threat-model.md` carries the asset/boundary model.

## Architecture

| File | Role |
|---|---|
| `Service.qml` | The suspend state machine, and the owner of every machine-wide watcher (the screensaver flag probe + directory watch live here). Loaded once by the shell. |
| `BarWidget.qml` | The bar button. Hosts the panel through an eagerly-active Loader — the first-party pattern (clock, weather). One instance **per monitor**. |
| `Panel.qml` | The UI. Binds host-derived state; writes through the shell's config API; owns nothing global. |
| `Model.js` | Pure logic: stop arrays, the clamp, snapping, keyboard steps, config normalization. Testable without a running shell. |
| `RistrettoIcon.qml` | The mark as a Qt Quick Shape on a 24-unit grid. `steam: bool` — the curls render only while stay-awake is on. |

The split rule: **panels exist once per monitor, so anything singleton —
watchers, processes, timers — belongs in the service**, and panels bind it
via `shell.serviceFor("halmylyseas.ristretto")`. `BarWidget.qml`/
`Panel.qml` expose a handful of `_debug*` read-only aliases (the panel's
content item, the loaded panel instance, the three timers' `running`
state) for the probe harnesses below; production code never reads them.

## Decisions that look odd until you know why

- **A manual lock never leads to suspend.** Two independent checks. The
  first is eligibility: a two-step latch on `omarchy.idle`'s `lastEvent` —
  the only origin-carrying signal the host exposes (`lockRequested` is set
  for every lock; `idledThisCycle` is already cleared when the lock
  lands). `lock-system` only announces; the latch sets when the same
  synchronous `lockSystem()` call follows it with `process-start: lock`,
  confirming a spawn. Anything else drops the announcement, a
  `process-exit: lock` while still unlocked drops the latch, and a 3s
  expiry catches a spawn that dies silently. A `lock-system` that lands
  while the session is *already* locked sets the latch but can never fire,
  since `locked` has no rising edge left. The second check is origin,
  decided at the `secureLocked` rising edge itself, because `locked` is
  shared and a manual lock can win the race against an in-flight idle
  lock: a plugin-owned `IdleMonitor` (raw input, 30s window — well under
  the 2-minute minimum lock stop) must report the user idle, judged one
  second after the edge so the compositor resume event from a manual
  lock's own keypress has time to arrive. A manual lock is input, so it
  can never pass this check, whatever raised the edge. The bias is
  explicit: missing a real idle lock fails safe (no suspend); claiming a
  manual one must never happen. `lastEvent`'s wording dependency and the
  one intentional gap this leaves are in `docs/threat-model.md`.
- **`secureLocked`, not `locked`, is the arming signal.** `locked` rises as
  soon as a lock is *requested*; with no real screen behind it,
  `pendingSessionLock` can stay true forever. `secureLocked` is
  `locked && !pendingSessionLock` — the edge that actually means the
  screen is locked, and the one both checks above re-verify at fire time.
- **The suspend timer's interval is assigned at arm time, never bound.** A
  live binding on a running QML Timer restarts it on any config change —
  and a mid-countdown edit to "never" (-1) would clamp into a one-second
  fuse. A delay change, an unlock, or stay-awake turning on all cancel a
  pending countdown outright; so does the host losing `omarchy.idle` or
  `omarchy.lock` mid-countdown (the shell can recreate either singleton).
- **Lock must sit strictly above screensaver.** At equal values the host
  derives both stage delays as zero and fires the screensaver and the lock
  in the same pass (the screensaver's "skip if locked" guard is an async
  subprocess that races the lock). Slider commits enforce the clamp
  against the *stored* partner value and write **only the moved key**
  unless the clamp forces the partner to move; a hand-broken stored pair
  is surfaced as a warning, never silently repaired — opening a panel must
  not write.
- **Displayed delays come from `omarchy.idle`'s derived properties**
  (`screensaverTimeoutSeconds` / `lockTimeoutSeconds`), never from
  re-parsing `shell.json`: the host's parser accepts `0` as "immediately"
  and owns the defaults, and a re-implementation drifts.
- **`updateEntryInline` replaces the whole entry** with `{id}` plus what
  you pass — always merge (`Model.mergedSettings`) or every sibling key,
  `dryRun` included, is dropped. The CLI `omarchy-shell shell
  setBarWidget` merges safely. A plain-string bar-layout entry
  (`"some.id"`) renders fine but can hold no settings at all; the service
  logs a delayed warning (after `configEntryCheckMs`, so `shellConfig`'s
  brief startup default has time to settle) when it finds no entry.
- **Defaults fail safe.** `sleepAfterIdleLock` ships as `-1` (never), so an
  install changes nothing until the user picks a delay. `dryRun` is a
  config-only testing valve, off by default — the delay default is the
  guard, not `dryRun`.

## Config normalization

| Key | Accepted | Rejected/clamped to |
|---|---|---|
| `sleepAfterIdleLock` | A finite number (or numeric string) at or above the floor (60s in production, `minSleepSeconds`), up to `SLEEP_MAX_SECONDS` (86400, 24h). | Below the floor, non-numeric, or negative → never (`-1`). Above 24h → clamped down to it, logged. The cap exists because `Timer.interval` is a signed 32-bit millisecond count; an uncapped value times 1000 can overflow and wrap the interval negative. |
| `dryRun` | `true`, `"true"`, `1`, `"1"`. | Everything else, `undefined` included, is `false` — a string that merely *looks* true must never read as false and produce a real suspend, so the safe direction is the narrow allow-list, not a broad reject-list. |

## Process contract

Every external tool is a direct Quickshell `Process` child — never a bash
wrapper, since Quickshell only signals its *direct* child and a wrapped
grandchild is invisible to its kill/orphan handling. Each of the seven
process kinds below gets its own watchdog `Timer` (`signal(15)` at the
deadline, a PID-guarded `signal(9)` a second later) and the same
failed-start finalize: a missing binary flips `running` false without ever
emitting `exited`, so `onRunningChanged` + `Qt.callLater`, guarded by a
per-arm generation counter, synthesizes exit code 127 for it.

| Kind | Command | Deadline (production) |
|---|---|---|
| `resolveToggle` / `resolveToggleEnabled` | `bash -lc "type -P omarchy-toggle[-enabled]"` — absolute path only, one 15s retry on failure | 5s |
| `mkdirToggles` | `mkdir -p ~/.local/state/omarchy/toggles`, once at startup | 5s |
| `write` | resolved `omarchy-toggle screensaver-off on\|off` | 5s |
| `probe` | resolved `omarchy-toggle-enabled screensaver-off` (exit-code only) | 5s |
| `suspend` | `systemctl suspend` (or nothing, under `dryRun`) | 15s |
| `notify` | `omarchy-notification-send` (`dryRun` only) | 5s |

Output is bounded to `outputCapChars` (4096) total across stdout+stderr,
collected only for failure logging; a breach caps the buffer and TERMs the
child early.

## Probe seams

Three plain (non-`readonly`) properties exist only so a probe can shorten
production timing; nothing in the shipped plugin ever assigns them:
`minSleepSeconds` (the 60s floor `normalizeSleepSeconds` enforces),
`configEntryCheckMs` (the delayed no-config-entry warning), and
`originIdleSource` (swapped for a stub `QtObject{isIdle}`, since real
compositor idle state cannot be scripted).

## Workflow traps

- **Any bar-widget edit — and any new file — needs `omarchy restart
  shell`.** Hot reload never re-creates a registered widget component, and
  a file added after the first scan fails with `File name case mismatch`.
- **Every file save under the plugin folder triggers a full plugin
  reload** (the shell runs `inotifywait -r`), which tears down and
  rebuilds every plugin widget. `.git/` is exempt, so commits are quiet.
- Rule out a real idle inhibitor before assuming the idle pipeline is
  broken: `hyprctl clients -j | grep inhibitingIdle` — a browser playing
  video legitimately blocks idling.
- Never pass Nerd-Font PUA glyphs through a bash heredoc or an exact-match
  edit tool — they are silently stripped. Write such files with a
  Unicode-safe writer.
- `qmllint` needs an import root containing a `qs` entry and is not on
  `PATH`: `mkdir -p /tmp/qmlroot && ln -sfn /usr/share/omarchy/shell
  /tmp/qmlroot/qs && /usr/lib/qt6/bin/qmllint -I /tmp/qmlroot -I
  /usr/share/omarchy/shell Panel.qml`.
- Liveness is the IPC probe, not the plugin list:
  `omarchy-shell halmylyseas.ristretto __probe__` → `Function not found.`
  means loaded; `Target not found.` means not.
- The repo is the installed folder — the validator rejects a symlinked
  plugin directory, so the checkout lives at
  `~/.config/omarchy/plugins/halmylyseas.ristretto/`.
- Never `omarchy plugin clone` a first-party plugin — the clone replaces
  the built-in. Scaffold by hand and read `/usr/share/omarchy/shell/` as
  reference (reading is safe and encouraged; writing there is destroyed by
  every update).
- `omarchy plugin disable` splices the entry out of `shell.json` —
  settings, `dryRun` included, do not survive a disable/enable cycle.

## Testing

- `node test/model.test.js` — pure-logic coverage of `Model.js` (stop
  tables, the clamp, snapping, keyboard steps, config normalization,
  config-entry lookups). `Model.js` opens with `.pragma library`
  (QML-only), so the loader reads it as text, checks line 1 is exactly
  that pragma, swaps it in place for `"use strict";` (same position, so
  line numbers in stack traces don't shift), runs a regex tripwire for
  post-ES5 syntax (arrow functions, template literals, `let`/`const`/
  `async`/`class`, spread/rest — Node parses all of it but the QML engine
  does not), then evaluates the result in a fresh `vm` context. vm-realm
  objects compare unequal to native literals under `deepStrictEqual`, so
  comparisons JSON-round-trip them first.
- `node test/host-contract.mjs` — read-only pin on host wording/API
  members nothing else here checks (idle/lock `Service.qml` log-event
  strings and property names, `shell.qml`'s four config-API functions,
  the shared `Ui/` components this plugin's QML declares, and the
  installed `omarchy` package version against `Model.js`'s
  `SUPPORTED_OMARCHY_MIN`). Skips cleanly (`SKIP:` + exit 0) when the
  shell tree is absent; `RISTRETTO_SHELL_TREE` overrides the default
  `/usr/share/omarchy/shell`.
- `node --test test/comment-hygiene.test.js` — every shipped file's
  comments stay ≤3 lines and free of internal project-log references.
- `node test/qml-sinks.test.js` — every local QML `Text{}` sink declares
  `textFormat: Text.PlainText`.
- `bash test/probe/run` — drives the real `Service.qml` through the idle
  lock/secure-lock/suspend state matrix under `qs -n -p`, PATH-shadowed
  mocks standing in for `systemctl`/`omarchy-toggle*`/
  `omarchy-notification-send`.
- `bash test/probe/run-ui` — drives the real `BarWidget.qml`/`Panel.qml`
  under `qs -n -p` with a stub `bar`/`shell`: rendering, slider commits,
  the conflict warning, the keyboard cursor, the hero subtitle, the
  settings merge, the null-service lifecycle, and that nothing spawns a
  process the service itself didn't start.
- `test/ci-local [--no-cage]` — mirrors `.github/workflows/test.yml` on a
  dev box: qmllint, `omarchy plugin validate .`, `node --test
  test/*.test.js`, `node test/host-contract.mjs`, then both `qs` probes
  under `cage` (install it yourself, Arch `extra`) or, with `--no-cage`,
  whatever Wayland display the calling session already has. Ends with
  `ALL SUITES PASSED` or a failure summary. The workflow itself runs the
  same steps in a fresh `archlinux:latest` container on every push to
  `master`/`hardening` and every pull request, extracting
  `usr/share/omarchy/shell` and the validator binary out of the `omarchy`
  package with `pacman -Swdd` + `bsdtar` instead of installing the whole
  desktop, then drives both probes under `cage` with a headless Wayland
  backend. Nothing here needs a marketplace CLI beyond what
  `test/mocks` already stands in for.
- `bash test/all` runs everything above in order and exits non-zero on
  any failure. Both `qs` probes and the host-contract check skip
  themselves cleanly with no live shell tree/Wayland session to run
  against.

## Releasing

The marketplace lists an exact validated commit, not a branch. To ship a
new version once the plugin is listed:

1. Bump `version` in `manifest.json`, commit, and push `master`.
2. Open a **Plugin verification** issue on
   `HANCORE-linux/omarchy-plugin-marketplace` (template
   `verify-plugin.yml`), choose *newer upstream commit*, and give the
   plugin ID, the repository root URL, and the full 40-character SHA of
   the pushed HEAD.
3. Validation and the security baseline run against that exact commit; a
   maintainer's `approved-and-verified` replaces the listed snapshot.

Until that lands, the listing shows *Update unverified* against a newer
`master` — harmless, but avoid pushing while a submission awaits approval,
since approval is bound to the commit that was validated. Re-run `omarchy
plugin validate .` and qmllint on a clean `git archive` checkout before
any release commit.

## Accepted risks

- **`lastEvent` is a free-form log mirror**, not a stable API — the
  eligibility latch depends on the exact wording of two adjacent events. A
  host rewording disables arming silently (no suspend on a real idle
  lock) but can never arm a manual one, since origin is decided
  separately and does not depend on wording.
- **A programmatic manual lock issued while the user genuinely is idle**
  passes the origin check the same as a real idle lock would — the check
  can only observe input, not intent. Narrow and accepted: the bias favors
  never missing a real idle lock's origin.
- **The screensaver switch's optimistic write can briefly disagree with
  the watcher.** A flip lands in the UI before the write completes and is
  reconciled on exit if it failed; a rapid second click mid-write is
  queued, not lost, but the switch may show a stale value for one write's
  duration. Cosmetic only.
