# ADR 0003: Routes read contract field constants; matching walks a boot-time segment trie

Date: 2026-09-27

Status: accepted. Decisions 3 and 4 are amended by [ADR 0020](0020-action-ingress-and-json-bodies.md).

## Context

Crystal's `TypeNode#instance_vars` is available only to macros expanded inside methods, so a
top-level `Router.draw` block cannot read a contract's fields through it. The router still has
to verify every route against its action's contract at compile time, and match requests
without allocating.

## Decision

1. **Contract declarations are compile-time constants.** An Action declares `contract do … end` with lines of the form `field name : Type, min:, max:, default:`. `field name : Array(T), max:, min:` declares a bounded array of one of the scalar types; it cannot bind a route parameter. Each `field` records a `CARAMEL_FIELD_<NAME>` constant holding the name, scalar type, nilability, whether a default exists, and a summary. `Router.draw` reads those constants to verify every route. A route fails to compile when:
   - its action is undefined, does not inherit from `Caramel::Action`, or has no contract;
   - it binds a `:param` to a missing field, or to a field that is nilable, defaulted, or not `String`, `Int32` or `Int64`.

   Each error names the route's source location and gives a one-line remedy.
2. **Contracts are parsed, never hydrated.** `Contract.parse(input)` binds each field by name from, in order, the route parameters, the form body and the query. It collects every error. A name sent twice is an error, except for an `Array` field, which takes each occurrence in order. The router calls `handle` only with a valid contract.
3. **Dispatch.** `draw` generates an `AppRouter` that holds the verified route table, with one generated method per route and a `case` that selects among them. At boot a segment trie is built once from that table:
   - Static children win over the parameter child, and matching backtracks.
   - Matching walks byte offsets in a stack-allocated `Segments` value. It uses no regular expressions and **allocates nothing**.
   - Binding allocates only the decoded parameter strings, the input maps and the contract.
4. Replaced by ADR 0020.

## Reasons

- Constants are visible to every later macro and carry the nilability and default information the router needs to reject unsafe parameters.
- `parse` returns a contract with aggregated errors instead of raising. Forms can then re-render every message together (`contract.values`, `contract.errors`), and JSON and MRDP clients get the same error set.
- A data trie built from a compile-time table keeps the generated code small enough to read and keeps matching free of allocation and regular expressions. Because the table is verified at compile time, the runtime structure cannot drift from the declarations. The trie is built once per process.
- Rejected: reading `instance_vars` in the router macro, because it returns an empty list for top-level code and verifies nothing.
