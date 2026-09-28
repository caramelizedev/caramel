# ADR 0016: Versioning and releases

Date: 2026-09-28

Status: accepted. Everything the implementation order lists before `v0.1.0` is implemented; see Implementation. The parts it lists for before 1.0 and eventually remain.

## Context

Before this decision, Caramel had never been released:

- The version, `0.1.0`, was written twice: `Caramel::VERSION` in `src/caramel/version.cr` and `version:` in `shard.yml`. `Latte.app` separately said `1.0`.
- There were no tags and no changelog, and the public repository had no releases. Every binary, including the Swift installers, was built on the developer's machine.
- `frappe new` copied the whole framework into each app's `vendor/caramel/`, with `snapshot.json` to detect edits. The app's `shard.yml` depended on it with `path:`, and `.caramel-version` pinned the version exactly.
- Frappé refused a project pinned to another version and dispatched to the checkout registered for it in `installations.json`. That registration was manual, from a checkout.
- The generated `src/<app>.cr` was 94 lines of framework behaviour: argument parsing, database URL checks, `migrate`, `lint`, `drift`, `seed`, `serve`, Cold Brew start-up and signal handling. Every change to it had to be made by hand in every app.
- Several compatibility versions existed without being called that:
  - Latte's control API version was 1, and Frappé rejected any other.
  - Latte's registry, `installations.json` and toolchain receipts were all format version 1.
  - The PostgreSQL data directory was keyed by major version (`services/postgres/18`).
  - Cold Brew's migrations shipped with the framework.
  - The system integration (the relay binary, its launchd plist and the resolver) was identified by the digests of those files in its receipt.
  - A toolchain release was the digest of its pins, launchers and smoke program.
- Latte is one per user: one daemon, one PostgreSQL cluster, one CA, fixed ports and one relay. Several Caramel versions could be installed at once, and whichever `frappe` first needed Latte started its own `latte` ([ADR 0015](0015-local-setup-and-latte-lifecycle.md)).
- `bin/frappe` and `bin/latte` find OpenSSL through an absolute rpath into the builder's toolchain, so they cannot run on another machine. [ADR 0001](0001-managed-toolchain-provider.md) lists relocatable artifacts as an open gate.

## Decision

1. **One version for the repository.** The public repository `github.com/caramelizedev/caramel` tags releases `vX.Y.Z` (semantic versioning), with pre-releases `X.Y.Z-rc.N`, which are tagged by hand; `scripts/release` cuts final releases. During 0.x a minor release may break compatibility, and a patch release never does. The version is written only in `shard.yml`; `Caramel::VERSION` and `Latte.app`'s bundle version are generated from it at build time.
2. **Explicit compatibility contracts.** Each release keeps these promises:
   - Latte's control API is versioned. Latte serves a window of API versions, and each Frappé states the one it needs.
   - Latte's state formats migrate forward when Latte starts.
   - A PostgreSQL major bump ships a `pg_upgrade` step. The previous major's binaries are kept until that step has run.
   - Framework migrations are only appended, never edited.
   - Latte's CA is never replaced silently.
   - `frappe doctor` reports a resolver, relay or plist that differs from the newest installed release's, with the command that replaces it.
3. **Apps depend on the framework as a shard.**
   - Generated apps declare `caramel: github: caramelizedev/caramel, version: "~> X.Y.Z"`, and `shard.lock` pins the release, whose tag Shards checks out.
   - `vendor/caramel/`, `snapshot.json` and `.caramel-version` are removed. Frappé reads the pinned version from `shard.lock`.
   - A checkout that is not a git checkout of its release tag without tracked changes (an unreleased checkout, or a source archive) generates apps with a `path:` dependency on itself.
4. **Frappé installs the version a project pins.**
   - `frappe installations install VERSION` clones the tag into `~/Library/Application Support/Caramel/releases/<version>/`, installs its toolchain (reusing one with the same digest), builds it and registers it.
   - When a project pins a version that is not installed, `frappe` offers to install it on a terminal, or prints that command to agents and pipes.
   - `frappe installations register` remains for contributors' checkouts.
5. **One Latte: the newest installed.** On-demand start, the login item and the `~/.local/bin` launchers all run the newest installed release's Latte: an older `latte daemon` hands over to it. Older releases' Frappé use it through the API window. A Frappé that needs a newer API than the running Latte names the release to install.
6. **Releases are cut by `scripts/release`, written in Crystal.**
   - It derives the next version from the Conventional Commits since the last tag. A fix is a patch and a feature is a minor; a breaking change is a minor during 0.x.
   - It writes `CHANGELOG.md` from those commits plus hand-written upgrade notes, sets the version in `shard.yml`, and creates an annotated tag only after the full check suite passes.
   - Pushing the tag and publishing the GitHub release stay manual.
