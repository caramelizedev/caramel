# ADR 0016: One version serves the repository, applications pin a release as a shard, and each release keeps stated compatibility promises

Date: 2026-09-28

Status: accepted.

## Context

Applications must be able to pin a Caramel release, upgrade it and keep several releases installed side by side. Latte is one per user: one daemon, one PostgreSQL cluster, one CA, one resolver and one relay, whatever the number of installed releases. A framework copied into each application, or a thick generated entry point, drifts from the release the application pins. Shards copies a repository's whole tagged tree into an application's `lib/`, and most of this repository is not what an application compiles. The binaries find OpenSSL through a path into the builder's toolchain, so they do not run on another machine ([ADR 0001](0001-toolchain-and-setup.md)).

## Decision

1. **One version serves the framework, Latte and the shard.** It follows semantic versioning and is written in one place, from which every other statement of it is generated. During 0.x a minor release may break compatibility; a patch release never does.
2. **Latte's control API is versioned, and each side names its window.** Latte serves a window of versions and each Frappé states the one version it needs. A mismatch is refused with the release that fixes it.
3. **Latte's state formats migrate forward, and a release refuses a newer format.** Choosing which Latte runs is not refusing: when the list of installations is unreadable, this release's own Latte runs.
4. **Each PostgreSQL major keeps its own cluster, and a major bump ships a `pg_upgrade` step.** The previous major's binaries stay until that step has run. Latte refuses to start an empty cluster beside another major's data.
5. **Framework migrations are only appended, never edited.** The release tool refuses to tag a release that breaks this.
6. **Latte's CA is never replaced silently.**
7. **The resolver, the relay and the login item's plist belong to the newest installed release.** `frappe doctor` reports one that differs. Replacing another release's integration is an explicit uninstall followed by an install, never an overwrite.
8. **An application depends on the framework as a shard, from the repository its release is published to.** Its lock pins the release's published commit, Frappé reads the pinned version from the lock, and nothing of the framework is copied into the application's own source. The framework an application runs changes only when its lock changes. A checkout that is not a clean release tag generates applications that depend on the checkout itself by path.
9. **A release publishes each shard as an assembled tree, to a repository nobody edits.** The framework's shard, and each library released with it, has a published repository that holds one tree for each release: only what an application installs, as one declaration selects it ([ADR 0014](0014-repository-and-writing.md)). Such a library names the framework by its published repository. Everything is written in this repository, and its tags are the releases.
10. **A published commit follows from its release's tag alone.** It has no parent, a fixed author, the tagged commit's date and a message that states only the shard and its version. Whoever has the tag computes the commit's id, and nothing records it.
11. **The gate tests what a release publishes.** The checks assemble the trees from the working tree, and every application they generate installs the framework, and a library where it uses one, from those trees with a lock that pins their commits.
12. **Every git dependency is locked to the commit its tag pointed at.** The rule covers the framework's own dependencies, a generated application's lock and the editor tools' dependencies (`site#c-releases-dependencies`).
13. **Frappé installs the version a project pins.** It fetches the release's tag and builds it with that release's own build script. When the pinned version is not installed, Frappé offers to install it on a terminal and prints the command to agents and pipes (`site#c-local-releases`).
14. **One Latte runs: the newest installed.** On-demand start, the login item and the launchers all run it ([ADR 0012](0012-latte.md)). Older releases' Frappé use it through the API window.
15. **A native tool cuts releases from the commit history.** It derives the next version from the Conventional Commits since the last tag and tags only after the full check suite passes. It prepares the tag's published commits and pushes nothing: pushing the published shards, then the tag, and publishing the release stay manual.
16. **Releases are source-only until signing.** A release is a tag and its source; users build it. Prebuilt, notarized binaries wait for an Apple Developer ID, before 1.0.
17. **A removal is deprecated first.** Even in 0.x, one release warns and names the replacement before the removal. A change whose warning cannot reach applications ships as a breaking change in a minor release without a deprecation release.
18. **The version is visible to agents.** The agent manifest states the release and where that release's documentation is.
19. **The generated application is thin.** Its main and its spec helper's configuration are one call each into the framework; the behaviour lives in the framework.
20. **An internal that a library outside the framework depends on is named and pinned.** Its doc comment says that such libraries depend on it, and a spec fails when it is renamed or reshaped.

## Reasons

- Rejected: copying the framework into each application. Rails 2's `vendor/rails` copies were edited and drifted until Bundler and a lockfile replaced them.
- Every file of a published tree is copied into every application, where its agents read and search it. The tools, the website, the specs and the records are most of this repository and none of what an application compiles.
- An assembled tree takes files from several directories and leaves their neighbours behind. A commit without a parent depends on no earlier publication, so any release is published, or published again, from its tag.
- An id that follows from the tag lets `frappe new` pin the published commit without the network, and lets anyone prove that a published repository holds what its tag assembles. A lock that pins the commit installs the same tree whatever a tag there points at later.
- A file the declaration leaves out fails the gate, not the first application that installs the release.
- The published shards are pushed before the tag, because an application generated from the tag installs them at once.
- Rejected: installing from this repository's whole tree. Every application copied the tools, the website, the specs and the records.
- Rejected: developing a library that is released with the framework in a repository of its own. A change to the framework and the change to the library that follows it would land in two repositories and pass two gates ([ADR 0030](sweettalk/0030-scope-and-modules.md) for SweetTalk).
- Rejected: a library that reaches the framework by a path into the application's `lib/caramel`. A fresh clone has no `lib/`, so its first install fails.
- Rejected: a subtree split of this repository. It publishes one directory with its history, and the framework's tree selects files from several directories.
- A project's pin selects, and if necessary fetches, its tools, as `bin/rails`, `artisan`, mix tasks and Go 1.21's `go.mod` toolchain line do.
- Generated code becomes code that users upgrade by hand; Laravel 11 cut its skeleton for this reason. With the behaviour in the framework, a framework upgrade upgrades the application.
- A single local environment is its own product and owns its binaries: Laravel Herd does, and Valet broke when Homebrew upgraded its packages.
- A database is never lost across an upgrade, and the CA is never replaced silently. Postgres.app keeps a data directory per PostgreSQL major, and `pg_upgrade` needs the old and new binaries at once.
- Rails and Django warn for at least one release before removing a feature.
- A library outside the framework's shard, as SweetTalk is ([ADR 0030](sweettalk/0030-scope-and-modules.md)), keeps reaching internals that no application calls. Unnamed, such an internal changes in a refactor and breaks the library in a release that promised no break. A doc comment tells the contributor before the change, and the spec fails after it.
- The release tool is native. Only the website check it runs needs Node, which the website's build already needs.
- Deferred: mechanical upgrades. Publishing the diff between applications generated by consecutive releases, and a command that applies what it can, are wanted but not built.
