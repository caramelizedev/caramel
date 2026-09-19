#!/usr/bin/env python3
"""Exercise PostgreSQL lifecycle ownership in a disposable experiment root."""

from __future__ import annotations

import json
from pathlib import Path
import shlex
import subprocess
import sys
from typing import List, Optional, TextIO


ROOT = Path(__file__).resolve().parent
CLUSTER = ROOT / "cluster"
SOCKET = ROOT / "socket"
LOGS = ROOT / "logs"
PORT = "55439"


def git_checkout_root(path: Path) -> Optional[Path]:
    for candidate in (path.resolve(), *path.resolve().parents):
        if (candidate / ".git").exists():
            return candidate
    return None


def validate_root(root: Path = ROOT) -> None:
    root = root.resolve()
    checkout = git_checkout_root(root)
    if checkout is not None:
        raise RuntimeError(
            "refusing to run inside a Git checkout; copy experiments/toolchain "
            "to a fresh tempfile directory first"
        )
    if not (root / "run-mise.py").is_file() or not (root / "project" / "mise.lock").is_file():
        raise RuntimeError(f"missing copied mise harness below {root}")
    if (root / "project" / "caramel-eval.toml").is_symlink():
        raise RuntimeError("project config must be a copied file")


def require_fresh_cluster(cluster: Path = CLUSTER) -> None:
    """Refuse every pre-existing cluster path; never reuse or overwrite data."""

    if cluster.exists() or cluster.is_symlink():
        raise RuntimeError(f"refusing pre-existing PostgreSQL data directory: {cluster}")


def ensure_socket_directory(socket: Path = SOCKET) -> None:
    if socket.exists() and not socket.is_dir():
        raise RuntimeError(f"private socket path is not a directory: {socket}")
    socket.mkdir(mode=0o700, parents=False, exist_ok=True)
    socket.chmod(0o700)


def usage() -> str:
    return (
        "usage: python3 pg-lifecycle.py\n\n"
        "Initialize, query, stop, restart, and stop a private disposable cluster.\n"
        "The cluster path is fixed to this script's parent/cluster and must not exist.\n"
    )


class CommandLog:
    def __init__(self, stream: TextIO, path: Path) -> None:
        self.stream = stream
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.file = self.path.open("w", encoding="utf-8")

    def close(self) -> None:
        self.file.close()

    def write(self, text: str) -> None:
        self.stream.write(text)
        self.stream.flush()
        self.file.write(text)
        self.file.flush()

    def command(self, args: list[str]) -> subprocess.CompletedProcess[str]:
        line = f"COMMAND {json.dumps(args)}\n"
        self.write(line)
        result = subprocess.run(args, text=True, capture_output=True)
        if result.stdout:
            self.write(result.stdout)
        if result.stderr:
            self.write(result.stderr)
        self.write(f"EXIT {result.returncode}\n")
        return result


def run_lifecycle(root: Path = ROOT) -> None:
    validate_root(root)
    cluster = root / "cluster"
    socket = root / "socket"
    logs = root / "logs"
    server_log = logs / "postgres-server.txt"
    run_log = logs / "pg-lifecycle-run.txt"
    # Check before opening logs or entering the cleanup block.  A refused
    # pre-existing path must never make this helper stop someone else's server.
    require_fresh_cluster(cluster)
    ensure_socket_directory(socket)
    log = CommandLog(sys.stdout, run_log)
    base = [sys.executable, str(root / "run-mise.py"), "exec", "--"]

    def command(*args: str) -> subprocess.CompletedProcess[str]:
        return log.command(base + list(args))

    def checked(*args: str) -> str:
        result = command(*args)
        if result.returncode:
            raise subprocess.CalledProcessError(
                result.returncode,
                [*base, *args],
                output=result.stdout,
                stderr=result.stderr,
            )
        return result.stdout

    try:
        checked(
            "initdb",
            "-D",
            str(cluster),
            "-U",
            "caramel_spike",
            "--locale=C",
            "--encoding=UTF8",
            "-A",
            "trust",
        )
        options = f"-k {shlex.quote(str(socket))} -c listen_addresses='' -p {PORT} -c unix_socket_permissions=0700"
        query = [
            "psql",
            "-h",
            str(socket),
            "-p",
            PORT,
            "-U",
            "caramel_spike",
            "-d",
            "postgres",
            "-X",
            "-v",
            "ON_ERROR_STOP=1",
            "-At",
            "-c",
        ]
        start_args = (
            "pg_ctl",
            "-D",
            str(cluster),
            "-l",
            str(server_log),
            "-o",
            options,
            "-w",
            "start",
        )
        result = command(*start_args)
        if result.returncode:
            raise subprocess.CalledProcessError(result.returncode, [*base, *start_args], output=result.stdout, stderr=result.stderr)

        listen_addresses = checked(*query, "SELECT current_setting('listen_addresses') = '';").strip()
        if listen_addresses != "t":
            raise AssertionError(f"listen_addresses is not empty: {listen_addresses!r}")
        first = checked(
            *query,
            "SHOW data_directory; SHOW server_version; "
            "CREATE TABLE caramel_probe(id integer primary key, title text not null); "
            "INSERT INTO caramel_probe VALUES(1, 'Bookshelf'); "
            "SELECT title FROM caramel_probe;",
        )
        if "Bookshelf" not in first:
            raise AssertionError(f"initial row was not returned: {first!r}")

        checked("pg_ctl", "-D", str(cluster), "-m", "fast", "-w", "stop")

        result = command(*start_args)
        if result.returncode:
            raise subprocess.CalledProcessError(result.returncode, [*base, *start_args], output=result.stdout, stderr=result.stderr)
        listen_addresses = checked(*query, "SELECT current_setting('listen_addresses') = '';").strip()
        if listen_addresses != "t":
            raise AssertionError(f"listen_addresses is not empty after restart: {listen_addresses!r}")
        after_restart = checked(*query, "SELECT title FROM caramel_probe WHERE id=1;").strip()
        if after_restart != "Bookshelf":
            raise AssertionError(f"row did not survive restart: {after_restart!r}")
        log.write("PASS: row survives restart, no TCP listeners configured\n")
    except Exception as error:
        log.write(f"ERROR: {error}\n")
        raise
    finally:
        cleanup_error = None
        if (cluster / "postmaster.pid").exists():
            result = command("pg_ctl", "-D", str(cluster), "-m", "fast", "-w", "stop")
            if result.returncode:
                cleanup_error = f"cleanup stop exited {result.returncode}"
                log.write(f"ERROR: {cleanup_error}\n")
        log.close()
        if cleanup_error is not None:
            raise RuntimeError(cleanup_error)


def main(argv: Optional[List[str]] = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if args == ["--help"] or args == ["-h"]:
        print(usage(), end="")
        return 0
    if args:
        print(usage(), file=sys.stderr, end="")
        return 2
    try:
        run_lifecycle(ROOT)
    except (RuntimeError, AssertionError, subprocess.CalledProcessError) as error:
        print(f"pg-lifecycle: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
