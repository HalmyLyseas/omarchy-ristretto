# Developer notes

The distilled why and how of this plugin, for a contributor starting from
a bare clone. The README covers using it; `CLAUDE.md` carries the project
rules; `docs/threat-model.md` carries the asset/boundary model.

## Architecture

| File | Role |
|---|---|
| `Service.qml` | The suspend state machine, and the owner of every machine-wide watcher (the screensaver flag probe + directory watch live here). Loaded once by the shell. |
| `BarWidget.qml` | The bar button. Hosts the panel through an eagerly-active Loader — the first-party pattern (clock, weather). One instance **per monitor**. |
| `Panel.qml` | The UI. Binds host-derived state; routes shared writes through its service; owns nothing global. |
| `HostBridge.qml` | Scoped-host adapter: idle status, origin correlation, delay writes, final suspend checks. |
| `HostIdle.qml` / `HostOrigin.qml` | Bounded IPC reader/writer and own-process log follower. |
| `CommandJob.qml` | Direct child command with output limit and TERM/KILL deadlines. |
| `OriginModel.js` | Pure timestamped lock-origin reducer. |
| `tools/update-idle.py` | Narrow atomic shared idle-delay writer. |
| `Model.js` | Pure logic: stop arrays, the clamp, snapping, keyboard steps, config normalization. Testable without a running shell. |
| `RistrettoIcon.qml` | The mark as a Qt Quick Shape on a 24-unit grid. `steam: bool` — the curls render only while stay-awake is on. |

The split rule: **panels exist once per monitor, so anything singleton —
watchers, processes, timers — belongs in the service**, and panels bind it
via `shell.serviceFor("halmylyseas.ristretto")`. `BarWidget.qml`/
`Panel.qml` expose a handful of `_debug*` read-only aliases (the panel's
content item, the loaded panel instance, the three timers' `running`
state) for the probe harnesses below; production code never reads them.

## Decisions that look odd until you know why

- **Idle origin needs evidence before the lock appears.** On hosts exposing
  live first-party services, the service samples raw idle synchronously at
  the idle announcement and waits for the secure edge. On scoped hosts,
  `HostOrigin.qml` follows the current Quickshell process's detailed log,
  and `OriginModel.js` correlates announcement, lock process start, request,
  and secure events within bounded phase deadlines. The secure edge also
  supplies locked evidence when no session-lock rising event is emitted. Raw idle
  transitions carry wall and monotonic timestamps. The state strictly
  before the source announcement decides origin; equal-millisecond samples
  are ambiguous and rejected. Sampling at log delivery would be wrong:
  the lock screen itself can reset the compositor idle notifier.
- **A fresh log marker establishes continuity.** The follower replays the
  log only until its own fresh nonce, discarding older events. Heartbeats,
  bounded replay/output, clock checks, and reconnect generations invalidate
  incomplete evidence. Quickshell 0.3.1's `--tail` can discard records in
  later follower batches, so the command deliberately omits it. Excessive
  replay fails unavailable. This depends on Quickshell's ordered same-thread
  QML logging and its detailed-log writer, rather than journal delivery.
- **Suspend uses two fresh barriers.** A saved token must survive a marker,
  fresh idle and lock IPC status, and a second marker after those replies.
  Idle must be loaded and enabled; lock must be secure, session-locked, and
  not pending. The service then rechecks its settings and cancellation
  generation synchronously before dispatching suspend. Unlock, stay-awake,
  observation failure, and replacement lock attempts invalidate the token.
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
- **Displayed delays come from the host.** Legacy service properties or
  scoped `idle status` IPC provide the effective values. Unknown state is
  shown as unavailable, and shared controls are disabled until it is current.
  The scoped writer accepts a version-1 regular owned JSON file, bounds its
  size, rejects symlinks, and merges the requested stop into the latest
  config. It preserves unrelated values and a compliant partner exactly.
  A persistent sidecar `flock` serializes plugin writers; a same-directory
  temporary file and atomic replace avoid partial JSON. A detected external
  edit causes one reread/retry. The host must subsequently report the new
  effective pair before the write is considered verified. Noncooperating
  writers can still race the final compare/rename; see the threat model.
