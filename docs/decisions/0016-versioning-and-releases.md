# ADR 0016: Versioning and releases

Date: 2026-09-28

Status: accepted. Amends ADR 0015 on on-demand start and the launchers.

## Context

Caramel needs releases that applications can pin, upgrade and install side by side:

- One version number must serve the framework, Latte and the shard, and compatibility between Frappé, Latte and its state must be explicit.
- Latte is one per user (one daemon, one PostgreSQL cluster, one CA, fixed ports, one relay), while several Caramel versions can be installed at once.
- A copied framework and a thick generated entry point would drift from the release an application pins.
- `bin/frappe` and `bin/latte` find OpenSSL through an absolute rpath into the builder's toolchain, so they cannot run on another machine ([ADR 0001](0001-managed-toolchain-provider.md)).

## Decision

1. **One version for the repository.** The public repository `github.com/caramelizedev/caramel` tags releases `vX.Y.Z` (semantic versioning), with pre-releases `X.Y.Z-rc.N`, which are tagged by hand; `scripts/release` cuts final releases. During 0.x a minor release may break compatibility, and a patch release never does. The version is written only in `shard.yml`; `Caramel::VERSION` (read when the framework compiles, `src/caramel/version.cr`) and `Latte.app`'s bundle versions (written by `scripts/build-latte-menu`) are generated from it.
2. **Explicit compatibility contracts.** Each release keeps these promises:
   - Latte's control API is versioned. Latte serves the versions in `Latte::ControlAPI::VERSIONS`, reports its release and window in `/v1/status`, and answers any other version with `unsupported_api` and both. Each Frappé states the version it needs (`LatteClient::API_VERSION`) and names the release that fixes a mismatch. `latte version` prints the release and window.
   - Latte's state formats migrate forward when Latte starts. Latte's registry, `installations.json` and the trust receipt refuse a newer format, naming the file and the format this release reads (`src/latte/state_format.cr`); the Swift toolchain installer refuses a newer receipt the same way. Choosing which Latte runs is not refusing: when `installations.json` is unreadable there, this release's own Latte runs. The first new format adds its forward migration.
   - A PostgreSQL major bump ships a `pg_upgrade` step, and the previous major's binaries are kept until that step has run. The cluster lives in `services/postgres/<major>/data`, and Latte refuses to start an empty cluster beside another major's data. Latte adopts a postmaster that another toolchain's build of the major started on the cluster's directory, identified by the private PID file, owner, start time and data directory.
   - Framework migrations are only appended, never edited: `scripts/release` refuses to tag when a migration the last release shipped was edited or removed, or a new one sorts before it.
   - Latte's CA is never replaced silently.
   - `frappe doctor` reports a resolver, relay or plist that differs from the newest installed release's, with the command that replaces it. `install-local-integration status` compares them without sudo. `frappe doctor` asks the newest installed release, and prints `prepare` then `sudo … apply` when nothing is installed, or `prepare`, `sudo … uninstall` and `sudo … apply` to replace another release's integration, which `apply` alone refuses.
3. **Apps depend on the framework as a shard.**
   - Generated apps declare `caramel: github: caramelizedev/caramel, version: "~> X.Y.Z"`, and `shard.lock` pins the release, whose tag Shards checks out. `CARAMEL_REPOSITORY` substitutes a git repository for GitHub.
   - `vendor/caramel/`, `snapshot.json` and `.caramel-version` do not exist. Frappé reads the pinned version from `shard.lock`.
   - A checkout that is not a git checkout of its release tag without tracked changes (an unreleased checkout, or a source archive) generates apps with a `path:` dependency on itself. Untracked files, such as an app generated inside a release clone, do not make a release unreleased.
   - A release's framework changes only with `shard.lock`, which `frappe dev` watches. A `path:` dependency's sources are hashed into every build's fingerprint but not watched, so after editing that checkout, save an application file or restart `frappe dev`.
4. **Frappé installs the version a project pins.**
   - `frappe installations install VERSION` clones the tag into `~/Library/Application Support/Caramel/releases/<version>/`, installs its toolchain (reusing one with the same digest), builds it and registers it.
   - It builds a release with that release's own `scripts/build-release`, and with fixed steps for releases through 0.3.0, which have none. Installing a registered release again builds what it lacks, such as the linter, and `frappe doctor` names that command.
   - When a project pins a version that is not installed, `frappe` offers to install it on a terminal, or prints that command to agents and pipes.
   - `frappe installations register` remains for contributors' checkouts.
5. **One Latte: the newest installed.** On-demand start, the login item and the `~/.local/bin` launchers all run the newest installed release's Latte: `latte daemon` hands over to the newest installed release's built `latte`. Older releases' Frappé use it through the API window. A Frappé that needs a newer API than the running Latte names the release to install.
6. **Releases are cut by `scripts/release`, written in Crystal.**
   - It derives the next version from the Conventional Commits since the last tag. A fix is a patch and a feature is a minor; a breaking change is a minor during 0.x.
   - It writes `CHANGELOG.md` from those commits plus hand-written upgrade notes (`CHANGELOG.md` holds the Unreleased notes), sets the version in `shard.yml`, and creates an annotated tag only after the full check suite passes.
   - Pushing the tag and publishing the GitHub release stay manual.
7. **Releases are source-only until signing.** A release is a tag and its source archive; users build with `scripts/install-toolchain` and the build scripts, or with `frappe installations install`. Prebuilt, notarized binaries wait for an Apple Developer ID, before 1.0. They also need three things:
   - OpenSSL shipped beside the binaries with an `@executable_path`-relative rpath, or linked statically;
   - `SMAppService` for the login item and the port relay;
   - a signed release manifest that the Swift installer verifies with CryptoKit.
8. **Deprecate before removing.** Even in 0.x, a removal is preceded by one release that warns and names the replacement. `CONTRIBUTING.md` states the rule. A command carries `deprecated:` in the command table, and framework APIs use Crystal's `@[Deprecated]`. Support windows are published at 1.0.
9. **The version is visible to agents.** `frappe agent-manifest` prints `VERSION:` and `DOCS:` lines after its first line, and the documentation for each release is the tagged tree on GitHub.
10. **The generated app is thin.** The behaviour that was in the generated `src/<app>.cr` lives in the framework, so a framework upgrade upgrades it; the app's main is one call: `Caramel.run(App)` and `Corretto.configure(App)` replace the generated main, configuration and spec helper bodies, and `config/database.yml` does not exist because `Caramel::Database.url` knows Frappé's variables.
11. **Deferred: mechanical upgrades.** Publishing the diff between apps generated by consecutive releases, and a `frappe upgrade` command that applies what it can, are wanted eventually but not built.

## Reasons

- Rejected: copying the framework into each app, because Rails 2's `vendor/rails` copies were edited and drifted until Bundler and a lockfile replaced them.
- A project's pin should select, and if necessary fetch, its tools, as `bin/rails`, `artisan`, mix tasks and Go 1.21's `go.mod` toolchain line do.
- Generated code becomes code that users upgrade by hand (Laravel 11 cut its skeleton for this reason), so the generated app stays thin.
- A single local environment should be its own product and own its binaries: Laravel Herd does, and Valet broke when Homebrew upgraded its packages.
- Postgres.app keeps a data directory per PostgreSQL major version, and `pg_upgrade` needs the old and new binaries at once.
- A database is never lost across an upgrade, and the CA is never replaced silently.
- Rails and Django warn for at least one release before removing a feature.
- Native release tooling needs no Node or Python layer.
