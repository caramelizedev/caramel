# @@TITLE@@

A Crystal browser application built with Caramel @@VERSION@@, PostgreSQL and locally bundled htmx 4.

```sh
frappe setup  # after cloning; creates fresh private local credentials
```

Create your first feature:

```sh
frappe make resource Book title:string author:string
frappe migrate
frappe test
```

Routes live in `config/routes.cr`, application code in `app/`, and database changes in `db/migrations/`. Generated files are yours to edit. Source assets live in `app/assets/`; Frappé publishes them into `public/assets/`. Only `public/` is served directly.

Run `frappe --help` for implemented commands. `frappe seed` executes `db/seeds.cr` without resetting data. This preview implements setup, resource generation, migration and testing; the watched `frappe dev` loop and optional `frappe add auth` are still being built.

Resource fields support `string`, `int32`, `int64`, `bool`, `float64`, and RFC 3339 `time`. Append `?` for nullable values (quote these declarations in shells that expand `?`). For irregular plurals, use `--plural=people`. Generation refuses existing files and preserves edits around the route and path markers. Review the generated files before running migrations.

The local preview includes its framework source in `vendor/caramel/` because it is not yet a published shard. Commit this directory, `shard.yml`, `shard.lock`, `.caramel-version`, and `config/environment.yml`. The snapshot manifest detects accidental changes; setup preserves this project's pinned copy. Dependencies are installed from the lockfile by Frappé.

Keep `.env`, `lib/`, `.caramel/` and local storage out of version control. Do not deploy local database URLs, secrets or CA material. Production supplies its own `DATABASE_URL`, `MIGRATION_DATABASE_URL`, `APP_SECRET`, `APP_ORIGIN`, and private application socket.
