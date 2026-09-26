"""Root-scoped mise environment for Caramel's toolchain installer.

`scripts/install-toolchain` copies this file into each installation as
`toolchain-provider.py` and runs mise with `build_environment(root)`. All mise,
XDG, conda and Crystal state stays below the installation root, and only the
installation's own configuration is visible to mise.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Dict, Mapping, Optional, Tuple


CONFIG_NAME = "caramel-toolchain.toml"

# Only these inherited values are allowed to cross into mise.  HOME is kept so
# programs which use it for display or identity continue to behave normally;
# mise's config/data paths below still point into the root.
INHERITED_ENV = ("HOME", "USER", "LOGNAME", "TMPDIR")

OWNED_DIRECTORIES = {
    "MISE_DATA_DIR": "data",
    "MISE_CACHE_DIR": "cache",
    "MISE_STATE_DIR": "state",
    "MISE_CONFIG_DIR": "config",
    "MISE_SYSTEM_CONFIG_DIR": "system-config",
    "MISE_SYSTEM_DATA_DIR": "system-data",
    "XDG_CACHE_HOME": "xdg-cache",
    "XDG_CONFIG_HOME": "xdg-config",
    "XDG_DATA_HOME": "xdg-data",
    "XDG_STATE_HOME": "xdg-state",
    "MAMBA_ROOT_PREFIX": "mamba",
    "CRYSTAL_CACHE_DIR": "crystal-cache",
}


def config_files(root: Path) -> Tuple[Path, Path, Path]:
    """Return the only config files supplied to mise.

    Keeping this small and explicit makes the discovery boundary testable: mise
    never searches for or reads config from an ancestor directory.
    """

    root = root.resolve()
    return (
        root / "config" / "empty.toml",
        root / "system-config" / "empty.toml",
        root / "project" / CONFIG_NAME,
    )


def build_environment(root: Path, inherited: Optional[Mapping[str, str]] = None) -> Dict[str, str]:
    """Build the filtered, root-scoped environment passed to mise."""

    root = root.resolve()
    source = os.environ if inherited is None else inherited
    env = {key: source[key] for key in INHERITED_ENV if source.get(key) is not None}
    env.update(
        {
            "PATH": f"{root / 'bin'}:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "TERM": "dumb",
            "MISE_COLOR": "0",
            "MISE_AUTO_ENV": "0",
            "MISE_ENV_CONF_D": "0",
            "MISE_OVERRIDE_TOOL_VERSIONS_FILENAMES": "none",
            "MISE_OVERRIDE_CONFIG_FILENAMES": CONFIG_NAME,
            "MISE_CEILING_PATHS": str(root),
            "MISE_ENV": "",
            "MISE_NO_ENV": "1",
            "MISE_NO_HOOKS": "1",
            "MISE_NETRC": "0",
            # Running exec must never install a missing tool implicitly.  The
            # explicit `install --locked` command remains available.
            "MISE_AUTO_INSTALL": "0",
            "MISE_PARANOID": "1",
            "MISE_LOCKFILE_PLATFORMS": "macos-arm64",
            "MISE_HTTP_TIMEOUT": "30s",
            "MISE_HTTP_DOWNLOAD_TIMEOUT": "3m",
            "MISE_HTTP_RETRIES": "1",
            "MISE_GLOBAL_CONFIG_FILE": str(root / "config" / "empty.toml"),
            "MISE_SYSTEM_CONFIG_FILE": str(root / "system-config" / "empty.toml"),
        }
    )
    for variable, child in OWNED_DIRECTORIES.items():
        path = root / child
        path.mkdir(parents=True, exist_ok=True)
        env[variable] = str(path)
    for empty_config in config_files(root)[:2]:
        empty_config.parent.mkdir(parents=True, exist_ok=True)
        empty_config.touch(exist_ok=True)
    return env
