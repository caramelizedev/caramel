# ADR 0038: Static files: streamed, validated, and `.well-known` reachable

Date: 2026-10-24

Status: accepted.

## Context

`Application#static_response` answered before the router. It returned 404 for any path with a
segment that starts with a dot, so `/.well-known/change-password` could never reach a route and
`public/.well-known/` files, which ACME challenges, `security.txt` and app-link files need, could
not be served. It read each file whole into a String, sent no `ETag`, `Last-Modified` or
`Cache-Control`, and a file deleted between its lookup and its read raised outside every handler,
so the stdlib answered 500 without the security headers.

## Decision

1. **Order.** A request is checked against the host first, then `public/`, then the router.
2. **Refused paths.** A decoded path with a NUL byte, a backslash, or a `.` or `..` segment
   answers 404. A malformed percent escape answers 400. A file whose real path, after symbolic
   links, lies outside `public/` answers 404.
3. **Hidden segments.** A path with a hidden segment is never served from `public/`, except
   when its first segment is exactly `.well-known`. Every other such path goes to the router,
   which answers 404 unless a route matches. A `.well-known` path that no file answers also goes
   to the router, so a route may serve `/.well-known/change-password`.
4. **Methods.** GET and HEAD serve a file. Any other method on an existing file answers 405 with
   `Allow: GET, HEAD`.
5. **Streaming.** A GET streams the file with its `Content-Length`. HEAD answers the headers
   alone. Range requests are not supported and `Accept-Ranges` is not sent.
6. **Validators.** Every file answer carries `ETag`, a strong tag of the file's size and
   modification time, and `Last-Modified`. A request whose `If-None-Match` names the tag (weak
   prefix and `*` allowed), or, with no `If-None-Match`, whose `If-Modified-Since` is not older
   than the file, answers 304 with the validators and `Cache-Control` only. A date that does not
   parse is ignored.
7. **Caching.** `Cache-Control` is `public, max-age=31536000, immutable` for a name that ends in
   a three-part version and an extension, such as `htmx-4.0.0.min.js`, and `no-cache` for every
   other name.
8. **Read failures.** A file that vanishes between the lookup and the open goes to the router.
   Any other read error is reported to Crema with source `static` and answers 500 with
   `Something went wrong.` and `Cache-Control: no-store`, with the security headers.
9. **Tracing.** Static files stay untraced ([ADR 0027](0027-crema-tracing.md)).

## Reasons

- **`.well-known` by name.** Allowing exactly that first segment keeps `.env`, `.git/` and
  `.well-known/.secret` unservable while serving what ACME and app-link files need.
- **Routing hidden paths.** A path that is not a served file is no different from any other
  unknown path, and an application may own such a route.
- **Streaming, not reading.** A large file no longer sits in memory for each request.
- **`no-cache` unless versioned.** Assets are not fingerprinted yet, so `app.css` keeps its name
  while its content changes; `immutable` there would pin a stale file for a year. A name that
  carries a version never changes under that name.
- **No Range.** Assets are small and the proxy in front of `serve` is the place for ranges.
- **Rejected:** a hard 404 for hidden paths with only `.well-known` allowed, which would still
  block an application's own `/.something` route; and `immutable` for every file.
