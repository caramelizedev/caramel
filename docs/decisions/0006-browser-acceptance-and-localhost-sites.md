# ADR 0006: Browser acceptance drives headless Chrome over WebDriver against a `.localhost` site; Latte never installs trust implicitly

Date: 2026-09-27

Status: accepted.

## Context

Morph focus and scroll, `<hx-partial>` ingestion, the island lifecycle and Server-Sent Events
through the local proxy can only be confirmed in a browser. The check must reach a live
application through Latte's Caddy proxy without Node or Python tooling, without a visible
window or an unlocked screen, and without changing the machine's resolver, ports or
certificate trust. `.caramel` names resolve only through a
system resolver entry that needs administrator rights, and Latte's local CA is trusted only
after the owner runs `latte trust install`. Caddy's undeclared default `local` CA tries to
install itself into the system, Java and NSS trust stores for a `.localhost` name; the
[incident note](https://github.com/caramelizedev/caramel-notes/blob/main/research/incident-2026-09-27-caddy-local-ca.md)
has the details.

## Decision

1. `scripts/check browser` is written in Crystal. It drives Chrome for Testing's `chrome-headless-shell` through its `chromedriver`, using a minimal W3C WebDriver client (`scripts/checks/support/webdriver.cr`).
   - `tools/browser-darwin-arm64.json` pins both by archive and executable SHA-256. `scripts/install-browser-tools` installs them into the toolchain's `data/installs/chrome-for-testing/`. The check never downloads them; it verifies both executables before it starts them.
   - It creates a disposable Latte fixture, a generated project, and probe actions, views and assets.
   - It asserts morph focus and scroll (with an `innerHTML` control that must fail), multi-target `hx-partial` ingestion from one CSRF-protected POST, island mount/update/unmount and late registration, and SSE delivery through Caddy.
   - It uses real WebDriver key and click events. The browser has no window and runs with `HOME` inside the fixture, so the check runs with the screen locked. chromedriver's own temporary profile is deleted with the session; a custom `--user-data-dir` leaves the headless shell without a page to attach to.
2. Latte accepts `localhost` as a site suffix, alongside `caramel` and `test`. The IETF special-use names standard (6761) reserves `.localhost` for loopback. Chrome resolves its names to loopback itself, without any system configuration, so a `.localhost` site is reachable without administrator rights. CoreDNS still serves a zone for every suffix, because Latte's readiness probe queries each registered name.
3. The check accepts Latte's untrusted local CA through WebDriver's `acceptInsecureCerts` capability. It never adds trust anywhere.
4. Latte's Caddy configuration declares every CA Caddy can provision, `caramel` and the implicit `local`, with `install_trust: false`.
5. Check fixtures run Caddy with HOME inside the fixture. A trust guard fails the run, and deletes every fixture CA key, if Caddy logs a root installation or creates an undeclared authority.
6. Trusted browser HTTPS for `.caramel` names needs the owner's one-time trust and resolver installation.

## Reasons

- Assertions run against real morphed HTML in a real browser, with no mocks of htmx or the DOM.
- No Node, npm or Python layer: a pinned browser and its own WebDriver endpoint, both verified by hash.
- Safari was the first backend. It has no headless mode, opens a visible window, drops WebDriver clicks while the screen is locked and needs Remote Automation enabled, so it was removed; the check no longer covers WebKit.
- The executables are pinned by hash and used only by a check, so like the editor tools they skip the toolchain's dyld library verification.
- A check never modifies state it does not own. Trust stores belong to the machine owner.
- `.localhost` gives named HTTPS through the real Caddy route without touching `/etc/resolver`. `acceptInsecureCerts` limits the unverified trust to one automation session.
- The check exercises Latte's actual Caddy routes, TLS and Unix-socket upstreams, and the generated application's real asset pipeline, CSRF and layout.
