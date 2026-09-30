# ADR 0003: Routes read contract field constants; matching walks a boot-time segment trie

Date: 2026-09-27

Status: accepted. Amends [RFC-0001](../rfc.md) §2.1, §2.2 and §3. Decisions 3 and 4 are amended by [ADR 0020](0020-action-ingress-and-json-bodies.md).

## Context

RFC-0001 described its router and contracts with sketches that the implementation does not use:

- `Router.draw` read `Contract.instance_vars` and called `Contract.from_hash`.
- Contracts used a `schema` block of `property` declarations.
- The router expanded into "an inlined, non-allocating radix tree dispatch method".
- `RequestContracts` enforced the 2 MB form cap.

Agents and readers who follow those sketches write code that does not compile. The implementation works and has compile-time checks. This record describes it and makes the RFC say so.

## Decision

1. **Contract declarations are compile-time constants.** An Action declares `contract do … end` with lines of the form `field name : Type, min:, max:, default:`. Each `field` records a `CARAMEL_FIELD_<NAME>` constant holding the name, scalar type, nilability, whether a default exists, and a summary. `Router.draw` reads those constants to verify every route. A route fails to compile when:
   - its action is undefined, does not inherit from `Caramel::Action`, or has no contract;
   - it binds a `:param` to a missing field, or to a field that is nilable, defaulted, or not `String`, `Int32` or `Int64`.

   Each error names the route's source location and gives a one-line remedy.
2. **Contracts are parsed, never hydrated.** `Contract.parse(input)` binds each field by name from, in order, the route parameters, the form body and the query. It collects every error. The router calls `handle` only with a valid contract.
3. **Dispatch.** `draw` generates an `AppRouter` that holds the verified route table, with one generated method per route and a `case` that selects among them. At boot a segment trie is built once from that table:
   - Static children win over the parameter child, and matching backtracks.
   - Matching walks byte offsets in a stack-allocated `Segments` value. It uses no regular expressions and **allocates nothing**.
   - Binding allocates only the decoded parameter strings, the input maps and the contract.
4. **Input limits live in `Caramel::RequestInput`.** Every request is read by `RequestInput` before its contract binds. It caps URL-encoded bodies and multipart text at 2 MiB, and streams file parts to request-scoped tempfiles (64 MiB in total).

## Reasons

- Crystal's `TypeNode#instance_vars` is available only to macros expanded inside methods. For top-level code such as a `Router.draw` block it returns an empty list, so the RFC sketch cannot verify anything. Constants are visible to every later macro and carry the nilability and default information the router needs to reject unsafe parameters.
- `parse` returns a contract with aggregated errors instead of raising. Forms can then re-render every message together (`contract.values`, `contract.errors`), and JSON and MRDP clients get the same error set.
- A data trie built from a compile-time table keeps the generated code small enough to read, which matters for RFC-0008 §3, where every macro must expand to plain Crystal. It also keeps matching free of allocation and regular expressions. Because the table is verified at compile time, the runtime structure cannot drift from the declarations. The trie is built once per process.
- Size limits must apply before any contract exists, and they cover requests whose route or contract never matches. They therefore belong to the input reader, not the contract.

Principles followed:

- Manifesto 7: compile-time AST macros replace runtime reflection.
- Manifesto 3: no hidden abstraction or allocation on the matching path.
- Manifesto 8 and RFC-0008 §2.5: an action reads as contract, handle and egress, with no plumbing.

## Verification

- `scripts/check route-compilation` covers undefined actions, missing contracts, route-contract mismatches, nilable or defaulted parameters, and duplicate or ambiguous routes.
- `scripts/check contract-compilation` covers unsupported types and options.
- `spec/caramel/router_spec.cr` covers precedence, backtracking, 404, 405 and HEAD handling, and asserts with the GC allocation counter that route matching allocates no heap memory.
- `spec/caramel/request_contract_spec.cr` and `spec/caramel/request_input_spec.cr` cover binding, errors and limits.

Full-dispatch allocation and throughput were not measured. Performance work is deferred.
