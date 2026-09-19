#!/usr/bin/env python3
"""Run the pinned mise experiment with all state below this directory.

This is a research harness, not an installer.  Copy the whole experiment to
a disposable directory outside a Git checkout before invoking it.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import time
from typing import Dict, Mapping, Optional, Tuple


ROOT = Path(__file__).resolve().parent
PROJECT = ROOT / "project"
CONFIG = PROJECT / "caramel-eval.toml"
MISE = ROOT / "bin" / "mise"

# Only these inherited values are allowed to cross into mise.  HOME is kept so
# programs which use it for display or identity continue to behave normally;
# mise's config/data paths below still point into ROOT.
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


def git_checkout_root(path: Path) -> Optional[Path]:
    """Return the nearest Git checkout containing *path*, if one is visible."""

    for candidate in (path, *path.parents):
        marker = candidate / ".git"
        if marker.exists():
            return candidate
    return None


def validate_root(root: Path = ROOT) -> None:
    """Validate the copied experiment before any directory is created."""

    root = root.resolve()
    if not root.is_dir():
        raise RuntimeError(f"experiment root does not exist: {root}")
    checkout = git_checkout_root(root)
    if checkout is not None:
        raise RuntimeError(
            "refusing to run inside a Git checkout; copy experiments/toolchain "
            "to a fresh tempfile directory first"
        )
    project = root / "project"
    config = project / "caramel-eval.toml"
    mise = root / "bin" / "mise"
    if not project.is_dir() or not config.is_file():
        raise RuntimeError(f"missing copied project config below {root}")
    if config.is_symlink() or config.resolve().parent != project.resolve():
        raise RuntimeError(f"project config must be a regular copied file: {config}")
    if not (project / "mise.lock").is_file():
        raise RuntimeError(f"missing locked tool selection: {project / 'mise.lock'}")
    if not mise.is_file() or not os.access(mise, os.X_OK):
        raise RuntimeError(f"missing executable {mise}; download the pinned mise binary into bin/")


def config_files(root: Path = ROOT) -> Tuple[Path, Path, Path]:
    """Return the only config files supplied to mise.

    Keeping this small and explicit makes the discovery boundary testable: the
    wrapper does not search for or copy config from an ancestor directory.
    """

    root = root.resolve()
    return (
        root / "config" / "empty.toml",
        root / "system-config" / "empty.toml",
        root / "project" / "caramel-eval.toml",
    )


def build_environment(root: Path = ROOT, inherited: Optional[Mapping[str, str]] = None) -> Dict[str, str]:
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
            "MISE_OVERRIDE_CONFIG_FILENAMES": "caramel-eval.toml",
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


def usage() -> str:
    return (
        "usage: python3 run-mise.py MISE_ARGS...\n\n"
        "Run mise from project/ with root-scoped state and filtered environment.\n"
        "Copy this directory outside a Git checkout before normal use.\n"
        "Examples:\n"
        "  python3 run-mise.py install --locked\n"
        "  python3 run-mise.py exec -- crystal --version\n"
    )


def main(argv: Optional[list[str]] = None) -> int:
    mise_args = list(sys.argv[1:] if argv is None else argv)
    if not mise_args or mise_args[0] in {"-h", "--help"}:
        print(usage(), end="")
        return 0
    try:
        validate_root(ROOT)
    except RuntimeError as error:
        print(f"run-mise: {error}", file=sys.stderr)
        return 2

    env = build_environment(ROOT)
    start = time.monotonic()
    result = subprocess.run(
        [str(MISE), *mise_args],
        cwd=PROJECT,
        env=env,
    )
    print(
        json.dumps(
            {
                "args": mise_args,
                "seconds": round(time.monotonic() - start, 3),
                "exit": result.returncode,
            }
        ),
        file=sys.stderr,
    )
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
