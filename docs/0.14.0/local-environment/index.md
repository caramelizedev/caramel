Reference / Local environment

# A local home for every app.

Latte runs PostgreSQL, DNS, and HTTPS on your Mac, and Frappé builds, serves, and checks each application at its own named origin.

## What Latte runs {#c-local-latte}

Latte is a per-user service supervisor for macOS. It runs one shared PostgreSQL 18 cluster on a private Unix socket, CoreDNS, and a Caddy HTTPS proxy, and keeps a registry of your sites. Applications run under `frappe dev` in your terminal, not under Latte.

When a Frappé command needs the services and Latte is not running, Frappé runs `latte daemon --detach`. The daemon outlives the terminal. Stopping it leaves the services running, and the next daemon adopts them.

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

The login item is opt-in. `latte service install` writes `~/Library/LaunchAgents/dev.caramel.latte.plist`, takes over from a running daemon, and starts Latte now. `latte daemon` without `--detach` runs Latte in the current terminal.

Latte’s logs live in `~/Library/Application Support/Caramel/logs/`: `latte.log` for the daemon, and `postgres.log`, `dns.log`, and `proxy.log` for the services. Past one MiB, a log’s last MiB moves to a `.previous` file.

The menu bar app shows the services and sites, opens a site, its folder, or its logs, and starts or stops the services. It does not start Latte. Build it from a Caramel checkout with `scripts/build-latte-menu`, which writes `bin/Latte.app`.

## Set up a Mac once {#c-local-setup}

Caramel 0.14.0 runs on Apple Silicon with Apple’s Command Line Tools, and installs from source. From a checkout of the release, these steps install the pinned toolchain, put `frappe` and `latte` in `~/.local/bin`, and connect `.caramel` names to Latte.

**Terminal · inside the caramel checkout**

```bash
scripts/install-toolchain
scripts/build-release
bin/frappe installations register
frappe services start
scripts/install-local-integration prepare /private/tmp/caramel-integration-bundle && sudo scripts/install-local-integration apply /private/tmp/caramel-integration-bundle
latte trust install
```

`prepare` builds the integration bundle as you, and `apply` installs it as an administrator. It adds the resolver `/etc/resolver/caramel`, which sends `.caramel` lookups to Latte’s DNS on port 15353, and a launchd relay from ports 80 and 443 to Caddy on 18080 and 18443. `latte trust install` adds Latte’s certificate authority to your default keychain. `sudo scripts/install-local-integration uninstall` and `latte trust remove` undo these steps.

## Sites and origins {#c-local-sites}

`frappe new NAME` registers the application with Latte as a site, writes its private `.env`, and applies its migrations. Its origin is `https://NAME.caramel`. In a cloned project, `frappe setup` installs the locked dependencies and takes the same steps, keeping existing files.

**Terminal**

```bash
frappe sites
frappe sites remove demo
frappe open
```

`frappe sites` prints each site’s name, state, origin, and folder; `(terminal)` marks a site that a `frappe dev` session serves. `frappe sites remove NAME` unregisters a site but keeps its folder, databases, credentials, logs, and backups; `frappe setup` registers it again. `frappe open` opens the origin in your browser.

The suffix is `domain_suffix` in `config/environment.yml`: `caramel`, `test`, or `localhost`. macOS and browsers resolve `.localhost` names to loopback without a resolver entry. To switch, change the suffix, delete `.env`, and run `frappe setup`, which registers a new site with its own databases.

That removes only the resolver step. `frappe dev`, `frappe open`, and `frappe doctor` require the origin to reach loopback with trusted HTTPS on the standard port, so a `.localhost` site still needs the port relay and `latte trust install`.

## The development loop {#c-local-dev}

`frappe dev` builds the application, serves it at its origin, and opens the browser when the first build is ready. It watches `src`, `config`, `db`, `app`, `public`, `shard.yml`, `shard.lock`, and `.env` with kqueue. Ctrl-C stops the project. One development session runs per project at a time.

**Terminal**

```bash
frappe dev
frappe dev --no-open
frappe dev --branch experiment
```

