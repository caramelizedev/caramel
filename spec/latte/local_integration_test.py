import contextlib
import importlib.machinery
import io
import json
import os
import plistlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
installer = importlib.machinery.SourceFileLoader('local_integration', str(REPO / 'scripts/install-local-integration')).load_module()

class IntegrationInstallerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='caramel-installer-')
        self.root = Path(self.temp.name)
        self.bundle = self.root / 'bundle'
        with contextlib.redirect_stdout(io.StringIO()):
            installer.prepare(self.bundle)

    def tearDown(self):
        self.temp.cleanup()

    def test_prepare_contains_only_fixed_owned_configuration(self):
        manifest, data = installer.load_bundle(self.bundle)
        self.assertEqual(manifest['uid'], os.getuid())
        self.assertEqual(set(data), {'relay', 'plist', 'resolver'})
        self.assertIn(b'port 15353', data['resolver'])
        self.assertEqual(self.bundle.stat().st_mode & 0o777, 0o700)

    def test_modified_artifact_is_rejected(self):
        (self.bundle / 'relay').write_bytes(b'changed')
        with self.assertRaisesRegex(RuntimeError, 'checksum'):
            installer.load_bundle(self.bundle)

    def test_symlink_artifact_is_rejected(self):
        (self.bundle / 'relay').unlink()
        (self.bundle / 'relay').symlink_to(REPO / 'bin/latte-port-relay')
        with self.assertRaisesRegex(RuntimeError, 'ownership or permissions'):
            installer.load_bundle(self.bundle)

    def test_manifest_cannot_change_resolver_scope(self):
        data = b'nameserver 8.8.8.8\n'
        (self.bundle / 'resolver').write_bytes(data)
        manifest = json.loads((self.bundle / 'manifest.json').read_text())
        manifest['sha256']['resolver'] = installer.digest(data)
        (self.bundle / 'manifest.json').write_text(json.dumps(manifest))
        with self.assertRaisesRegex(RuntimeError, 'fixed scope'):
            installer.load_bundle(self.bundle)

    def test_manifest_cannot_run_the_relay_as_root(self):
        plist = plistlib.loads((self.bundle / 'plist').read_bytes())
        plist['UserName'] = 'root'
        data = plistlib.dumps(plist)
        (self.bundle / 'plist').write_bytes(data)
        manifest = json.loads((self.bundle / 'manifest.json').read_text())
        manifest['sha256']['plist'] = installer.digest(data)
        (self.bundle / 'manifest.json').write_text(json.dumps(manifest))
        with self.assertRaisesRegex(RuntimeError, 'fixed template'):
            installer.load_bundle(self.bundle)

    def test_existing_unowned_resolver_is_preserved(self):
        existing = self.root / 'caramel'
        existing.write_bytes(b'existing local resolver')
        with patch.object(installer, 'DESTINATIONS', {**installer.DESTINATIONS, 'resolver': existing}), \
             patch.object(installer, 'RECEIPT', self.root / 'missing-receipt'), \
             patch.object(installer.os, 'geteuid', return_value=0):
            with self.assertRaisesRegex(RuntimeError, 'Existing configuration was preserved'):
                installer.apply(self.bundle)
        self.assertEqual(existing.read_bytes(), b'existing local resolver')
        self.assertFalse((self.root / 'missing-receipt').exists())

    def test_same_label_job_from_another_plist_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'not owned'):
            installer.verify_job('path = /Library/LaunchDaemons/other.plist\nprogram = /tmp/other\n')

    def test_same_path_job_with_extra_arguments_is_rejected(self):
        description = (f"path = {installer.DESTINATIONS['plist']}\n"
                       f"program = {installer.DESTINATIONS['relay']}\n"
                       f"arguments = {{\n{installer.DESTINATIONS['relay']}\n--extra\n}}\n")
        with self.assertRaisesRegex(RuntimeError, 'unexpected arguments'):
            installer.verify_job(description)

    def test_port_conflict_closes_every_reserved_socket(self):
        from unittest.mock import MagicMock
        first, second = MagicMock(), MagicMock()
        second.bind.side_effect = OSError('Address already in use')
        with patch.object(installer.socket, 'socket', side_effect=[first, second]):
            with self.assertRaisesRegex(RuntimeError, '443'):
                installer.reserve_ports()
        first.close.assert_called_once()
        second.close.assert_called_once()

    def test_resume_checks_ports_when_its_job_is_absent(self):
        manifest, _ = installer.load_bundle(self.bundle)
        with patch.object(installer.os, 'geteuid', return_value=0), \
             patch.object(installer, 'read_receipt', return_value=manifest), \
             patch.object(installer, 'require_owned_files'), \
             patch.object(installer, 'job_description', return_value=None), \
             patch.object(installer, 'reserve_ports', side_effect=RuntimeError('Port 443 is occupied')), \
             patch.object(installer, 'atomic_write') as write:
            with self.assertRaisesRegex(RuntimeError, '443'):
                installer.apply(self.bundle)
        write.assert_not_called()

    def test_competing_job_is_preserved_while_fresh_transaction_rolls_back(self):
        destinations = {name: self.root / name for name in installer.DESTINATIONS}
        foreign = 'path = /Library/LaunchDaemons/foreign.plist\n'
        with patch.object(installer.os, 'geteuid', return_value=0), \
             patch.object(installer, 'DESTINATIONS', destinations), \
             patch.object(installer, 'load_bundle', return_value=({'uid': os.getuid()}, {key: b'x' for key in destinations})), \
             patch.object(installer, 'read_receipt', return_value=None), \
             patch.object(installer, 'job_description', side_effect=[None, foreign, foreign]), \
             patch.object(installer, 'reserve_ports', return_value=[]), \
             patch.object(installer, 'atomic_write'), \
             patch.object(installer, 'remove_owned_files') as cleanup, \
             patch.object(installer.subprocess, 'run') as command:
            with self.assertRaisesRegex(RuntimeError, 'not owned'):
                installer.apply(self.bundle)
        cleanup.assert_called_once()
        command.assert_not_called()

if __name__ == '__main__':
    unittest.main(verbosity=2)
