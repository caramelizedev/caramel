# Contributing to Caramel

Caramel's decisions are recorded in [docs/decisions](docs/decisions). Read the one that governs a change before making it, and record a new decision when a change needs one.

## Build and check

On Apple Silicon with Apple's Command Line Tools (including `cc` and `ar` for
Corretto's Lexbor parser):

```sh
scripts/install-toolchain
scripts/shards install --frozen
scripts/build-frappe && scripts/build-latte
scripts/check all
```

`scripts/check all` builds everything, then runs the spec suite and every check in three lanes side by side ([ADR 0022](docs/decisions/0022-parallel-check-lanes.md)), and keeps the full output of any failure in a log named on its FAIL line. Each lane beyond the first uses its own toolchain prefix, `lanes/lane-N` inside the toolchain, with its own compiler caches. Three lanes' compilers peaked at about 6 GB; on a machine with less memory, `--lanes 1` runs everything in turn. Outside `check all` the checks share one compiler cache, so never run two `scripts/check` at once. Inside one step, compiles may run side by side: a type check (`--no-codegen`) creates no program cache directory and never runs the compiler's keep-10 cache cleanup, and `scripts/crystal build` marks its program's cache directory as used before compiling, so another build's cleanup keeps it. Keep a lane's full builds to two at a time to bound memory. `scripts/check NAME` runs one, and `scripts/check` alone lists them. The browser check needs an unlocked screen and Safari's Allow Remote Automation. The Latte daemon check needs Latte's fixed ports, so stop your own Latte first: run `frappe services stop`, wait until `frappe services` shows every service stopped, then run `latte stop`.

What the checks need:

- Every command uses the pinned managed tools; none falls back to a Crystal or Shards on `PATH`. `scripts/install-toolchain` installs into `~/Library/Application Support/Caramel/toolchains/` and records the location in this checkout's `.caramel-toolchain`, which every command and check reads. `--root <dir>` installs elsewhere, and `CARAMEL_TOOLCHAIN_ROOT` overrides the recorded location. The selection and lockfile live in `tools/toolchain/`.
- `integration` creates and cleans up its own database cluster. It never uses an existing application database or changes system DNS or certificate trust. No check runs the system integration installer or `latte trust install`; those are separate, explicit operations.
- The Latte checks (`latte-ipc`, `latte-postgres`, `latte-network`, `latte-daemon`, `native`) also need the pinned CoreDNS artifact (`scripts/install-latte-tools --help`) and the macOS Swift compiler. Run `scripts/build-latte` and `scripts/build-frappe` before the checks that use them.
- `latte-daemon` runs the real `bin/latte daemon` on Latte's fixed ports: DNS 15353 and HTTP/HTTPS 18080/18443.
- `browser` drives Safari through `safaridriver` against a generated app on an isolated Latte stack; enable Safari's "Allow Remote Automation" once with `safaridriver --enable`.
- `scripts/check all --except NAME` skips a check, for example `--except latte-daemon` while your own Latte holds its ports. It runs `frappe-project` once, as `frappe-project-dev`, because the `--dev` run covers every step of the plain flow.

Editor tools: build Frappé first (`scripts/build-frappe`), then run `bin/frappe lsp install`; the repo's `.zed/settings.json` runs `bin/frappe lsp …`, so trust the worktree when Zed asks. `scripts/check editor-tools` verifies them.

## Formatting and linting

Code follows Caramel's rule set ([ADR 0017](docs/decisions/0017-formatting-and-linting.md)): `crystal tool format` for layout, and Ameba 1.7.0 plus `Caramel/ServiceNoun` for the rest. `scripts/check lint` builds `bin/frappe-lint` and lints the framework. `bin/frappe-lint --fix` applies Ameba's corrections, but review every one: some change behaviour, and ADR 0017 lists those that are not adopted. An inline `# ameba:disable Rule -- reason` goes on its own line above the code it covers and always names its reason.

## Style

The formatter owns layout, and the linter owns what it can check ([ADR 0017](docs/decisions/0017-formatting-and-linting.md), [ADR 0021](docs/decisions/0021-line-length.md)). The rest is judgment. It is written down here so that people and agents make the same calls. Code reads as short sentences, one thought each.

- **Keep lines short.** The framework's limit is 100 characters for every file, with no exclusions or inline disables, and most lines should be well under it. When a line grows, name its parts instead of nesting them:

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
- **No service nouns.** `…Service`, `…Manager`, `…Factory` and the like hold a verb that belongs on its subject: a method on the model, a changeset or a job.
- **Specs:**
  - name their inputs and expectations;
  - test one concern per example;
  - share setup through small helpers named for what they return, such as `signed(body)`.
- **Templates read as the code they generate.** Resource templates mark optional code with whole lines: `# frappe:only a,b`, `# frappe:unless a,b`, `# frappe:else` and `# frappe:end`. They never tag the end of a code line.

## Writing

Every piece of writing has one home, chosen by what it is ([ADR 0026](docs/decisions/0026-writing-homes.md)):

- What application authors need: the website (`website/source/site.html`). API detail
  goes in doc comments at the code.
- What contributors must do: this file.
- A decision: an ADR in `docs/decisions` with Context (optional, the problem), Decision
  (the rules in force, present tense) and Reasons (why, and what was rejected). When a
  change alters a decision, edit its ADR in the same commit.
- Status, measurements, investigations, incident timelines and history: not this
  repository. Use [caramel-notes](https://github.com/caramelizedev/caramel-notes), the
  pull request description or the CHANGELOG.

State a fact once and link to it. `scripts/check prose` checks where markdown lives,
the ADR sections, relative links and each file's size.

## Principles

Decisions follow these principles:

1. One machine is enough: a compiled binary and PostgreSQL, without premature distribution.
2. State lives in PostgreSQL and in server-rendered HTML that htmx morphs.
3. Nothing hides the machine: native processes and Unix sockets, no containers in development.
4. Data integrity comes first: schema changes are branched and verified before they touch data.
5. No mocks: specs exercise real PostgreSQL and real rendered HTML.
6. Agents get stateless command-line tools with compact diagnostics, not daemons.
7. Compile-time macros, not runtime reflection, with fast repair loops.
8. Code reads like short sentences, without ceremonial plumbing.

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
