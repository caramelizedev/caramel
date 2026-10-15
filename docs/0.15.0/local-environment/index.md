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
| Log size before Latte’s sweep rolls it (the file moves to `.previous`) | 1 MiB, checked once a second |
| Development sessions per project | 1 |
| `frappe logs` lines | 200 |
| Wait for related saves before a build | 50 ms |
| First `crystalline` build | up to 20 minutes |
| Latte’s DNS port; Caddy’s ports behind the relay | 15353; 18080 and 18443 |
| Toolchain root directory mode | 0700 |
| `.env` mode | 0600 |

## Latte runs three services, not your application {#c-local-latte}

Latte is a per-user service supervisor for macOS. It runs one shared PostgreSQL 18 cluster on a private Unix socket, CoreDNS, and a Caddy HTTPS proxy, and keeps a registry of your sites. Applications run under `frappe dev` in your terminal, not under Latte. Latte also runs a trace collector; the Crema reference describes it.

| Condition | Outcome |
| --- | --- |
| A Frappé command needs the services and Latte is not running | Frappé runs `latte daemon --detach` |
| The daemon | outlives the terminal |
| Stopping the daemon | leaves the services running; the next daemon adopts them |
| `latte daemon` without `--detach` | runs Latte in the current terminal |
| A log past 1 MiB at Latte’s once-a-second sweep | moves to a `.previous` file, so a log can pass 1 MiB between sweeps |
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

**Expect:** `frappe services`, `start` and `stop` print one line each for `postgres`, `dns` and `proxy` with its state, then `collector running (127.0.0.1:4318)`; `start` starts Latte first when needed, and after `stop` the services read `stopped` while Latte keeps running. `latte stop` prints `Latte stopped; its services were left as they were (frappe services stop stops them).`, or `Latte is not running.` `latte service install` prints `Latte now starts when you log in (~/Library/LaunchAgents/dev.caramel.latte.plist), and is running.` `latte service uninstall` prints `Latte no longer starts at login; the Latte it started has stopped.` and that the services keep running. `latte version` prints `Latte 0.15.0 (control API 1, 2)`.

The login item is opt-in. `latte service install` writes `~/Library/LaunchAgents/dev.caramel.latte.plist`, takes over from a running daemon, and starts Latte now.

Latte’s logs live in `~/Library/Application Support/Caramel/logs/`: `latte.log` for the daemon, and `postgres.log`, `dns.log`, and `proxy.log` for the services.

The menu bar app shows the services and sites, opens a site, its folder, or its logs, and starts or stops the services. Build it from a Caramel checkout with `scripts/build-latte-menu`, which writes `bin/Latte.app`.

## Setup runs once per machine {#c-local-setup}

Caramel 0.15.0 runs on Apple Silicon with Apple’s Command Line Tools, and installs from source. From a checkout of the release, these steps install the pinned toolchain, put `frappe` and `latte` in `~/.local/bin`, and connect `.caramel` names to Latte. Add `~/.local/bin` to your shell’s `PATH` before the fourth step: from there on the commands run the installed launchers. Each step is safe to run again; `prepare` refuses an existing bundle folder, so the `rm -rf` clears it first.

**Terminal · inside the caramel checkout**

```bash
scripts/install-toolchain
scripts/build-release
bin/frappe installations register
frappe services start
rm -rf /private/tmp/caramel-integration-bundle && scripts/install-local-integration prepare /private/tmp/caramel-integration-bundle && sudo scripts/install-local-integration apply /private/tmp/caramel-integration-bundle
latte trust install
```

**Expect:** `install-toolchain` installs the pinned Crystal and PostgreSQL tools into a private 0700 root and writes its path to `.caramel-toolchain`. `build-release` installs the locked dependencies and builds `bin/frappe`, `bin/latte` and the linter. `installations register` prints `Registered Caramel 0.15.0: PATH` and writes the launchers to `~/.local/bin`. `frappe services start` prints the three services and the collector with their states. `prepare` prints a JSON review with `bundle`, `installs`, `runs_as` and `sha256`; `apply` asks for your password and prints `Installed Caramel resolver and unprivileged standard-port relay.` `latte trust install` prints `Latte certificate trust installed.`

