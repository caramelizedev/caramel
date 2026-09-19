"""Integrity and interrupted-install checks; no network or user tool state."""
import hashlib
import importlib.machinery
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/install-latte-tools"
loader = importlib.machinery.SourceFileLoader("latte_tools", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)


class ToolInstallTest(unittest.TestCase):
    def fixture(self, root, data=b"verified executable", member="coredns"):
        archive = root / "test.tgz"
        with tarfile.open(archive, "w:gz") as stream:
            info = tarfile.TarInfo(member)
            info.size = len(data)
            stream.addfile(info, io.BytesIO(data))
        entry = {"version": "1.14.7", "archive_sha256": module.digest(archive),
                 "binary_sha256": hashlib.sha256(data).hexdigest()}
        return archive, entry

    def test_verified_install_is_repeatable_and_private(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive, entry = self.fixture(root)
            target = root / "version"
            module.install_archive(archive, target, entry)
            module.install_archive(archive, target, entry)
            self.assertEqual((target / "coredns").read_bytes(), b"verified executable")
            self.assertEqual(target.stat().st_mode & 0o777, 0o700)
            self.assertEqual((target / "coredns").stat().st_mode & 0o777, 0o755)

    def test_bad_download_cannot_replace_existing_install(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive, entry = self.fixture(root)
            target = root / "version"
            module.install_archive(archive, target, entry)
            (target / "coredns").write_bytes(b"tampered")
            with self.assertRaisesRegex(RuntimeError, "existing"):
                module.install_archive(archive, target, entry)
            self.assertEqual((target / "coredns").read_bytes(), b"tampered")

    def test_integrity_failure_leaves_no_partial_install(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive, entry = self.fixture(root)
            entry["binary_sha256"] = "0" * 64
            target = root / "version"
            with self.assertRaisesRegex(RuntimeError, "binary checksum"):
                module.install_archive(archive, target, entry)
            self.assertFalse(target.exists())
            self.assertEqual(sorted(p.name for p in root.iterdir()), ["test.tgz"])

    def test_archive_paths_and_symlink_targets_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive, entry = self.fixture(root, member="../coredns")
            with self.assertRaisesRegex(RuntimeError, "archive"):
                module.install_archive(archive, root / "version", entry)
            (root / "real").mkdir()
            (root / "version").symlink_to(root / "real")
            with self.assertRaisesRegex(RuntimeError, "symlink"):
                module.install_archive(archive, root / "version", entry)


if __name__ == "__main__":
    unittest.main()
