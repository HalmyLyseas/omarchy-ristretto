# Developer notes

The distilled why and how of this plugin, for a contributor (or a future
maintenance session) starting from a bare clone. The README covers using it;
`CLAUDE.md` carries the project rules. Everything here was learned against a
live Omarchy 4.0.0 system, usually the hard way.

## Architecture

| File | Role |
|---|---|
| `Service.qml` | The suspend state machine, and the owner of every machine-wide watcher (the screensaver flag probe + directory watch live here). Loaded once by the shell. |
| `BarWidget.qml` | The bar button. Hosts the panel through an eagerly-active Loader — the first-party pattern (clock, weather). One instance **per monitor**. |
| `Panel.qml` | The UI. Binds host-derived state; writes through the shell's config API; owns nothing global. |
| `Model.js` | Pure logic: stop arrays, the clamp, snapping, keyboard steps. Testable without a running shell. |
| `RistrettoIcon.qml` | The mark as a Qt Quick Shape on a 24-unit grid. `steam: bool` — the curls render only while stay-awake is on. |

The split rule: **panels exist once per monitor, so anything singleton —
watchers, processes, timers — belongs in the service**, and panels bind it
via `shell.serviceFor("halmylyseas.ristretto")`.

## Decisions that look odd until you know why

- **A manual lock never leads to suspend.** Two independent gates. The
  first is eligibility: a two-step latch on `omarchy.idle`'s `lastEvent` —
  the only origin-carrying signal the host has (`lockRequested` is set for
  every lock; `idledThisCycle` is already cleared when the lock lands).
  `lock-system` only announces; the latch sets when the same synchronous
  `lockSystem()` call follows it with `process-start: lock`, confirming a
  spawn. Anything else drops the announcement, a `process-exit: lock`
  while still unlocked drops the latch, and a 3s expiry catches a spawn
  that dies silently. The second gate is origin, decided at the `locked`
  rising edge itself, because `locked` is shared and a manual lock can win
  the race against an in-flight idle lock: a plugin-owned `IdleMonitor`
  (raw input, 30s window — well under the 2-minute minimum lock stop) must
  report the user idle, judged one second after the edge so the compositor
  resume event from a manual lock's own keypress has arrived. A manual
  lock is input, so it can never pass this gate, whatever raised the edge.
  The bias is explicit: missing a real idle lock fails safe (no suspend);
  claiming a manual one must never happen. The latch's string scrape of a
  log mirror is documented in `Service.qml` as an accepted risk — a host
  rewording silently disables arming but can never suspend a manual lock,
  because the origin gate does not depend on wording.
- **The suspend timer's interval is assigned at arm time, never bound.** A
  live binding on a running QML Timer restarts it on any config change —
  and a mid-countdown edit to "never" (-1) would clamp into a one-second
  fuse. A delay change, an unlock, or stay-awake turning on all cancel a
  pending countdown outright.
- **Lock must sit strictly above screensaver.** At equal values the host
  derives both stage delays as zero and fires the screensaver and the lock
  in the same pass (the screensaver's "skip if locked" guard is an async
  subprocess that races the lock). Slider commits enforce the clamp against
  the *stored* partner value and write **only the moved key** unless the
  clamp forces the partner to move; a hand-broken stored pair is surfaced
  as a warning, never silently repaired — opening a panel must not write.
- **Displayed delays come from `omarchy.idle`'s derived properties**
  (`screensaverTimeoutSeconds` / `lockTimeoutSeconds`), never from
  re-parsing `shell.json`: the host's parser accepts `0` as "immediately"
  and owns the defaults, and a re-implementation drifts.
- **`updateEntryInline` replaces the whole entry** with `{id}` plus what
  you pass — always merge (`Model.mergedSettings`) or every sibling key,
  `dryRun` included, is dropped. The CLI `omarchy-shell shell setBarWidget`
  merges safely. A plain-string bar-layout entry (`"some.id"`) renders fine
  but can hold no settings at all; the service logs a delayed warning when
  it finds no entry.
- **Defaults fail safe.** `sleepAfterIdleLock` ships as `-1` (never), so an
  install changes nothing until the user picks a delay. `dryRun` is a
  config-only testing valve, off by default — the delay default is the
  guard, not `dryRun`.

## Workflow traps (each one cost real time)

- **Any bar-widget edit — and any new file — needs `omarchy restart
  shell`.** Hot reload never re-creates a registered widget component, and
  a file added after the first scan fails with `File name case mismatch`
  even though it exists. Do not debug a widget that "ignores" your change
  until you have restarted.
