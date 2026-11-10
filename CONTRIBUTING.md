# Contributing to Ristretto

This document is the operational contract for maintainers and contributors.
Read it before changing code, tests, release metadata, or the installed copy.

## Project purpose

An Omarchy shell plugin: direct bar control over power-saver behaviour --
when the screensaver starts, when the session locks, and when the machine
suspends after an idle lock. Omarchy has no suspend-on-idle of its own;
this plugin adds it at the shell layer, the only place it can work.

## Required outcome

From the bar, without editing JSON by hand, a user can set and see:

1. The screensaver delay.
2. The lock delay.
3. A suspend-after-idle-lock delay -- the primary reason this plugin exists.
4. All of the above, taking effect immediately and surviving a shell
   restart and an `omarchy update`.

## Hard rules

1. **Never modify anything under `/usr/share/omarchy/`.** Reading it is
   safe, encouraged, and the primary way to learn the plugin API.
2. **Never fork or clone a first-party plugin.** Use the scoped settings API, own-process IPC/log observation, and shared
   Ui kit. Never impersonate a privileged plugin or traverse its parents.
3. **Never run `omarchy refresh`/`omarchy reinstall`.** They overwrite
   user config.
4. **Ask before anything that suspends, locks, or blanks the screen**
   during testing -- the user may be mid-task on the machine under test.
5. **Every external tool spawn is a direct Quickshell `Process` child,
   never a bash wrapper.** A wrapped grandchild is invisible to
   Quickshell's own kill/orphan handling.
6. **Defaults fail safe.** `sleepAfterIdleLock` ships as never; `dryRun`
   is a config-only testing valve, off by default.

## Environment

Compatibility targets: Omarchy 4.5.0 and 4.0.5 (current and previous release), Quickshell 0.3.2. Earlier 4.0.x paths remain but are outside the tested contract. Relevant paths:

```
/usr/share/omarchy/shell/plugins/     # first-party plugin source -- read only
/usr/share/omarchy/shell/shell.qml    # the shell host: config plumbing, service registry
~/.config/omarchy/shell.json          # user config: bar layout, idle timings, plugin entries
~/.config/omarchy/plugins/<id>/       # where user plugins must live to be discovered
~/.local/state/omarchy/toggles/       # feature toggles (screensaver-off)
```

## Repository layout

The canonical repo is the installed folder,
`~/.config/omarchy/plugins/halmylyseas.ristretto/` -- what the shell loads
and what `omarchy plugin validate`/the marketplace check. Develop in a
separate clone on a development branch, commit there, then deploy in one
burst by pulling that branch into the installed checkout. Do not pull from
`master` during development; restart the shell after deploying code or adding
files.
Never edit files directly under the installed folder -- the shell watches
it with `inotifywait -r`, and every save tears down and rebuilds the bar.

## Architecture

`Service.qml` (loaded once) owns the suspend state machine and every
machine-wide watcher; `BarWidget.qml`/`Panel.qml` (one per monitor) bind
its state and write through the shell's config API; `Model.js` is pure
ES5 logic, testable with plain Node. Scoped hosts use `HostBridge.qml`,
`HostIdle.qml`, `HostOrigin.qml`, and `OriginModel.js`; the narrow Python
helper writes shared idle delays only after a slider action. Scoped own settings
come from a singleton watched file entry, because copied facade snapshots can
remain stale after widget writes. Panels display the service values. Full detail: `docs/developers.md`.

## Testing

The host hot-reloads `shell.json` changes; verify that the service reflects its
own settings before relying on a live change. QML code changes and new files
require a shell restart. `bash test/all` runs Node and Python tests, read-only host contracts,
hygiene and sink scans, and real QML probes with mocked mutations.
`bash test/ci-local` adds lint and validation and runs under headless cage.
See `docs/developers.md` for contracts and supported behavior.

Before a live lock or suspend test, state the expected timing and user-visible
behavior, then pause at least 20 seconds before starting the disruptive action.
Obtain explicit authorization before any test that can lock, blank, or suspend
the session.

Do not treat copied facade settings as proof of active state. Exercise the
real widget, compare disk and service values, and restore the starting settings.

## Releasing

For a release candidate, bump `manifest.json`'s version, promote the changelog
entry, and push a `release/<version>` branch for GitHub Actions validation.
Only a final version merged to `master` proceeds to marketplace verification
with its exact 40-character SHA. See `docs/developers.md` "Releasing".
