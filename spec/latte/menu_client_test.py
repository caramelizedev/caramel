#!/usr/bin/env python3
"""Protocol checks for the native Latte menu client.

The tests use a private fake Latte daemon, so they do not launch a GUI or
touch the host's resolver, trust store, database, or proxy processes.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import socketserver
import subprocess
import tempfile
import threading
import time
import unittest


REPO = Path(__file__).resolve().parents[2]
BUILD = REPO / "scripts" / "build-latte-menu"
APP = REPO / "bin" / "Latte.app" / "Contents" / "MacOS" / "Latte"


def runtime_socket(home: Path) -> Path:
    canonical = home.expanduser().resolve()
    digest = hashlib.sha256(str(canonical).encode()).hexdigest()[:12]
    return Path("/private/tmp") / f"caramel-{os.getuid()}-{digest}" / "latte.sock"


class FakeLatte(socketserver.UnixStreamServer):
    allow_reuse_address = False

    def __init__(
        self,
        path: Path,
        payloads: dict[tuple[str, str], object],
        trickle: bool = False,
        delays: dict[tuple[str, str], float] | None = None,
    ):
        self.payloads = payloads
        self.trickle = trickle
        self.delays = delays or {}
        super().__init__(str(path), FakeRequest)


class FakeRequest(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        request_line = self.rfile.readline().decode("ascii", "replace").strip()
        method, path, _ = request_line.split(" ", 2)
        while self.rfile.readline().strip():
            pass
        body = self.server.payloads.get((method, path))  # type: ignore[attr-defined]
        if body is None:
            status = "404 Not Found"
            body = {"version": 1, "error": {"code": "not_found", "message": "missing"}}
        else:
            status = "200 OK"
        delay = self.server.delays.get((method, path), 0)  # type: ignore[attr-defined]
        if delay:
            time.sleep(delay)
        encoded = json.dumps(body, separators=(",", ":")).encode()
        headers = f"HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {len(encoded)}\r\nConnection: close\r\n\r\n".encode()
        if self.server.trickle:  # type: ignore[attr-defined]
            try:
                self.wfile.write(headers)
                for byte in encoded[:60]:
                    self.wfile.write(bytes([byte]))
                    self.wfile.flush()
                    time.sleep(0.05)
                self.wfile.write(encoded[60:])
                self.wfile.flush()
            except BrokenPipeError:
                pass
        else:
            try:
                self.wfile.write(headers + encoded)
            except BrokenPipeError:
                pass


class MenuClientTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        subprocess.run([str(BUILD)], cwd=REPO, check=True)

    def setUp(self) -> None:
        self.temp = Path(tempfile.mkdtemp(prefix="latte-menu-test-", dir="/private/tmp"))
        self.home = self.temp / "Caramel"
        self.home.mkdir(mode=0o700)
        self.log_root = self.home / "logs"
        self.log_root.mkdir(mode=0o700)
        self.socket_path = runtime_socket(self.home)
        self.socket_path.parent.mkdir(mode=0o700)
        os.chmod(self.socket_path.parent, 0o700)
        self.server: FakeLatte | None = None
        self.thread: threading.Thread | None = None

    def tearDown(self) -> None:
        if self.server is not None:
            self.server.shutdown()
            self.server.server_close()
        if self.thread is not None:
            self.thread.join(timeout=2)
        shutil.rmtree(self.temp, ignore_errors=True)
        if self.socket_path.exists():
            self.socket_path.unlink()
        if self.socket_path.parent.exists():
            self.socket_path.parent.rmdir()

    def serve(
        self,
        sites: list[dict[str, object]],
        trickle: bool = False,
        include_sites_version: bool = True,
        delays: dict[tuple[str, str], float] | None = None,
        service_states: dict[str, str] | None = None,
        status_error: str | None = None,
    ) -> None:
        sites_payload: dict[str, object] = {"sites": sites}
        if include_sites_version:
            sites_payload["version"] = 1
        states = service_states or {
            "postgres": "running",
            "dns": "running",
            "proxy": "stopped",
        }
        status_payload: dict[str, object] = {
            "version": 1,
            "services": {
                name: {"state": state, "detail": None}
                for name, state in states.items()
            },
        }
        if status_error is not None:
            status_payload["error"] = status_error
        payloads = {
            (
                "GET",
                "/v1/status",
            ): status_payload,
            ("GET", "/v1/sites"): sites_payload,
        }
        self.server = FakeLatte(self.socket_path, payloads, trickle=trickle, delays=delays)
        os.chmod(self.socket_path, 0o600)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def run_check(self) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["CARAMEL_HOME"] = str(self.home)
        return subprocess.run(
            [str(APP), "--check"],
            cwd=REPO,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=10,
        )

    def test_check_reads_shared_status_and_sites(self) -> None:
        self.serve(
            [
                {
                    "id": "0123456789abcdef",
                    "name": "bookshelf",
                    "directory": str(self.temp / "bookshelf"),
                    "suffix": "caramel",
                    "domain": "bookshelf.caramel",
                    "origin": "https://bookshelf.caramel",
                    "upstream": None,
                }
            ]
        )
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("status: postgres=running dns=running proxy=stopped", result.stdout)
        self.assertIn("sites: 1", result.stdout)
        self.assertIn("https://bookshelf.caramel", result.stdout)

    def test_check_rejects_origin_that_does_not_match_validated_domain(self) -> None:
        self.serve(
            [
                {
                    "id": "0123456789abcdef",
                    "name": "bookshelf",
                    "directory": str(self.temp / "bookshelf"),
                    "suffix": "caramel",
                    "domain": "bookshelf.caramel",
                    "origin": "https://evil.example",
                    "upstream": None,
                }
            ]
        )
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("origin", result.stdout.lower())

    def test_check_rejects_runtime_directory_with_non_private_mode(self) -> None:
        self.socket_path.parent.chmod(0o755)
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("private", result.stdout.lower())

    def test_check_rejects_sites_response_without_protocol_version(self) -> None:
        self.serve([], include_sites_version=False)
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("json could not be decoded", result.stdout.lower())

    def test_check_accepts_failed_service_with_status_diagnostic(self) -> None:
        self.serve(
            [],
            service_states={
                "postgres": "failed",
                "dns": "running",
                "proxy": "stopped",
            },
            status_error="postgres failed to start",
        )
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("status: postgres=failed dns=running proxy=stopped", result.stdout)
        self.assertIn("diagnostic: postgres failed to start", result.stdout)

    def test_check_applies_one_deadline_across_status_and_sites_requests(self) -> None:
        self.serve(
            [],
            delays={
                ("GET", "/v1/status"): 1.2,
                ("GET", "/v1/sites"): 1.2,
            },
        )
        started = time.monotonic()
        result = self.run_check()
        elapsed = time.monotonic() - started
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("timed out", result.stdout.lower())
        self.assertLess(elapsed, 3.5, result.stdout)

    def test_check_has_an_aggregate_deadline_for_trickled_responses(self) -> None:
        self.serve([], trickle=True)
        started = time.monotonic()
        result = self.run_check()
        elapsed = time.monotonic() - started
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("timed out", result.stdout.lower())
        self.assertLess(elapsed, 6, result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
