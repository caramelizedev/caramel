# Latte network verification

Date: 2026-09-19. Supported host: Apple Silicon macOS.

## Verified components

`scripts/install-latte-tools` installs CoreDNS 1.14.7 into the isolated toolchain. The official archive and extracted executable are independently SHA256-pinned in `tools/latte-darwin-arm64.json`. Four offline tests cover repeat installation, a modified existing executable, failed integrity leaving no partial destination, and invalid archive paths/symlink destinations. The real pinned archive installs and reports its expected version. This supplements the existing mise experiment; it is not yet a complete consumer installer.

`scripts/check-latte-network` creates fresh private state, compiles the actual configuration fixture, starts two owned Unix-socket application fixtures, and launches pinned CoreDNS and Caddy. It checks:

- Exact registered IPv4 answers over UDP and TCP; known IPv4-only names return AAAA NODATA, absent project names NXDOMAIN, and unrelated names REFUSED without forwarding.
- Two different project hostnames serve the correct application through certificate-verified HTTPS, using an explicit test CA and curl resolution override.
- Plain HTTP redirects preserve path/query and lead to the matching HTTPS origin.
- The Caddy administration socket is mode 0600. Whole-config reload removes one route without disrupting the other project. A mismatched SNI/Host returns 421, and a removed hostname no longer completes TLS.
- Live DNS removal takes effect, project directories survive unregister, and Caddy restart retains the same CA and working remaining route.

All checks pass. The harness stops its own processes and removes its own state; it does not modify OS resolution or trust. The standalone configuration test also checks private files, exact routes, explicit trust-install disablement, and loopback listeners.

## Platform integration still required

An unprivileged bind probe to `127.0.0.1:80` and `:443` returned permission denied on this host. The supported plan therefore needs a narrow launchd socket-activation helper for the two standard ports, relaying to Caddy's owned high loopback ports while running as the installing user. No PF/firewall changes are planned.

The scoped `/etc/resolver/caramel` file is absent. An existing `/etc/resolver/test` points at the user's existing local resolver and remains untouched. System lookup, per-user CA trust, real browser acceptance, the listener helper, and the final installer/uninstaller transaction are not yet verified.

## Configuration references

- [Caddy network address and Unix socket permission syntax](https://caddyserver.com/docs/conventions#network-addresses).
- [Pinned Caddy CA configuration and trust-install field](https://github.com/caddyserver/caddy/blob/v2.11.4/modules/caddypki/ca.go).
- [Pinned Caddy HTTP server configuration](https://github.com/caddyserver/caddy/blob/v2.11.4/modules/caddyhttp/server.go).
- [CoreDNS artifact and native-plugin probe](latte-dns.md).
