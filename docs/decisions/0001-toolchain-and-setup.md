# ADR 0001: A pinned mise toolchain supplies every tool, recorded once per checkout and never found on PATH

Date: 2026-09-19

Status: accepted.

## Context

Caramel needs Crystal, Shards, Caddy, PostgreSQL and their native libraries at known versions on a developer's machine, without Homebrew, a global version manager or a compiled PostgreSQL. The first run, from a new project to a served page, must work without exported variables, full paths or a manual migration. Browser behaviour (morphing, partials, islands, server-sent events through the local proxy) can only be confirmed in a browser, and that check must not change the machine's resolver, ports or certificate trust.

## Decision

1. **mise, pinned and behind an isolated adapter, installs prebuilt tools.** Caramel writes no version manager of its own and compiles no PostgreSQL during setup.
2. **mise serves contributors; its use for consumers is provisional.** The application-facing environment manifest stays authoritative. If a consumer adapter uses mise, it generates mise's configuration from that manifest, and users maintain no second list of versions.
3. **The selection is one authored file and one lock with checksums.** Changing a tool version or a backend is a reviewed dependency change.
4. **mise owns tool installation and nothing else.** Frappé is the developer's interface, Shards owns Crystal dependencies, and Latte ([ADR 0012](0012-latte.md)) owns databases, services, DNS, certificates and the proxy. Database data lives outside tool installations, so installing, upgrading or removing a tool never creates or removes a database.
5. **What the Crystal archive lacks comes from the managed toolchain, never from the host.** The archive's bundled Shards is used, and OpenSSL and GMP are managed tools. The PostgreSQL library directory is never a compiler search path.
6. **Installed tools work offline; offline reinstallation is not promised.** A consumer adapter retains verified artifacts or defines its supported cache, and tests recovery from missing or corrupt files.
7. **mise runs on Caramel-owned configuration and a filtered environment.** System and global mise configuration are overridden, and the discovered configuration is validated before any installation hook or task runs. The adapter is not a security boundary for untrusted projects.
8. **The installer records the toolchain once per checkout, and nothing falls back to `PATH`.** Every component finds the toolchain through one lookup. The installer is the only writer of the record. The record and the toolchain root must be owned by the user and writable by no one else.
9. **A toolchain is named by the digest of its selection.** A changed selection installs beside the old one. The compiler launcher scripts are outside the digest, so a release that changes only them reuses the toolchain.
10. **`frappe` and `latte` are marked launcher scripts in `~/.local/bin`.** Each runs the newest installed release ([ADR 0016](0016-versioning-and-releases.md)). Registration refuses when a name is taken by a file Caramel did not create or when the directory is writable by others.
11. **A new project starts migrated.** Creating or setting up a project applies its pending migrations unless the developer opts out.
12. **Browser acceptance drives a pinned headless Chrome over WebDriver, from Crystal.** The check runs a generated application behind Latte's real proxy on a `.localhost` site. It never downloads the browser or its driver, and verifies both executables before it starts them.
13. **A check never adds trust.** The browser session accepts Latte's untrusted local authority for that session only. A run fails, and its fixture authority keys are deleted, if the proxy installs a root certificate.

## Reasons

- Prebuilt upstream archives install in seconds and run with no network once installed.
- Pinned versions with recorded checksums make every toolchain change a reviewed diff.
- Separate prefixes let several Crystal versions coexist and leave the host's shell and tools untouched.
- Bundling GMP lets an application use the standard library's exact arithmetic in every managed build, without a link annotation of its own.
- Rejected: the whole PostgreSQL library directory on the compiler search path. It causes an iconv ABI mismatch with Crystal's macOS bindings.
- The installer is the only component that knows where it installed. Recording that per checkout replaces an environment variable every shell had to carry.
- Rejected: falling back to a Crystal on `PATH`. The compiler scripts could silently use whatever version is there.
- The ownership checks keep another local user from redirecting the compiler this user runs.
- Keeping the launcher scripts out of the digest avoids a new toolchain, with its download and cold caches, for every launcher edit.
- `~/.local/bin` is the per-user executable directory that is usually already on `PATH`, so no shell profile is edited.
- Rejected: symlinks as launchers. A marked script proves Caramel created the file, and lets each binary find its checkout through its own executable path.
- A project that serves right after it is created is the expected first run.
- Assertions run against real morphed HTML in a real browser, through Latte's actual routes, TLS and sockets and the generated application's real assets and CSRF. Nothing is mocked.
- Rejected: a Node, npm or Python layer. A pinned browser and its own WebDriver endpoint, both verified by hash, need none.
- Rejected: Safari as the browser. It has no headless mode, opens a visible window and drops WebDriver clicks while the screen is locked. WebKit is not covered.
- Rejected: a `.caramel` site for the check. Its names resolve only through a system resolver entry that needs administrator rights; `.localhost` gives named HTTPS through the real proxy without one.
- A check never modifies state it does not own. Trust stores belong to the machine owner.
