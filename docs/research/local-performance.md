# Local performance: compiling, testing and releasing

Status: measured on 2026-09-28 at commit `5dcf865` (tag `v0.4.0`) on an Apple M3 Pro (12 CPUs, 36 GiB RAM, macOS 26.6.2) with the managed Crystal 1.21.0 toolchain (LLVM 15.0.7, Apple ld-1230.1, Swift 6.2.4). These numbers supersede the edit-latency, readiness, semantic-check, spec-command, release-build and compiler-profile figures in [development-performance.md](development-performance.md), because that baseline predates the Tier-1 type check, kqueue watching and Blueprint views. The owner skipped the instrumented full-suite run, so suite attribution rests on the 0.4.0 release log's per-run times and suite savings are estimates unless marked measured. Every number below comes from one observation unless a range is given.

Implementation: Phase 1 of the remediation (E4-1, E4-3, E4-4, E4-5, E4-8, E4-10) shipped in v0.4.1 on 2026-09-29. Its release gate's runs took 548 s against 738 s at 0.4.0, and the whole release 553.6 s against 747 s (one observation each). Each implemented opportunity's section starts with its status.

## Summary

- **Where release time goes.** The 0.4.0 release took 747 s: 738 s of `scripts/check all` runs and about 9 s of release-tool work. The four checks that drive an app on a private Latte (frappe-project-dev 177 s, frappe-project 128 s, schema-diff 78 s, browser 28 s) are 411 s (56%). Installations take 79 s (11%), the build step 46 s, three spec-program runs 47 s (6%), lint 36 s and native (Swift rebuilds plus its specs) 26 s (0.4.0 release log, no attribution).
- **Suite #1: run the frappe-project flow once** (E4-1): about **128 s off every `check all`** (estimated), a one-line change to `scripts/checks/all.cr`. frappe-project-dev already runs every step of the plain flow.
- **Suite #2: parallel lanes** (E4-7): **344 s** (2 lanes) or **387 s** (3 lanes) off a 738 s suite (estimated, no contention measured). It needs per-lane compiler caches and the `bin/` rewrites removed first (E4-3, E4-4, E4-5). Effort L, risk high.
- **Dev #1: a larger compiler GC heap** (E1-5): with `GC_INITIAL_HEAP_SIZE=2G` one 22-resource type-check pass took **1.046 s**, against 1.43–1.55 s for the same pass with the default heap. That is **0.34 s (stage sums) to 0.51 s (wall) saved per pass**, one observation; the default pass ran 13 full collections. It comes to about **0.7–1.0 s per compiled save** (estimated: two passes per save). The full-build effect and the memory cost are not measured.
- **Dev #2: macOS first-launch scans** (E3-8): the first run of a freshly linked binary took **0.575 s**; repeats took 0.009 s. Every save, compiling command and Corretto run pays this per new binary. Exempting the terminal (Developer Tools) would save about **0.57 s per save** (estimated), but it must be the developer's choice.
- **A 22-resource Crystal save takes 5.79 s (median)**: a duplicated 1.43 s type check, a 2.91 s warm build and 1.46 s outside the compiler. Folding the check into the build (E3-1) removes the 1.43 s (measured). Reusing the dev binary for one-shot commands (E3-2) removes about 3.2 s per repeated command.
- **Cold compiles are dominated by two macro-run helpers.** The stdlib ECR processor costs 6.37 s (58–62% of a cold app build), but only in an empty cache; it stayed in the shared cache in every listing. Ameba's `read_type_doc` costs 26.28 s of a cold 34.83 s linter build. It and the linter are evicted by Crystal's 10-entry cache between suite runs, so the lint check runs cold (36.02 s cold vs 6.91 s warm, measured).
- **Things that do not help:** `--no-debug` (warm builds get slower: bc+obj 0.81–0.94 s vs 0.16 s), `-no_deduplicate` and alternative `dsymutil` linkers (no change), more codegen threads (already 12), and a Crystal upgrade (no compile-time work in 1.21.1 or 1.22.0).

## Where the time goes

### The full suite, by kind of run

Per-run seconds from the 0.4.0 release log (no attribution inside a run); grouping by each run's dominant work, read from the check sources.

| Kind | Runs (seconds) | Seconds | Share of 738 s |
|---|---|---|---|
| App flows on a private Latte (`LatteFixture`) | frappe-project-dev 177, frappe-project 128, schema-diff 78, browser 28 | 411 | 55.7% |
| Install from a tagged clone | installations 79 | 79 | 10.7% |
| Spec programs (`crystal spec`) | spec 22, integration 16, latte-postgres 9 | 47 | 6.4% |
| Native (Swift rebuilds, then `crystal spec spec/native`) | native 26 | 26 | 3.5% |
| Build step | build 46 | 46 | 6.2% |
| Lint | lint 36 | 36 | 4.9% |
| Latte service checks | latte-ipc 20, latte-daemon 8, latte-network 6 | 34 | 4.6% |
| Other checks | editor-tools 9, dev-retirement 6, runtime-diagnostics 6, compiler 4, dev-child 4, toolchain-paths 4 | 33 | 4.5% |
| Compile-only checks (`--no-codegen` fixtures) | orm-compilation 11, route-compilation 8, contract-compilation 4, cold-brew-compilation 3 | 26 | 3.5% |
| **Total runs** | 24 runs | **738** | 100% |
| Release tool outside the suite | 747 − 738 | ≈9 | – |

Directly measured pieces of these runs: lint cold 36.02 s vs warm 6.91 s (m5); route-compilation 7.67 s (m5); one frappe-project fixture flow ≈117 s inside m3; the framework unit spec run 22.67 s cold / 20.61 s warm, of which **16.15–16.24 s is spec execution** and 3.8–5.8 s compilation (fq-Fra-12).

### App compile stages

Seconds from `--stats`. Profile rows build `src/bookshelf.cr -D caramel_development` in a fresh private cache (`scripts/checks/compiler_profile.cr:57`); m2 and fq rows reuse those caches. Wall includes the `scripts/crystal` wrapper for m2/fq rows.

| Build | Wall s | Semantic (top level) | Semantic (main) | Codegen (crystal) | Codegen (bc+obj) | Linking | dsymutil | Object reuse | Macro run |
|---|---|---|---|---|---|---|---|---|---|
| 22 · cold (empty cache) | 11.05 | 0.374 | 7.385 | 1.054 | 1.520 | 0.222 | 0.247 | none reused | ECR 6.37 s |
| 22 · unchanged, warm | 3.14 | 0.373 | 0.717 | 0.969 | 0.355 | 0.207 | 0.247 | 1804/1823 | – |
| 22 · view edit | 2.92 | 0.381 | 0.698 | 0.981 | 0.143 | 0.207 | 0.247 | 1822/1823 | – |
| 22 · controller edit | 2.91 | 0.376 | 0.703 | 0.967 | 0.138 | 0.208 | 0.244 | 1822/1823 | – |
| 22 · type check only (m2a-2) | 1.43 | 0.371 | 0.741 | – | – | – | – | (no codegen) | – |
| 22 · type check, no view bodies (m2d-2) | 1.31 | 0.371 | 0.662 | – | – | – | – | (no codegen) | – |
| 22 · type check, no resource routes (m2e-2) | 1.00 | 0.353 | 0.370 | – | – | – | – | (no codegen) | – |
| 22 · warm build, no view bodies (fq-Fra-1-2) | 3.08 | 0.393 | 0.725 | 1.013 | 0.153 | 0.229 | 0.267 | all | – |
| 22 · warm build, no resource routes (fq-Fra-2-2) | 2.56 | 0.383 | 0.408 | 0.488 | 0.597 | 0.170 | 0.185 | all | – |
| 22 · `--no-debug`, first (m2c-1) | 4.41 | 0.372 | 0.736 | 0.786 | 2.045 | 0.175 | – | none reused | – |
| 22 · `--no-debug`, warm (m2c-2) | 3.19 | 0.385 | 0.766 | 0.783 | 0.809 | 0.170 | – | all | – |
| 22 · no `-D` after dev objects (m2b-1) | 3.27 | 0.366 | 0.740 | 0.962 | 0.429 | 0.209 | 0.243 | 1645/1819 | – |
| 22 · no `-D`, warm (m2b-2) | 2.97 | 0.379 | 0.749 | 0.963 | 0.138 | 0.212 | 0.246 | all | – |
| 22 · dev flags after no-`-D` objects (m2b-3) | 3.47 | 0.383 | 0.751 | 1.179 | 0.406 | 0.212 | 0.250 | 1649/1823 | – |
| 22 · type check, default GC (fq-Com-7 run 2) | 1.554 (time) | 0.429 | 0.821 | – | – | – | – | (no codegen) | – |
| 22 · type check, `GC_INITIAL_HEAP_SIZE=2G` (fq-Com-7 run 3) | 1.046 (time) | 0.355 | 0.473 | – | – | – | – | (no codegen) | – |
| 22 · `--release` (fq-Fra-14) | 84.85 | 0.397 | 0.808 | 0.985 | 81.561 | 0.332 | 0.403 | none reused | – |
| 22 · `--release`, no view bodies (fq-Fra-15) | 72.50 | 0.442 | 0.745 | 0.687 | 69.708 | 0.295 | 0.303 | none reused | – |
| 2 · cold (empty cache) | 10.21 | 0.321 | 7.302 | 0.464 | 1.592 | 0.178 | 0.177 | none reused | ECR 6.37 s |
| 2 · unchanged, warm | 2.57 | 0.333 | 0.461 | 0.467 | 0.749 | 0.155 | 0.176 | 1264/1283 | – |
| 2 · view edit | 2.28 | 0.316 | 0.464 | 0.463 | 0.514 | 0.156 | 0.171 | 1282/1283 | – |
| 2 · controller edit | 2.29 | 0.312 | 0.486 | 0.461 | 0.504 | 0.154 | 0.173 | 1282/1283 | – |
| 2 · type check only (m2f-2) | 1.03 | 0.310 | 0.485 | – | – | – | – | (no codegen) | – |
| 2 · no `-D` after dev objects (fq-App-5) | 2.97 | 0.338 | 0.519 | 0.498 | 0.945 | 0.179 | 0.194 | 1205/1279 | – |

What the rows say:

- A warm 22-resource build is about 79% single-threaded work: type checking plus LLVM IR generation (`Codegen (crystal)`). Object generation, linking and `dsymutil` are 0.14 + 0.21 + 0.25 s.
- 154 resource routes cost 0.43 s of a type check (m2a-2 − m2e-2) and 0.74 s of a warm build (fq-Fra-0-2 3.30 − fq-Fra-2-2 2.56). All 110 view bodies cost only 0.12 s and 0.22 s.
- Flipping `-D caramel_development` in one cache dir recompiles about 174 modules (+0.30 s and +0.33 s). `Tools#compile` builds without the define and the dev loop with it (`src/frappe/tools.cr:44`, `src/frappe/dev_session.cr:229`).
- `--no-debug` saves `dsymutil` (0.25 s) but its warm bc+obj stays at 0.81–0.94 s with every object reused (m2c-2, fq-Com-0). A debug build shows the same 0.88 s with `--threads 1` (fq-Com-1). The GC logs show 22 collections for a no-debug build against 15 for a debug build.
- The cold rows are 58–62% one macro-run helper. Crystal's `HTTP::StaticFileHandler` renders directory listings with `ECR.def_to_s` (stdlib `http/server/handlers/static_file_handler.cr:318`), and typing it compiles the ECR processor at -O3.

### Programs the suite rebuilds, cold vs warm

| Program | Cold s | Warm s | Source |
|---|---|---|---|
| `src/frappe_lint.cr` (linter; cold includes Ameba `read_type_doc` 26.28 s) | 34.83 | 4.70 | fq-Com-4 |
| `src/frappe.cr` (`bin/frappe`) | 3.70 | 2.65 | fq-Com-4 |
| `spec/fixtures/frappe_environment.cr` (LatteFixture daemon) | 2.42 | 1.72 | fq-Com-4 |
| `spec/fixtures/frappe_dev.cr` | 2.59 | 1.80 | fq-Com-4 |
| check binary `scripts/checks/route_compilation.cr` | 1.48 | 1.09 | fq-Com-4 |
| check binary `scripts/checks/frappe_project.cr` | 2.20 | 1.60 | fq-Sui-1 |
| framework unit spec (compile + 16.2 s run) | 22.67 | 20.61 | fq-Fra-12 |
| 22-resource Corretto spec binary | 5.17 | 3.64 | fq-App-4 |
| `src/frappe.cr` / `src/latte.cr` / `src/frappe_lint.cr` in an empty cache | 11.13 / 2.47 / 35.02 | 3.03 / 1.64 / 4.27 | fq-Sui-4 |
| `swiftc -O` Latte.app / relay / 3 installers (module cache cold → warm) | 32.08 / 2.31 / 2.95, 1.53, 2.37 | 2.38 / 1.77 / 3.27, 1.83, 2.57 | fq-Sui-6 |

### Development loop, Corretto and one-shot commands

From `scripts/check frappe-project --benchmark` (m3, `benchmark.json` complete). Edits are HTTP-visible latency over 20 samples; compare the previous baseline in development-performance.md.

| Metric | 2 resources | 22 resources | 22 resources, 2026-09-19 baseline |
|---|---|---|---|
| CSS edit, median / p95 | 78 / 79 ms | 108 / 115 ms | p95 157 ms |
| JavaScript edit, median / p95 | 77 / 79 ms | 112 / 115 ms | p95 159 ms |
| View edit, median / p95 | 4818 / 4970 ms | 5674 / 5945 ms | p95 7.65 s (ECR) |
| Crystal controller edit, median / p95 | 4868 / 5076 ms | 5792 / 5950 ms | p95 7.76 s |
| First development readiness | 5223 ms | 5509 ms | 5.96 s |
| Cached development readiness | 290 ms | 275 ms | 217 ms |
| Type check (`--no-codegen`, no `-D`) | 1007 ms | 1446 ms | 3.74 s |
| `frappe corretto` (N = 1) | 7954 ms | 10632 ms | 12.72 s |
| `frappe migrate` after 20 `make resource` | – | 4777 ms | – |
| `--release` build / binary | 39.03 s / 3.33 MiB | 82.46 s / 5.73 MiB | 56.94 s / 3.53 MiB |

The 2-resource Crystal save regressed from a 4.55 s to a 5.08 s p95: the Tier-1 check added 1.03 s (m2f-2) while the build improved only 2.43 → 2.29 s. At 22 resources, the faster type checker (3.05 → 0.70 s `Semantic (main)`) outweighs the added check.

Anatomy of the 22-resource Crystal save (median 5792 ms). The parts come from separate measurements, so they sum only approximately:

| Part | ms | Source |
|---|---|---|
| Tier-1 type check (`--no-codegen`) | 1430 | m2a-2 |
| Warm build with one changed module | 2906 | profile `22/controller_edit` |
| Outside the compiler | 1456 | 5792 − 1430 − 2906 |
| · first exec of the freshly linked binary | 566 | fq-App-3 |
| · debounce (200) + completion and health polling (2 × 25 + 25) + benchmark curl polling (≈25) | ≈300 | `src/frappe/dev_session.cr:121`, `:232-234`, `:255-283` |
| · two `__caramel_dev_child` relaunches, each with its 50 ms post-exit sleep | 124 | fq-App-0; `src/frappe/dev_child.cr:32-34` |
| · source snapshot + binary/.dwarf SHA-256 | 40 | fq-App-2-fixed |
| · app boot to `/health` (upper bound; cached readiness also includes some of the above) | ≤275 | `cached_dev_ready_ms` |
| · unattributed | ≈150 | remainder |

### Release tool

| Step | Seconds | Source |
|---|---|---|
| `scripts/release --dry-run` at v0.4.0: rebuild `bin/release` + `git status`/`describe`/`log`, then exit (nothing to release) | 1.85 / 1.30 | m4-release-dry-1/-2 |
| one migration probe: cold `crystal run` of a new temp path requiring `cold_brew/migrations.cr` | 1.95 | fq-Sui-8 |
| two probes concurrently | 2.59 | fq-Sui-8 |
| `git archive` + `tar -xf` of the whole v0.4.0 tree / of `src/` only | 0.16 / 0.02 | fq-Sui-9 |
| release-tool work outside the suite in the 0.4.0 release | ≈9 | 747 − 738 |
| full-suite gate (`scripts/cut/cut.cr:111`, ADR 0016 §6) | 738 | 0.4.0 release log |

## Opportunities: suite and release

Ranked by `check-all` seconds saved ÷ effort points (S = 1, M = 3, L = 8); ties go to lower risk, then lower effort. Rows qualify when they save `check-all`, `release`, `framework-spec` or `install` time. A `framework-spec` saving also counts toward `check-all`, since every suite runs the framework spec once. Suite savings rest on the 0.4.0 release log's per-run times unless marked measured.

