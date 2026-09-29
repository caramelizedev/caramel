# Caramel

Caramel is an early Crystal framework and local development environment for complete browser applications, inspired by Laravel's integrated developer experience.

The intended workflow combines PostgreSQL, server-rendered HTML with bundled htmx 4, optional one-command authentication, and named local HTTPS projects managed by Latte. Frappé is the developer CLI.

Views are Blueprint classes: markup written as plain Crystal, with typed inputs and escaped text and attributes. They replace both the ECR templates of Caramel 0.1.0 and the Slang templates RFC-0008 first proposed ([ADR 0018](docs/decisions/0018-blueprint-views.md)).

## Current state

The toolchain feasibility milestone is complete. The runtime has reusable Crystal web primitives: PostgreSQL persistence, escaped Blueprint views, CSRF-protected forms and locally bundled htmx 4. The reference application is the project Frappé generates; `scripts/check frappe-project` builds one with resources, runs its request specs and serves its native binary through Caddy over named HTTPS and a private Unix socket.

Latte now has a private project registry, managed PostgreSQL, DNS/HTTPS configuration, a shared service daemon and a native macOS menu client. Frappé starts the daemon when a command needs it; an opt-in login item starts it at login instead. Disposable integration checks cover service startup, crash recovery, two-site HTTPS and database retention.

- The macOS resolver/port installer and `latte trust install` are applied on the development machine: `https://<site>.caramel` resolves through `/etc/resolver/caramel`, reaches Caddy on port 443 through the launchd relay, and is trusted by Safari and curl without flags.
- Sites can instead choose the `.localhost` suffix, which macOS and browsers resolve without a resolver entry ([ADR 0006](docs/decisions/0006-browser-acceptance-and-localhost-sites.md)).

The application workflow branch adds SugarORM (immutable schemas, explicit changesets, typed queries and preloads, and migrations derived and linted by `frappe db diff`), Caramel Core (compile-time checked routes, typed request contracts that bind forms and JSON objects, per-action ingress for signed webhooks and token APIs ([ADR 0020](docs/decisions/0020-action-ingress-and-json-bodies.md)), actions with HTML or JSON egress, multi-target htmx partials and client islands), and the native Frappé CLI.

- The CLI creates and restores projects, generates typed resources, derives and applies migrations, and runs Corretto specs (`frappe corretto`) in rolled-back savepoints against per-worker Latte databases.
- Resource generation produces editable SugarORM schemas and changesets, actions with request contracts, views, route helpers, derived migrations and request specs.
- The watched development loop reacts to kqueue events, type-checks before building, serves same-origin build diagnostics, refreshes assets and cleans up terminal-owned app processes.
- `scripts/check browser` accepts the browser experience on a `.localhost` site.

Still unfinished: smaller individual generators, custom commands, dependency editing, optional authentication, a consumer installer and production deployment. Mise provides the pinned private toolchain.

Frappé's agent surface (RFC-0005) is one command table: `frappe --help`, `frappe COMMAND --help`, argument validation and the stateless `frappe agent-manifest` all read it, and unknown commands or malformed arguments exit 1 with the intended command's exact syntax and a "Did you mean" suggestion. `frappe check` runs the Tier-1 `crystal build --no-codegen` type check and reports compiler errors either in the RFC-0008 terminal typography (a TTY, or `--human`) or as token-dense MRDP (`--agent`, or piped output), including `CONTRACT_MISMATCH` and `N_PLUS_ONE` diagnostics whose `PATCH:` lines can be applied mechanically. `frappe routes FILTER`, `frappe db branch create|list|delete`, `frappe dev --branch NAME` and `frappe expand FILE:LINE:COL` complete it; usage errors, `frappe migrate` lint refusals and `frappe db diff` halts print as MRDP in agent mode too.

`frappe lint` checks an application against Caramel's RFC-0008 rule set, Ameba 1.7.0 plus Caramel's service-noun rule, printing Ameba's report on a terminal or MRDP `ERR LINT_<RULE>` lines for agents; `frappe format` runs the pinned formatter ([ADR 0017](docs/decisions/0017-formatting-and-linting.md)). The framework follows the same rule set.

Caramel Cold Brew (RFC-0003) keeps background work in PostgreSQL: typed jobs enqueued inside the business transaction, `FOR UPDATE SKIP LOCKED` worker fibers with per-job and global `retry_on`, daily-partitioned `caramel_jobs` with a maintenance fiber, leased recurring schedules, LISTEN/NOTIFY PubSub for server-sent events, an UNLOGGED cache, and a synchronous `drain_queue!` for specs. Generated apps include its system migrations and run its workers from `serve`, or from a worker-only `work` process. `Caramel::ColdBrew.status` and hooks that run after a retry or failure is written report jobs without querying Cold Brew's tables ([ADR 0019](docs/decisions/0019-cold-brew-status-hooks-and-work.md)).

- [Caramel RFCs](docs/rfc.md)
- [RFC implementation status and ranked gaps](docs/research/rfc-implementation-status.md)
- [Views: elements, attributes, escaping and trusted HTML](docs/views.md)
- [SugarORM and request contract APIs, verification and limits](docs/research/typed-application-apis.md)
- [Frappé generated-project workflow and current limits](docs/research/frappe-workflow.md)
- [Development watcher, process ownership and acceptance limits](docs/research/frappe-development.md)
- [Development performance measurements and limits](docs/research/development-performance.md)
- [Laravel Herd comparison and deferred local-development features](docs/research/herd-comparison.md)
- [Latte supervisor verification and limits](docs/research/latte-supervisor.md)
- [Toolchain decision and remaining gates](docs/decisions/0001-managed-toolchain-provider.md)
- [Resumable toolchain installer component](docs/research/toolchain-installer.md)
- [Versioning and releases (ADR 0016)](docs/decisions/0016-versioning-and-releases.md)
- [Optional Crystal editor tools (Zed)](docs/editor-tools.md)
- [Incident 2026-09-27: Caddy installed an implicit local CA (cleanup steps)](docs/research/incident-2026-09-27-caddy-local-ca.md)

