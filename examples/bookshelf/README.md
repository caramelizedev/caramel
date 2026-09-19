# Bookshelf reference application

Bookshelf demonstrates Caramel's first runtime slice: PostgreSQL persistence, compiled escaped views, safe forms, and locally bundled htmx 4. It has list, detail, create, edit, and delete pages. Authentication is not installed.

This is a contributor reference application. The managed `frappe new` / `frappe dev` workflow is being built separately; this directory is not yet a generated project template. `BookStore` uses explicit parameterized SQL while the model DSL is developed.

From the repository root, after restoring the pinned toolchain and shards:

```sh
mkdir -p bin
scripts/crystal build examples/bookshelf/src/bookshelf.cr -o bin/bookshelf
```

The native binary provides three commands:

```text
bookshelf migrate  Apply pending migrations explicitly
bookshelf seed     Add four sample books only when the shelf is empty
bookshelf serve    Serve the application on its private Unix socket
```

Set `DATABASE_URL` for the explicitly selected database. TCP database connections use verified TLS; managed local connections use a private Unix socket directory. `serve` additionally requires `APP_SECRET` (at least 32 random bytes), `APP_ORIGIN` (for example `https://bookshelf.caramel`), and `CARAMEL_SOCKET` in a private current-user-owned directory. The HTTPS proxy must preserve the configured Host. The server refuses to start with pending migrations or to replace an existing socket.

For a fully automated disposable verification run:

```sh
scripts/integration --http-smoke
```

The test harness creates its own PostgreSQL cluster, separate databases/roles, test certificates, native binary, and Caddy proxy, verifies requests, then stops and removes its owned resources. It does not change system DNS or certificate trust. Do not use test-cluster credentials or the harness's trust authentication in production.

All forms work without JavaScript. htmx adds targeted navigation with explicit attribute inheritance. POST actions require a signed CSRF cookie, a matching form token, and the exact application Origin. Application authentication and per-record authorization are separate future additions; this sample collection is public to anyone permitted to access its origin.
