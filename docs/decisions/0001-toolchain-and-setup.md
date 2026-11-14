# ADR 0001: A pinned mise toolchain supplies every tool, recorded once per checkout and never found on PATH

Date: 2026-09-19

Status: accepted.

## Context

Caramel needs Crystal, Shards, Caddy, PostgreSQL, OpenSSL, GMP and pkgconf at known versions on a developer's machine, without Homebrew, a global version manager or a compiled PostgreSQL. Each tool must install from prebuilt artifacts and run without touching the host's own tools.

The first-run path, `frappe new demo && cd demo && frappe dev`, must work without manual steps:

- Every command would need `CARAMEL_TOOLCHAIN_ROOT` exported, and `scripts/crystal` and `scripts/shards` could silently use whatever Crystal is on `PATH`.
- `frappe` and `latte` would need full paths in the checkout.
- A new project would refuse to serve until `frappe migrate` ran.

Morph focus and scroll, `<hx-partial>` ingestion, the island lifecycle and Server-Sent Events through the local proxy can only be confirmed in a browser. The check must reach a live application through Latte's Caddy proxy without Node or Python tooling, without a visible window or an unlocked screen, and without changing the machine's resolver, ports or certificate trust.

## Decision

The rules a developer relies on are stated on the website ([site.html](../../website/source/site.html)), chiefly its Local environment and Commands references, in the sections cited below by anchor, and in the doc comments under [src/latte](../../src/latte) and [src/frappe](../../src/frappe). This record states what was chosen. Latte, which runs the tools as services, is [ADR 0012](0012-latte.md).

1. **Pinned mise supplies the tools behind an isolated adapter.** mise 2026.9.11 runs behind an isolated toolchain adapter. Its backends are explicit: GitHub for Crystal, aqua for Caddy, and conda-forge for prebuilt PostgreSQL, OpenSSL, GMP and pkgconf. Caramel does not write a general version manager and does not compile PostgreSQL during ordinary setup. mise serves contributors; its adoption for consumers is provisional. The application-facing Caramel environment manifest stays authoritative: if the consumer adapter uses mise, it generates internal configuration from that manifest, and users do not maintain duplicate version declarations.
2. **The selection is one authored file and one lock.** `tools/toolchain/caramel-toolchain.toml` is the authored tool selection, and `tools/toolchain/mise.lock` records the resolved artifacts: the concrete artifact URLs and SHA-256 checksums, including PostgreSQL's transitive dependency packages. The tested set is Crystal with its bundled Shards 0.20.0, Caddy, PostgreSQL, OpenSSL 3.6.5, GMP 6.3.0 and pkgconf 3.0.7; the Crystal, Caddy and PostgreSQL versions are stated once on the website, on the page `site#c-releases-tools` names (Crystal also in `site#c-releases-dependencies`). Updating a tool version or backend is a reviewed dependency change. `scripts/install-toolchain` installs exactly that selection into a private prefix, verifies the native tools and records a receipt; `scripts/crystal` and `scripts/shards` run from that prefix.
3. **mise owns tool installation and nothing else.** Frappé is the application developer's interface. Shards owns Crystal application dependencies. Latte owns database data, roles, lifecycle, project registration, DNS, and certificate and proxy configuration. None of these is delegated to mise bootstrap or mise daemons.
4. **Installing a tool never creates or removes a database.** The conda package creates no cluster. Latte initializes and supervises its own data directory outside tool installations. Upgrading or removing a tool never removes databases.
5. **What the Crystal archive lacks is supplied explicitly.**
   - **Shards.** The Crystal archive has `embedded/bin/shards`, while mise's default GitHub integration exposes `bin`. The bundled binary is invoked through the selected compiler version; a global Shards installation never takes over silently.
   - **OpenSSL.** The archive does not include OpenSSL. A dedicated managed OpenSSL prefix and pkgconf with a `pkg-config` entry point supply it: OpenSSL is exposed via `PKG_CONFIG_LIBDIR`, and its library directory is embedded as a development runtime search path.
   - **GMP.** The archive does not include GMP, which `BigDecimal`, `BigInt` and `BigRational` link. `scripts/crystal` links it through a single link to `libgmp.dylib` in its private compiler directory, not through GMP's conda library directory, and embeds that directory as a development runtime search path.
   - **Narrow search paths.** A database prefix is not a general compiler dependency directory: the PostgreSQL library directory is never added to the compiler search path.