| Condition | Outcome |
| --- | --- |
| `prepare` | builds the integration bundle as you; as root it refuses with `Prepare the installation as the ordinary installing user` |
| `prepare` with an existing bundle folder | fails with `File exists` |
| `apply` | installs it as an administrator; refuses unless run through `sudo` |
| `apply` while another release’s integration is installed | refuses with `A different Caramel integration is installed; uninstall it explicitly first`; `frappe doctor` then prints the `prepare`, `uninstall` and `apply` sequence that replaces it |
| `scripts/install-local-integration status` | prints a JSON object with `current`, `stale` or `absent` for `relay`, `plist` and `resolver`, without `sudo` |
| The resolver `/etc/resolver/caramel` | sends `.caramel` lookups to Latte’s DNS on `127.0.0.1` port 15353 |
| The launchd relay `/Library/PrivilegedHelperTools/dev.caramel.ports`, loaded by `/Library/LaunchDaemons/dev.caramel.ports.plist` | forwards ports 80 and 443 to Caddy on 18080 and 18443 |
| The receipt `/Library/Application Support/Caramel/local-integration.json` | records what `apply` installed, and `uninstall` removes only files that still match it |
| `latte trust install` | adds Latte’s certificate authority, named `Caramel Local Authority` in Keychain Access, to the keychain `security default-keychain -d user` names |
| `latte trust install` after the authority was rotated | refuses with `Remove the previously installed Latte certificate before rotating its authority` |
| `sudo scripts/install-local-integration uninstall` and `latte trust remove` | undo these steps; `uninstall` leaves certificate trust alone |

## Every site gets its own origin {#c-local-sites}

A site’s origin is `https://NAME.caramel`.

| Condition | Outcome |
| --- | --- |
| `frappe new NAME` | registers the application with Latte as a site, writes its private `.env`, and applies its migrations |
| `frappe setup` in a cloned project | installs the locked dependencies and takes the same steps, keeping existing files |
| A site’s state in `frappe sites` | is `running`, `building`, `build-error`, `stopped`, `unavailable` or `unknown`; `(terminal)` after it marks a site that a `frappe dev` session serves |
| `frappe sites remove NAME` | unregisters the site and keeps its folder, databases, credentials, logs, and backups; `frappe setup` registers it again |
| `frappe sites remove NAME` for a name Latte does not know | exits 1 with `No registered site is named NAME` |
| `domain_suffix` in `config/environment.yml` | `caramel`, `test`, or `localhost` |
| A `.localhost` name | resolves to loopback without a resolver entry, but `frappe dev`, `frappe open`, and `frappe doctor` still need the port relay and `latte trust install`, because they require the origin to reach loopback with trusted HTTPS on the standard port |
| Switching the suffix | change it, delete `.env`, and run `frappe setup`, which registers a new site with its own databases |

**Terminal**

```bash
frappe sites
frappe sites remove demo
frappe open
```

**Expect:** `frappe sites` prints one line per site: its name, state, origin and folder. `frappe sites remove demo` prints `Removed demo (https://demo.caramel) from Latte.`, that its folder, databases, credentials, logs and backups were kept, and the `frappe setup` command that registers it again. `frappe open` opens the origin in your browser.

## Source changes rebuild the application {#c-local-dev}

`frappe dev` builds the application, serves it at its origin, and opens the browser when the first build is ready. It watches `src`, `config`, `db`, `app`, `public`, `shard.yml`, `shard.lock`, and `.env` with kqueue. Ctrl-C stops the project.

**Terminal**

```bash
frappe dev
frappe dev --no-open
frappe dev --branch experiment
```

