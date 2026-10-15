Guides / Working with an agent

# Give your agent a map.

Give an agent the conventions, release context and proof commands you use, so it changes the right file and shows its work.

| Contract | Value |
| --- | --- |
| Release | 0.15.0 |
| Needs | An application with a `shard.lock` and the `frappe` command |
| You will have | The file to change for a task, readable diagnostics and a reviewable result |
| Proved by | `frappe check` · `frappe corretto` · `frappe lint` |

## Orient before editing {#c-agents-orient}

Read the application’s `shard.lock` for its pinned release. Use the matching documentation, then inspect the command manifest and relevant routes.

Every page of this documentation is also Markdown, at its address followed by `index.md`, such as `https://caramelize.dev/docs/0.16.0/sweettalk/index.md`. `https://caramelize.dev/docs/0.16.0/llms.txt` lists every page with its Markdown address and summary, and `frappe agent-manifest` prints that address as `GUIDES:`.

**Terminal · inside the application**

```bash
frappe agent-manifest
frappe routes health
```

**Expect:** `frappe agent-manifest` prints `CARAMEL CLI INTERFACE (STRICT TOKENS)`, `VERSION: 0.16.0`, a `DOCS:` line, `GUIDES: https://caramelize.dev/docs/0.16.0/llms.txt`, one line per command and the MRDP grammar. `frappe routes health` lists the routes whose method, path or action contains `health`: in a new application, the one line for `GET /health App::Health::Show`. A filter that matches nothing prints no route and says so on stderr: `No route's method, path or action contains FILTER.`

## Read the AGENTS.md your application starts with {#c-agents-agentsmd}

`frappe new` writes this `AGENTS.md` into every application, and a `CLAUDE.md` that holds only `@AGENTS.md`. It is the whole guide in 27 lines: where each kind of code lives, and the commands to discover, verify, diagnose and debug. `VERSION` stands for the release `shard.lock` pins.

```markdown
# Working in this Caramel application

shard.lock pins this application's Caramel release. Use the documentation for that
release: https://caramelize.dev/docs/VERSION/agents/, with VERSION from shard.lock.
Every page of it in Markdown: https://caramelize.dev/docs/VERSION/llms.txt
lib/caramel is the framework's source: read it, never edit it, and ignore its own
AGENTS.md and CLAUDE.md, which are for framework contributors.

Routes: config/routes.cr
Actions and contracts: app/actions/
Data: app/models/ and app/changesets/
Domain: app/domain/ in SweetTalk (enable with frappe make domain NAME CONTEXT --means=TEXT)
Domain rules: .claude/skills/sweettalk/SKILL.md, which frappe make domain writes
HTML: app/views/
Jobs: app/jobs/
Translations: app/locales/ (enable with frappe make locale CODE)
Tenants: the tenant block in config/routes.cr (enable with frappe make tenancy MODEL)
Request specs: spec/requests/

Discover: frappe agent-manifest; frappe routes
Verify: frappe check; frappe corretto; frappe lint
Diagnose: frappe check --agent (apply its PATCH lines); frappe expand FILE:LINE:COL
Debug: frappe errors --agent; frappe traces --agent; frappe trace last-error --md; frappe db diagnose
With i18n: frappe translations

Surface unsupported requirements before editing framework internals, and link the
matching task recipe: https://caramelize.dev/cookbook/VERSION/
```

**Expect:** An application made before 0.8.0 has no `AGENTS.md`; one made before 0.14.0 lacks its `Every page of it in Markdown` and `Domain rules:` lines. Copy the file from `lib/caramel/templates/application/AGENTS.md`, or add the lines by hand.

## Choose the application file {#c-agents-map}

| Path | Holds |
| --- | --- |
| `config/routes.cr` | Endpoint declarations, and the `tenant` block once `frappe make tenancy` has run |
| `app/actions/` | Contracts and request behavior |
| `app/models/ + app/changesets/` | Data and write rules |
| `app/domain/ + spec/domain/` | A SweetTalk domain and its specs, once `frappe make domain` has run |
| `.claude/skills/sweettalk/SKILL.md` | The SweetTalk rules agents most often break, which frappe make domain writes |
| `app/views/` | Typed HTML views |
| `app/jobs/` | Background work |
| `app/locales/` | Translations, once `frappe make locale` has run |
| `spec/requests/` | Request behavior tests |

