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

- **A manual lock never leads to suspend.** The discriminator is a
  two-step latch on `omarchy.idle`'s `lastEvent` — the only origin-carrying
  signal the host has (`lockRequested` is set for every lock;
  `idledThisCycle` is already cleared when the lock lands). `lock-system`
  only announces; the latch sets when the same synchronous `lockSystem()`
  call follows it with `process-start: lock`, confirming a spawn. Anything
  else drops the announcement, a `process-exit: lock` while still unlocked
  drops the latch, and a 3s expiry catches a confirmed spawn that dies
  silently — so a failed or skipped lock spawn cannot poison a later
  deliberate lock. The bias is explicit: missing a real idle lock fails
  safe (no suspend); claiming a manual one must never happen. This is a
  string scrape of a log mirror and is documented in `Service.qml` as an
  accepted risk; the wording-independent replacement, if the host ever
  rewords it, is a plugin-owned `IdleMonitor` consulted at the `locked`
  rising edge.
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
- **Shell restarts silently kill `omarchy.idle`'s idle monitor** (and
  idle-delay config writes appear able to as well): no screensaver, no
  lock, nothing from this plugin, while `omarchy-shell idle status` looks
  perfectly healthy. Revive it with `omarchy toggle idle stay-awake`, wait
  a few seconds, `omarchy toggle idle allow-idle` — the pause matters,
  because the CLI only touches a flag file the service watches
  asynchronously, and a rapid create+delete loses the delete.
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
