import importlib.util
from pathlib import Path
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[2] / "tools/toolchain/provider.py"
spec = importlib.util.spec_from_file_location("toolchain_provider", SOURCE)
provider = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provider)


class ProviderEnvironmentTests(unittest.TestCase):
    def test_environment_stops_at_the_root_and_filters_inherited_values(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temporary:
            root = Path(temporary) / "toolchain"
            root.mkdir()
            ancestor = root.parent / "mise.toml"
            ancestor.write_text("[tasks.sentinel]\nrun = 'echo should-not-run'\n", encoding="utf-8")
            env = provider.build_environment(root, {
                "HOME": "/Users/example",
                "USER": "example",
                "LOGNAME": "example",
                "TMPDIR": "/private/tmp",
                "SECRET_SHOULD_NOT_CROSS": "redacted",
            })
            self.assertEqual(env["MISE_CEILING_PATHS"], str(root.resolve()))
            self.assertEqual(env["MISE_OVERRIDE_CONFIG_FILENAMES"], "caramel-toolchain.toml")
            self.assertEqual(env["MISE_ENV"], "")
            self.assertEqual(env["MISE_NO_ENV"], "1")
            self.assertEqual(env["MISE_NO_HOOKS"], "1")
            self.assertEqual(env["MISE_NETRC"], "0")
            self.assertEqual(env["MISE_AUTO_INSTALL"], "0")
            self.assertNotIn("MISE_TRUSTED_CONFIG_PATHS", env)
            self.assertNotIn("SECRET_SHOULD_NOT_CROSS", env)
            for variable in provider.OWNED_DIRECTORIES:
                self.assertTrue(Path(env[variable]).is_relative_to(root.resolve()), variable)
            configs = provider.config_files(root)
            self.assertEqual(configs[2], root.resolve() / "project/caramel-toolchain.toml")
            self.assertNotIn(ancestor.resolve(), configs)
            self.assertTrue(configs[0].is_file() and configs[1].is_file())


if __name__ == "__main__":
    unittest.main()
