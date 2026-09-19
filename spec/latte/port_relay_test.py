#!/usr/bin/env python3
"""High-loopback-port integration tests for the native Latte byte relay.

The test-only relay mode binds only caller-selected ports at or above 1024 and
forwards opaque bytes to two caller-owned loopback servers.  No launchd plist,
privileged port, DNS setting, trust store, database, or application process is
used by this suite.
"""

from __future__ import annotations

import socket
import subprocess
import threading
import time
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
BUILD = REPO / "scripts" / "build-latte-relay"
RELAY = REPO / "bin" / "latte-port-relay"


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def connect_when_ready(port: int, process: subprocess.Popen[bytes], timeout: float = 3.0) -> socket.socket:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise AssertionError(f"relay exited early with status {process.returncode}")
        try:
            return socket.create_connection(("127.0.0.1", port), timeout=0.15)
        except OSError:
            time.sleep(0.02)
    raise AssertionError(f"relay did not accept on 127.0.0.1:{port}")


class ByteServer:
    """Small real TCP server used for both clear and opaque TLS-like bytes."""

    def __init__(self, initial: bytes = b"", eof_reply: bytes = b"") -> None:
        self.initial = initial
        self.eof_reply = eof_reply
        self.ready = threading.Event()
        self.stop = threading.Event()
        self.errors: list[BaseException] = []
        self.connections: list[socket.socket] = []
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(16)
        self.port = int(self.sock.getsockname()[1])

    def start(self) -> None:
        self.thread.start()
        if not self.ready.wait(2):
            raise AssertionError("byte server did not start")

    def close(self) -> None:
        self.stop.set()
        try:
            self.sock.close()
        except OSError:
            pass
        for conn in self.connections:
            try:
                conn.close()
            except OSError:
                pass
        self.thread.join(timeout=2)
        if self.errors:
            raise self.errors[0]

    def _run(self) -> None:
        self.ready.set()
        self.sock.settimeout(0.2)
        try:
            while not self.stop.is_set():
                try:
                    conn, _ = self.sock.accept()
                except socket.timeout:
                    continue
                except OSError:
                    return
                self.connections.append(conn)
                threading.Thread(target=self._serve, args=(conn,), daemon=True).start()
        except BaseException as error:  # pragma: no cover - reported by close
            self.errors.append(error)

    def _serve(self, conn: socket.socket) -> None:
        with conn:
            conn.settimeout(2)
            if self.initial:
                conn.sendall(self.initial)
            while True:
                try:
                    data = conn.recv(16 * 1024)
                except (ConnectionResetError, socket.timeout):
                    return
                if not data:
                    if self.eof_reply:
                        try:
                            conn.sendall(self.eof_reply)
                            conn.shutdown(socket.SHUT_WR)
                        except OSError:
                            pass
                    return
                try:
                    conn.sendall(data)
                except OSError:
                    return


class StreamingServer(ByteServer):
    """A real continuously writable destination for fairness regression tests."""

    def __init__(self) -> None:
        super().__init__()
        self.chunk = b"stream-byte" * 1489  # 16,379 bytes per write

    def _serve(self, conn: socket.socket) -> None:
        with conn:
            conn.settimeout(1)
            while not self.stop.is_set():
                try:
                    conn.sendall(self.chunk)
                except (OSError, socket.timeout):
                    return


class PortRelayTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        subprocess.run([str(BUILD)], cwd=REPO, check=True)

    def setUp(self) -> None:
        self.http = ByteServer(initial=b"http-ready", eof_reply=b"http-eof")
        self.https = ByteServer(initial=b"tls-ready", eof_reply=b"tls-eof")
        self.http.start()
        self.https.start()
        self.http_port = free_port()
        self.https_port = free_port()
        while self.https_port == self.http_port:
            self.https_port = free_port()
        self.relay = subprocess.Popen(
            [
                str(RELAY),
                "--test-listen",
                str(self.http_port),
                str(self.https_port),
                str(self.http.port),
                str(self.https.port),
            ],
            cwd=REPO,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.stream: StreamingServer | None = None

    def stop_relay(self) -> None:
        if self.relay.poll() is None:
            self.relay.terminate()
            try:
                self.relay.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.relay.kill()
                self.relay.wait(timeout=3)
        self.relay.communicate(timeout=1)

    def tearDown(self) -> None:
        self.stop_relay()
        self.http.close()
        self.https.close()
        if self.stream is not None:
            self.stream.close()

    def test_plain_and_tls_like_bytes_round_trip_and_half_close(self) -> None:
        for port, ready, payload, eof_reply in (
            (self.http_port, b"http-ready", b"GET /opaque HTTP/1.1\r\n\x16\x03\x01", b"http-eof"),
            (self.https_port, b"tls-ready", b"\x16\x03\x03clienthello\x00", b"tls-eof"),
        ):
            with self.subTest(port=port):
                with connect_when_ready(port, self.relay) as client:
                    client.settimeout(2)
                    self.assertEqual(client.recv(64), ready)
                    client.sendall(payload)
                    self.assertEqual(client.recv(256), payload)
                    client.shutdown(socket.SHUT_WR)
                    self.assertEqual(client.recv(64), eof_reply)
                    self.assertEqual(client.recv(1), b"")

    def test_unavailable_target_closes_connection_and_relay_survives(self) -> None:
        unavailable_http = free_port()
        unavailable_https = free_port()
        while unavailable_https == unavailable_http:
            unavailable_https = free_port()
        self.stop_relay()
        self.relay = subprocess.Popen(
            [
                str(RELAY),
                "--test-listen",
                str(self.http_port),
                str(self.https_port),
                str(unavailable_http),
                str(unavailable_https),
            ],
            cwd=REPO,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        probe = connect_when_ready(self.http_port, self.relay)
        probe.close()
        for _ in range(3):
            with connect_when_ready(self.http_port, self.relay) as client:
                client.settimeout(2)
                client.sendall(b"target-unavailable")
                try:
                    response = client.recv(1)
                except ConnectionResetError:
                    response = b""
                self.assertEqual(response, b"")
        self.assertIsNone(self.relay.poll())

    def test_continuous_stream_and_connection_churn_do_not_delay_sigterm(self) -> None:
        self.stop_relay()
        self.stream = StreamingServer()
        self.stream.start()
        http_port = free_port()
        https_port = free_port()
        while https_port == http_port:
            https_port = free_port()
        self.relay = subprocess.Popen(
            [
                str(RELAY),
                "--test-listen",
                str(http_port),
                str(https_port),
                str(self.stream.port),
                str(self.https.port),
            ],
            cwd=REPO,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        stream_client = connect_when_ready(http_port, self.relay)
        stream_client.settimeout(0.1)
        reader_stop = threading.Event()
        churn_stop = threading.Event()
        received = [0]

        def drain_stream() -> None:
            while not reader_stop.is_set():
                try:
                    data = stream_client.recv(64 * 1024)
                except socket.timeout:
                    continue
                except OSError:
                    return
                if not data:
                    return
                received[0] += len(data)

        def churn_connections() -> None:
            while not churn_stop.is_set():
                try:
                    with socket.create_connection(("127.0.0.1", https_port), timeout=0.2) as client:
                        client.settimeout(0.2)
                        client.sendall(b"churn")
                        if client.recv(5) != b"churn":
                            continue
                except OSError:
                    if self.relay.poll() is not None:
                        return

        reader = threading.Thread(target=drain_stream, daemon=True)
        churners = [threading.Thread(target=churn_connections, daemon=True) for _ in range(4)]
        reader.start()
        for churner in churners:
            churner.start()
        try:
            deadline = time.monotonic() + 1.0
            while received[0] < 256 * 1024 and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertGreater(received[0], 256 * 1024)

            started = time.monotonic()
            self.relay.terminate()
            self.relay.wait(timeout=2)
            self.assertLess(time.monotonic() - started, 1.5)
        finally:
            churn_stop.set()
            reader_stop.set()
            try:
                stream_client.close()
            except OSError:
                pass
            reader.join(timeout=2)
            for churner in churners:
                churner.join(timeout=2)

    def test_relay_termination_releases_listeners(self) -> None:
        probe = connect_when_ready(self.http_port, self.relay)
        probe.close()
        self.relay.terminate()
        self.relay.wait(timeout=3)
        with self.assertRaises(OSError):
            socket.create_connection(("127.0.0.1", self.http_port), timeout=0.4)


if __name__ == "__main__":
    unittest.main(verbosity=2)