**Expect:** `frappe dev` builds the application, serves it at its origin and opens the browser when the first build is ready; `--no-open` leaves the browser alone. The terminal prints `Type check passed in N ms` or `Type check failed in N ms` when the compiler finishes its semantic stages, then `Building NAME…`. `--branch experiment` runs against the database branch that `frappe db branch create experiment` made.

| Condition | Outcome |
| --- | --- |
| A source change | waits 50 ms for related saves, then runs one compiler build with `-D caramel_development` |
| A type-check failure | prints `Type check failed in N ms` and skips code generation |
| A newer change | stops an obsolete build |
| Asset changes alone | refresh the page without a rebuild |
| The application is building or has failed | answers 503 at its origin with a diagnostics page showing the compiler’s output, with secrets and database URLs redacted; the page reloads when the next build is ready |
| Pending migrations | `frappe dev` says so once and serves as soon as `frappe migrate` applies them |
| A changed `.env` | needs a restart |
| A second `frappe dev` for the same project | refuses |

**Terminal**

```bash
frappe logs
frappe logs compiler --follow
```

**Expect:** `frappe logs` prints the last 200 lines of the application log through `tail`; `compiler --follow` keeps printing. A missing log exits 1.

`frappe logs access` prints the proxy’s access log. These logs live in `~/Library/Application Support/Caramel/logs/sites/`.

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
| A `DATABASE_URL` or `MIGRATION_DATABASE_URL` in `.env` that differs from Latte’s | refuses with `KEY differs from this project’s Latte credentials; command refused` |
| An `APP_ORIGIN` in `.env` that differs from the project’s | refuses with `APP_ORIGIN differs from this project; run frappe setup` |
| `frappe seed` | runs `App.seed` from `db/seeds.cr` against the development database, and never resets it |
| `frappe db restore FILE` | saves the current database as a pre-restore backup first, then restores FILE; refuses while a development session runs |
| `frappe db branch create NAME` that is not a lowercase letter followed by up to 30 lowercase letters, digits or underscores | exits 1 with the usage message |

**Terminal**

```bash
frappe seed
frappe db dump
frappe db restore backup.dump
frappe db branch create experiment
```

**Expect:** `seed` runs `App.seed` against the development database. `db dump` saves a backup under `~/Library/Application Support/Caramel/backups/SITE_ID/`. `db restore` saves the current database as a pre-restore backup, then restores the file. `db branch create` clones the development database into branch `experiment` and prints its connection URL.

A branch is a copy-on-write clone of the development database.