7. **Releases are source-only until signing.** A release is a tag and its source archive; users build with `scripts/install-toolchain` and the build scripts, or with `frappe installations install`. Prebuilt, notarized binaries wait for an Apple Developer ID, before 1.0. They also need three things:
   - OpenSSL shipped beside the binaries with an `@executable_path`-relative rpath, or linked statically;
   - `SMAppService` for the login item and the port relay;
   - a signed release manifest that the Swift installer verifies with CryptoKit.
8. **Deprecate before removing.** Even in 0.x, a removal is preceded by one release that warns and names the replacement. Support windows are published at 1.0.
9. **The version is visible to agents.** `frappe agent-manifest` states the version it describes, and the documentation for each release is the tagged tree on GitHub.
10. **The generated app is thin.** The behaviour in the generated `src/<app>.cr` moves into the framework, so a framework upgrade upgrades it; the app's main is one call.
11. **Deferred: mechanical upgrades.** Publishing the diff between apps generated by consecutive releases, and a `frappe upgrade` command that applies what it can, are wanted eventually but not built now.

## Reasons

Prior art from comparable ecosystems:

- Rails 2 copied Rails into each app (`rake rails:freeze:gems` into `vendor/rails`). Those copies were edited and drifted, and Rails 3 replaced them with Bundler and a lockfile. Caramel's `vendor/caramel/` and `snapshot.json` repeated that pattern.
- `bin/rails`, Laravel's `artisan` and Phoenix's mix tasks run the framework version from the app's own dependencies; only the project generator is global. Go 1.21 downloads the Go version a module names in `go.mod`, verified against its checksum database. A project's pin should select, and if necessary fetch, its tools.
- Laravel 11 cut its application skeleton down because generated code becomes code that users upgrade by hand.
- railsdiff.org and phoenixdiff.org publish the difference between generated apps across versions; `rails app:update`, Angular's `ng update` and Next.js codemods apply changes. Laravel leaves this to a paid service, Laravel Shift. It is worth having, but not before there are releases to diff.
- Laravel Herd is a signed, self-updating Mac app with its own PHP builds, released independently of the framework. Valet depended on Homebrew's packages, and Homebrew upgrades could break it. A single local environment should be its own product and own its binaries.
- Postgres.app keeps a data directory per PostgreSQL major version. Upgrading uses `pg_upgrade`, which needs the old and new binaries at the same time.
- Since macOS 13, signed apps register login items and privileged helpers with `SMAppService`, approved by the user in System Settings.
- Bun and Deno ship self-contained binaries with a built-in `upgrade`.
- Rails and Django warn about a feature for at least one release before removing it. Laravel publishes 18 months of bug fixes and 2 years of security fixes per major version.

Principles followed:

- Manifesto 4: never lose a database across an upgrade, and never replace the CA silently.
- Manifesto 6 and 7: stateless tools that know their version, and a first run and upgrades that work without manual steps.
- Manifesto 8: no framework ceremony copied into applications.
- Manifesto 3: native release tooling, with no Node or Python layer.

## Implementation order

1. Before the first release, `v0.1.0`, so that no released app ever carries a copied framework:
   - the single version source;
   - the thin application skeleton;
   - the compatibility contracts that need code now: Latte's version and API window, state-format refusal, the PostgreSQL major guard and the stale-relay report;
   - the shard dependency, replacing `vendor/caramel/` and `.caramel-version`;
   - the newest installed Latte, and `frappe installations install`;
   - the version in `frappe agent-manifest`;
   - `scripts/release`, `CHANGELOG.md` and the deprecation rule in the contributor docs.

   Both the shard dependency and `frappe installations install` are tested against a local git repository with a tag. Only the final smoke test needs the published tag: a fresh clone of `v0.1.0` generates an app that resolves `caramelizedev/caramel` from GitHub.
2. Before 1.0, with an Apple Developer ID: prebuilt, notarized binaries, relocatable OpenSSL, `SMAppService`, the signed release manifest and published support windows.
3. Eventually: mechanical upgrades.

## Verification

Each part is accepted by a check when it lands:

