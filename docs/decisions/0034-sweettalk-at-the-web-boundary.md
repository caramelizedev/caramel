# ADR 0034: SweetTalk at the web boundary: refusals answer 422, and values bind as contract fields

Date: 2026-10-13

Status: accepted. Amends [ADR 0003](0003-core-routing-and-contracts.md) decision 1, and
applies [ADR 0030](0030-sweettalk-domain-language.md) to actions.

## Context

A SweetTalk command that says no raises `SweetTalk::Refusal`. Raised in an action's
`handle`, it reached `Application#route`'s last rescue: the client got a 500 with a
reference, and Crema reported an unhandled error, although a domain rule saying no is an
answer, not a fault. A contract field took only `String`, `Int32`, `Int64`, `Float64`,
`Bool`, `Time` and `UploadedFile`, so an action read an `Int32` and built a `Quantity` in
`handle`, where its refusal named no field.

## Decision

1. **Core answers a valid contract through a hook.** The router runs `handle` and
   `respond` inside `Caramel::Action#__caramel_answer(contract) { … }`, whose core body
   only yields, like the hooks of [ADR 0025](0025-multi-tenancy.md) decision 1. Core code
   never names SweetTalk.
2. **`require "caramel/sweet_talk"` redefines the hook.**
   - A `SweetTalk::Refusal` that `handle` does not rescue answers 422 through
     `render_refusal(contract, refusal)`. Its message joins the contract's errors under
     `_base`. A JSON client gets `{"errors": {"_base": [message]}}`, a browser or an htmx
     request `contract_failure_page(contract)`, and any other client MRDP text starting
     `ERR INVALID:422`, as `render_errors` answers. An action overrides
     `contract_failure_page` to re-render its form with the refusal, or `render_refusal`
     to answer otherwise.
   - A `SweetTalk::Missing` answers 404 with `Not found`, as a route parameter that does
     not convert does. `find`, and a command whose aggregate is gone, raise it. Asking an
     aggregate for its id before `create`, or an event for its subject before it is
     emitted, raises `NilAssertionError` instead, since that is a programming error.
   - Neither is reported to Crema as an error. The command's domain span still records
     the refusal.
   - `SweetTalk::Boundary` is a programming error. It stays a 500 with an unhandled
     report.

   A refusal raised by an authenticator, or inside a streamed body, is not answered this
   way.
3. **A contract field may take a field value** (amends ADR 0003 decision 1). A type that
   includes `Caramel::FieldValue(W)` and defines `self.from_field(raw : W, & : String ->)`
   binds like a field of `W`, which is `String`, `Int32`, `Int64`, `Float64`, `Bool` or
   `Time`. The JSON type, the text grammar and the "must be a valid" error are `W`'s; then
   `from_field` returns the value, or yields a message that becomes the field's error. Such
   a field may be nilable, take `default:` and be an `Array` item. It binds a route
   parameter when `W` is `String`, `Int32` or `Int64`, and takes no `min:` or `max:`. Its
   summary names both types, as in `quantity:Ordering::Quantity(Int32)`, and
   `CARAMEL_FIELD_<NAME>` adds the declared type.
4. **SweetTalk's values and ids are field values.** A value that wraps `Int32`, `Int64` or
   `String` binds from it, and its refusal is the field's error:
   `quantity: Quantity must be between 1 and 10`. `Name::Id` binds from `Int64` and never
   refuses; a route parameter that is not an `Int64` answers 404. A value with parts is not
   a field value: an action builds it from one field per part.

## Reasons

- A refusal is the domain's answer to a valid request, so it is answered like an invalid
  one: 422, in the shapes ADR 0003 and [ADR 0020](0020-action-ingress-and-json-bodies.md)
  give contract failures, without an error report that would page someone. A boundary
  error is a bug, so it stays a 500.
- An identity hook keeps the mapping out of every program that does not require
  `caramel/sweet_talk`, and `scripts/check sweet-talk-compilation` proves it on the binary.
  Crystal inlines a method that yields, so the hook adds no call to core.
- Answering a browser with `contract_failure_page` lets one override serve both failures,
  and generated forms already list `_base` messages.
- A protocol in core lets any type bind, not only SweetTalk's, and keeps one grammar per
  wire type, so a JSON client and a form get the same errors with or without values.
- Binding a value in the contract gives its refusal the field's key, which a form shows
  beside its input, and a route parameter typed `Order::Id` keeps a `Tea::Id` out.

Rejected:

- **Answering refusals in `Application#failure`.** It knows the request, not the action,
  so it can neither re-render the action's form nor use its layout.
- **A module each action includes.** It needs the same hook, and an action that forgets it
  answers 500 again.
- **`rescue SweetTalk::Refusal` in each `handle`.** One forgotten rescue is a 500.
- **A SweetTalk branch in the contract macro.** Core would name SweetTalk, and no other
  type could bind.
- **409 for a refusal.** Caramel answers errors found after the contract with 422
  (`render_errors`); one status keeps a client's handling to one shape.
- **Deferred:** refusal messages translated by `caramel/i18n`
  ([ADR 0024](0024-internationalization.md)); a refusal's text is the domain's English.