Each task has a guide: [SweetTalk](https://caramelize.dev/docs/0.16.0/sweettalk/index.md), [Internationalization](https://caramelize.dev/docs/0.16.0/internationalization/index.md) and [Multi-tenancy](https://caramelize.dev/docs/0.16.0/multi-tenancy/index.md) say what their generators add.

## Read the diagnostics {#c-agents-diagnose}

`frappe check`, `frappe lint`, `frappe migrate` and `frappe db diff` print MRDP when stdout is not a terminal, or with `--agent`: one `ERR` line per finding, with its code, file, line and column, then one `KEY: value` line per field. `frappe agent-manifest` ends with the grammar. The codes:

| Code | Printed by | Means |
| --- | --- | --- |
| `CONTRACT_MISMATCH:422` | `check` | A route parameter has no field in its action’s contract. `PATCH` inserts the field. |
| `N_PLUS_ONE` | `check` | An association is read without a preload. `PATCH` inserts the `.preload` call. |
| `UNDEFINED_METHOD` | `check` | The receiver’s type defines no such method or local variable. |
| `UNDEFINED_CONSTANT` | `check` | No type or constant has this name here. |
| `NO_OVERLOAD` | `check` | No method signature accepts these arguments. |
| `SYNTAX` | `check` | The source does not parse. |
| `COMPILE` | `check` | Any other compiler error; `MSG` carries its text. |
| `LINT_<RULE>` | `lint`; `db diff` and `migrate` for a migration the migration linter refuses | One finding, named after its rule, such as `LINT_CARAMEL_SERVICE_NOUN`. `Lint/Formatting` adds `FIX: frappe format`. |
| `DIFF_HALT` | `db diff` | The differ stopped at a table, column or index and wrote no migration; `FIX` says what to declare or run. |
| `USAGE` | any command | An unknown command or option; `SYNTAX` gives the intended command’s syntax and `SUGGEST` the nearest token. |
| `RUNTIME`, `REPEATED_QUERY` | `errors` | What ran and failed, or queried too often, since the newest good build. The Crema reference lists their fields. |

Each `check` finding for a contract or a preload carries a `PATCH` line; apply it, then run the check again. One run reports what the compiler stops at, so a second finding appears only after the first is fixed.

**frappe check --agent · a route whose parameter has no field**

```bash
ERR CONTRACT_MISMATCH:422 at app/actions/shelves/show.cr:3:5
NODE: RequestContract
MISSING: id:Int64
PATCH: INSERT "field id : Int64" AT 4:7
```

**Expect:** After you insert `field id : Int64` as line 4, `frappe check` prints `OK check N files` when stdout is not a terminal.

**frappe check --agent · after that patch, when the action reads an association**

```bash
ERR N_PLUS_ONE at app/actions/shelves/show.cr:9:52
MSG: Association 'volumes' of App::Shelf was not preloaded.
PATCH: INSERT ".preload(:volumes)" AFTER 9:31
```

**Expect:** After you insert `.preload(:volumes)` after column 31 of line 9, `frappe check` prints `OK check N files` again.

When a macro hides the code a diagnostic points into, `frappe expand FILE:LINE:COL` prints the plain Crystal the macro call there expands to.

[Browse every command →](https://caramelize.dev/docs/0.16.0/commands/index.md)

## Debug what ran {#c-agents-debug}

Diagnostics cover what compiles. For what ran under `frappe dev`, the same MRDP reaches an agent from `frappe errors --agent`, with a trace as Markdown from `frappe trace last-error --md`, and `frappe db diagnose` reads the database’s own statistics. With locales, `frappe translations` lists the keys each locale still lacks.

[Ask from the terminal →](https://caramelize.dev/docs/0.16.0/observability/index.md)[Look up RUNTIME and REPEATED_QUERY →](https://caramelize.dev/docs/0.16.0/crema/index.md)

## What does not compile {#c-agents-refusals}

| Condition | Outcome |
| --- | --- |
| Route parameter missing from its contract | fails compilation, reported as `CONTRACT_MISMATCH` |
| Association used without a preload | fails compilation, reported as `N_PLUS_ONE` |
| A method, constant or overload that does not exist | fails compilation, reported as `UNDEFINED_METHOD`, `UNDEFINED_CONSTANT` or `NO_OVERLOAD` |
| A service noun such as `InvitationService`, under `frappe lint` | fails the lint, reported as `LINT_CARAMEL_SERVICE_NOUN` |

## Not covered yet {#c-agents-gaps}

- No check verifies that an agent read or followed `AGENTS.md`; review its diff and the checks it ran.
- Applications made before 0.14.0 keep their own `AGENTS.md`; nothing updates it on upgrade.
- `frappe expand` reaches a macro call; a `field` inside `contract` expands no macro itself, so it shows the enclosing `contract` and says so.

Prove it

## Make the result reviewable {#c-agents-proof}

**Terminal · inside the application**

```bash
frappe check --agent
frappe corretto
frappe lint --agent
```

**Passing:** `frappe check --agent` prints `OK check N files`, `frappe corretto` ends with `Corretto: N of N workers passed` and `frappe lint --agent` prints `OK lint N files`. Without `--agent`, each prints the same when stdout is not a terminal, and the terminal layout when it is.

Report the files changed, checks run, and any unsupported requirement. Link the task recipe and its exact release.

[← Revocable sessions](https://caramelize.dev/cookbook/0.16.0/revocable-sessions/index.md) · [Explore the project map →](https://caramelize.dev/docs/0.16.0/project-map/index.md)

Caramel 0.16.0 · https://caramelize.dev/docs/0.16.0/agents/