| Rank | Opportunity | Saving per check-all | Effort | Risk | Evidence |
|---|---|---|---|---|---|
| 1 | E4-1: Run the frappe-project flow once in `check all` (keep only the `--dev` run) | 128 s (estimated) | S | low | `all.cr:61-63`, `frappe_project.cr:125`; log 128 s; m3 flow ≈117 s |
| 2 | E4-7: Run `check all` in 2–3 parallel lanes after the build step, one toolchain prefix and compiler cache per lane | 344 s (estimated); 3 lanes 387 s | L | high | `all.cr:3-4`, `scripts/crystal:88`, `cache_dir.cr:122-129`; log per-run times |
| 3 | E4-4: Lint check reuses a fresh `bin/frappe-lint` instead of rebuilding it | 33.42 s (estimated, measured parts) | S | low | `lint.cr:11`, `frappe/lint.cr:56-61`; m5 36.02 vs 6.91 s; fq-Com-4 |
| 4 | E4-3: LatteFixture reuses the build step's `bin/frappe` and one prebuilt environment daemon under `check all` | 22.06 s (estimated) | S | low | `latte_fixture.cr:112-113`; fq-Com-4 3.70 s + 2.42 s |
| 5 | E1-1: Give each checkout program its own `CRYSTAL_CACHE_DIR` root so the 10-slot LRU stops evicting framework builds | 59.24 s (estimated, measured parts) | M | medium | `cache_dir.cr:122-129`, `scripts/crystal:88`; m5 36.02 vs 6.91 s; fq-Com-4 34.83 vs 4.70 s |
| 6 | E4-2: Compile one multi-check binary per suite instead of 23 check binaries | 39.3 s (estimated) | M | medium | `scripts/check:17-18`; fq-Com-4 1.48 s, fq-Sui-1 2.20 s |
| 7 | E1-4: `scripts/crystal` fast path: fewer processes per compiler call | 10.3 s (estimated); install 0.2 s | S | low | m2h 0.080 s/call; fq-Com-6 0.032 s/call |
| 8 | E4-8: Parametrise the IPC read timeout and request deadline so latte-ipc's trickle proof takes ≈2.6 s instead of 12.4 s | 9.8 s (estimated) | S | medium | `latte_ipc.cr:42-45`, `server.cr:89-90,110` |
| 9 | E4-5: Incremental Swift builds so latte-ipc, native and the dev phase stop rebuilding Latte.app and the relay | 8.91 s (estimated, measured parts) | S | low | fq-Sui-6 2.38 s, 1.77 s |
| 10 | E4-9: Build independent artifacts concurrently in `build-release`, the build step and `build-installers` | 25.9 s (estimated); install 14.7 s | M | medium | `build-release:9-12`; fq-Sui-4/5 48.62 vs 33.11 s |
| 11 | E4-6: Run the 31 compile-only `--no-codegen` cases with bounded concurrency | 8.48 s (estimated) | S | low | `route_compilation.cr:21-22`; fq-Sui-2/3 5.96 vs 2.19 s |
| 12 | E4-10: Run the release's two migration probes concurrently and extract only `src/` from the tag archive | 1.31 s (estimated); release 1.45 s | S | medium | `cut.cr:101,146-151`; fq-Sui-8/9 |
| 13 | E2-5: Run the unit spec's three nested mocking-fixture compiles concurrently | 0.94 s (estimated) | S | low | `mocking_spec.cr:5-10`; fq-Fra-13 |
| 14 | E1-2: Stop the stdlib ECR macro run by overriding `HTTP::StaticFileHandler#directory_listing` | 0 s (estimated); install 6.37 s | S | medium | `static_file_handler.cr:318`; profile cold 6.37 s |
| 15 | E4-11: Skip the release probe compiles when nothing the probe requires changed since the tag | 0 s (estimated); release 4.06 s | M | medium | `cut.cr:101,137-165`; fq-Sui-8/9 |

### 1. E4-1: Run the frappe-project flow once in `check all` (keep only the `--dev` run)

- **Status.** Implemented in v0.4.1 (`af68d1d`). The v0.4.1 release gate ran no standalone frappe-project run (0.4.0: 128 s); frappe-project-dev took 169 s (0.4.0: 177 s).
- **Mechanism.** `scripts/checks/all.cr` lists `frappe-project` from the check glob and appends `frappe-project --dev` (`scripts/checks/all.cr:61-63`). The `--dev` run executes the whole plain flow, then its dev phase (`scripts/checks/frappe_project.cr:125`, `Dev.new(self, clone).check if args.includes?("--dev")`), then the plain run's final serve-and-fetch step (`:128-131`), so every step and assertion of the plain run already runs inside frappe-project-dev. Change: register frappe-project only once, with `--dev`. `scripts/check frappe-project` stays available on its own.
- **Evidence.** `scripts/checks/all.cr:61-63`; `scripts/checks/frappe_project.cr:125`; 0.4.0 log: frappe-project 128 s, frappe-project-dev 177 s; m3 contains one fixture flow of ≈117 s (711.02 s total − 594 s sampled benchmark span).
- **Savings.**
  - `check-all`: **128 s** (estimated). The standalone frappe-project run goes: 128 s (0.4.0 release log). Cross-check: one fixture flow measured ≈117 s inside m3 (711.02 s total − 594 s sampled span).
  - Score: 128 ÷ 1 = 128.00.
