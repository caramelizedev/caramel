import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[2] / "scripts/install-toolchain"
loader = importlib.machinery.SourceFileLoader("toolchain_installer", str(SOURCE))
spec = importlib.util.spec_from_loader(loader.name, loader)
installer = importlib.util.module_from_spec(spec)
loader.exec_module(installer)


class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="caramel-installer-unit-")
        self.root = Path(self.tmp.name) / "Toolchain With Spaces"
        self.payloads = {"project/caramel-toolchain.toml": b"[tools]\n", "project/mise.lock": b"version = 1\n"}
        self.critical = ["bin/mise", "data/installs/test/bin/compiler"]
        self.patch = patch.multiple(installer, authored_payloads=lambda: self.payloads, CRITICAL=self.critical, ALIASES={})
        self.patch.start()

    def tearDown(self):
        self.patch.stop()
        self.tmp.cleanup()

    def complete(self):
        with installer.Installation(self.root) as install:
            install.prepare()
            for name in self.critical:
                path = self.root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"fake verified artifact")
                path.chmod(0o700)
            install.complete()

    def test_unrelated_nonempty_directory_is_preserved(self):
        self.root.mkdir()
        existing = self.root / "notes.txt"
        existing.write_text("keep me")
        with self.assertRaisesRegex(RuntimeError, "nonempty"):
            with installer.Installation(self.root):
                pass
        self.assertEqual(existing.read_text(), "keep me")
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), ["notes.txt"])

    def test_partial_state_is_resumable_but_authored_configuration_cannot_change(self):
        with installer.Installation(self.root) as install:
            install.prepare()
        with installer.Installation(self.root) as install:
            install.prepare()
        config = self.root / "project/caramel-toolchain.toml"
        config.write_text("[tasks.unreviewed]\nrun = 'echo unsafe'\n")
        with self.assertRaisesRegex(RuntimeError, "differs"):
            with installer.Installation(self.root) as install:
                install.prepare()
        self.assertIn("unreviewed", config.read_text())

    def test_completed_installation_is_verified_without_downloads(self):
        self.complete()
        with installer.Installation(self.root) as install:
            self.assertTrue(install.verified())
            self.assertEqual(install.state["status"], "complete")
        with patch.object(installer, "install_payloads", side_effect=AssertionError("must not download")):
            installer.install(self.root, offline=True, preflight=False)

    def test_modified_binary_fails_closed_and_is_preserved(self):
        self.complete()
        binary = self.root / self.critical[-1]
        binary.write_text("changed")
        with self.assertRaisesRegex(RuntimeError, "verification"):
            with installer.Installation(self.root) as install:
                install.verified()
        self.assertEqual(binary.read_text(), "changed")

    def test_receipt_cannot_omit_a_required_binary(self):
        self.complete()
        receipt = self.root / installer.RECEIPT
        state = json.loads(receipt.read_text())
        state["artifacts"].pop(self.critical[-1])
        receipt.write_text(json.dumps(state))
        with self.assertRaisesRegex(RuntimeError, "artifact inventory"):
            with installer.Installation(self.root) as install:
                install.verified()

    def test_symlinked_state_and_payload_directories_are_refused(self):
        with installer.Installation(self.root) as install:
            install.prepare()
        other = Path(self.tmp.name) / "external"
        other.mkdir()
        (self.root / "data").rename(self.root / "data.original")
        (self.root / "data").symlink_to(other, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, "symlink"):
            with installer.Installation(self.root) as install:
                install.prepare()
        self.assertEqual(list(other.iterdir()), [])

    def test_other_installer_lock_is_not_taken_over(self):
        with installer.Installation(self.root) as first:
            first.prepare()
            with self.assertRaisesRegex(RuntimeError, "already running"):
                with installer.Installation(self.root):
                    pass

    def test_offline_incomplete_installation_fails_without_mutation(self):
        with patch.object(installer, "install_payloads", side_effect=AssertionError("must not download")):
            with self.assertRaisesRegex(RuntimeError, "offline"):
                installer.install(self.root, offline=True, preflight=False)
        self.assertFalse(self.root.exists())

    def test_failed_provider_keeps_resumable_state_and_retry_completes(self):
        with patch.object(installer, "install_payloads", side_effect=RuntimeError("download interrupted")):
            with self.assertRaisesRegex(RuntimeError, "interrupted"):
                installer.install(self.root, preflight=False)
        state = json.loads((self.root / installer.RECEIPT).read_text())
        self.assertEqual(state["status"], "installing")
        config_before = (self.root / "project/caramel-toolchain.toml").read_bytes()

        def complete_payloads(installation, **kwargs):
            for name in self.critical:
                path = self.root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"verified after retry")

        with patch.object(installer, "install_payloads", side_effect=complete_payloads):
            installer.install(self.root, preflight=False)
        self.assertEqual((self.root / "project/caramel-toolchain.toml").read_bytes(), config_before)
        self.assertEqual(json.loads((self.root / installer.RECEIPT).read_text())["status"], "complete")

    def test_moving_an_installation_requires_a_fresh_install(self):
        self.complete()
        moved = self.root.with_name("moved")
        self.root.rename(moved)
        with self.assertRaisesRegex(RuntimeError, "moved"):
            with installer.Installation(moved):
                pass

    def test_native_probe_rejects_libraries_from_other_package_managers(self):
        result = SimpleNamespace(stdout="Crystal 1.21.0\n", stderr="dyld[123]: <ABCD> /opt/homebrew/lib/libssl.3.dylib\n")
        with patch.object(installer.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(RuntimeError, "outside"):
                installer.verify_native_command(self.root, ["compiler", "--version"], "Crystal 1.21.0", {})

    def test_native_probe_checks_versions_and_requires_observed_libraries(self):
        root = self.root.resolve()
        result = SimpleNamespace(stdout="Crystal 1.21.0\n", stderr=f"dyld[123]: <ABCD> {root}/bin/compiler\ndyld[123]: <1234> /usr/lib/libSystem.B.dylib\n")
        with patch.object(installer.subprocess, "run", return_value=result):
            evidence = installer.verify_native_command(root, ["compiler", "--version"], "Crystal 1.21.0", {})
            self.assertEqual(len(evidence["libraries"]), 2)
            with self.assertRaisesRegex(RuntimeError, "version"):
                installer.verify_native_command(root, ["compiler", "--version"], "Crystal 1.20.0", {})
        with patch.object(installer.subprocess, "run", return_value=SimpleNamespace(stdout="ok", stderr="")):
            with self.assertRaisesRegex(RuntimeError, "library evidence"):
                installer.verify_native_command(root, ["compiler"], "ok", {})


if __name__ == "__main__":
    unittest.main()
