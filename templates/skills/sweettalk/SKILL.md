---
name: sweettalk
description: Rules for SweetTalk, the Domain-Driven Design language of this Caramel application. Use when reading or changing app/domain/ or spec/domain/, or when a task names a context, value, aggregate, entity, command, event, policy, projection, process, service, factory or border.
---

# SweetTalk in this application

shard.lock pins this application's Caramel release. Its SweetTalk guide, in Markdown, is
https://caramelize.dev/docs/VERSION/sweettalk/index.md, with VERSION from shard.lock. Each
line below ends with the section that states it; where they differ, the guide is right.

Read first the map of Domain-Driven Design patterns to SweetTalk words:
https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-ddd

## Rules agents most often break

- Give every context, value, aggregate, entity, event, projection, service and process `means:`. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-meaning
- Name another context's types (`Other::`) or call its services (`Other.price_of`) only in a context that says `follows: Other`, or inside its `border Other`. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-contexts
- Once a context `publishes`, name and call only what it publishes. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-published
- Name `Caramel::Outbound` or `HTTP::Client` only inside `border Name, outside: "…"`, call it from a `whenever`, and fake it in specs with `Corretto.stub_wire`. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-outside
- `subdomain: :core`, `:supporting` or `:generic` labels a context for readers and changes no rule. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-subdomains
- Change one aggregate per command, service, policy or process step. For work across aggregates, write a `process`, or emit an event and react to it with `whenever`. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-ddd
- Change state only in the aggregate's commands (`to`), never through `Rows`. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-aggregates
- `has tea : Catalogue::Tea` stores an id: load the aggregate with `find` when you need it. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-aggregates
- Emit only the aggregate's own events. A handler reads the event's fields, which are facts as emitted, not the aggregate now. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-events
- Stop a command with `refuse "message"`. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-commands
- State invariants with `never` and `always`, and move the lifecycle with its movers, such as `placed!`. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-lifecycle
- Use a `factory` when an aggregate must start with an event; it then has no `create`. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-factories
- Read with `find`, `find?`, `all`, and the `finds` and `counts` an aggregate or a projection declares; sort and limit with `order:` and `first:`. Use a `finds … do |rows|` block only for what `where:` cannot say. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-queries
- State a rule once with `specification`, then use `name?` in guards and `satisfying:` in queries. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-specifications
- Rename with `renamed_from:`, so tables, channels and queued jobs keep their stored names. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-renames
- In a multi-tenant application, name the `tenant` before the first context, and mark a context `central: true` only when every tenant shares its rows. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-tenancy
- After changing what the domain stores, its lifecycle states included, run `frappe db diff`, then `frappe migrate`; a row in a removed state stops the migration. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-lifecycle
- A contract field may be a value or an aggregate's id: it binds from the type the value wraps, and the value's refusal becomes the field's error. A value with parts is one field per part. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-actions
- A refusal that an action's `handle` does not rescue answers 422, and `SweetTalk::Missing` answers 404; override `render_refusal` to answer otherwise. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-actions

## Not available yet

Do not write these; the map says what your release has.

- Shared kernel, partnership, customer/supplier and an event log: not planned. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-ddd

## Verify

Run `frappe check`, `frappe corretto` and `frappe lint`. https://caramelize.dev/docs/VERSION/agents/index.md#c-agent-proof
