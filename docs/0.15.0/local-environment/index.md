Reference / Local environment

# A local home for every app.

Latte runs PostgreSQL, DNS, and HTTPS on your Mac, and Frappé builds, serves, and checks each application at its own named origin.

| Contract | Value |
| --- | --- |
| Release | 0.15.0 |
| Needs | An Apple Silicon Mac with Apple’s Command Line Tools, and a checkout of the release |
| You will have | PostgreSQL, DNS and HTTPS from Latte, and each application at `https://NAME.caramel` |
| Proved by | `frappe doctor` |

Learning it for the first time? [Your first application](https://caramelize.dev/docs/0.15.0/getting-started/index.md) installs the release and sets up local HTTPS in order. This page lists every command, file and setting of the local environment.

## Limits at a glance {#c-local-limits}

| Limit | Value |
| --- | --- |
| Log size before it rolls (the last MiB moves to `.previous`) | 1 MiB |
| Development sessions per project | 1 |
| `frappe logs` lines | 200 |
| Wait for related saves before a build | 50 ms |
| First `crystalline` build | up to about 20 minutes |
| Toolchain root directory mode | 0700 |
| `.env` mode | 0600 |

## Latte runs three services, not your application {#c-local-latte}

Latte is a per-user service supervisor for macOS. It runs one shared PostgreSQL 18 cluster on a private Unix socket, CoreDNS, and a Caddy HTTPS proxy, and keeps a registry of your sites. Applications run under `frappe dev` in your terminal, not under Latte.

| Condition | Outcome |
| --- | --- |
| A Frappé command needs the services and Latte is not running | Frappé runs `latte daemon --detach` |
| The daemon | outlives the terminal |
| Stopping the daemon | leaves the services running; the next daemon adopts them |
| `latte daemon` without `--detach` | runs Latte in the current terminal |
| A log past one MiB | its last MiB moves to a `.previous` file |
| The menu bar app | does not start Latte |

**Terminal**

```bash
frappe services          # postgres, dns and proxy with their states
frappe services start    # starts Latte when needed, then its services
frappe services stop     # stops the services; Latte keeps running
latte stop               # stops Latte; the services keep running
latte service install    # start Latte at every login
latte service uninstall
latte version
```

**Expect:** `frappe services` lists postgres, dns and proxy with their states. `start` starts Latte when needed, then its services. `stop` stops the services and Latte keeps running. `latte stop` stops Latte and the services keep running. `latte service install` starts Latte at every login.

The login item is opt-in. `latte service install` writes `~/Library/LaunchAgents/dev.caramel.latte.plist`, takes over from a running daemon, and starts Latte now.

Latte’s logs live in `~/Library/Application Support/Caramel/logs/`: `latte.log` for the daemon, and `postgres.log`, `dns.log`, and `proxy.log` for the services.

The menu bar app shows the services and sites, opens a site, its folder, or its logs, and starts or stops the services. Build it from a Caramel checkout with `scripts/build-latte-menu`, which writes `bin/Latte.app`.

## Setup runs once per machine {#c-local-setup}

Caramel 0.15.0 runs on Apple Silicon with Apple’s Command Line Tools, and installs from source. From a checkout of the release, these steps install the pinned toolchain, put `frappe` and `latte` in `~/.local/bin`, and connect `.caramel` names to Latte.

**Terminal · inside the caramel checkout**

```bash
scripts/install-toolchain
scripts/build-release
bin/frappe installations register
frappe services start
scripts/install-local-integration prepare /private/tmp/caramel-integration-bundle && sudo scripts/install-local-integration apply /private/tmp/caramel-integration-bundle
latte trust install
```

**Expect:** Installs the pinned toolchain, builds and registers `frappe` and `latte` in `~/.local/bin`, and starts the services.

| Condition | Outcome |
| --- | --- |
| `prepare` | builds the integration bundle as you |
| `apply` | installs it as an administrator; refuses unless run through `sudo` |
| The resolver `/etc/resolver/caramel` | sends `.caramel` lookups to Latte’s DNS on port 15353 |
| The launchd relay | forwards ports 80 and 443 to Caddy on 18080 and 18443 |
| `latte trust install` | adds Latte’s certificate authority to your default keychain |
| `sudo scripts/install-local-integration uninstall` and `latte trust remove` | undo these steps |

## Every site gets its own origin {#c-local-sites}

A site’s origin is `https://NAME.caramel`.

| Condition | Outcome |
| --- | --- |
| `frappe new NAME` | registers the application with Latte as a site, writes its private `.env`, and applies its migrations |
| `frappe setup` in a cloned project | installs the locked dependencies and takes the same steps, keeping existing files |
| `(terminal)` in `frappe sites` | marks a site that a `frappe dev` session serves |
| `frappe sites remove NAME` | unregisters the site and keeps its folder, databases, credentials, logs, and backups; `frappe setup` registers it again |
| `domain_suffix` in `config/environment.yml` | `caramel`, `test`, or `localhost` |
| A `.localhost` name | resolves to loopback without a resolver entry, but `frappe dev`, `frappe open`, and `frappe doctor` still need the port relay and `latte trust install`, because they require the origin to reach loopback with trusted HTTPS on the standard port |
| Switching the suffix | change it, delete `.env`, and run `frappe setup`, which registers a new site with its own databases |

**Terminal**

```bash
frappe sites
frappe sites remove demo
frappe open
```

**Expect:** `frappe sites` prints each site’s name, state, origin, and folder. `frappe open` opens the origin in your browser.

## Source changes rebuild the application {#c-local-dev}

`frappe dev` builds the application, serves it at its origin, and opens the browser when the first build is ready. It watches `src`, `config`, `db`, `app`, `public`, `shard.yml`, `shard.lock`, and `.env` with kqueue. Ctrl-C stops the project.

**Terminal**

```bash
frappe dev
frappe dev --no-open
frappe dev --branch experiment
```

**Expect:** `frappe dev` builds the application, serves it at its origin and opens the browser when the first build is ready. The terminal prints `Type check passed` or `Type check failed` when the compiler finishes its semantic stages. `--branch experiment` runs against the database branch that `frappe db branch create experiment` made.

| Condition | Outcome |
| --- | --- |
| A source change | waits 50 ms for related saves, then runs one compiler build with `-D caramel_development` |
| A type-check failure | prints `Type check failed` and skips code generation |
| A newer change | stops an obsolete build |
| Asset changes alone | refresh the page without a rebuild |
| The application is building or has failed | its origin answers 503 with a diagnostics page showing the compiler’s output, with secrets and database URLs redacted; the page reloads when the next build is ready |
| Pending migrations | `frappe dev` says so once and serves as soon as `frappe migrate` applies them |
| A changed `.env` | needs a restart |
| A second `frappe dev` for the same project | refuses |
| `frappe doctor` with any failed check | prints `CHECK` for it and exits 1 |

**Terminal**

```bash
frappe logs
frappe logs compiler --follow
frappe doctor
```

**Expect:** `frappe logs` prints the last 200 lines of the application log; `compiler --follow` keeps printing. `frappe doctor` prints `OK` or `CHECK` for each check.

`frappe logs access` prints the proxy’s access log. These logs live in `~/Library/Application Support/Caramel/logs/sites/`. `frappe doctor` checks the toolchain, this installation, dependencies, `.env`, Latte’s services, trusted HTTPS, and the port relay.

## Every site gets two databases {#c-local-databases}

Latte gives each site a development database and a separate spec database, each with a runtime URL and a migration URL. Setup writes them to `.env` with `APP_ORIGIN` and a fresh `APP_SECRET`.

| File | Holds |
| --- | --- |
| `.env` | Private: the origin, the secret, and the development and spec database URLs |
| `.env.test` | Committed test-only settings for every spec worker |
| `config/environment.yml` | Site name, PostgreSQL major, extensions, and domain suffix |
| `db/seeds.cr` | Seed data for frappe seed |

Specs never touch development data. `frappe corretto` migrates the spec database, has Latte clone one for each worker, and gives each worker the values in `.env.test`. [The keys that file cannot set are in the Corretto reference →](https://caramelize.dev/docs/0.15.0/corretto/index.md)

| Condition | Outcome |
| --- | --- |
| `.env` | mode 0600, ignored by Git |
| A database URL in `.env` that differs from Latte’s | the command refuses to run |
| `frappe seed` | runs `App.seed` from `db/seeds.cr` against the development database, and never resets it |
| `frappe db restore FILE` | first saves the current database as a pre-restore backup, then restores FILE; refuses while a development session runs |

**Terminal**

```bash
frappe seed
frappe db dump
frappe db restore backup.dump
frappe db branch create experiment
```

**Expect:** `seed` loads `db/seeds.cr` into the development database. `db dump` saves a backup in a folder for the site under `~/Library/Application Support/Caramel/backups/`. `db restore` saves the current database as a pre-restore backup, then restores the file. `db branch create` clones the development database into branch `experiment`.

A branch is a copy-on-write clone of the development database.

[Branch, diff, and migrate with SugarORM →](https://caramelize.dev/docs/0.15.0/sugarorm/index.md)

## Projects run the release their lock pins {#c-local-releases}

An application’s `shard.lock` pins its Caramel release, and Frappé hands each project command to that release’s Frappé.

| Condition | Outcome |
| --- | --- |
| A missing release | offered for install on a terminal; agents and pipes get the install command |
| `frappe sites` and other commands that need no project | run in the Frappé you called |
| The launchers in `~/.local/bin`, on-demand Latte, and the login item | run the newest installed release |
| A resolver or port relay that differs from the newest release | `frappe doctor` prints the commands that replace them |
| `installations install` on an installed release | builds what is missing, such as its linter |

**Terminal**

```bash
frappe installations
frappe installations install 0.15.0
frappe installations register
frappe installations remove 0.15.0
```

**Expect:** `install` clones the release’s tag into `~/Library/Application Support/Caramel/releases/`, reuses your toolchain when the release pins the same one, builds it and registers it. `register` records the current checkout and needs a built `bin/frappe` and `bin/latte`. `remove` forgets a release.

[See every command’s syntax →](https://caramelize.dev/docs/0.15.0/commands/index.md)

## Each installation pins two language servers {#c-local-editor}

Each installation pins two language servers that use its private toolchain and its pinned Crystal 1.21.1 compiler, never a global or Homebrew Crystal: crystalline 0.20.0 for definitions, hover, limited completion, diagnostics on save, formatting, document symbols, and signature help, and ameba-ls 0.2.0 for lint diagnostics with Fix and Ignore actions. liger is disabled.

**Terminal**

```bash
frappe lsp install
```

**Expect:** The first run needs network access, `git` and Apple’s Command Line Tools, and builds crystalline from source; this can take up to about 20 minutes. Later runs verify the installed tools.

| Condition | Outcome |
| --- | --- |
| `frappe lsp crystalline` or `frappe lsp ameba-ls` | checks the pinned release, then runs a server on stdio for the current project; any editor can run them from the project folder |
| Zed with no matching `frappe` on its login-shell PATH | the servers do not start (see troubleshooting) |

| File | Holds |
| --- | --- |
| `.zed/settings.json` | Generated: runs both servers through frappe in Zed, which must find frappe on its login-shell PATH |

Older projects copy `.zed/settings.json` from `templates/application` in Caramel’s source. `frappe installations register` puts `frappe` in `~/.local/bin`, where Zed’s login-shell PATH finds it. A one-off `PATH=… zed .` can start the servers but may be lost when Zed refreshes the worktree environment. `CARAMEL_TOOLCHAIN_ROOT` is optional, because the installation’s `.caramel-toolchain` names the toolchain. Before it starts a server, `frappe lsp` checks the release pinned in `shard.lock`, as `frappe dev` does.

Several installations can sit side by side. Each pins its own tools, and installations that share a toolchain root keep their versions apart; different Crystal pins need separate toolchain roots. A project is served by the installation whose `frappe` Zed finds, and `frappe lsp` runs under the release the project pins in `shard.lock`. crystalline navigates into the project’s Caramel dependency in `lib/caramel`.

To verify, run `tail -f ~/Library/Logs/Zed/Zed.log`, which shows the `lsp crystalline` server starting, or run `dev: open language server logs` in Zed to see the server’s `frappe lsp:` startup line with its binary, toolchain root and where the root came from.

## Editor messages point to their fix {#c-local-editor-trouble}

| Message or symptom | What to do |
| --- | --- |
| `frappe lsp: no Caramel toolchain is configured` | Run `scripts/install-toolchain` in the Caramel checkout. |
| `frappe lsp: toolchain root …` (ownership, symlink or privacy) | The root must be an owned, private (0700) directory; fix it or point to the right root. |
| `frappe lsp: <root> is not a completed Caramel toolchain` | Rerun `scripts/install-toolchain` to finish it. |
| `frappe lsp: <root> does not provide Crystal <version>` | This installation needs a toolchain root with its Crystal pin. |
| `frappe lsp: <name> <version> is not installed in <root>` | Run `frappe lsp install` for this installation. |
| `frappe lsp: <binary> failed verification` | Remove the named directory and run `frappe lsp install`. |
| `frappe lsp: another editor tools installation is running` | Wait for it to finish. |
| `frappe lsp: checksum mismatch` or `download failed` | Nothing was installed; retry on a working network. |
| `frappe lsp: … loaded a library outside Caramel or macOS` | The binary was not published; report it. |
| `frappe lsp: crystalline build directory preserved for inspection` | The build output above names the failure; remove the directory afterwards. |
| `This project uses Caramel X, not Y; use its matching Caramel installation` | Install that release with `frappe installations install X`, or register its checkout. |
| Zed `failed to spawn command` for `bin/frappe` | Run `scripts/build-frappe`. For `frappe`: the matching binary is absent from Zed’s login-shell PATH, and a one-off `PATH=… zed .` may work at first but not survive a worktree-environment refresh. |
| Zed `Please install crystalline manually and make sure it is on $PATH` | The project settings were not applied, because the worktree is untrusted or `.zed/settings.json` is missing. |
| Zed `Waiting for worktree … to be trusted` | Trust the worktree. |
| After installing | Run `editor: restart language server`. |
| ameba-ls diagnostics while you edit | ameba-ls intentionally disables `Layout/TrailingWhitespace`, `Layout/TrailingBlankLines` and `Lint/Formatting` while you edit. Try `pp! 1` to verify `Lint/DebugCalls` diagnostics instead. |
| Syntax diagnostics in `templates/**` | Expected: those files contain generator placeholders. |
| Memory use | crystalline compiles the project in memory and can use several hundred MB to a few GB of RAM on large projects. |
| Format on save | Uses crystalline, which formats with the pinned Crystal formatter. |

## Removing editor tools changes nothing else {#c-local-editor-remove}

- All editor tools in a root: `rm -rf "<toolchain root>/editor"`, where the root is the first line of the checkout’s `.caramel-toolchain`.
- One version: delete its `editor/ameba-ls/<version>` or `editor/crystalline/<version>-<fingerprint>` directory.

After deleting tools, launches report “not installed”. Nothing else changes.

Prove it

## Run the doctor {#c-local-prove}

**Terminal · inside the application**

```bash
frappe doctor
```

**Passing:** Each check prints `OK`, and the command exits 0. A line starting `CHECK` names what failed, and the exit is 1.

[← Commands](https://caramelize.dev/docs/0.15.0/commands/index.md) · [Build your first application →](https://caramelize.dev/docs/0.15.0/getting-started/index.md)

Caramel 0.15.0 · https://caramelize.dev/docs/0.15.0/local-environment/
