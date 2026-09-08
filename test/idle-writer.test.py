#!/usr/bin/env python3
import importlib.util
import fcntl
import json
import os
import stat
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPEC = importlib.util.spec_from_file_location("idle_writer", os.path.join(ROOT, "tools", "update-idle.py"))
writer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(writer)


class IdleWriterTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.directory.name, "shell.json")
        self.original = {"version": 1, "idle": {"screensaver": 300, "lock": 600},
                         "bar": {"layout": {"left": [{"id": "x"}]}}, "other": [1, 2]}
        self._save(self.original)

    def tearDown(self):
        self.directory.cleanup()

    def _save(self, value):
        with open(self.path, "w", encoding="utf-8") as stream:
            json.dump(value, stream)

    def _load(self):
        with open(self.path, encoding="utf-8") as stream:
            return json.load(stream)

    def test_moved_key_clamps_partner_and_preserves_unrelated(self):
        self.assertEqual(writer.write_config(self.path, "screensaver", 600),
                         {"screensaver": 600, "lock": 900})
        result = self._load()
        self.assertEqual(result["idle"], {"screensaver": 600, "lock": 900})
        self.assertEqual(result["bar"], self.original["bar"])
        self.assertEqual(result["other"], [1, 2])

    def test_lock_move_clamps_screensaver_below(self):
        self._save({"version": 1, "idle": {"screensaver": 900, "lock": 120}, "x": 4})
        writer.write_config(self.path, "lock", 300)
        self.assertEqual(self._load()["idle"], {"screensaver": 180, "lock": 300})

    def test_rejects_bad_inputs(self):
        for bad in ("{", {"version": 2, "idle": {}}, {"version": 1},
                    {"version": 1, "idle": []}, {"version": 1, "idle": {"screensaver": "x", "lock": 300}}):
            if isinstance(bad, str):
                with open(self.path, "w") as stream:
                    stream.write(bad)
            else:
                self._save(bad)
            with self.assertRaises(writer.UpdateError):
                writer.write_config(self.path, "lock", 300)
            self._save(self.original)

    def test_rejects_symlink_oversize_and_directory(self):
        link = os.path.join(self.directory.name, "link.json")
        os.symlink(self.path, link)
        with self.assertRaises(writer.UpdateError):
            writer.write_config(link, "lock", 300)
        with open(self.path, "wb") as stream:
            stream.write(b"x" * (writer.MAX_BYTES + 1))
        with self.assertRaises(writer.UpdateError):
            writer.write_config(self.path, "lock", 300)

    def test_mode_and_temp_cleanup(self):
        os.chmod(self.path, 0o640)
        writer.write_config(self.path, "lock", 900)
        self.assertEqual(stat.S_IMODE(os.stat(self.path).st_mode), 0o640)
        self.assertEqual([x for x in os.listdir(self.directory.name) if "ristretto-idle-" in x], [])
        self.assertTrue(os.path.exists(self.path + ".ristretto.lock"))

    def test_valid_off_scale_partner_is_untouched(self):
        self._save({"version": 1, "idle": {"screensaver": 150, "lock": 420}, "x": 1})
        writer.write_config(self.path, "screensaver", 120)
        self.assertEqual(self._load()["idle"], {"screensaver": 120, "lock": 420})

    def test_string_and_fraction_partner_is_preserved_exactly(self):
        self._save({"version": 1, "idle": {"screensaver": "150", "lock": "420.9"}, "x": 1})
        writer.write_config(self.path, "screensaver", 120)
        self.assertEqual(self._load()["idle"], {"screensaver": 120, "lock": "420.9"})

    def test_read_open_failure_is_update_error(self):
        missing = os.path.join(self.directory.name, "missing.json")
        with self.assertRaises(writer.UpdateError) as caught:
            writer._read(missing)
        self.assertNotIn("UnboundLocalError", str(caught.exception))

    def test_lock_sidecar_symlink_is_rejected(self):
        lock_path = self.path + ".ristretto.lock"
        target = os.path.join(self.directory.name, "other.lock")
        with open(target, "w"):
            pass
        os.symlink(target, lock_path)
        with self.assertRaises(writer.UpdateError):
            writer.write_config(self.path, "lock", 900)

    def test_flock_failure_closes_sidecar_fd(self):
        lock_path = self.path + ".ristretto.lock"
        original_flock = writer.fcntl.flock
        original_close = writer.os.close
        closed = []
        def failing_flock(fd, operation):
            raise OSError("flock failure")
        def recording_close(fd):
            closed.append(fd)
            return original_close(fd)
        writer.fcntl.flock = failing_flock
        writer.os.close = recording_close
        try:
            with self.assertRaises(writer.UpdateError):
                writer.write_config(self.path, "lock", 900)
        finally:
            writer.fcntl.flock = original_flock
            writer.os.close = original_close
        self.assertTrue(closed)
        os.unlink(lock_path)

    def test_same_read_exception_closes_descriptor(self):
        identity = os.stat(self.path)
        key = (identity.st_dev, identity.st_ino, identity.st_size, identity.st_mtime_ns)
        original_fdopen = writer.os.fdopen
        original_close = writer.os.close
        closed = []
        writer.os.fdopen = lambda fd, mode: (_ for _ in ()).throw(OSError("fdopen failure"))
        writer.os.close = lambda fd: (closed.append(fd), original_close(fd))[1]
        try:
            self.assertFalse(writer._same(self.path, key, b""))
        finally:
            writer.os.fdopen = original_fdopen
            writer.os.close = original_close
        self.assertTrue(closed)

    def test_directory_is_rejected(self):
        with self.assertRaises(writer.UpdateError):
            writer.write_config(self.directory.name, "lock", 300)

    def test_write_error_cleans_temporary_file(self):
        original_fsync = writer.os.fsync
        writer.os.fsync = lambda fd: (_ for _ in ()).throw(OSError("fsync failure"))
        try:
            with self.assertRaises(OSError):
                writer.write_config(self.path, "lock", 900)
        finally:
            writer.os.fsync = original_fsync
        self.assertEqual([x for x in os.listdir(self.directory.name) if "ristretto-idle-" in x], [])

    def test_first_conflict_retries(self):
        original_same = writer._same
        calls = [0]
        def conflict_once(path, identity, data):
            calls[0] += 1
            return False if calls[0] == 1 else original_same(path, identity, data)
        writer._same = conflict_once
        try:
            writer.write_config(self.path, "lock", 900)
        finally:
            writer._same = original_same
        self.assertEqual(calls[0], 2)
        self.assertEqual(self._load()["idle"]["lock"], 900)

    def test_external_change_is_preserved_by_retry(self):
        original_same = writer._same
        calls = [0]
        def external_change(path, identity, data):
            calls[0] += 1
            if calls[0] == 1:
                with open(path, "w") as stream:
                    json.dump({"version": 1, "idle": {"screensaver": 150, "lock": 420}, "external": True}, stream)
                return False
            return original_same(path, identity, data)
        writer._same = external_change
        try:
            writer.write_config(self.path, "screensaver", 120)
        finally:
            writer._same = original_same
        self.assertEqual(self._load()["idle"], {"screensaver": 120, "lock": 420})
        self.assertTrue(self._load()["external"])

    def test_released_flock_allows_recovery_after_writer_exit(self):
        lock_path = self.path + ".ristretto.lock"
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        os.close(fd)
        writer.write_config(self.path, "lock", 900)

    def test_recurring_conflict_does_not_overwrite(self):
        original_same = writer._same
        writer._same = lambda path, identity, data: False
        try:
            with self.assertRaises(writer.UpdateError):
                writer.write_config(self.path, "lock", 900)
        finally:
            writer._same = original_same
        self.assertEqual(self._load(), self.original)
        self.assertEqual(sorted(os.listdir(self.directory.name)), ["shell.json", "shell.json.ristretto.lock"])


if __name__ == "__main__":
    unittest.main()
