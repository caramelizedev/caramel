# @@TITLE@@

A Crystal browser application built with Caramel @@VERSION@@, PostgreSQL and locally bundled htmx 4.

```sh
frappe setup  # after cloning; creates fresh private local credentials
frappe dev    # compiles, watches, and opens your named HTTPS project
```

Create your first feature:

```sh
frappe make resource Book title:string author:string
frappe migrate
frappe test
```

Routes live in `config/routes.cr`, actions in `app/actions/`, other application code in `app/`, and database changes in `db/migrations/`. Each action declares a `contract do ... end` of typed fields; route parameters must match contract fields, and the build fails otherwise. `frappe routes` lists every route with its contract. Actions answer browsers with HTML and clients sending `Accept: application/json` with JSON. Register client components with `CaramelIslands.define("Name", (element, props) => ...)` in `app/assets/javascript/app.js` and render them with `island("Name", props)`. Generated files are yours to edit. Source assets live in `app/assets/`; Frappé publishes them into `public/assets/`. Only `public/` is served directly.

Run `frappe --help` for implemented commands. `frappe seed` executes `db/seeds.cr` without resetting data. The optional `frappe add auth` feature is still being built.

`frappe dev` watches Crystal, compiled templates and configuration. Broken builds show a diagnostic page at the same HTTPS address and recover when you save a fix. CSS/JavaScript changes refresh without compilation. Pending migrations require an explicit `frappe migrate`; dev resumes after they are applied. Ctrl-C stops this project's app and watcher while leaving shared services and other projects running. `--no-open` suppresses browser launch and still requires working named, trusted HTTPS. Use `frappe doctor` if local DNS or trust needs repair.

Resource fields support `string`, `int32`, `int64`, `bool`, `float64`, and RFC 3339 `time`. Append `?` for nullable values (quote these declarations in shells that expand `?`). For irregular plurals, use `--plural=people`. Generation refuses existing files and preserves edits around the route and path markers. Review the generated files before running migrations.

The local preview includes its framework source in `vendor/caramel/` because it is not yet a published shard. Commit this directory, `shard.yml`, `shard.lock`, `.caramel-version`, and `config/environment.yml`. The snapshot manifest detects accidental changes; setup preserves this project's pinned copy. Dependencies are installed from the lockfile by Frappé.

Keep `.env`, `lib/`, `.caramel/` and local storage out of version control. Do not deploy local database URLs, secrets or CA material. Production supplies its own `DATABASE_URL`, `MIGRATION_DATABASE_URL`, `APP_SECRET`, `APP_ORIGIN`, and private application socket.
