# ADR 0022: `scripts/check all` runs its checks in parallel lanes

Date: 2026-09-30

Status: accepted. Replaces the rule in CONTRIBUTING.md that `scripts/check all` runs its checks one after another. [ADR 0016](0016-versioning-and-releases.md) §6 still holds: a release runs every check.

## Context

- `scripts/check all` ran its runs one after another because they shared one compiler cache: Crystal's keep-10 cleanup ends every build, `crystal spec` names its program after `<cwd>/spec`, and the suite's temporary projects churn the shared cache. In the v0.5.0 release gate its 23 runs took 417 s on a 12-core machine, most of them single-threaded.
- A private toolchain prefix isolates all of that. Its `data/installs` and `bin` link to the toolchain's, it has compiler and shards caches of its own, and Frappé, Latte and the checks follow `CARAMEL_TOOLCHAIN_ROOT` to it (`src/latte/toolchain.cr`). `scripts/checks/compiler_profile.cr` already builds such prefixes.
- Runs on different prefixes then compete only for CPU and memory, and for what a check holds outside its toolchain: free ports, which fixtures take by binding port 0, and Latte's fixed ports, which only latte-daemon uses.
- A prefix's compiler sees the standard library through the prefix's path, so objects cached under the toolchain's own paths do not match there. A prefix made for one run would compile cold every time: schema-diff took 78 s in a new prefix against 48 s in a warm one.
- Running fixtures side by side exposed one product bug. Latte refused to start a service while two other processes of the user had its executable's name; [ADR 0012](0012-latte-supervision-watching-branching.md) §1 now refuses only exact matches.

## Decision

1. `scripts/check all --lanes N` (1 to 4) runs the build step first, then deals the spec run and the checks to N lanes that run side by side. Within a lane, runs go one after another. Without `--lanes`, `check all` uses 3 lanes.
2. The first lane uses the checkout's toolchain. Each further lane uses the persistent prefix `lanes/lane-N` inside that toolchain, made on first use, with its shards cache cloned from the toolchain's. It persists so that its caches stay warm from one run to the next; a new toolchain's lanes start cold once.
3. Placement:
   - The first lane takes installations, which checks that a release reuses this toolchain's selection; editor-tools, which uses its editor tools; native, which rebuilds the installers in `bin/`; and the four `crystal spec` programs (the spec run, native's, integration's and latte-postgres's).
   - The other runs are dealt heaviest first to the lightest lane, weighted by their v0.5.0 gate times, with frappe-project-dev never on the first lane and the timing-sensitive latte-ipc dealt last.
   - browser runs first in its lane.
   - latte-daemon keeps Latte's fixed ports, which no other check uses, so a full run still needs the user's own Latte stopped.
4. When the build step fails, the checks run in one lane: without its binaries each check builds its own into `bin/`, and lanes would race to write them.
5. Outside `check all` the checks share the checkout's toolchain, so two `scripts/check NAME` still never run at once.

## Reasons

- Contention is moderate. With warm prefixes, schema-diff beside orm-compilation, route-compilation and latte-ipc took 47.6 s against 48.1 s alone. In full three-lane runs the heaviest checks slowed by 10–40 % (installations 84 s against 76 s, frappe-project-dev 138 s against 124 s), and the lanes still more than halved the suite.
- Three consecutive full runs with three lanes passed every check in 180.8, 189.9 and 187.8 s, against 417 s for the v0.5.0 gate's runs. Two lanes took 240 s on 21 of the runs: the floor for two lanes is half the work, so a third lane pays.
- The first lane, with installations, is the longest (about 170 s), so a fourth lane adds little.
- Across the three lanes the compilers, codegen workers included, peaked at 5.7 GB resident. On a machine with less memory, `--lanes 1` keeps the old behaviour.

## Verification

- The three runs above, and every release gate after them, run `scripts/check all` with the default lanes.
- `spec/latte/postgres_spec.cr` covers starting a service beside same-named processes with other arguments, and its managed-child examples use a private executable, so another lane's `sleep` cannot match them.
