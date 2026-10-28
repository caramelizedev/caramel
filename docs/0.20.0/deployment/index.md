Guides / Production

# From local to live.

Build the release artifact, set the variables a compiled application needs, and run its process roles under the contract any deploy tool can rely on.

| Contract | Value |
| --- | --- |
| Release | 0.15.0 |
| Needs | A committed application tree, a container engine such as Docker Desktop for the build, and a Linux host with PostgreSQL for the run |
| You will have | A `linux/amd64` artifact that holds `bin/SHARD` and `public/`, migrated, serving on a Unix socket and answering `GET /health` |
| Status | The build, the role script, `migrate`, `serve --no-workers`, `GET /health` and SIGTERM run in `scripts/check frappe-project-build` when a container engine runs; `jobs unknown` and the proxy are not run by a check |
| Proved by | `frappe build` · `APP migrate` · `curl --unix-socket` |

A compiled application promises any deploy tool the behaviour below, as [ADR 0032 ↗](https://github.com/caramelizedev/caramel/blob/v0.20.0/docs/decisions/0032-application-production-contract.md) records. `SHARD` is the application’s name in `shard.yml`, such as `bookshelf`; `APP` below stands for the unpacked `bin/SHARD`, such as `/srv/bookshelf/bin/bookshelf`.

## The guide in four stages {#c-deploy-map}

12 sections · read in order the first time

- **1 · Build**

  - [Build the artifact](#c-deploy-contract)
  - [Serve public files](#c-deploy-public)
  - [Embed the files the binary reads](#c-deploy-files)
- **2 · Run**

  - [Set the environment](#c-deploy-env)
  - [Run the process roles](#c-deploy-now)
  - [Check readiness](#c-deploy-ready)
  - [Shut down gracefully](#c-deploy-shutdown)
- **3 · Cut over**

  - [Check for unknown jobs](#c-deploy-unknown)
  - [Set up the database](#c-deploy-database)
  - [Cut over in order](#c-deploy-order)
- **4 · Limits**

  - [What does not compile](#c-deploy-refusals)
  - [Not covered yet](#c-deploy-gaps)

Stage 1 · Build

## Build the artifact {#c-deploy-contract}

**Terminal · inside the application**

```bash
frappe build
```

**Expect:** Prints the path of `.caramel/build/SHARD-YYYYmmddTHHMMSSZ-SHA7-linux-amd64.tar.gz` as its only line of output. The archive holds `bin/SHARD` and `public/`. Beside it sit `SHARD-….tar.gz.sha256`, which `sha256sum -c` or `shasum -a 256 -c` verifies, and `SHARD-….tar.gz.sbom.json`, a CycloneDX 1.5 bill of materials naming the application at its commit, the Crystal version, each shard with its version and commit, and the musl, gc, gmp, OpenSSL, pcre2 and zlib versions linked into the binary, with the image digest under `properties`.

`frappe build` publishes `app/assets` into `public/`, then compiles the committed tree with `crystal build --release --static` in the pinned `crystallang/crystal:1.22.1-alpine` image for `linux/amd64`, keeping debug info. Alpine’s `gmp-static` is installed first, so an application that uses `BigDecimal` links GMP into the binary. It needs a container engine, such as Docker Desktop, for this build only. `CARAMEL_BUILD_IMAGE`, set where `frappe build` runs, replaces the image, for example with one carrying a patched OpenSSL; it must name the image by digest, such as `crystallang/crystal:1.22.1-alpine@sha256:…`, so the build stays reproducible, and the SBOM records which digest built the artifact.

| Condition | Outcome |
| --- | --- |
| `frappe build` with uncommitted changes in the working tree | refuses to build |
| `frappe build` when publishing `app/assets` into `public/` leaves changes | refuses to build |
| `CARAMEL_BUILD_IMAGE` without a `@sha256:` digest | exits 1 with `CARAMEL_BUILD_IMAGE must name an image by digest` |

## Serve public files {#c-deploy-public}

`serve` reads `public/` from `CARAMEL_ROOT` when it is set, so the binary runs from wherever the artifact is unpacked.

| Condition | Outcome |
| --- | --- |
| `CARAMEL_ROOT` that is not an absolute path | exits 1 with `CARAMEL_ROOT must be an absolute path` |
| `CARAMEL_ROOT` with no `public/` inside it | exits 1 with `CARAMEL_ROOT has no public directory` |

## Embed the files the binary reads {#c-deploy-files}

The artifact holds `bin/SHARD` and `public/` and nothing else: no source tree and no Node or other runtime. The compiler expands `__DIR__` when it builds, so in the binary it names a path inside the build container, such as `/work/source/src`.

| Condition | Outcome |
| --- | --- |
| `File.read`, `File.open` or `Dir.glob` of a path built from `__DIR__` | raises `File::NotFoundError` in the release, and an action that reaches it answers 500; it works from a source checkout, so specs pass |
| `{{ read_file("#{__DIR__}/file") }}` of a committed file | embeds the file in the binary when it compiles; a change to the file needs a new build |
| A file a browser fetches, under `app/assets` | is published to `public/assets/` and served at `/assets/` |

`frappe lint` reports a `File` or `Dir` reader called with `__DIR__` among its arguments as `Caramel/SourceTreeRead`; a path stored in a constant or a local first is not reported.

Caramel installs no external runtime on the server, and `frappe build` neither packs nor checks one. A feature that shells out to Node or a browser needs its host to provide it.

Stage 2 · Run

## Set the environment {#c-deploy-env}

With `CARAMEL_ENV` unset the binary runs as production. These variables are read when a process starts:

| Variable | Meaning |
| --- | --- |
| `DATABASE_URL` | The runtime role’s connection, for `serve`, `work`, `seed` and `jobs`; a missing one exits 1 with `Missing database configuration: DATABASE_URL` |
| `MIGRATION_DATABASE_URL` | The migration role’s connection, for `migrate` |
| `APP_ORIGIN` | The public origin, such as `https://bookshelf.example`; `serve` exits 1 with `APP_ORIGIN is required` without it |
| `APP_SECRET` | The secret that signs sessions and tokens; `serve` exits 1 with `APP_SECRET is required` without it |
| `APP_SECRET_PREVIOUS` | The secrets `APP_SECRET` replaced, comma-separated, each at least 32 bytes; sessions and CSRF tokens they signed still read, so a rotation signs no one out. Unset it once the session window has passed |
| `CARAMEL_SOCKET` | The Unix socket path `serve` listens on, in a directory only its owner can enter; `serve` exits 1 with `CARAMEL_SOCKET is required; use frappe dev` without it, and with `CARAMEL_SOCKET must be in a private owned directory` when the directory is open |
| `CARAMEL_SOCKET_GROUP` | A group that may enter the socket’s directory instead, for a proxy that runs as another user; the socket is then mode 0660 |
| `CARAMEL_ROOT` | The absolute path of the unpacked artifact, holding `public/` |
| `CARAMEL_SHUTDOWN_TIMEOUT` | Whole seconds from 1 to 3600, default 25, that `serve` and `work` give requests and jobs in flight after their first signal; another value exits 1 with `CARAMEL_SHUTDOWN_TIMEOUT must be a whole number of seconds from 1 to 3600` |

The secret’s minimum length is on the security reference, and the database timeouts and Crema’s ops socket on the Crema reference.

[Read the security limits →](https://caramelize.dev/docs/0.20.0/security/index.md)[Read the Crema variables →](https://caramelize.dev/docs/0.20.0/crema/index.md)

## Run the process roles {#c-deploy-now}

A compiled application can serve HTTP or run Cold Brew with `work`, including queue selection, concurrency, and graceful completion of in-flight jobs. Run each web process as `serve --no-workers`, which keeps the PubSub broker and maintenance but runs no jobs or schedules, and run one `work` process.

**Terminal · on the server**

```bash
APP serve --no-workers
```

**Expect:** Prints `TITLE is ready at APP_ORIGIN` once the socket is bound, and serves until SIGTERM.

[Read the serve and work flags →](https://caramelize.dev/docs/0.20.0/commands/index.md)

## Check readiness {#c-deploy-ready}

Each process binds a socket path of its own, and the proxy moves to it once it is ready. A generated application routes `GET /health` to an action that touches no database; an application that removes the route has no readiness check.

**Terminal · on the server**

```bash
curl --unix-socket "$CARAMEL_SOCKET" -H "Host: bookshelf.example" http://localhost/health
```

**Expect:** Prints `ok`. The `Host` is the authority of `APP_ORIGIN`; another host answers 421.

## Shut down gracefully {#c-deploy-shutdown}

| Condition | Outcome |
| --- | --- |
| The first SIGTERM or SIGINT | stops `serve` accepting connections, stops claiming jobs and starting schedule blocks, ends every PubSub subscription so a server-sent events stream ends, and answers in-flight requests with `Connection: close` |
| Requests, jobs and schedule blocks in flight | get `CARAMEL_SHUTDOWN_TIMEOUT` seconds, default 25; `serve` exits 0 when they finish or the time passes, and logs what was still running |
| A job cut off at that deadline | rolls back; the next maintenance pass, within a minute, finds its session gone and releases it, and a release does not count as an attempt |
| `work` | stops the same way after its first signal |
| A second SIGTERM or SIGINT | exits 1 at once |
| A request that arrives on a kept-alive connection after the last one in flight finished | is not guaranteed an answer, so a deploy moves the proxy first |
| A supervisor that stops `serve` or `work` | must allow `CARAMEL_SHUTDOWN_TIMEOUT` plus 5 s before it kills the process |

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

**Expect:** Prints, without passwords, the psql script that creates a migration role that owns the database and a runtime role with DML through default privileges. It stops before any grant when either role already exists with SUPERUSER, CREATEDB, CREATEROLE, BYPASSRLS or REPLICATION, so run it with `psql -v ON_ERROR_STOP=1`; the role that runs it stays a member of both roles until you revoke them.

Connect with `sslmode=verify-full`, plus `sslrootcert` for a private CA, or through a Unix socket, directly or through a session-mode pooler, never a transaction-mode one. The application needs no superuser and no extension. Each connection sets a statement and a lock timeout when it opens. [Read the timeout variables →](https://caramelize.dev/docs/0.20.0/crema/index.md)

## Cut over in order {#c-deploy-order}

1. Run the new binary’s `migrate` while the old one serves.
2. Stop the old workers.
3. Move traffic to the new web process.

**Terminal · on the server**

```bash
APP migrate
```

**Expect:** Prints `Applied N migrations.` with `MIGRATION_DATABASE_URL` set, then a warning for each queued job class this binary lacks.

| Condition | Outcome |
| --- | --- |
| `serve`, `work` or `seed` with a migration not yet applied | exits 1 with `Pending migrations. Run frappe migrate first.` |
| `serve`, `work` or `seed` of an older binary against a schema a newer one migrated | starts, after `WARNING: the database holds migrations this binary lacks (v…); starting anyway` on standard error |
| `migrate` or `lint` of an older binary against that schema | exits 1 with `Applied migration N is missing from this application` |

Migrations never roll back: an old binary restarted after the new one’s `migrate` keeps serving until cutover, but going back across a migration means restoring the database.

Stage 4 · Limits

## What does not compile {#c-deploy-refusals}

Nothing on this page is checked at compile time: the artifact is the application as `frappe check` passed it. Each refusal above happens when the command runs, before it binds a socket or writes a row.

## Not covered yet {#c-deploy-gaps}

- Caramel ships no command that provisions servers, installs a proxy or deploys.
- Artifacts are `linux/amd64` only; arm64 artifacts are deferred.
- Assets are published as files under `public/`; embedded and fingerprinted assets are deferred.
- The artifact carries no external runtime, such as Node.

Prove it

## Check the artifact before cutover {#c-deploy-prove}

On the build host:

**Terminal · inside the application**

```bash
frappe build
```

On the server, with the artifact unpacked at `/srv/bookshelf` and the variables above exported:

**Terminal · on the server**

```bash
/srv/bookshelf/bin/bookshelf migrate
/srv/bookshelf/bin/bookshelf jobs unknown
/srv/bookshelf/bin/bookshelf serve --no-workers &
curl --unix-socket "$CARAMEL_SOCKET" -H "Host: bookshelf.example" http://localhost/health
```

**Passing:** `frappe build` prints one artifact path. `migrate` prints `Applied N migrations.`, `jobs unknown` prints nothing and exits 0, `serve` prints `Bookshelf is ready at https://bookshelf.example`, and `curl` prints `ok`. `scripts/check frappe-project-build` runs the build, the role script, `migrate`, `serve --no-workers`, `GET /health` and SIGTERM in a container when an engine is running, and prints `SKIP: frappe build needs a running container engine` otherwise.

[← Work with an agent](https://caramelize.dev/docs/0.20.0/agents/index.md) · [Review worker process options →](https://caramelize.dev/cookbook/0.20.0/background-jobs/index.md)

Caramel 0.20.0 · https://caramelize.dev/docs/0.20.0/deployment/