6. **Installed tools work offline; offline reinstallation is not promised.** Installed-tool reuse works offline. Ordinary mise download retention gives no uniform offline reinstallation guarantee. A consumer adapter retains verified distributable artifacts or explicitly defines the supported installed-tool cache, and tests recovery from missing or corrupt files.
7. **mise runs on Caramel-owned configuration and a filtered environment.** The adapter uses Caramel-owned configuration, data, cache and state; explicit system and global overrides; a bounded discovery root; a filtered environment; reviewed backends; and content-bound config trust. It validates the discovered configuration set before executing installation hooks or tasks. The experiment wrapper is research tooling, not a security boundary for arbitrary untrusted projects.
8. **One lookup finds the toolchain, and nothing falls back to `PATH`.** `Caramel::Latte::Toolchain.locate`, `scripts/crystal`, `scripts/shards` and the Swift installers find the toolchain the same way: `CARAMEL_TOOLCHAIN_ROOT` when set, otherwise the first line of the checkout's `.caramel-toolchain`, otherwise an error naming `scripts/install-toolchain` (`Toolchain.locate`). The pointer must be a regular file the user owns that no one else can write, and it must name an absolute path. The root must be a private directory the user owns, not a symlink; its mode is in `site#c-local-limits`. There is no fallback to a Crystal found on `PATH` (`Toolchain`). The variable stays as the override that checks use for test toolchains.
9. **The installer records the toolchain, and is the only writer of the pointer.**
   - Without `--root`, `scripts/install-toolchain` reuses the toolchain `.caramel-toolchain` already names when its receipt is for this release, so a rerun verifies or resumes it. Otherwise it installs into `~/Library/Application Support/Caramel/toolchains/<release>`. `<release>` is 12 hex digits of the pinned selection's digest, so a changed release installs beside the old one.
   - The selection leaves out the launchers, the toolchain's copies of `scripts/crystal` and `scripts/shards` (`launchers/`). A release that changes only them reuses the toolchain: after verifying it, the installer writes the release's launchers over the old ones and records the selection without them. Frappé builds with each release's own `scripts/crystal`; the toolchain's copies serve only its `bin/crystal`.
   - After a fresh install or a verified reuse, it writes `.caramel-toolchain`. `frappe lsp install` does not write the pointer.
