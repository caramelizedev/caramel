# ADR 0016: One version serves the repository, applications pin a release as a shard, and each release keeps stated compatibility promises

Date: 2026-09-28

Status: accepted.

## Context

Applications must be able to pin a Caramel release, upgrade it and keep several releases installed side by side. Latte is one per user: one daemon, one PostgreSQL cluster, one CA, one resolver and one relay, whatever the number of installed releases. A framework copied into each application, or a thick generated entry point, drifts from the release the application pins. The binaries find OpenSSL through a path into the builder's toolchain, so they do not run on another machine ([ADR 0001](0001-toolchain-and-setup.md)).

## Decision

1. **One version serves the framework, Latte and the shard.** It follows semantic versioning and is written in one place, from which every other statement of it is generated. During 0.x a minor release may break compatibility; a patch release never does.
2. **Latte's control API is versioned, and each side names its window.** Latte serves a window of versions and each Frappé states the one version it needs. A mismatch is refused with the release that fixes it.
3. **Latte's state formats migrate forward, and a release refuses a newer format.** Choosing which Latte runs is not refusing: when the list of installations is unreadable, this release's own Latte runs.
4. **Each PostgreSQL major keeps its own cluster, and a major bump ships a `pg_upgrade` step.** The previous major's binaries stay until that step has run. Latte refuses to start an empty cluster beside another major's data.
5. **Framework migrations are only appended, never edited.** The release tool refuses to tag a release that breaks this.
6. **Latte's CA is never replaced silently.**
7. **The resolver, the relay and the login item's plist belong to the newest installed release.** `frappe doctor` reports one that differs. Replacing another release's integration is an explicit uninstall followed by an install, never an overwrite.
8. **An application depends on the framework as a shard.** Its lock pins the release, Frappé reads the pinned version from the lock, and nothing of the framework is copied into the application. The framework an application runs changes only when its lock changes. A checkout that is not a clean release tag generates applications that depend on the checkout itself by path.
9. **Every git dependency is locked to the commit its tag pointed at.** The rule covers the framework's own dependencies, a generated application's lock and the editor tools' dependencies (`site#c-releases-dependencies`).
10. **Frappé installs the version a project pins.** It fetches the release's tag and builds it with that release's own build script. When the pinned version is not installed, Frappé offers to install it on a terminal and prints the command to agents and pipes (`site#c-local-releases`).
11. **One Latte runs: the newest installed.** On-demand start, the login item and the launchers all run it ([ADR 0012](0012-latte.md)). Older releases' Frappé use it through the API window.
12. **A native tool cuts releases from the commit history.** It derives the next version from the Conventional Commits since the last tag and tags only after the full check suite passes. Pushing the tag and publishing the release stay manual.
13. **Releases are source-only until signing.** A release is a tag and its source; users build it. Prebuilt, notarized binaries wait for an Apple Developer ID, before 1.0.
14. **A removal is deprecated first.** Even in 0.x, one release warns and names the replacement before the removal. A change whose warning cannot reach applications ships as a breaking change in a minor release without a deprecation release.
15. **The version is visible to agents.** The agent manifest states the release and where that release's documentation is.
16. **The generated application is thin.** Its main and its spec helper's configuration are one call each into the framework; the behaviour lives in the framework.

## Reasons

- Rejected: copying the framework into each application. Rails 2's `vendor/rails` copies were edited and drifted until Bundler and a lockfile replaced them.
- A project's pin selects, and if necessary fetches, its tools, as `bin/rails`, `artisan`, mix tasks and Go 1.21's `go.mod` toolchain line do.
- Generated code becomes code that users upgrade by hand; Laravel 11 cut its skeleton for this reason. With the behaviour in the framework, a framework upgrade upgrades the application.
- A single local environment is its own product and owns its binaries: Laravel Herd does, and Valet broke when Homebrew upgraded its packages.
- A database is never lost across an upgrade, and the CA is never replaced silently. Postgres.app keeps a data directory per PostgreSQL major, and `pg_upgrade` needs the old and new binaries at once.
- Rails and Django warn for at least one release before removing a feature.
- The release tool is native. Only the website check it runs needs Node, which the website's build already needs.
- Deferred: mechanical upgrades. Publishing the diff between applications generated by consecutive releases, and a command that applies what it can, are wanted but not built.
