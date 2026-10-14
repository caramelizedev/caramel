Guides / Production

# From local to live.

What a compiled application promises any deploy tool: the release artifact, its process roles, readiness, shutdown and database setup.

| Contract | Value |
| --- | --- |
| Release | 0.14.0 baseline |
| Needs | A committed application tree, and a container engine such as Docker Desktop for the build |
| You will have | A `linux/amd64` artifact that holds `bin/SHARD` and `public/` |
| Proved by | `frappe build` · `APP jobs unknown` |

A compiled application promises any deploy tool the behaviour below, as [ADR 0032 ↗](https://github.com/caramelizedev/caramel/blob/v0.14.0/docs/decisions/0032-application-production-contract.md) records.

## The guide in four stages {#c-deploy-map}

9 sections · read in order the first time

- **1 · Build**

  - [Build the artifact](#c-deploy-contract)
  - [Serve public files](#c-deploy-public)
- **2 · Run**

  - [Run the process roles](#c-deploy-now)
  - [Check readiness](#c-deploy-ready)
  - [Shut down gracefully](#c-deploy-shutdown)
- **3 · Cut over**

  - [Check for unknown jobs](#c-deploy-unknown)
  - [Set up the database](#c-deploy-database)
  - [Cut over in order](#c-deploy-order)
- **4 · Limits**

  - [Not covered yet](#c-deploy-gaps)

Stage 1 · Build

## Build the artifact {#c-deploy-contract}

**Terminal · inside the application**

```bash
frappe build
```

**Expect:** Prints the path of `.caramel/build/SHARD-YYYYmmddTHHMMSSZ-SHA7-linux-amd64.tar.gz` as its only line of output. The archive holds `bin/SHARD` and `public/`.

`frappe build` publishes `app/assets` into `public/`, then compiles the committed tree with `crystal build --release --static` in the pinned `crystallang/crystal:1.21.1-alpine` image for `linux/amd64`, keeping debug info. It needs a container engine, such as Docker Desktop, for this build only.

| Condition | Outcome |
| --- | --- |
| The working tree has uncommitted changes | `frappe build` refuses |
| Publishing `app/assets` into `public/` leaves changes | `frappe build` refuses |

## Serve public files {#c-deploy-public}

`serve` reads `public/` from `CARAMEL_ROOT` when it is set, so the binary runs from wherever the artifact is unpacked.

Stage 2 · Run

## Run the process roles {#c-deploy-now}

A compiled application can serve HTTP or run Cold Brew with `work`, including queue selection, concurrency, and graceful completion of in-flight jobs. Run each web process as `serve --no-workers`, which keeps the PubSub broker and maintenance but runs no jobs or schedules, and run one `work` process.

[Set up the local environment →](https://caramelize.dev/docs/0.14.0/local-environment/index.md)

## Check readiness {#c-deploy-ready}

Each process binds a socket path of its own, and the proxy moves to it once it is ready.

| Condition | Outcome |
| --- | --- |
| `GET /health` on the new process’s own socket, with `Host` set to the authority of `APP_ORIGIN` | answers 200 and `ok` |

## Shut down gracefully {#c-deploy-shutdown}

| Condition | Outcome |
| --- | --- |
| SIGTERM | `serve` stops accepting connections, answers in-flight requests with `Connection: close` and exits when they finish or after 25 s |
| An open server-sent events stream | counts as in flight |

Stage 3 · Cut over

## Check for unknown jobs {#c-deploy-unknown}

Before cutover, check the new binary against the queue.

**Terminal · on the server**

```bash
APP jobs unknown
```

**Expect:** Prints nothing and exits 0 when every queued class is known; otherwise it prints each class the binary lacks, one per line, and exits 1.

## Set up the database {#c-deploy-database}

**Terminal · on the server**

```bash
APP db roles DATABASE MIGRATION_ROLE RUNTIME_ROLE
```

**Expect:** Prints, without passwords, the psql script that creates a migration role that owns the database and a runtime role with DML through default privileges.

Connect with `sslmode=verify-full`, plus `sslrootcert` for a private CA, or through a Unix socket, directly or through a session-mode pooler, never a transaction-mode one. The application needs no superuser and no extension. Each connection sets `statement_timeout` and `lock_timeout` when it opens: `CARAMEL_STATEMENT_TIMEOUT` (default 30) and `CARAMEL_LOCK_TIMEOUT` (default 5) for `serve`, `work`, `seed`, `lint` and `drift`, and `CARAMEL_MIGRATION_STATEMENT_TIMEOUT` (default 0) and `CARAMEL_MIGRATION_LOCK_TIMEOUT` (default 5) for `migrate`. Each is whole seconds from 0 to 86400, and 0 means none. PostgreSQL ends a slow statement and reports it; the client gives up 5 seconds later, and with no statement timeout it waits.

## Cut over in order {#c-deploy-order}

1. Run the new binary’s `migrate` while the old one serves.
2. Stop the old workers.
3. Move traffic to the new web process.

| Condition | Outcome |
| --- | --- |
| A binary that lacks an applied migration | refuses to start |

Going back across a migration means restoring the database.

Stage 4 · Limits

## Not covered yet {#c-deploy-gaps}

- Caramel ships no command that provisions servers or deploys.

Prove it

## Check the artifact before cutover {#c-deploy-prove}

**Terminal · inside the application**

```bash
frappe build
APP jobs unknown
```

**Passing:** `frappe build` prints one artifact path. `APP jobs unknown` prints nothing and exits 0. The new web process answers `GET /health` with 200 and `ok`.

[← Work with an agent](https://caramelize.dev/docs/0.14.0/agents/index.md) · [Review worker process options →](https://caramelize.dev/cookbook/0.14.0/background-jobs/index.md)

Caramel 0.14.0 · https://caramelize.dev/docs/0.14.0/deployment/
