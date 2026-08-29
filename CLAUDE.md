# Ristretto (`halmylyseas.ristretto`)

An Omarchy shell plugin: direct bar control over power-saver behaviour --
when the screensaver starts, when the session locks, and when the machine
suspends after an idle lock. Omarchy has no suspend-on-idle of its own;
this plugin adds it at the shell layer, the only place it can work.

## The outcome this project must achieve

From the bar, without editing JSON by hand, a user can set and see:

1. The screensaver delay.
2. The lock delay.
3. A suspend-after-idle-lock delay -- the primary reason this plugin exists.
4. All of the above, taking effect immediately and surviving a shell
   restart and an `omarchy update`.

## Hard rules

1. **Never modify anything under `/usr/share/omarchy/`.** Reading it is
   safe, encouraged, and the primary way to learn the plugin API.
2. **Never fork or clone a first-party plugin.** Everything needed here is
   reachable through the shell's documented seams: its config API, service
   registry, and shared Ui kit.
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

Tested against Omarchy 4.0.1, Quickshell 0.3.1. Relevant paths:

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
separate clone, commit there, then deploy in one burst:
`git -C ~/.config/omarchy/plugins/halmylyseas.ristretto pull <work-clone> master`.
Never edit files directly under the installed folder -- the shell watches
it with `inotifywait -r`, and every save tears down and rebuilds the bar.

## Architecture

`Service.qml` (loaded once) owns the suspend state machine and every
machine-wide watcher; `BarWidget.qml`/`Panel.qml` (one per monitor) bind
its state and write through the shell's config API; `Model.js` is pure
ES5 logic, testable with plain Node. Full detail: `docs/developers.md`.

## Testing

`bash test/all` runs everything: the Node unit suite over `Model.js`, a
read-only contract check against the installed shell tree (skips cleanly
without one), comment-hygiene and QML-sink scans, and two `qs`-driven
probes (the service state machine, then the BarWidget/Panel UI). See
`docs/developers.md` "Testing" for what each one covers.

## Releasing

Bump `manifest.json`'s `version`, commit, push, and open a marketplace
verification issue with the exact 40-character SHA. See
`docs/developers.md` "Releasing".
