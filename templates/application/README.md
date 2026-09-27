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

Routes live in `config/routes.cr`, actions in `app/actions/`, SugarORM schemas in `app/models/`, changesets in `app/changesets/`, other application code in `app/`, and database changes in `db/migrations/`. Each action declares a `contract do ... end` of typed fields; route parameters must match contract fields, and the build fails otherwise. `frappe routes` lists every route with its contract. Actions answer browsers with HTML and clients sending `Accept: application/json` with JSON. Register client components with `CaramelIslands.define("Name", (element, props) => ...)` in `app/assets/javascript/app.js` and render them with `island("Name", props)`. Generated files are yours to edit. Source assets live in `app/assets/`; Frappé publishes them into `public/assets/`. Only `public/` is served directly.

Run `frappe --help` for implemented commands. `frappe seed` executes `db/seeds.cr` without resetting data. The optional `frappe add auth` feature is still being built.

Schemas are immutable rows; every write goes through a changeset. `App::Book.create(title: "Dune")` and `book.update(title: "Dune")` build `App::Book::CreateChangeset`/`UpdateChangeset`, validate, write, and return the changeset: check `saved?`, then use `record` or show `errors`. Read with `App::Book.query.where(author: "Frank Herbert").order_by(:id, :desc).limit(20).to_a` or `App::Book.query.find(id)`. `App.build` binds `SugarORM::Repo.database` to the application pool; specs bind it to the verified spec database.

Schemas in `app/models/` declare your tables. After changing one, `frappe db diff --name add_isbn` clones the development database into a disposable Latte branch, derives the migration, checks it against the zero-lock linter, proves it on the branch, and writes `db/migrations/<UTC timestamp>_add_isbn.cr`. Index changes on existing tables go into a separate `_concurrently` migration that runs outside a transaction. Risky changes halt with a remediation: a NOT NULL field without a default, SET NOT NULL, a type change, or a column no field declares. Rename a field with `renamed_from: :old_name`, and drop a column with `drop_column :old_name`. `frappe migrate` lints and applies pending migrations, then warns about remaining drift between the schema and the database. In development only, `--dev-override` on either command turns halts and lint violations into warnings; test and production always refuse them.

`frappe dev` watches Crystal, compiled templates and configuration. Broken builds show a diagnostic page at the same HTTPS address and recover when you save a fix. CSS/JavaScript changes refresh without compilation. Pending migrations require an explicit `frappe migrate`; dev resumes after they are applied. Ctrl-C stops this project's app and watcher while leaving shared services and other projects running. `--no-open` suppresses browser launch and still requires working named, trusted HTTPS. Use `frappe doctor` if local DNS or trust needs repair.

Zed support is optional. Run `frappe lsp install` once per Caramel installation (it pins and builds the Crystal language servers without Homebrew). Trust the project when Zed asks; `.zed/settings.json` runs `frappe lsp crystalline` and `frappe lsp ameba-ls`. Put this project's matching `frappe` on Zed's login-shell PATH. A one-off `PATH=… zed .` can start the servers initially but may be lost when Zed refreshes the worktree environment.

`frappe make resource` writes a schema, one changeset serving both create and update, seven actions, views, a request spec, and the `create_<plural>` migration that `frappe db diff` would derive for the new table. Resource fields support `string`, `int32`, `int64`, `bool`, `float64`, and RFC 3339 `time`. Append `?` for nullable values (quote these declarations in shells that expand `?`). Required text fields must not be blank. For irregular plurals, use `--plural=people`. Generation refuses existing files and preserves edits around the route and path markers. Review the generated files before running migrations.

The local preview includes its framework source in `vendor/caramel/` because it is not yet a published shard. Commit this directory, `shard.yml`, `shard.lock`, `.caramel-version`, and `config/environment.yml`. The snapshot manifest detects accidental changes; setup preserves this project's pinned copy. Dependencies are installed from the lockfile by Frappé.

Keep `.env`, `lib/`, `.caramel/` and local storage out of version control. Do not deploy local database URLs, secrets or CA material. Production supplies its own `DATABASE_URL`, `MIGRATION_DATABASE_URL`, `APP_SECRET`, `APP_ORIGIN`, and private application socket.
