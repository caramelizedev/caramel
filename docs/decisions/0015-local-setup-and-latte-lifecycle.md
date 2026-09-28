# ADR 0015: One recorded toolchain, launchers on PATH, Latte started on demand or at login, and migrated new projects

Date: 2026-09-28

Status: accepted. Amends [RFC-0004](../rfc.md) §2.1 and [RFC-0005](../rfc.md) §2.1. [ADR 0016](0016-versioning-and-releases.md) amends on-demand start and the launchers: both run the newest installed release.

## Context

The first-run path, `frappe new demo && cd demo && frappe dev`, needed four manual steps that the RFCs never asked for:

- Every command needed `CARAMEL_TOOLCHAIN_ROOT` exported. `scripts/crystal` and `scripts/shards` silently used whatever Crystal was on `PATH` without it.
- `frappe` and `latte` had to be called by their full paths in the checkout.
- `latte daemon` had to be started by hand in a terminal, and it stopped when that terminal closed.
- A new project refused to serve until `frappe migrate` ran. `frappe dev` then printed the same refusal every second.

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
   - After a fresh install or a verified reuse, it writes `.caramel-toolchain`. It is the only writer; `frappe lsp install` no longer writes the pointer.
3. **Launchers on PATH.**
   - `frappe installations register` writes `~/.local/bin/frappe` and `~/.local/bin/latte`. Each is a marked script that `exec`s this checkout's binary.
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
- `~/.local/bin` is the per-user executable directory that is usually already on `PATH`, so no shell profile is edited. Marked scripts make "Caramel created this file" provable. Unlike symlinks, they let each binary find its checkout through its own executable path.
- Starting the service supervisor on demand removes a manual step without adding an agent daemon. Frappé commands stay one-shot and stateless (RFC-0005), and the daemon still carries no agent protocol state. The login item is opt-in because it changes what runs at login.
- launchd kills a job's whole process group when the job exits. Without `AbandonProcessGroup`, a crash or `latte stop` would take PostgreSQL, CoreDNS and Caddy with it. With `KeepAlive`, a daemon that exits because another one is already running would restart in a loop; on-demand start already recovers from a crash.
- A project that serves right after `frappe new` is the first run the RFCs describe.

Principles followed:

- Manifesto 3: native processes and Unix sockets, with no containers and no shell activation.
- Manifesto 4: never overwrite a file Caramel did not create; services survive daemon exits.
- Manifesto 6: Frappé stays a set of stateless one-shot tools. The daemon it starts supervises processes, not an agent protocol.
- Manifesto 7: `frappe new demo && cd demo && frappe dev` works on the first try.
- RFC-0008 §2.6: every refusal names its remedy, such as "Run scripts/install-toolchain."

## Verification

- `spec/latte/toolchain_spec.cr` covers the lookup precedence and refuses a pointer others can write, a symlinked pointer and a relative root.
- `scripts/check native`:
  - `spec/native/toolchain_installer_spec.cr` covers the pointer written after installing and after an offline verification, and the default root. A bare rerun reuses the recorded toolchain of the same release, and a changed release installs under `CARAMEL_HOME/toolchains`.
  - `spec/native/login_item_spec.cr` loads a login item into the user's GUI domain. It checks that the item runs at load, that its children outlive the job and its unloading, and that it uninstalls cleanly. Without `AbandonProcessGroup`, launchd kills those children.
- `spec/latte/login_item_spec.cr` parses the rendered agent with `plutil`.
- `spec/frappe/launchers_spec.cr` covers quoting, replacing Caramel's own launchers, refusing foreign files and shared directories, and removal.
- `spec/frappe/latte_client_spec.cr` covers the on-demand start and the log line reported when a start fails. `spec/latte/server_spec.cr` covers a stop request being answered before the server closes.
- `scripts/check latte-daemon` runs `frappe services start` with no daemon. It checks that the detached daemon outlives Frappé in its own session with a private log, and that `latte stop` ends it.
- `scripts/check frappe-project` and `scripts/check schema-diff` start from projects that `frappe new` has migrated. `scripts/check frappe-project --dev` shows a pending migration and serves once it is applied.
