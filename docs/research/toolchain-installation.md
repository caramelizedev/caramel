# Caramel managed toolchain installation

This is the installation result for the exact pins tested on Apple Silicon macOS on 2026-09-19. It is a feasibility record for that run, not a claim about releases after the dates shown. The selected artifact URLs, SHA-256 values, licenses, and mise backend comparison are kept in [toolchain-artifacts.md](toolchain-artifacts.md); no publisher signature was independently verified.

## Reproduce the isolated run

Follow the [experiment README](../../experiments/toolchain/README.md) to copy the harness into a short, fresh temporary path outside Git, bootstrap and verify mise, trust the reviewed copied configuration, install the locked tools, and create the two local command aliases. Do not run the experiment in the repository. All generated state belongs to that disposable copy.

The wrapper's default environment is already no-auto-install. It scopes mise, XDG, conda, and Crystal state below `<EVAL>`, accepts only the copied `project/caramel-eval.toml`, uses `project/mise.lock` for `macos-arm64`, and sets `MISE_CEILING_PATHS`, `MISE_ENV=''`, `MISE_NO_ENV=1`, `MISE_NO_HOOKS=1`, and `MISE_NETRC=0`. The source and lockfile are under `experiments/toolchain/project`; the smoke source is `project/smoke.cr`.

The complete README sequence was also replayed from a second fresh temporary directory, with fresh downloads and no reused tool cache. It passed checksum verification, locked installation, native smoke compilation, and database restart persistence. After review added explicit no-TCP assertions at both starts, the final database helper was [rerun successfully](evidence/toolchain-2026-09-19/final-pg-verification.txt) against the installed tools. The tested helper scripts match the checked-in copies byte-for-byte; all five regression checks pass. See [README replay evidence](evidence/toolchain-2026-09-19/readme-reproduction.txt). This is a fresh-directory test on the same host, not a clean-machine test.

## Installation result

`mise install --locked` completed for:

```text
github:crystal-lang/crystal@1.21.0
aqua:caddyserver/caddy@2.11.4
conda:postgresql@18.6 (conda-forge)
conda:openssl@3.6.4 (conda-forge)
conda:pkgconf@3.0.7 (conda-forge)
```

The first Crystal+Caddy install took 9.866 s, PostgreSQL 7.7 s, OpenSSL 459 ms, and pkgconf 482 ms in the recorded run. The locked file contains the exact archive URLs and dependency checksums. The [recorded version checks](evidence/toolchain-2026-09-19/tool-versions.txt) passed for Crystal 1.21.0 (LLVM 15.0.7, target `aarch64-apple-macosx11.0`), Shards 0.20.0, Caddy 2.11.4, PostgreSQL server/client/initdb/pg_ctl 18.6, OpenSSL 3.6.4, and pkgconf 3.0.7. The mise binary was pinned at v2026.9.11 and its raw SHA-256 is recorded in [mise-verification.json](evidence/toolchain-2026-09-19/mise-verification.json).

The Crystal archive contains `embedded/bin/shards`, but mise's Crystal wrapper does not add that directory to `PATH`; the harness therefore exposes a Caramel-owned `shards` alias. The conda package is named `pkgconf`, so the native compile also needs a `pkg-config` alias.

## Crystal compile and native linking

After changing into the prepared experiment copy, the successful cold-cache smoke command is reproduced as:

```sh
CARAMEL_EVAL="$PWD"
python3 "$CARAMEL_EVAL/run-mise.py" exec -- env \
  PKG_CONFIG_LIBDIR="$CARAMEL_EVAL/data/installs/conda-openssl/3.6.4/lib/pkgconfig" \
  CRYSTAL_CACHE_DIR="$CARAMEL_EVAL/crystal-cold-2" \
  crystal build smoke.cr -o "$CARAMEL_EVAL/project/smoke" \
  "--link-flags=-Wl,-rpath,$CARAMEL_EVAL/data/installs/conda-openssl/3.6.4/lib"
"$CARAMEL_EVAL/project/smoke"
```

The command exited 0 and produced `{"message":"Caramel","regex":"0"}`. It used only the dedicated OpenSSL 3.6.4 prefix for TLS; the resulting arm64 Mach-O directly loaded that prefix's `libssl.3.dylib` and `libcrypto.3.dylib`, plus Apple system libraries. Exposing the complete PostgreSQL `lib` directory caused an `_iconv` unresolved-symbol collision because that closure includes conda `libiconv`; keep PostgreSQL's library path private.

The original tiny cold-cache sample took 3.486 s; the hardened rerun took 1.626 s after OS-cache effects. These are smoke-build timings, not a framework benchmark. The sampled Crystal, smoke, Caddy, and PostgreSQL linkage/load reports contain no `/opt/homebrew` or Herd library path.

## PostgreSQL lifecycle

`pg-lifecycle.py` initialized a disposable PostgreSQL 18.6 cluster, started it with `listen_addresses=''`, and connected through a mode-0700 private Unix socket. It inserted `Bookshelf`, stopped, restarted, and read the same row. The process was stopped afterward; the disposable cluster was removed after confirming `PG_VERSION` 18 and no `postmaster.pid`. No TCP listener was configured. The lifecycle proof is [`pg-lifecycle.txt`](evidence/toolchain-2026-09-19/pg-lifecycle.txt).

## Offline, warm-cache, and recovery results

Under an actual deny-network sandbox, version-only execution of Crystal, Shards, Caddy, and PostgreSQL passed ([offline-exec.txt](evidence/toolchain-2026-09-19/offline-exec.txt)). A fresh-prefix locked reinstall reused the shared conda cache and installed PostgreSQL, OpenSSL, and pkgconf in 2.248 s, while Crystal and Caddy attempted network access and failed because their GitHub archives were not cached ([offline-reinstall.txt](evidence/toolchain-2026-09-19/offline-reinstall.txt)). This run does not establish a uniform archive-cache strategy; it shows that the installer needs an explicit, tested cache or mirror plan for those archives. A warm locked install completed in 0.036 s ([install-locked-warm.txt](evidence/toolchain-2026-09-19/install-locked-warm.txt)).

Crystal 1.20.3 was interrupted while downloading at 17.8/59.1 MB. With the wrapper's `MISE_AUTO_INSTALL=0`, executing the missing version exited 1 instead of running a partial install. A retry completed in 6.157 s, and both 1.20.3 and 1.21.0 then executed successfully ([retry-install.txt](evidence/toolchain-2026-09-19/retry-install.txt), [coexistence.txt](evidence/toolchain-2026-09-19/coexistence.txt)).

## Limits

The host already had Apple compiler/system tooling and Herd; this was not a clean-machine bootstrap. The external host `psql` remained Herd17, shell hashes were unchanged, and the test changed no system certificates, DNS, Homebrew, Herd, or global shell files. One restricted sandbox lifecycle attempt failed at `shmget` with `Operation not permitted`; the normal isolated lifecycle run passed. The evidence covers the tested commands and direct libraries, not every optional Crystal shard or Caddy extension.

See [toolchain-artifacts.md](toolchain-artifacts.md) for the official mise, Crystal, Caddy, conda, and license sources and the exact locked artifact inventory.