- The version source: `spec/native/version_spec.cr`, run by `scripts/check native`, requires `Caramel::VERSION`, `shard.yml` and the built `Latte.app`'s bundle versions to agree.
- The thin skeleton: `scripts/check frappe-project` and `scripts/check browser` run apps whose main is one call.
- The newest Latte: `spec/frappe/launchers_spec.cr` requires the launchers to choose the newest registered release, and `spec/latte/installed_releases_spec.cr` requires the choice that on-demand start and `latte daemon` make: the newest built release's `latte`, when it is newer.
- `scripts/release`: `spec/release/cut_spec.cr` cuts releases in a temporary repository with Conventional Commits and tags.
- The shard dependency: `scripts/check frappe-project` resolves the framework from a git source.
- `frappe installations install`: `scripts/check installations` installs a tag from a local repository.

## Implementation

Before `v0.1.0`:

- **Version source.** `Caramel::VERSION` reads `shard.yml` when the framework compiles (`src/caramel/version.cr`), and `scripts/build-latte-menu` writes `Latte.app`'s bundle versions from it.
- **Control API.** Latte serves the versions in `Latte::ControlAPI::VERSIONS`, reports its release and window in `/v1/status`, and answers any other version with `unsupported_api` and both. Frappé needs `LatteClient::API_VERSION` and names the release that fixes a mismatch. `latte version` prints the release and window. `scripts/check latte-daemon` asserts the status fields and `latte version` on a running daemon; `spec/latte/server_spec.cr` and `spec/frappe/latte_client_spec.cr` cover `unsupported_api` and Frappé's messages.
- **State formats.** Latte's registry, `installations.json` and the trust receipt refuse a newer format, naming the file and the format this release reads (`src/latte/state_format.cr`; `spec/latte/registry_spec.cr`, `spec/frappe/installations_spec.cr`). The Swift toolchain installer refuses a newer receipt the same way. Choosing which Latte runs is not refusing: when `installations.json` is unreadable there, this release's own Latte runs. Every format is still version 1, so no forward migration exists yet; the first new format adds one.
- **PostgreSQL.** The cluster lives in `services/postgres/<major>/data`. Latte refuses to start an empty cluster beside another major's data (`spec/latte/postgres_spec.cr`), as it already refused a cluster of another major.
- **Framework migrations.** `scripts/release` refuses to tag when a migration the last release shipped was edited or removed, or a new one sorts before it.
- **Relay.** `install-local-integration status` compares the installed resolver, relay and plist with the ones a release would install, without sudo (`spec/native/local_integration_spec.cr`). `frappe doctor` asks the newest installed release, and prints `prepare` then `sudo … apply` when nothing is installed, or `prepare`, `sudo … uninstall` and `sudo … apply` to replace another release's integration, which `apply` alone refuses.
- **Shard dependency and thin app.** Described under Decisions 3 and 10: `Caramel.run(App)` and `Corretto.configure(App)` replace the generated main, configuration and spec helper bodies, and `config/database.yml` is gone because `Caramel::Database.url` knows Frappé's variables. An unreleased checkout generates `path:` dependencies; untracked files, such as an app generated inside a release clone, do not make a release unreleased. `CARAMEL_REPOSITORY` substitutes a git repository for GitHub. A release's framework changes only with `shard.lock`, which `frappe dev` watches; a `path:` dependency's sources are hashed into every build's fingerprint but not watched, so after editing that checkout, save an application file or restart `frappe dev`.
- **Installs and the newest Latte.** Described under Decisions 4 and 5. `frappe installations install` reuses this toolchain when the release pins the same selection, and installs the release's own otherwise. `latte daemon` hands over to the newest installed release's built `latte`, so the login item and an older Frappé's on-demand start run the newest release.
- **Agents.** `frappe agent-manifest` prints `VERSION:` and `DOCS:` lines after its first line.
- **Deprecation.** `CONTRIBUTING.md` states the rule. A command carries `deprecated:` in the command table, and framework APIs use Crystal's `@[Deprecated]`.
- **Changelog.** `CHANGELOG.md` holds the Unreleased upgrade notes; `scripts/release` writes each release's section.

After `v0.1.0`:

- **Release builds.** `frappe installations install` builds a release with that release's own `scripts/build-release`, and with fixed steps for releases through 0.3.0, which have none, so a later release's build steps apply whichever frappe installs it. Installing a registered release again builds what it lacks, such as the linter a frappe older than 0.3.0 left out, and `frappe doctor` names that command (`scripts/check installations`).
- **PostgreSQL handover.** Latte adopts a postmaster that another toolchain's build of the major started on the cluster's directory, so a newer release's Latte takes over the running cluster; 0.1.0's Latte refuses it as unverified. The private PID file, owner, start time and data directory identify it (`spec/latte_integration/postgres_spec.cr`).
