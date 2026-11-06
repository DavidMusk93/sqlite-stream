"""Process-level faults and WAL snapshot contracts; Python is test-only."""
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest

BINARY = str(Path(sys.argv.pop(1)).resolve())


class CliContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sqlite-stream-", dir=os.getenv("TMPDIR"))
        self.root = Path(self.temp.name)
        self.source = self.root / "source.db"
        self.archive = self.root / "backup.sqls.zst"
        self.target = self.root / "restored.db"

    def tearDown(self):
        self.temp.cleanup()

    def run_tool(self, *args, ok=True, **kwargs):
        result = subprocess.run([BINARY, *map(str, args)], capture_output=True, timeout=15, **kwargs)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def seed(self, rows=2, blob=65536, wal=False):
        db = sqlite3.connect(self.source)
        if wal:
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("PRAGMA wal_autocheckpoint=0")
        db.execute("CREATE TABLE x(id INTEGER PRIMARY KEY, v BLOB)")
        db.executemany("INSERT INTO x(v) VALUES(randomblob(?))", [(blob,)] * rows)
        db.commit()
        if wal:
            db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        return db

    def no_staging(self):
        self.assertEqual(list(self.root.glob(".sqlite-stream-*")), [])

    def test_file_and_pipe_roundtrip(self):
        with self.seed() as db:
            expected = db.execute("SELECT id,hex(v) FROM x ORDER BY id").fetchall()
        self.run_tool("backup", self.source, self.archive)
        self.run_tool("verify", self.archive, "--scratch", self.root)
        self.run_tool("restore", "-", self.target, input=self.archive.read_bytes())
        with sqlite3.connect(self.target) as db:
            self.assertEqual(db.execute("SELECT id,hex(v) FROM x ORDER BY id").fetchall(), expected)
        self.no_staging()

    def test_existing_files_and_dangling_symlinks_are_preserved(self):
        self.seed().close()
        self.archive.write_bytes(b"keep")
        self.run_tool("backup", self.source, self.archive, ok=False)
        self.assertEqual(self.archive.read_bytes(), b"keep")
        self.target.symlink_to(self.root / "missing")
        self.run_tool("restore", self.archive, self.target, ok=False)
        self.assertTrue(self.target.is_symlink())
        self.no_staging()

    def test_restore_database_rows_and_input_caps_leave_no_output(self):
        self.seed().close()
        self.run_tool("backup", self.source, self.archive)
        for option, maximum in [
            ("--max-database-bytes", 8192),
            ("--max-rows", 1),
            ("--max-archive-bytes", 100),
        ]:
            with self.subTest(option=option):
                self.run_tool("restore", self.archive, self.target, option, maximum, ok=False)
                self.assertFalse(self.target.exists())
                self.no_staging()

    def test_backup_row_and_output_caps_leave_no_output(self):
        self.seed().close()
        for option, maximum in [
            ("--max-row-bytes", 1024),
            ("--max-rows", 1),
            ("--max-archive-bytes", 100),
        ]:
            with self.subTest(option=option):
                self.run_tool("backup", self.source, self.archive, option, maximum, ok=False)
                self.assertFalse(self.archive.exists())
                self.no_staging()

    def test_blocked_stdin_has_deadline(self):
        start = time.monotonic()
        process = subprocess.Popen(
            [BINARY, "verify", "-", "--scratch", str(self.root), "--timeout-seconds", "1"],
            stdin=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        try:
            self.assertNotEqual(process.wait(timeout=4), 0)
            self.assertIn(b"Deadline", process.stderr.read())
            self.assertLess(time.monotonic() - start, 3)
        finally:
            process.stdin.close()
            process.stderr.close()
            if process.poll() is None:
                process.kill()
                process.wait()
        self.no_staging()

    def test_blocked_stdout_has_deadline(self):
        self.seed(rows=2, blob=1048576).close()
        start = time.monotonic()
        process = subprocess.Popen(
            [BINARY, "backup", str(self.source), "-", "--timeout-seconds", "1"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        try:
            self.assertNotEqual(process.wait(timeout=4), 0)
            self.assertIn(b"Deadline", process.stderr.read())
            self.assertLess(time.monotonic() - start, 3)
        finally:
            process.stdout.close()
            process.stderr.close()
            if process.poll() is None:
                process.kill()
                process.wait()

    def test_concurrent_ddl_and_rows_share_original_snapshot(self):
        writer = self.seed(rows=16, blob=65536, wal=True)
        process = subprocess.Popen(
            [BINARY, "backup", str(self.source), "-", "--timeout-seconds", "10"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0,
        )
        try:
            prefix = process.stdout.read(4)  # Bytes imply schema/checks/scan already started.
            self.assertEqual(len(prefix), 4)
            writer.executescript("CREATE TABLE later(v); INSERT INTO x(v) VALUES(x'aa');")
            writer.commit()
            remaining, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, stderr)
            self.archive.write_bytes(prefix + remaining)
            self.run_tool("restore", self.archive, self.target)
            with sqlite3.connect(self.target) as db:
                self.assertEqual(db.execute("SELECT count(*) FROM x").fetchone()[0], 16)
                self.assertEqual(db.execute("SELECT count(*) FROM sqlite_schema WHERE name='later'").fetchone()[0], 0)
            self.assertEqual(writer.execute("SELECT count(*) FROM x").fetchone()[0], 17)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            writer.close()

    def test_wal_growth_aborts_and_releases_snapshot(self):
        writer = self.seed(rows=16, blob=65536, wal=True)
        process = subprocess.Popen(
            [BINARY, "backup", str(self.source), "-", "--max-wal-bytes", "8192"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        try:
            self.assertEqual(len(process.stdout.read(4)), 4)
            writer.execute("INSERT INTO x(v) VALUES(randomblob(65536))")
            writer.commit()
            self.assertNotEqual(process.wait(timeout=4), 0)
            self.assertIn(b"WalBudget", process.stderr.read())
            self.assertEqual(writer.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()[0], 0)
        finally:
            process.stdout.close()
            process.stderr.close()
            if process.poll() is None:
                process.kill()
                process.wait()
            writer.close()

    def test_sigterm_aborts_and_releases_snapshot(self):
        writer = self.seed(rows=16, blob=65536, wal=True)
        process = subprocess.Popen(
            [BINARY, "backup", str(self.source), "-"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        try:
            self.assertEqual(len(process.stdout.read(4)), 4)
            process.send_signal(signal.SIGTERM)
            self.assertNotEqual(process.wait(timeout=4), 0)
            self.assertIn(b"Cancelled", process.stderr.read())
            self.assertEqual(writer.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()[0], 0)
        finally:
            process.stdout.close()
            process.stderr.close()
            if process.poll() is None:
                process.kill()
                process.wait()
            writer.close()

    @unittest.skipUnless(Path("/dev/full").exists(), "Linux ENOSPC device")
    def test_enospc_releases_source_snapshot(self):
        writer = self.seed(rows=16, blob=65536, wal=True)
        try:
            with open("/dev/full", "wb") as full:
                result = subprocess.run([BINARY, "backup", str(self.source), "-"],
                                        stdout=full, stderr=subprocess.PIPE, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"Write", result.stderr)
            self.assertEqual(writer.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()[0], 0)
        finally:
            writer.close()

    def test_invalid_utf16_and_shadowed_rowid_fail_explicitly(self):
        with sqlite3.connect(self.source) as db:
            db.executescript("PRAGMA encoding='UTF-16'; CREATE TABLE x(v); INSERT INTO x VALUES(1);")
        self.run_tool("backup", self.source, self.archive, ok=False)
        self.assertFalse(self.archive.exists())
        self.source.unlink()
        with sqlite3.connect(self.source) as db:
            db.execute("CREATE TABLE x(rowid,_rowid_,oid)")
        result = self.run_tool("backup", self.source, self.archive, ok=False)
        self.assertIn(b"ShadowedRowid", result.stderr)
        self.no_staging()


if __name__ == "__main__":
    unittest.main(verbosity=2)