- **Effort S, risk low.** The dev run already covers the plain run; only the reporting changes (one PASS line for both). A failure before line 125 still stops before the dev phase; the final HTTPS page check now runs after the ≈49 s dev phase (177 − 128), so a failure there surfaces later.
- **Verify after implementing.** `scripts/check all` prints no `PASS frappe-project (` line, and the sum of PASS seconds drops by ≈128 s from 738 s.
- **Overlaps.** E4-3 (one fixture fewer: its saving falls to 3 × 3.70 + 2 × 2.42 = 15.9 s); E4-2 (one check-binary compile fewer); E4-7 (lane schedules change: 2 lanes then save 281 s, 3 lanes 376 s); E3-2 (would also shrink the flow's own rebuilds); E4-9 (same file, `scripts/checks/all.cr`). Savings that share seconds are not additive.

### 2. E4-7: Run `check all` in 2–3 parallel lanes after the build step, one toolchain prefix and compiler cache per lane

- **Mechanism.** `check all` runs its 24 runs one after another because they share one compiler cache (`scripts/checks/all.cr:3-4`, `CONTRIBUTING.md:16`). Keep the build step as a barrier, then run 2–3 lanes. Every lane but one gets a private toolchain prefix like the one `scripts/checks/compiler_profile.cr:41-46` builds (own `crystal-cache`), plus a new APFS clone of `shards-cache`, so `scripts/crystal:88` gives it its own `CRYSTAL_CACHE_DIR` and Frappé follows `CARAMEL_TOOLCHAIN_ROOT` (`src/latte/toolchain.cr:52-54`). That removes the shared-cache hazards: the unlocked keep-10 cleanup (`codegen/cache_dir.cr:122-129`), the one `<repo>/spec` cache dir and `crystal-run-spec.tmp` (`command/spec.cr:92`, `:99`). Prerequisites: E4-3, E4-4 and E4-5 with its bundle step made conditional (no `bin/` rewrites while lanes run), `build-installers` in the build step, frappe-project(-dev) in one lane, installations on the real-toolchain lane (`scripts/checks/installations.cr:33-36`), the four spec programs in one lane, browser first in its lane (the screen must stay unlocked only for its ≈28 s), latte-daemon on its fixed ports (other lanes use free ports).

  Schedules, 0.4.0 seconds, build 46 s first. **2 lanes:** A = frappe-project 128 + frappe-project-dev 177 + lint 36 + cold-brew 3 = 344; B = spec 22 + native 26 + integration 16 + latte-postgres 9 + schema-diff 78 + installations 79 + browser 28 + latte-ipc 20 + editor-tools 9 + orm 11 + route 8 + latte-daemon 8 + dev-retirement 6 + latte-network 6 + runtime-diagnostics 6 + compiler 4 + contract 4 + dev-child 4 + toolchain-paths 4 = 348; wall 46 + 348 = 394 s. **3 lanes:** A = frappe-project 128 + frappe-project-dev 177 = 305; B (real toolchain) = spec 22 + native 26 + integration 16 + latte-postgres 9 + installations 79 + lint 36 + cold-brew 3 = 191; C = the other 14 runs = 196; wall 46 + 305 = 351 s. **With E4-1** (610 s of runs): 2 lanes A = browser 28 + frappe-project-dev 177 + schema-diff 78 = 283, B = 281, wall 329 s; 3 lanes 188 + 188 + 188, wall 234 s.
- **Evidence.** `scripts/checks/all.cr:3-4`; `CONTRIBUTING.md:16`; `scripts/crystal:88`; `codegen/cache_dir.cr:122-129`; `scripts/checks/installations.cr:33-36`; 0.4.0 per-run times; CPU headroom: 12 cores, m3 user/wall 1012.65/711.02 = 1.42 (a lower bound, see Method).
- **Savings.**
  - `check-all`: **344 s** (estimated). 2 lanes: wall 46 + 348 = 394 s vs 738 s → 344 s (3 lanes: 46 + 305 = 351 s → 387 s). After E4-1 (610 s of runs): 2 lanes 329 s (→ 281 s), 3 lanes 234 s (→ 376 s). No contention assumed.
  - Score: 344 ÷ 8 = 43.00.
- **Effort L, risk high.** Timing-sensitive checks can flake under load: the menu client spec's 1.2 s delays against a 2 s deadline, latte-ipc's 3.1 s trickles against a 5 s read timeout (`src/latte/server.cr:89-90`). Other costs: free-port races across lanes, 1.2–2.5 GB of summed RSS per concurrent compiler (development-performance.md), and rewriting the rule in `CONTRIBUTING.md:16`. ADR 0016 §6 is unaffected: every check still runs before the tag.
- **Verify after implementing.** On a clone, three `caffeinate -d scripts/check all` runs: wall ≤ 394 s (2 lanes) or ≤ 351 s (3 lanes) plus contention, zero flaky FAILs, and no evicted cache entries in lane 1's cache while other lanes compile. Contention was not measured (the follow-up needed more than 5 minutes).
- **Overlaps.** Every other suite row: they shorten runs inside lanes, and lanes shorten the wall around them. E1-1 uses the same cache-isolation tool per program instead of per lane. Savings that share seconds are not additive.

### 3. E4-4: Lint check reuses a fresh `bin/frappe-lint` instead of rebuilding it

- **Status.** Implemented in v0.4.1 (`28770aa`) with a different trigger: once `check all`'s build step passes it sets `CARAMEL_CHECK_ALL_BUILT`, and the lint check then skips `scripts/build-lint`. A standalone `scripts/check lint` always rebuilds. Unlike the staleness rule, this cannot miss a toolchain change or a require outside the glob. lint took 3 s in the v0.4.1 release gate (0.4.0: 36 s).
- **Mechanism.** `scripts/checks/lint.cr:11` always runs `scripts/build-lint`, though the build step built the same `bin/frappe-lint` minutes earlier (`scripts/checks/all.cr:30`). By the lint run (17th of 24) the linter's and Ameba's `read_type_doc` cache dirs have been evicted, so the rebuild is cold: 34.83 s, of which 26.28 s is the -O3 `read_type_doc` macro-run helper (`lib/ameba/src/ameba/rule/base.cr:157-161`). Change: apply the staleness rule `frappe lint` already uses (`src/frappe/lint.cr:56-61`: rebuild only when `src/frappe/lint/*.cr`, `src/frappe_lint.cr` or `shard.lock` is newer than the binary).
- **Evidence.** `scripts/checks/lint.cr:11`; `src/frappe/lint.cr:56-61`; m5-lint-1 36.02 s (created the three evicted entries) vs m5-lint-2 6.91 s; fq-Com-4 linter cold 34.83 s (`read_type_doc` 26.28 s), warm 4.70 s; 0.4.0 lint 36 s.
- **Savings.**
  - `check-all`: **33.42 s** (estimated, from measured parts). m5-lint-1 36.02 − m5-lint-2 6.91 = 29.11 s (cold vs warm lint run), plus the warm linter rebuild still inside m5-lint-2 (fq-Com-4 frappe_lint warm 4.70 s), minus the lint check binary's own cold−warm difference that stays (fq-Com-4 route_compilation proxy 1.48 − 1.09 = 0.39 s): 29.11 + 4.70 − 0.39 = 33.42 s.
  - Adjusted after the follow-up measurements: expert 29 s (estimated); follow-up fq-Com-4 measured the warm rebuild.
  - Score: 33.42 ÷ 1 = 33.42.
- **Effort S, risk low.** The rule is one Frappé already trusts for this binary, and the build step always rebuilds, so `check all` still tests a fresh linter. The rule misses edits to other files `frappe_lint.cr` requires; widen the glob if that matters.
- **Verify after implementing.** In `scripts/check all`, `PASS lint` takes ≈3 s (was 36 s). A standalone `scripts/check lint` after touching `src/frappe/lint/*.cr` still rebuilds.
- **Overlaps.** E1-1 (keeps the rebuild warm instead: the same ≈29 s); E4-9 (the build step's linter is the critical path there); E4-7. Savings that share seconds are not additive.

### 4. E4-3: LatteFixture reuses the build step's `bin/frappe` and one prebuilt environment daemon under `check all`

- **Status.** Implemented in v0.4.1 (`173258e`). The build step also builds the daemon, into `bin/checks/frappe-environment`, and fixtures skip both builds under `CARAMEL_CHECK_ALL_BUILT`. A partial `check all` built `src/frappe.cr` and `frappe_environment.cr` once each outside installations. In the v0.4.1 release gate schema-diff took 72 s (0.4.0: 78 s) and browser 23 s (28 s).
- **Mechanism.** `LatteFixture#start` runs `scripts/build-frappe` and compiles `spec/fixtures/frappe_environment.cr` (`scripts/checks/support/latte_fixture.cr:112-113`) in browser, frappe-project, schema-diff and frappe-project-dev, though the build step already built `bin/frappe` from the same tree (`scripts/checks/all.cr:30`, `scripts/build-frappe:6`). Change: `check all` builds the environment daemon once after the build step and sets a flag that makes fixtures skip both builds. Standalone checks keep building. Each fixture keeps its fresh initdb and CA.
- **Evidence.** `scripts/checks/support/latte_fixture.cr:112-113`; `scripts/build-frappe:6`; fq-Com-4: `src/frappe.cr` 3.70 s cold / 2.65 s warm, `frappe_environment.cr` 2.42 s / 1.72 s.
- **Savings.**
  - `check-all`: **22.06 s** (estimated). 4 `bin/frappe` builds × 3.70 s + 3 of 4 environment builds × 2.42 s = 14.80 + 7.26 = 22.06 s (cold build times, fq-Com-4, cache with the ECR helper warm). That these rebuilds are cold in the suite is inferred from the 10-entry LRU.
  - Adjusted after the follow-up measurements: expert 20 s (estimated) from app-scale proxies; follow-up fq-Com-4 measured both programs.
  - Score: 22.06 ÷ 1 = 22.06.
- **Effort S, risk low.** Under `check all` the build step and the fixtures build the same tree minutes apart, and no check edits `src/`.
- **Verify after implementing.** Watching processes during `check all`: one `crystal build …src/frappe.cr` (was 5) and one `frappe_environment.cr` build (was 4); the four fixture runs lose ≈22 s together.
- **Overlaps.** E4-1 (one fixture fewer); E1-1 (would make these rebuilds warm instead: 4 × 1.05 + 3 × 0.70 = 6.3 s); E4-7 (prerequisite); E4-2 and E4-9 (same file, `scripts/checks/all.cr`). Savings that share seconds are not additive.

### 5. E1-1: Give each checkout program its own `CRYSTAL_CACHE_DIR` root so the 10-slot LRU stops evicting framework builds

- **Mechanism.** Crystal keeps the 10 most recently modified program dirs in one cache and deletes the rest after every code generation (`codegen/cache_dir.cr:122-129`, called from `compiler.cr:398`). `scripts/crystal:88` sends every compile to one `crystal-cache`, shared by the developer's apps, the suite's random `/private/tmp` projects, the spec programs (all keyed `<cwd>/spec`, `command/spec.cr:92`) and about 23 check binaries. One suite creates far more than 10 dirs, so stable programs recur cold. Change: `scripts/crystal` keys checkout programs to their own root outside the shared cache, e.g. `$BASE/crystal-cache-repo/<program>`. Each root holds fewer than 10 dirs, so its own cleanup deletes nothing, and the parent is never a `CRYSTAL_CACHE_DIR`. The roots must not sit inside `crystal-cache`: a build in the shared root cleans every child of that root (`codegen/cache_dir.cr:54-58`, `:131-133`), so a nested `repo/` dir would be deleted once 10 newer entries exist. Transient and user programs stay in shared roots, because a new root per random path would recompile the ECR helper each time (6.37 s).
- **Evidence.** `codegen/cache_dir.cr:122-129`; `scripts/crystal:88`; m5: lint cold 36.02 s vs warm 6.91 s; route-compilation evicted `spec-fixtures-frappe_dev.cr`; the owner's two app builds and M3's projects evicted the lint entries; 328 MB for 10 entries.
- **Savings.**
  - `check-all`: **59.24 s** (estimated, from measured parts). The lint check's rebuild, cold vs warm: m5-lint-1 36.02 − m5-lint-2 6.91 = 29.11 s (measured). The build step's own linter rebuild (`scripts/checks/all.cr:30`), cold 34.83 s vs warm 4.70 s (fq-Com-4): 30.13 s. The 0.4.0 build step's 46 s matches the cold per-build sum 3.70 + 2.47 + 2.38 + 1.77 + 34.83 = 45.15 s; the build-step part is 0 s when the linter happens to be cached already. Total 29.11 + 30.13 = 59.24 s. Not counted (estimated, from measured cold − warm deltas in fq-Com-4, fq-Sui-1, fq-Sui-4 and fq-Fra-12, if those programs are cold in the suite): frappe.cr 5 × 1.05, latte.cr 0.83, frappe_environment.cr 4 × 0.70, frappe_dev.cr 0.79, 23 check binaries × ≈0.5, unit spec 2.06 ≈ 23 s more.
  - Adjusted after review: the expert's 29.11 s covered only the lint check; the build step's linter rebuild was added.
  - Score: 59.24 ÷ 3 = 19.75.
- **Effort M, risk medium.** Disk grows to ≈1.5 GB (≈45 checkout programs, the CompilerToolchainExpert's estimate, × 32.8 MB per entry from 328 MB / 10), and stale roots need pruning. Parsing argv in `sh` can mis-key a program; that costs only speed, since Crystal validates reused objects byte for byte.
- **Verify after implementing.** Run `scripts/check lint`, three other checks, then `scripts/check lint` again: the second lint takes ≈6.9 s (m5-lint-2), not 36.02 s. Then build 10 or more programs in the shared root (for example user apps) and confirm the lint root survives. In the next `check all`, lint takes ≈7 s and `PASS build` ≈16 s (46 − 30.13).
- **Overlaps.** E4-4 (removes the same lint rebuild outright); E4-3 and E4-2 (would make their rebuilds warm instead of removing them); E4-7 (needs the same isolation); E1-2 (each new root pays the ECR helper once); E4-9 (a warm linter removes the cold critical path its build-step saving is computed from); E1-4 and E1-5 (same file, `scripts/crystal`). Savings that share seconds are not additive.

### 6. E4-2: Compile one multi-check binary per suite instead of 23 check binaries

- **Mechanism.** `scripts/check:17-18` compiles `scripts/checks/<name>.cr` before every exec, 23 times per suite (frappe_project twice), each into its own cache dir that the 10-entry LRU has evicted since the last suite. Change: each check becomes a `main(args)` in a table; `check all` compiles one `bin/checks/checks` and runs `bin/checks/checks NAME` in a separate process per check. `scripts/check NAME` can keep building one check.
- **Evidence.** `scripts/check:17-18`; `scripts/checks/all.cr:62`; cold check-binary compiles 1.48 s (route_compilation, fq-Com-4) and 2.20 s (frappe_project, fq-Sui-1); m5-route-compilation created a fresh check-binary cache entry.
- **Savings.**
  - `check-all`: **39.3 s** (estimated). 23 cold check-binary compiles × 1.84 s (mean of fq-Com-4 route_compilation 1.48 s and fq-Sui-1 frappe_project 2.20 s) = 42.3 s, minus ≈3 s for the one union binary (the SuiteReleaseExpert's estimate) = 39.3 s.
  - Adjusted after the follow-up measurements: expert 40 s from the m4 proxy; follow-ups measured two check binaries.
  - Score: 39.3 ÷ 3 = 13.10.
- **Effort M, risk medium.** Five checks run top-level code that must move into functions (native, route/orm/contract/cold-brew compilation), and a compile error in any check now stops the suite at its start.
- **Verify after implementing.** Count `crystal build …scripts/checks/` processes during `check all`: 1 (was 23); the run sum drops ≈39 s.
- **Overlaps.** E4-1 (one compile fewer); E4-6; E1-1 (warm check binaries would save ≈0.5 s each instead); E1-4; E3-8 (22 fewer freshly linked binaries to launch); E4-3 and E4-9 (same file, `scripts/checks/all.cr`). Savings that share seconds are not additive.

### 7. E1-4: `scripts/crystal` fast path: fewer processes per compiler call

- **Mechanism.** Before `exec`, every compiler call re-runs the wrapper's checks: pointer checks, `openssl dgst` of the toolchain path (`scripts/crystal:32`), runtime-dir and alias checks, and a three-file `.pc` rewrite loop with `grep`/`mktemp`/`sed`/`cmp` (`scripts/crystal:54-81`), about 35 process spawns. Change: cache the key, check ownership and modes with one `stat`, and skip the rewrite when a stamp in the private runtime dir matches. Keep every check, and fall back to the full path on any mismatch.
- **Evidence.** m2h: 10 calls 0.94 s through the wrapper vs 0.14 s direct → 0.080 s per call; fq-Com-6: without the `.pc` loop 0.688 s vs 1.010 s per 10 calls → the loop is 0.032 s per call; `scripts/crystal:32`, `:54-81`.
- **Savings.**
  - `check-all`: **10.3 s** (estimated). ≈206 wrapper calls per suite (the CompilerToolchainExpert's estimate from the per-check compile counts in the code-reading reports) × 0.05 s. Measured overhead 0.080 s/call (m2h: (0.94 − 0.14)/10); the `.pc` rewrite loop alone is 0.032 s/call (fq-Com-6: (1.010 − 0.688)/10); the fast path keeps ≈0.03 s.
  - `install`: **0.2 s** (estimated). ≈4 calls in build-release × 0.05 s
  - `dev-save-22`: **0.1 s** (estimated). 2 calls (check + build) × 0.05 s
  - `dev-save-2`: **0.1 s** (estimated). 2 calls × 0.05 s
  - `frappe-command`: **0.05 s** (estimated). 1 call × 0.05 s
  - `corretto-22`: **0.1 s** (estimated). 2 calls (migrate compile + 1 worker) × 0.05 s
  - Score: 10.3 ÷ 1 = 10.30.
- **Effort S, risk low.** The wrapper guards a private metadata dir in the shared `/private/tmp` and `.pc` files that Crystal pastes unquoted into a shell (`scripts/crystal:30-31`). The fast path must keep those checks, or it opens a tampering window.
- **Verify after implementing.** Re-run m2h: 10 calls ≤ 0.45 s (was 0.94 s), and a build still links against `$RUNTIME/openssl`.
- **Overlaps.** E3-1 (one wrapper call fewer per save); E4-2 and E4-6 (fewer calls in the suite); E3-2 (a hit removes the command's call); E1-1 and E1-5 (same file, `scripts/crystal`). Savings that share seconds are not additive.

### 8. E4-8: Parametrise the IPC read timeout and request deadline so latte-ipc's trickle proof takes ≈2.6 s instead of 12.4 s

- **Status.** Implemented in v0.4.1 (`8dc625b`) with a 2 s idle timeout, a 2.5 s deadline and 0.7 s gaps. A spec pins the daemon's 5 s and 12 s, and with a 10 s deadline the check fails. latte-ipc took 8 s in the v0.4.1 release gate (0.4.0: 20 s), which includes E4-5.
- **Mechanism.** latte-ipc trickles four headers 3.1 s apart (`scripts/checks/latte_ipc.cr:42-45`). Each gap stays under the 5 s read timeout (`src/latte/server.cr:89-90`) while the total passes the 12 s request deadline (`src/latte/server.cr:110`), which proves the deadline cuts off a trickled request. Change: make both values constructor parameters with the production defaults, pass e.g. 1 s and 2.5 s from the fixture, trickle 4 × 0.65 s, and pin the defaults with a unit spec.
- **Evidence.** `scripts/checks/latte_ipc.cr:42-45`; `src/latte/server.cr:89-90`, `:110`; 0.4.0 latte-ipc 20 s.
- **Savings.**
  - `check-all`: **9.8 s** (estimated). 12.4 s of fixed sleeps (`scripts/checks/latte_ipc.cr:42-45`) − 4 × 0.65 s = 9.8 s.
  - Score: 9.8 ÷ 1 = 9.80.
- **Effort S, risk medium.** The end-to-end check then exercises the mechanism with scaled values, not the production 12 s; the default-pinning spec covers the constants. Margins under load get tighter (do not scale below ≈0.35 s under a 1 s timeout).
- **Verify after implementing.** `scripts/check latte-ipc` still prints its expired-trickle PASS line and runs ≈10 s faster.
- **Overlaps.** E4-5 (the same run's Latte.app rebuild); E4-7. Savings that share seconds are not additive.

### 9. E4-5: Incremental Swift builds so latte-ipc, native and the dev phase stop rebuilding Latte.app and the relay

- **Status.** Implemented in v0.4.1 (`722ae34`) with a different trigger: under `CARAMEL_CHECK_ALL_BUILT`, latte-ipc, native and the dev phase skip the Swift builds the build step just made, so nothing rewrites `bin/Latte.app` after it. The build step still always compiles, so no stamp is needed. A partial `check all` compiled `Latte.swift` and `PortRelay.swift` once each outside installations; native took 23 s in the v0.4.1 release gate (0.4.0: 26 s).
- **Mechanism.** Latte.app is rebuilt with `swiftc -O` by the build step, latte-ipc (`scripts/checks/latte_ipc.cr:19`), native (`scripts/checks/native.cr:3`) and the dev phase (`scripts/checks/frappe_project/dev.cr:114`); the relay by the build step and native (`scripts/build-latte-menu:14-22`, `scripts/build-latte-relay`). Change: wrap each `swiftc` call in the repo's existing `find … -newer` test (as `scripts/install-toolchain:5` does), and make the bundle step conditional too (`scripts/build-latte-menu:24-41`: Info.plist copy, two `plutil` version edits, icon copy, `chmod`), running it only when `latte/macos/Info.plist` or `shard.yml` is newer, so a no-op call writes nothing into `bin/Latte.app`.
- **Evidence.** fq-Sui-6 with a warm module cache: Latte.app 2.38 s, relay 1.77 s; `scripts/build-latte-menu:14-22`.
- **Savings.**
  - `check-all`: **8.91 s** (estimated, from measured per-build times). 3 Latte.app rebuilds × 2.38 s + 1 relay rebuild × 1.77 s = 8.91 s (fq-Sui-6, warm module cache, which the suite's shared Swift module cache is assumed to be).
  - Adjusted after the follow-up measurements: expert 8 s (estimated); follow-up fq-Sui-6 measured per-build swiftc time.
  - Score: 8.91 ÷ 1 = 8.91.
- **Effort S, risk low.** An mtime test misses a `swiftc` upgrade; add a stamp of `/usr/bin/swiftc --version`. Leaving the bundle step unconditional would keep rewriting `bin/Latte.app` while other lanes launch it (E4-7).
- **Verify after implementing.** During `check all`, `Latte.swift` compiles once outside installations (was 4) and `PortRelay.swift` once (was 2).
- **Overlaps.** E4-9; E4-7 (prerequisite); E4-8. Savings that share seconds are not additive.

### 10. E4-9: Build independent artifacts concurrently in `build-release`, the build step and `build-installers`

- **Mechanism.** `scripts/build-release:9-12` runs shards install, `build-frappe`, `build-latte` (Crystal plus the menu and relay `swiftc`) and `build-lint` one after another; `build-installers` builds three installers in sequence; the build step chains the same three (`scripts/checks/all.cr:30`). After shards install these are independent programs with separate cache dirs. Change: run them as parallel jobs with buffered output, capped at 2–3 Crystal compiles by memory. The cold linter (34.83 s) becomes the critical path. These builds share one compiler cache: the installations check and a user install reuse the checkout's toolchain (`scripts/checks/installations.cr:33-36`, `scripts/crystal:88`), which is why `scripts/checks/all.cr:3-4` and `CONTRIBUTING.md:16` forbid concurrent compiles. Every build ends with the unlocked keep-10 cleanup (`codegen/cache_dir.cr:122-129`), and a warm build that only reads its objects keeps an old directory mtime, so a concurrent build's dir could be deleted mid-build. Mitigation: touch each program's cache dir just before starting it, so the two or three in-flight dirs are the newest and survive the keep-10 cleanup, or make E1-1 a prerequisite. The fq-Sui-5 evidence ran in a fresh private prefix, where the race cannot happen.
- **Evidence.** `scripts/build-release:9-12`; `scripts/checks/all.cr:30`; three cold Crystal builds: 48.62 s sequential (fq-Sui-4) vs 33.11 s concurrent (fq-Sui-5); per-build times fq-Com-4 and fq-Sui-6.
- **Savings.**
  - `check-all`: **25.9 s** (estimated). Build step: 46 s (0.4.0 log) with the cold lint build (34.83 s, fq-Com-4) on the critical path → ≈11.2 s saved. installations: installers 3.27 + 1.83 + 2.57 → 3.27 when parallel (4.4 s saved); build-release frappe 3.70 ‖ latte 2.47 + menu 2.38 + relay 1.77 ‖ lint 34.83 → 3.70 + 6.62 = 10.3 s saved; 14.7 s. Total 11.17 + 4.40 + 10.32 = 25.9 s.
  - `install`: **14.7 s** (estimated). The installations arithmetic above: 4.40 + 10.32 = 14.7 s (per-build times measured in fq-Com-4 and fq-Sui-6; concurrency assumed contention-free). Direct check: three cold Crystal builds took 33.11 s concurrently vs 48.62 s sequentially (fq-Sui-5/4).
  - Adjusted after the follow-up measurements: expert install 17 / check-all 34 (estimated); recomputed from measured per-build times.
  - With the touch-first mitigation above these savings hold. E1-1 alone covers only the build-step part (11.2 s), because the installations clone and user installs build under paths outside E1-1's roots. Without either, only the `swiftc` steps may run concurrently: menu + relay 2.38 + 1.77 = 4.15 s hidden in the build step, installers 4.40 + 4.15 = 8.55 s in installations, ≈12.7 s per `check all`.
  - Score: 25.9 ÷ 3 = 8.63.
- **Effort M, risk medium.** It relaxes the one-cache rule inside a build step, so the mitigation above must land with it. Three concurrent compilers at 1.2–2.5 GB each (summed RSS during rebuilds, development-performance.md) can swap on small Macs; the job runner must keep each job's log and first-failure semantics.
- **Verify after implementing.** `scripts/check installations` ≈15 s faster than 79 s; `PASS build` ≈11 s faster than 46 s; `frappe installations install` on a scratch `CARAMEL_HOME` ≈15 s faster.
- **Overlaps.** E4-4 (the build step's linter stays the critical path); E4-5; E4-7; E1-1 (a warm linter removes the cold critical path); E4-1, E4-2 and E4-3 (same file, `scripts/checks/all.cr`). Savings that share seconds are not additive.

### 11. E4-6: Run the 31 compile-only `--no-codegen` cases with bounded concurrency

- **Mechanism.** route (12 cases), orm (15), contract (3) and cold-brew (1) compile their fixtures one after another with `--no-codegen` (`scripts/checks/route_compilation.cr:21-22`). 27 of them must each fail with their own diagnostic, so they cannot share one compiler process, but `--no-codegen` never reaches the code-generation path that creates program cache dirs and runs the keep-10 cleanup (`compiler.cr:365`, `:398`); only a cold macro-run helper creates its own dir, with cleanup disabled (`macros/macros.cr:164-170`). Change: run the first case alone (warming any macro-run helper), then the rest with 4 workers, reporting in case order.
- **Evidence.** `scripts/checks/route_compilation.cr:21-22`; `compiler.cr:365`, `:398`; fq-Sui-2 5.96 s sequential vs fq-Sui-3 2.19 s with 4 workers.
- **Savings.**
  - `check-all`: **8.48 s** (estimated). Route: 12 cases sequential 5.96 s vs 4 workers 2.19 s = 3.77 s, 0.314 s per case (measured, fq-Sui-2/3). The proposed schedule runs each check's first case alone, which forgoes that case's share: (12 − 1) route + (15 − 1) orm + (3 − 1) contract = 27 cases × 0.314 s = 8.48 s; cold-brew's single case gains nothing.
  - Adjusted after the follow-up measurements: expert 10 s (estimated); route part now measured, and the solo first case per check is priced in.
  - Score: 8.48 ÷ 1 = 8.48.
- **Effort S, risk low.** No cleanup runs on this path, and warmed macro-run helpers are only read. Output ordering must stay deterministic, and each case keeps its 90 s timeout.
- **Verify after implementing.** `scripts/check route-compilation` runs ≈3.5 s faster than m5's 7.67 s; `scripts/check orm-compilation` ≈4.4 s faster than 11 s.
- **Overlaps.** E2-5 (the same technique inside the unit spec); E4-2; E1-4. Savings that share seconds are not additive.

### 12. E4-10: Run the release's two migration probes concurrently and extract only `src/` from the tag archive

- **Status.** Implemented in v0.4.1 (`061ec9a`). A tag without the migrations file is read with `git ls-tree` instead of being archived. `scripts/release --dry-run` with both probes, in clones with a `fix:` commit after `v0.4.0`, took 7.51–8.20 s before and 5.49–6.00 s after (four runs each).
- **Mechanism.** `Cut.run` runs the two migration probes one after the other (`scripts/cut/cut.cr:101`). Each is a cold `crystal run` of a new temp path (`scripts/cut/cut.cr:138`, `:159`), and the tag probe extracts the whole tree though it reads only `src/caramel/cold_brew/migrations.cr` (`scripts/cut/cut.cr:146-151`). Change: run both probes concurrently, each compiled to its own output (`crystal build -o <work>/probe`, then run it), and pass `src` as a pathspec to `git archive`. Separate outputs are required: both probe files are named `probe.cr` (`scripts/cut/cut.cr:155`), and `crystal run` links every run of a file with that name to the same `crystal-run-probe.tmp` in the shared compiler cache (compiler `util.cr:23-25`, `command.cr:287`) and deletes it afterwards. Two concurrent `crystal run` probes would link, run and delete one file, so the tag probe could run the working tree's binary and the edited-migration guard would compare the tree with itself. The two probes' new cache dirs are the newest, so the keep-10 cleanup leaves them alone.
- **Evidence.** `scripts/cut/cut.cr:101`, `:146-151`, `:159`; fq-Sui-8 one probe 1.95 s, two concurrent 2.59 s; fq-Sui-9 archive + extract 0.16 s vs 0.02 s. fq-Sui-8's concurrent pair used `crystal run` on two `probe.cr` files, so it shared one temp executable (identical JSON hides a swap); its timing is a proxy.
- **Savings.**
  - `check-all`: **1.31 s** (estimated). Via the framework-spec run inside `check all`.
  - `release`: **1.45 s** (estimated, from measured proxies). Two probes: 2 × 1.95 − 2.59 (concurrent) = 1.31 s (fq-Sui-8); `src/`-only archive + extract 0.02 s vs 0.16 s = 0.14 s (fq-Sui-9). 1.31 + 0.14 = 1.45 s.
  - `framework-spec`: **1.31 s** (estimated). `spec/release/cut_spec.cr` also runs both probes; same 1.31 s assumed.
  - Adjusted after the follow-up measurements: expert release 3.5 / framework-spec 1 (estimated); follow-ups measured the probes and the archive.
  - Score: 1.31 ÷ 1 = 1.31.
- **Effort S, risk medium.** Without separate outputs the probes race on one temp executable and can silently compare the working tree with itself; with them the probes are independent. Error messages must still name the tree that failed.
- **Verify after implementing.** On a clone with a `fix:` commit after the tag, `/usr/bin/time -p scripts/release --dry-run` drops ≈1.4 s.
- **Overlaps.** E4-11 (skips both probes when unchanged; then this saves nothing). Savings that share seconds are not additive.

### 13. E2-5: Run the unit spec's three nested mocking-fixture compiles concurrently

- **Mechanism.** `spec/corretto/mocking_spec.cr:5-10` runs three `--no-codegen` compiles of Corretto fixtures one after another inside the unit spec run. Change: start all three at once in a memoized helper, then assert per example. `--no-codegen` runs no cleanup and creates no program cache dir, and these fixtures ran no macro-run helper (fq-Fra-13).
- **Evidence.** `spec/corretto/mocking_spec.cr:5-10`; fq-Fra-13: 0.82 s, 0.47 s, 0.47 s.
- **Savings.**
  - `check-all`: **0.94 s** (estimated). Via the framework-spec run inside `check all`.
  - `framework-spec`: **0.94 s** (estimated). Measured one by one: 0.82 + 0.47 + 0.47 = 1.76 s (fq-Fra-13); concurrent ≈ the longest, 0.82 s → 0.94 s.
  - Adjusted after the follow-up measurements: expert 0.9 s from proxies; follow-up fq-Fra-13 measured the three compiles.
  - Score: 0.94 ÷ 1 = 0.94.
- **Effort S, risk low.** Test-only change; three concurrent type checks on 12 cores.
- **Verify after implementing.** `scripts/crystal spec spec/corretto/mocking_spec.cr` runs ≈0.9 s faster.
- **Overlaps.** E4-6 (same technique in the compile-only checks). Savings that share seconds are not additive.

### 14. E1-2: Stop the stdlib ECR macro run by overriding `HTTP::StaticFileHandler#directory_listing`

- **Mechanism.** Programs that run an `HTTP::Server` handler chain (apps, Frappé, Latte) make `HTTP::StaticFileHandler#call` reachable, and with it the directory listing (`static_file_handler.cr:330-331` in the Crystal stdlib), which calls `DirectoryListing#to_s`, generated by `ECR.def_to_s` (`:318`). Requiring `http/server` alone is not enough: the route_compilation check binary and the fq-Com-3 probe run no ECR macro. Typing the listing runs the `ecr/process` macro-run helper, compiled at -O3: 6.37 s in an empty cache, 0.005 s once cached. Change: a small file required right after `http/server` by caramel, frappe and latte redefines `directory_listing` without ECR.
- **Evidence.** stdlib `http/server/handlers/static_file_handler.cr:318`, `:330-331`; profile cold rows `Macro runs: process.cr 6.37 s` (58% and 62% of the cold builds). fq-Com-3 was inconclusive: its probe never started a server, so neither variant reached the listing.
- **Savings.**
  - `check-all`: **0 s** (estimated). Steady state: the helper stays in the shared cache (present in every listing).
  - `install`: **6.37 s** (estimated). A fresh cache pays the ECR helper once: 6.37 s (profile cold rows). Whether install pays it is inferred; the fq-Com-3 probe was inconclusive (it never reached the code).
  - Score: 0 ÷ 1 = 0.00.
- **Effort S, risk medium.** It monkey-patches a private stdlib method; a Crystal upgrade can silently undo it (speed only). Apps that serve directory listings need equivalent HTML.
- **Verify after implementing.** `scripts/check compiler-profile`: both cold rows show no `Macro runs:` line, and cold wall drops to ≈3.8 s (2 resources) and ≈4.7 s (22).
- **Overlaps.** E1-1 (a new cache root pays the helper once; this removes that cost). Savings that share seconds are not additive.

### 15. E4-11: Skip the release probe compiles when nothing the probe requires changed since the tag

- **Mechanism.** The probes only compare framework migrations (version, name, checksum) between the tag and the working tree (`scripts/cut/cut.cr:101`, `:158`). If nothing in the probe's require closure (plus `shard.lock`) changed since the tag, both print the same JSON. Change: compute the closure with `crystal tool dependencies`, run `git diff --quiet <tag> HEAD -- <closure> shard.lock`, and run the probes only when it differs.
- **Evidence.** `scripts/cut/cut.cr:101`, `:137-165`; fq-Sui-8 1.95 s per probe; fq-Sui-9 0.16 s archive.
- **Savings.**
  - `check-all`: **0 s** (estimated). Release-only.
  - `release`: **4.06 s** (estimated, from measured proxies). Both probes 2 × 1.95 s (fq-Sui-8) + full archive and extract 0.16 s (fq-Sui-9) = 4.06 s when the closure is unchanged, 0 s otherwise, minus the unmeasured cost of the closure check (`crystal tool dependencies` + `git diff`).
  - Adjusted after the follow-up measurements: expert 7 s (estimated); follow-ups measured probe and archive.
  - Score: 0 ÷ 3 = 0.00.
- **Effort M, risk medium.** A closure that misses a file read at macro time would skip a probe that should run and could let an edited migration ship; run the probes on any error computing the closure.
- **Verify after implementing.** After a docs-only `fix:` commit, `scripts/release --dry-run` runs no `crystal run probe.cr`; after editing `migrations.cr` it still refuses.
- **Overlaps.** E4-10. Savings that share seconds are not additive.

## Opportunities: application development

Ranked by weighted seconds ÷ effort points, where weighted seconds = 10 × `dev-save-22` + 3 × `frappe-command` + 1 × `corretto-22`: one hour of work on a 22-resource app (ten compiled saves, three one-shot compiling commands, one `frappe corretto`). `-2` figures stand in only where no `-22` figure exists. Ties go to lower risk, then lower effort.

| Rank | Opportunity | Weighted seconds | Effort | Risk | Evidence |
|---|---|---|---|---|---|
| 1 | E1-5: Start the compiler with a larger GC heap (`GC_INITIAL_HEAP_SIZE`) in `scripts/crystal` | 10.50 s (dev-save-22 0.84, frappe-command 0.42, corretto-22 0.84; estimated) | S | medium | fq-Com-7 1.046 s vs 1.43–1.55 s default (m2a, fq-Com-7); 13 collections |
| 2 | E3-8: Tell developers to exempt their terminal from macOS first-launch scans of freshly linked binaries (doctor/dev hint + docs) | 8.49 s (dev-save-22 0.566, frappe-command 0.566, corretto-22 1.13; estimated) | S | medium | fq-App-3 0.575 vs 0.009 s |
| 3 | E3-1: Fold the Tier-1 type check into the dev build and report it from the build's stage marker | 14.30 s (dev-save-22 1.43; measured) | M | medium | `dev_session.cr:182,196,229`; m2a-2 1.43 s |
| 4 | E3-2: Give `Tools#compile` the dev fingerprint cache and build with the dev flags into the dev slot | 14.22 s (dev-save-22 0.13, frappe-command 3.23, corretto-22 3.23; estimated/measured; upper bound) | M | medium | `tools.cr:41-46`; m2b-1 3.27 s; fq-App-2-fixed 40 ms |
| 5 | E3-6: Keep Corretto's spec binaries behind a fingerprint and skip the spec compile on unchanged reruns | 3.60 s (corretto-22 3.60; measured; upper bound) | S | low | `corretto_runner.cr:165-168`; fq-App-4-2 3.64 s |
| 6 | E3-7: Trim the fixed waits in the dev loop (debounce, dev_child post-exit sleep, 50 ms polls) | 3.20 s (dev-save-22 0.32; estimated) | S | low | `dev_session.cr:121,232-234`; fq-App-0 |
| 7 | E3-3: `frappe db diff` applies the derived migration to the scratch branch in-process, skipping its second compile | 8.91 s (frappe-command 2.97; estimated; upper bound) | M | medium | `schema_diff.cr:31,58`; m2b-2 2.97 s |
| 8 | E1-3: Build `Tools#compile` with `-D caramel_development` so one cache dir stops alternating object sets | 2.50 s (dev-save-22 0.13, frappe-command 0.3, corretto-22 0.3; estimated/measured) | S | low | `tools.cr:44`, `application.cr:9-11`; m2b-1/-3 |
| 9 | E3-5: Compile each Corretto worker from a stable generated entry file | 1.53 s (corretto-22 1.53; measured; upper bound) | S | low | `corretto_runner.cr:160`; fq-App-4 5.17 vs 3.64 s |
| 10 | E1-4: `scripts/crystal` fast path: fewer processes per compiler call | 1.25 s (dev-save-22 0.1, frappe-command 0.05, corretto-22 0.1; estimated) | S | low | m2h 0.080 s/call; fq-Com-6 0.032 s/call |
| 11 | E2-4: SugarORM write path: capture `Changeset#write`'s block and make `Repo.connection`/`using` single-yield | 1.15 s (dev-save-22 0.08, frappe-command 0.07, corretto-22 0.14; estimated) | S | medium | `changeset.cr:260-266`, `repo.cr:102-108`; fq-Fra-11 |
| 12 | E3-4: Corretto starts the spec-binary compile at once, alongside the app compile, migrate and clone | 3.27 s (corretto-22 3.27; estimated) | M | medium | `corretto_runner.cr:69-73,160`; m2b-1 3.27 s |
| 13 | E2-2: Leaner per-action egress: move type-independent bodies of `respond`/`json`/`page`/… into once-typed helpers | 3.00 s (dev-save-22 0.215, frappe-command 0.17, corretto-22 0.34; estimated) | M | low | `action.cr:132-135`, `router.cr:381`; fq-Fra-8/9 |
| 14 | E2-3: Flatten Blueprint block elements to one typed copy per call site | 1.35 s (dev-save-22 0.1, frappe-command 0.07, corretto-22 0.14; estimated) | M | medium | `element_registrar.cr:4-19`; fq-Fra-1 views 0.21 s ceiling |
| 15 | E2-1: Gate the routes/schema/migrate/lint/drift branches of `CommandLine` out of dev builds | 0.40 s (dev-save-22 0.04; estimated) | S | medium | `command_line.cr:37-48`; fq-Fra-6 −0.042 s |

### 1. E1-5: Start the compiler with a larger GC heap (`GC_INITIAL_HEAP_SIZE`) in `scripts/crystal`

- **Mechanism.** The compiler's Boehm GC starts small and grows. The default type check of the 22-resource app ran 13 full collections and 48 heap growths (`GC_PRINT_STATS`, fq-Com-7). The same pass with `GC_INITIAL_HEAP_SIZE=2G` took `Semantic (main)` 0.473 s and 1.046 s wall, against 0.741–0.821 s and 1.43–1.554 s with the default heap (m2a-1/2, fq-Com-7). Change: export a GC initial heap size with the other compiler environment in `scripts/crystal` (`scripts/crystal:83-89`), after measuring 1 GB against 2 GB and the peak memory. The CompilerToolchainExpert had rejected GC tuning as "at most ≈0.1 s per compile" before its own follow-up measured this.
- **Evidence.** fq-Com-7: runs with `GC_PRINT_STATS`, plain and 2 GB, stage sums 1.388 / 1.439 / 0.935 s; `followup-gc-sem.err`: 13 collections. The debug and no-debug full-build GC logs show 15 and 22 collections (fq-Com-1, fq-Com-0).
- **Savings.**
  - `dev-save-22`: **0.84 s** (estimated). One type-check pass with a 2 GB heap: stage sum 0.935 s, wall 1.046 s (fq-Com-7 run 3). Default heap, same command and cache: stage sums 1.275–1.439 s, wall 1.43–1.554 s (m2a-1/2, fq-Com-7 runs 1–2). The saving per pass is 0.34 s (stage sum vs m2a-2) to 0.51 s (wall vs the back-to-back plain run), midpoint 0.42 s. A dev save runs two passes (check + build): 2 × 0.42 = 0.84 s (range 0.68–1.02 s). The build's own pass and any codegen effect are not measured.
  - `frappe-command`: **0.42 s** (estimated). 1 pass × 0.42 s (range 0.34–0.51 s)
  - `corretto-22`: **0.84 s** (estimated). 2 compiles (migrate + spec binary) × 0.42 s
  - Adjusted after the follow-up measurements: E1 rejected this (H11, 'at most ≈0.1 s per compile'); its own follow-up fq-Com-7 measured 0.34–0.51 s per pass.
  - Weighted hour: 10 × dev-save + 3 × frappe-command + 1 × corretto = **10.50 s** (range 8.50–12.75 s; at the low end it ties E3-8); score 10.50 ÷ 1 = 10.50.
- **Effort S, risk medium.** One observation of a type check only, and the saving depends on which default-heap run is the baseline (0.34–0.51 s). The full-build effect and the peak memory are not measured, and a 2 GB initial heap per compiler matters when compiles run side by side (Corretto workers, E4-7, E4-9). An exported variable is also inherited by what the compiler runs: `crystal run` and `crystal spec` binaries (compiler `command.cr:319`, default environment) and macro-run helpers. Either set it only for `build`, or include the unit spec run and the release probes in the memory check.
- **Verify after implementing.** In the 22-resource app, `GC_INITIAL_HEAP_SIZE=2G scripts/crystal build src/bookshelf.cr -D caramel_development --stats` twice (compare fq-Fra-0-2, 3.30 s) under `/usr/bin/time -l` for peak RSS; then the edit benchmark (Crystal median 5792 ms).
- **Overlaps.** E3-1 (one type check per save instead of two halves this saving); E2-2, E2-3, E2-4 (smaller passes); E3-2 (a hit removes the command and Corretto-migrate compiles); E1-4 and E1-1 (same file, `scripts/crystal`). Savings that share seconds are not additive.

### 2. E3-8: Tell developers to exempt their terminal from macOS first-launch scans of freshly linked binaries (doctor/dev hint + docs)

- **Mechanism.** The first run of a freshly linked binary took 0.575 s; the next two took 0.0098 s and 0.0085 s (fq-App-3). Every dev save launches a new binary (`src/frappe/dev_session.cr:252`), every compiling command a new `.caramel/application` (`src/frappe/tools.cr:41-46`), and Corretto two. [INFERENCE] The delay is macOS's first-launch assessment (syspolicyd/XProtect). Adding the terminal under Privacy & Security → Developer Tools exempts its child processes, as the [nextest documentation](https://nexte.st/docs/installation/macos/) describes. Change: `frappe doctor` and `frappe dev` detect a slow first launch and print a one-time hint, plus a docs note. Frappé must not change the setting itself.
- **Evidence.** fq-App-3; `src/frappe/dev_session.cr:252`; `src/frappe/tools.cr:41-46`; the save anatomy above (1456 ms outside the compiler).
- **Savings.**
  - `dev-save-22`: **0.566 s** (estimated). First exec of a freshly linked app binary 0.575 s vs 0.0098/0.0085 s on repeats → 0.566 s (fq-App-3). One new binary per save. Attribution to syspolicyd/XProtect and the exemption's effect are not measured.
  - `dev-save-2`: **0.566 s** (estimated). Same per-binary penalty
  - `frappe-command`: **0.566 s** (estimated). 1 new binary per compiling command
  - `corretto-22`: **1.13 s** (estimated). 2 new binaries (migrate app, spec binary) × 0.566 s
  - `corretto-2`: **1.13 s** (estimated). 2 × 0.566 s
  - Adjusted after the follow-up measurements: expert 0.2 s per binary (published threshold); follow-up fq-App-3 measured 0.566 s.
  - Weighted hour: 10 × dev-save + 3 × frappe-command + 1 × corretto = **8.49 s**; score 8.49 ÷ 1 = 8.49.
- **Effort S, risk medium.** The exemption lowers malware scanning for everything the terminal runs, so it must stay the developer's informed choice. The benefit is zero on machines already exempt, and the exemption's effect was not measured here.
- **Verify after implementing.** Re-run fq-App-3 on a freshly linked binary after enabling Developer Tools for the terminal: the first run should match the repeats. Then the edit benchmark.
- **Overlaps.** E3-7 (both sit in the 1.46 s outside the compiler); E3-2 (a fingerprint hit launches no new binary); E3-6 (a kept spec binary needs no first launch); E3-1 (same file, `src/frappe/dev_session.cr`); E4-2 (fewer new binaries in the suite). The suite also launches dozens of freshly linked binaries per run; how many was not sampled. Savings that share seconds are not additive.

### 3. E3-1: Fold the Tier-1 type check into the dev build and report it from the build's stage marker

- **Mechanism.** Every compiled save runs `--no-codegen` and then a full build with the same flags (`src/frappe/dev_session.cr:182`, `:196`, `:229`). On a type error `build` stops at the same point, so the separate check only repeats the type check when the code is valid. Change: one `build … --stats -o <tmp>` per save. Print `Type check passed in N ms` when the last semantic stage line arrives, filter the stats lines out of error pages, and keep ADR 0012's messages.
- **Evidence.** `src/frappe/dev_session.cr:182`, `:196`, `:229`; m2a-2 1.43 s, m2f-2 1.03 s; benchmark Crystal medians 5792 / 4868 ms.
- **Savings.**
  - `dev-save-22`: **1.43 s** (measured). The removed invocation is m2a-2 = 1.43 s (same app, same flags). 5792 − 1430 ≈ 4362 ms projected median.
  - `dev-save-2`: **1.03 s** (measured). m2f-2 = 1.03 s. 4868 − 1030 ≈ 3838 ms projected median.
  - Weighted hour: 10 × dev-save + 3 × frappe-command + 1 × corretto = **14.30 s**; score 14.30 ÷ 3 = 4.77.
- **Effort M, risk medium.** It relies on the `--stats` line order and flushing of Crystal 1.21. ADR 0012's wording and the Tier-1 assertions in `scripts/checks/frappe_project/dev.cr` change in the same commit.
- **Verify after implementing.** `scripts/check frappe-project --edit-benchmark`: Crystal median ≈4.4 s (22) and ≈3.8 s (2); `scripts/check frappe-project --dev` still passes its type-error assertions.
- **Overlaps.** E1-5 (halves its saving); E3-7 and E1-4 (one relaunch and one wrapper call fewer); E2-2, E2-3, E2-4, E2-1 (a smaller pass shrinks this saving); E3-2 and E3-8 (same file, `src/frappe/dev_session.cr`). Savings that share seconds are not additive.

### 4. E3-2: Give `Tools#compile` the dev fingerprint cache and build with the dev flags into the dev slot

- **Mechanism.** `Tools#compile` always runs a full build without `-D` (`src/frappe/tools.cr:41-46`) for routes, migrate, seed, `db diff` and Corretto's migrate. Change: share the dev loop's `cached?` and `write_metadata` (`src/frappe/dev_session.cr:336-348`, `:209`). On a fingerprint hit, run the dev binary (hard-linked first, so dev cleanup cannot delete it). On a miss, build with the dev flags into the dev slot.
- **Evidence.** `src/frappe/tools.cr:41-46`; `src/frappe/dev_session.cr:209`, `:336-348`; m2b-1 3.27 s; fingerprint check 29.8 ms snapshot + 10.3 ms artifact SHA-256 (fq-App-2-fixed); first vs cached dev readiness 5509 / 275 ms.
- **Savings.**
  - `dev-save-22`: **0.13 s** (estimated). The next dev save after a no-D build pays 0.33 s (m2b-3 3.47 − 3.14); 4 non-dev compiles per 10 saves → 0.13 s per save
  - `frappe-command`: **3.23 s** (measured). Hit case (dev already built the current sources): the whole compile goes, m2b-1 = 3.27 s, minus the fingerprint check: DevFiles snapshot 29.8 ms + binary/.dwarf SHA-256 10.3 ms (fq-App-2-fixed) → 3.23 s. Miss case: 0.30 s (no flag alternation).
  - `corretto-22`: **3.23 s** (measured). Corretto's migrate compile (corretto_runner.cr:69) after dev builds, same hit arithmetic
  - `corretto-2`: **2.93 s** (measured). fq-App-5 2.97 s − 0.04 s
  - Adjusted after the follow-up measurements: expert 3.27 (estimated); fingerprint cost now measured.
  - Weighted hour: 10 × dev-save + 3 × frappe-command + 1 × corretto = **14.22 s**; score 14.22 ÷ 3 = 4.74.
- **Effort M, risk medium.** A reused binary is only as correct as the fingerprint (macros that read env or files are not hashed). Concurrency with a running dev session needs care, and commands then run a binary built with the development define (the error page stays gated by `CARAMEL_ENV`).
- **Verify after implementing.** With `frappe dev` running and built, time `bin/frappe routes`: it drops from ≈3.3 s of compile to the run alone. The benchmark's `spec_command_ms` drops ≈3 s.
- **Overlaps.** E1-3 (included); E3-3, E3-4, E3-6 (the same compiles); E2-1 (conflicts: dev binaries must keep every command). On a hit it also removes the `frappe-command` and Corretto-migrate parts of E1-5, E1-4, E2-2, E2-3 and E2-4, and E3-8's first launch of that binary. E3-1 and E3-7 change the same file (`src/frappe/dev_session.cr`). Savings that share seconds are not additive.

### 5. E3-6: Keep Corretto's spec binaries behind a fingerprint and skip the spec compile on unchanged reruns

- **Mechanism.** Corretto deletes each worker binary and its `.dwarf` after the run (`src/frappe/corretto_runner.cr:165-168`), so a rerun with no change recompiles. Change: keep the binaries under `.caramel/corretto/` with a fingerprint (source signature, hash of `spec/**`, file list, toolchain, version) and skip the compile when it matches.
- **Evidence.** `src/frappe/corretto_runner.cr:165-168`; fq-App-4-2 warm spec compile 3.64 s.
- **Savings.**
  - `corretto-22`: **3.60 s** (measured). Warm unchanged spec-binary compile 3.64 s (fq-App-4-2) − 0.04 s fingerprint = 3.60 s; only for reruns with no app or spec change.
  - Adjusted after the follow-up measurements: expert 3.14 s stand-in; follow-up fq-App-4 measured the spec compile.
  - Weighted hour: 10 × dev-save + 3 × frappe-command + 1 × corretto = **3.60 s**; score 3.60 ÷ 1 = 3.60.
- **Effort S, risk low.** A compile input outside the hashed trees would reuse a stale binary; ≈20 MB kept per worker (the 22-resource dev binary plus `.dwarf` is 20.4 MB).
- **Verify after implementing.** Two `bin/frappe corretto` runs with no change: the second prints no compiler output and runs ≈3.6 s faster.
- **Overlaps.** E3-2, E3-4, E3-5 (E3-4 and E3-5 also change `src/frappe/corretto_runner.cr`); E3-8 (a kept spec binary needs no first launch, removing half of E3-8's Corretto figure). Savings that share seconds are not additive.

### 6. E3-7: Trim the fixed waits in the dev loop (debounce, dev_child post-exit sleep, 50 ms polls)

- **Mechanism.** Per compiled save the loop waits a 200 ms debounce (`src/frappe/dev_session.cr:121`), sleeps 50 ms after each compiler exit in the dev child (`src/frappe/dev_child.cr:32-34`, twice per save), and polls compile completion and `/health` every 50 ms (`src/frappe/dev_session.cr:232-234`, `:283`). Change: a ≈50 ms debounce with a precise deadline, no post-exit sleep on a normal exit, waiting on the status fiber instead of polling, and `/health` polled every 10 ms.
- **Evidence.** `src/frappe/dev_session.cr:121`, `:232-234`, `:283`; `src/frappe/dev_child.cr:32-34`; fq-App-0: 0.062 s per dev-child relaunch, including its 50 ms sleep.
- **Savings.**
  - `dev-save-22`: **0.32 s** (estimated). Debounce 200 → 50 ms 0.15 s + 2 × 50 ms child sleep 0.10 s + 2 × 25 ms completion polling 0.05 s + health poll 0.02 s = 0.32 s. fq-App-0 measured the dev_child relaunch at 0.062 s including its 50 ms sleep.
  - `dev-save-2`: **0.32 s** (estimated). Same fixed waits
  - Weighted hour: 10 × dev-save + 3 × frappe-command + 1 × corretto = **3.20 s**; score 3.20 ÷ 1 = 3.20.
- **Effort S, risk low.** A shorter debounce starts builds that multi-step saves then cancel (CPU only). The TERM/KILL path for abnormal exits stays.
- **Verify after implementing.** Edit benchmark: Crystal and view medians ≈0.3 s lower, CSS/JS unchanged; the `--dev` burst-edit assertions pass.
- **Overlaps.** E3-1 (one relaunch fewer, ≈0.25 s left); E3-8; E3-2 (same file, `src/frappe/dev_session.cr`). Savings that share seconds are not additive.

### 7. E3-3: `frappe db diff` applies the derived migration to the scratch branch in-process, skipping its second compile

- **Mechanism.** `frappe db diff` compiles the app (`src/frappe/schema_diff.cr:31`), writes the migration, then compiles the whole app again only to run it on the scratch branch (`src/frappe/schema_diff.cr:58`). Change: apply the derived statements to the branch from Frappé, which already holds them. The user's `frappe migrate` compiles the new file next anyway.
- **Evidence.** `src/frappe/schema_diff.cr:31`, `:58`; m2b-2 2.97 s.
- **Savings.**
  - `frappe-command`: **2.97 s** (estimated). One warm no-D compile, m2b-2 = 2.97 s, removed per `db diff` that writes a migration (0 s for diffs that derive nothing).
  - Weighted hour: 10 × dev-save + 3 × frappe-command + 1 × corretto = **8.91 s**; score 8.91 ÷ 3 = 2.97.
- **Effort M, risk medium.** The branch run no longer proves that the rendered file compiles and carries the same statements; a rendering bug would surface at `frappe migrate`. A render-and-reparse unit test mitigates it.
- **Verify after implementing.** `bin/frappe db diff --name probe` after a model change runs ≈3 s faster; `scripts/check schema-diff` still passes.
- **Overlaps.** E3-2 (with both, diff + migrate needs one compile). The weighted figure assumes every command is a migration-writing diff, so it is an upper bound. Savings that share seconds are not additive.

### 8. E1-3: Build `Tools#compile` with `-D caramel_development` so one cache dir stops alternating object sets

- **Mechanism.** `Tools#compile` builds without the define (`src/frappe/tools.cr:44`) into the same cache dir as dev builds (`src/frappe/dev_session.cr:229`). The define adds `development_error` (`src/caramel/application.cr:9-11`), which shifts type IDs, so about 174 modules recompile at each switch. Change: pass `-D caramel_development` in `Tools#compile`; the error page stays gated by `CARAMEL_ENV == "development"` at runtime (`src/caramel/application.cr:60-61`).
- **Evidence.** m2b-1 3.27 s (1645/1819 reused) vs m2b-2 2.97 s; m2b-3 3.47 s (1649/1823) vs 3.14 s; `src/caramel/application.cr:9-11`, `:60-61`.
- **Savings.**
  - `dev-save-22`: **0.13 s** (estimated). m2b-3 3.47 − 3.14 = 0.33 s on the next save, × 4 non-dev compiles per 10 saves (3 commands + Corretto's migrate) = 0.13 s
  - `frappe-command`: **0.3 s** (measured). m2b-1 3.27 − m2b-2 2.97 = 0.30 s for the first Tools#compile after dev builds
  - `corretto-22`: **0.3 s** (estimated). Corretto's migrate compile pays the same 0.30 s
  - Weighted hour: 10 × dev-save + 3 × frappe-command + 1 × corretto = **2.50 s**; score 2.50 ÷ 1 = 2.50.
- **Effort S, risk low.** Command binaries carry the inert development-error code; none of these commands serves HTTP.
- **Verify after implementing.** After a dev save, `frappe routes` with `--stats` reports full reuse, and the next save matches `22/view_edit` (2.92 s), not m2b-3 (3.47 s).
- **Overlaps.** E3-2 (includes this change). Savings that share seconds are not additive.

### 9. E3-5: Compile each Corretto worker from a stable generated entry file

- **Mechanism.** Corretto compiles `build <group files…>` (`src/frappe/corretto_runner.cr:160`), and Crystal names the cache dir after the first file (`codegen/cache_dir.cr:24-26`), so a subset run or a new first-sorting spec starts cold. Change: generate `.caramel/corretto/w<N>.cr`, which requires the group's files in order, and compile that.
- **Evidence.** `src/frappe/corretto_runner.cr:160`; `codegen/cache_dir.cr:24-26`; fq-App-4: spec binary 5.17 s cold vs 3.64 s warm.
- **Savings.**
  - `corretto-22`: **1.53 s** (measured). Spec binary cold 5.17 s − warm 3.64 s = 1.53 s (fq-App-4), for runs whose first spec file changed (subsets, a new first-sorting spec); 0 s for repeated full runs.
  - Adjusted after the follow-up measurements: expert 1.54 s (app-build stand-in); follow-up fq-App-4 measured the spec binary.
  - Weighted hour: 10 × dev-save + 3 × frappe-command + 1 × corretto = **1.53 s**; score 1.53 ÷ 1 = 1.53.
- **Effort S, risk low.** Same files in the same order, so spec order is unchanged.
- **Verify after implementing.** `bin/frappe corretto spec/requests/home_spec.cr`, then `…/books_spec.cr`: the second reports object reuse and no new `…books_spec.cr` cache entry appears.
- **Overlaps.** E3-6 and E3-4 (same file, `src/frappe/corretto_runner.cr`). Savings that share seconds are not additive.

### 10. E1-4: `scripts/crystal` fast path: fewer processes per compiler call

Same change as suite rank 7; mechanism, evidence, risk and verification are there.

- **Savings in this family.**
  - `dev-save-22`: **0.1 s** (estimated). 2 calls (check + build) × 0.05 s
  - `dev-save-2`: **0.1 s** (estimated). 2 calls × 0.05 s
  - `frappe-command`: **0.05 s** (estimated). 1 call × 0.05 s
  - `corretto-22`: **0.1 s** (estimated). 2 calls (migrate compile + 1 worker) × 0.05 s
  - Weighted hour: **1.25 s**; score 1.25 ÷ 1 = 1.25.
- **Overlaps.** E3-1 (one wrapper call fewer per save); E4-2 and E4-6 (fewer calls in the suite); E3-2 (a hit removes the command's call); E1-1 and E1-5 (same file, `scripts/crystal`). Savings that share seconds are not additive.

### 11. E2-4: SugarORM write path: capture `Changeset#write`'s block and make `Repo.connection`/`using` single-yield

- **Mechanism.** `Changeset#write` yields in three places, one inside `Repo.transaction`, whose yields sit inside `Repo.connection` with two more (`src/sugar_orm/changeset.cr:260-266`, `src/sugar_orm/repo.cr:102-108`). Code generation inlines the block at every yield, about 10 query paths per insert and update per changeset. Change: capture `write`'s block and call it, and make `connection`/`using` single-yield.
- **Evidence.** `src/sugar_orm/changeset.cr:260-266`; `src/sugar_orm/repo.cr:102-108`; patched copy vs baseline, warm build: `Semantic (main)` −0.008 s, `Codegen (crystal)` −0.062 s (fq-Fra-11-2 vs fq-Fra-0-2). Identical warm builds varied 0.967–1.298 s in `Codegen (crystal)` (profile rows, fq-Com-1, fq-Fra-0-1/-2), so this difference is within run-to-run noise.
- **Savings.**
  - `dev-save-22`: **0.08 s** (estimated, within run-to-run noise). Patched copy, warm build: Semantic (main) −0.008 s, Codegen (crystal) −0.062 s (fq-Fra-11-2 vs fq-Fra-0-2) → 2 × 0.008 + 0.062 = 0.078 s per save
  - `dev-save-2`: **0.005 s** (estimated). Expert estimate for 2 changesets
  - `frappe-command`: **0.07 s** (estimated). 0.008 + 0.062 = 0.07 s per build
  - `corretto-22`: **0.14 s** (estimated). 2 builds × 0.07 s (the app-build delta applied to the spec binary)
  - Adjusted after the follow-up measurements: expert 0.05 s (estimated); follow-up fq-Fra-11 measured the patched copy.
  - Weighted hour: 10 × dev-save + 3 × frappe-command + 1 × corretto = **1.15 s**; score 1.15 ÷ 1 = 1.15.
- **Effort S, risk medium.** It touches connection checkout and release and the savepoint path of every write.
- **Verify after implementing.** `scripts/check compiler-profile`: `22/controller_edit` `Codegen (crystal)` ≈0.06 s lower; `scripts/crystal spec spec/sugar_orm` passes.
- **Overlaps.** E2-2, E2-3, E1-5; E3-1 (removes one of the two type checks this counts); E3-2 (a fingerprint hit removes the command and Corretto compiles). Savings that share seconds are not additive.

### 12. E3-4: Corretto starts the spec-binary compile at once, alongside the app compile, migrate and clone

- **Mechanism.** Corretto runs app compile → template migrate → clone → spec compile → run in sequence (`src/frappe/corretto_runner.cr:69-73`, `:160`). The spec compile needs no database. Change: start it at once. The app build and the spec build use different cache dirs.
- **Evidence.** `src/frappe/corretto_runner.cr:69-73`, `:160`; m2b-1 3.27 s; fq-App-4 3.64–5.17 s.
- **Savings.**
  - `corretto-22`: **3.27 s** (estimated). Hides min(A, S): A = app compile 3.27 s (m2b-1) + migrate + clone (unmeasured), S = spec compile 3.64–5.17 s (fq-App-4) ≥ A → saving ≈ A ≥ 3.27 s.
  - `corretto-2`: **2.97 s** (estimated). A ≥ fq-App-5 2.97 s
  - Weighted hour: 10 × dev-save + 3 × frappe-command + 1 × corretto = **3.27 s**; score 3.27 ÷ 3 = 1.09.
- **Effort M, risk medium.** It doubles peak memory, and cancellation and error reporting need care. The LRU race needs the spec dir touched first (E1-1 does not cover app programs).
- **Verify after implementing.** The benchmark's `spec_command_ms` drops from 10632 to ≈7.4 s (22).
- **Overlaps.** E3-2 (a hit removes the app compile, leaving only migrate and clone to hide); E3-6 and E3-5 (same file, `src/frappe/corretto_runner.cr`). Savings that share seconds are not additive.

### 13. E2-2: Leaner per-action egress: move type-independent bodies of `respond`/`json`/`page`/… into once-typed helpers

- **Mechanism.** Each of the 154 action structs re-types `Caramel::Action`'s egress methods (`respond`, `json`, `page`, `render_contract_failure`, `contract_failure_page`, `html_headers`; `src/caramel/action.cr:132-135` and neighbours), which every route method calls (`src/caramel/http/router.cr:381`). Change: keep one-line forwarders and move the type-independent bodies into class methods typed once.
- **Evidence.** `src/caramel/action.cr:132-135`; `src/caramel/http/router.cr:381`; upper bound with all egress removed: `Semantic (main)` −0.038 s, `Codegen (crystal)` −0.139 s (fq-Fra-8, fq-Fra-9-2 vs fq-Fra-0-2); the baseline's `Codegen (crystal)` varied 0.967–1.298 s across identical builds.
- **Savings.**
  - `dev-save-22`: **0.215 s** (estimated). Expert estimate 0.25 s, capped at the measured upper bound for removing all egress: 2 × 0.038 (Semantic (main)) + 0.139 (Codegen (crystal)) = 0.215 s (fq-Fra-9-2 and fq-Fra-8 vs fq-Fra-0-2)
  - `dev-save-2`: **0.02 s** (estimated). Expert estimate
  - `frappe-command`: **0.17 s** (estimated). Expert estimate, below the measured bound 0.038 + 0.139 = 0.177 s
  - `corretto-22`: **0.34 s** (estimated). 2 builds × 0.17 s
  - Adjusted after the follow-up measurements: expert 0.25 s capped by follow-up fq-Fra-8/9 upper bound.
  - Weighted hour: 10 × dev-save + 3 × frappe-command + 1 × corretto = **3.00 s**; score 3.00 ÷ 3 = 1.00.
- **Effort M, risk low.** A behaviour-preserving refactor behind the same public methods; overrides of `layout`, `title_for` and `contract_failure_page` keep working.
- **Verify after implementing.** `scripts/check compiler-profile` (`22/controller_edit`: `Semantic (main)` 0.703 s, `Codegen (crystal)` 0.967 s) and the edit benchmark.
- **Overlaps.** E2-3, E2-4, E3-1; E1-5 (a faster pass shrinks both); E3-2 (a hit removes the command compile). Savings that share seconds are not additive.

### 14. E2-3: Flatten Blueprint block elements to one typed copy per call site

- **Mechanism.** An element call with a block goes through three yielding methods (`lib/blueprint/src/blueprint/html/element_registrar.cr:4-19`, `lib/blueprint/src/blueprint/html/buffer_renderer.cr:19-25`), and Crystal never caches a block call's typed copy (compiler `semantic/call.cr:376-383`), so each call site types three copies. Change: redefine `register_element` in Caramel so the `(**attributes, &)` overload writes the tag directly.
- **Evidence.** `element_registrar.cr:4-19`; `buffer_renderer.cr:19-25`; `semantic/call.cr:376-383`; every view body together costs `Semantic (main)` 0.068 s + `Codegen (crystal)` 0.074 s per warm build (fq-Fra-1-2 vs fq-Fra-0-2) and 12.35 s of the 84.85 s release build (fq-Fra-14/15); the warm-build ceiling uses the same fq-Fra-0-2 baseline, whose `Codegen (crystal)` varied 0.967–1.298 s across identical builds.
- **Savings.**
  - `dev-save-22`: **0.1 s** (estimated). Expert estimate; the measured ceiling for removing every view body is 2 × 0.068 + 0.074 = 0.21 s per save (fq-Fra-1-2 vs fq-Fra-0-2)
  - `dev-save-2`: **0.01 s** (estimated). Expert estimate
  - `frappe-command`: **0.07 s** (estimated). Expert estimate
  - `corretto-22`: **0.14 s** (estimated). 2 builds × 0.07 s
  - Weighted hour: 10 × dev-save + 3 × frappe-command + 1 × corretto = **1.35 s**; score 1.35 ÷ 3 = 0.45.
- **Effort M, risk medium.** It must reproduce Blueprint's content rule and escaping, and it couples Caramel to Blueprint 1.1.0 internals.
- **Verify after implementing.** View specs plus a rendered-HTML diff of the generated app; the views' share of a type check (0.079 s) roughly halves.
- **Overlaps.** E2-2, E3-1; E1-5 (a faster pass shrinks both); E3-2 (a hit removes the command compile). Savings that share seconds are not additive.

### 15. E2-1: Gate the routes/schema/migrate/lint/drift branches of `CommandLine` out of dev builds

- **Mechanism.** `CommandLine.run` dispatches on a runtime string (`src/caramel/command_line.cr:37-48`), so the routes, schema, migrate, lint and drift branches are typed in every build, while dev binaries only run `serve` (`src/frappe/dev_session.cr:252`). Change: wrap those branches in `{% unless flag?(:caramel_development) %}`.
- **Evidence.** `src/caramel/command_line.cr:37-48`; serve-only vs `Caramel.run` in the same copy: `Codegen (crystal)` 0.488 → 0.446 s (fq-Fra-6-2 vs fq-Fra-2-2); type check alone no faster (fq-Fra-5: `Semantic (main)` 0.377–0.397 vs m2e 0.370–0.371).
- **Savings.**
  - `dev-save-22`: **0.04 s** (estimated, within run-to-run noise). Serve-only vs Caramel.run in the same no-routes copy: Codegen (crystal) 0.488 → 0.446 s = −0.042 s (fq-Fra-6-2 vs fq-Fra-2-2); semantic-only shows no saving (fq-Fra-5 S(main) 0.377–0.397 vs m2e 0.370–0.371) → ≈0.04 s per save
  - `dev-save-2`: **0.04 s** (estimated). The 22-resource figure; the same framework code is reachable
  - Adjusted after the follow-up measurements: expert 0.12 s (estimated); follow-ups fq-Fra-4/5/6 measured ≈0.04 s.
  - Weighted hour: 10 × dev-save + 3 × frappe-command + 1 × corretto = **0.40 s**; score 0.40 ÷ 1 = 0.40.
- **Effort S, risk medium.** Dev binaries lose those commands (conflicts with E3-2), and `frappe check` stops checking the migration paths.
- **Verify after implementing.** `scripts/check compiler-profile`: `Codegen (crystal)` ≈0.04 s lower.
- **Overlaps.** E3-2 (conflict); E2-2, E2-3. Savings that share seconds are not additive.

## Evaluated and rejected

| Idea | Reason |
|---|---|
| E1 H2: `--no-debug` for builds whose `.dwarf` nobody reads (Tools#compile, Corretto workers, check binaries, `bin/release`, release probes) | Measured slower. With every object reused, warm `--no-debug` bc+obj takes 0.81–0.94 s (m2c-2, fq-Com-0) against 0.16 s with debug info, and the 0.25 s `dsymutil` saving is lost. Cold it saves 0.04 s (codegen stages 1.054 + 1.520 + 0.222 + 0.247 = 3.043 s in profile 22/cold vs 0.786 + 2.045 + 0.175 = 3.006 s in m2c-1). The debug level is not in the cache key, so alternating with debug builds of the same entry recompiles every object (m2c-1 4.41 s). It also drops file:line from backtraces. |
| E1 H4: more codegen threads (`--threads`, `CRYSTAL_WORKERS`) | Codegen already uses 12 workers (`compiler.cr:100-101`). The parallel stage is 0.14 s of a 2.82 s warm build; 79% of it is single-threaded type checking and IR generation. |
| E1 H5: a faster linker or `-no_deduplicate` | Warm linking is 0.21 s (7%) and already uses ld-prime (`ld-1230.1`). `-no_deduplicate` measured 0.232 s warm (fq-Com-8): no gain. |
| E1 H7: move to a Crystal release after 1.21.0 for compile time | 1.21.1 (2026-09-26) and the 1.22.0 milestone have no compile-time changes ([1.21.1 release notes](https://crystal-lang.org/2026/09/26/1.21.1-released/), [Crystal milestones](https://github.com/crystal-lang/crystal/milestones); from the CompilerToolchainExpert's search). A new toolchain root restarts every cache cold. 1.21.1 is still worth taking for its macOS 26.7 socket fix. |
| E1 H8: remove or prebuild Ameba's `read_type_doc` helper | It costs 26.28 s only when evicted (fq-Com-4). E4-4 or E1-1 keep it off the suite's path without patching a pinned shard's private macro. |
| E1 H9 alternatives: prewarm the ECR helper at install, or keep macro-run outputs outside the LRU | Prewarming moves the 6.37 s instead of removing it. The second needs a compiler patch (macro-run dirs share the keep-10 root). |
| E1 H10: stop the 19 modules re-generated on the first warm build after a cold one | 0.21 s once per cache fill (bc+obj 0.355 vs 0.143 s). It comes from the in-process macro-run compile advancing a closure counter; E1-2 removes it for apps. |
| E1 H11: shrink the fixed `Semantic (top level)` and cvars stages in the toolchain | No toolchain lever; top level grows only ≈3 ms per resource (0.310 → 0.371 s from 2 to 22). |
| E1: faster `dsymutil` (parallel DWARF linker, no accelerator tables) | Measured 0.26–0.27 s against 0.27 s classic (fq-Com-2): no gain. |
| E1 H1 variant: a separate cache root for every program, including random `/private/tmp` apps | Each new root recompiles the ECR helper, +6.37 s per cold app build; E1-1 limits roots to checkout programs. |
| E2 H1: per-command binaries or entry points | Stages that do not depend on reachability are 58% of the type-check floor (0.519 of 0.889 s in m2e-2) and would be paid again per program, each in a new cache entry. |
| E2 H1: cut Cold Brew, the HTTP server or the migrator from `serve` | `serve` needs them; the ECR helper comes from the stdlib HTTP handlers, which `pg` also requires. |
| E2 H2: shrink the generated `__caramel_route_N` body | It is ≈6 statements (`router.cr:370-382`); its cost is what it reaches (E2-2). |
| E2 H3: make the generated form's `labelled` helper block-free | ≈0.012 s per 22-resource save (FrameworkCompileExpert estimate: ≈7% of the views' 0.079 s type-check share, twice per save), below run-to-run noise. |
| E2 H3: attribute the 22-resource release-build growth (56.94 → 82.46 s) to views | Now measured: views are 12.35 s of the 84.85 s release build (fq-Fra-14/15). App release builds are in no ranked workflow, and E2-3 targets the same code. |
| E2 H4: stop generating the unused `DefaultChangeset` | Macro expansion only, never typed; ≤0.005 s per compile (FrameworkCompileExpert estimate from ≈2.8 ms of top-level work per resource). |
| E2 H4: fewer `QueryOf`/`Loaded` instantiations | Generated apps call no `preload`, so there is nothing to remove. |
| E2 H4: single-yield `Repo.transaction` | Savepoint and rollback risk for little gain once E2-4 captures `write`'s block. |
| E2 H5: replace `Router.draw`'s O(R²) macro check | Measured noise: top level 0.371–0.387 s with 156 routes vs 0.353–0.381 s with 2 (m2a, m2e). |
| E2 H6: split the framework unit spec into programs compiled in parallel | Spec execution is 16.2 s of the 20.6–22.7 s run and compilation 3.8–5.8 s (fq-Fra-12); splits repeat the shared parse work. |
| E2 H6: build the unit spec with `--no-debug` | Same mechanism as E1 H2 (slower warm; loses backtrace lines). |
| E3 H1: drop the Tier-1 check outright | Dominated by E3-1, which saves the same 1.43 s and keeps ADR 0012's messages. |
| E3 H1: run the check and the build concurrently | Same wall saving as E3-1, with double CPU and a second compiler's peak memory per save. |
| E3 H1: folding the check loses diagnostics or `--error-trace` | Not a loss: the dev check already passes `--error-trace` (`dev_session.cr:229`) and shows raw compiler output. |
| E3 H4c: compile one spec binary and run it N times with file filters | 0 s at N = 1, the measured case; for N > 1 the compiles already run in parallel. |
| E3 H4b: clone worker databases in parallel | 0 s at N = 1; clone time was not measured (it needs the owner's Latte). |
| E3 H5: faster source fingerprint and artifact hashing | Measured small: snapshot 29.8 ms, binary + `.dwarf` SHA-256 10.3 ms (fq-App-2-fixed). |
| E3 H5: replace the `__caramel_dev_child` relaunch with a direct spawn | Measured 0.062 s per relaunch including the 50 ms sleep that E3-7 removes (fq-App-0). |
| E3 H6: treat the benchmark regressions as separate items | Explained: the 2-resource save regressed because the Tier-1 check added 1.03 s; E3-1 removes it. |
| E3: `--no-debug` for dev builds | Dev builds must produce `.dwarf` (`dev_session.cr:203-207`), and warm `--no-debug` is slower. |
| E3 H7: the hour-of-work weighting as an opportunity | Not a mechanism; it is the ranking rule. |
| E4 H2 variant: a staleness test in `scripts/check` | Within one suite each check binary compiles once (after E4-1). Across suites it needs dependency tracking, because `src/caramel/version.cr` reads `shard.yml` at compile time. |
| E4 H3: share one initialised Latte state across fixtures | Weakens the per-fixture CA isolation guard (`latte_fixture.cr:125-147`). |
| E4 H4: drop installations' cold rebuilds | They are what the check tests: a tagged release installed from a clean clone. |
| E4 H4: dedupe native's installer builds | The installations clone must build its own installers. |
| E4 H5: shorten `dev.cr:81`'s 3 s sleep | Load-bearing: the pending-migration retry assertion needs it. |
| E4 H5: drop `dev.cr:154`'s 0.5 s sleep | Load-bearing: it proves a CSS edit starts no Crystal build. |
| E4 H5: shorten the browser probe's 1.5 s job pause | Load-bearing: graceful stop must finish an in-flight job. |
| E4 H5: remove the integration and native spec sleeps (0.3 + 0.3 + 1.2 + 0.5 + 1.2 ≈ 3.5 s, SuiteReleaseExpert count) | Each proves time-based behaviour (TTL expiry, no duplicate run, timeouts, the menu's 2 s deadline). |
| E4 H6: stable project paths so app compiles reuse cache dirs | Once the ECR helper is cached, a cold full-size (22-resource) app compile costs only ≈1.3–1.6 s more than a warm one (fq-Fra-9 4.44 − 3.10 = 1.34 s, fq-Fra-11 1.51 s, fq-App-4 1.53 s, fq-Fra-1 1.61 s); the upper bound, ≈11 cold-path compiles × 1.3 s ≈ 14 s (SuiteReleaseExpert estimate), needs cache capacity too (E1-1). |
| E4 H7: one compiler process for all 31 compile-only cases | 27 of the 31 cases must each fail with their own diagnostic (4 are valid fixtures). |
| E4 H7: merge the valid fixtures (route `compile_valid`; orm `compile_valid` and `compile_rfc_examples`; cold-brew `rfc_snippets`) | 2–3 type-check passes, ≈0.8–1.2 s at the SuiteReleaseExpert's 0.39 s per case (from m5-route-compilation), at the cost of coupling unrelated fixtures. |
| E4 H9: skip rebuilding `bin/release` when fresh | ≤1.30 s including git (m4-release-dry-2). |
| E4 H9: skip the full suite in releases or allow `--except` | Forbidden by ADR 0016 §6 (`docs/decisions/0016-versioning-and-releases.md:47`). |
| E4 H10: ship prebuilt binaries | ADR 0016 §7 keeps releases source-only until signing and a relocatable OpenSSL exist. |
| E4 H10: build installers or the linter lazily | Moves the cost: `frappe doctor` builds the installers, and the linter is part of a complete install. |
| E4 H10: seed a new release's cache dirs from the previous release's | Measured 86% object reuse (1196/1396, fq-Sui-10), but with the ECR helper warm that saves only ≈1.1 s per artifact (3.95 → 2.89 s). |
| E4: reorder `check all` to keep cache entries warm | E4-3 and E4-4 remove those builds instead of warming them. |

## Method

All measurements ran one at a time from a Python harness on the machine above, with the owner's Latte running. Each row records wall time (monotonic clock) and child CPU time, and whether another `embedded/bin/crystal` process existed when the row started; none did. `CARAMEL_TOOLCHAIN_ROOT` was unset, so `scripts/crystal` used the checkout's toolchain, except where a row names a private prefix. Raw outputs were written under `/private/tmp/caramel-perf` and are archived outside the repository, on the measuring machine, at `~/Documents/Caramel/performance-runs/2026-09-28-v0.4.0-5dcf865/` (with a SHA-256 manifest). They are not committed.

Commands (Step 2):

- **M1**: `scripts/check compiler-profile`. It generates the 2- and 22-resource Bookshelf apps, each with a private toolchain prefix and an empty `crystal-cache`, and runs four builds per app with `--stats` (cold, unchanged, view edit, controller edit).
- **M2**: `scripts/crystal build src/bookshelf.cr` in the 22-resource app with its private prefix: `--no-codegen -D caramel_development --stats` (m2a ×2); `--stats --error-trace -o …` without `-D` (m2b-1, m2b-2), then back to `-D caramel_development --stats --error-trace` (m2b-3); `-D caramel_development --no-debug --stats` (m2c ×2). Then the same type check on a copy whose 110 resource views have `blueprint` bodies replaced by `plain ""` (m2d ×2), on a copy without the 154 resource routes (m2e ×2), and on the 2-resource app (m2f ×2). m2h times 10 × `--version` through `scripts/crystal` against the compiler binary directly.
- **M3**: `CARAMEL_BENCHMARK_OUTPUT=… scripts/check frappe-project --benchmark` (a private Latte fixture on free ports; `benchmark.json` complete).
- **M4**: `scripts/release --dry-run`, twice.
- **M5**: `scripts/check lint` twice, then `scripts/check route-compilation`, listing the shared compiler cache after each.

Step 3, the instrumented `caffeinate -d scripts/check all` under a 250 ms process sampler with cache-event tracking, was **skipped by the owner**, so the sampler never ran. Its limits would have been 250 ms resolution, summed process durations that double-count parallel work, one observation, and noise from foreign compiles. Per-run times therefore come from the 0.4.0 release log.

Expert pass and follow-ups: four read-only expert subagents (compiler/toolchain, framework code, app workflow, suite/release) worked from the dataset, the code-reading reports, the repo and the Crystal 1.21.0 source. They returned 45 measurement questions. The 42 that needed neither the owner's Latte nor more than 5 minutes ran once each, in private compiler caches (rows `fq-*`). App-6 (needs the owner's Latte), App-7 (≈570 s) and Sui-11 (≈360 s) did not run. Sui-0 and Sui-7 were covered by Com-4, and Com-5 by Fra-12 (same programs and command). App-2 failed as written (`crystal eval` does not resolve an absolute `require`) and ran once more with a relative `require`. Savings confirmed or corrected by a follow-up say so in their section.

Limits:

- One observation per row, two for the m2 pairs; repeat pairs differ by up to 0.07 s wall (m2d 1.38 vs 1.31 s). Identical follow-up builds differ more: fq-Fra-0-1/-2 by 0.20 s wall, and `Codegen (crystal)` of identical warm 22-resource builds ranged 0.967–1.298 s, so single differences below ≈0.2 s (E2-1, E2-2, E2-3, E2-4) are within noise.
- CPU time undercounts for `scripts/check` and `scripts/release`, which `exec` after building (macOS drops accumulated child CPU time at `exec`; checked with a throwaway script). Only wall times are used.
- The owner built two demo apps at 20:02:44–20:02:59, between M4 and M5 and outside every row.
- M4 stopped at `scripts/cut/cut.cr:100` (nothing to release at v0.4.0), so probe costs come from the fq-Sui-8/9 proxies.
- Stats sanity check: m2a-2 `Semantic (main)` 0.741 s ≤ 0.717 s × 1.2 = 0.860 s (`22/unchanged_warm`), passed. The full-run sanity check does not apply without Step 3.
- Generated apps install caramel 0.4.0 from GitHub, which equals the checkout (HEAD is the v0.4.0 tag).

Ranking rules as applied: scores follow the formulas above; a `framework-spec` saving counts toward `check-all`; E2-2 is capped at its measured upper bound; the weighted figures of E3-2 (a hit needs a fresh dev build), E3-3 (only migration-writing diffs), E3-5 (only when the first spec file changed) and E3-6 (only unchanged reruns) are upper bounds, ranked as if the condition always held; E1-5 was reopened from a rejected hypothesis because its own follow-up contradicted the rejection.

Not measured, so labelled as estimates or left open:

- per-run attribution inside `check all` (Step 3 skipped);
- contention between parallel lanes (Sui-11);
- release probes inside a real release (early exit; proxies only);
- Latte clone and drop time per Corretto worker (App-6);
- the dev session's own check/build/ready timings for the save residual (App-7);
- the full-build and memory effect of a larger GC heap;
- whether exempting the terminal removes the first-launch delay;
- whether the ECR override removes the macro run (fq-Com-3 was inconclusive);
- how many freshly linked binaries one suite launches.

## Measurements

Paths are abbreviated: `<repo>` = the checkout, `$PERF` = `/private/tmp/caramel-perf`, `$PROFILE` = the compiler-profile root `/private/tmp/20260928-54596-1w29ielcaramel-compiler-profile-`, `<toolchain>` = the managed toolchain root. Commands longer than 160 characters are cut at `…`.

### Targeted and follow-up measurements (`measurements.tsv`)

| id | command | cwd | wall_s | user_s | sys_s | exit | foreign_compile |
|---|---|---|---|---|---|---|---|
| m1-compiler-profile | `scripts/check compiler-profile` | <repo> | 45.88 | 73.58 | 15.29 | 0 | no |
| m2a-1 | `<repo>/scripts/crystal build src/bookshelf.cr --no-codegen -D caramel_development --stats` | $PROFILE/22/bookshelf | 1.47 | 1.68 | 0.22 | 0 | no |
| m2a-2 | `<repo>/scripts/crystal build src/bookshelf.cr --no-codegen -D caramel_development --stats` | $PROFILE/22/bookshelf | 1.43 | 1.68 | 0.21 | 0 | no |
| m2b-1 | `<repo>/scripts/crystal build src/bookshelf.cr --stats --error-trace -o $PERF/m2b-app` | $PROFILE/22/bookshelf | 3.27 | 5.89 | 1.56 | 0 | no |
| m2b-2 | `<repo>/scripts/crystal build src/bookshelf.cr --stats --error-trace -o $PERF/m2b-app` | $PROFILE/22/bookshelf | 2.97 | 3.98 | 1.46 | 0 | no |
| m2b-3 | `<repo>/scripts/crystal build src/bookshelf.cr -D caramel_development --stats --error-trace -o $PROFILE/22/application` | $PROFILE/22/bookshelf | 3.47 | 6.30 | 1.57 | 0 | no |
| m2c-1 | `<repo>/scripts/crystal build src/bookshelf.cr -D caramel_development --no-debug --stats -o $PERF/m2c-app` | $PROFILE/22/bookshelf | 4.41 | 16.54 | 2.45 | 0 | no |
| m2c-2 | `<repo>/scripts/crystal build src/bookshelf.cr -D caramel_development --no-debug --stats -o $PERF/m2c-app` | $PROFILE/22/bookshelf | 3.19 | 7.99 | 1.42 | 0 | no |
| m2d-1 | `<repo>/scripts/crystal build src/bookshelf.cr --no-codegen -D caramel_development --stats` | $PROFILE/22/bookshelf-noviews | 1.38 | 1.67 | 0.20 | 0 | no |
| m2d-2 | `<repo>/scripts/crystal build src/bookshelf.cr --no-codegen -D caramel_development --stats` | $PROFILE/22/bookshelf-noviews | 1.31 | 1.61 | 0.20 | 0 | no |
| m2e-1 | `<repo>/scripts/crystal build src/bookshelf.cr --no-codegen -D caramel_development --stats` | $PROFILE/22/bookshelf-noroutes | 1.04 | 1.11 | 0.18 | 0 | no |
| m2e-2 | `<repo>/scripts/crystal build src/bookshelf.cr --no-codegen -D caramel_development --stats` | $PROFILE/22/bookshelf-noroutes | 1.00 | 1.12 | 0.18 | 0 | no |
| m2f-1 | `<repo>/scripts/crystal build src/bookshelf.cr --no-codegen -D caramel_development --stats` | $PROFILE/2/bookshelf | 1.03 | 1.12 | 0.17 | 0 | no |
| m2f-2 | `<repo>/scripts/crystal build src/bookshelf.cr --no-codegen -D caramel_development --stats` | $PROFILE/2/bookshelf | 1.03 | 1.11 | 0.17 | 0 | no |
| m2h-wrapper | `/bin/sh -c for i in 1 2 3 4 5 6 7 8 9 10; do scripts/crystal --version >/dev/null; done` | <repo> | 0.94 | 0.12 | 0.11 | 0 | no |
| m2h-direct | `/bin/sh -c for i in 1 2 3 4 5 6 7 8 9 10; do '<toolchain>/data/installs/github-crystal-lang-crystal/1.21.0/embedded/bin/crystal' --version >/dev/null; done` | <repo> | 0.14 | 0.09 | 0.04 | 0 | no |
| m3-benchmark | `scripts/check frappe-project --benchmark` | <repo> | 711.02 | 1012.65 | 253.59 | 0 | no |
| m4-release-dry-1 | `scripts/release --dry-run` | <repo> | 1.85 | 0.02 | 0.03 | 1 | no |
| m4-release-dry-2 | `scripts/release --dry-run` | <repo> | 1.30 | 0.02 | 0.02 | 1 | no |
| m5-lint-1 | `scripts/check lint` | <repo> | 36.02 | 45.65 | 4.91 | 0 | no |
| m5-lint-2 | `scripts/check lint` | <repo> | 6.91 | 9.95 | 2.29 | 0 | no |
| m5-route-compilation | `scripts/check route-compilation` | <repo> | 7.67 | 4.88 | 1.51 | 0 | no |
| fq-App-0 | `/bin/bash -c for i in 1 2 3 4 5 6 7 8 9 10; do <repo>/bin/frappe __caramel_dev_child /usr/bin/true < <(/bin/sleep 20); done` | $PERF | 0.66 | 0.05 | 0.06 | 0 | no |
| fq-App-1 | `/bin/bash -c for i in 1 2 3 4 5 6 7 8 9 10; do /usr/bin/true < <(/bin/sleep 20); done` | $PERF | 0.04 | 0.01 | 0.01 | 0 | no |
| fq-App-3 | `/bin/zsh -c zmodload zsh/datetime; for i in 1 2 3; do s=$EPOCHREALTIME; $PERF/m2c-app routes >/dev/null 2>&1; print $(( EPOCHREALTIME - s )); done` | $PERF | 0.61 | 0.02 | 0.02 | 0 | no |
| fq-Sui-9 | `/bin/sh -c D=$PERF/followup-archive; mkdir -p $D/tree $D/src-only && /usr/bin/time -p /usr/bin/git -C <repo> archive --output $D/tree.tar v0.4.0 && /usr/bin/ti…` | $PERF | 0.23 | 0.03 | 0.11 | 0 | no |
| fq-Com-6 | `/bin/sh -c set -e; D=$PERF/followup-wrapper; mkdir -p "$D"; sed "52,81d" <repo>/scripts/crystal > "$D/crystal"; chmod 700 "$D/crystal"; export CARAMEL_TOOLCHAI…` | $PERF | 1.73 | 0.25 | 0.21 | 0 | no |
| fq-Com-0 | `/bin/sh -c C=<repo>/scripts/crystal; for i in 1 2; do $C build src/bookshelf.cr -D caramel_development --no-debug --stats -o $PERF/m2c-app; done; $C build src/…` | $PROFILE/22/bookshelf | 13.98 | 30.55 | 5.75 | 0 | no |
| fq-Com-1 | `/bin/sh -c C=<repo>/scripts/crystal; A=$PROFILE/22/application; for i in 1 2 3; do $C build src/bookshelf.cr -D caramel_development --stats -o $A; done; $C bui…` | $PROFILE/22/bookshelf | 18.91 | 32.92 | 8.51 | 0 | no |
| fq-Com-2 | `/bin/sh -c A=$PROFILE/22/application; O=$PERF/followup-dsym; mkdir -p $O; for m in classic parallel; do /usr/bin/time -p dsymutil --flat --linker $m -o $O/$m.d…` | $PERF | 0.88 | 0.58 | 0.49 | 0 | no |
| fq-Fra-0-1 | `<repo>/scripts/crystal build src/bookshelf.cr -D caramel_development --stats --error-trace -o $PROFILE/22/application` | $PROFILE/22/bookshelf | 3.50 | 4.78 | 1.50 | 0 | no |
| fq-Fra-0-2 | `<repo>/scripts/crystal build src/bookshelf.cr -D caramel_development --stats --error-trace -o $PROFILE/22/application` | $PROFILE/22/bookshelf | 3.30 | 4.26 | 1.55 | 0 | no |
| fq-Com-7 | `/bin/sh -c C=<repo>/scripts/crystal; GC_PRINT_STATS=1 $C build src/bookshelf.cr --no-codegen -D caramel_development --stats 2> $PERF/followup-gc-sem.err; time …` | $PROFILE/22/bookshelf | 4.12 | 4.30 | 0.76 | 0 | no |
| fq-App-2 | `<repo>/scripts/crystal eval require "<repo>/src/frappe/dev_files"; files = Caramel::Frappe::DevFiles.new("$PROFILE/22/bookshelf"); files.snapshot; t = Time.ins…` | $PERF | 0.29 | 0.22 | 0.06 | 1 | no |
| fq-App-2-fixed | `<repo>/scripts/crystal run $PERF/followup-devfiles/probe.cr` | <repo> | 1.85 | 2.66 | 0.87 | 0 | no |
| fq-App-4-1 | `/bin/sh -c mkdir -p $PERF/followup-spec && exec <repo>/scripts/crystal build spec/requests/*_spec.cr --stats -o $PERF/followup-spec/w1` | $PROFILE/22/bookshelf | 5.17 | 17.07 | 2.65 | 0 | no |
| fq-App-4-2 | `/bin/sh -c mkdir -p $PERF/followup-spec && exec <repo>/scripts/crystal build spec/requests/*_spec.cr --stats -o $PERF/followup-spec/w1` | $PROFILE/22/bookshelf | 3.64 | 4.99 | 1.54 | 0 | no |
| fq-Fra-1-1 | `<repo>/scripts/crystal build src/bookshelf.cr -D caramel_development --stats --error-trace -o $PERF/followup-noviews-app` | $PROFILE/22/bookshelf-noviews | 4.69 | 14.53 | 2.59 | 0 | no |
| fq-Fra-1-2 | `<repo>/scripts/crystal build src/bookshelf.cr -D caramel_development --stats --error-trace -o $PERF/followup-noviews-app` | $PROFILE/22/bookshelf-noviews | 3.08 | 4.03 | 1.47 | 0 | no |
| fq-Fra-2-1 | `<repo>/scripts/crystal build src/bookshelf.cr -D caramel_development --stats --error-trace -o $PERF/followup-noroutes-app` | $PROFILE/22/bookshelf-noroutes | 3.48 | 11.60 | 2.14 | 0 | no |
| fq-Fra-2-2 | `<repo>/scripts/crystal build src/bookshelf.cr -D caramel_development --stats --error-trace -o $PERF/followup-noroutes-app` | $PROFILE/22/bookshelf-noroutes | 2.56 | 5.62 | 1.52 | 0 | no |
| fq-Fra-3 | `/usr/bin/python3 -c import shutil,pathlib;q=chr(34);n=chr(10);d=pathlib.Path('$PERF/followup-floor');shutil.copytree('$PROFILE/22/bookshelf-noroutes',d,symlink…` | $PERF | 0.31 | 0.04 | 0.20 | 0 | no |
| fq-Fra-4-1 | `<repo>/scripts/crystal build src/floor.cr --no-codegen -D caramel_development --stats` | $PERF/followup-floor | 0.76 | 0.75 | 0.15 | 0 | no |
| fq-Fra-4-2 | `<repo>/scripts/crystal build src/floor.cr --no-codegen -D caramel_development --stats` | $PERF/followup-floor | 0.81 | 0.78 | 0.16 | 0 | no |
| fq-Fra-5-1 | `<repo>/scripts/crystal build src/serve_only.cr --no-codegen -D caramel_development --stats` | $PERF/followup-floor | 1.14 | 1.18 | 0.22 | 0 | no |
| fq-Fra-5-2 | `<repo>/scripts/crystal build src/serve_only.cr --no-codegen -D caramel_development --stats` | $PERF/followup-floor | 1.05 | 1.19 | 0.19 | 0 | no |
| fq-Fra-6-1 | `<repo>/scripts/crystal build src/serve_only.cr -D caramel_development --stats -o $PERF/followup-floor/serve_only-app` | $PERF/followup-floor | 2.69 | 7.14 | 1.55 | 0 | no |
| fq-Fra-6-2 | `<repo>/scripts/crystal build src/serve_only.cr -D caramel_development --stats -o $PERF/followup-floor/serve_only-app` | $PERF/followup-floor | 2.00 | 2.29 | 0.98 | 0 | no |
| fq-Fra-7 | `/usr/bin/python3 -c import shutil,pathlib;q=chr(34);n=chr(10);d=pathlib.Path('$PERF/followup-noplumbing');shutil.copytree('$PROFILE/22/bookshelf',d,symlinks=Tr…` | $PERF | 0.31 | 0.04 | 0.20 | 0 | no |
| fq-Fra-8-1 | `<repo>/scripts/crystal build src/bookshelf.cr --no-codegen -D caramel_development --stats` | $PERF/followup-noplumbing | 1.41 | 1.75 | 0.24 | 0 | no |
| fq-Fra-8-2 | `<repo>/scripts/crystal build src/bookshelf.cr --no-codegen -D caramel_development --stats` | $PERF/followup-noplumbing | 1.49 | 1.73 | 0.24 | 0 | no |
| fq-Fra-9-1 | `<repo>/scripts/crystal build src/bookshelf.cr -D caramel_development --stats -o $PERF/followup-noplumbing/app` | $PERF/followup-noplumbing | 4.44 | 13.55 | 2.43 | 0 | no |
| fq-Fra-9-2 | `<repo>/scripts/crystal build src/bookshelf.cr -D caramel_development --stats -o $PERF/followup-noplumbing/app` | $PERF/followup-noplumbing | 3.10 | 3.86 | 1.46 | 0 | no |
| fq-Fra-10 | `/usr/bin/python3 -c import shutil,pathlib,functools;n=chr(10);d=pathlib.Path('$PERF/followup-sugar');shutil.copytree('$PROFILE/22/bookshelf',d,symlinks=True);c…` | $PERF | 0.26 | 0.04 | 0.19 | 0 | no |
| fq-Fra-11-1 | `<repo>/scripts/crystal build src/bookshelf.cr -D caramel_development --stats -o $PERF/followup-sugar/app` | $PERF/followup-sugar | 4.73 | 14.37 | 2.63 | 0 | no |
| fq-Fra-11-2 | `<repo>/scripts/crystal build src/bookshelf.cr -D caramel_development --stats -o $PERF/followup-sugar/app` | $PERF/followup-sugar | 3.22 | 4.16 | 1.51 | 0 | no |
| fq-Sui-2 | `/bin/sh -c for n in compile_valid compile_missing_contract_field compile_wrong_param_type compile_nilable_param compile_defaulted_param compile_undefined_actio…` | <repo> | 5.96 | 4.99 | 1.56 | 0 | no |
| fq-Sui-3 | `/bin/sh -c printf '%s\n' compile_valid compile_missing_contract_field compile_wrong_param_type compile_nilable_param compile_defaulted_param compile_undefined_…` | <repo> | 2.19 | 5.18 | 1.79 | 0 | no |
| fq-Sui-8 | `/bin/sh -c for d in a b c; do mkdir -p $PERF/followup-probe-$d && printf '%s\n' 'require "../../../..<repo>/src/caramel/cold_brew/migrations.cr"' 'require "jso…` | <repo> | 4.62 | 10.88 | 3.33 | 0 | no |
| fq-App-5 | `<repo>/scripts/crystal build src/bookshelf.cr --stats --error-trace -o $PERF/followup-m2b2-app` | $PROFILE/2/bookshelf | 2.97 | 7.29 | 1.40 | 0 | no |
| fq-Com-4 | `/bin/sh -c set -e; O=$PERF/followup-cold; mkdir -p "$O"; for s in src/frappe.cr spec/fixtures/frappe_environment.cr spec/fixtures/frappe_dev.cr scripts/checks/…` | <repo> | 57.11 | 88.32 | 15.63 | 0 | no |
| fq-Sui-1 | `/bin/sh -c mkdir -p $PERF/followup-checkbin && for i in 1 2; do /usr/bin/time -p <repo>/scripts/crystal build <repo>/scripts/checks/frappe_project.cr -o $PERF/…` | <repo> | 3.86 | 7.75 | 2.04 | 0 | no |
| fq-Fra-13-valid | `<repo>/scripts/crystal build --no-codegen --stats spec/fixtures/corretto/compile_valid.cr` | <repo> | 0.82 | 0.82 | 0.16 | 0 | no |
| fq-Fra-13-mocks | `<repo>/scripts/crystal build --no-codegen --stats spec/fixtures/corretto/compile_mocks.cr` | <repo> | 0.47 | 0.35 | 0.13 | 1 | no |
| fq-Fra-13-spectator | `<repo>/scripts/crystal build --no-codegen --stats spec/fixtures/corretto/compile_spectator_mocks.cr` | <repo> | 0.47 | 0.35 | 0.13 | 1 | no |
| fq-Fra-12-1 | `<repo>/scripts/crystal spec spec/caramel spec/frappe spec/latte spec/sugar_orm spec/cold_brew spec/corretto spec/release --stats` | <repo> | 22.67 | 23.64 | 5.74 | 0 | no |
| fq-Fra-12-2 | `<repo>/scripts/crystal spec spec/caramel spec/frappe spec/latte spec/sugar_orm spec/cold_brew spec/corretto spec/release --stats` | <repo> | 20.61 | 11.79 | 4.41 | 0 | no |
| fq-Com-3 | `/bin/sh -c set -e; R=$PERF/followup-ecr; TC="<toolchain>"; mkdir -p "$R/root/data"; ln -sfn "$TC/data/installs" "$R/root/data/installs"; ln -sfn "$TC/bin" "$R/…` | $PERF | 1.17 | 1.09 | 0.26 | 0 | no |
| fq-Sui-4 | `/bin/sh -c P=$PERF/followup-prefix-seq; O=$PERF/followup-build-seq; mkdir -m 700 $P && mkdir $P/data $O && ln -s '<toolchain>/data/installs' $P/data/installs &…` | <repo> | 57.65 | 81.74 | 12.01 | 0 | no |
| fq-Sui-5 | `/bin/sh -c P=$PERF/followup-prefix-par; O=$PERF/followup-build-par; mkdir -m 700 $P && mkdir $P/data $O && ln -s '<toolchain>/data/installs' $P/data/installs &…` | <repo> | 33.11 | 72.22 | 7.39 | 0 | no |
| fq-Sui-6 | `/bin/sh -c D=$PERF/followup-swift; mkdir -p $D/cache && for i in 1 2; do /usr/bin/time -p /usr/bin/swiftc -parse-as-library -O -module-cache-path $D/cache latt…` | <repo> | 53.15 | 49.72 | 3.59 | 0 | no |
| fq-Sui-10 | `/bin/sh -c B=$PERF/followup-seed; P=$B/prefix; mkdir -p $B/a $B/b && mkdir -m 700 $P && mkdir $P/data && ln -s '<toolchain>/data/installs' $P/data/installs && …` | $PERF | 15.58 | 22.97 | 4.22 | 0 | no |
| fq-Com-8 | `/bin/sh -c C=<repo>/scripts/crystal; for i in 1 2; do $C build src/bookshelf.cr -D caramel_development --stats --link-flags=-Wl,-no_deduplicate -o $PERF/follow…` | $PROFILE/22/bookshelf | 8.13 | 19.47 | 4.10 | 0 | no |
| fq-Fra-14 | `<repo>/scripts/crystal build src/bookshelf.cr --release --stats -o $PERF/followup-release-full` | $PROFILE/22/bookshelf | 84.85 | 83.05 | 2.47 | 0 | no |
| fq-Fra-15 | `<repo>/scripts/crystal build src/bookshelf.cr --release --stats -o $PERF/followup-release-noviews` | $PROFILE/22/bookshelf-noviews | 72.50 | 70.84 | 2.17 | 0 | no |

### Suite runs (0.4.0 release log, no attribution)

| Order | Run | Seconds | Share of 738 s |
|---|---|---|---|
| 1 | build | 46 | 6.2% |
| 2 | spec | 22 | 3.0% |
| 3 | browser | 28 | 3.8% |
| 4 | cold-brew-compilation | 3 | 0.4% |
| 5 | compiler | 4 | 0.5% |
| 6 | contract-compilation | 4 | 0.5% |
| 7 | dev-child | 4 | 0.5% |
| 8 | dev-retirement | 6 | 0.8% |
| 9 | editor-tools | 9 | 1.2% |
| 10 | frappe-project | 128 | 17.3% |
| 11 | installations | 79 | 10.7% |
| 12 | integration | 16 | 2.2% |
| 13 | latte-daemon | 8 | 1.1% |
| 14 | latte-ipc | 20 | 2.7% |
| 15 | latte-network | 6 | 0.8% |
| 16 | latte-postgres | 9 | 1.2% |
| 17 | lint | 36 | 4.9% |
| 18 | native | 26 | 3.5% |
| 19 | orm-compilation | 11 | 1.5% |
| 20 | route-compilation | 8 | 1.1% |
| 21 | runtime-diagnostics | 6 | 0.8% |
| 22 | schema-diff | 78 | 10.6% |
| 23 | toolchain-paths | 4 | 0.5% |
| 24 | frappe-project-dev | 177 | 24.0% |

### `--stats` stages

| run | wall_s | Parse | Semantic (top level) | Semantic (new) | Semantic (type declarations) | Semantic (abstract def check) | Semantic (restrictions augmenter) | Semantic (ivars initializers) | Semantic (cvars initializers) | Semantic (main) | Semantic (cleanup) | Semantic (recursive struct check) | Codegen (crystal) | Codegen (bc+obj) | Codegen (linking) | dsymutil | sum | object reuse | macro runs |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| profile 2/cold | 10.21 | 0.000 | 0.321 | 0.001 | 0.017 | 0.008 | 0.005 | 0.020 | 0.043 | 7.302 | 0.000 | 0.001 | 0.464 | 1.592 | 0.178 | 0.177 | 10.130 | no previous .o files were reused | process.cr: 00:00:06.366753500 |
| profile 2/unchanged_warm | 2.57 | 0.000 | 0.333 | 0.001 | 0.017 | 0.045 | 0.005 | 0.009 | 0.043 | 0.461 | 0.000 | 0.001 | 0.467 | 0.749 | 0.155 | 0.176 | 2.463 | 1264/1283 .o files were reused | process.cr: reused previous compilation (00:00:00.005105208) |
| profile 2/view_edit | 2.28 | 0.000 | 0.316 | 0.002 | 0.019 | 0.018 | 0.005 | 0.009 | 0.046 | 0.464 | 0.000 | 0.001 | 0.463 | 0.514 | 0.156 | 0.171 | 2.183 | 1282/1283 .o files were reused | process.cr: reused previous compilation (00:00:00.005034125) |
| profile 2/controller_edit | 2.29 | 0.000 | 0.312 | 0.001 | 0.018 | 0.017 | 0.005 | 0.009 | 0.044 | 0.486 | 0.000 | 0.001 | 0.461 | 0.504 | 0.154 | 0.173 | 2.188 | 1282/1283 .o files were reused | process.cr: reused previous compilation (00:00:00.005274375) |
| profile 22/cold | 11.05 | 0.000 | 0.374 | 0.002 | 0.022 | 0.009 | 0.007 | 0.010 | 0.112 | 7.385 | 0.000 | 0.001 | 1.054 | 1.520 | 0.222 | 0.247 | 10.966 | no previous .o files were reused | process.cr: 00:00:06.369878292 |
| profile 22/unchanged_warm | 3.14 | 0.000 | 0.373 | 0.002 | 0.021 | 0.009 | 0.007 | 0.010 | 0.116 | 0.717 | 0.000 | 0.001 | 0.969 | 0.355 | 0.207 | 0.247 | 3.034 | 1804/1823 .o files were reused | process.cr: reused previous compilation (00:00:00.005152834) |
| profile 22/view_edit | 2.92 | 0.000 | 0.381 | 0.002 | 0.022 | 0.009 | 0.006 | 0.010 | 0.107 | 0.698 | 0.000 | 0.001 | 0.981 | 0.143 | 0.207 | 0.247 | 2.815 | 1822/1823 .o files were reused | process.cr: reused previous compilation (00:00:00.005296459) |
| profile 22/controller_edit | 2.91 | 0.000 | 0.376 | 0.002 | 0.022 | 0.009 | 0.007 | 0.011 | 0.113 | 0.703 | 0.000 | 0.001 | 0.967 | 0.138 | 0.208 | 0.244 | 2.802 | 1822/1823 .o files were reused | process.cr: reused previous compilation (00:00:00.005318500) |
| m2a-1 | 1.47 | 0.000 | 0.387 | 0.002 | 0.023 | 0.009 | 0.008 | 0.011 | 0.122 | 0.743 | 0.000 | 0.001 | – | – | – | – | 1.307 | (no codegen) | process.cr: reused previous compilation (00:00:00.005231333) |
| m2a-2 | 1.43 | 0.000 | 0.371 | 0.002 | 0.024 | 0.009 | 0.007 | 0.010 | 0.110 | 0.741 | 0.000 | 0.001 | – | – | – | – | 1.275 | (no codegen) | process.cr: reused previous compilation (00:00:00.005216209) |
| m2b-1 | 3.27 | 0.000 | 0.366 | 0.002 | 0.022 | 0.009 | 0.006 | 0.009 | 0.124 | 0.740 | 0.000 | 0.001 | 0.962 | 0.429 | 0.209 | 0.243 | 3.123 | 1645/1819 .o files were reused | process.cr: reused previous compilation (00:00:00.005188625) |
| m2b-2 | 2.97 | 0.000 | 0.379 | 0.002 | 0.022 | 0.009 | 0.007 | 0.011 | 0.106 | 0.749 | 0.000 | 0.001 | 0.963 | 0.138 | 0.212 | 0.246 | 2.845 | all previous .o files were reused | process.cr: reused previous compilation (00:00:00.005726917) |
| m2b-3 | 3.47 | 0.000 | 0.383 | 0.002 | 0.023 | 0.009 | 0.007 | 0.010 | 0.123 | 0.751 | 0.000 | 0.001 | 1.179 | 0.406 | 0.212 | 0.250 | 3.355 | 1649/1823 .o files were reused | process.cr: reused previous compilation (00:00:00.005834500) |
| m2c-1 | 4.41 | 0.000 | 0.372 | 0.002 | 0.023 | 0.009 | 0.006 | 0.011 | 0.115 | 0.736 | 0.001 | 0.001 | 0.786 | 2.045 | 0.175 | – | 4.281 | no previous .o files were reused | process.cr: reused previous compilation (00:00:00.005261958) |
| m2c-2 | 3.19 | 0.000 | 0.385 | 0.002 | 0.022 | 0.009 | 0.006 | 0.010 | 0.113 | 0.766 | 0.000 | 0.001 | 0.783 | 0.809 | 0.170 | – | 3.076 | all previous .o files were reused | process.cr: reused previous compilation (00:00:00.005611000) |
| m2d-1 | 1.38 | 0.000 | 0.391 | 0.002 | 0.021 | 0.009 | 0.006 | 0.010 | 0.126 | 0.684 | 0.000 | 0.001 | – | – | – | – | 1.251 | (no codegen) | process.cr: reused previous compilation (00:00:00.005251458) |
| m2d-2 | 1.31 | 0.000 | 0.371 | 0.002 | 0.022 | 0.009 | 0.006 | 0.010 | 0.107 | 0.662 | 0.000 | 0.001 | – | – | – | – | 1.189 | (no codegen) | process.cr: reused previous compilation (00:00:00.005323041) |
| m2e-1 | 1.04 | 0.000 | 0.381 | 0.002 | 0.022 | 0.009 | 0.006 | 0.009 | 0.128 | 0.371 | 0.000 | 0.001 | – | – | – | – | 0.929 | (no codegen) | process.cr: reused previous compilation (00:00:00.005242250) |
| m2e-2 | 1.00 | 0.000 | 0.353 | 0.002 | 0.022 | 0.009 | 0.006 | 0.009 | 0.117 | 0.370 | 0.000 | 0.001 | – | – | – | – | 0.889 | (no codegen) | process.cr: reused previous compilation (00:00:00.005124292) |
| m2f-1 | 1.03 | 0.000 | 0.312 | 0.002 | 0.018 | 0.017 | 0.005 | 0.009 | 0.045 | 0.479 | 0.000 | 0.001 | – | – | – | – | 0.888 | (no codegen) | process.cr: reused previous compilation (00:00:00.004865584) |
| m2f-2 | 1.03 | 0.000 | 0.310 | 0.001 | 0.019 | 0.017 | 0.005 | 0.010 | 0.045 | 0.485 | 0.000 | 0.001 | – | – | – | – | 0.893 | (no codegen) | process.cr: reused previous compilation (00:00:00.004992375) |

Follow-up builds, one row per build (multi-build rows split at each `Parse:` timing line):

| Build | Wall s | Semantic (top level) | Semantic (main) | Codegen (crystal) | Codegen (bc+obj) | Linking | dsymutil | Object reuse | Macro run |
|---|---|---|---|---|---|---|---|---|---|
| fq-Com-0 #1 | – | 0.434 | 0.776 | 0.878 | 0.928 | 0.201 | – | all previous .o files were reused | – |
| fq-Com-0 #2 | – | 0.408 | 0.787 | 0.880 | 0.939 | 0.191 | – | all previous .o files were reused | – |
| fq-Com-0 #3 | – | 0.396 | 0.797 | 0.884 | 0.832 | 0.199 | – | all previous .o files were reused | – |
| fq-Com-0 #4 | – | 0.393 | 0.804 | 0.880 | 0.944 | 0.197 | – | all previous .o files were reused | – |
| fq-Com-1 #1 | – | 0.397 | 0.795 | 1.101 | 1.773 | 0.231 | 0.278 | 1/1823 .o files were reused | – |
| fq-Com-1 #2 | – | 0.438 | 0.785 | 1.063 | 0.163 | 0.230 | 0.278 | all previous .o files were reused | – |
| fq-Com-1 #3 | – | 0.432 | 0.785 | 1.093 | 0.162 | 0.235 | 0.277 | all previous .o files were reused | – |
| fq-Com-1 #4 | – | 0.399 | 0.811 | 1.105 | 0.884 | 0.227 | 0.261 | all previous .o files were reused | – |
| fq-Com-1 #5 | – | 0.424 | 0.825 | 1.283 | 0.157 | 0.226 | 0.264 | all previous .o files were reused | – |
| fq-Com-7 #1 | – | 0.402 | 0.805 | – | – | – | – | (no codegen) | – |
| fq-Com-7 #2 | – | 0.429 | 0.821 | – | – | – | – | (no codegen) | – |
| fq-Com-7 #3 | – | 0.355 | 0.473 | – | – | – | – | (no codegen) | – |
| fq-Com-8 #1 | – | 0.462 | 0.805 | 1.030 | 1.756 | 0.236 | 0.276 | no previous .o files were reused | – |
| fq-Com-8 #2 | – | 0.409 | 0.784 | 1.088 | 0.161 | 0.232 | 0.271 | all previous .o files were reused | – |
| fq-Sui-10 #1 | – | 0.361 | 7.910 | 1.132 | 1.157 | 0.216 | 0.200 | no previous .o files were reused | – |
| fq-Sui-10 #2 | – | 0.361 | 0.592 | 0.917 | 0.472 | 0.201 | 0.194 | 1196/1396 .o files were reused | – |
| fq-Fra-0-1 | 3.50 | 0.431 | 0.771 | 1.298 | 0.165 | 0.234 | 0.275 | all previous .o files were reused | – |
| fq-Fra-0-2 | 3.30 | 0.404 | 0.793 | 1.086 | 0.164 | 0.234 | 0.273 | all previous .o files were reused | – |
| fq-Fra-1-1 | 4.69 | 0.428 | 0.765 | 0.969 | 1.703 | 0.233 | 0.268 | no previous .o files were reused | – |
| fq-Fra-1-2 | 3.08 | 0.393 | 0.725 | 1.013 | 0.153 | 0.229 | 0.267 | all previous .o files were reused | – |
| fq-Fra-2-1 | 3.48 | 0.377 | 0.401 | 0.479 | 1.574 | 0.162 | 0.165 | no previous .o files were reused | – |
| fq-Fra-2-2 | 2.56 | 0.383 | 0.408 | 0.488 | 0.597 | 0.170 | 0.185 | all previous .o files were reused | – |
| fq-Fra-4-1 | 0.76 | 0.377 | 0.061 | – | – | – | – | (no codegen) | – |
| fq-Fra-4-2 | 0.81 | 0.390 | 0.063 | – | – | – | – | (no codegen) | – |
| fq-Fra-5-1 | 1.14 | 0.399 | 0.397 | – | – | – | – | (no codegen) | – |
| fq-Fra-5-2 | 1.05 | 0.380 | 0.377 | – | – | – | – | (no codegen) | – |
| fq-Fra-6-1 | 2.69 | 0.390 | 0.399 | 0.446 | 0.836 | 0.153 | 0.154 | no previous .o files were reused | – |
| fq-Fra-6-2 | 2.00 | 0.426 | 0.382 | 0.446 | 0.086 | 0.159 | 0.164 | all previous .o files were reused | – |
| fq-Fra-8-1 | 1.41 | 0.403 | 0.706 | – | – | – | – | (no codegen) | – |
| fq-Fra-8-2 | 1.49 | 0.420 | 0.738 | – | – | – | – | (no codegen) | – |
| fq-Fra-9-1 | 4.44 | 0.407 | 0.711 | 0.966 | 1.569 | 0.212 | 0.234 | no previous .o files were reused | – |
| fq-Fra-9-2 | 3.10 | 0.419 | 0.755 | 0.948 | 0.130 | 0.252 | 0.235 | all previous .o files were reused | – |
| fq-Fra-11-1 | 4.73 | 0.424 | 0.813 | 0.994 | 1.675 | 0.240 | 0.266 | no previous .o files were reused | – |
| fq-Fra-11-2 | 3.22 | 0.426 | 0.785 | 1.025 | 0.155 | 0.229 | 0.265 | all previous .o files were reused | – |
| fq-App-4-1 | 5.17 | 0.473 | 0.766 | 1.172 | 1.914 | 0.230 | 0.295 | no previous .o files were reused | – |
| fq-App-4-2 | 3.64 | 0.416 | 0.816 | 1.354 | 0.165 | 0.225 | 0.302 | all previous .o files were reused | – |
| fq-App-5 | 2.97 | 0.338 | 0.519 | 0.498 | 0.945 | 0.179 | 0.194 | 1205/1279 .o files were reused | – |
| fq-Fra-12-1 | 22.67 | 0.370 | 0.920 | 1.546 | 2.175 | 0.271 | 0.330 | no previous .o files were reused | – |
| fq-Fra-12-2 | 20.61 | 0.401 | 0.923 | 1.503 | 0.183 | 0.271 | 0.335 | all previous .o files were reused | – |
| fq-Fra-13-valid | 0.82 | 0.355 | 0.232 | – | – | – | – | (no codegen) | – |
| fq-Fra-14 | 84.85 | 0.397 | 0.808 | 0.985 | 81.561 | 0.332 | 0.403 | no previous .o files were reused | – |
| fq-Fra-15 | 72.50 | 0.442 | 0.745 | 0.687 | 69.708 | 0.295 | 0.303 | no previous .o files were reused | – |
| fq-Com-4 frappe cold | 3.70 | 0.339 | 0.578 | 0.959 | 1.218 | 0.202 | 0.191 | no previous .o files were reused | process.cr: reused previous compilation (00:00:00.144802250) |
| fq-Com-4 frappe warm | 2.65 | 0.339 | 0.561 | 0.977 | 0.119 | 0.206 | 0.209 | all previous .o files were reused | process.cr: reused previous compilation (00:00:00.005250500) |
| fq-Com-4 frappe_environment cold | 2.42 | 0.304 | 0.316 | 0.504 | 0.788 | 0.151 | 0.138 | no previous .o files were reused | process.cr: reused previous compilation (00:00:00.005028625) |
| fq-Com-4 frappe_environment warm | 1.72 | 0.332 | 0.312 | 0.490 | 0.071 | 0.143 | 0.127 | all previous .o files were reused | process.cr: reused previous compilation (00:00:00.005270583) |
| fq-Com-4 frappe_dev cold | 2.59 | 0.329 | 0.343 | 0.560 | 0.827 | 0.157 | 0.133 | no previous .o files were reused | process.cr: reused previous compilation (00:00:00.005615167) |
| fq-Com-4 frappe_dev warm | 1.80 | 0.318 | 0.316 | 0.541 | 0.083 | 0.166 | 0.142 | all previous .o files were reused | process.cr: reused previous compilation (00:00:00.005410167) |
| fq-Com-4 route_compilation cold | 1.48 | 0.328 | 0.070 | 0.260 | 0.393 | 0.103 | 0.080 | no previous .o files were reused | – |
| fq-Com-4 route_compilation warm | 1.09 | 0.300 | 0.072 | 0.254 | 0.043 | 0.103 | 0.084 | all previous .o files were reused | – |
| fq-Com-4 frappe_lint cold | 34.83 | 28.626 | 1.744 | 1.444 | 2.029 | 0.275 | 0.238 | no previous .o files were reused | read_type_doc.cr: 00:00:26.283073750 |
| fq-Com-4 frappe_lint warm | 4.70 | 0.862 | 0.899 | 1.508 | 0.591 | 0.231 | 0.253 | 1363/1423 .o files were reused | read_type_doc.cr: reused previous compilation (00:00:00.005415208) |
