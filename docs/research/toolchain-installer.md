# Toolchain installer component

`scripts/install-toolchain` installs the pinned selection in `tools/toolchain` as a repeatable installation component. It installs Crystal 1.21.0, Shards 0.20.0, PostgreSQL 18.6, OpenSSL 3.6.4, pkgconf 3.0.7, Caddy 2.11.4 and CoreDNS 1.14.7. Mise 2026.9.11 remains an internal provider with isolated configuration and state.

This is one component of the consumer installer, not the finished Caramel installation. It does not install Frappé or the menu app, start services, create databases, edit DNS, or add certificate trust. The complete installer and clean-machine acceptance are still pending.

## Use

On Apple Silicon macOS with Apple's Command Line Tools (clang, Swift and a usable macOS SDK):

```sh
scripts/install-toolchain
```

Without `--root`, the installer reuses the toolchain the checkout's `.caramel-toolchain` names when that installation's receipt is for this release, so a rerun verifies or resumes it. Otherwise it uses `~/Library/Application Support/Caramel/toolchains/<release>` (under `CARAMEL_HOME` when that is set), where `<release>` is a short digest of the pinned selection. The selection includes the copied `scripts/crystal` and `scripts/shards` launchers, so changing them is a new release. `--root DIR` picks another private final location. The destination must be empty or an installation previously claimed by this component. Use its final location: conda native packages and compiled application rpaths may depend on that prefix. Moving an installation is rejected. A different toolchain release gets a new prefix; the default name does this on its own, and an old prefix can be deleted once nothing points at it.

When the toolchain is installed or verified, the installer writes its path to the checkout's `.caramel-toolchain` (git-ignored, mode 0644). This is the only writer of that file. `frappe`, `latte`, `scripts/crystal`, `scripts/shards`, `scripts/install-latte-tools` and every `scripts/check` target read it. `CARAMEL_TOOLCHAIN_ROOT` overrides it; checks use the override for test toolchains. The pointer must be a regular file the user owns that no one else can write, and it must name an absolute path. The compiler entry point is `<root>/bin/crystal`; it needs no shell activation. Global shell files and existing mise/Homebrew installations are not modified.

For a completed installation:

```sh
scripts/install-toolchain --offline
```

Offline mode verifies and reuses existing files; it cannot install a fresh prefix from cached archives. `--mise-binary PATH` can reuse an already downloaded mise executable, but still checks the pinned SHA-256. Other artifacts use the locked provider downloads.

## State and recovery

The prefix is mode 0700. A nonblocking file lock excludes another installer. A private JSON receipt binds the canonical prefix, authored tool selection, lockfile, compiler launchers and critical executable/library hashes. The installer refuses unrelated nonempty directories, altered authored configuration, malformed/relocated receipts and conflicting aliases. Existing content is preserved on these failures.

The receipt is `installing` until provider installation, native compilation, execution and version/library checks finish. Rerunning the same command resumes that owned prefix. A completed installation is checked before reuse and changed critical files fail verification; there is no silent repair of modified installations. The receipt covers the explicitly listed critical binaries and OpenSSL libraries, not every optional file in every package. Artifact authenticity relies on the pinned hashes/locked provider checks; no independent publisher signature claim is made.

The provider trusts only the package-authored copied configuration, uses explicit exact backends/versions, and disables automatic install-on-exec, hooks and ambient environment/config discovery. Native packages are installed directly at the final prefix. CoreDNS retains its separate archive and executable checksums.

Native verification runs eleven commands, including the compiled HTTP/TLS smoke app, with loader diagnostics. It checks expected versions/output and refuses observed libraries outside the installation or macOS system-library roots. The private evidence file is `<root>/project/native-verification.json`. This establishes the loaded dependencies of those exercised commands, not every optional runtime code path.

## Observed checks

- `scripts/check native` passes 39 black-box examples: seven menu-client cases, four relay cases, 13 toolchain-installer cases, four CoreDNS-installer cases and 11 local-integration cases. They cover directory preservation, resumable state, altered configuration, binary corruption, receipt inventory, symlinked state, concurrent installation, offline reuse, relocation, failed-provider retry and native version/library diagnostics.
- A fresh prefix containing spaces completed the pinned downloads and compiled/executed the smoke app. All eleven native commands passed version and library provenance checks there.
- Eight real managed-PostgreSQL integration checks passed using that fresh installation, including lifecycle and project credential behavior; their private test cluster was stopped and cleaned up.
- Offline reuse of that prefix passed.
- In a second fresh prefix, the harness terminated only the installer's own process group after mise began installation. The receipt remained `installing`. Rerunning the installer completed the pinned tools, compiled the smoke app, passed all eleven native probes, recorded completion and then passed offline reuse. No system service was started by this check.

The host already has Apple's SDK and other development tooling. These are fresh-prefix tests, not proof of clean-machine setup or a declared minimum macOS version. Independent review remains pending because the Luna workers reached their account usage limit.
