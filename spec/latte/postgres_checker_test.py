import contextlib
import importlib.machinery
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
loader = importlib.machinery.SourceFileLoader('postgres_checker', str(REPO / 'scripts/check-latte-postgres'))
spec = importlib.util.spec_from_loader(loader.name, loader)
checker = importlib.util.module_from_spec(spec)
loader.exec_module(checker)


class PostgresCheckerCleanupTest(unittest.TestCase):
    def exercise(self, failure, cluster):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as parent:
            parent = Path(parent)
            tools = parent / 'tools/data/installs/conda-postgresql/18.6/bin'
            tools.mkdir(parents=True)
            for name in ('initdb', 'pg_ctl'):
                (tools / name).touch()
            root = parent / 'owned'
            root.mkdir(mode=0o700)

            def run(argv, **kwargs):
                if argv[0].endswith('scripts/crystal'):
                    if not cluster:
                        raise PermissionError('compiler is not executable')
                    data = root / 'services/postgres/18/data'
                    data.mkdir(parents=True)
                    (data / 'postmaster.pid').write_text('123\n')
                    return subprocess.CompletedProcess(argv, 0)
                if failure == 'timeout':
                    raise subprocess.TimeoutExpired(argv, 30)
                (root / 'services/postgres/18/data/postmaster.pid').unlink()
                return subprocess.CompletedProcess(argv, 1)

            messages = io.StringIO()
            with patch.dict(os.environ, {'CARAMEL_TOOLCHAIN_ROOT': str(parent / 'tools')}), \
                    patch.object(checker.sys, 'argv', ['check-latte-postgres']), \
                    patch.object(checker.tempfile, 'mkdtemp', return_value=str(root)), \
                    patch.object(checker.subprocess, 'run', side_effect=run), \
                    patch.object(checker, 'owned_postgres_pid', return_value=True), \
                    contextlib.redirect_stderr(messages):
                code = checker.main()
            return code, root.exists(), messages.getvalue()

    def test_compiler_launch_error_cleans_empty_owned_root(self):
        code, preserved, _ = self.exercise('launch', False)
        self.assertEqual(code, 127)
        self.assertFalse(preserved)

    def test_cleanup_timeout_preserves_cluster_and_reports_path(self):
        code, preserved, message = self.exercise('timeout', True)
        self.assertEqual(code, 1)
        self.assertTrue(preserved)
        self.assertIn('Preserved owned integration root:', message)

    def test_missing_pid_after_failed_stop_does_not_authorize_deletion(self):
        code, preserved, message = self.exercise('missing-pid', True)
        self.assertEqual(code, 1)
        self.assertTrue(preserved)
        self.assertIn('Preserved owned integration root:', message)