A source change waits 50 ms for related saves, then runs one compiler build with `-D caramel_development`. The terminal prints `Type check passed` or `Type check failed` as soon as the compiler finishes its semantic stages, and a failure skips code generation. A newer change stops an obsolete build. Asset changes alone refresh the page without a rebuild.

While the application builds or fails, its origin answers 503 with a diagnostics page showing the compiler’s output, with secrets and database URLs redacted. The page reloads when the next build is ready. With pending migrations, `frappe dev` says so once and serves as soon as `frappe migrate` applies them. A changed `.env` needs a restart. `--branch NAME` runs against a database branch that `frappe db branch create NAME` made.

**Terminal**

```bash
frappe logs
frappe logs compiler --follow
frappe doctor
```

`frappe logs` prints the last 200 lines of the application or compiler log, and `--follow` keeps printing; `frappe logs access` prints the proxy’s access log. These logs live in `~/Library/Application Support/Caramel/logs/sites/`. `frappe doctor` checks the toolchain, this installation, dependencies, `.env`, Latte’s services, trusted HTTPS, and the port relay. It prints `OK` or `CHECK` for each, and exits 1 when any check fails.

## Databases and environment files {#c-local-databases}

Latte gives each site a development database and a separate spec database, each with a runtime URL and a migration URL. Setup writes them to `.env` with `APP_ORIGIN` and a fresh `APP_SECRET`. `.env` is private (mode 0600) and ignored by Git; commands refuse to run when its database URLs differ from Latte’s.

- `.env`: Private: the origin, the secret, and the development and spec database URLs
- `.env.test`: Committed test-only settings for every spec worker
- `config/environment.yml`: Site name, PostgreSQL major, extensions, and domain suffix
- `db/seeds.cr`: Seed data for frappe seed

Specs never touch development data. `frappe corretto` migrates the spec database, has Latte clone one for each worker, and gives each worker the values in `.env.test`. That file cannot set Caramel’s own keys, such as `APP_SECRET`, `DATABASE_URL`, or any `SPEC_` key.

**Terminal**

```bash
frappe seed
frappe db dump
frappe db restore backup.dump
frappe db branch create experiment
```

`frappe seed` runs `App.seed` from `db/seeds.cr` against the development database, and never resets it. `frappe db dump` saves a backup in `~/Library/Application Support/Caramel/backups/`, in a folder for the site. `frappe db restore FILE` first saves the current database as a pre-restore backup, then restores FILE. It refuses while a development session runs. A branch is a copy-on-write clone of the development database.

