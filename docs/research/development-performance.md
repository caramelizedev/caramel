# Development performance measurements

The measurement entry point is:

```sh
CARAMEL_TOOLCHAIN_ROOT=/path/to/verified/toolchain \
CARAMEL_BENCHMARK_OUTPUT=/private/tmp/caramel-performance.json \
scripts/check-frappe-project --benchmark
```

The output file must not already exist. The command creates disposable PostgreSQL, DNS and HTTPS services and generated projects, runs the existing project setup checks, then measures the development workflow. It stops its processes afterward. The JSON report survives fixture cleanup and preserves completed groups if a later measurement fails. It does not change system DNS, certificate trust or launchd configuration.

## Method

The small fixture contains Book and mixed-scalar Person resources. The larger fixture adds twenty two-field resources, each with a model, input, controller, CRUD templates, routes, migration and request specs. Both serve the same simple homepage; this tests the cost of a larger compiled application, not a heavy database query or complex page render.

Each fixture receives twenty sequential changes for each of CSS, JavaScript, ECR templates and Crystal controller source. Every change has a unique marker. Timing starts immediately before the file write and ends when a CA-verified HTTPS response contains the expected marker. Observations poll every 50 ms using a new curl process. All individual samples are retained; p95 is the nearest-rank 19th observation in the sorted twenty samples.

This is HTTP-visible edit latency, including the watcher, compilation where applicable, application readiness and proxy response. It does not measure the browser refresh script, DOM updates, or paint. Those remain browser acceptance work. Private fixture ports and an explicit fixture CA do not establish ordinary installed HTTPS behavior.

Other recorded operations are first development readiness, a cached development restart, semantic checking, application specs including compilation and explicit spec migration, and a native macOS release build. The compiler and dependency caches are already warmed by setup. “First development readiness” means that scenario has no matching development executable; it is not a cold compiler or fresh installation measurement. The release command is a measurement of current compilation, not acceptance of the future Linux/musl artifact.

A sampler records the descendants of the fixture's known Latte daemon and development owner every 500 ms. Summed RSS can count shared pages repeatedly and can miss brief peaks. The CPU field sums `ps` process-lifetime averages; it is not instantaneous CPU utilization or total CPU time. Semantic/spec/release compiler processes are outside the development-owner tree, so their resource usage is not included in that series. Host-wide workload is not controlled. Hardware, platform and the pinned tool manifest accompany the report.

## Initial baseline: 2026-09-19

The first run uses an Apple M3 Pro (12 logical CPUs, 36 GiB RAM). Framework source is commit `ec942df`. This is a single host/run with warm compiler/dependency caches; it establishes a baseline, not a general performance guarantee.

| HTTP-visible edit latency, p95 of 20 | Bookshelf, 2 resources | Larger, 22 resources |
| --- | ---: | ---: |
| CSS | 158 ms | 157 ms |
| JavaScript | 156 ms | 159 ms |
| ECR template | 4.58 s | 7.65 s |
| Crystal controller | 4.55 s | 7.76 s |

First development readiness took 4.14 seconds for Bookshelf and 5.96 seconds for the larger application. Static edit visibility is well below the proposed one-second threshold in this HTTP fixture. Compiled changes miss the proposed three-second threshold in both applications. Do not describe source/template edits as meeting that target, or describe the static results as browser-paint measurements.

| Other measured operation | Bookshelf | Larger |
| --- | ---: | ---: |
| Cached development readiness | 160 ms | 217 ms |
| Semantic check | 1.67 s | 3.74 s |
| Spec command including compilation/migration | 6.08 s | 12.72 s |
| Native macOS release compilation | 38.97 s | 56.94 s |
| Release executable size | 2.73 MiB | 3.53 MiB |

The generated spec suites pass 3 and 23 examples respectively. During the brief CSS groups, the development process tree's largest observed summed RSS was 47.5 MiB and 50.1 MiB. During Crystal rebuilds, including the compiler, it reached 1,236 MiB and 2,541 MiB. Managed services reached approximately 120 MiB summed RSS. These sums can double-count shared pages; the compiler measurements are not application-server memory claims, and 500 ms sampling can miss peaks.

Both scenarios and fixture cleanup completed successfully. [Raw timing report](evidence/development-performance-2026-09-19/report.json) and [resource observations](evidence/development-performance-2026-09-19/resource-samples.jsonl) retain the underlying evidence, including the benchmark script checksum. The original JSON report's checksum is also recorded; its resource rows are stored separately here for readable diffs.

The next investigation should separate compiler semantic/code-generation/linking time from watcher and process-replacement time. In particular, the current session awaits old-process retirement after making the replacement ready; rapid subsequent edits may wait behind that cleanup. Any change must preserve cancellation, parent-death cleanup and the rule that traffic only reaches a ready replacement.

## Acceptance still required

Retain the raw report alongside the results discussion. Compare subsequent distributions against the same fixtures and keep failing proposed targets visible.

Cold installation/network behavior, isolated compiler-cache builds, separate service and database initialization costs, full compiler resource accounting, actual browser refresh latency and larger application-specific workloads need additional measurements. This harness does not close those gates.
