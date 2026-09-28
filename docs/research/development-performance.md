# Development performance measurements

The numbers below were measured before `frappe dev` switched from polling to kqueue watching and began type-checking before every build ([ADR 0012](../decisions/0012-latte-supervision-watching-branching.md)). They have not been re-measured, because performance work is deferred. Compilation dominates each compiled edit, so the targets are still missed. Re-run the benchmark below to refresh them.

The measurement entry point is:

```sh
CARAMEL_BENCHMARK_OUTPUT=/private/tmp/caramel-performance.json \
scripts/check frappe-project --benchmark
```

The output file must not already exist. The command creates disposable PostgreSQL, DNS and HTTPS services and generated projects, runs the existing project setup checks, then measures the development workflow. It stops its processes afterward. The JSON report survives fixture cleanup and preserves completed groups if a later measurement fails. It does not change system DNS, certificate trust or launchd configuration.

Use `--edit-benchmark` instead of `--benchmark` to repeat the same edit/startup/resource measurements without repeating semantic checks, specs and release builds inside the measurement stage. The report explicitly labels this mode; the normal fixture setup checks still run.

## Method

The small fixture contains Book and mixed-scalar Person resources. The larger fixture adds twenty two-field resources, each with a model, input, controller, CRUD templates, routes, migration and request specs. Both serve the same simple homepage; this tests the cost of a larger compiled application, not a heavy database query or complex page render.

Each fixture receives twenty sequential changes for each of CSS, JavaScript, ECR templates and Crystal controller source. Every change has a unique marker. Timing starts immediately before the file write and ends when a CA-verified HTTPS response contains the expected marker. Observations poll every 50 ms using a new curl process. All individual samples are retained; p95 is the nearest-rank 19th observation in the sorted twenty samples.

This is HTTP-visible edit latency, including the watcher, compilation where applicable, application readiness and proxy response. It does not measure the browser refresh script, DOM updates, or paint. Those remain browser acceptance work. Private fixture ports and an explicit fixture CA do not establish ordinary installed HTTPS behavior.

Other recorded operations are first development readiness, a cached development restart, semantic checking, application specs including compilation and explicit spec migration, and a native macOS release build. The compiler and dependency caches are already warmed by setup. “First development readiness” means that scenario has no matching development executable; it is not a cold compiler or fresh installation measurement. The release command is a measurement of current compilation, not acceptance of the future Linux/musl artifact.

A sampler records the descendants of the fixture's known Latte daemon and development owner every 500 ms. Summed RSS can count shared pages repeatedly and can miss brief peaks. The CPU field sums `ps` process-lifetime averages; it is not instantaneous CPU utilization or total CPU time. Semantic/spec/release compiler processes are outside the development-owner tree, so their resource usage is not included in that series. Host-wide workload is not controlled. Hardware, platform and the pinned tool manifest accompany the report.

## Initial baseline: 2026-09-19

The first run uses an Apple M3 Pro (12 logical CPUs, 36 GiB RAM). Framework source is commit `84f3aee`. This is a single host/run with warm compiler/dependency caches; it establishes a baseline, not a general performance guarantee.

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

Both scenarios and fixture cleanup completed successfully.

The baseline session awaited old-process retirement after making the replacement ready, so rapid subsequent edits could wait behind that cleanup. The next implementation moves retirement into a tracked queue while preserving shutdown waiting and debug artifacts for retiring processes. Separate native and generated-app tests cover termination, cleanup failures, parent death and superseded compilation. A repeated edit benchmark is required to quantify the improvement.

## Compiler phase investigation

`scripts/check compiler-profile` generates the same two resource counts without starting application services. Each scenario receives a new, empty compiler-cache directory, backed by the already installed tool binaries and native dependencies. It retains its generated source and compiler `--stats` logs in a printed temporary directory. This is cold **compiler-cache** evidence; operating-system file caches, the toolchain installation and dependency caches are already warm.

| Compiler-only operation, one observation | Bookshelf | Larger |
| --- | ---: | ---: |
| Empty compiler cache | 21.94 s | 27.72 s |
| Unchanged source, warm cache | 2.67 s | 6.15 s |
| Template edit, warm cache | 2.51 s | 5.69 s |
| Controller edit, warm cache | 2.43 s | 5.72 s |

These are individual diagnostic observations, not percentile estimates. In the larger controller-edit case, main semantic analysis takes 3.05 seconds and Crystal code generation 0.89 seconds. The compiler reuses 1,210 of 1,211 object files; warm edits are not rebuilding every object. Improving the process handoff alone cannot meet the proposed three-second larger-app target.

## Acceptance still required

For future measurements, retain the raw report alongside the results discussion. Compare subsequent distributions against the same fixtures and keep failing proposed targets visible.

Cold installation/network behavior, repeated isolated compiler-cache builds, separate service and database initialization costs, full compiler resource accounting, actual browser refresh latency and larger application-specific workloads need additional measurements. These investigations do not close those gates.
