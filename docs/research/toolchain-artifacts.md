# Caramel toolchain artifact inventory

Observed on 2026-09-19 on an Apple Silicon host (`arch=arm64`). Evidence is the isolated evaluation root `/private/tmp/caramel-toolchain-eval`, especially `project/caramel-eval.toml`, `project/mise.lock`, the release JSON files, install logs, installed prefixes, and the PostgreSQL lifecycle logs. The sanitized persistent evidence is in [evidence/toolchain-2026-09-19](evidence/toolchain-2026-09-19/README.md). The project lock targets only `macos-arm64`.

## Selected artifacts

| Tool | Selected artifact | Evidence and integrity | Runtime / license notes |
|---|---|---|---|
| mise | `v2026.9.11`, macOS ARM64, 101,799,024 bytes | [verification evidence](evidence/toolchain-2026-09-19/mise-verification.json) and `shasum` agree on `bbfd47ef65c2278c4e9ba09b523beb1019365a3c0b9c9fc60f686dc16f358e0f`; the downloaded binary and installed `bin/mise` are byte-identical | `2026.9.11 macos-arm64 (2026-09-18)`; official [MIT license](https://raw.githubusercontent.com/jdx/mise/main/LICENSE). Publisher signature was not independently verified; redistribution notice completeness remains open. |
| Crystal | `1.21.0`, GitHub `crystal-1.21.0-1-darwin-universal.tar.gz`, 59,332,679 bytes | Release JSON and `mise.lock` pin `sha256:7fc4af56b0cb5c7ea5703f744c6629bb19ff36ba3abbf232d50e40c39a20ee16`; [official release](https://github.com/crystal-lang/crystal/releases/tag/1.21.0) | Prebuilt universal archive; runtime reports `Default target: aarch64-apple-macosx11.0`. The official [Apache-2.0 license with Runtime Library Exception](https://raw.githubusercontent.com/crystal-lang/crystal/master/LICENSE) applies; the bundled `libffi` license is present at `LICENSES/libffi-LICENSE`. The main license is not copied into this installed prefix, so redistribution notice completeness remains open. |
| Shards | `0.20.0`, bundled by the Crystal archive | `embedded/bin/shards` exists and is a Mach-O universal binary; `shards --version` reports `Shards 0.20.0 (2025-12-19)` | mise's exposed Crystal bin path does not expose this embedded executable automatically. The isolated runner required a `shards` alias to `.../github-crystal-lang-crystal/1.21.0/embedded/bin/shards`. No separate Shards license file was recorded. |
| Caddy | `2.11.4`, `caddy_2.11.4_mac_arm64.tar.gz`, 16,448,366 bytes | `mise.lock` pins `sha256:9efb0af2d6cf09cfb5053c0e51721b9b3d4956d346234f39368d943d25a3c9a7`; [official release](https://github.com/caddyserver/caddy/releases/tag/v2.11.4) | Installed binary is Mach-O arm64; `caddy version` reports `v2.11.4 h1:XKxkMTgNSizEvKG6QHue6cAsFOteU2qA61w2tKkCWi0=`. Installed `LICENSE` is Apache-2.0. Release `.sig`/`.pem` assets exist in `caddy-release.json`, but their signatures were not independently verified. |
| PostgreSQL | conda-forge `postgresql-18.6-heca42e1_1.conda`, macOS ARM64 | `mise.lock` pins `sha256:dd469d447042285531e89fc73310f5027eef0540a63e453e02e907efb84b2156` and the exact URL `https://conda.anaconda.org/conda-forge/osx-arm64/postgresql-18.6-heca42e1_1.conda`; [install evidence](evidence/toolchain-2026-09-19/install-postgres.txt) shows 23 packages downloaded | Native `postgres`, `psql`, `initdb`, and `pg_ctl` are present. The official [conda-forge recipe](https://raw.githubusercontent.com/conda-forge/postgresql-feedstock/main/recipe/meta.yaml) labels the output `license: PostgreSQL` and `license_file: COPYRIGHT`; the installed prefix does not expose that file, so redistribution notice completeness remains open. |
| OpenSSL | conda-forge `openssl-3.6.4-h55eecbc_0.conda`, macOS ARM64 | `mise.lock` pins `sha256:f23239eacd75c4c50705e68fae1aa3292da473e6a3a4abe2330f1e6afa680704`; `openssl version` reports `OpenSSL 3.6.4 25 Aug 2026` | Dedicated prefix is usable for Crystal linking. OpenSSL 3.0 and later use the [Apache License v2](https://www.openssl.org/source/license.html); the installed prefix has no license file, so redistribution notice completeness remains open. |
| pkgconf | conda-forge `pkgconf-3.0.7-h74c22ad_0.conda`, macOS ARM64 | `mise.lock` pins `sha256:7ae352abea0e489193aa61e0751dbe275a329dd90a20966d01d7ead9a85194ca`; `pkgconf --version` reports `3.0.7` | `pkg-config` was exposed through an isolated alias to the package's `pkgconf` binary. Installed `share/doc/pkgconf/COPYING` and the official [COPYING](https://raw.githubusercontent.com/pkgconf/pkgconf/master/COPYING) contain ISC-style permissive text; no SPDX label was recorded. |

All conda package URLs and SHA-256 values above, plus the dependency checksums, are in [tools/toolchain/mise.lock](../../tools/toolchain/mise.lock). The lock's hashes provide artifact-byte integrity; no conda publisher signature or independent signature verification is recorded here. License labels above come from official upstream or recipe evidence; missing files in an installed prefix do not make the license unknown, but a complete redistribution notice bundle still needs an explicit audit.

The 22 transitive conda dependency licenses are not itemized here. Treat that notice and license bundle as a follow-up gate before redistribution; the direct artifact licenses and recipe labels above are the verified provenance available from this run.

## PostgreSQL dependency closure

The locked PostgreSQL build is exact build `heca42e1_1`. Its 22 locked conda dependencies are:

```text
openldap-2.6.13-hf7f56bc_0
libpq-18.6-h08b03b9_1
krb5-1.22.2-h34f8a20_2
cyrus-sasl-2.1.28-hb961e35_1
libntlm-1.8-h5505292_0
libxslt-1.1.45-haaf9281_1
libzlib-1.3.2-h8088a28_3
lz4-c-1.10.0-hdca3b7d_2
readline-8.3-h8b90a29_1
icu-78.3-py310h579977c_2
libxml2-2.15.4-h550178d_0
libxml2-16-2.15.4-heb56d2d_0
openssl-3.6.4-h55eecbc_0
tzcode-2026c-h1a92334_0
tzdata-2026c-h151e31d_0
zstd-1.5.7-hf451053_7
libedit-3.1.20250104-pl5321h26f1114_1
libcxx-23.1.1-h55c6f16_0
liblzma-5.8.3-h8088a28_1
libiconv-1.18-he4c29f2_3
ca-certificates-2026.7.22-hbd8a1cb_0
ncurses-6.6-he64c551_1
```

`mise install` completed through the built-in conda backend; no separate conda, mamba, or micromamba executable was installed or required. The installed PostgreSQL prefix contains the server and client programs, while mise exposes requested-package binaries through `.mise-bins` launchers.

## Rejected alternative: `vfox:mise-plugins/vfox-postgres`

The official plugin's `main` source was inspected on 2026-09-19; no commit SHA was captured, so this is an unpinned source inspection. The plugin was not installed or executed, and no runtime result is claimed. Its [pre-install hook](https://github.com/mise-plugins/vfox-postgres/blob/main/hooks/pre_install.lua) constructs a PostgreSQL FTP source-tarball URL from the requested version; it does not return a checksum. The [post-install hook](https://github.com/mise-plugins/vfox-postgres/blob/main/hooks/post_install.lua) runs `./configure`, `make`, `make install`, and a contrib build, so this path is a source build rather than a prebuilt ARM64 artifact. Native ARM64 output and its dependency closure were therefore not verified.

On macOS the plugin documents a C compiler and `make`, with `xcode-select --install` plus Homebrew OpenSSL and readline; zlib and the macOS UUID API are also part of the configuration. The hook passes `--with-openssl --with-zlib`, discovers OpenSSL from environment/pkg-config/Nix/Homebrew paths, and adds include/library paths. The [environment hook](https://github.com/mise-plugins/vfox-postgres/blob/main/hooks/env_keys.lua) sets `PGDATA` to `{install_path}/data`, inside the managed install directory. The [post-install hook](https://github.com/mise-plugins/vfox-postgres/blob/main/hooks/post_install.lua) creates that directory unconditionally, then runs `initdb -D <install>/data -U postgres` unless `POSTGRES_SKIP_INITDB=1` (or `true`) is set. The skip flag suppresses `initdb` but not directory creation, so the default still conflicts with Latte's requirement that data live outside tool installs and be owned by the database lifecycle.

The plugin's official [metadata](https://github.com/mise-plugins/vfox-postgres/blob/main/metadata.lua) labels the plugin MIT and says it compiles from source; it does not provide a locked PostgreSQL source revision or artifact digest. The source URL is official PostgreSQL FTP provenance, but reproducible checksum/signature verification would need to be added around the plugin. For Caramel's bounded, no-source-build default, the explicit `conda:postgresql` artifact remains the selected backend.

## Verification results

- `crystal --version`, `shards --version`, `caddy version`, `postgres --version`, `openssl version`, and `pkgconf --version` all succeeded through the isolated mise runner.
- The Crystal smoke source [tools/toolchain/smoke.cr](../../tools/toolchain/smoke.cr) compiled to an arm64 Mach-O and ran as `{"message":"Caramel","regex":"0"}`. The HTTP compile succeeded with `PKG_CONFIG_LIBDIR` scoped to the dedicated OpenSSL/pkgconf prefixes and a dedicated OpenSSL library rpath; no explicit compiler include path was used. See [linkage evidence](evidence/toolchain-2026-09-19/linkage.txt) and [loaded smoke libraries](evidence/toolchain-2026-09-19/loaded-smoke.txt).
- A `pkg-config` alias to conda `pkgconf` and a `shards` alias to Crystal's embedded binary were required. Do not put the complete PostgreSQL `lib` directory on the Crystal link path: that attempt produced an `iconv` ABI collision. Keep OpenSSL/library paths scoped to the compile that needs them.
- PostgreSQL was initialized in an external data directory, never in the tool install prefix. The test used `initdb --locale=C --encoding=UTF8 -A trust`, started with `pg_ctl`, and connected with `psql` over a private Unix socket (`listen_addresses=''`). A row inserted before shutdown was returned after restart; the log reports PostgreSQL 18.6 on `aarch64-apple-darwin20.0.0`, 64-bit. See [lifecycle evidence](evidence/toolchain-2026-09-19/pg-lifecycle.txt).
- A separate restricted sandbox run failed during `initdb` because `shmget` was denied (`Operation not permitted`); the normal lifecycle run passed. This is an execution-sandbox shared-memory limitation.
- A warm [`mise install --locked` run](evidence/toolchain-2026-09-19/install-locked-warm.txt) was an online no-op for all five locked tools. Under the separate network-denied checks, [offline execution](evidence/toolchain-2026-09-19/offline-exec.txt) succeeded for the already-installed commands; [offline reinstall](evidence/toolchain-2026-09-19/offline-reinstall.txt) reused the cached conda tools but Crystal and Caddy attempted network access and failed. A full offline reinstall was not demonstrated.

## Registry and selection note

Locally, `mise registry postgres` returns:

```text
conda:postgresql vfox:mise-plugins/vfox-postgres asdf:mise-plugins/mise-postgres
```

The current registry output places conda first. Use the explicit `conda:postgresql` name in Caramel configuration anyway, so selection does not depend on registry ordering or a future alias change.
