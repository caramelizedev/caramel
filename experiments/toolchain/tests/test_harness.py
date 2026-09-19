from __future__ import annotations

import importlib.util
import io
from pathlib import Path
from shutil import copy2
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise AssertionError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


run_mise = load_module("run_mise", ROOT / "run-mise.py")
pg_lifecycle = load_module("pg_lifecycle", ROOT / "pg-lifecycle.py")


class HarnessBoundaryTests(unittest.TestCase):
    def fixture_root(self, temporary: str) -> Path:
        root = Path(temporary) / "experiment"
        (root / "project").mkdir(parents=True)
        copy2(ROOT / "run-mise.py", root / "run-mise.py")
        copy2(ROOT / "project" / "caramel-eval.toml", root / "project" / "caramel-eval.toml")
        copy2(ROOT / "project" / "mise.lock", root / "project" / "mise.lock")
        return root

    def test_environment_stops_at_copy_root_and_filters_inherited_values(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temporary:
            root = Path(temporary) / "experiment"
            root.mkdir()
            ancestor = root.parent / "mise.toml"
            ancestor.write_text("[tasks.sentinel]\nrun = 'echo should-not-run'\n", encoding="utf-8")
            try:
                env = run_mise.build_environment(
                    root,
                    {
                        "HOME": "/Users/example",
                        "USER": "example",
                        "LOGNAME": "example",
                        "TMPDIR": "/private/tmp",
                        "SECRET_SHOULD_NOT_CROSS": "redacted",
                    },
                )
                self.assertEqual(env["MISE_CEILING_PATHS"], str(root))
                self.assertEqual(env["MISE_ENV"], "")
                self.assertEqual(env["MISE_NO_ENV"], "1")
                self.assertEqual(env["MISE_NO_HOOKS"], "1")
                self.assertEqual(env["MISE_NETRC"], "0")
                self.assertNotIn("MISE_TRUSTED_CONFIG_PATHS", env)
                self.assertNotIn("SECRET_SHOULD_NOT_CROSS", env)
                self.assertEqual(
                    run_mise.config_files(root)[2],
                    root / "project" / "caramel-eval.toml",
                )
                self.assertNotIn(ancestor, run_mise.config_files(root))
            finally:
                ancestor.unlink()

    def test_existing_postgres_data_is_refused_without_modification(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temporary:
            root = self.fixture_root(temporary)
            cluster = root / "cluster"
            cluster.mkdir()
            marker = cluster / "keep.me"
            marker.write_text("untouched", encoding="utf-8")
            (cluster / "postmaster.pid").write_text("99999\n", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "pre-existing PostgreSQL data directory"):
                with patch.object(pg_lifecycle.subprocess, "run") as subprocess_run:
                    pg_lifecycle.run_lifecycle(root)
            subprocess_run.assert_not_called()
            self.assertEqual(marker.read_text(encoding="utf-8"), "untouched")

    def test_cleanup_failure_is_reported_after_owned_server_stops(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temporary:
            root = self.fixture_root(temporary)
            stop_calls = 0

            def fake_command(_log, args):
                nonlocal stop_calls
                tool = args[args.index("--") + 1]
                if tool == "initdb":
                    (root / "cluster").mkdir()
                    return subprocess.CompletedProcess(args, 0, "", "")
                if tool == "pg_ctl" and "start" in args:
                    (root / "cluster" / "postmaster.pid").write_text("123\n", encoding="utf-8")
                    return subprocess.CompletedProcess(args, 0, "", "")
                if tool == "pg_ctl" and "stop" in args:
                    stop_calls += 1
                    if stop_calls == 1:
                        (root / "cluster" / "postmaster.pid").unlink()
                        return subprocess.CompletedProcess(args, 0, "", "")
                    return subprocess.CompletedProcess(args, 9, "", "cleanup failed")
                if tool == "psql":
                    output = "t\n" if any("current_setting('listen_addresses')" in arg for arg in args) else "Bookshelf\n"
                    return subprocess.CompletedProcess(args, 0, output, "")
                raise AssertionError(args)

            with patch.object(pg_lifecycle.CommandLog, "command", new=fake_command):
                with redirect_stdout(io.StringIO()):
                    with self.assertRaisesRegex(RuntimeError, "cleanup stop exited 9"):
                        pg_lifecycle.run_lifecycle(root)
            self.assertTrue((root / "cluster" / "postmaster.pid").exists())

    def test_keyboard_interrupt_stops_owned_server_by_pid(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temporary:
            root = self.fixture_root(temporary)
            saw_stop = False

            def fake_command(_log, args):
                nonlocal saw_stop
                tool = args[args.index("--") + 1]
                if tool == "initdb":
                    (root / "cluster").mkdir()
                    return subprocess.CompletedProcess(args, 0, "", "")
                if tool == "pg_ctl" and "start" in args:
                    (root / "cluster" / "postmaster.pid").write_text("123\n", encoding="utf-8")
                    return subprocess.CompletedProcess(args, 0, "", "")
                if tool == "psql":
                    if any("current_setting('listen_addresses')" in arg for arg in args):
                        return subprocess.CompletedProcess(args, 0, "t\n", "")
                    raise KeyboardInterrupt
                if tool == "pg_ctl" and "stop" in args:
                    saw_stop = True
                    (root / "cluster" / "postmaster.pid").unlink()
                    return subprocess.CompletedProcess(args, 0, "", "")
                raise AssertionError(args)

            with patch.object(pg_lifecycle.CommandLog, "command", new=fake_command):
                with redirect_stdout(io.StringIO()):
                    with self.assertRaises(KeyboardInterrupt):
                        pg_lifecycle.run_lifecycle(root)
            self.assertTrue(saw_stop)
            self.assertFalse((root / "cluster" / "postmaster.pid").exists())

    def test_nonempty_listen_addresses_fails_and_stops_owned_server(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temporary:
            root = self.fixture_root(temporary)
            saw_stop = False

            def fake_command(_log, args):
                nonlocal saw_stop
                tool = args[args.index("--") + 1]
                if tool == "initdb":
                    (root / "cluster").mkdir()
                    return subprocess.CompletedProcess(args, 0, "", "")
                if tool == "pg_ctl" and "start" in args:
                    (root / "cluster" / "postmaster.pid").write_text("123\n", encoding="utf-8")
                    return subprocess.CompletedProcess(args, 0, "", "")
                if tool == "psql" and any("current_setting('listen_addresses')" in arg for arg in args):
                    return subprocess.CompletedProcess(args, 0, "f\n", "")
                if tool == "pg_ctl" and "stop" in args:
                    saw_stop = True
                    (root / "cluster" / "postmaster.pid").unlink()
                    return subprocess.CompletedProcess(args, 0, "", "")
                raise AssertionError(args)

            with patch.object(pg_lifecycle.CommandLog, "command", new=fake_command):
                with redirect_stdout(io.StringIO()):
                    with self.assertRaisesRegex(AssertionError, "listen_addresses"):
                        pg_lifecycle.run_lifecycle(root)
            self.assertTrue(saw_stop)
            self.assertFalse((root / "cluster" / "postmaster.pid").exists())


if __name__ == "__main__":
    unittest.main()
