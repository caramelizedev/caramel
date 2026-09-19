# Bounded mise toolchain reproduction

This directory is a small reproduction of the successful Apple Silicon
toolchain experiment. It is research material, not a consumer installer. It
keeps the authored project selection, exact lockfile, Crystal HTTP smoke
source, and two disposable helpers. Downloaded tools, mise state, PostgreSQL
clusters, and generated binaries are deliberately not stored here.

The experiment was observed on Apple Silicon macOS with Python 3 supplied by
the Xcode Command Line Tools and a usable macOS SDK. Those prerequisites are
needed for the Crystal compiler and linker. The reproduction does not claim a
clean machine, a minimum macOS version, or consumer installation readiness.

Run it from a fresh temporary directory outside any Git checkout. The wrappers
derive every path from their own file location, preserve only `HOME`, `USER`,
`LOGNAME`, and `TMPDIR`, and put mise data, cache, state, system data, config,
and Crystal's cache under the copied root. They set these isolation controls:

```text
MISE_CEILING_PATHS=<copy-root>
MISE_ENV=""
MISE_NO_ENV=1
MISE_NO_HOOKS=1
MISE_NETRC=0
MISE_AUTO_INSTALL=0
```

The ceiling stops discovery above the copied root while still allowing
`project/caramel-eval.toml`. The project config contains only `[settings]` and
`[tools]`; it has no tasks, environment templates, or hooks. The wrapper does
not grant broad automatic trust. Trust the copied config explicitly inside the
isolated config directory before installation.

## Exact reproduction

From the repository root, run the following on the supported host. The short
temporary path also keeps PostgreSQL's Unix socket within macOS's path-length
limit.

```sh
SOURCE="$(git rev-parse --show-toplevel)/experiments/toolchain"
REPRO="$(mktemp -d /private/tmp/caramel-probe.XXXXXX)"
(
  set -eu
  cp -R "$SOURCE/." "$REPRO/"
  if git -C "$REPRO" rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "refusing a temporary path that is still inside a Git checkout" >&2
    exit 1
  fi
  cd "$REPRO"

  mkdir -p bin
  MISE_URL="https://github.com/jdx/mise/releases/download/v2026.9.11/mise-v2026.9.11-macos-arm64"
  MISE_SHA="bbfd47ef65c2278c4e9ba09b523beb1019365a3c0b9c9fc60f686dc16f358e0f"
  MISE_TMP="$REPRO/bin/mise.partial"
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    "$MISE_URL" --output "$MISE_TMP"
  printf '%s  %s\n' "$MISE_SHA" "$MISE_TMP" | shasum -a 256 -c -
  mv "$MISE_TMP" "$REPRO/bin/mise"
  chmod 0755 "$REPRO/bin/mise"

  python3 run-mise.py trust "$REPRO/project/caramel-eval.toml"
  python3 run-mise.py install --locked

  CRYSTAL="$REPRO/data/installs/github-crystal-lang-crystal/1.21.0"
  PKGCONF="$REPRO/data/installs/conda-pkgconf/3.0.7"
  test -x "$CRYSTAL/embedded/bin/shards"
  test -x "$PKGCONF/bin/pkgconf"
  ln -s "$CRYSTAL/embedded/bin/shards" "$REPRO/bin/shards"
  ln -s "$PKGCONF/bin/pkgconf" "$REPRO/bin/pkg-config"

  python3 run-mise.py exec -- crystal --version
  python3 run-mise.py exec -- shards --version
  python3 run-mise.py exec -- caddy version
  python3 run-mise.py exec -- postgres --version
  python3 run-mise.py exec -- initdb --version
  python3 run-mise.py exec -- openssl version
  python3 run-mise.py exec -- pkg-config --version

  OPENSSL="$REPRO/data/installs/conda-openssl/3.6.4"
  python3 run-mise.py exec -- env \
    PKG_CONFIG_LIBDIR="$OPENSSL/lib/pkgconfig" \
    CRYSTAL_CACHE_DIR="$REPRO/crystal-cache" \
    crystal build smoke.cr -o "$REPRO/project/smoke" \
    --link-flags=-Wl,-rpath,"$OPENSSL/lib"
  ./project/smoke

  python3 pg-lifecycle.py
)
```

The smoke build intentionally scopes `PKG_CONFIG_LIBDIR` to the dedicated
OpenSSL prefix and embeds only that prefix's `lib` directory as an rpath. Do
not add the whole PostgreSQL library directory to the Crystal link flags; the
experiment found that doing so can select an incompatible iconv ABI. The
`shards` and `pkg-config` links are local aliases for the selected Crystal
archive's `embedded/bin/shards` and conda pkgconf's `bin/pkgconf`.

`pg-lifecycle.py` refuses an existing `cluster` path, initializes its own
cluster, uses a mode-0700 Unix socket with `listen_addresses=''`, records
command and server output below `logs/`, explicitly checks that
`current_setting('listen_addresses') = ''` after each start, inserts a probe
row, stops and starts again, asserts that the row remains, and stops the server
in `finally` even if a query or interrupt fails. The stopped disposable data
remains below the temporary root until that root is removed.

The pinned mise binary is verified by the raw SHA-256 above. The selected
Crystal, Caddy, PostgreSQL, OpenSSL, pkgconf, and transitive conda artifact
SHA-256 values are in `project/mise.lock`. No executable is vendored in this
directory.

## Local checks without downloads

The narrow tests exercise the two safety boundaries without invoking mise or
PostgreSQL:

```sh
python3 -m unittest discover -s tests -v
```

To inspect wrapper help without running anything:

```sh
python3 run-mise.py --help
python3 pg-lifecycle.py --help
```

The normal commands intentionally refuse when run directly from this checkout;
copying to the fresh temporary root above is part of the reproduction.
