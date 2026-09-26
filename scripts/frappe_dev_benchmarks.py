"""HTTP-visible edit measurements in the disposable generated-project fixture.

This measures neither browser paint nor a cold machine. The managed compiler
cache is already warm from fixture setup; all raw edit samples are retained.
"""
import json
import math
import os
from pathlib import Path
import platform
import statistics
import subprocess
import threading
import time


def distribution(samples):
    ordered = sorted(samples)
    return {"samples_ms": samples, "count": len(samples),
            "median_ms": statistics.median(samples),
            "p95_ms": ordered[math.ceil(len(samples) * .95) - 1],
            "min_ms": ordered[0], "max_ms": ordered[-1]}


class ProcessSampler:
    """Sample only descendants of this fixture's daemon and development owner."""
    def __init__(self, daemon_pid):
        self.daemon_pid = daemon_pid
        self.dev_pid = None
        self.rows = []
        self.phase = "setup"
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.collect, daemon=True)

    def collect(self):
        while not self.stop.wait(.5):
            result = subprocess.run(["/bin/ps", "-ax", "-o", "pid=,ppid=,%cpu=,rss="], capture_output=True, text=True, timeout=5)
            if result.returncode:
                continue
            processes = {}
            for line in result.stdout.splitlines():
                parts = line.split()
                if len(parts) == 4:
                    processes[int(parts[0])] = (int(parts[1]), float(parts[2]), int(parts[3]))
            row = {"phase": self.phase, "monotonic_seconds": time.monotonic()}
            for name, root in (("services", self.daemon_pid), ("development", self.dev_pid)):
                owned = {root} if root else set()
                while True:
                    descendants = {pid for pid, values in processes.items() if values[0] in owned}
                    if descendants <= owned:
                        break
                    owned |= descendants
                values = [values for pid, values in processes.items() if pid in owned]
                row[name] = {"processes": len(values), "summed_rss_kib": sum(item[2] for item in values),
                             "summed_ps_cpu_percent": sum(item[1] for item in values)}
            self.rows.append(row)


