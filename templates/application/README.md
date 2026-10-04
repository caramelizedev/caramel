# @@TITLE@@

A Crystal browser application built with Caramel, PostgreSQL and locally bundled htmx 4.

```sh
frappe setup  # after cloning; creates fresh private local credentials and applies migrations
frappe dev    # compiles, watches, and opens your named HTTPS project
```

Create your first feature:

```sh
frappe make resource Book title:string author:string
frappe migrate
frappe corretto
```

`frappe --help` lists every command, and `frappe COMMAND --help` prints one command's
syntax. `frappe check`, `frappe lint` and `frappe corretto` verify a change.
[AGENTS.md](AGENTS.md) is the map for coding agents.

Commit `shard.yml`, `shard.lock` and `config/environment.yml`: `shard.lock` pins the
Caramel release, and Frappé runs that release's commands for this application. Keep
`.env`, `lib/`, `.caramel/` and local storage out of version control, and never deploy
local database URLs, secrets or CA material. Production supplies its own `DATABASE_URL`,
`MIGRATION_DATABASE_URL`, `APP_SECRET`, `APP_ORIGIN` and private application socket.

Documentation for this application's release: https://caramelize.dev/docs/VERSION/, with
VERSION from `shard.lock`.