- **Every file save under the plugin folder triggers a full plugin reload**
  (the shell runs `inotifywait -r` over `~/.config/omarchy/plugins/`), which
  tears down and rebuilds every plugin widget — the visible bar flash.
  `.git/` is exempt, so commits are quiet; doc edits are not.
- **Shell restarts used to silently kill `omarchy.idle`'s idle monitor**
  (no screensaver, no lock, nothing from this plugin, while
  `omarchy-shell idle status` looked perfectly healthy). **Fixed as of
  omarchy 4.0.1 + Quickshell 0.3.1** — verified by a live restart-then-
  idle reproduction with no workaround applied; the fix arrived with the
  quickshell-git → 0.3.1 release swap. On older stacks, revive with
  `omarchy toggle idle stay-awake`, wait a few seconds, `omarchy toggle
  idle allow-idle` — the pause matters, because the CLI only touches a
  flag file the service watches asynchronously, and a rapid
  create+delete loses the delete. When idle looks dead, also rule out a
  real inhibitor first: `hyprctl clients -j | grep inhibitingIdle` — a
  browser playing video legitimately blocks idling.
- **Never pass Nerd-Font PUA glyphs through a bash heredoc or an
  exact-match edit tool** — they are silently stripped or fail to match.
  Write such files with a Unicode-safe writer.
- **`qmllint` needs an import root containing a `qs` entry** and is not on
  `PATH`:

  ```bash
  mkdir -p /tmp/qmlroot && ln -sfn /usr/share/omarchy/shell /tmp/qmlroot/qs
  /usr/lib/qt6/bin/qmllint -I /tmp/qmlroot -I /usr/share/omarchy/shell Panel.qml
  ```

- **Liveness is the IPC probe, not the plugin list.**
  `omarchy-shell halmylyseas.ristretto __probe__` → `Function not found.`
  means loaded; `Target not found.` means not. The `active` field in
  `omarchy plugin list --json` is false even for visible widgets.
- **The repo is the installed folder.** The validator rejects a symlinked
  plugin directory, so the checkout lives at
  `~/.config/omarchy/plugins/halmylyseas.ristretto/` and any working-copy
  symlink points *at* it, not the other way round.
- **Never `omarchy plugin clone` a first-party plugin** — the clone
  replaces the built-in. Scaffold by hand and read
  `/usr/share/omarchy/shell/` as reference (reading is safe and
  encouraged; writing there is destroyed by every update).
- **`omarchy plugin disable` splices the entry out of `shell.json`** —
  settings, `dryRun` included, do not survive a disable/enable cycle.

## Testing

- `./test/all` runs the unit suite: pure-logic coverage of `Model.js` (stop
  tables, the clamp, snapping, keyboard steps, the config-entry lookups) with
  plain Node and `assert` -- no framework, no Quickshell, no live session.
  `node test/model.test.js` runs the same suite directly. Both exit non-zero
  on any failure.
- `Model.js` opens with `.pragma library` (QML-only syntax) so it can be
  shared read-only across every QML importer -- Node can't parse that line.
  The test loader reads the file as text, strips just the pragma line, and
  runs the rest in a fresh `vm` context, then reads the top-level functions
  back off it; the file on disk is never touched. This only keeps working if
  `Model.js` stays pure ES5 with no Quickshell imports and no syntax beyond
  the pragma that Node's parser rejects -- the day it needs one, the loader
  needs a matching strip.
- Set `dryRun: true` first; every timing path then proves itself in the
  journal with nothing at stake:

  ```bash
  journalctl --user -f | grep "qml: ristretto"
  ```

- Idle behaviour needs genuine input idleness — no keyboard, no mouse.
  Shorten `idle.screensaver`/`idle.lock` for the run (values below the
  slider stops are fine; the panel only approximates them and will not
  rewrite them). `wtype` drives the panel's keyboard model headlessly.
- Wayland idle inhibitors gate the whole pipeline: an app that implements
  the protocol (Chromium playing video) pauses everything upstream of this
  plugin; an app that does not (Zoom's Linux client) inhibits nothing.
  When in doubt, run two `IdleMonitor`s side by side — one
  `respectInhibitors: true`, one `false` — in a separate Quickshell
  instance, and redirect the output to a file, never a pipe (pipes
  block-buffer and swallow everything).

## Releasing an update

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
`master` — harmless, but avoid pushing mid-review of a pending
submission, since approval is bound to the commit that was validated.
Re-run `omarchy plugin validate .` and qmllint on a clean `git archive`
checkout before any release commit.
