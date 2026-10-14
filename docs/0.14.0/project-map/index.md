Guides / Project structure

# A place for every change.

Start with your intention. Caramel’s conventions give it a home, and its tools help you check the result.

| Contract | Value |
| --- | --- |
| Covers | Endpoints, stored data, pages, background jobs, languages and the domain model |
| You will have | The files that own each kind of change, and the commands that check it |
| Proved by | `frappe check` · `frappe corretto` |

## Find the file for a change {#c-map-task}

| I want to… | It goes in | Check it with |
| --- | --- | --- |
| **Add or change an endpoint** Declare the route, then its typed contract and behavior. Keep the response and failure cases in a request spec. | `config/routes.cr` `app/actions/` | `frappe routes` · `frappe check` · `frappe corretto` |
| **Change the data your application stores** Describe the stored shape and write rules, derive the migration, and review it before applying it. | `app/models/` `app/changesets/` `db/migrations/` | `frappe db diff` · `frappe migrate` · `frappe corretto` |
| **Change what the browser renders** Use Blueprint classes for typed HTML, `have_html` for rendered requirements, and browser checks for client behavior. | `app/views/` `app/assets/` `spec/requests/` | `frappe check` · `have_html` · browser inspection |
| **Move work into a background job** Define the job payload and behavior. Enqueue within the intended transaction and test the observable result. | `app/jobs/` `spec/` | Corretto session · `drain_queue!` · database assertion |
| **Translate the application** Enable locales with `frappe make locale`, define typed messages, and check translated pages, errors, and language selection. | `app/locales/` `config/application.cr` `app/views/` `spec/requests/` | `frappe translations` · `frappe check` · `frappe corretto` |
| **Model the domain in SweetTalk** Start with `frappe make domain`, then declare contexts, values and aggregates, and run their commands from actions. The skill gives agents the rules, each linked to the SweetTalk guide. | `app/domain/` `spec/domain/` `.claude/skills/sweettalk/SKILL.md` | `frappe check` · `frappe db diff` · `frappe corretto` |

## Meet the framework {#c-map-components}

| Component | What it does |
| --- | --- |
| **Frappé** | Your developer command line |
| **Latte** | Local services and named HTTPS |
| **SugarORM** | Schemas, changesets, and queries |
| **Blueprint views** | HTML written in typed Crystal |
| **Cold Brew** | PostgreSQL-backed background work |
| **Corretto** | Application tests with real data |

> **Application code is the extension point**
>
> Keep changes in your application’s files. When the public API does not support a task, identify the gap before changing framework internals.

Prove it

## Check the change you made {#c-map-prove}

**Terminal · inside your application**

```bash
frappe check
frappe corretto
```

**Passing:** `frappe check` prints `✓ Type check passed` and `frappe corretto` ends with `Corretto: N of N workers passed`.

[← Your first application](https://caramelize.dev/docs/0.14.0/getting-started/index.md) · [The short guide for agents →](https://caramelize.dev/docs/0.14.0/agents/index.md)

Caramel 0.14.0 · https://caramelize.dev/docs/0.14.0/project-map/