10. **`frappe` and `latte` are launchers in `~/.local/bin`.** `frappe installations register` writes `~/.local/bin/frappe` and `~/.local/bin/latte`. Each is a marked script that `exec`s the binary of the newest installed release, which may be this checkout's, as the one-Latte rule of [ADR 0016](0016-versioning-and-releases.md) says. It refuses, before writing either file, when a name is taken by a file Caramel did not create, or when the directory is writable by others (`Launchers`). `frappe installations remove` deletes the launchers that ran the removed checkout when no release remains; otherwise they run the newest remaining release (`Launchers#follow`, `site#c-local-releases`).
11. **A new project starts migrated.** `frappe new` and `frappe setup` apply pending migrations after they configure the site. `frappe setup --no-migrate` configures the site and applies no migration; it prints that migrations were skipped and names `frappe migrate` as the next command (`site#c-local-sites`). When `frappe dev` finds pending migrations, it says so once, retries quietly every second, and serves as soon as they are applied (`site#c-local-dev`).
12. **Browser acceptance drives headless Chrome over WebDriver against a `.localhost` site.** `scripts/check browser` is written in Crystal. It drives Chrome for Testing's `chrome-headless-shell` through its `chromedriver`, using a minimal W3C WebDriver client (`scripts/checks/support/webdriver.cr`).
    - **Pinned tools.** `tools/browser-darwin-arm64.json` pins both by archive and executable SHA-256. `scripts/install-browser-tools` installs them into the toolchain's `data/installs/chrome-for-testing/`. The check never downloads them; it verifies both executables before it starts them.
    - **Fixture.** It creates a disposable Latte fixture, a generated project, and probe actions, views and assets. The site takes the `localhost` suffix that [ADR 0012](0012-latte.md) admits, so the browser reaches it without administrator rights.
    - **Assertions.** It asserts morph focus and scroll (with an `innerHTML` control that must fail), multi-target `hx-partial` ingestion from one CSRF-protected POST, island mount/update/unmount and late registration, and SSE delivery through Caddy.
    - **Events and profile.** It uses real WebDriver key and click events. The browser has no window and runs with `HOME` inside the fixture, so the check runs with the screen locked. chromedriver's own temporary profile is deleted with the session; the check sets no `--user-data-dir`.
    - **Trust.** The check accepts Latte's untrusted local CA through WebDriver's `acceptInsecureCerts` capability. It never adds trust anywhere.
    - **Trust guard.** Check fixtures run Caddy with `HOME` inside the fixture. A trust guard fails the run, and deletes every fixture CA key, if Caddy logs a root installation or creates an undeclared authority.

## Reasons

- Prebuilt upstream archives install in seconds and run with no network once installed; the experiment's inventory is at https://github.com/caramelizedev/caramel-notes/blob/main/research/toolchain-artifacts.md.
- Pinned versions with recorded checksums make every toolchain change a reviewed diff.
- Crystal 1.21.1 fixes non-blocking `Socket#connect` on macOS 26.7 and later, `HTTP::Server` request smuggling, and automatic decompression of request bodies.
- Crystal 1.22.1 fixes `OpenSSL::SSL::Options::ALL`, io_uring event loop hangs and the `Content-Length` regressions of 1.22.0, and keeps the io_uring event loop that Linux release builds can select.
- Separate prefixes let several Crystal versions coexist and leave the host's shell, Homebrew and Herd untouched.
- Bundling GMP lets an application use the standard library's exact arithmetic in every managed build, without Homebrew or a link annotation of its own.
- Adding the entire PostgreSQL library directory to the compiler search path causes an iconv ABI mismatch with Crystal's macOS bindings.
- The installer is the only component that knows where it installed. Recording that per checkout replaces an environment variable every shell had to carry. The ownership checks keep another local user from redirecting the compiler this user runs.
- Launcher reuse avoids a new toolchain for every launcher edit (a 39 s download, about 491 MB, cold compiler caches and a 20-minute crystalline rebuild).
- `~/.local/bin` is the per-user executable directory that is usually already on `PATH`, so no shell profile is edited. Marked scripts make "Caramel created this file" provable. Unlike symlinks, they let each binary find its checkout through its own executable path.
- A project that serves right after `frappe new` is the expected first run.
- Assertions run against real morphed HTML in a real browser, with no mocks of htmx or the DOM.
- No Node, npm or Python layer: a pinned browser and its own WebDriver endpoint, both verified by hash.
- Rejected: Safari as the browser. It has no headless mode, opens a visible window, drops WebDriver clicks while the screen is locked and needs Remote Automation enabled. The check does not cover WebKit.
- Rejected: a custom `--user-data-dir`, which leaves the headless shell without a page to attach to.
- The executables are pinned by hash and used only by a check, so like the editor tools they skip the toolchain's dyld library verification.
- A check never modifies state it does not own. Trust stores belong to the machine owner.
- `.caramel` names resolve only through a system resolver entry that needs administrator rights. `.localhost` gives named HTTPS through the real Caddy route without touching `/etc/resolver`. `acceptInsecureCerts` limits the unverified trust to one automation session.
- The check exercises Latte's actual Caddy routes, TLS and Unix-socket upstreams, and the generated application's real asset pipeline, CSRF and layout.
