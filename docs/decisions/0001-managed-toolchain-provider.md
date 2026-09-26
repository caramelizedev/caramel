# ADR 0001: Use mise for contributor tools; keep consumer adoption provisional

Date: 2026-09-19

Status: accepted for the Caramel development prototype; consumer installer acceptance remains open.

## Decision

Use pinned mise 2026.9.11 behind an isolated toolchain adapter for the next Caramel prototype. Select explicit backends: GitHub for Crystal, aqua for Caddy, and conda-forge for prebuilt PostgreSQL, OpenSSL, and pkgconf. Do not write a general version manager or compile PostgreSQL during ordinary setup.

The tested set is Crystal 1.21.0 with bundled Shards 0.20.0, Caddy 2.11.4, PostgreSQL 18.6, OpenSSL 3.6.4, and pkgconf 3.0.7. Preserve the concrete artifact URLs and SHA-256 checksums in the experiment lockfile, including PostgreSQL's transitive dependency packages. Updating a tool version or backend is a reviewed dependency change.

Frappé remains the application developer's interface. Shards owns Crystal application dependencies. Latte owns database data, roles, lifecycle, project registration, DNS, and certificate/proxy configuration. This decision does not delegate those responsibilities to mise bootstrap or mise daemons.

## Evidence

See [artifact inventory](../research/toolchain-artifacts.md) and [installation evidence](../research/toolchain-installation.md).

| Check | Observed result |
| --- | --- |
| Crystal + Caddy installation | 9.866 seconds together; prebuilt upstream archives |
| PostgreSQL installation | 7.770 seconds; prebuilt server plus 22 dependency packages |
| HTTP-importing Crystal smoke program | Compiles and executes with a dedicated OpenSSL prefix and a pkg-config alias; 3.486 seconds with an empty Crystal cache |
| Database lifecycle | Private socket, empty TCP listen address; inserted row persists across stop/start; test server stopped afterward |
| Repeated locked install | All five selected tools already installed; 0.036 seconds |
| Network-denied execution | Crystal, Shards, PostgreSQL, and Caddy version commands succeed |
| Network-denied fresh-prefix installation | Three conda tools reinstall from retained archives; Crystal/Caddy fail because their archives were not retained |
| Interrupted installation | Crystal 1.20.3 interrupted during download; execution with automatic installation disabled refuses the partial installation; retry succeeds in 6.157 seconds |
| Version coexistence | Crystal 1.20.3 and 1.21.0 both execute after retry |
| Host coexistence | Recorded shell/configuration hashes unchanged; ordinary psql still resolves to Herd; sampled process library loads contain no Homebrew/Herd paths |

These are single-run observations on the development machine, not product speed guarantees. The tiny smoke program does not measure an application framework, database driver, htmx interaction, or request-serving throughput.

## Required integration

1. **Expose bundled Shards explicitly.** The Crystal archive has `embedded/bin/shards`, while mise's default GitHub integration exposes `bin`. Invoke the bundled binary through the selected compiler version; do not let a global Shards installation silently take over.
2. **Supply native compiler dependencies explicitly.** The Crystal archive does not include OpenSSL. Use a dedicated managed OpenSSL prefix and pkgconf with a `pkg-config` entry point. The experiment exposed OpenSSL via `PKG_CONFIG_LIBDIR` and embedded its library directory as a development runtime search path.
3. **Keep native search paths narrow.** Adding the entire PostgreSQL library directory to the compiler search path caused an iconv ABI mismatch with Crystal's macOS bindings. Do not treat a database prefix as a general compiler dependency directory.
4. **Keep installation separate from database initialization.** The conda package did not create a cluster. Latte will initialize and supervise its own data directory outside tool installations. Upgrading or removing a tool must never remove databases.
5. **Define cache guarantees.** Installed-tool reuse works offline. Ordinary mise download retention does not provide a uniform offline reinstallation guarantee. A consumer adapter must retain verified distributable artifacts or explicitly define the supported installed-tool cache, and test recovery from missing/corrupt files.
6. **Isolate configuration and execution.** Use Caramel-owned configuration/data/cache/state, explicit system/global overrides, a bounded discovery root, filtered environment, reviewed backends, and content-bound config trust. Validate the discovered configuration set before executing installation hooks or tasks. The experiment wrapper is research tooling, not a security boundary for arbitrary untrusted projects.

## Source of truth

`tools/toolchain/caramel-toolchain.toml` is the authored tool selection and `tools/toolchain/mise.lock` records resolved artifacts. `scripts/install-toolchain` installs exactly that selection into a private prefix, verifies the native tools, and records a receipt; `scripts/crystal` and `scripts/shards` run from that prefix.

The application-facing Caramel environment manifest remains authoritative. If the consumer adapter uses mise, it generates internal configuration from that manifest; users do not maintain duplicate version declarations. The precise manifest-to-toolchain mapping will be implemented with Frappé after the application slice establishes its required native libraries.

## Consumer release gates still open

- A clean Apple Silicon macOS installation without Homebrew or Herd. This machine already has Apple Command Line Tools; the experiment cannot establish the absence of an Xcode/SDK prerequisite. No clean-machine host was available for this run.
- A complete native dependency and license inventory for redistribution, supported minimum macOS versions, and signed/provenance verification policy. Published SHA-256 integrity was checked; this run does not establish independent publisher signature verification for every artifact.
- Caddy service operation, named local DNS, trusted browser HTTPS, scoped privileged setup, and existing-port/service conflict behavior.
- Recovery across interrupted extraction, upgrades, corrupted installations, and loss of cached artifacts. A download interruption test alone does not cover these cases.
- A relocatable release artifact and Linux deployment recipe. The smoke binary's absolute temporary OpenSSL search path is suitable only for this experiment.
