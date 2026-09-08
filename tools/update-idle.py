#!/usr/bin/env python3
"""Atomically update one Omarchy idle delay."""

import argparse
import json
import math
import os
import stat
import tempfile
import fcntl

MAX_BYTES = 1024 * 1024
SCREENSAVER = (60, 120, 180, 300, 600, 900)
LOCK = (120, 180, 300, 600, 900, 1800)


class UpdateError(Exception):
    pass


def _js_number(value):
    """Convert the supported JSON scalar forms used by the idle service."""
    if value is None:
        return 0.0
    if isinstance(value, bool):
        return 1.0 if value else 0.0
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return 0.0
        try:
            return float(text)
        except ValueError:
            return float("nan")
    return float("nan")


def _seconds(value, name):
    number = _js_number(value)
    if not math.isfinite(number) or number < 0:
        raise UpdateError("idle.%s is not a valid delay" % name)
    return int(math.floor(number))


def _nearest(stops, value):
    return min(range(len(stops)), key=lambda i: (abs(stops[i] - value), i))


def _partner(kind, requested, idle):
    raw_ss = idle["screensaver"]
    raw_lock = idle["lock"]
    ss = _seconds(idle["screensaver"], "screensaver")
    lock = _seconds(idle["lock"], "lock")
    if kind == "screensaver":
        ss = requested
        if lock > ss:
            return {"screensaver": ss, "lock": raw_lock}
        index = _nearest(LOCK, lock)
        if LOCK[index] <= ss:
            index = next((i for i, stop in enumerate(LOCK) if stop > ss), len(LOCK) - 1)
        lock = LOCK[index]
    else:
        lock = requested
        if ss < lock:
            return {"screensaver": raw_ss, "lock": lock}
        index = _nearest(SCREENSAVER, ss)
        if SCREENSAVER[index] >= lock:
            index = next((i for i in range(len(SCREENSAVER) - 1, -1, -1)
                          if SCREENSAVER[i] < lock), 0)
        ss = SCREENSAVER[index]
    return {"screensaver": ss, "lock": lock}


def _assert_safe_target(path):
    path = os.path.abspath(os.fspath(path))
    # A symlink in any component could redirect the pinned path between checks.
    current = os.path.sep
    for component in path.strip(os.path.sep).split(os.path.sep):
        current = os.path.join(current, component)
        try:
            if stat.S_ISLNK(os.lstat(current).st_mode):
                raise UpdateError("configuration path contains a symlink")
        except FileNotFoundError:
            raise UpdateError("configuration path does not exist")
    info = os.lstat(path)
    if not stat.S_ISREG(info.st_mode):
        raise UpdateError("configuration is not a regular file")
    if info.st_size > MAX_BYTES:
        raise UpdateError("configuration exceeds 1 MiB")
    if info.st_uid != os.geteuid():
        raise UpdateError("configuration owner differs from current user")
    return path