- **`updateEntryInline` replaces the whole entry** with `{id}` plus what
  you pass — always merge (`Model.mergedSettings`) or every sibling key,
  `dryRun` included, is dropped. The CLI `omarchy-shell shell
  setBarWidget` merges safely. A plain-string bar-layout entry
  (`"some.id"`) renders fine but can hold no settings at all; the service
  logs separate delayed diagnostics for missing settings and missing host
  observation. Scoped facades expose a copied `barConfig`, which supplies
  the own-entry settings and refreshes on host replacements.
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
original process kinds below gets its own watchdog `Timer` (`signal(15)` at the
deadline, a PID-guarded `signal(9)` a second later) and the same
failed-start finalize: a missing binary flips `running` false without ever
emitting `exited`, so `onRunningChanged` + `Qt.callLater`, guarded by a
per-arm generation counter, synthesizes exit code 127 for it.

| Kind | Command | Deadline (production) |
|---|---|---|
| `resolveToggle` / `resolveToggleEnabled` | `bash -lc "type -P omarchy-toggle[-enabled]"` — absolute path only, up to three 15s retries on failure | 5s |
| `mkdirToggles` | `mkdir -p ~/.local/state/omarchy/toggles`, once at startup | 5s |
| `write` | resolved `omarchy-toggle screensaver-off on\|off` | 5s |
| `probe` | resolved `omarchy-toggle-enabled screensaver-off` (exit-code only) | 5s |
| `suspend` | `systemctl suspend` (or nothing, under `dryRun`) | 15s |
| `notify` | `omarchy-notification-send` (`dryRun` only) | 5s |
| Scoped idle | `qs ipc --pid PID call -- idle status/enable/disable` | 2s |
| Preflight | `qs ipc --pid PID call -- idle/lock status` | 2.5s per call |
| Origin | `qs log --pid PID --follow --no-color` | 3s marker deadline |
| Delay writer | `/usr/bin/python3 tools/update-idle.py` with fixed named arguments | 2.5s |

Output is bounded to `outputCapChars` (4096) total across stdout+stderr,
collected only for failure logging; a breach caps the buffer and TERMs the
child early.

## Probe seams

Plain (non-`readonly`) properties exist only so a probe can shorten
production timing; nothing in the shipped plugin ever assigns them:
`minSleepSeconds` (the 60s floor `normalizeSleepSeconds` enforces),
`configEntryCheckMs` (the delayed no-config-entry warning),
`toolRetryIntervalMs` (the 15s spacing between resolution retries), and
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

`bash test/all` runs Node logic, host contracts, source hygiene, Python
writer tests, and every real QML probe. `test/ci-local [--no-cage]` also
runs lint and plugin validation, using headless cage by default. CI installs
Python alongside Quickshell, Node, and cage, and extracts the host shell
without installing the desktop. Tests use temporary config and mocked
mutating commands. Live lock/suspend tests require explicit authorization.

The original service and UI runners cover legacy bindings. Additional
`test/probe/run-*` runners exercise actual adapters, failed starts, output
limits, watchdogs, callbacks, origin transport, and scoped host behavior.
Host contracts inspect the installed source and CLI wording; they do not
establish runtime authorization merely because a method name exists.

All QML files, including untracked development files, are linted locally.
Node tests strip `.pragma library` before evaluating pure QML JavaScript.
The idle writer tests exercise invalid targets, preserved settings, atomic
replacement, conflict retries, locking, and failure cleanup in temporary
files only.

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

Host log wording and Quickshell logging behavior are version-dependent.
Malformed, stale, ambiguous, or missing evidence prevents arming. Detailed
logs can grow large enough that replay exceeds the bound and suspend stays
unavailable. The log reader processes the own host process only; it does
not retain authentication details from lock status. A manual request racing
an already spawned idle lock cannot be attributed perfectly from these
observations. See `docs/threat-model.md` for boundaries and limitations.
