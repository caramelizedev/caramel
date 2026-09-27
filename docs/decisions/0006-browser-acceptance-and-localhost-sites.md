# ADR 0006: Browser acceptance drives Safari over WebDriver against a `.localhost` site; Latte never installs trust implicitly

Date: 2026-09-27

Status: accepted.

## Context

RFC-0001 promises several things that only a browser can confirm:

- morphs preserve focus and scroll;
- htmx 4 ingests `<hx-partial>` responses;
- islands run their lifecycle.

RFC-0003 streams Server-Sent Events through the local proxy. No check exercised any of this in a browser.

A browser check must reach a live application through Latte's Caddy proxy. It cannot use Node or Python tooling, and it cannot change the machine's resolver, ports or certificate trust. `.caramel` names resolve only through a system resolver entry that needs administrator rights. Latte's local CA is trusted only after the owner runs `latte trust install`.

While the check was being built, Caddy provisioned its undeclared default `local` CA for a `.localhost` name and tried to install that CA into the system, Java and NSS trust stores. The details are in [the incident note](../research/incident-2026-09-27-caddy-local-ca.md).

## Decision

1. `scripts/check browser` is written in Crystal. It drives Safari through `/usr/bin/safaridriver` using a minimal W3C WebDriver client (`scripts/checks/support/webdriver.cr`).
   - It creates a disposable Latte fixture, a generated project, and probe actions, views and assets.
   - It asserts morph focus and scroll (with an `innerHTML` control that must fail), multi-target `hx-partial` ingestion from one CSRF-protected POST, island mount/update/unmount and late registration, and SSE delivery through Caddy.
   - It uses real WebDriver key and click events. Safari's "Allow Remote Automation" must be enabled once (`safaridriver --enable`).
2. Latte accepts `localhost` as a site suffix, alongside `caramel` and `test`. RFC 6761 reserves `.localhost` for loopback. macOS's resolver and browsers resolve its names without any system configuration, so a `.localhost` site is reachable without administrator rights. CoreDNS still serves a zone for every suffix, because Latte's readiness probe queries each registered name.
3. The check accepts Latte's untrusted local CA through WebDriver's `acceptInsecureCerts` capability. It never adds trust anywhere.
4. Latte's Caddy configuration declares every CA Caddy can provision, `caramel` and the implicit `local`, with `install_trust: false`.
5. Check fixtures run Caddy with HOME inside the fixture. A trust guard fails the run, and deletes every fixture CA key, if Caddy logs a root installation or creates an undeclared authority.

## Reasons

- Manifesto 5: assert against real morphed HTML in a real browser, with no mocks of htmx or the DOM.
- Manifesto 3: no Node, npm or Python layer, only the platform's own WebDriver endpoint.
- Manifesto 4: a check must never modify state it does not own. Trust stores belong to the machine owner.
- `.localhost` gives named HTTPS through the real Caddy route without touching `/etc/resolver`. `acceptInsecureCerts` limits the unverified trust to one automation session.

## Consequences

- The check exercises Latte's actual Caddy routes, TLS and Unix-socket upstreams, and the generated application's real asset pipeline, CSRF and layout.
- It found and fixed four product bugs:
  - `.localhost` DNS readiness;
  - implicit CA trust installation;
  - the starter `app.js` stealing focus after every swap;
  - morphs dropping `data-island-state`.
- Trusted browser HTTPS for `.caramel` names still needs the owner's one-time trust and resolver installation.