## Getting started

Caramel is released as source tags; there are no prebuilt binaries until it has an Apple Developer ID ([ADR 0016](docs/decisions/0016-versioning-and-releases.md)). On Apple Silicon with Apple's Command Line Tools, install a release from its tag ([ADR 0015](docs/decisions/0015-local-setup-and-latte-lifecycle.md)):

```sh
git clone --branch v0.1.0 https://github.com/caramelizedev/caramel.git caramel && cd caramel
scripts/install-toolchain                   # pinned Crystal, PostgreSQL, Caddy and CoreDNS; recorded in .caramel-toolchain
scripts/shards install --frozen --without-development
scripts/build-frappe && scripts/build-latte
bin/frappe installations register           # frappe and latte in ~/.local/bin
frappe services start                       # starts Latte in the background
scripts/install-local-integration prepare /private/tmp/caramel-integration-bundle
sudo scripts/install-local-integration apply /private/tmp/caramel-integration-bundle   # .caramel resolver and ports 80/443
latte trust install                         # trusts Latte's local CA in your login keychain
frappe new demo && cd demo && frappe dev
```

Later releases install beside it: `frappe installations install 0.2.0` clones that tag into `~/Library/Application Support/Caramel/releases/`, reuses the toolchain when the release pins the same one, builds and registers it. Each application's `shard.lock` pins its release, and `frappe` runs that release's commands for it, offering to install a missing one. `~/.local/bin/frappe` and `latte`, on-demand Latte and the login item all run the newest installed release. `frappe doctor` names the command that updates a resolver or port relay from an older release.

The integration and trust steps are needed once per machine. `sudo scripts/install-local-integration uninstall` and `latte trust remove` undo them. After that, the last line is the whole workflow:

- `frappe new` configures the site and applies its migrations.
- Any command that needs Latte starts it when it is not running. It keeps running after the terminal closes and logs to `~/Library/Application Support/Caramel/logs/latte.log`.
- `latte stop` stops Latte, and `frappe services stop` stops its services.
- `latte service install` starts Latte at every login instead; `latte service uninstall` removes that login item.

## Contributor checks

[CONTRIBUTING.md](CONTRIBUTING.md) covers commits, the rule set, releases, the compatibility contracts and deprecation.

Install the pinned toolchain (Apple Silicon, Apple Command Line Tools required) with `scripts/install-toolchain`. It installs into `~/Library/Application Support/Caramel/toolchains/` and records the location in this checkout's `.caramel-toolchain`, which every Caramel command and check reads; `--root <dir>` installs elsewhere and `CARAMEL_TOOLCHAIN_ROOT` overrides the recorded location. The selection and lockfile live in `tools/toolchain/`. The launchers preserve the caller's working directory and use the pinned Crystal/Shards/OpenSSL tools without shell activation.

```sh
scripts/shards install --frozen
scripts/crystal spec spec/caramel spec/frappe spec/latte spec/sugar_orm spec/corretto spec/cold_brew spec/release
scripts/check lint
scripts/check compiler
scripts/check orm-compilation
scripts/check route-compilation
scripts/check contract-compilation
scripts/check cold-brew-compilation
scripts/check toolchain-paths
scripts/check integration
```

The integration command creates and cleans up its own database cluster. It never uses an existing application database or changes system DNS/certificate trust. Every command uses the pinned managed tools; none falls back to a Crystal or Shards found on `PATH`.

Latte contributor checks additionally require the pinned CoreDNS artifact and the macOS Swift compiler:

```sh
scripts/install-latte-tools --help
scripts/build-latte
scripts/check latte-ipc
scripts/check latte-postgres
scripts/check latte-network
scripts/check latte-daemon
scripts/check native
scripts/build-frappe
scripts/check frappe-project
scripts/check installations
scripts/check frappe-project --dev
scripts/check schema-diff
scripts/check dev-child
scripts/check dev-retirement
scripts/check runtime-diagnostics
scripts/check browser
```

These checks use isolated temporary state and local listeners. Running the system integration installer or `latte trust install` is a separate, explicit operation; neither is part of the test commands.

`scripts/check all` builds everything, then runs the spec suite and every check in sequence and reports each one; a release requires all of them. `scripts/check all --except latte-daemon` skips a check, for example while your own Latte holds its ports.

`scripts/check latte-daemon` runs the real `bin/latte daemon`, which listens on Latte's fixed ports: DNS 15353 and HTTP/HTTPS 18080/18443. If you use Latte yourself, stop it first: run `frappe services stop`, then `latte stop`.

`scripts/check browser` drives Safari through `safaridriver` against a generated app served by that isolated Latte stack to prove morph focus/scroll, `hx-partial`, islands, SSE behavior, and a Cold Brew job whose PubSub event reaches an `EventSource`; it needs Safari's "Allow Remote Automation", enabled once with `safaridriver --enable`.

Optional language servers for Zed and other editors: `scripts/build-frappe`, `bin/frappe lsp install`, then `scripts/check editor-tools`; see [docs/editor-tools.md](docs/editor-tools.md).

## License

Caramel is released under the [MIT License](LICENSE). Components distributed under other licenses are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
