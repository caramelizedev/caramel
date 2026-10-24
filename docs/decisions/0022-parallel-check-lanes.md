# ADR 0022: `scripts/check all` runs its checks in parallel lanes

Date: 2026-09-30

Status: accepted.

## Context

- Running checks one after another is slow: a full run is 23 mostly single-threaded runs, 417 s on a 12-core machine.
- They ran serially because they share one compiler cache: Crystal's keep-10 cleanup ends every build, `crystal spec` names its program after `<cwd>/spec`, and the suite's temporary projects churn the cache.
- A private toolchain prefix isolates that: its `data/installs` and `bin` link to the toolchain's, it has compiler and shards caches of its own, and Frappé, Latte and the checks follow `CARAMEL_TOOLCHAIN_ROOT` to it (`src/latte/toolchain.cr`). Runs on different prefixes then compete only for CPU, memory, free ports (fixtures bind port 0) and Latte's fixed ports (only latte-daemon uses them).
- A prefix's compiler sees the standard library through the prefix's path, so objects cached under the toolchain's own paths do not match there. A throwaway prefix compiles cold every time.

## Decision

1. `scripts/check all --lanes N` (1 to 8) runs the build step first, then deals the spec run and the checks to N lanes that run side by side. Within a lane, runs go one after another. Without `--lanes`, `check all` uses the smaller of half the machine's cores and a quarter of its memory in GB, from 2 to 8, and prints its choice. After the runs it prints each lane's total and longest run.
2. The first lane uses the checkout's toolchain. Each further lane uses the persistent prefix `lanes/lane-N` inside that toolchain, made on first use, with its shards cache cloned from the toolchain's. It persists so that its caches stay warm from one run to the next; a new toolchain's lanes start cold once.
3. Placement:
   - The first lane takes installations, which checks that a release reuses this toolchain's selection; editor-tools, which uses its editor tools; native, which rebuilds the installers in `bin/`; and the four `crystal spec` programs (the spec run, native's, integration's and latte-postgres's).
   - The other runs are dealt heaviest first to the lightest lane, weighted by the duration each took the last time it passed on this machine, which `check all` records with its lane in `check-durations.json` in the toolchain root, and until then by constants from a 2026-10 run. A run keeps the lane it last ran on while that lane's load is within a fifth of the lightest lane's, or 30 s of it, so its compiler cache there stays warm. The timing-sensitive latte-ipc is dealt last.
   - `frappe-project`, `frappe-project-dev` and `frappe-project-build` each create their own application, so the longest flow no longer bounds one lane.
   - browser runs first in its lane.
   - latte-daemon keeps Latte's fixed ports, which no other check uses, so a full run still needs the user's own Latte stopped.
4. When the build step fails, the checks run in one lane: without its binaries each check builds its own into `bin/`, and lanes would race to write them.
5. Outside `check all` the checks share the checkout's toolchain, so two `scripts/check NAME` never run at once.
6. A release runs every check ([ADR 0016](0016-versioning-and-releases.md) §6).
7. Latte refuses to start a service only when another process has its exact executable ([ADR 0012](0012-latte-supervision-watching-branching.md) §1), so same-named processes of other lanes do not block it. Managed-child specs use a private executable, so another lane's `sleep` cannot match them.

## Reasons

- Contention is moderate: with warm prefixes, the heaviest checks slow by 10–40 % in a full three-lane run, and the lanes still more than halve the suite.
- A run's wall time is the build step plus its heaviest lane. In 2026-10 one check, `frappe-project --dev`, took 391 s of a 540 s lane on a 12-core machine, and the planner, dealing by weights measured at v0.5.0, still put three other runs beside it. Recording each machine's own durations, splitting that check and letting the lane count follow the machine remove that floor without a fixed number for any machine.
- A run that changes lane compiles cold in the new prefix, which can double its time, so a run keeps its lane while the loads stay close.
- Each lane's compiler peaks at about 2 GB resident, so a quarter of the memory in GB bounds the lanes; `--lanes 1` keeps serial behaviour on any machine.
- Rejected: a fresh prefix per run, because it compiles cold every time and costs more than the contention it avoids.