def check(run, repo, root, project, rpc, ports, env, daemon_pid, *, edit_only=False):
    destination = Path(os.environ.get("CARAMEL_BENCHMARK_OUTPUT", f"/private/tmp/caramel-dev-benchmark-{time.time_ns()}.json"))
    # Refuse to replace an earlier result. Keep partial measurements on failure.
    output = destination.open("x")
    os.chmod(destination, 0o600)
    sampler = ProcessSampler(daemon_pid)
    report = {"complete": False, "mode": "edit-only" if edit_only else "full", "scenarios": {}, "hardware": {}, "resource_samples": sampler.rows,
              "limitations": ["HTTP-visible changes, not browser paint or browser refresh execution",
                              "50 ms polling plus a new curl process per observation",
                              "Managed compiler cache and dependencies warmed by fixture setup",
                              "Summed RSS double-counts shared pages; ps CPU is a process-lifetime average",
                              "Resource sampling every 500 ms can miss short-lived processes",
                              "Private HTTPS ports and explicitly supplied fixture CA; no system DNS/trust acceptance"],
              "versions_manifest": (repo / "tools/toolchain/caramel-toolchain.toml").read_text(),
              "platform": platform.platform(), "sample_count_per_edit_kind": 20}
    process = None
    log = None
    executable = root / "dev-benchmark-fixture"
    certificate = root / "state/services/caddy/storage/pki/authorities/caramel/root.crt"

    def persist():
        output.seek(0)
        json.dump(report, output, indent=2)
        output.write("\n")
        output.truncate()
        output.flush()
        os.fsync(output.fileno())

    def request(path):
        result = subprocess.run(["/usr/bin/curl", "--silent", "--show-error", "--max-time", "5", "--noproxy", "*",
                                 "--cacert", str(certificate), "--resolve", f"bookshelf.caramel:{ports[2]}:127.0.0.1",
                                 "-H", "Host: bookshelf.caramel", "--write-out", "\n%{http_code}",
                                 f"https://bookshelf.caramel:{ports[2]}{path}"], capture_output=True, text=True, timeout=8)
        body, _, status = result.stdout.rpartition("\n")
        return int(status or 0), body

    def visible(path, marker, timeout=120):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            assert process is not None and process.poll() is None, "development owner exited"
            status, body = request(path)
            if status == 200 and marker in body:
                return
            time.sleep(.05)
        raise AssertionError(f"Timed out waiting for benchmark content: HTTP {status}")

    def start(scenario):
        nonlocal process, log
        log = (root / f"{scenario}-benchmark.log").open("a")
        process = subprocess.Popen([str(executable), str(project)], cwd=project, env=env, stdout=log, stderr=log)
        sampler.dev_pid = process.pid

    def stop():
        nonlocal process, log
        if process is not None:
            if process.poll() is None:
                process.terminate()
            assert process.wait(timeout=25) == 0
            process = None
        sampler.dev_pid = None
        if log is not None:
            log.close()
            log = None

    def elapsed(operation):
        started = time.monotonic()
        operation()
        return (time.monotonic() - started) * 1000

    try:
        for key in ("hw.model", "hw.memsize", "hw.ncpu", "machdep.cpu.brand_string"):
            value = subprocess.run(["/usr/sbin/sysctl", "-n", key], capture_output=True, text=True)
            report["hardware"][key] = value.stdout.strip() if value.returncode == 0 else "unavailable"
        report["revision"] = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True, check=True).stdout.strip()
        run([repo / "scripts/crystal", "build", "spec/fixtures/frappe_dev.cr", "-o", executable])
        sampler.thread.start()
        controller = project / "app/actions/home/show.cr"
        original_controller = controller.read_text()
        template = project / "app/views/home/index.html.ecr"
        original_template = template.read_text()
        for scenario, resources in (("bookshelf", 2), ("larger", 22)):
            metrics = report["scenarios"][scenario] = {"generated_resources": resources, "edits": {}}
            if scenario == "larger":
                sampler.phase = "larger/generation"
                for letter in "ABCDEFGHIJKLMNOPQRST":
                    run([repo / "bin/frappe", "make", "resource", "Benchmark" + letter, "title:string", "description:string"], cwd=project)
                metrics["migration_command_ms"] = elapsed(lambda: run([repo / "bin/frappe", "migrate"], cwd=project))
            sampler.phase = scenario + "/first-dev-build"
            metrics["first_dev_ready_ms"] = elapsed(lambda: (start(scenario), visible("/", "A little less setup.")))
            for kind, path, url in (("css", project / "app/assets/stylesheets/app.css", "/assets/app.css"),
                                    ("javascript", project / "app/assets/javascript/app.js", "/assets/app.js"),
                                    ("template", template, "/"), ("crystal", controller, "/")):
                sampler.phase = scenario + "/" + kind
                before = path.read_text()
                samples = []
                for index in range(20):
                    marker = f"benchmark-{scenario}-{kind}-{index}"
                    if kind == "crystal":
                        updated = original_controller.replace('Caramel::Page.new("Welcome", content)', f'Caramel::Page.new("Welcome", content + "<!-- {marker} -->")')
                        assert updated != original_controller
                    elif kind == "template":
                        updated = original_template + f"\n<!-- {marker} -->\n"
                    else:
                        updated = before + f"\n/* {marker} */\n"
                    samples.append(elapsed(lambda: (path.write_text(updated), visible(url, marker))))
                metrics["edits"][kind] = distribution(samples)
                print(f"MEASURED {scenario} {kind}: median={statistics.median(samples):.0f} ms p95={metrics['edits'][kind]['p95_ms']:.0f} ms", flush=True)
                persist()
            stop()
            sampler.phase = scenario + "/cached-start"
            metrics["cached_dev_ready_ms"] = elapsed(lambda: (start(scenario), visible("/", f"benchmark-{scenario}-crystal-19")))
            stop()
            build_files = list((project / ".caramel/dev").glob("application-*"))
            metrics["development_artifacts_bytes"] = {item.suffix or "binary": item.stat().st_size for item in build_files}
            if edit_only:
                persist()
                continue
            sampler.phase = scenario + "/semantic-check"
            metrics["semantic_check_ms"] = elapsed(lambda: run([repo / "scripts/crystal", "build", "src/bookshelf.cr", "--no-codegen"], cwd=project))
            sampler.phase = scenario + "/specs"
            metrics["spec_command_ms"] = elapsed(lambda: run([repo / "bin/frappe", "test"], cwd=project))
            sampler.phase = scenario + "/release-build"
            release = root / (scenario + "-release")
            metrics["release_build_ms"] = elapsed(lambda: run([repo / "scripts/crystal", "build", "src/bookshelf.cr", "--release", "-o", release], cwd=project))
            metrics["release_binary_bytes"] = release.stat().st_size
            persist()
        report["complete"] = True
        print("Performance report: " + str(destination), flush=True)
    finally:
        try:
            stop()
        finally:
            sampler.stop.set()
            if sampler.thread.is_alive():
                sampler.thread.join(timeout=7)
            persist()
            output.close()
            print("Saved performance evidence (complete=" + str(report["complete"]) + "): " + str(destination), flush=True)
