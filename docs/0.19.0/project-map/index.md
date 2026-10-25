Guides / Project structure

# A place for every change.

Start with your intention. Caramel’s conventions give it a home, and its tools help you check the result.

| Contract | Value |
| --- | --- |
| Covers | Endpoints, stored data, pages, background jobs, languages, the domain model, seed data, tenants and the production build |
| You will have | The files that own each kind of change, the commands that check it, and the page that states its rules |
| Proved by | `frappe check` · `frappe corretto` |

## Find the file for a change {#c-map-task}

Each row names the files, the commands that check them, and the page that states the rules.

| I want to… | It goes in | Check it with |
| --- | --- | --- |
| **Add or change an endpoint** [Routes and contracts →](https://caramelize.dev/docs/0.19.0/routes-and-contracts/index.md) | `config/routes.cr` `app/actions/` `spec/requests/` | `frappe routes` · `frappe check` · `frappe corretto` |
| **Change the data the application stores** [SugarORM →](https://caramelize.dev/docs/0.19.0/sugarorm/index.md) | `app/models/` `app/changesets/` `db/migrations/` | `frappe db diff` · `frappe migrate` · `frappe corretto` |
| **Change what the browser renders** [Views →](https://caramelize.dev/docs/0.19.0/views/index.md) [Test rendered HTML →](https://caramelize.dev/docs/0.19.0/testing-html/index.md) | `app/views/` `app/assets/` `spec/requests/` | `frappe check` · `frappe corretto` |
| **Move work into a background job** [Cold Brew →](https://caramelize.dev/docs/0.19.0/cold-brew/index.md) | `app/jobs/` `spec/requests/` | `frappe check` · `frappe corretto` |
| **Translate the application** [Internationalization →](https://caramelize.dev/docs/0.19.0/internationalization/index.md) | `app/locales/` `config/application.cr` | `frappe translations` · `frappe check` · `frappe corretto` |
| **Model the domain in SweetTalk** [SweetTalk →](https://caramelize.dev/docs/0.19.0/sweettalk/index.md) | `app/domain/` `spec/domain/` `.claude/skills/sweettalk/SKILL.md` | `frappe check` · `frappe db diff` · `frappe corretto` |
| **Seed development data** [Local environment →](https://caramelize.dev/docs/0.19.0/local-environment/index.md) | `db/seeds.cr` | `frappe seed` |
| **Serve many accounts from one application** [Multi-tenancy →](https://caramelize.dev/docs/0.19.0/multi-tenancy/index.md) | The `tenant` block in `config/routes.cr` `app/models/` | `frappe make tenancy` · `frappe routes` · `frappe corretto` |
| **Build for production** [Production →](https://caramelize.dev/docs/0.19.0/deployment/index.md) | The committed tree; `public/` in the artifact | `frappe build` · `APP jobs unknown` |

Your application’s files are the extension point. [Best practices says what to do when the public API falls short →](https://caramelize.dev/docs/0.19.0/best-practices/index.md)

## Meet the framework {#c-map-components}

Seven components, one job each, all standing on PostgreSQL, and one opt-in language on top of them.

| Component | What it does |
| --- | --- |
| **Blueprint** | HTML written in typed Crystal |
| **SugarORM** | Schemas, changesets and queries |
| **Cold Brew** | Background work, backed by PostgreSQL |
| **Corretto** | Application tests with real data |
| **Crema** | Logs, metrics and traces |
| **Frappé** | Your developer command line |
| **Latte** | Local services and named HTTPS |
| **SweetTalk** | An opt-in language for the domain model, experimental |

## What does not compile {#c-map-compile}

A change in the wrong place is caught by `frappe check`, before any request. Each page linked above states its own rules; these are the ones a newcomer meets first.

| Condition | Outcome |
| --- | --- |
| A route parameter without a field in the action’s contract | fails compilation |
| An association a view reads without a preload | fails compilation, reported as `N_PLUS_ONE` |
| Two schemas that name one table | fails compilation |
| A mocking library compiled beside Corretto | fails compilation |

## Not covered yet {#c-map-gaps}

- `app/commands/` is generated empty and `config/application.cr` does not require it; a command registered with `Caramel::Crema.command` lives in a file you require yourself.
- `spec/system/` and `storage/` are generated empty; no page describes browser tests or file storage.
- Caramel ships no command that provisions servers or deploys.

Prove it

## Check the change you made {#c-map-prove}

**Terminal · inside your application**

```bash
frappe check
frappe corretto
```

**Passing:** `frappe check` exits 0 and `frappe corretto` ends with `Corretto: N of N workers passed`.

[← Your first application](https://caramelize.dev/docs/0.19.0/getting-started/index.md) · [The short guide for agents →](https://caramelize.dev/docs/0.19.0/agents/index.md)

Caramel 0.19.0 · https://caramelize.dev/docs/0.19.0/project-map/
