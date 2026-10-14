Guides / Working with an agent

# Give your agent a map.

The same conventions, release context, and proof commands that make Caramel easier for a person to learn.

Application guide · Target: 0.14.0

| Contract | Value |
| --- | --- |
| Release | 0.14.0 |
| Needs | An application with a `shard.lock` and the `frappe` command |
| You will have | The file to change for a task, readable diagnostics and a reviewable result |
| Proved by | `frappe check` · `frappe corretto` · `frappe lint` |

## Orient before editing {#c-agent-orient}

Read the application’s `shard.lock` for its pinned release. Use the matching documentation, then inspect the command manifest and relevant routes.

Every page of this documentation is also Markdown, at its address followed by `index.md`, such as `https://caramelize.dev/docs/0.14.0/sweettalk/index.md`. `https://caramelize.dev/docs/0.14.0/llms.txt` lists every page with its Markdown address and summary, and `frappe agent-manifest` prints that address as `GUIDES:`.

**Terminal**

```bash
frappe agent-manifest
frappe routes books
```

**Expect:** `frappe agent-manifest` prints the command list, the diagnostic grammar and a line `GUIDES: https://caramelize.dev/docs/0.14.0/llms.txt`. `frappe routes books` lists the routes whose method, path or action contains `books`.

## Choose the application file {#c-agent-map}

| Path | Holds |
| --- | --- |
| `config/routes.cr` | Endpoint declarations |
| `app/actions/` | Contracts and request behavior |
| `app/models/ + app/changesets/` | Data and write rules |
| `app/domain/ + spec/domain/` | A SweetTalk domain and its specs |
| `.claude/skills/sweettalk/SKILL.md` | The SweetTalk rules agents most often break, which frappe make domain writes |
| `app/views/` | Typed HTML views |
| `app/jobs/` | Background work |
| `spec/requests/` | Request behavior tests |

## Read the diagnostics {#c-agent-diagnose}

`frappe check`, `frappe lint`, `frappe migrate` and `frappe db diff` print MRDP when stdout is not a terminal, or with `--agent`: one finding per block, with its file, line and column.

| Condition | Outcome |
| --- | --- |
| Route parameter missing from its contract | fails compilation, reported as `CONTRACT_MISMATCH` |
| Association used without a preload | fails compilation, reported as `N_PLUS_ONE` |

Each finding carries a `PATCH` line; apply it, then run the check again.

**frappe check --agent · two findings**

```bash
ERR CONTRACT_MISMATCH:422 at app/actions/shelves/show.cr:3:5
NODE: RequestContract
MISSING: id:Int64
PATCH: INSERT "field id : Int64" AT 4:7
ERR N_PLUS_ONE at app/actions/shelves/show.cr:9:52
MSG: Association 'volumes' of App::Shelf was not preloaded.
PATCH: INSERT ".preload(:volumes)" AFTER 9:31
```

**Expect:** After you apply each `PATCH` line, `frappe check` prints `OK check N files` when stdout is not a terminal.

When a macro hides the code a diagnostic points into, `frappe expand FILE:LINE:COL` prints the plain Crystal that the macro call there expands to, such as `Caramel::Router.draw` or a `contract` block. Aimed at a `field` inside `contract`, which no expansion reaches by itself, it prints the `contract` expansion up to the step that expands the field and names the call it used.

[Browse every command →](https://caramelize.dev/docs/0.14.0/commands/index.md)

Prove it

## Make the result reviewable {#c-agent-proof}

**Terminal**

```bash
frappe check
frappe corretto
frappe lint
```

**Passing:** `frappe check` prints `OK check N files` when stdout is not a terminal (`✓ Type check passed` on one), `frappe corretto` ends with `Corretto: N of N workers passed` and `frappe lint` prints `OK lint N files` with `--agent`.

Report the files changed, checks run, and any unsupported requirement. Link the task recipe and its exact release. Treat framework-source edits as a signal that the extension path needs review.

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

[← Revocable sessions](https://caramelize.dev/cookbook/0.14.0/revocable-sessions/index.md) · [Explore the project map →](https://caramelize.dev/docs/0.14.0/project-map/index.md)

Caramel 0.14.0 · https://caramelize.dev/docs/0.14.0/agents/
