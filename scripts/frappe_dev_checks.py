"""Native watcher acceptance using the existing disposable HTTPS/PG fixture."""
import json
from pathlib import Path
import subprocess
import time


def check(run, repo, root, project, clone, rpc, ports, env):
    executable = root / "dev-fixture"
    run([repo / "scripts/crystal", "build", "spec/fixtures/frappe_dev.cr", "-o", executable])
    certificate = root / "state/services/caddy/storage/pki/authorities/caramel/root.crt"
    processes = []
    logs = []

    def request(name, path="/", headers=()):
        jar = root / (name + "-cookies")
        command = ["/usr/bin/curl", "--silent", "--show-error", "--max-time", "5", "--noproxy", "*", "--cacert", str(certificate), "--resolve", f"{name}.caramel:{ports[2]}:127.0.0.1", "-H", f"Host: {name}.caramel", "--cookie", str(jar), "--cookie-jar", str(jar), "--write-out", "\n%{http_code}"]
        for header in headers:
            command.extend(["-H", header])
        command.append(f"https://{name}.caramel:{ports[2]}{path}")
        response = subprocess.run(command, capture_output=True, text=True, timeout=8)
        body, _, status = response.stdout.rpartition("\n")
        return int(status or 0), body

    def wait_for(name, predicate, timeout=100):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            status, body = request(name)
            if predicate(status, body):
                return body
            assert all(item.poll() is None for item in processes), "dev session exited; inspect fixture logs"
            time.sleep(.15)
        raise AssertionError(f"Timed out waiting for {name}: {status}\n{body[:3000]}")

    def start(directory, name):
        log = (root / (name + "-dev.log")).open("w")
        logs.append(log)
        process = subprocess.Popen([str(executable), str(directory)], cwd=directory, env=env, stdout=log, stderr=log)
        processes.append(process)
        return process

    try:
        first = start(project, "bookshelf")
        body = wait_for("bookshelf", lambda status, body: status == 200 and "A little less setup." in body)
        assert "/__caramel/dev/client.js" in body
        status, state = request("bookshelf", "/__caramel/dev/status", ["X-Caramel-Dev: 1"])
        assert status == 200 and json.loads(state)["state"] == "ready"
        initial_generation = json.loads(state)["generation"]
        duplicate = subprocess.run([str(executable), str(project)], cwd=project, env=env, capture_output=True, text=True, timeout=20)
        assert duplicate.returncode != 0 and "already running" in duplicate.stderr

        # The clone has spec migrations, but its development schema is empty.
        second = start(clone, "bookshelf-clone")
        wait_for("bookshelf-clone", lambda status, body: status == 503 and "Pending migrations" in body)
        run([repo / "bin/frappe", "migrate"], cwd=clone)
        wait_for("bookshelf-clone", lambda status, body: status == 200 and "A little less setup." in body)

        controller = project / "app/controllers/home_controller.cr"
        original = controller.read_text()
        controller.write_text(original + "\ndef deliberately_broken(\n")
        wait_for("bookshelf", lambda status, body: status == 503 and "home_controller.cr" in body)
        assert request("bookshelf-clone")[0] == 200
        controller.write_text(original)
        wait_for("bookshelf", lambda status, body: status == 200 and "A little less setup." in body)
        status, state = request("bookshelf", "/__caramel/dev/status", ["X-Caramel-Dev: 1"])
        assert status == 200 and json.loads(state)["generation"] > initial_generation

        source = project / "app/assets/stylesheets/app.css"
        before = (root / "bookshelf-dev.log").read_text().count("Build ready")
        source.write_text(source.read_text() + "\n/* dev-asset-refresh-proof */\n")
        deadline = time.monotonic() + 8
        while "dev-asset-refresh-proof" not in request("bookshelf", "/assets/app.css")[1]:
            assert time.monotonic() < deadline, "asset changes did not publish"
            time.sleep(.1)
        time.sleep(.5)
        assert (root / "bookshelf-dev.log").read_text().count("Build ready") == before, "CSS triggered a Crystal compile"

        destination = project / "public/assets/app.css"
        destination.write_text("A public edit that must be preserved")
        wait_for("bookshelf", lambda status, body: status == 503 and "Asset output conflict" in body)
        assert destination.read_text() == "A public edit that must be preserved"
        destination.write_text(source.read_text())
        wait_for("bookshelf", lambda status, body: status == 200 and "A little less setup." in body)

        first.terminate()
        assert first.wait(timeout=20) == 0
        processes.remove(first)
        sites = rpc("GET", "/v1/sites")["sites"]
        site = next(item for item in sites if item["name"] == "bookshelf")
        assert site["upstream"] is None
        assert request("bookshelf")[0] == 503
        assert request("bookshelf-clone")[0] == 200
        assert all(item["state"] == "running" for item in rpc("GET", "/v1/status")["services"].values())

        # An abruptly lost terminal owner must not leave the application alive.
        restarted = start(project, "bookshelf")
        wait_for("bookshelf", lambda status, body: status == 200 and "A little less setup." in body)
        deadline = time.monotonic() + 5
        while "Build ready (cached)" not in (root / "bookshelf-dev.log").read_text():
            assert time.monotonic() < deadline
            time.sleep(.05)
        listing = subprocess.run(["/bin/ps", "-ax", "-o", "pid=,args="], capture_output=True, text=True, check=True).stdout
        native_pids = [int(line.strip().split(None, 1)[0]) for line in listing.splitlines() if len(line.strip().split(None, 1)) == 2 and line.strip().split(None, 1)[1].startswith(str(project / ".caramel/dev/application-"))]
        assert len(native_pids) == 1, "expected one owned native app"
        restarted.kill()
        restarted.wait(timeout=5)
        processes.remove(restarted)
        deadline = time.monotonic() + 8
        for pid in native_pids:
            while True:
                info = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "stat=,args="], capture_output=True, text=True).stdout.strip()
                if not info or info.startswith("Z") or str(project / ".caramel/dev/application-") not in info:
                    break
                assert time.monotonic() < deadline, "native app survived terminal owner death"
                time.sleep(.05)
        restarted = start(project, "bookshelf")
        wait_for("bookshelf", lambda status, body: status == 200 and "A little less setup." in body)
        assert request("bookshelf-clone")[0] == 200
        print("PASS: cached restart, abrupt terminal death cleanup, stale socket recovery, and asset-conflict recovery", flush=True)
        print("PASS: watched native builds, same-origin diagnostics/recovery, pending-migration recovery, authenticated refresh, CSS without compilation, duplicate session refusal, and independent project shutdown", flush=True)
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=20)
        for log in logs:
            log.close()