def _read(path):
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    fd = None
    before = None
    after = None
    try:
        fd = os.open(path, flags)
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_uid != os.geteuid():
            raise UpdateError("configuration is not a safe regular file")
        if before.st_size > MAX_BYTES:
            raise UpdateError("configuration exceeds 1 MiB")
        with os.fdopen(fd, "rb") as stream:
            data = stream.read(MAX_BYTES + 1)
            after = os.fstat(stream.fileno())
        fd = None
    except OSError as exc:
        raise UpdateError("cannot read configuration: %s" % exc)
    finally:
        if fd is not None:
            os.close(fd)
    if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != \
            (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
        raise UpdateError("configuration changed while reading")
    if len(data) > MAX_BYTES:
        raise UpdateError("configuration exceeds 1 MiB")
    try:
        config = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise UpdateError("invalid JSON: %s" % exc)
    if not isinstance(config, dict) or config.get("version") != 1 or isinstance(config.get("version"), bool):
        raise UpdateError("configuration must have numeric version 1")
    if not isinstance(config.get("idle"), dict):
        raise UpdateError("configuration idle must be an object")
    if "screensaver" not in config["idle"] or "lock" not in config["idle"]:
        raise UpdateError("configuration idle must contain screensaver and lock")
    return config, data, (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)


def _same(path, identity, data):
    fd = None
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        info = os.fstat(fd)
        if info.st_uid != os.geteuid() or (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns) != identity:
            os.close(fd)
            fd = None
            return False
        with os.fdopen(fd, "rb") as stream:
            fd = None
            return stream.read(MAX_BYTES + 1) == data
    except OSError:
        return False
    finally:
        if fd is not None:
            os.close(fd)


def write_config(path, kind, seconds, _ops=None):
    """Update config; _ops is a test-only injectable module-like object."""
    ops = _ops or os
    path = _assert_safe_target(path)
    if kind not in ("screensaver", "lock"):
        raise UpdateError("kind must be screensaver or lock")
    stops = SCREENSAVER if kind == "screensaver" else LOCK
    if isinstance(seconds, bool) or not isinstance(seconds, int) or seconds not in stops:
        raise UpdateError("seconds is not an allowed %s delay" % kind)

    lock_path = path + ".ristretto.lock"
    lock_fd = None
    try:
        lock_flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
        lock_fd = ops.open(lock_path, lock_flags, 0o600)
        lock_info = ops.fstat(lock_fd) if hasattr(ops, "fstat") else os.fstat(lock_fd)
        if not stat.S_ISREG(lock_info.st_mode) or lock_info.st_uid != os.geteuid():
            raise UpdateError("lock sidecar is not owned by current user")
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        if lock_fd is not None:
            os.close(lock_fd)
            lock_fd = None
        raise UpdateError("another update is in progress") from exc
    except BaseException:
        if lock_fd is not None:
            os.close(lock_fd)
            lock_fd = None
        raise
    try:
        for attempt in range(2):
            path = _assert_safe_target(path)
            config, original, identity = _read(path)
            identity_info = os.stat(path)
            pair = _partner(kind, seconds, config["idle"])
            config["idle"]["screensaver"] = pair["screensaver"]
            config["idle"]["lock"] = pair["lock"]
            mode = stat.S_IMODE(identity_info.st_mode)
            directory = os.path.dirname(path)
            fd = None
            temporary = None
            try:
                fd, temporary = tempfile.mkstemp(prefix=".ristretto-idle-", dir=directory)
                os.fchmod(fd, mode)
                payload = (json.dumps(config, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
                offset = 0
                while offset < len(payload):
                    offset += os.write(fd, payload[offset:])
                os.fsync(fd)
            except BaseException:
                if fd is not None:
                    os.close(fd)
                    fd = None
                if temporary is not None:
                    try:
                        os.unlink(temporary)
                    except FileNotFoundError:
                        pass
                raise
            finally:
                if fd is not None:
                    os.close(fd)
                    fd = None
            try:
                if not _same(path, identity, original):
                    if attempt == 0:
                        continue
                    raise UpdateError("configuration changed during update")
                os.replace(temporary, path)
                dir_fd = os.open(directory, os.O_RDONLY)
                try:
                    os.fsync(dir_fd)
                finally:
                    os.close(dir_fd)
                return pair
            finally:
                if fd is not None:
                    os.close(fd)
                if temporary is not None:
                    try:
                        os.unlink(temporary)
                    except FileNotFoundError:
                        pass
        raise UpdateError("configuration changed during update")
    finally:
        if lock_fd is not None:
            os.close(lock_fd)


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--kind", choices=("screensaver", "lock"), required=True)
    parser.add_argument("--seconds", required=True, type=int)
    args = parser.parse_args(argv)
    try:
        pair = write_config(args.config, args.kind, args.seconds)
        effective = {key: _seconds(value, key) for key, value in pair.items()}
        print(json.dumps(effective, separators=(",", ":")))
        return 0
    except (UpdateError, OSError) as exc:
        print("update-idle: %s" % exc, file=__import__("sys").stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
