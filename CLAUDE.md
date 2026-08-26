# omarchy-ristretto

An Omarchy shell plugin that gives the user direct control over power-saver
behaviour: **when the screensaver starts, when the screen locks, and when the
machine suspends.**

This file is the project charter. `exchange/` is gitignored local scratch —
the scoping documents, mockups, and icon sources this design rests on. When
it is present, read the **highest-numbered** `exchange/NNN-*.md` first (it
is the current state and supersedes the older ones), then
`001-initial-scope.md` and `002-actions-plan.md` for the measured facts and
the original plan. When it is not — a fresh clone — this file, the README,
and `docs/developers.md` (the distilled design record and workflow traps,
shipped with every clone) are enough to build, install, and maintain the
plugin: the `001` / `002` citations below are corroboration for claims
already stated here, never instructions to go and read something absent.

## The outcome this project must achieve

A user on this machine can, without editing JSON by hand:

1. **Set the screensaver delay** — how long after going idle the screensaver
   appears.
2. **Set the lock delay** — how long after going idle the session locks.
3. **Set a suspend delay** — how long after the session locks the machine
   suspends. *This capability does not exist anywhere in Omarchy today.* It is
   the primary reason this project exists.
4. See the current values and change them from the bar, with the change taking
   effect immediately and surviving a shell restart and an `omarchy update`.

Done means: all four work on a live session, the plugin survives
`omarchy update`, and no file under `/usr/share/omarchy/` was modified.

**Status (2026-08-26): done.** All four outcomes are met and verified live —
including the real suspend — and v1.0.0 is published at
<https://github.com/HalmyLyseas/omarchy-ristretto>. The charter's rules
remain in force for all future work.

### Explicitly out of scope (for now)

- **Timed "stay awake" / Caffeine-style temporary inhibition** (15/30/60 min
  with a countdown). Originally the motivating feature; deferred because the
  problem driving it turned out to be a Firefox bug that the user solved by
  switching video playback to Chromium. See `001` §2. Revisit only if the user
  asks — the groundwork in `001` §5 still applies.
- **Fixing idle inhibition for any application.** Investigated exhaustively and
  settled: the inhibitor chain works correctly. See `001` §2. Do not re-open
  this without new evidence.
- **Media detection** (polling PipeWire for playing audio to infer "user is
  watching something"). Considered and rejected — the Wayland inhibitor
  protocol already does this correctly for every app that implements it.

## Hard rules

1. **Never modify anything under `/usr/share/omarchy/`.** It is owned by the
   `omarchy` package and any change is destroyed by the next `omarchy update`.
   Reading it is safe, encouraged, and the primary way to learn the plugin API.
2. **Never fork or clone a first-party plugin** (`omarchy plugin clone ...`) for
   this project. A clone replaces the built-in and permanently stops receiving
   upstream fixes. Everything needed here is reachable through documented seams
   — the shell's config API, its service registry, and the shared Ui kit
   (`001` §4 corroborates). If you believe you need a clone, you have missed
   one of those seams.
3. **Do not run `omarchy refresh ...` or `omarchy reinstall`** — they overwrite
   user config. If a reset seems necessary, ask the user first.
4. **Ask before anything that suspends, locks, or blanks the screen** during
   testing. The user may be mid-task on the machine you are testing on.

## Environment

Measured 2026-08-24 on hostname `Navi`:

| Component | Version |
|---|---|
| Omarchy | 4.0.0-1 |
| Hyprland | 0.56.2-1 |
| Quickshell | 0.3.0.r20.g28771c7-2 (`quickshell-git`) |

Relevant paths:

```
/usr/share/omarchy/shell/plugins/     # first-party plugin source — READ ONLY, best reference
/usr/share/omarchy/shell/shell.qml    # the shell host: config plumbing, service registry
~/.config/omarchy/shell.json          # user config: bar layout, idle timings, plugin entries
~/.config/omarchy/plugins/<id>/       # where user plugins must live to be discovered
~/.local/state/omarchy/indicators/    # runtime state flags (stay-awake)
~/.local/state/omarchy/toggles/       # feature toggles (screensaver-off, suspend-off)
```

There is also a machine-specific `navi-omarchy` skill and a stock `omarchy`
skill available to the agent. Read both before touching Hyprland config or
anything needing root.

## Working agreement

- **`exchange/` is the handoff log.** Numbered markdown documents
  (`001-...`, `002-...`) carrying findings, decisions, and rationale between
  sessions and between agents. Write for a reader with zero context: absolute
  paths, file:line references, exact commands, and the evidence behind each
  claim. When a session produces a durable finding or a decision, it belongs in
  a new numbered document rather than only in chat.
- **Scope before code.** The user wants the problem understood and written down
  before implementation starts. Do not begin writing plugin code because the
  design looks obvious.
- **Measure, don't assume.** Every non-obvious claim in `001` was verified
  against the live system, and several plausible-sounding hypotheses were killed
  that way. Measure the same way: probe the live system (a separate Quickshell
  instance works well), redirect probe output to files — never pipes, which
  block-buffer — and sample the surrounding conditions alongside the probe
  (`001` §6 corroborates).
- **Testing idle behaviour requires the human.** The probe needs ~26 seconds
  with no keyboard or mouse input. You cannot fake this; ask the user, tell them
  exactly how long, and tell them when it's finished.

## Naming

`ristretto` — a short, concentrated shot. The plugin id should follow Omarchy's
convention of `<username>.<name>`, i.e. **`halmylyseas.ristretto`**, so it cannot
collide with a first-party id or another user's plugin.
