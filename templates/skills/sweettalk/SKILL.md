---
name: sweettalk
description: Rules for SweetTalk, the Domain-Driven Design language of this Caramel application. Use when reading or changing app/domain/ or spec/domain/, or when a task names a context, kernel, value, aggregate, entity, command, event, policy, projection, process, service, factory or border.
---

# SweetTalk in this application

shard.lock pins this application's Caramel release. Its SweetTalk guide, in Markdown, is
https://caramelize.dev/docs/VERSION/sweettalk/index.md, with VERSION from shard.lock. Each
line below ends with the section that states it; where they differ, the guide is right.

Read first the map of Domain-Driven Design patterns to SweetTalk words:
https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-ddd

## Rules agents most often break

- Give every context, kernel, value, aggregate, entity, event, projection, specification, service and process `means:`. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-meaning
- Name another context's types (`Other::`) or call its services (`Other.price_of`) only in a context that says `follows: Other`, or inside its `border Other`. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-contexts
- Once a context `publishes`, name and call only what it publishes. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-published
- Name a kernel's types, commands and events (`Money::Cents`) only in a context or kernel that says `shares: Money` and that the kernel's `shared_by:` lists. A kernel holds only values and aggregates, names no context, shares only kernels declared before it, and holds only what two or more of its sharers name. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-kernel
- Name `Caramel::Outbound` or `HTTP::Client` only inside `border Name, outside: "…"`, call it from a `whenever`, and fake it in specs with `Corretto.stub_wire`. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-outside
- `subdomain: :core`, `:supporting` or `:generic` labels a context for readers and changes no rule. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-subdomains
- Change one aggregate per command, service, policy or process step, by as many commands as it needs. For work across aggregates, write a `process`, or emit an event and react to it with `whenever`; two commands inside one `SugarORM::Repo.transaction` commit and roll back together. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-ddd
- Change state only in the aggregate's commands (`to`), never through `Rows`. `has tea : Catalogue::Tea` stores an id: load the aggregate with `find` when you need it. Build an entity by name, `Line.new(tea: tea, quantity: quantity)`, so a defaulted attribute may sit anywhere; `created_at` and `updated_at` read the row. An entity holds no entities. `has flag : Bool` reads as `flag?` too, so no `moves` state shares its name. A projection or process attribute other than the key is optional or defaults to a literal or a value built from one, as in `Cents.new(0)`. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-aggregates
- Say an optional part with `?` only for what may be absent: a column some kinds lack is a value with parts or a state; a rule tying attributes is a `never`. Set a reference with `self.owner = other`. `one_of: %w[…]` is a closed list, and `value Day, Date` a calendar day kept in a `date` column: pass the day in, there is no `Day.today`. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-richer-values
- Emit only the aggregate's own events, `carries: [kind]` for fields it holds. A handler reads the event's fields, which are facts as emitted, not the aggregate now. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-events
- A policy runs as a job after the command commits; jobs start in declaration order (policies, then projections, then processes) and finish in any, so read the event, not another handler's row. Set a flaky handler's retries with `attempts:`, `backoff:` and `base:` on its `whenever`. In a spec, read what a command emitted with `SweetTalk.emitted { … }`. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-events
- Stop a command with `refuse "message"`. State invariants with `never` and `always`, on the entity when the rule is the entity's, and move the lifecycle with its movers, such as `placed!`. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-commands
- Use a `factory` when an aggregate must start with an event; declaring it removes `create`, so replace each `create` call with the factory in the same change. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-factories
- Read with `find`, `find?`, `all`, and the `finds` and `counts` an aggregate, a projection or a process declares; sort and limit with `order:` and `first:`. A `finds` block is only for what `where:` cannot say. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-queries
- State a rule once with `specification`, then use `name?` in guards and `satisfying:` in queries. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-specifications
- Rename with `renamed_from:`, so tables, channels and queued jobs keep their stored names. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-renames
- In a multi-tenant application, name the `tenant` before the first context, and mark a context `central: true` only when every tenant shares it. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-tenancy
- After changing what the domain stores, run `frappe db diff`, then `frappe migrate`; a row breaking a new CHECK or key stops it. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-aggregates
- A contract field may be a value or an aggregate's id: it binds from the type the value wraps, and its refusal is the field's error. A value with parts is one field per part. A refusal `handle` does not rescue answers 422, and `SweetTalk::Missing` answers 404; override `render_refusal` to answer otherwise. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-actions

## Not planned

Do not write these; the map says what your release has.

- Partnership, customer/supplier and an event log: not planned. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-ddd

## Verify

Run `frappe check`, `frappe corretto` and `frappe lint`. https://caramelize.dev/docs/VERSION/agents/index.md#c-agents-proof
