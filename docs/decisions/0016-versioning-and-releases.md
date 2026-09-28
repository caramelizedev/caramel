# ADR 0016: Versioning and releases

Date: 2026-09-28

Status: accepted. Implementation is pending and follows the order below; each part cites its check when it lands.

## Context

Caramel has never been released:

- The version, `0.1.0`, is written twice: `Caramel::VERSION` in `src/caramel/version.cr` and `version:` in `shard.yml`. `Latte.app` separately says `1.0`.
- There are no tags, no changelog and no remote. Every binary, including the Swift installers, is built on the developer's machine.
- `frappe new` copies the whole framework into each app's `vendor/caramel/`, with `snapshot.json` to detect edits. The app's `shard.yml` depends on it with `path:`, and `.caramel-version` pins the version exactly.
- Frappé refuses a project pinned to another version and dispatches to the checkout registered for it in `installations.json`. That registration is manual, from a checkout.
- The generated `src/<app>.cr` is 94 lines of framework behaviour: argument parsing, database URL checks, `migrate`, `lint`, `drift`, `seed`, `serve`, Cold Brew start-up and signal handling. Every change to it has to be made by hand in every app.
- Several compatibility versions exist without being called that:
  - Latte's control API version is 1, and Frappé rejects any other.
  - Latte's registry, `installations.json` and toolchain receipts are all format version 1.
  - The PostgreSQL data directory is keyed by major version (`services/postgres/18`).
  - Cold Brew's migrations ship with the framework.
  - The system relay is identified by the digest of its launchd plist.
  - A toolchain release is the digest of its pins.
- Latte is one per user: one daemon, one PostgreSQL cluster, one CA, fixed ports and one relay. Several Caramel versions can be installed at once, and whichever `frappe` first needs Latte starts its own `latte` ([ADR 0015](0015-local-setup-and-latte-lifecycle.md)).
- `bin/frappe` and `bin/latte` find OpenSSL through an absolute rpath into the builder's toolchain, so they cannot run on another machine. [ADR 0001](0001-managed-toolchain-provider.md) lists relocatable artifacts as an open gate.

## Decision

1. **One version for the repository.** The public repository `github.com/caramelizedev/caramel` tags releases `vX.Y.Z` (semantic versioning), with pre-releases `X.Y.Z-rc.N`. During 0.x a minor release may break compatibility, and a patch release never does. The version is written only in `shard.yml`; `Caramel::VERSION` and `Latte.app`'s bundle version are generated from it at build time.
2. **Explicit compatibility contracts.** Each release keeps these promises:
   - Latte's control API is versioned. Latte serves a window of API versions, and each Frappé states the one it needs.
   - Latte's state formats migrate forward when Latte starts.
   - A PostgreSQL major bump ships a `pg_upgrade` step. The previous major's binaries are kept until that step has run.
   - Framework migrations are only appended, never edited.
   - Latte's CA is never replaced silently.
   - `frappe doctor` reports a relay whose plist digest is stale, with the command that updates it.
3. **Apps depend on the framework as a shard.**
   - Generated apps declare `caramel: github: caramelizedev/caramel, version: "~> X.Y.Z"`, and `shard.lock` pins the commit.
   - `vendor/caramel/`, `snapshot.json` and `.caramel-version` are removed. Frappé reads the pinned version from `shard.lock`.
   - An unreleased checkout generates apps with a `path:` dependency on itself.
4. **Frappé installs the version a project pins.**
   - `frappe installations install VERSION` clones the tag into `~/Library/Application Support/Caramel/releases/<version>/`, installs its toolchain (reusing one with the same digest), builds it and registers it.
   - When a project pins a version that is not installed, `frappe` offers to install it on a terminal, or prints that command to agents and pipes.
   - `frappe installations register` remains for contributors' checkouts.
5. **One Latte: the newest installed.** On-demand start, `latte service install` and the `~/.local/bin` launchers all use the newest installed release. Older releases' Frappé use it through the API window. A Frappé that needs a newer API than the running Latte names the release to install.
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

- Rails 2 copied Rails into each app (`rake rails:freeze:gems` into `vendor/rails`). Those copies were edited and drifted, and Rails 3 replaced them with Bundler and a lockfile. Caramel's `vendor/caramel/` and `snapshot.json` repeat that pattern.
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

1. Now, needing nothing outside the repository:
   - the single version source;
   - the thin application skeleton;
   - the newest installed Latte;
   - the version in `frappe agent-manifest`;
   - `scripts/release` and `CHANGELOG.md`;
   - the deprecation rule in the contributor docs.
2. Once `github.com/caramelizedev/caramel` exists and the first release is tagged:
   - the shard dependency, replacing `vendor/caramel/` and `.caramel-version`;
   - `frappe installations install`.
3. Before 1.0, with an Apple Developer ID: prebuilt, notarized binaries, relocatable OpenSSL, `SMAppService`, the signed release manifest and published support windows.
4. Eventually: mechanical upgrades.

## Verification

Each part is accepted by a check when it lands:

- The version source: a spec that `Caramel::VERSION`, `shard.yml` and `Latte.app`'s bundle version agree.
- The thin skeleton: `scripts/check frappe-project` and `scripts/check browser` run apps whose main is one call.
- The newest Latte: a spec that the launcher chooses the newest registered release.
- `scripts/release`: a spec over a temporary repository with Conventional Commits and tags.
- The shard dependency: `scripts/check frappe-project` resolves the framework from a git source.
- `frappe installations install`: a check that installs a tag from a local repository.
