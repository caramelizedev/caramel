---
name: sweettalk
description: Rules for SweetTalk, the Domain-Driven Design language of this Caramel application. Use when reading or changing app/domain/ or spec/domain/, or when a task names a context, kernel, value, aggregate, entity, command, event, policy, projection, process, service, unit, factory or border.
---

# SweetTalk in this application

shard.lock pins this application's Caramel release. Its SweetTalk guide, in Markdown, is
https://caramelize.dev/docs/VERSION/sweettalk/index.md, with VERSION from shard.lock. Each
line below ends with the section that states it; where they differ, the guide is right.

Read first the map of Domain-Driven Design patterns to SweetTalk words:
https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-ddd

## Rules agents most often break

- Give every context, kernel, value, aggregate, entity, event, projection, specification, service, unit and process `means:`. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-meaning
- Name another context's types (`Other::`) or call its services (`Other.price_of`) only in a context that says `follows: Other`, or inside its `border Other`. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-contexts
- Once a context `publishes`, name and call only what it publishes. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-published
- Name a kernel's types, commands and events (`Money::Cents`) only in a context or kernel that says `shares: Money` and that the kernel's `shared_by:` lists. A kernel holds only values and aggregates, names no context, shares only kernels declared before it, and holds only what two or more of its sharers name. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-kernel
- Name `Caramel::Outbound` or `HTTP::Client` only inside `border Name, outside: "…"`, call it from a `whenever`, and fake it in specs with `Corretto.stub_wire`. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-outside
- `subdomain: :core`, `:supporting` or `:generic` labels a context for readers and changes no rule. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-subdomains
- Change one aggregate per command, service, policy or process step, by as many commands as it needs. For work across aggregates, write a `process`, or emit an event and react to it with `whenever`; two commands inside one `SugarORM::Repo.transaction` commit and roll back together. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-ddd
- When two aggregates must change together, declare a `unit` in the context: `changes:` lists the aggregates its commands change, `locks:` the arguments whose rows it locks first, in table then id order, and a `never` in its body is a rule over the set. Call it from an action, a service or a handler, never from a command; a command on a type outside `changes:`, or on an existing row `locks:` did not name, raises `SweetTalk::Boundary`. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-units
- Change state only in the aggregate's commands (`to`), never through `Rows`. `has tea : Catalogue::Tea` stores an id: load the aggregate with `find` when you need it. Build an entity by name, `Line.new(tea: tea, quantity: quantity)`, so a defaulted attribute may sit anywhere; `created_at` and `updated_at` read the row. An entity holds no entities. `has flag : Bool` reads as `flag?` too, so no `moves` state shares its name. A projection or process attribute other than the key is optional or defaults to a literal or a value built from one, as in `Cents.new(0)`. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-aggregates
- Let the database keep what must hold whoever writes the row: `has label : String, unique: true` or `unique: "sentence"`, `index: true`, `check: {"sql", "sentence"}`, and over several attributes `unique :a, :b, otherwise: "…"`, `index :a, :state` and `check :name, "sql", otherwise: "…"`. A violation is a `Refusal` with that sentence. An entity's `unique` is unique within its aggregate; a projection or process declares none. Before migrating a `unique` onto rows, find the duplicates with `GROUP BY … HAVING count(*) > 1`. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-aggregates
- Say an optional part with `?` only for what may be absent: a column some kinds lack is a value with parts or a state; a rule tying attributes is a `never`. Set a reference with `self.owner = other`. `one_of: %w[…]` is a closed list, and `value Day, Date` a calendar day kept in a `date` column: pass the day in, there is no `Day.today`. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-richer-values
- A rate or an amount with decimals is `value Rate, Decimal(20, 8), at_least: "0"`, exact in a `numeric` column, after `require "caramel/sweet_talk/decimal"`; its bounds are decimal text and its JSON is a string. A document is `value Evidence, Json(Snapshot)` or `Json`, a `jsonb` column asked only for equality or absence, never sorted. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-values
- Emit only the aggregate's own events, `carries: [kind]` for fields it holds. For a change no aggregate holds, declare the context's own `event` (no `carries:`) and `emit` it from a service body, nowhere else. A handler reads the event's fields, which are facts as emitted, not the aggregate now. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-events
- A policy runs as a job after the command commits; jobs start in declaration order (policies, then projections, then processes) and finish in any, so read the event, not another handler's row; a handler that must see another's row saved says `whenever Event, after: Owner`, and that owner's job enqueues it. Set a flaky handler's retries with `attempts:`, `backoff:` and `base:` on its `whenever`. In a spec, read what a command emitted with `SweetTalk.emitted { … }`. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-events
- `context X, event_log: true` keeps every event in `x_events`, in the command's transaction; read it with `X.logged(Event, subject:, since:)`, prune it with `SweetTalk.prune_events(X, before:)` on a schedule, and rebuild a projection from it with `SweetTalk.rebuild(X::Projection)` once the queue is drained. It holds only events logged since it was enabled, and a rebuild replays against present state. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-event-log
- Stop a command with `refuse "message"`. State invariants with `never` and `always`, on the entity when the rule is the entity's, and move the lifecycle with its movers, such as `placed!`. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-commands
- Use a `factory` when an aggregate must start with an event; declaring it removes `create`, so replace each `create` call with the factory in the same change. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-factories
- Read with `find`, `find?`, `all`, and the `finds` and `counts` an aggregate, a projection or a process declares; sort and limit with `order:` and `first:`. A `finds` block is only for what `where:` cannot say. A sum or a group is a projection keyed by what it groups by, added up in Crystal over its `finds` rows; a `GROUP BY` is `SugarORM.sql` outside the context with the tenant predicate written out. `find(id, entities: false)` reads the root alone when a request only checks it; its lists raise, and a command on it loads them. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-queries
- State a rule once with `specification`, then use `name?` in guards and `satisfying:` in queries. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-specifications
- Rename with `renamed_from:`, so tables, channels and queued jobs keep their stored names. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-renames
- In a multi-tenant application, name the `tenant` before the first context, and mark a context `central: true` only when every tenant shares it. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-tenancy
- After changing what the domain stores, run `frappe db diff`, then `frappe migrate`; a row breaking a new CHECK, key or unique index stops it. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-aggregates
- A contract field may be a value or an aggregate's id: it binds from the type the value wraps, and its refusal is the field's error. A value with parts is one field per part. A refusal `handle` does not rescue answers 422, and `SweetTalk::Missing` answers 404; override `render_refusal` to answer otherwise. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-actions

## Not planned

Do not write these; the map says what your release has.

- Partnership and customer/supplier: not planned. https://caramelize.dev/docs/VERSION/sweettalk/index.md#c-sweettalk-ddd

## Verify

Run `frappe check`, `frappe corretto` and `frappe lint`. https://caramelize.dev/docs/VERSION/agents/index.md#c-agents-proof