[Branch, diff, and migrate with SugarORM →](https://caramelize.dev/docs/0.15.0/sugarorm/index.md)

## Projects run the release their lock pins {#c-local-releases}

An application’s `shard.lock` pins its Caramel release, and Frappé hands each project command to that release’s Frappé.

| Condition | Outcome |
| --- | --- |
| A missing release | is offered for install on a terminal; agents and pipes get the install command |
| `frappe sites` and other commands that need no project | run in the Frappé you called |
| The launchers in `~/.local/bin`, on-demand Latte, and the login item | run the newest installed release |
| A resolver or port relay that differs from the newest release | fails `frappe doctor`’s `Port relay` check, which prints the `prepare`, `uninstall` and `apply` commands that replace them |
| `installations install` on an installed release | builds what is missing, such as its linter |

**Terminal**

```bash
frappe installations
frappe installations install 0.15.0
frappe installations register
frappe installations remove 0.15.0
```

**Expect:** `frappe installations` prints one line per release, its version then its root, with `(this installation)` after the one you called; with none it says so and names the two ways to install one. `install` clones the release’s tag into `~/Library/Application Support/Caramel/releases/VERSION`, reuses your toolchain when the release pins the same one, builds it and registers it. `register` prints `Registered Caramel 0.15.0: PATH` and needs a built `bin/frappe` and `bin/latte`; without them it exits 1 naming the build script. `remove` forgets a release.

[See every command’s syntax →](https://caramelize.dev/docs/0.15.0/commands/index.md)

## Each installation pins two language servers {#c-local-editor}

Each installation pins two language servers that use its private toolchain and the Crystal compiler the release pins, never a global or Homebrew Crystal: crystalline 0.20.0 for definitions, hover, limited completion, diagnostics on save, formatting, document symbols, and signature help, and ameba-ls 0.2.0 for lint diagnostics with Fix and Ignore actions. liger is disabled. The Current release page states the Crystal pin.

**Terminal**

```bash
frappe lsp install
```

**Expect:** The first run needs network access, `git` and Apple’s Command Line Tools, and prints `Building crystalline 0.20.0 with Crystal VERSION (this can take up to 20 minutes)…` while it builds crystalline from source. Later runs verify the installed tools.

| Condition | Outcome |
| --- | --- |
| `frappe lsp crystalline` or `frappe lsp ameba-ls` | checks the pinned release, then runs a server on stdio for the current project; any editor can run them from the project folder |
| Zed with no matching `frappe` on its login-shell PATH | does not start the servers (see troubleshooting) |

| File | Holds |
| --- | --- |
| `.zed/settings.json` | Generated: runs both servers through frappe in Zed, which must find frappe on its login-shell PATH |

Older projects copy `.zed/settings.json` from `templates/application` in Caramel’s source. `frappe installations register` puts `frappe` in `~/.local/bin`, where Zed’s login-shell PATH finds it. A one-off `PATH=… zed .` starts the servers until Zed refreshes the worktree environment, which drops that PATH. `CARAMEL_TOOLCHAIN_ROOT` is optional, because the installation’s `.caramel-toolchain` names the toolchain. Before it starts a server, `frappe lsp` checks the release pinned in `shard.lock`, as `frappe dev` does.

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
| Zed `failed to spawn command` for `bin/frappe` | Run `scripts/build-frappe`. For `frappe`: the matching binary is absent from Zed’s login-shell PATH; a one-off `PATH=… zed .` works until a worktree-environment refresh. |
| Zed `Please install crystalline manually and make sure it is on $PATH` | The project settings were not applied, because the worktree is untrusted or `.zed/settings.json` is missing. |
| Zed `Waiting for worktree … to be trusted` | Trust the worktree. |
| After installing | Run `editor: restart language server`. |
| ameba-ls diagnostics while you edit | ameba-ls intentionally disables `Layout/TrailingWhitespace`, `Layout/TrailingBlankLines` and `Lint/Formatting` while you edit. Try `pp! 1` to verify `Lint/DebugCalls` diagnostics instead. |
| Syntax diagnostics in `templates/**` | Expected: those files contain generator placeholders. |
| Memory use | crystalline compiles the project in memory; its use grows with the project and its dependencies. |
| Format on save | Uses crystalline, which formats with the pinned Crystal formatter. |

## Removing editor tools changes nothing else {#c-local-editor-remove}

The root is the first line of the checkout’s `.caramel-toolchain`.

| Condition | Outcome |
| --- | --- |
| `rm -rf "ROOT/editor"` | removes every editor tool in that root |
| Deleting `ROOT/editor/ameba-ls/VERSION` or `ROOT/editor/crystalline/VERSION-FINGERPRINT` | removes one version |
| A launch after deleting | prints `frappe lsp: NAME VERSION is not installed in ROOT`; nothing else changes |

Prove it

## Run the doctor {#c-local-prove}

**Terminal · inside the application**

```bash
frappe doctor
```

**Passing:** Each of the nine checks prints `OK` and its label, from `Project configuration` to `Port relay`, and the command exits 0. A failed check prints `CHECK LABEL: reason` instead, and the exit is 1. A stale resolver or relay fails `Port relay` with the `prepare`, `uninstall` and `apply` commands that replace them.

[← Commands](https://caramelize.dev/docs/0.15.0/commands/index.md) · [Build your first application →](https://caramelize.dev/docs/0.15.0/getting-started/index.md)

Caramel 0.15.0 · https://caramelize.dev/docs/0.15.0/local-environment/
