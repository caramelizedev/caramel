# Frappé development loop

The native `frappe dev [--no-open]` implementation combines the shared Latte services with a terminal-owned project session. It verifies the pinned framework, locked dependencies, authoritative local database configuration and system-resolved trusted HTTPS before starting. A failed DNS/trust preflight never substitutes an HTTP or high-port browser address. `--no-open` suppresses browser launch, not that preflight.

## Lifecycle

Each site has an owner-private runtime directory and an exclusive development-session lock. The session binds a private Unix socket and registers it through Latte. This socket is a development HTTP gateway: it serves build diagnostics and authenticated refresh, and forwards normal traffic only to a successfully compiled, ready application. Caddy keeps the named HTTPS origin stable.

Source/configuration/template changes are detected by content hashes with a 100 ms polling interval and 200 ms debounce. A changed source cancels an obsolete compile. During compilation or failure the gateway does not forward requests to the old app. The next application must return `200 ok` from `/health` before traffic switches. Stopping the previous app then proceeds in a tracked retirement queue, allowing the next edit to compile without waiting for its termination grace period. Cleanup failures are surfaced, terminal shutdown waits for the queue, and old executable/debug files remain available until retired processes finish. Pending migrations remain explicit: the startup failure names `frappe migrate`, and dev retries booting the compiled app after that command applies the schema.

The build cache records source fingerprint, binary checksum, development compilation mode, framework version and toolchain prefix. On macOS it also publishes and checksums Crystal's companion `.dwarf` file: renaming the executable alone loses source locations. Reuse validates both files before launch; a missing or changed companion forces a rebuild. Source assets are published separately and refresh without a Crystal build. Asset output conflicts preserve public edits and show an actionable diagnostic. Correcting the conflict restores service. The poller currently hashes watched contents each pass; performance on larger projects remains to be measured.

App processes receive the development runtime database URL; migration/spec credentials are withheld. Changing local environment metadata or secrets while dev is active requires a restart. The normal CLI validates these credentials against Latte before entering the session; the disposable fixture invokes the session directly against its own prepared state.

## Ownership and shutdown

Compiler and app commands run through a small native helper in a newly created POSIX session. The terminal owner holds a pipe lease. Normal cancellation or parent death closes that pipe; the helper signals only its own process group and escalates to terminate resistant descendants. It never restores or kills a PID from an old record. Tests cover preserved child output/exit status and a TERM-resistant descendant.

Ctrl-C closes owned commands, conditionally clears the exact registered gateway socket, removes its socket files and releases the session lock. Shared database/DNS/proxy services remain available. Route cleanup compares the expected socket, so it cannot clear a different upstream. A later session removes only owned, private, recognized socket names after a refused connection proves they are stale; live sockets are preserved.

## Diagnostics and refresh

Compiler/startup diagnostics are escaped, bounded and redacted using known local secret values plus database-URL patterns. They are served at the project HTTPS origin with no-store and restrictive browser policies. Repeated identical failures do not repeatedly advance the refresh generation.

Application exceptions have an additional development-only page with an escaped message, application locations first, collapsed internal frames and a request reference. Frame classification accounts for Crystal's relative paths. Known environment secrets, database credentials and credential-like assignments are redacted before truncation; the page does not dump request bodies or environment variables, or read arbitrary source files. These diagnostics require both the `caramel_development` compile flag and `CARAMEL_ENV=development`. Production builds exclude the diagnostic implementation; production/test runtime modes use the generic response even in a development binary. Runtime exceptions do not mark an otherwise healthy app as a compiler failure.

Full HTML responses receive a local external refresh script. Fragments do not. Application cookies and response status are preserved. A random per-session host-only Secure/HttpOnly/SameSite=Strict cookie authenticates refresh polling, together with a required custom request header and exact Origin validation when supplied. Unknown hosts and cross-origin refresh are refused. No development client or endpoint is added to the production application binary; the gateway owns these features.

## Event streams

The gateway reads ordinary responses whole, with a 30-second upstream read timeout, before returning them. A non-HEAD response whose `Content-Type` starts with `text/event-stream` is proxied as a stream instead:

