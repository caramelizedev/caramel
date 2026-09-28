# Laravel Herd comparison

## Comparison table

| Herd capability | Caramel equivalent | Status |
|---|---|---|
| `park`, `link` | Explicit `frappe new` / `frappe setup` registration as `<name>.caramel` | Different by design; parking deferred |
| `unlink` | `frappe sites remove NAME` | Implemented; keeps project, databases, credentials, logs, backups |
| `secure` | Caddy internal `caramel` CA; `latte trust install` | Implemented; browser-trust acceptance pending |
| `isolate` with `herd php` proxies | the caramel pin in `shard.lock` + `frappe installations` dispatch | Implemented; one toolchain per installation; Latte shared |
| `herd.yml` / `herd init` | `config/environment.yml` + `frappe setup` | Partial |
| Services | One PostgreSQL 18 cluster with per-site dev/spec databases, CoreDNS, Caddy | Partial (PostgreSQL only) |
| Database tooling | `frappe db dump` / `frappe db restore FILE` | Implemented (development database, private backups, pre-restore safety dump) |
| Log viewer, `herd log` | `frappe logs [app\|compiler] [--follow]`; menu per-site “Open logs” | Implemented |
| Dumps | Development exception page only | Absent |
| Mail | none | Deferred: needs an SMTP capture service |
| `share` (Expose) | none | Deferred: needs a tunnel service and public exposure policy |
| MCP server | none | Deferred |
| Menu bar app | Latte.app | Implemented |

## Design differences

- Explicit site registration, not directory discovery.
- Per-app Unix sockets, not per-app TCP ports.
- Terminal-owned `frappe dev` processes.
- Latte is shared across Caramel installations through `CARAMEL_HOME`, API version 1.

## Sources

- https://herd.laravel.com/docs/macos/advanced-usage/herd-cli
- https://herd.laravel.com/docs/macos/sites/managing-sites.md
- https://herd.laravel.com/docs/macos/herd-pro-services/mail.md
- https://herd.laravel.com/docs/macos/debugging/dumps.md
- https://herd.laravel.com/docs/macos/debugging/logs.md
