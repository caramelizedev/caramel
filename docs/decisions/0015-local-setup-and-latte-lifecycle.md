# ADR 0015: One recorded toolchain, launchers on PATH, Latte started on demand or at login, and migrated new projects

Date: 2026-09-28

Status: accepted. Amended by [ADR 0016](0016-versioning-and-releases.md) on on-demand start and the launchers.

## Context

The first-run path, `frappe new demo && cd demo && frappe dev`, must work without manual steps:

- Every command would need `CARAMEL_TOOLCHAIN_ROOT` exported, and `scripts/crystal` and `scripts/shards` could silently use whatever Crystal is on `PATH`.
- `frappe` and `latte` would need full paths in the checkout.
- `latte daemon` would need starting by hand, and would stop when that terminal closes.
- A new project would refuse to serve until `frappe migrate` ran.

## Decision

1. **One toolchain lookup.**
   - `Caramel::Latte::Toolchain.locate`, `scripts/crystal`, `scripts/shards` and the Swift installers find the toolchain the same way:
     - `CARAMEL_TOOLCHAIN_ROOT` when set;
     - otherwise the first line of the checkout's `.caramel-toolchain`;
     - otherwise an error naming `scripts/install-toolchain`.
   - The pointer must be a regular file the user owns that no one else can write, and it must name an absolute path. The root must be a private (0700) directory the user owns, not a symlink.
   - There is no fallback to a Crystal found on `PATH`. The variable stays as the override that checks use for test toolchains.
2. **The installer records the toolchain.**
   - Without `--root`, `scripts/install-toolchain` reuses the toolchain `.caramel-toolchain` already names when its receipt is for this release, so a rerun verifies or resumes it. Otherwise it installs into `~/Library/Application Support/Caramel/toolchains/<release>`. `<release>` is 12 hex digits of the pinned selection's digest, so a changed release installs beside the old one.
   - The selection leaves out the launchers, the toolchain's copies of `scripts/crystal` and `scripts/shards` (`launchers/`). A release that changes only them reuses the toolchain: after verifying it, the installer writes the release's launchers over the old ones and records the selection without them. Frappé builds with each release's own `scripts/crystal`; the toolchain's copies serve only its `bin/crystal`.
   - After a fresh install or a verified reuse, it writes `.caramel-toolchain`. It is the only writer; `frappe lsp install` does not write the pointer.
3. **Launchers on PATH.**
   - `frappe installations register` writes `~/.local/bin/frappe` and `~/.local/bin/latte`. Each is a marked script that `exec`s the binary of the newest installed release, which may be this checkout's ([ADR 0016](0016-versioning-and-releases.md) decision 5).
   - It refuses, before writing either file, when a name is taken by a file Caramel did not create, or when the directory is writable by others.
   - `frappe installations remove` deletes the launchers that run the removed checkout.
4. **Latte's lifecycle.**
   - **On demand.** When no daemon serves the per-user state, every command that needs Latte services runs `latte daemon --detach`: the newest installed release's `latte`, or the one beside the running `frappe` when that release is the newest ([ADR 0016](0016-versioning-and-releases.md)).
     - The daemon moves into its own session, so Ctrl-C and closing the terminal leave it running.
     - It writes its output to `logs/latte.log`, which is retained like the service logs.
     - Frappé never starts a daemon for a `CARAMEL_HOME` someone set. Checks and fixtures run their own daemons there.
   - **`latte stop`.** It asks the daemon to exit through its control socket (`POST /v1/daemon/stop`) and waits for the instance lock to be released. Services keep running and are adopted by the next daemon, as in [ADR 0012](0012-latte-supervision-watching-branching.md).
   - **Opt-in login item.** `latte service install` writes `~/Library/LaunchAgents/dev.caramel.latte.plist` and loads it into `gui/<uid>`.
     - The agent runs `latte daemon --detach` with `RunAtLoad` and `AbandonProcessGroup`, and no `KeepAlive`.
     - Installing takes over from a running daemon. `latte service uninstall` unloads the agent and deletes it.
5. **A new project starts migrated.**
   - `frappe new` and `frappe setup` apply pending migrations after they configure the site.
   - When `frappe dev` finds pending migrations, it says so once, retries quietly every second, and serves as soon as they are applied.

## Reasons

- The installer is the only component that knows where it installed. Recording that per checkout replaces an environment variable every shell had to carry. The ownership checks keep another local user from redirecting the compiler this user runs.
- Launcher reuse avoids a new toolchain for every launcher edit (a 39 s download, about 491 MB, cold compiler caches and a 20-minute crystalline rebuild).
- `~/.local/bin` is the per-user executable directory that is usually already on `PATH`, so no shell profile is edited. Marked scripts make "Caramel created this file" provable. Unlike symlinks, they let each binary find its checkout through its own executable path.
- Starting the service supervisor on demand removes a manual step without adding an agent daemon. Frappé commands stay one-shot and stateless, and the daemon still carries no agent protocol state. The login item is opt-in because it changes what runs at login.
- launchd kills a job's whole process group when the job exits. Without `AbandonProcessGroup`, a crash or `latte stop` would take PostgreSQL, CoreDNS and Caddy with it.
- Rejected: `KeepAlive` on the login item, because a daemon that exits since another one is already running would restart in a loop, and on-demand start already recovers from a crash.
- A project that serves right after `frappe new` is the expected first run.
