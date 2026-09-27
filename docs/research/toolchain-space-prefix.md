# Fresh tool installation under a path containing spaces

Date: 2026-09-19. Host: the existing Apple Silicon macOS development machine with Command Line Tools installed. This is a fresh tool prefix, **not** a clean-machine result.

The existing pinned mise binary was checked against SHA-256 `bbfd47ef65c2278c4e9ba09b523beb1019365a3c0b9c9fc60f686dc16f358e0f`. The reviewed experiment configuration and lockfile were copied to `/private/tmp/Caramel Fresh Toolchain a1m4g3mv`; only the pinned mise binary was reused. Its tools, caches and state were newly installed through `install --locked`. Five tools installed in 20.345 seconds in this single observed run.

PostgreSQL 18.6 initialized in that prefix, used a private socket with no TCP listener, retained an inserted row across stop/start, and stopped successfully afterward. No system resolver, service, shell configuration or certificate trust was changed.

After correcting the compiler integration below, the full eight-example Latte managed PostgreSQL suite also passed using this newly installed toolchain and a separate fresh private cluster, including restricted runtime roles, development/spec isolation, configuration reconciliation and backup/restore.

The first Crystal HTTP-importing build failed: Crystal 1.21 embeds OpenSSL `pkg-config` output in unquoted shell substitutions. A package prefix containing spaces was split into multiple linker arguments. Quoting Caramel's rpath argument fixed only the rpath, not this upstream integration.

The compiler adapter now generates private OpenSSL package metadata with a short compilation-only prefix under `/private/tmp/caramel-compiler-<uid>-<hash>/`. The prefix links to the selected managed OpenSSL installation. Metadata files are private and atomically replaced; conflicting/foreign files are refused. The built executable retains the **real** managed OpenSSL path as its rpath, so it does not need the temporary compilation alias to run. Caramel does not modify the installed OpenSSL packages or Crystal source.

The fresh-prefix build then compiled and executed successfully. `otool -L` showed managed OpenSSL through `@rpath/libssl.3.dylib` and `@rpath/libcrypto.3.dylib`, plus macOS system zlib, iconv and libSystem. This is a native dynamically linked macOS development build, not the separate Linux static release artifact.

`scripts/check toolchain-paths` also verifies an executable build and recorded rpath when the adapter-visible prefix includes spaces, a quote and a dollar sign. That regression reuses installed tools through links; it does not claim to relocate conda packages or to repeat fresh installation. The fresh install above establishes the separately observed package-prefix behavior.
