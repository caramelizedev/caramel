Reference / Commands

# Every command, in one place.

Frappé, your application’s binary, and Latte, listed from the source of Caramel 0.15.0.

| Contract | Value |
| --- | --- |
| Release | 0.15.0 |
| Needs | An application folder, except commands marked as working anywhere |
| Covers | Frappé, your application’s binary, Latte |
| Proved by | `frappe COMMAND --help` |

Learning it for the first time? [Your first application](https://caramelize.dev/docs/0.17.0/getting-started/index.md) runs the everyday commands in order. This page lists every command.

## Limits at a glance {#c-commands-limits}

| Limit | Value |
| --- | --- |
| Exit status | 0 success, 1 failure, 2 usage error (application binary and Latte) |
| `frappe corretto --concurrency` | 1–8 |
| `frappe db branch create NAME` | a lowercase letter, then up to 30 lowercase letters, digits or underscores |
| `frappe traces --limit` default | 20 |
| `frappe logs` lines | 200 |

## Frappé runs the release your application pins {#c-commands-frappe}

| Condition | Outcome |
| --- | --- |
| A command marked “Works outside an application” | works anywhere |
| Every other command | runs inside an application folder |
| An application whose `shard.lock` pins a Caramel release | Frappé runs that release’s commands for it |
| `frappe COMMAND --help` | prints one command’s syntax |
| `frappe agent-manifest` | prints the whole list with the diagnostic grammar for agents |

- `frappe help`: Print every command with its description. Works outside an application.
- `frappe version`: Print the Frappé version. Works outside an application.
- `frappe agent-manifest`: Print the release's version and the addresses of its documentation and guides, this strict command list and the MRDP diagnostic grammar for coding agents. Works outside an application.
- `frappe new NAME`: Create the application ./NAME, install its locked dependencies and register it with Latte. Works outside an application.
- `frappe setup [--no-migrate]`: Install locked dependencies, register this project with Latte and apply pending migrations to the development database, preserving existing files; --no-migrate leaves the database unchanged.
- `frappe dev [--no-open] [--branch NAME]`: Build, serve and reload the app at its HTTPS origin; --branch runs it against database branch NAME.
- `frappe check [--agent|--human]`: Run the Tier-1 type check (crystal build --no-codegen) and report diagnostics; MRDP unless stdout is a TTY.
- `frappe lint [--agent|--human]`: Check the application against Caramel's rule set in .ameba.yml; MRDP unless stdout is a TTY.
- `frappe format`: Format the application's Crystal files with the pinned compiler's formatter.
- `frappe routes [FILTER]`: List routes with their contracts; FILTER keeps routes whose method, path or action contains it (any case).
- `frappe expand FILE:LINE:COL`: Print the plain Crystal that the macro call at FILE:LINE:COL expands to; where none expands, the call whose block encloses it, such as `contract` for a `field`, and say which.
- `frappe make resource NAME FIELD:TYPE... [--plural=NAME] [--only=ACTIONS] [--central]`: Generate a SugarORM schema, migration, actions, views, routes and specs; FIELD:TYPE:server marks a field the server sets, kept out of forms and contracts, :unique adds a unique index and changeset constraint, and :url validates an http or https URL entered in a URL input. --only=create,show,index,new keeps the listed actions of index, show, new, create, edit, update and destroy; create and show are required, and edit needs new and update. In a multi-tenant application a resource belongs to the tenant unless --central is given.
- `frappe make locale CODE`: Add the locale CODE, such as fr or pt-BR: create app/locales/CODE.cr; on first use also app/locales/en.cr and the i18n lines in config/application.cr, after which frappe make resource writes translated views.
- `frappe make tenancy MODEL`: Make the application multi-tenant with MODEL, such as Account, as the tenant: its schema, migration, sign-up page at /PLURAL/new and home at /SLUG, require "caramel/tenancy" and the tenant block in config/routes.cr; frappe make resource then writes resources that belong to a tenant.
- `frappe make domain NAME CONTEXT --means=TEXT [--central]`: Start a SweetTalk domain: app/domain/NAME.cr with its first context CONTEXT, which means TEXT, and spec/domain/NAME_spec.cr; on first use also require "caramel/sweet_talk" and require "../app/domain/*" in config/application.cr. When the application has no SweetTalk skill for agents, it also writes .claude/skills/sweettalk/SKILL.md. In a multi-tenant application the domain names the tenant, and --central makes the context one every tenant shares.
- `frappe translations`: List the keys each locale still takes from the default locale; exits 1 while any is missing.
- `frappe migrate [--dev-override] [--agent|--human]`: Lint and apply pending migrations, then report schema drift read-only.
- `frappe seed`: Load db/seeds.cr into the development database.
- `frappe build`: Build the Linux release artifact in a container: a static linux/amd64 binary and public/ in .caramel/build/; refuses uncommitted changes and prints the artifact's path.
- `frappe corretto [SPEC_PATHS...] [--concurrency=1..8]`: Run specs in isolated Latte test databases with synchronous queue drains.
- `frappe db dump`: Save a backup of the development database.
- `frappe db restore FILE`: Restore the development database from FILE after a safety backup.
- `frappe db diff --name NAME [--dev-override] [--agent|--human]`: Derive migrations from the declared schema and prove them on a scratch branch.
- `frappe db branch create NAME`: Clone the development database into branch NAME and print its connection URL.
- `frappe db branch list`: List this project's database branches.
- `frappe db branch delete NAME`: Drop database branch NAME.
- `frappe db diagnose`: Report database health: connections, locks, cache hits, unused indexes and the slowest statements.
- `frappe logs [app|compiler|access] [--follow]`: Show the development app or compiler log, or Caddy's access log.
- `frappe traces [--errors] [--slow=MS] [--limit=N] [--agent|--human]`: List the development session's recent requests, jobs and schedule runs, newest first.
- `frappe trace REF [--md]`: Show one development trace: its summary, queries, logs and error. REF is last, last-error, or a prefix of a trace id, a request id or an error fingerprint.
- `frappe errors [--agent|--human]`: List development runtime errors and repeated queries, grouped.
- `frappe services [status|start|stop]`: Show, start or stop Latte's PostgreSQL, DNS and HTTPS services. Works outside an application.
- `frappe sites`: List the sites registered with Latte. Works outside an application.
- `frappe sites remove NAME`: Unregister site NAME, keeping its files, databases, credentials, logs and backups. Works outside an application.
- `frappe installations [list]`: List the Caramel releases installed on this Mac. Works outside an application.
- `frappe installations install VERSION`: Clone, build and register the tagged release VERSION, reusing this toolchain when the release pins the same one; if VERSION is installed, build what it lacks, such as its linter. Works outside an application.
- `frappe installations register`: Register this checkout for projects pinned to its version; ~/.local/bin/frappe and latte run the newest installed release. Works outside an application.
- `frappe installations remove VERSION`: Forget the installation registered for VERSION; the launchers move to the newest remaining release. Works outside an application.
- `frappe doctor`: Check the toolchain, this Caramel installation, dependencies, local configuration, Latte services, trusted HTTPS and the port relay.
- `frappe open`: Open the application's HTTPS origin in the browser; while frappe dev runs, a single-use link signs the browser in to the toolbar and inspector.
- `frappe lsp crystalline|ameba-ls [SERVER_ARGS...]`: Run a pinned language server for this project on stdio.
- `frappe lsp install`: Build the pinned language servers. Works outside an application.

## Diagnostics follow where stdout goes {#c-commands-output}

| Condition | Outcome |
| --- | --- |
| `check`, `lint`, `migrate`, `db diff`, `traces` or `errors` when stdout is not a terminal | prints MRDP diagnostics |
| `--agent` | prints MRDP diagnostics |
| `--human` | prints the terminal layout |
| A mistyped command or option on a terminal | exits 1 with `frappe migrte: unknown command migrte`, the intended command’s `Usage:` line and `Did you mean migrate?` |
| A mistyped command or option when stdout is not a terminal, or with `--agent` | exits 1 with one MRDP `USAGE` block: `MSG`, `SYNTAX` and `SUGGEST` |
| `frappe corretto --concurrency` outside 1 to 8 | refuses |
| `frappe db branch create NAME` that is not a lowercase letter followed by up to 30 lowercase letters, digits or underscores | exits 1 with `branch name NAME must be a lowercase letter followed by up to 30 lowercase letters, digits or underscores` |
| `frappe traces` without `--limit` | prints at most 20 traces |
| `frappe logs` | prints the last 200 lines |

[Read diagnostics as an agent →](https://caramelize.dev/docs/0.17.0/agents/index.md)

## The application binary takes its own commands {#c-commands-app}

Each application compiles to one binary whose main is `Caramel.run(App)`; below, `APP` stands for it. Frappé runs these commands for you: `frappe dev` serves, `frappe routes`, `frappe seed`, `frappe migrate` and `frappe translations` run the commands of the same name, `frappe db diff` runs `schema`, `frappe db diagnose` runs `db diagnose` and `frappe corretto` runs `migrate` on the spec database. `frappe build` compiles the same binary for Linux in a container, so it needs a container engine such as Docker Desktop. `serve` and `work` are the two process roles. `ops`, `jobs`, `db diagnose` and `insights` belong to Crema, which also lets your application add commands of its own.

| Condition | Outcome |
| --- | --- |
| Any binary command | exits 0 on success, 1 on failure, 2 on a usage error |
| `serve` or `work` with pending migrations | stops with `Pending migrations. Run frappe migrate first.` |

- `APP serve [--no-workers]`: Serve HTTP on the private socket CARAMEL_SOCKET names, with Cold Brew’s workers, maintenance and schedules; --no-workers keeps the PubSub broker and maintenance but runs no workers or schedules, for a deployment that runs work separately. CARAMEL_ROOT, when set, names the directory whose public/ it serves. Refuses to start with pending migrations.
- `APP work [--queues=NAMES] [--concurrency=N] [--no-scheduler]`: Run Cold Brew’s workers, maintenance and schedules without HTTP. --queues and --concurrency replace CARAMEL_WORKER_QUEUES and CARAMEL_WORKER_CONCURRENCY; --no-scheduler leaves schedules to other processes.
- `APP seed`: Load db/seeds.cr into the database.
- `APP routes`: Print every route with its action, contract and ingress.
- `APP schema`: Print the declared schema as JSON.
- `APP drift`: Compare the database with the declared schema; exits 1 when they differ.
- `APP translations`: List the keys each locale still takes from the default locale; exits 1 while any is missing.
- `APP migrate [--dev-override]`: Lint and apply pending migrations; --dev-override relaxes the linter in development.
- `APP lint [--dev-override]`: Lint pending migrations without applying them; --dev-override relaxes the linter in development.
- `APP ops status|requests|fibers|metrics|tail|errors|error|traces|trace|debug-token|console [--socket=PATH]`: Ask a running application, through its owner-only ops socket, for its status, in-flight work, Prometheus text, a live tail, errors and traces; issue a debug token; print the console’s ssh line and URL. Details are in the Crema reference.
- `APP jobs [stats|failed|show ID|retry ID|--class=NAME|unknown]`: Count each queue’s jobs, list failures, show one job with its stored error, or retry failed jobs. Needs the database, not a running application. unknown prints queued job classes this binary does not compile, one per line, and exits 1 when any exist.
- `APP db diagnose|roles DATABASE MIGRATION_ROLE RUNTIME_ROLE`: diagnose reports database health: connections, locks, cache hits, unused indexes and the slowest statements, and needs the database, not a running application. roles prints the psql script that creates an application’s migration and runtime roles and its database.
- `APP insights [--since=DURATION] [--kind=request|job|schedule|sql|outbound]`: Show the recorder’s per-minute latency history for routes, jobs, schedules, SQL or outbound hosts. Needs require "caramel/crema/recorder".

## Frappé starts Latte when a command needs it {#c-commands-latte}

Frappé runs `latte daemon --detach` when a command needs the services and Latte is not running, and `frappe services` starts and stops the services Latte runs. You call Latte yourself for the login item, certificate trust and its version.

| Condition | Outcome |
| --- | --- |
| An unknown Latte command | exits 2 with `Unknown command. Use latte --help.` |
| `latte version` | prints `Latte 0.17.0 (control API 1, 2)` |

- `latte daemon`: Run Latte in this terminal.
- `latte daemon --detach`: Run Latte in its own session, logging to logs/latte.log. Frappé starts Latte this way when it is not running.
- `latte stop`: Stop the running Latte. Services keep running.
- `latte service install`: Start Latte whenever you log in (a per-user login item), and now.
- `latte service uninstall`: Remove that login item; the Latte it started stops.
- `latte trust install`: Trust Latte's certificate authority in your default keychain.
- `latte trust remove`: Remove that one certificate from the keychain it was added to.
- `latte version`: Print this Latte's release and the control API versions it serves.

Prove it

## Ask for the syntax {#c-commands-prove}

**Terminal · inside the application**

```bash
frappe check --help
frappe agent-manifest
frappe migrte
```

**Passing:** `--help` prints `Usage: frappe check …` and the command’s summary. `agent-manifest` prints every command with the diagnostic grammar. The mistyped `migrte` exits 1: on a terminal with `frappe migrte: unknown command migrte`, the `Usage:` line of `migrate` and `Did you mean migrate?`; piped, with one MRDP `USAGE` block.

[← Security defaults](https://caramelize.dev/docs/0.17.0/security/index.md) · [Set up the local environment →](https://caramelize.dev/docs/0.17.0/local-environment/index.md)

Caramel 0.17.0 · https://caramelize.dev/docs/0.17.0/commands/
