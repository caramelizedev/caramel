# ADR 0001: Use mise for contributor tools; keep consumer adoption provisional

Date: 2026-09-19

Status: accepted.

## Context

Caramel needs Crystal, Shards, Caddy, PostgreSQL, OpenSSL, GMP and pkgconf at known versions on a
developer's machine, without Homebrew, a global version manager or a compiled PostgreSQL.
Each tool must install from prebuilt artifacts and run without touching the host's own tools.

## Decision

1. **Provider.** Pinned mise 2026.9.11 runs behind an isolated toolchain adapter. Backends are
   explicit: GitHub for Crystal, aqua for Caddy, and conda-forge for prebuilt PostgreSQL,
   OpenSSL, GMP and pkgconf. Caramel does not write a general version manager and does not compile
   PostgreSQL during ordinary setup.
2. **Tested set.** Crystal 1.22.1 with bundled Shards 0.20.0, Caddy 2.11.4, PostgreSQL 18.6,
   OpenSSL 3.6.4, GMP 6.3.0 and pkgconf 3.0.7. The experiment lockfile preserves the concrete artifact
   URLs and SHA-256 checksums, including PostgreSQL's transitive dependency packages. Updating
   a tool version or backend is a reviewed dependency change.
3. **Responsibilities.** Frappé is the application developer's interface. Shards owns Crystal
   application dependencies. Latte owns database data, roles, lifecycle, project registration,
   DNS, and certificate and proxy configuration. None of these is delegated to mise bootstrap
   or mise daemons.
4. **Expose bundled Shards explicitly.** The Crystal archive has `embedded/bin/shards`, while
   mise's default GitHub integration exposes `bin`. Invoke the bundled binary through the
   selected compiler version; a global Shards installation never takes over silently.
5. **Supply native compiler dependencies explicitly.** The Crystal archive does not include
   OpenSSL. Use a dedicated managed OpenSSL prefix and pkgconf with a `pkg-config` entry point.
   OpenSSL is exposed via `PKG_CONFIG_LIBDIR`, and its library directory is embedded as a
   development runtime search path. Nor does it include GMP, which `BigDecimal`, `BigInt` and
   `BigRational` link. `scripts/crystal` links it through a single link to `libgmp.dylib` in its
   private compiler directory, not through GMP's conda library directory, and embeds that
   directory as a development runtime search path.
6. **Keep native search paths narrow.** Adding the entire PostgreSQL library directory to the
   compiler search path causes an iconv ABI mismatch with Crystal's macOS bindings. A database
   prefix is not a general compiler dependency directory.
7. **Keep installation separate from database initialization.** The conda package creates no
   cluster. Latte initializes and supervises its own data directory outside tool installations.
   Upgrading or removing a tool never removes databases.
8. **Define cache guarantees.** Installed-tool reuse works offline. Ordinary mise download
   retention gives no uniform offline reinstallation guarantee. A consumer adapter retains
   verified distributable artifacts or explicitly defines the supported installed-tool cache,
   and tests recovery from missing or corrupt files.
9. **Isolate configuration and execution.** Use Caramel-owned configuration, data, cache and
   state; explicit system and global overrides; a bounded discovery root; a filtered
   environment; reviewed backends; and content-bound config trust. Validate the discovered
   configuration set before executing installation hooks or tasks. The experiment wrapper is
   research tooling, not a security boundary for arbitrary untrusted projects.
10. **Source of truth.** `tools/toolchain/caramel-toolchain.toml` is the authored tool
    selection and `tools/toolchain/mise.lock` records resolved artifacts.
    `scripts/install-toolchain` installs exactly that selection into a private prefix,
    verifies the native tools and records a receipt; `scripts/crystal` and `scripts/shards` run
    from that prefix.
11. **Manifest authority.** The application-facing Caramel environment manifest stays
    authoritative. If the consumer adapter uses mise, it generates internal configuration from
    that manifest; users do not maintain duplicate version declarations.

## Reasons

- Prebuilt upstream archives install in seconds and run with no network once installed; the
  experiment's inventory is at
  https://github.com/caramelizedev/caramel-notes/blob/main/research/toolchain-artifacts.md.
- Pinned versions with recorded checksums make every toolchain change a reviewed diff.
- Crystal 1.21.1 fixes non-blocking `Socket#connect` on macOS 26.7 and later, `HTTP::Server`
  request smuggling, and automatic decompression of request bodies.
- Crystal 1.22.1 fixes `OpenSSL::SSL::Options::ALL`, io_uring event loop hangs and the
  `Content-Length` regressions of 1.22.0, and keeps the io_uring event loop that Linux release
  builds can select.
- Separate prefixes let several Crystal versions coexist and leave the host's shell, Homebrew
  and Herd untouched.
- Bundling GMP lets an application use the standard library's exact arithmetic in every
  managed build, without Homebrew or a link annotation of its own.
