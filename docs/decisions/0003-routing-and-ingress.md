# ADR 0003: Routes are verified against typed contracts at compile time, and each route declares how its request is read

Date: 2026-09-27

Status: accepted.

## Context

The router has to verify every route against its action's contract at compile time and match requests without allocating. Crystal's `TypeNode#instance_vars` is available only to macros expanded inside methods, so a top-level `Router.draw` block cannot read a contract's fields through it.

Reading every request the same way before routing, and checking CSRF on every write, does not fit two kinds of client. JSON clients ([#2](https://github.com/caramelizedev/caramel/issues/2)) need their body bound to contract fields. Signed webhooks ([#3](https://github.com/caramelizedev/caramel/issues/3)) and token-authenticated APIs need the exact bytes, a limit of their own, and an authentication policy in place of the browser CSRF check.

## Decision

1. **Every action declares a typed contract, and each field is recorded as a compile-time constant.** One `Router.draw` block holds every route and verifies each against those constants at compile time.
2. **Contracts are parsed, never hydrated.** Parsing collects every error instead of raising. An action's `handle` runs only with a valid contract.
3. **Any type binds as a contract field through a protocol in core.** The type names the wire type it binds from, and that wire type's grammar reads the request. Core names no type that uses the protocol; [ADR 0033](sweettalk/0033-framework-boundary.md) records one user.
4. **One UUID spelling binds.** A `UUID` field or route parameter accepts the canonical lowercase hyphenated form only. A route parameter in any other form answers 404.
5. **Matching walks a segment trie built once at boot from the compile-time route table, and allocates nothing.**
6. **An action declares how its route reads the request, beside its contract.** The declaration covers the body form, its size limit, the CSRF check and the authenticator. It is checked at compile time, and a subtype inherits its parent's declaration. A redeclaration under an authenticating parent must name an authenticator.
7. **The route is matched before the body is read.** The matched route's declaration decides how the body is read and whether CSRF is checked. A request that matches no route is read and checked under the default policy.
8. **The body is bounded by bytes and by count, and a file is stored only for a route whose contract takes one.** A raw route keeps the exact bytes, and its contract binds from the route and the query only.
9. **A form route binds a JSON object through the same contract.** Each member must have its field's JSON type. `+json` media types are not read as JSON.
10. **Writes are CSRF-checked unless the matched route names another credential.** Turning the check off requires an authenticator, and the compiler refuses a declaration without one. On such a route the session reads empty and is never saved.
11. **The authenticator runs after the body is read and before the contract binds.** It guards every method of its route, reads included. A failure answers 401 with no detail.
12. **A method override reaches only a route that reads its body the same way as the POST that carries it.** Any other target is refused.
13. **Core answers a valid contract through a hook that does nothing in core.** An opt-in require redefines it to answer errors of its own, like the tenancy hooks of [ADR 0025](0025-tenancy.md). Core names no library that does; [ADR 0033](sweettalk/0033-framework-boundary.md) records one.

## Reasons

- Constants are visible to every later macro and carry the nilability and default information the router needs to reject unsafe parameters.
- Rejected: reading `instance_vars` in the router macro. It returns an empty list for top-level code and verifies nothing.
- Parsing returns a contract with every error instead of raising, so a form re-renders all its messages together and a JSON client gets the same error set.
- A data trie built from a compile-time table keeps the generated code small enough to read and keeps matching free of allocation. The table is verified at compile time, so the runtime structure cannot drift from the declarations.
- A protocol in core lets any type bind, not only one library's, and keeps one grammar per wire type, so a JSON client and a form get the same errors.
- Rejected: a branch per library in the contract macro. Core would name the library, and no other type could bind.
- Rejected: any UUID spelling in routes. Uppercase, braced or unhyphenated forms would give one record several URLs, splitting caches and links.
- The policy that guards a route belongs next to the code that verifies its credential, where a compile error can insist that turning CSRF off names a verifier.
- An action inherits its parent's declaration so that an API base declares it once. A redeclaration must keep an authenticator, so changing a limit can never drop authentication.
- The body is read differently per route, so the route has to be known before the body is read. Falling back to the default policy keeps every unmatched request guarded: a route's CSRF setting never applies to a request it did not match.
- JSON members bind through the same grammar as form text, so one contract and one set of messages serve both clients. Checking each member's JSON type keeps `"5"` from passing as a number.
- `+json` media types have conventions for `null` and nesting that this binding would silently change.
- The body is read before the CSRF check and the authenticator, so what an anonymous request can make the server hold is bounded by count as well as by bytes, and a route that takes no file writes none to disk.
- Another site's form carries the browser's cookies, so only a credential a browser does not attach on its own, such as a signature or a bearer token, may stand in for the CSRF check. An empty session on such routes turns the one authenticator that would reopen CSRF, a session cookie, into one that fails closed.
- The authenticator runs before the contract binds, so an unauthenticated caller learns nothing from contract errors.
- A method override is held to the POST's own policy, so an override never skips a check.
- A hook whose core body only yields is inlined by Crystal, so it adds no call to core, and core names no library.