[Branch, diff, and migrate with SugarORM →](https://caramelize.dev/docs/0.14.0/sugarorm/index.md)

## Installations and pinned releases {#c-local-releases}

An application’s `shard.lock` pins its Caramel release, and Frappé hands each project command to that release’s Frappé. A missing release is offered for install on a terminal; agents and pipes get the install command. Commands that need no project, such as `frappe sites`, run in the Frappé you called.

**Terminal**

```bash
frappe installations
frappe installations install 0.14.0
frappe installations register
frappe installations remove 0.14.0
```

`install` clones the release’s tag into `~/Library/Application Support/Caramel/releases/`, reuses your toolchain when the release pins the same one, builds it, and registers it. On an installed release, it builds what is missing, such as its linter. `register` records the current checkout, which needs a built `bin/frappe` and `bin/latte`. `remove` forgets a release.

The launchers in `~/.local/bin`, on-demand Latte, and the login item run the newest installed release. The resolver and port relay must match it too; `frappe doctor` prints the commands that replace them when they differ.

[See every command’s syntax →](https://caramelize.dev/docs/0.14.0/commands/index.md)

## Editor tools {#c-local-editor}

Each installation pins two language servers that use its private toolchain and its pinned Crystal 1.21.1 compiler, never a global or Homebrew Crystal: crystalline 0.20.0 for definitions, hover, limited completion, diagnostics on save, formatting, document symbols, and signature help, and ameba-ls 0.2.0 for lint diagnostics with Fix and Ignore actions. liger is disabled.

**Terminal**

```bash
frappe lsp install
```

The first install needs network access, `git`, and Apple’s Command Line Tools, and builds crystalline from source in up to about 20 minutes; later runs verify the installed tools and take seconds. `frappe lsp crystalline` and `frappe lsp ameba-ls` run a server on stdio for the current project, after checking its pinned release. Any editor can run them from the project folder.

- `.zed/settings.json`: Generated: runs both servers through frappe in Zed, which must find frappe on its login-shell PATH

Older projects copy `.zed/settings.json` from `templates/application` in Caramel’s source. `frappe installations register` puts `frappe` in `~/.local/bin`, where Zed’s login-shell PATH finds it. A one-off `PATH=… zed .` can start the servers but may be lost when Zed refreshes the worktree environment. `CARAMEL_TOOLCHAIN_ROOT` is optional, because the installation’s `.caramel-toolchain` names the toolchain. Before it starts a server, `frappe lsp` checks the release pinned in `shard.lock`, as `frappe dev` does.

Several installations can sit side by side. Each pins its own tools, and installations that share a toolchain root keep their versions apart; different Crystal pins need separate toolchain roots. A project is served by the installation whose `frappe` Zed finds, and `frappe lsp` runs under the release the project pins in `shard.lock`. crystalline navigates into the project’s Caramel dependency in `lib/caramel`.

To verify, run `tail -f ~/Library/Logs/Zed/Zed.log`, which shows the `lsp crystalline` server starting, or run `dev: open language server logs` in Zed to see the server’s `frappe lsp:` startup line with its binary, toolchain root and where the root came from.

## Troubleshooting {#c-local-editor-trouble}

- `frappe lsp: no Caramel toolchain is configured`: run `scripts/install-toolchain` in the Caramel checkout.
- `frappe lsp: toolchain root …` (ownership, symlink or privacy): the root must be an owned, private (0700) directory; fix it or point to the right root.
- `frappe lsp: <root> is not a completed Caramel toolchain`: rerun `scripts/install-toolchain` to finish it.
- `frappe lsp: <root> does not provide Crystal <version>`: this installation needs a toolchain root with its Crystal pin.
- `frappe lsp: <name> <version> is not installed in <root>`: run `frappe lsp install` for this installation.
- `frappe lsp: <binary> failed verification`: remove the named directory and run `frappe lsp install`.
- `frappe lsp: another editor tools installation is running`: wait for it to finish.
- `frappe lsp: checksum mismatch` or `download failed`: nothing was installed; retry on a working network.
- `frappe lsp: … loaded a library outside Caramel or macOS`: the binary was not published; report it.
- `frappe lsp: crystalline build directory preserved for inspection`: the build output above names the failure; remove the directory afterwards.
- `This project uses Caramel X, not Y; use its matching Caramel installation`: install that release with `frappe installations install X`, or register its checkout.
- Zed `failed to spawn command` for `bin/frappe`: run `scripts/build-frappe`. For `frappe`: the matching binary is absent from Zed’s login-shell PATH, and a one-off `PATH=… zed .` may work at first but not survive a worktree-environment refresh.
- Zed `Please install crystalline manually and make sure it is on $PATH`: the project settings were not applied, because the worktree is untrusted or `.zed/settings.json` is missing.
- Zed `Waiting for worktree … to be trusted`: trust the worktree.
- After installing, run `editor: restart language server`.
- ameba-ls intentionally disables `Layout/TrailingWhitespace`, `Layout/TrailingBlankLines` and `Lint/Formatting` while you edit. Try `pp! 1` to verify `Lint/DebugCalls` diagnostics instead.
- Syntax diagnostics in the framework’s `templates/**` are expected: those files contain generator placeholders.
- crystalline compiles the project in memory and can use several hundred MB to a few GB of RAM on large projects.
- Format on save uses crystalline, which formats with the pinned Crystal formatter.

## Removal {#c-local-editor-remove}

- All editor tools in a root: `rm -rf "<toolchain root>/editor"`, where the root is the first line of the checkout’s `.caramel-toolchain`.
- One version: delete its `editor/ameba-ls/<version>` or `editor/crystalline/<version>-<fingerprint>` directory.

After deleting tools, launches report “not installed”. Nothing else changes.

[← All recipes](https://caramelize.dev/cookbook/0.14.0/) · [Build your first application →](https://caramelize.dev/docs/0.14.0/getting-started/index.md)

Caramel 0.14.0 · https://caramelize.dev/docs/0.14.0/local-environment/
