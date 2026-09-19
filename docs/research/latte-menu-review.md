# Native menu integration review

The Swift client builds, and `scripts/check-latte-ipc` passes against the real Crystal Unix-socket server with kernel peer-UID checks, mode-0600 socket, JSON status/site responses, and a service command. That fixture's service controller has no database/proxy side effects. The separate daemon check also exercises native client status against the real supervisor and its services. Interactive menu acceptance remains pending.

## Resolved compliance findings

- The client checks its monotonic deadline on every read/write iteration, including successful progress. A regression sends bytes every 50 ms; a separate check verifies one deadline across the status/sites pair. Both pass.
- The control socket suppresses `SIGPIPE`, so a daemon closing its connection during a write produces a recoverable client error rather than terminating the menu app.

The daemon explicitly sends `Content-Length` because this small client deliberately does not implement HTTP chunk decoding. Service start/stop returns promptly with asynchronous starting/stopping state; the client's normal aggregate request deadline is two seconds. Seven native client tests pass, including protocol versions, private runtime ownership, exact site origins and failed-service diagnostics.
