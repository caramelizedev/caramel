Guides / Production

# From local to live.

What a compiled application promises any deploy tool: the release artifact, its process roles, readiness, shutdown and database setup.

0.14.0 baseline

## Available process roles {#c-deploy-now}

Latte manages local services and named HTTPS; Frappé builds and supervises the development app. A compiled application can serve HTTP or run Cold Brew with `work`, including queue selection, concurrency, and graceful completion of in-flight jobs. On SIGTERM, `serve` stops accepting connections, answers in-flight requests with `Connection: close` and exits when they finish or after 25 s.

## The production contract {#c-deploy-contract}

A compiled application promises any deploy tool the behaviour below, as [ADR 0032 ↗](https://github.com/caramelizedev/caramel/blob/v0.14.0/docs/decisions/0032-application-production-contract.md) records. Caramel itself ships no command that provisions servers or deploys.

**Terminal · inside the application**

```bash
frappe build
```

- **Artifact.** `frappe build` refuses uncommitted changes, publishes `app/assets` into `public/` and refuses if that leaves changes, then compiles the committed tree with `crystal build --release --static` in the pinned `crystallang/crystal:1.21.1-alpine` image for `linux/amd64`, keeping debug info. It needs a container engine, such as Docker Desktop, for this build only. It writes `.caramel/build/SHARD-YYYYmmddTHHMMSSZ-SHA7-linux-amd64.tar.gz`, which holds `bin/SHARD` and `public/`, and prints that path as its only line of output.
- **Public files.** `serve` reads `public/` from `CARAMEL_ROOT` when it is set, so the binary runs from wherever the artifact is unpacked.
- **Process roles.** Run each web process as `serve --no-workers`, which keeps the PubSub broker and maintenance but runs no jobs or schedules, and run one `work` process.
- **Readiness.** A new web process is ready when its own socket answers `GET /health`, sent with `Host` set to the authority of `APP_ORIGIN`, with 200 and `ok`. Each process binds a socket path of its own, and the proxy moves to it once it is ready.
- **Shutdown.** On SIGTERM, `serve` stops accepting connections, answers in-flight requests with `Connection: close` and exits when they finish or after 25 s. An open server-sent events stream counts as in flight.
- **Unknown jobs.** Before cutover, the new binary’s `jobs unknown` must print nothing and exit 0; otherwise queued jobs name classes it does not compile.
- **Database.** `APP db roles DATABASE MIGRATION_ROLE RUNTIME_ROLE` prints, without passwords, the psql script that creates a migration role that owns the database and a runtime role with DML through default privileges. Connect with `sslmode=verify-full`, plus `sslrootcert` for a private CA, or through a Unix socket, directly or through a session-mode pooler, never a transaction-mode one. The application needs no superuser and no extension.
- **Order.** Run the new binary’s `migrate` while the old one serves, stop the old workers, then move traffic to the new web process. A binary that lacks an applied migration refuses to start, so going back across a migration means restoring the database.

[← All recipes](https://caramelize.dev/cookbook/0.14.0/) · [Review worker process options →](https://caramelize.dev/cookbook/0.14.0/background-jobs/index.md)

Caramel 0.14.0 · https://caramelize.dev/docs/0.14.0/deployment/
