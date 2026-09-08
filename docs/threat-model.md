# Threat model

Scope: Ristretto controls idle delays and suspends after a verified idle
lock. It runs as the desktop user inside Omarchy's Quickshell process.

## Assets

- User activity and manual locking must not initiate automatic suspend.
- A session must be securely locked before suspend can be dispatched.
- Unrelated shell settings must survive delay edits.
- Missing, stale, malformed, or ambiguous observations must fail closed.

## Writes and commands

The plugin updates its own bar-entry settings through `updateEntryInline`.
Explicit slider actions update `idle.screensaver` and `idle.lock`, using
legacy host mutation or a narrow Python helper on scoped hosts. The helper
also creates a persistent `.ristretto.lock` sidecar and temporary files in
the configuration directory. It never writes on startup.

Stay-awake uses explicit idle enable/disable IPC. The screensaver switch
uses the native toggle CLI and its existing state directory. Startup makes
that toggle directory if needed and probes its flag. Verified countdowns
call `systemctl suspend`; dry run substitutes a notification and log entry.
No command changes the installed host tree or requires root.

## Boundaries

| Boundary | Guard |
|---|---|
| Scoped plugin API | Own settings use the copied bar snapshot. No privileged clone, full-bar identity, parent traversal, or upstream host modification. |
| Idle/lock observation | Own-process PID-pinned current-boot user journal, fresh nonce after replay, periodic barriers, bounded phase deadlines, and reconnect generations. Only required event fields are parsed. |
| Raw input | Wall and monotonic timestamps reconstruct idle before the source announcement. Equal-millisecond ambiguity, clock discontinuity, or absent history reject origin. |
| Suspend dispatch | Secure idle token, fresh barrier, loaded/enabled idle status, secure nonpending lock status, second barrier, and synchronous settings/cancellation checks. |
| Shared config | Owned regular version-1 JSON, size limit, symlink rejection, same-directory temporary file, atomic replace, sidecar flock, final identity/content comparison, one retry, and subsequent host-state verification. |
| Own settings | Type/range normalization and whole-entry merge preserve sibling settings. Sleep defaults to never. |
| Child tools | Fixed argv, direct Process children, bounded collected output, deadline TERM then PID-guarded KILL, generation-aware completion. |
| User-writable toggle directory | FileView watches without preloading; native exit-code probe reads flag state. |

## Residual risks

- Host log wording and ordered journal stream delivery are implementation
  contracts, pinned to tested versions. A fresh marker proves reader
  progress through the same logging stream; it cannot compensate for a host
  or journal that silently drops or changes relevant records. Contract drift needs
  investigation before extending support.
- The journal follower replays to a fresh marker using `--no-tail`. A large
  journal, unavailable user journal, rate limiting, or delayed delivery can
  prevent observation and leave suspend unavailable.
- A manual request racing an already spawned idle lock cannot always be
  distinguished from that lock's own request. Raw activity and phase checks
  narrow the window but do not provide a host-issued causal identifier.
- The last status/log observations and dispatch are not an atomic host
  transaction. Events generated after the final marker can race the final
  synchronous dispatch. Every observed unlock or cancellation rejects the
  saved token.
- A noncooperating configuration writer can change the file between the
  final comparison and rename. Flock serializes plugin helpers, not the
  host's own writer. Whole-file atomic replacement prevents partial JSON
  but does not eliminate this residual lost-update window. It may also
  change inode metadata beyond preserved file mode; custom ACLs and xattrs
  are not copied.
- SplitParser bounds apply after complete lines arrive. A malicious child
  emitting one unbroken line can allocate parser memory before the bound
  is evaluated; command deadlines limit its lifetime.
- The screensaver switch updates optimistically and then reconciles with
  its probe. It can briefly show a value that the native write rejected.

## Out of scope

A compromised same-user session, host process, plugin, installed binary,
kernel, or package supply chain can bypass these boundaries. The plugin
trusts installed Omarchy, Quickshell, Python, systemd, and native tools.
It does not claim isolation from code running inside the same host process.
