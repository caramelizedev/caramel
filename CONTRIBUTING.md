# Contributing to Caramel

Caramel's decisions are recorded in [docs/decisions](docs/decisions). Read the one that governs a change before making it, and record a new decision when a change needs one.

## Build and check

On Apple Silicon with Apple's Command Line Tools:

```sh
scripts/install-toolchain
scripts/shards install --frozen
scripts/build-frappe && scripts/build-latte
scripts/check all
```

`scripts/check all` builds everything, runs the spec suite and every check in sequence, and keeps the full output of any failure in a log named on its FAIL line. Checks share one compiler cache, so never run two at once. Inside one step, compiles may run side by side: a type check (`--no-codegen`) creates no program cache directory and never runs the compiler's keep-10 cache cleanup, and `scripts/crystal build` marks its program's cache directory as used before compiling, so another build's cleanup keeps it. Keep full builds to two at a time to bound memory. `scripts/check NAME` runs one; the README lists what each needs. The browser check needs an unlocked screen and Safari's Allow Remote Automation. The Latte daemon check needs Latte's fixed ports, so stop your own Latte first (`frappe services stop`, then `latte stop`).

## Formatting and linting

Code follows Caramel's RFC-0008 rule set ([ADR 0017](docs/decisions/0017-formatting-and-linting.md)): `crystal tool format` for layout, and Ameba 1.7.0 plus `Caramel/ServiceNoun` for the rest. `scripts/check lint` builds `bin/frappe-lint` and lints the framework. `bin/frappe-lint --fix` applies Ameba's corrections, but review every one: some change behaviour, and ADR 0017 lists those that are not adopted. An inline `# ameba:disable Rule -- reason` goes on its own line above the code it covers and always names its reason.

## Style

The formatter owns layout, and the linter owns what it can check ([ADR 0017](docs/decisions/0017-formatting-and-linting.md), [ADR 0021](docs/decisions/0021-line-length.md)). The rest is judgment. It is written down here so that people and agents make the same calls. Code reads as short sentences, one thought each.

- **Keep lines short.** The framework's limit is 100 characters, and most lines should be well under it. When a line grows, name its parts instead of nesting them:

  ```crystal
  # A run-on sentence
  client.post("/api/notes", json: {title: "Tea", copies: 2}, headers: {"Accept" => "application/json", "X-CSRF-Token" => "forged"}).should have_status(403)

  # Named steps
  accept = {"Accept" => "application/json"}
  forged = accept.merge({"X-CSRF-Token" => "forged"})
  note = {title: "Tea", copies: 2}
  client.post("/api/notes", json: note, headers: forged).should have_status(403)
  ```

- **Stack what does not fit.** A long signature or call takes one argument per line, and a record is built with named arguments:

  ```crystal
  def initialize(@body : Body = Body::Form,
                 @limit : Int64 = DEFAULT_LIMIT,
                 @csrf : Bool = true,
                 @authenticate : String? = nil)
  ```

- **Return early.** Guard clauses keep the main path at the left margin:

  ```crystal
  return json({errors: errors}, status) if @context.wants_json?
  timestamp = request.headers["X-Timestamp"]? || return false
  ```

- **Name the steps.** A method that does three things calls three private methods named for what they do. Tables, limits and messages are named constants.
- **Write multi-line text as it reads.** JSON bodies, SQL, `.env` files and expected output are heredocs, not strings joined with `\n`.
- **Specs:**
  - name their inputs and expectations;
  - test one concern per example;
  - share setup through small helpers named for what they return, such as `signed(body)`.
- **Leave listed files better.** Under `Layout/LineLength`, `.ameba.yml` lists the files that predate the limit. Add no long line to them. When a change rewrites a listed file's long lines, remove it from the list in the same change.

## Commits

Commits follow [Conventional Commits](https://www.conventionalcommits.org/): `type(scope): subject`, where the type is one of `feat`, `fix`, `perf`, `refactor`, `docs`, `test`, `build`, `chore` or `style`, and the scope names a product such as `frappe`, `latte` or `lint`. Mark a breaking change with `!` after the type or scope, or with a `BREAKING CHANGE:` footer. `scripts/release` reads these to choose the next version and write the changelog.

## Releases

A release is a tag `vX.Y.Z` of this repository and its source archive ([ADR 0016](docs/decisions/0016-versioning-and-releases.md)). During 0.x a minor release may break compatibility and a patch release never does.

1. Write the upgrade notes a user needs under `## Unreleased` in `CHANGELOG.md`, and commit them.
2. Run `scripts/release --dry-run` to see the next version and its changelog section.
3. Run `scripts/release`. It refuses a dirty working tree and an edited released framework migration. It sets the version in `shard.yml`, which `Caramel::VERSION` and `Latte.app` read, and writes the changelog. It runs `scripts/check all`, then commits `chore(release): vX.Y.Z` and creates the annotated tag. When a check fails it restores both files and tags nothing.
4. Push and publish by hand, as it prints: `git push origin HEAD vX.Y.Z`, then `gh release create vX.Y.Z --verify-tag --title "Caramel X.Y.Z" --notes-from-tag`.

## Compatibility contracts

Each release keeps the contracts ADR 0016 lists. In practice:

- **Framework migrations** in `src/caramel/cold_brew/migrations.cr` are only appended. `scripts/release` refuses to tag when a migration an earlier release shipped was edited or removed, or when a new one sorts before it.
- **Latte's control API** is versioned in the path (`/v1/…`). Change it by adding a version to `Latte::ControlAPI::VERSIONS` and serving both, then have Frappé ask for the new one. Drop the old one in a later release.
- **State formats** (Latte's registry, `installations.json`, the trust receipt and toolchain receipts) carry a format version. A new format gets a new number and a forward migration in the reader. Older releases refuse the newer format, and nothing writes an older one.
- **PostgreSQL** keeps each major version's cluster in its own directory. A major bump must ship the `pg_upgrade` step and keep the previous binaries until it has run; until then Latte refuses another major's data.
- **Latte's certificate authority** is never replaced silently.
- **The port relay** and resolver belong to the newest installed release; `frappe doctor` names the command that updates them.

## Deprecation

Even in 0.x, remove nothing without warning first: one release keeps it working, warns when it is used and names the replacement, and a later release removes it. Say so in that release's upgrade notes.

- A command gets `deprecated: "Use frappe …"` in the command table (`src/frappe/commands.cr`). Invoking it prints a warning on stderr, and help and `frappe agent-manifest` show the replacement.
- A framework API gets Crystal's `@[Deprecated("Use …")]` annotation, so every application that calls it compiles with a warning that names the replacement.

## License

Contributions are released under the [MIT License](LICENSE).
