# Toolchain experiment evidence

Captured 2026-09-19 on the existing Apple Silicon development Mac. `<EVAL>` and `<OFFLINE_EVAL>` replace the two temporary directory roots; `<LOCAL_USER>` replaces the local database owner name. Terminal blank lines are normalized. The two loaded-library logs omit Apple system-library paths and delayed-load bookkeeping; their headers record omission counts and a hash of the full normalized log. Other output is preserved. These are observations from one run, not benchmark guarantees.

- `install-*.txt`: selected versions, first installation and already-installed timings.
- `pg-lifecycle.txt`: private-socket database startup, row persistence across restart, and final shutdown.
- `offline-*.txt`: execution/reinstallation under macOS `sandbox-exec` with `(deny network*)`.
- `interrupted-install.txt`, `partial-exec.txt`, `retry-install.txt`, `coexistence.txt`: interrupted download, refusal to execute an incomplete compiler with auto-install disabled, successful retry, and both compiler versions.
- `linkage.txt`, `loaded-*.txt`: static dependency listings and actual sampled native process library loads. They do not cover all extensions or optional runtime paths.
- `mise-verification.json`: raw mise binary size and SHA-256, checked against GitHub release asset metadata and `SHASUMS256.txt`. Publisher signature verification was not performed.

The final recorded version checks are in `tool-versions.txt`; the hardened compile and configuration discovery checks are in `compile-smoke.txt` and `config-isolation.txt`. `readme-reproduction.txt` captures the complete checked-in instructions replayed with fresh downloads in a second temporary directory (`<REPRO>`). `final-host-check.json` records the post-run configuration comparison and removal of the stopped disposable clusters.

`final-pg-verification.txt` records the reviewed database helper rerun with explicit no-TCP assertions after both starts.
