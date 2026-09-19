# Toolchain installer component

`scripts/install-toolchain` turns the pinned provider experiment into a repeatable installation component. It installs Crystal 1.21.0, Shards 0.20.0, PostgreSQL 18.6, OpenSSL 3.6.4, pkgconf 3.0.7, Caddy 2.11.4 and CoreDNS 1.14.7. Mise 2026.9.11 remains an internal provider with isolated configuration and state.

This is one component of the consumer installer, not the finished Caramel installation. It does not install Frappé or the menu app, start services, create databases, edit DNS, or add certificate trust. The complete installer and clean-machine acceptance are still pending.

## Use

On Apple Silicon macOS with Apple's Command Line Tools, Python 3, clang and a usable macOS SDK:

```sh
scripts/install-toolchain --root '/path/to/a/private/final/toolchain'
```

The destination must be empty or an installation previously claimed by this component. Use its final location: conda native packages and compiled application rpaths may depend on that prefix. Moving an installation is rejected. A different toolchain release belongs in a new versioned prefix.

The compiler entry point is `<root>/bin/crystal`; it needs no shell activation. Internal Frappé/Shards integration can also use the copied launchers with `CARAMEL_TOOLCHAIN_ROOT` set. Global shell files and existing mise/Homebrew installations are not modified.

For a completed installation:

```sh
scripts/install-toolchain --root '/path/to/a/private/final/toolchain' --offline
```

Offline mode verifies and reuses existing files; it cannot install a fresh prefix from cached archives. `--mise-binary PATH` can reuse an already downloaded mise executable, but still checks the pinned SHA-256. Other artifacts use the locked provider downloads.

## State and recovery

The prefix is mode 0700. A nonblocking file lock excludes another installer. A private JSON receipt binds the canonical prefix, authored tool selection, lockfile, compiler launchers and critical executable/library hashes. The installer refuses unrelated nonempty directories, altered authored configuration, malformed/relocated receipts and conflicting aliases. Existing content is preserved on these failures.

The receipt is `installing` until provider installation, native compilation, execution and version/library checks finish. Rerunning the same command resumes that owned prefix. A completed installation is checked before reuse and changed critical files fail verification; there is no silent repair of modified installations. The receipt covers the explicitly listed critical binaries and OpenSSL libraries, not every optional file in every package. Artifact authenticity relies on the pinned hashes/locked provider checks; no independent publisher signature claim is made.

The provider trusts only the package-authored copied configuration, uses explicit exact backends/versions, and disables automatic install-on-exec, hooks and ambient environment/config discovery. Native packages are installed directly at the final prefix. CoreDNS retains its separate archive and executable checksums.

Native verification runs eleven commands, including the compiled HTTP/TLS smoke app, with loader diagnostics. It checks expected versions/output and refuses observed libraries outside the installation or macOS system-library roots. The private evidence file is `<root>/project/native-verification.json`. This establishes the loaded dependencies of those exercised commands, not every optional runtime code path.

## Observed checks

- Twelve installer unit tests cover directory preservation, resumable state, altered configuration, binary corruption, receipt inventory, symlinked state, concurrent installation, offline reuse, relocation, failed-provider retry and native version/library diagnostics. Four CoreDNS provider checks and five earlier isolation/lifecycle harness checks also pass.
- A fresh prefix containing spaces completed the pinned downloads and compiled/executed the smoke app. All eleven native commands passed version and library provenance checks there.
- Eight real managed-PostgreSQL integration checks passed using that fresh installation, including lifecycle and project credential behavior; their private test cluster was stopped and cleaned up.
- Offline reuse of that prefix passed.
- In a second fresh prefix, the harness terminated only the installer's own process group after mise began installation. The receipt remained `installing`. Rerunning the installer completed the pinned tools, compiled the smoke app, passed all eleven native probes, recorded completion and then passed offline reuse. No system service was started by this check.

The host already has Apple's SDK and other development tooling. These are fresh-prefix tests, not proof of clean-machine setup or a declared minimum macOS version. Independent review remains pending because the Luna workers reached their account usage limit.
