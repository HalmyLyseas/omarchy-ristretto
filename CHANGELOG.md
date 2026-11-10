# Changelog

Notable user-facing changes, newest first. Marketplace verification applies
to an exact commit and is tracked separately from the version.

## 1.2.3 — 2026-11-10

### Fixed

- Keep idle-origin observation available across a system wall-clock step
  (for example an NTP correction) instead of tearing down the journal reader
  and disabling suspend for the session.

### Changed

- Target Omarchy 4.5.0 and 4.0.5 in CI and the documented compatibility
  contract; earlier 4.0.x paths remain outside the tested contract.
- Note Omarchy 4.5's custom bar-icon normalization in the widget source.
- Keep automatically discovered agent instructions out of the installed
  plugin payload.

## 1.2.2 — 2026-10-19

### Fixed

- Cancel a pending legacy countdown when `dryRun` changes, so turning the
  test guard off cannot turn an armed dry run into a real suspend.
- Clear the announcement and latch on unlock and on delay changes, so a
  delayed lock spawn cannot inherit a cancelled idle lock.
- Accept a lock spawn that the journal reports after its secure edge, instead
  of losing a real idle-driven lock to log ordering.
- Keep the sleep delay slider on a clicked target while the host confirms the
  value, matching the screensaver and lock sliders.
- Update the Omarchy and Quickshell compatibility contract for Omarchy 4.0.5
  and Quickshell 0.3.2, including exact-tag CI validation.
- Qualify the QML palette singleton as `Commons.Color` for Qt 6.12, preventing
  undefined color and icon bindings.
- Prefer Qt 6 `qmllint` and let local validation target a selected Omarchy
  checkout through `RISTRETTO_SHELL_TREE` and the validator override.

## 1.2.1 — 2026-09-12

### Fixed

- Keep delay sliders on a clicked target while the host confirms the new
  screensaver or lock value, preventing a visible snap-back and return.

## 1.2.0 — 2026-09-09

### Fixed

- Preserve current saved sibling settings when a stale widget edits the
  suspend delay, including the dry-run setting.
- Clear legacy idle-lock eligibility immediately when stay-awake is enabled.
- Make local QML lint independent of the caller's directory and reject every
  nonzero linter exit; share the same wrapper with CI.
- Restore idle controls and suspend on Omarchy 4.0.3 with capability-scoped
  plugin APIs, without modifying the installed host.
- Apply widget settings to the running service from the saved own entry.
  Display the service's effective suspend delay and dry-run state, avoiding
  stale copied settings after an inline widget change.
- Recognize secure idle locks when the host omits the lock-state rising event
  or its lock helper exits successfully before secure confirmation.
- Expire legacy pending lock attempts that never become secure.

### Changed

- Observe idle origin through the current-boot, own-process user journal,
  avoiding crashes in Quickshell's log-following client.
- Require fresh journal barriers around current idle and secure-lock status
  before suspend; discard eligibility after unlock or observation failure.
- Validate shared idle-delay writes, preserve unrelated settings, replace
  atomically, and confirm the host's effective values.

### Added

- Diagnostics for countdown cancellation and failed final status checks.
- Coverage for scoped settings, multiple widgets, malformed and deleted
  configuration, origin races, process cleanup, and real journal transport.
- Contributor instructions in `CONTRIBUTING.md` and this changelog.

## 1.1.0 — 2026-08-30

### Fixed

- Wait for secure lock before arming suspend and sample raw input at the idle
  announcement so the lock screen's own input reset does not reject it.
- Cancel on unlock, settings changes, stay-awake, and lost host services.
- Probe the screensaver flag on startup without changing it.
- Normalize settings consistently and reject invalid or unsafe sleep delays.

### Added

- Bounded direct child processes with timeouts and forced cleanup.
- Headless service and UI probes, host contract checks, and local CI tooling.

## 1.0.2 — 2026-08-27

### Fixed

- Check raw input around the lock edge to distinguish manual locking from
  an eligible idle-lock attempt.

## 1.0.1 — 2026-08-27

### Fixed

- Require a confirmed idle-lock process spawn before latching eligibility;
  reject skipped or failed attempts and expire the latch after three seconds.
- Keep the screensaver flag watcher from loading file contents.

## 1.0.0 — 2026-08-26

### Added

- Bar controls for stay-awake, screensaver, lock, and suspend-after-idle-lock
  delays, with keyboard navigation and persistent settings.