- Each chunk (up to 4 KiB) is written to the browser and flushed as soon as the application sends it. No refresh script is injected.
- Status, application headers and cookies are preserved. `Content-Length` and hop-by-hop headers are dropped, `Cache-Control: no-store` is set, and the development-session cookie is added.
- The upstream socket has no read timeout, so an idle stream stays open until one side closes it.
- The upstream socket is closed when the copy ends: the application finishes the stream, the application process exits, or the browser disconnects. A browser disconnect is not an error. The application's next writes to the closed socket fail, and `Caramel::Application` treats that failure as a disconnect.
- If a streaming response is never consumed, its socket is released 30 seconds after handoff.
- Streams are not tied to the refresh generation. After a rebuild, an open stream stays on the process that accepted it and ends when that process is retired; the browser's `EventSource` reconnects to the new build.
- HEAD requests never stream; they return headers only.

Unit coverage proxies a real Unix-socket upstream and reads the first event before the upstream sends the second. Delivery through Latte's Caddy proxy is unverified: Caddy is expected to pass `text/event-stream` through unbuffered, and `src/latte/proxy.cr` sets no `flush_interval`. If events arrive in batches under `frappe dev`, set `"flush_interval": -1` on the emitted `reverse_proxy` handler.

## Live project state

Latte queries each development gateway over its private socket using a separate owner token from a mode-0600 session manifest. The manifest identifies the session; it is not evidence that a process is alive. Reads have connection, read/write and aggregate deadlines. Only bounded state/owner values reach `frappe sites` and the native menu; compiler output and tokens remain private. Both interfaces distinguish running, building, build error, stopped, unavailable and unknown states, and label terminal-owned sessions. A registered legacy upstream without session metadata is reported as running when its socket accepts a connection; that fallback proves reachability, not application health. Menu interaction itself still needs visual acceptance.

## Evidence

- The combined runtime, Latte and Frappé unit suite passes 107 examples, including real Unix-socket proxying, full versus partial HTML, preserved application cookies, refresh authentication, escaped/redacted diagnostics including truncation boundaries, authenticated live state and asset conflict handling.
- `scripts/check-runtime-diagnostics` compiles separate production and development binaries, checks that the diagnostic marker is absent from the production artifact, and exercises full/partial responses under development, production and test runtime modes. Escaping, credential redaction and application-frame placement pass.
- Seven native menu protocol checks pass, including live-state labels and deadline handling. The generated-project fixture also invokes the actual CLI and native menu diagnostic command against its live Latte service.
- `scripts/check-dev-child` passes real process-group lifecycle checks.
- `scripts/check-dev-retirement` verifies nonblocking retirement, shutdown waiting for a yielding cleanup callback, surfaced cleanup failure, and termination of a TERM-resistant command.
- `scripts/check-frappe-project --dev` runs two generated native apps behind the disposable Caddy/PostgreSQL fixture. It verifies rebuild/error/fix recovery, explicit migration recovery without a source edit, refresh authentication, CSS updates without compilation, duplicate-session refusal, independent project shutdown, cached restart, abrupt owner death, stale-socket recovery and asset-conflict recovery.
- The same fixture verifies application source locations above collapsed internal frames, retained locations after a cached restart, and recompilation with restored locations after deliberately deleting the cached debug companion. It checks runtime-error requests leave the app's live state as running.
- It also interrupts an actual Crystal compilation while a macro deliberately ignores TERM. Replacing the source stops that macro, removes incomplete artifacts and restores the current build without serving stale code; the second project remains usable.
- The refresh JavaScript passes `node --check`. This is syntax evidence, not browser acceptance.

These HTTPS checks use private fixture ports and an explicitly supplied fixture CA. They do not establish normal system DNS, port 443, browser trust or browser rendering. Full `frappe dev` startup through the ordinary installation remains gated on the pending macOS integration and certificate trust work.

## Remaining development acceptance

Real browser refresh, htmx history/focus/422 behavior, native HTML forms and visual review remain open. The [initial warm-cache performance baseline and compiler profile](development-performance.md) include 20 edits per category on small/larger fixtures and separate empty-cache compiler measurements, and expose a missed compiled-edit target. Cold installation and service-startup measurements, full compiler resource accounting and browser timing remain unverified. Functional checks alone do not establish a timing promise. Independent review remains pending while the requested Luna workers are unavailable.
