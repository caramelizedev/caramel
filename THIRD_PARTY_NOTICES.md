# Third-party notices

Caramel reuses these components in the current runtime slice:

- **Blueprint 1.1.0** — MIT, copyright Stephann Vasconcelos. Restored through Shards, linked into applications. `src/caramel/view.cr` reopens its attribute renderer to escape attribute values fully and to render without its attribute cache. Full license: `vendor/licenses/blueprint-LICENSE`.
- **crystal-pg 0.30.0** — BSD 3-Clause, copyright Will Leinweber. Restored through Shards, linked into applications. Full license: `vendor/licenses/crystal-pg-LICENSE`.
- **crystal-db 0.14.0** — MIT, copyright Brian J. Cardiff. Restored through Shards, linked into applications. Full license: `vendor/licenses/crystal-db-LICENSE`.
- **htmx 4.0.0** — Zero-Clause BSD. The unmodified asset is vendored in `vendor/htmx/` and copied into the Bookshelf example's public assets. Full license: `vendor/htmx/LICENSE`; source and integrity digest: `vendor/htmx/README.md`.

The managed compiler/database/proxy toolchain includes additional components. Its artifact inventory and remaining redistribution checks are tracked separately in `docs/research/toolchain-artifacts.md`. This source repository does not contain those toolchain binaries.

CoreDNS 1.14.7 is installed separately by the Latte tool provider from the official Darwin-arm64 release. It is licensed under Apache-2.0; its license is retained in `vendor/licenses/coredns-LICENSE`. Archive and executable SHA256 values are pinned in `tools/latte-darwin-arm64.json`.
