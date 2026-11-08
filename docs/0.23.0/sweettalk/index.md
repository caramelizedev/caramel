Guides / SweetTalk

# Speak the domain’s language.

SweetTalk is an opt-in language for Domain-Driven Design. Its words expand into SugarORM schemas and changesets and Cold Brew jobs, so the domain keeps its own vocabulary and Caramel keeps one way to store and run it.

| Contract | Value |
| --- | --- |
| Needs | A Caramel application that requires `caramel/sweet_talk`, and PostgreSQL for its specs |
| You will have | A domain in `app/domain/` with its own words |
| Status | Experimental: new in 0.13.0, until an application has run it in production |
| Proved by | `frappe check` · `frappe db diff` · `frappe corretto` |

Prefer to see it built first? [Build a box office](https://caramelize.dev/docs/0.23.0/box-office/index.md) follows one domain in order, from the first command to passing specs. This guide lists every word and rule.

> Experimental **A minor release may change the names it stores.**
>
> SweetTalk is new in Caramel 0.13.0. Until an application has run it in production, it is experimental, and its upgrade notes say how to move the names. The examples are excerpts of the tea shop, the tea house, the shelf of its rules, the pantry of its constraints, the estate split across files and the tenant shop that its specs run against PostgreSQL, in the framework’s `spec/sweet_talk/support/` and `spec/sweet_talk_tenancy/support/`; the action is from the Box Office path. Accepted in ADRs 0030, 0031, 0033, 0034 to 0036, 0044 to 0051, 0053 to 0063 and 0065.

## The guide in seven stages {#c-sweettalk-map}

37 sections · read in order the first time

- **1 · Start**

  - [Opt in](#c-sweettalk-enable)
  - [Find the Domain-Driven Design patterns](#c-sweettalk-ddd)
  - [Give every noun a meaning](#c-sweettalk-meaning)
- **2 · Draw boundaries**

  - [Draw the contexts](#c-sweettalk-contexts)
  - [Mark the core domain](#c-sweettalk-subdomains)
  - [Publish a language](#c-sweettalk-published)
  - [Share a kernel](#c-sweettalk-kernel)
  - [Translate outside systems at a border](#c-sweettalk-outside)
- **3 · Model**

  - [Name the values](#c-sweettalk-values)
  - [Name strings and values with parts](#c-sweettalk-richer-values)
  - [Count money in its currency](#c-sweettalk-money)
  - [Declare aggregates and entities](#c-sweettalk-aggregates)
  - [Guard the lifecycle and the invariants](#c-sweettalk-lifecycle)
  - [Change state with commands](#c-sweettalk-commands)
  - [Make aggregates with factories](#c-sweettalk-factories)
- **4 · Query and decide**

  - [Find, count and retire aggregates](#c-sweettalk-queries)
  - [Name rules with specifications](#c-sweettalk-specifications)
  - [Name operations with services](#c-sweettalk-services)
  - [Change aggregates together with units](#c-sweettalk-units)
  - [Name a calculation and its rules](#c-sweettalk-calculations)
- **5 · React**

  - [Follow events with policies](#c-sweettalk-events)
  - [Keep an event log](#c-sweettalk-event-log)
  - [Read what was known at a time](#c-sweettalk-known-at)
  - [Record who acted](#c-sweettalk-metadata)
  - [Keep read models](#c-sweettalk-projections)
  - [Run processes with deadlines and compensation](#c-sweettalk-processes)
- **6 · Operate**

  - [Split a context across files](#c-sweettalk-files)
  - [Rename without moving data](#c-sweettalk-renames)
  - [Share a domain between tenants](#c-sweettalk-tenancy)
  - [Read the glossary and the context map](#c-sweettalk-glossary)
  - [Look up a word](#c-sweettalk-words)
  - [Trace requirements to rules and examples](#c-sweettalk-requirements)
  - [Call the domain from actions](#c-sweettalk-actions)
  - [Show the domain on screens](#c-sweettalk-screens)
  - [Preview a change before it commits](#c-sweettalk-preview)
- **7 · Limits**

  - [What does not compile](#c-sweettalk-refusals)
  - [Not covered yet](#c-sweettalk-limits)

Stage 1 · Start

## Opt in {#c-sweettalk-enable}

Let Frappé start a domain. It adds `require "caramel/sweet_talk"` after `require "caramel"`, and `require "../app/domain/*"` with `SweetTalk.boot` after it, to `config/application.cr`, writes `app/domain/shop.cr` with that context, and a spec in `spec/domain/`. A plain application compiles none of SweetTalk.

**Terminal · inside your application**

```bash
frappe make domain Shop Ordering --means="choosing teas and checking out"
```

**Expect:** Prints `Generated app/domain/shop.cr` and `Generated spec/domain/shop_spec.cr`. It also prints `Generated config/application.cr` when it adds the requires, and `Generated .claude/skills/sweettalk/SKILL.md` when the application has no SweetTalk skill.

> Agents
>
> The skill lists the rules agents most often break. Each ends with a link to its section here, so the guide stays the one source. An existing skill, edited or not, is left alone.

A multi-tenant application passes `--central` for a context every tenant shares: [Share a domain between tenants](#c-sweettalk-tenancy).

By hand, require SweetTalk after Caramel:

**config/application.cr · excerpt**

```crystal
require "caramel"
require "caramel/sweet_talk"
```

Then include `SweetTalk` in the module that holds your domain. The words exist only there: a `context` or `has` anywhere else is an ordinary call.

**app/domain/tea_shop.cr · opening**

```crystal
module TeaShop
  include SweetTalk

  context Catalogue, means: "the teas on our shelves" do
    # values, aggregates and projections
  end
end
```

A word that brings a dependency, serves one family of domains or adds a check some domains would refuse lives in a module with a require of its own ([ADR 0061 ↗](https://github.com/caramelizedev/caramel/blob/main/docs/decisions/0061-sweettalk-modules.md)). `caramel/sweet_talk/decimal` is one: it adds `Decimal(P, S)` values and links GMP ([Name the values](#c-sweettalk-values)). A module requires the core itself, so its require may replace `require "caramel/sweet_talk"`. A module’s word without its require fails compilation and names the require, and a program without the require holds none of the module’s code. A module adds words and never changes what a core word means.

## Find the Domain-Driven Design patterns {#c-sweettalk-ddd}

23 of the 26 patterns below have a SweetTalk word. The table names the word and the section that states its rules. A pattern SweetTalk lacks says so.

| Pattern | In SweetTalk | Rules |
| --- | --- | --- |
| Bounded context | `context`, a module with its own vocabulary. | [Draw the contexts](#c-sweettalk-contexts) |
| Module | `within`, which continues a context in another file, so its concepts are grouped by file. | [Split a context across files](#c-sweettalk-files) |
| Ubiquitous language | `means:` on every noun, and `SweetTalk.glossary`, which lists each with its kind and context. | [Give every noun a meaning](#c-sweettalk-meaning) |
| Entity | `entity`, which lives inside one aggregate and is saved with it. | [Declare aggregates and entities](#c-sweettalk-aggregates) |
| Value object | `value`: a number or a string with its bounds, or a value with parts, stored one column per part (`<attribute>_<part>`). | [Name the values](#c-sweettalk-values), [values with parts](#c-sweettalk-richer-values) |
| Aggregate | `aggregate`, a root with an id that only its commands change. Its entities reach the database only through it: a context that names `Rows` does not compile. | [Declare aggregates and entities](#c-sweettalk-aggregates), [commands](#c-sweettalk-commands) |
| Repository | The aggregate’s own `create`, `find`, `find?` and `all`, and the queries `finds`, `counts`, `sums` and `groups` declare: filtered by attributes, states and specifications, sorted with `order:`, limited with `first:`, added up by an attribute, or narrowed by a block that never names `Rows` and always returns aggregates. | [Find, count and retire aggregates](#c-sweettalk-queries) |
| Factory | `factory`. | [Make aggregates with factories](#c-sweettalk-factories) |
| Domain service | `service`, which changes at most one aggregate. | [Name operations with services](#c-sweettalk-services) |
| Domain event | `event` and `emit`. Each event records who acted and what caused it. | [Follow events with policies](#c-sweettalk-events), [Record who acted](#c-sweettalk-metadata) |
| Event handler (policy) | `whenever`, run as a Cold Brew job. | [Follow events with policies](#c-sweettalk-events) |
| Side-effect-free function | `calculation`, a typed function of a context whose `never` and `always` lines hold on its result; `the`, a derived value computed on every read; and plain Crystal methods in an aggregate’s or an entity’s body. | [Name a calculation and its rules](#c-sweettalk-calculations), [the invariants](#c-sweettalk-lifecycle) |
| Specification | `specification`, a rule stated once in `where:` and read both in Crystal, as a predicate such as `order.astray?`, and in PostgreSQL, by `satisfying:`. | [Name rules with specifications](#c-sweettalk-specifications) |
| Lifecycle (state machine) | `moves`, checked in Crystal and held in PostgreSQL by a `CHECK` constraint on the state column. A PostgreSQL enum type is not used, because `ALTER TYPE` cannot drop a value. | [Guard the lifecycle and the invariants](#c-sweettalk-lifecycle) |
| Process manager or saga | `process`, with `deadline` and `compensate`. | [Run processes](#c-sweettalk-processes) |
| Read model | `projection`, queried with `finds` and `counts`. | [Keep read models](#c-sweettalk-projections) |
| Transactional outbox | Built in: a command enqueues its policies’, projections’ and processes’ jobs in its own transaction, and publishes its notification with `pg_notify`, which PostgreSQL delivers when that transaction commits. | [Follow events with policies](#c-sweettalk-events) |
| Conformist | `follows:`, which adopts another context’s types as they are. | [Draw the contexts](#c-sweettalk-contexts) |
| Anticorruption layer | `border Other`, which translates another context’s events, values and ids into this one’s. Code in it may also read `Other::` directly, or call `Other.price_of`, which draws a dependency edge. `border Cards, outside: "…"` is the border with a system outside the program, the only code that may name `Caramel::Outbound` or `HTTP::Client`, a check on the code as written. | [Draw the contexts](#c-sweettalk-contexts), [Translate outside systems at a border](#c-sweettalk-outside) |
| Open-host service | The services a context lists in `publishes`: in one binary, a set of calls other contexts may make. | [Publish a language](#c-sweettalk-published) |
| Published language | `publishes`, the types, services, units and calculations other contexts may name; any other name of the context does not compile outside it. | [Publish a language](#c-sweettalk-published) |
| Shared kernel | `kernel`: values, and aggregates with their events, that the contexts and kernels in its `shared_by:` share, each saying `shares:`. `central: true` is tenancy, not a shared kernel. | [Share a kernel](#c-sweettalk-kernel) |
| Partnership | Not planned. Two contexts may react to each other’s events, but their dependency edges may not form a cycle. | [Draw the contexts](#c-sweettalk-contexts) |
| Customer/supplier | Not planned. A supplier’s promise to its customers is what it `publishes`. | [Publish a language](#c-sweettalk-published) |
| Distillation (core, supporting and generic subdomains) | `subdomain:` on `context`, carried by every glossary term. The label changes no rule the compiler checks. | [Mark the core domain](#c-sweettalk-subdomains) |
| Event sourcing | Not planned. State lives in rows. `event_log: true` keeps a context’s events in a table, which rebuilds a projection, answers an audit and says what was known at a time, but no aggregate is loaded from it. | [Keep an event log](#c-sweettalk-event-log), [Read what was known at a time](#c-sweettalk-known-at) |

Some differences from the patterns as usually described are deliberate:

- **The repository lives on the aggregate.** The aggregate already meets the repository’s rules: it reaches roots only, offers a collection’s interface (`create`, `find`, `find?`, `all`), and names its queries in domain terms with `finds`, whose keys are attributes and states the compiler checks, never SQL or SugarORM’s query syntax; a separate repository word would add a second name for the same thing (ADR 0030 decision 2, ADR 0031 decision 3).
- **One aggregate per transaction, services included.** A command, a service, a policy and a process step each change at most one aggregate, so each lock and each invariant stays its aggregate’s own; work across aggregates is a process, a policy that reacts to an event, or a `unit`, which names the aggregates it changes and locks their rows first (ADR 0030 decision 5, ADR 0031 decision 5, ADR 0046).
- **Events belong to their aggregate, or their context.** An aggregate emits only its own events and an entity emits none, because the aggregate guards the invariants its entities share; an entity changes through its aggregate’s commands. A context emits its own from a service, for a change no aggregate holds (ADR 0030 decision 2).
- **Contexts are modules of one binary.** Contexts call each other in the same process and react to each other’s events through Cold Brew jobs, so there is no RPC or HTTP transport between them (ADR 0030, Reasons).
- **`central: true` is tenancy.** It shares a context’s rows between the tenants of a multi-tenant application. A `kernel` shares a model between named contexts, and its rows still belong to one tenant (ADR 0033 decision 2, ADR 0044).
- **State lives in rows.** An event drives its policies, projections and processes, and SweetTalk expands into SugarORM tables and keeps state in PostgreSQL. A context that says `event_log: true` keeps its events in a table beside its rows, for audits, for rebuilding a projection and for reading what happened; the rows stay the truth, and nothing replays the log to load an aggregate (ADR 0030 decisions 4 and 6, ADR 0048).

Specs run the domain against real PostgreSQL. Each Corretto example rolls back, and `drain_queue!` runs the jobs a command enqueued at once, so a spec of a policy, a projection or a process waits for no worker; `drain_queue!(db, include_scheduled: true)` runs a deadline whose time has not come.

## Give every noun a meaning {#c-sweettalk-meaning}

Every context, kernel, value, aggregate, entity, event, projection, specification, service, unit, calculation and process carries `means:`. A noun without one does not compile, and `SweetTalk.glossary` lists every entry with its kind, its context and that context’s subdomain, so the ubiquitous language is part of the program.

The same word may mean different things in two contexts:

| Noun | Means |
| --- | --- |
| `Catalogue::Tins` | “a count of tins on the shelf” |
| `Fulfilment::Tins` | “tins of one tea packed in a parcel” |

Stage 2 · Draw boundaries

## Draw the contexts {#c-sweettalk-contexts}

A `context` is a bounded context: a module with its own vocabulary. `follows:` adopts another context’s types as they are. A `border` is the one place where a context may name a context it does not follow, and it translates that context’s values and ids into its own. A context that outgrows its file continues in others ([Split a context across files](#c-sweettalk-files)). Here each context reacts to the other’s event:

**app/domain/tea_shop.cr · two contexts**

```crystal
context Ordering, follows: Catalogue, means: "choosing teas and checking out" do
  # Ordering may name Catalogue::Tea anywhere.

  border Fulfilment do
    whenever Fulfilment::Parcel::Dispatched do |dispatched|
      Order.find(Order::Id.new(dispatched.order)).ship
    end
    # …
  end
end

context Fulfilment, means: "packing and dispatching parcels" do
  value Tins, Int32, at_least: 1, means: "tins of one tea packed in a parcel"
  # …

  border Ordering do
    whenever Ordering::Order::Placed do |placed|
      packings = placed.lines.map do |line|
        Parcel::Packing.new(line.tea.raw, Tins.new(line.quantity))
      end
      address = placed.deliver_to
      label = Label.new(street: address.street, city: address.city,
        postcode: address.postcode.raw)
      Parcel.pack placed.order_id.raw, packings, label
    end
    # …
  end
end
```

The context map is checked when the program compiles:

| Condition | Outcome |
| --- | --- |
| `follows: B` | draws a dependency edge to B |
| Anything in `border B` other than the event a `whenever` names | draws a dependency edge to B |
| A `whenever` that reacts to one of B’s events | draws an event edge |
| Naming `B::`, or calling `B.price_of`, in a context that follows B | allowed anywhere, unless B publishes and leaves the name out |
| Naming `B::`, or calling `B.price_of`, inside `border B` | allowed; a call draws a dependency edge too |
| A foreign name or call anywhere else | fails compilation |
| An edge to an unknown context | fails compilation |
| A cycle of dependency edges, such as Ordering and Fulfilment following each other | fails compilation |
| Ordering and Fulfilment reacting to each other’s events | allowed |
| `follows: B` in a context that names no `B::` and calls no `B.verb` outside `border B` | fails compilation at the context’s line |

For example, a foreign name outside a border stops the build with “Shop::Ordering names Catalogue:: outside a border: move that code into border Catalogue do … end, or declare follows: Catalogue”. A `follows:` nothing uses stops it with “Shop::Ordering follows Catalogue, but names no Catalogue:: and calls no Catalogue.verb outside a border with Catalogue: remove Catalogue from follows:”. An unused edge would still count in the cycle check.

`SweetTalk.context_map` returns the edges.

## Mark the core domain {#c-sweettalk-subdomains}

`subdomain:` on a context says which part of the business it serves:

| Value | Use for |
| --- | --- |
| `:core` | what sets the business apart |
| `:supporting` | what the core needs but could be built by anyone |
| `:generic` | a problem many businesses share |

It is optional and changes no rule, because no check can measure how carefully a core is modelled. Every glossary term carries its context’s subdomain, so `SweetTalk.glossary.select { |term| term.subdomain == "core" }` lists the core domain’s language. Any other value does not compile.

**app/domain/tea_house.cr · subdomains**

```crystal
context Pricing, shares: [Money, Calendar], subdomain: :supporting,
  means: "what each tea costs" do
  # …
end

context Billing, follows: Pricing, shares: [Money, Calendar], subdomain: :core,
  means: "charging members for their teas" do
  # …
end
```

## Publish a language {#c-sweettalk-published}

An upstream context can promise less than all of its model. `publishes` lists the types, services, units and calculations other contexts may name: its published language, and, in one binary, its open-host service. Naming a type publishes what it contains, so publishing `Tea` would publish `Tea::Id` and its commands too. `publishes` comes after the names it lists.

**app/domain/tea_house.cr · a published language**

```crystal
context Pricing, shares: [Money, Calendar], subdomain: :supporting,
  means: "what each tea costs" do
  aggregate Tea, means: "one tea and its price" do
    # …
  end

  service price_of(tea : Tea::Id), returns: Money::Cents, means: "what one tea costs today" do
    Tea.find(tea).price
  end

  publishes Tea::Id, price_of
end

context Billing, follows: Pricing, shares: [Money, Calendar], subdomain: :core,
  means: "charging members for their teas" do
  service bill(tea : Pricing::Tea::Id), returns: Bill::Id,
    means: "bill a member for one tea at today's price" do
    Bill.open(Pricing.price_of(tea)).id
  end
end
```

| Condition | Outcome |
| --- | --- |
| A context names a type or service the publisher does not list, whether it follows the publisher or reads it in a border | fails compilation at the line that names it |
| `publishes` lists a name the context does not declare | fails compilation |
| The publisher is declared after the context that names it | fails compilation; the program’s checks find the name, without a line |
| A context reacts to an event of a publishing context | allowed: events stay open to every context that may name them, because a follower reacts to them and a reaction depends on an event’s fields |
| A context does not publish | keeps the rules above |

For example, “Shop::Ordering names Catalogue::Tea, which Catalogue does not publish; it publishes Cents, Tea::Id, price_of: use one of those, or publish Tea in Catalogue”.

## Share a kernel {#c-sweettalk-kernel}

Two contexts that own part of a model together share it in a kernel. `kernel` declares that part beside the contexts: values, and aggregates with their entities, events and commands. `shared_by:` lists the two or more contexts or kernels that share it, and each of them says `shares:`, so a new sharer edits the kernel too.

A sharer names the kernel’s types as its own, runs its aggregates’ commands and reacts to its events, outside any border. No other context names the kernel, and the kernel names no context. A kernel may share a kernel declared before it, as `Money` shares `Calendar` below, so a voucher’s expiry is the calendar’s `Day`, not a copy. A kernel comes before the ones that share it.

Each value and aggregate of a kernel is named by at least two of its sharers, unless another word of the same kernel uses it, so a word only one sharer names moves into that sharer. The check reads the code as written: a sharer that only passes a value along, without writing its name, does not count.

**app/domain/tea_house.cr · shared kernels**

```crystal
kernel Calendar, shared_by: [Money, Pricing, Billing],
  means: "the days the tea house counts in" do
  value Day, Date, means: "a calendar day"
end

kernel Money, shared_by: [Pricing, Billing], shares: Calendar,
  means: "the money pricing and billing agree on" do
  value Cents, Int64, at_least: 0, means: "an amount of money"

  aggregate Voucher, means: "an amount off one tea's bill, spent once" do
    has amount : Cents
    has expires_on : Calendar::Day?
    moves unspent >> spent

    event Spent, tea : Int64, on : Calendar::Day, carries: [amount, expires_on],
      means: "a member spent a voucher on a tea"

    finds expiring(from : Calendar::Day, to : Calendar::Day), where: {expires_on: from..to}

    to spend(tea : Int64, on : Calendar::Day) do
      expiry = expires_on
      refuse "A voucher cannot be spent after it expires." if expiry && on > expiry
      spent!
      emit Spent, tea: tea, on: on
    end
  end
end

context Pricing, shares: [Money, Calendar], subdomain: :supporting,
  means: "what each tea costs" do
  # …
  service give(amount : Money::Cents, expires_on : Calendar::Day?), returns: Money::Voucher::Id,
    means: "give a member an amount off one tea" do
    Money::Voucher.create(amount: amount, expires_on: expires_on).id
  end
end

context Billing, follows: Pricing, shares: [Money, Calendar], subdomain: :core,
  means: "charging members for their teas" do
  # …
  service spend(voucher : Money::Voucher::Id, tea : Pricing::Tea::Id, on : Calendar::Day),
    means: "spend a voucher on one tea" do
    Money::Voucher.find(voucher).spend(tea.raw, on)
  end

  whenever Money::Voucher::Spent do |spent|
    Bill.open(Pricing.price_of(Pricing::Tea::Id.new(spent.tea)) - spent.amount)
  end
end
```

| Condition | Outcome |
| --- | --- |
| `shares: Money` in a context or kernel that Money’s `shared_by:` lists | draws a kernel edge to Money |
| A sharer names `Money::Cents`, calls `Money::Voucher.find` or reacts to `Money::Voucher::Spent` | allowed anywhere in the sharer |
| Another context or kernel names `Money::`, or a context follows Money or has a border with it | fails compilation |
| `shares:` of a context, of a kernel declared after the one saying it, or of a kernel whose `shared_by:` leaves it out | fails compilation at the line that says it |
| A `shared_by:` of fewer than two contexts or kernels, or of one that does not say `shares:` | fails compilation |
| A kernel that holds a service, projection, process, specification, border or policy, names a context, or reaches `Caramel::Outbound` | fails compilation |
| A value or aggregate of a kernel that fewer than two sharers name and no other word of the kernel uses | fails compilation, naming where it belongs |
| `shares: Money` in a context or kernel that names nothing in Money | fails compilation at its line, saying to remove Money from `shares:` and the sharer from `shared_by:` |

For example, “Shop::Fulfilment names Money::, a kernel it does not share: say shares: Money and list Fulfilment in its shared_by:, or leave Money to the ones that share it”, and “Shop::Money::Millionths is named only by Catalogue: a kernel holds what two or more of its sharers name; move Millionths into Catalogue”.

A kernel stores like a context: the tea house keeps its vouchers in `money_vouchers`, with `expires_on` a `date` column, and in a multi-tenant application a kernel’s rows belong to the tenant, because a kernel takes no `central:`. `SweetTalk.context_map` draws a `kernel` edge from each sharer, and the glossary lists each kernel with kind `kernel` as the context of its values, aggregates and events.

## Translate outside systems at a border {#c-sweettalk-outside}

A payment gateway or a carrier has a model of its own. `border Cards, outside: "…"` declares a module `Cards` in the context: the only code in it that may name `Caramel::Outbound` or `HTTP::Client`, and the place that turns the system’s answers into the context’s values and refusals.

The check reads the code as written, as the `Rows::` and `Other::` checks do, so an alias or a method defined outside the context escapes it. `outside:` is the line its glossary entry shows, and the context map gains an `outside` edge.

An outside system emits no events; a webhook arrives through an action, which runs a command.

Call the system from a `whenever`, after the command that needs it commits, so that a slow answer never holds an aggregate’s row lock. A command, a factory or a unit body that names the border’s module fails compilation, because a preview runs that body and rolls it back, and a call outside cannot be taken back. While a preview runs, `Caramel::Outbound` raises `Caramel::Outbound::Refused`, which catches an alias or a method defined outside the context.

Specs fake it at the wire with `Corretto.stub_wire`, as the Corretto reference’s “Third parties are faked at the wire” states. [Read the Corretto reference →](https://caramelize.dev/docs/0.23.0/corretto/index.md)

| Condition | Outcome |
| --- | --- |
| `Caramel::Outbound` or `HTTP::Client` named outside a `border …, outside:` | fails compilation |
| An `outside:` border named like a context | fails compilation |
| An `outside:` border holding a `whenever` | fails compilation |
| A command, a factory or a unit body that names an `outside:` border’s module | fails compilation |
| `Caramel::Outbound` called while `SweetTalk.preview` runs | raises `Caramel::Outbound::Refused` |

**app/domain/tea_house.cr · an outside system**

```crystal
whenever Bill::Opened do |opened|
  reference = Cards.charge(opened.bill_id.raw, opened.amount)
  Bill.find(opened.bill_id).settle reference
end

compensate Bill::Opened do |opened, refusal|
  Bill.find(opened.bill_id).decline
end

border Cards, outside: "the card gateway we charge through" do
  CHARGES = "https://cards.example/v1/charges"

  def self.charge(bill : Int64, amount : Money::Cents) : Reference
    headers = HTTP::Headers{"Content-Type" => "application/json"}
    body = {bill: bill, amount: amount.raw}.to_json
    response = Caramel::Outbound.post(CHARGES, headers, body)
    case response.status_code
    when 200 then Reference.new(JSON.parse(response.body)["id"].as_s)
    when 402 then raise SweetTalk::Refusal.new("The card was declined.")
    else          raise "Cards answered #{response.status_code}: #{response.body}"
    end
  end
end
```

Stage 3 · Model

## Name the values {#c-sweettalk-values}

**app/domain/tea_shop.cr · values**

```crystal
value Tins, Int32, at_least: 0, means: "a count of tins on the shelf"
value Cents, Int64, at_least: 0, means: "an amount of money"
value Quantity, Int32, within: 1..10, means: "tins of one tea in one order"
```

A value wraps an `Int32`, an `Int64`, a `String`, a `Date`, a `Decimal(P, S)` or a `Json(T)`, or has parts. An integer value takes `at_least:`, `at_most:`, `within:` and `times:`. It is validated when it is built and by every arithmetic result. `+` and `-` take the same value or an integer, and `*` takes an integer. `times: Quantity` on `Cents` would let `*` take a quantity. `otherwise: "A balance cannot go below zero."` is the sentence a value outside its bounds is refused with, wherever it is built, in place of the generated one; it goes with `at_least:`, `at_most:`, `within:`, `matches:`, `length:` or `one_of:`, and a decimal’s shape refusals, a day, a document and a value with parts take none. A value is stored as a column of its raw type and rebuilt, and so validated again, when it is loaded.

PostgreSQL checks the bounds too. Every column that stores `Tins` gets a `CHECK` constraint, such as `check_catalogue_teas_stock`, so a write that goes around SweetTalk, through SQL or another service, is refused when it is written. Bounds are therefore integer literals. `database_check: false` keeps a value’s bounds in Crystal only, where they may name a constant.

| Condition | Outcome |
| --- | --- |
| A build or arithmetic result outside the bounds, such as `@stock -= tins` below zero | refuses with “Tins must be at least 0”, or the `otherwise:` sentence |
| `+` or `-` of tins and cents | fails compilation |
| `*` of `Cents` by a `Quantity` without `times: Quantity` | fails compilation |

**app/domain/treasury.cr · a decimal and two JSON values, after require "caramel/sweet_talk/decimal"**

```crystal
value Rate, Decimal(20, 8), at_least: "0", at_most: "1", means: "a yearly rate, 0 to 1"
value Evidence, Json(Snapshot), means: "the figures a rate was set from"
value Note, Json, means: "any document a lender attaches to a loan"
```

A `Decimal(P, S)` value is a `BigDecimal` kept exact in a `numeric(P,S)` column, P digits in all and S after the point, through `SugarORM::DecimalCodec` ([ADR 0047 ↗](https://github.com/caramelizedev/caramel/blob/main/docs/decisions/0047-sweettalk-decimal-and-json-values.md)). It is opt-in: `require "caramel/sweet_talk/decimal"` before the domain links GMP, and a program without that line never does. `Rate.new("0.05")` reads digits with at most one point, `Rate.new(BigDecimal)` and `Rate.new(Int)` wrap, and a value the column would round or overflow, such as a ninth decimal, refuses before any write. Its bounds are decimal text, `at_least: "0"`, kept as a `CHECK` whose name carries them, `check_credit_loans_rate_between_0_and_1`. `+` and `-` take the same value, `*` an integer, and `<=>` compares by value whatever scale was written, so `Rate.new("0.50") == Rate.new("0.5")`. `to_s` is the plain digits, never an exponent, and that text is the value in JSON, in an event, in a job and in a contract field, so no reader rounds it through a float. `where: {rate: low..high}`, `rate: low..` and `order: {rate: :asc}` work in `finds`, `counts` and `specification`, as a day’s do.

A `Json(Snapshot)` value wraps a `JSON::Serializable` type declared before it, and `Json` alone a `JSON::Any`; `evidence.raw` is the document. It is kept whole in a `jsonb` column through `SugarORM::JSONB`, takes no bound, pattern, length or list, and in JSON it is the document itself. `Evidence.new(snapshot)` and `Evidence.parse(text)` build it. A query asks only whether a document equals one, `where: {evidence: evidence}`, or is absent, `where: {evidence: nil}`; the parts inside it are not queried yet. In a projection or a process, a decimal or a JSON attribute takes no default, so it is optional, as a day is.

| Condition | Outcome |
| --- | --- |
| `Rate.new("1e-2")`, `Rate.new("0,5")` or other text that is not digits with a point | refuses with “Rate must be a decimal written with digits and a point, as in 12.50” |
| `Rate.new("0.123456789")` for a `Decimal(20, 8)` | refuses with “Rate keeps 8 decimals and 12 digits before the point, not 0.123456789” |
| `Rate.new("1.5")` past `at_most: "1"`, or an arithmetic result past it | refuses with “Rate must be at most 1” |
| A write around SweetTalk past the bound, to a `numeric` column | is refused by the CHECK |
| `Decimal(20, 8)` without `require "caramel/sweet_talk/decimal"` | fails compilation, naming the require |
| A bound that is not decimal text, such as `at_least: 0`, or one written past S decimals | fails compilation |
| A `Json` value with `at_least:` or any other option, or `order:` on it | fails compilation |
| `where: {evidence: low..high}` on a `Json` value | fails compilation, with Crystal’s own message |

## Name strings and values with parts {#c-sweettalk-richer-values}

**app/domain/tea_shop.cr · string and composite values**

```crystal
value Email, String, matches: /\A[^@\s]+@[^@\s]+\z/, length: 3..254,
  means: "an address we can write to"
value Postcode, String, matches: /\A[A-Z0-9][A-Z0-9 ]{1,8}[A-Z0-9]\z/,
  means: "a postal code, in capitals"

value Address, means: "where a parcel goes" do
  part street : String
  part city : String
  part postcode : Postcode
  never "An address needs a street and a city." { street.blank? || city.blank? }
end
```

A string value takes `matches:` and `length:`, and has no arithmetic. It is stored as a text column. Its pattern is checked in Crystal only, because PostgreSQL reads regular expressions differently.

| Condition | Outcome |
| --- | --- |
| `Email.new("ada")`, a string that does not match the pattern | refuses with “Email must match /\A[^@\s]+@[^@\s]+\z/” before anything is written |
| A write around SweetTalk with a length outside 3..254 | refuses, by the CHECK `check_ordering_orders_receipt_to_length_3_254` |

A value with parts is built with one keyword per part, as in `Address.new(street: "1 Leaf Lane", city: "Camellia", postcode: Postcode.new("CA1 1TE"))`. It checks its `never` and `always` when it is built, and equals another address with the same parts. A part is a column type or a value that wraps one. `has deliver_to : Address` stores one column per part: `deliver_to_street`, `deliver_to_city` and `deliver_to_postcode`. A part’s value brings its constraints to its column.

**app/domain/tea_shop.cr · a closed list**

```crystal
value Roast, String, one_of: %w[light medium dark],
  means: "how far a tea is roasted"
```

A string value that takes `one_of:` is one of a closed list of words, written once. A word starts with a letter and holds letters, digits and underscores, and the value takes neither `matches:` nor `length:`. Crystal checks it when the value is built, loaded or bound, and PostgreSQL checks it too: every column that stores `Roast` gets a `CHECK` named `check_<table>_<column>_one_of_<hash>`, `"roast" IN ('light', 'medium', 'dark')`. The eight hex digits change with the list, so `frappe db diff` replaces the constraint when you add or remove a word. `database_check: false` keeps the list in Crystal only. The words become methods: `Roast.all` lists the members in the order written, `Roast.includes?("dark")` asks about a text, `Roast.dark` builds one and `tea.roast.dark?` asks. `tea.roast.member` returns the word as a member of the enum `Roast::Member`, `Dark`, and `Roast.new(member)` builds the value back; the column keeps the word. A screen branches on it in [Show the domain on screens](#c-sweettalk-screens).

| Condition | Outcome |
| --- | --- |
| `Roast.new("burnt")`, a text outside the list | refuses with “Roast must be one of light, medium, dark” |
| A write around SweetTalk of a text outside the list | refuses, by the CHECK on the column |
| A `one_of:` that is not a literal list of words, lists a word twice, takes `matches:` or `length:`, or names a method the value or every object already has, such as `all`, `name` or `hash`, or a Crystal keyword | fails compilation |
| A `case … in` over `roast.member` that misses a member | fails compilation, naming the missing member |

Adding the `CHECK` to a table that already has rows is not free of risk: `frappe db diff` adds it `NOT VALID` and validates it in a later step, and a row whose text is outside the list stops `frappe migrate` there. Before migrating, find the rows with `SELECT id, "roast" FROM catalogue_teas WHERE "roast" IS NOT NULL AND "roast" NOT IN ('light', 'medium', 'dark')`.

**app/domain/tea_shop.cr · a calendar day**

```crystal
value Day, Date, means: "a calendar day"

aggregate Order, means: "what a member buys at one checkout" do
  has shipped_on : Day?
  event Shipped, carries: [shipped_on], means: "an order left, and on which day"
  finds shipped_in(from : Day, to : Day), where: {shipped_on: from..to},
    order: {shipped_on: :desc}

  to ship(on : Day) do
    shipped!
    @shipped_on = on
    emit Shipped
  end
end
```

A `Date` value is a real calendar day, from year 1 to 9999, kept in a `date` column. Its `raw` is a `SugarORM::Date`, and `has` stores it through `SugarORM::DateCodec`, so PostgreSQL orders it as a day and refuses one that does not exist. It takes no bound, pattern, length or list. A part of a value with parts may be a day, one `date` column for each. `Day.new("2026-02-30")` refuses. `Day.new(2026, 3, 1)` builds a day, `Day.of(time)` reads the calendar day the time shows in its own zone, with no conversion to UTC, and `day.year`, `day.month`, `day.day`, `day.to_s` (`YYYY-MM-DD`) and `day.to_time` (midnight UTC) read it. `day + 7` and `day - 7` move by days, `day - other` counts the days between two as an `Int32`, and days compare and sort. A result outside years 1 to 9999 refuses. A day in JSON is its `YYYY-MM-DD` text.

There is no `Day.today`. A word that reads the clock reads UTC, and near midnight that is another day in the user’s zone, so a command takes the day it means as an argument, as `ship(on : Day)` does, and the action passes it, for instance `Day.of(Time.local(user_zone))`.

In `finds`, `counts` and `specification`, `where: {shipped_on: from..to}` takes a closed range of days, and `...day` or `day..` a range with one end; PostgreSQL reads each as dates, and `order: {shipped_on: :desc}` sorts by day. An event or a job carries a day as `"2026-03-01"`, and a projection may be keyed by one.

A table that holds the day as text, such as a former string value, is retyped by `frappe db diff`: its migration locks the table, checks every value first, and stops with a count and up to five of the values that are not a day.

| Condition | Outcome |
| --- | --- |
| `Day.new("2026-02-30")`, or a text that is not `YYYY-MM-DD` | refuses with “Day must be a calendar day written YYYY-MM-DD, as in 2026-02-28” |
| `day + 1` from `9999-12-31` | refuses with the same message |
| A write around SweetTalk of a text that is not a day, to a `date` column | is refused by PostgreSQL |
| `Day.today`, or a day added to a day | fails compilation |
| A `Date` value with `at_least:`, `matches:`, `one_of:`, `database_check:` or another option | fails compilation |

## Count money in its currency {#c-sweettalk-money}

An amount whose currency is data is a count of minor units and a currency code. `require "caramel/sweet_talk/money"` before the domain adds the words that keep the two together. It requires `caramel/sweet_talk/decimal`, and a program without the line holds none of its code ([ADR 0063 ↗](https://github.com/caramelizedev/caramel/blob/main/docs/decisions/0063-sweettalk-money.md)).

**app/domain/books.cr · after require "caramel/sweet_talk"**

```crystal
require "caramel/sweet_talk/money"

kernel Money, shared_by: [Ledger, Treasury], means: "how the books count money" do
  currencies %w[USD EUR UZS JPY XAU], exponent: {XAU: 4}, means: "a currency the books hold"
  quote Rate, rounding: :half_up, means: "one dated rate from a named source"
end

context Ledger, shares: Money, means: "the journal of what was paid and received" do
  aggregate Entry, means: "one payment, in the currency it was made in" do
    has original : Money::Amount
    has reported : Money::Amount?
    has rate : Money::Rate?

    to report(rate : Money::Rate) do
      @reported = original.convert(rate)
      @rate = rate
    end
  end
end
```

`currencies` lists the ISO 4217 codes a context or a kernel holds, once. It declares `Currency`, a closed set as `one_of:` declares one: `Currency.all`, `Currency.usd`, `currency.usd?` and a CHECK on every column that stores it. A code whose methods would hide ones every object has, such as ALL and TRY, gets none, and `Currency.new("TRY")` builds it. Each code’s minor units come from ISO 4217 list one, published 2026-09-17: 2 for USD, 0 for JPY, 3 for BHD. A code outside the list, or one it marks N.A., such as XAU, takes `exponent:`, 0 to 9.

`Money::Minor(Money::Currency::USD)` is a signed count of cents. `+`, `-` and `<=>` take the same currency, `*` takes an integer, and no integer is added to it. `Money::Amount` is any listed currency’s `Minor`, the type of an amount whose currency is data. Crystal will not add two of them: `Money.same(a, b) { |x, y| x + y }` runs the block on two amounts of one currency and refuses two currencies, and `Money.by_currency(amounts)` totals each currency. `Money::Amounts.new(currency:, raw:)` builds the amount a currency names.

Text is read in the currency’s units. `Minor(USD).parse("12.30")` and `Money::Amounts.parse("12.30", currency)` refuse a third decimal, and `round(text, rounding: :half_even)` rounds on purpose, for an import. `amount.text` is `12.30` and `amount.to_s` is `12.30 USD`.

`has original : Money::Amount` stores two columns: `original_currency`, under the currencies’ CHECK, and `original`, a `bigint`. An optional amount stores both or neither, under a second CHECK. `has fee : Money::Minor(Money::Currency::USD)` stores its currency too, and loading another refuses. An event carries an amount as `{"currency": "USD", "raw": 1230}`, and `finds` and `specification` compare both columns. `sums` of an amount whose currency is data returns `Hash(Currency, Amount)`, one total per currency in code order, in one statement; a `Minor(USD)` adds up as a number, and `groups` with `by:` an amount groups by its currency. A `groups` that adds up an `Amount` does not compile.

`quote Rate, rounding: :half_up` declares a rate between two of the currencies: an exact fraction, kept in lowest terms in two `bigint` columns, the day it was quoted for, a `RateDay`, and its source. `Rate.parse("1.0851", from:, to:, day:, source:)` reads it exactly. `amount.convert(rate)` gives the amount in `to`, rounded as the quote declares: `:half_up`, `:half_even`, `:down` or `:up`. `rate.inverse` and `rate.through(other)` are exact cross rates, and `through` joins rates of one day. Which rate applies on a day, a fallback and an override stay in the application.

`allocation split, of: Money::Amount, by: Weight, remainder: :largest_fraction, means: "…"` declares a [calculation](#c-sweettalk-calculations), `Ledger.split(total, weights)`, whose weights are a `Hash` keyed by `Int64`, or by the type `per:` names. Each key gets its share of the total in proportion to its weight, exactly, rounded down to whole minor units. `remainder:` says where the units left go: one each to the largest fractions, ties to the smaller key, with `:largest_fraction`; all to the first or the last key with a weight above zero, in key order, with `:first` or `:last`; all to a key passed as a third argument with `:to`. A weight is a whole number or a `Decimal(P, S)` value, and a negative total gives negative parts. Its rules on `result` say the parts add up to the total, in its currency; each part is the floor or the ceiling of its share, or its floor but the one the remainder goes to; and a key of weight zero gets nothing. A block adds rules of its own, and `Corretto.property(Ledger.split)` runs them all on 200 drawn cases.

| Condition | Outcome |
| --- | --- |
| `Minor(USD) + Minor(EUR)`, or two `Money::Amount`s added | fails compilation |
| `Money.same` of amounts in two currencies | refuses with “An amount in EUR and one in USD cannot be combined” |
| `Minor(USD).parse("12.345")` | refuses with “USD keeps 2 decimals, not 12.345” |
| `amount.convert(rate)` of an amount in another currency than the rate’s `from` | refuses with “This Rate converts EUR, not USD” |
| A rate from a currency to itself, or of zero | refuses with “A Rate converts between two currencies at a fraction above zero” |
| A write around SweetTalk of a code outside the list | is refused by the CHECK |
| `Ledger.split` of 100.00 USD by three equal weights | gives 33.34, 33.33 and 33.33, the cent to the smallest key |
| A weight below zero, or weights that add up to zero | refuses with “An allocation takes no weight below zero” or “An allocation needs a weight above zero” |
| `remainder: :to` given a key without a weight above zero | refuses with “The remainder of an allocation goes to a key with a weight above zero, not 4” |
| `Float64`, `to_f` or a float literal in an allocation’s types or block | fails compilation at that line |
| A money word without `require "caramel/sweet_talk/money"` | fails compilation, naming the require |

## Declare aggregates and entities {#c-sweettalk-aggregates}

An aggregate is a root with an id, such as `Order::Id`, and a repository: `find`, `find?`, `all`, and `create` unless it has a factory. An entity lives inside one aggregate and is saved with it, and has an id of its own, `Order::Line::Id`. In a domain keyed by UUID, the default, an aggregate and an entity get their id when they are built, so `id`, `==` and `hash` work before `create`, and entities come back in the order they were built. `ids Int64`, before the first context, keys the domain by an Int64 the database assigns: `line.id` then reads once the aggregate is saved and raises before. A domain with a tenant takes its tenant’s key type, and `ids` that differ from it fail compilation. Given to another aggregate’s `create` or factory, it is stored again as that aggregate’s own row, and the first aggregate keeps its own. An aggregate and an entity read `created_at` and `updated_at` from their rows: nil until the first save, refreshed by every save, and `updated_at` stays as it is when a save changes no column.

**app/domain/tea_shop.cr · an aggregate**

```crystal
aggregate Order, means: "what a member buys at one checkout" do
  has member : Account
  has receipt_to : Email
  has deliver_to : Address
  has lines : Array(Line)
  has late_parcel : Bool = false
  moves open >> placed >> shipped, open >> cancelled, placed >> cancelled
  never "An order needs at least one tea." { placed? && lines.empty? }

  entity Line, means: "one tea in an order, its price when added, and how many tins" do
    has tea : Catalogue::Tea
    has price : Catalogue::Cents
    has quantity : Quantity
    the cost : Catalogue::Cents = price * quantity.to_i
  end

  the total : Catalogue::Cents = lines.sum(&.cost)

  event Placed, lines : Array(Line), deliver_to : Address, means: "a member checked out"
  # …

  to add(tea : Catalogue::Tea, quantity : Quantity) do
    refuse "Teas can be added only while the order is open." unless open?
    refuse "#{tea.name} is already in this order." if lines.any? { |line| line.tea == tea.id }
    @lines << Line.new(tea, tea.price, quantity)
  end

  to place do
    placed!
    emit Placed, lines: lines, deliver_to: deliver_to
  end
end
```

Each aggregate, entity, projection and process is a SugarORM schema with its own changeset, and every write goes through that changeset. `has` chooses the storage from the type:

| `has` type | Stored as |
| --- | --- |
| `String`, `Int32`, `Int64`, `UUID`, `Bool`, `Float64` or `Time` | A column |
| A value that wraps a number or a string | A column of its raw type |
| A value that wraps a `Date`, such as `Day` | A `date` column, through `SugarORM::DateCodec` |
| A value that wraps a `Decimal(P, S)`, such as `Rate` | A `numeric(P,S)` column, through `SugarORM::DecimalCodec(P, S)`, with its bounds as a `CHECK` |
| A value that wraps a `Json(T)` or `Json`, such as `Evidence` | A `jsonb` column, through `SugarORM::JSONB(T)` |
| A value with parts | One column per part |
| Another aggregate | A foreign key; its getter returns that aggregate’s id: `line.tea` is a `Catalogue::Tea::Id`. Load the tea with `Catalogue::Tea.find` when you need it. |
| One of the application’s own SugarORM schemas, as in `has member : Account` | A foreign key; its getter returns a `SweetTalk::RecordId(Account)`, and `order.member.load` reads the account |
| An `Array` of the aggregate’s own entity, or of an entity’s own | A child table keyed by the parent’s row, `ordering_order_lines` for `Order::Line` and `ordering_order_line_remarks` for an entity inside it, at any depth; loaded, saved, dropped, checked and carried in events with its parent |
| `Bool`, not optional | A column; `has late_parcel : Bool` reads as `late_parcel` and `late_parcel?`, so no `moves` state or specification may share its name |

`has name : Type = expression` gives an attribute a default, as in `has held : Tins = Tins.zero`. The column gets a SQL default when the expression is a literal, as in `has late_parcel : Bool = false`, or a value built from one: `Cents.new(0)`, `Tins.zero` or a closed-set member such as `Roast.medium`. Such a value default is built when the program loads, so one outside the value’s bound stops it at start. An entity is built by name, `Line.new(tea: tea, quantity: quantity)`, which leaves out a defaulted attribute wherever it is declared; the positional `Line.new(tea, tea.price, quantity)` gives a default only to the trailing ones.

| Condition | Outcome |
| --- | --- |
| A `has` with any other type | fails compilation |
| A `has` of a `Hash` or an `Array` of scalars | fails compilation, with a pointer to the entity form; a list that is one document belongs in a `Json(T)` value |
| An attribute named like the tenant’s or the parent’s column or association | fails compilation |
| A context that names `Rows` | fails compilation |

A type followed by `?` makes the attribute optional: its column is nullable, its getter returns nil while it is not set, and it starts as nil unless it has a default, so `create` and a factory need not set it, wherever it is declared. It works for every type `has` takes, in an aggregate, an entity, a projection and a process, except a `key`. An aggregate may refer to its own type, as in `has reversal_of : Entry?` inside `Entry`: a nullable foreign key to its own table.

**app/domain/tea_shop.cr · optional attributes**

```crystal
has gift_to : Address?
has courier : Courier?
has packer : Account?

to wrap_as_gift(gift_to : Address?) do
  @gift_to = gift_to
end

to pack_with(packer : Account?) do
  self.packer = packer
end
```

| Optional type | Stored as |
| --- | --- |
| A column type, such as `String?` | A nullable column |
| A value, such as `Courier?` | A nullable column of its raw type; the getter returns the value or nil |
| A value with parts, such as `Address?` | One nullable column per part, and a `CHECK` that every part is set or none is; the getter returns the value or nil |
| An aggregate, such as `Account?` | A nullable foreign key; the getter returns its id or nil |
| One of the application’s own schemas | A nullable foreign key; the getter returns a `SweetTalk::RecordId(Account)` or nil |

A command sets a reference with its writer, `self.packer = packer`, which takes the aggregate, the record or its id, and nil when the attribute is optional. `@packer = packer` would declare a new instance variable and change nothing, because the reference is stored in `@packer_id`, so a command, factory, process step, compensation or deadline that writes it, with `=`, `||=` or a multiple assignment, does not compile. A projection’s `whenever` handler assigns the row it holds, as in `row.last_order = placed.order_id`; its key has no writer. `where: {packer: nil}` and `where: {gift_to: nil}`, in `finds`, `counts` and `specification`, ask for the orders where it is not set, in Crystal and in PostgreSQL alike. nil is accepted only for an optional attribute: for a required one the query does not compile, naming it. `order: {courier: :desc}` on an optional column puts the rows with no value first, as PostgreSQL does, and `:asc` last.

Use `?` for what the thing may lack. A column that is present only for some kinds of the thing is another concept: group it in a value with parts, which is set whole or not at all, give the aggregate a state that holds it, or tie it to the members of a closed-set value with `parts:`, below. A rule that ties the presence of one attribute to another, such as “a refund has a reason”, stays a `never`.

When an attribute is present only for some members of a closed-set value, say so with `parts:` on the value’s attribute. Each key is a member and lists the optional attributes it holds, declared above; a member the list omits holds none of them, and every attribute that some member lists is unset for a member that does not list it.

**app/domain/counter.cr · kinds with parts**

```crystal
aggregate Settlement, means: "money settled for one kind of transfer" do
  has payee : Owner?
  has leg : Money?
  has kind : Kind, parts: {payment: [payee], net_settlement: [payee, leg]}
end

settlement.as_payment # => {payee: Owner::Id}
```

| Condition | Outcome |
| --- | --- |
| A `create` or command that leaves a member without a part it holds, or with one it lacks | refuses with “Settlement kind payment holds payee and no leg”, or “Settlement kind receipt holds no payee or leg” |
| A write around SweetTalk that does the same | refuses, by one CHECK per member of the value, `check_<table>_<attribute>_<member>_<hash>`, omitted members included |
| `as_payment` | returns the member’s parts as a named tuple, each without its `?` |
| `as_payment` on a settlement of another kind | raises `TypeCastError` |

The checks are new constraints on tables that may already hold rows. `frappe db diff` adds each `NOT VALID` and validates it later, and a row that breaks one stops `frappe migrate` at that step. Find those rows first: `SELECT id FROM counter_settlements WHERE NOT ("kind" <> 'receipt' OR (num_nonnulls("payee_id", "leg_currency", "leg_cents") = 0))`.

The checks are new constraints on tables that may already hold rows, so they are not free of risk. `frappe db diff` adds a `CHECK` and a new foreign key `NOT VALID`, then validates them, and a row that breaks one stops `frappe migrate` at that step. Find those rows first: for an optional value with parts, `SELECT id FROM ordering_orders WHERE num_nonnulls("gift_to_street", "gift_to_city", "gift_to_postcode") NOT IN (0, 3)`; for a foreign key added to a column that held ids, `SELECT o.id FROM ordering_orders o LEFT JOIN accounts a ON a.id = o.packer_id WHERE o.packer_id IS NOT NULL AND a.id IS NULL`.

| Condition | Outcome |
| --- | --- |
| A write around SweetTalk that sets some columns of an optional value with parts and not the others | refuses, by the CHECK `check_<table>_<attribute>_all_or_none_<hash>`; loading such a row refuses too. The hash is of the value’s part names, so adding a part replaces the constraint |
| An optional value set outside its own bound, list or length | refuses, in Crystal and by the CHECK on its column; a null passes the CHECK |
| A `key` that is optional | fails compilation |
| `@packer = packer`, `@packer \|\|= packer` or `@packer, @x = …` in a command, factory, process step, compensation or deadline, for a reference | fails compilation, naming `self.packer =` |
| `row.tea = other` on a projection’s key | fails compilation: the key has no writer |
| `where: {note: nil}` for an attribute that is not optional | fails compilation, naming the attribute |

A rule the database must keep, whoever writes the row, is declared on the attribute or over the aggregate (ADR 0045). `has label : String, unique: true` is a unique index, refused with “Crate label must be unique”; `unique: "A crate with this code already exists."` gives the sentence. `index: true` is a plain index for the reads that look rows up by that attribute. `check: {"quantity >= 0", "A crate cannot hold less than nothing."}` is a `CHECK` written against the stored columns, with the sentence a row that breaks it is refused with. Over several attributes, `unique :source_key, :bundle, otherwise: "…"`, `index :owner, :state` and `check :pending_is_zero, "…", otherwise: "…"` name attributes declared above them, and `state` once `moves` is; a reference stands for its `_id` column and a value with parts for its part columns. An entity’s `unique` is unique within its aggregate: its index leads with the aggregate’s column. A violation is a `Refusal` with the sentence, so a command rolls back and reloads as any refusal does, and an action answers 422. In a tenanted context the tenant column joins every unique index, so two tenants may hold the same value.

**app/domain/pantry.cr · database constraints**

```crystal
aggregate Crate, means: "a crate with a label and a code of its own" do
  has label : String, unique: true
  has code : String, unique: "A crate with this code already exists."
  has owner : Account, index: true
  has quantity : Int32, check: {"quantity >= 0", "A crate cannot hold less than nothing."}
end

aggregate Adjustment, means: "one correction to one bundle of a source" do
  has source_key : String
  has bundle : String
  has debit : Int32 = 0
  has credit : Int32 = 0
  moves pending >> posted

  unique :source_key, :bundle, otherwise: "That bundle already has an adjustment."
  index :bundle, :state
  check :pending_is_zero, "state <> 'pending' OR (debit = 0 AND credit = 0)",
    otherwise: "A pending line carries no amounts."
end
```

| Condition | Outcome |
| --- | --- |
| A `create`, factory or command that writes a duplicate of a `unique` value | refuses with the declared sentence, or “Crate label must be unique”; the first row stands |
| A command that leaves a row breaking a `check` | refuses with its sentence, rolls back and reloads the aggregate |
| An entity replaced by one with the same unique value in one command | saves: the dropped rows are deleted before the new ones are written |
| Two entities that swap their unique values in one command | refuses: the index is not deferrable; drop one, save, then add the other |
| A violation of an index or check SweetTalk did not declare, such as one from a hand-written migration | raises `SugarORM::UniqueViolation` or `CheckViolation`, as before |
| A new `unique` or `index` on a table that has rows | is built `CONCURRENTLY` by `frappe db diff`, in a migration of its own; a new `check` is added `NOT VALID`, then validated |

Before migrating a `unique` onto rows, find the duplicates: `SELECT label, count(*) FROM pantry_crates GROUP BY label HAVING count(*) > 1`. A duplicate fails the `CREATE INDEX CONCURRENTLY` and leaves an INVALID index, which halts the next `frappe db diff` until `DROP INDEX CONCURRENTLY` removes it; a new `check` stops `frappe migrate` on the rows that break it, as above. A removed aggregate keeps its row, so its unique values stay taken.

The schemas live in each context’s `Rows` module, so every change goes through a command. Table names take English plurals. The tea shop’s tables are `catalogue_teas`, `ordering_orders`, `ordering_order_lines`, `ordering_sales`, `ordering_holds`, `fulfilment_parcels` and `fulfilment_parcel_packings`. They are ordinary schemas, so `frappe db diff` derives their migrations.

## Guard the lifecycle and the invariants {#c-sweettalk-lifecycle}

`moves` lists one or more chains of states, and the first state is the initial one. `moves open >> placed >> shipped, open >> cancelled, placed >> cancelled` stores the state and adds `open?`, `placed?`, `shipped?` and `cancelled?`, and the private movers `placed!`, `shipped!` and `cancelled!`. `Order.moves_from(state)` reads the graph: from `open` it returns `placed` and `cancelled`, in the order `moves` first names them. `order.may_become?(state)` asks whether the mover of that state may run now. `the` is a derived value, computed on every read and never stored. An entity declares its own `never` and `always`, and a command checks the aggregate’s, then every entity’s in each of its lists.

| Condition | Outcome |
| --- | --- |
| A mover such as `shipped!` is called when the current state does not come just before it in a chain | refuses with “Order cannot become shipped while cancelled” |
| A command leaves a `never` condition true | refuses |
| A command leaves an `always` condition false | refuses |
| A command leaves an entity’s `never` true or its `always` false | refuses |
| A `case … in` over the states that misses one | fails compilation, naming the missing state |

PostgreSQL holds the lifecycle too. The `state` column stores each state as `moves` spells it, such as `out_for_delivery`, and a `CHECK` constraint such as `check_ordering_orders_state_ef9524ce` refuses any other text, so a write around SweetTalk cannot leave a row no state names. The eight hex digits change with the list of states, so `frappe db diff` replaces the constraint when you add or remove one, and `frappe migrate` stops, naming the constraint, while a row still holds a state you removed.

A document that must say what a rule was when it applied needs a copy, not a reference. `has rules : Setup::Rules, pinned_at: :finalized` keeps both: the reference, and a read-only copy of the aggregate taken in the same transaction as the move that enters `finalized`. `pinned_rules` reads the copy, and is nil before that move.

**app/domain/books.cr · a journal that pins its rules**

```crystal
aggregate Journal, means: "one journal, sealed under the rules it was opened with" do
  has amount : Int64
  has rules : Setup::Rules, pinned_at: :finalized
  moves draft >> finalized

  to seal do
    finalized!
  end
end
```

| Condition | Outcome |
| --- | --- |
| The mover that enters the pinned state | stores the referenced aggregate as JSON in `<name>_pinned`: its id, its state and every attribute, entity lists included |
| A later change to the referenced aggregate | leaves the copy as it was |
| A command on the copy | raises `SweetTalk::Boundary`, “find Rules 7 to change it” |
| An attribute the aggregate gained after the copy was taken | reads nil when optional and its default when it has one; otherwise raises `ArgumentError` |
| A state that is not in `moves`, or is the first state | fails compilation, naming the states `moves` lists |

## Change state with commands {#c-sweettalk-commands}

`to verb(arg : Type) do … end` is a command, and it runs as one transaction:

1. load the aggregate with its row locked through SugarORM’s `lock`, so commands on one aggregate run one after another and the body sees the last committed state;
2. run the body;
3. check every `never` and `always`;
4. delete the entity rows the body dropped, in one statement per list and none when it dropped none, then save the root through its changeset, then its entities, each only when a column changes;
5. dispatch the queued events, each entity among their facts written now, with its id.

| Condition | Outcome |
| --- | --- |
| `refuse "message"` | raises `SweetTalk::Refusal`; the transaction rolls back and the aggregate reloads what is stored, so neither the table nor the object keeps half a change |
| `refuse "message", on: :tins`, or `on: :tins` on a `never` or an `always` | raises the refusal with `refusal.on` set to `"tins"`, the field an action answers it under |
| Another aggregate’s command, a `create` or a factory runs while a command runs | raises `SweetTalk::Boundary` and rolls the command back |

`create` and a factory check the invariants before they insert. A `create` then announces `Created` in the same transaction: an event of that aggregate that carries every attribute, on `sweettalk.<context>.<aggregate>.created`, so a `whenever` follows it and an event log keeps it. To carry some attributes only, declare `event Created, carries: [member, total], means: "…"`; a declared `Created` that lists fields of its own fails compilation, and so does a channel past PostgreSQL’s 63 characters (42 under an Int64 tenant, 36 under a UUID tenant). An aggregate with a factory has neither `create` nor this `Created`. Each command, factory, service and unit is a `domain` span in its trace, named like `Ordering::Order#place`; a refused one is marked failed.

A command changes one aggregate. A command may read another aggregate it is given: `add` copies the tea’s price into the line, so repricing the tea later does not change the order. Two commands called in turn inside one `SugarORM::Repo.transaction`, each a savepoint, commit together and roll back together; that is the supported way to change two aggregates atomically, and `scripts/check sweet-talk` proves it. A [unit](#c-sweettalk-units) names that seam: it lists the aggregates it changes, locks their rows first in one order and checks a rule over the set. A command named `finalize` fails compilation, because it would replace the garbage collector’s.

## Make aggregates with factories {#c-sweettalk-factories}

`factory verb(args) do … end` makes an aggregate. Arguments named like attributes set them, and the body runs as the aggregate’s first change and may `emit`. The aggregate is checked, saved and its events dispatched in one transaction, and each event names the new aggregate’s id. Declaring a factory removes the aggregate’s `create`, so every `create` call stops compiling: replace each one with the factory in the same change.

**app/domain/tea_shop.cr · a factory**

```crystal
factory open(member : Account, receipt_to : Email, deliver_to : Address) do
  emit Opened, receipt_to: receipt_to
end
```

`Ordering::Order.open(account, Email.new("ada@example.com"), address)` opens an order.

| Condition | Outcome |
| --- | --- |
| A factory leaves an attribute unset and no default covers it | fails compilation |
| A factory named like a repository method, such as `factory find` | fails compilation |
| An aggregate with a factory | has no `create` and no generated `Created`, so every order starts with `Opened` |

Stage 4 · Query and decide

## Find, count and retire aggregates {#c-sweettalk-queries}

**app/domain/tea_shop.cr · queries and a removal**

```crystal
finds placed_for(member : Account), where: {member: member, state: :placed}
finds newest_for(member : Account, count : Int32), where: {member: member},
  order: {id: :desc}, first: count
counts placed_count_for(member : Account), where: {member: member, state: :placed}
sums spent_by(member : Account), of: Line.price, where: {member: member, state: :placed}
groups priced_by_tea(member : Account), of: Line.price, by: Line.tea,
  where: {member: member, state: :placed}
sums spent_on(member : Account, teas : Array(Catalogue::Tea::Id)), of: Line.price,
  where: {member: member, state: :placed, lines: {tea: teas}}
groups priced_by_order(member : Account), of: Line.price, by: :id,
  where: {member: member, state: :placed}

to forget do
  refuse "Only a cancelled order can be forgotten." unless cancelled?
  remove
end
```

The aggregate is its own repository: `find`, `find?`, `all`, `create` or its factory, and the queries it declares. `finds` defines a query that returns aggregates.

| Option | Meaning |
| --- | --- |
| `where:` | Keeps the aggregates whose columns equal the expressions: a list matches any of its members and a range its span, and a range of days, `shipped_on: from..to`, is read by PostgreSQL as dates. |
| `state:` | Takes a state or a list of states. |
| `satisfying:` | Adds a specification. |
| `order:` | `order: {id: :desc}` sorts by `id` or by attributes stored in one column, and id breaks ties. |
| `first:` | Returns at most that many. |
| `counts` | Takes `where:` and `satisfying:` and returns how many, in one statement, without loading them. |
| `sums` | Takes `of:`, an attribute of the aggregate by symbol or of one of its entities as `Line.price`, with `where:` and `satisfying:`, and returns its sum in one statement as the attribute’s type: an `Int32`, `Int64` or `Float64`, or a value that wraps a whole number or a decimal, takes 0 and has no upper bound; zero when nothing matches. When `of:` names an entity’s attribute, `where: {state: :placed, lines: {tea: teas}}` adds conditions on each line it adds up, under the name of their list. An amount adds up per currency ([Count money in its currency](#c-sweettalk-money)). The tenant and removed aggregates stay excluded. |
| `groups` | `sums` once per value of `by:`, an attribute of the same model as `of:` stored in one column (text, a whole number, a UUID, a Bool, a day, a decimal, an aggregate it refers to, an amount, by its currency), `:state`, or `:id`, one row per aggregate, when `of:` names an entity’s attribute, as `{by: key, total: sum}` rows ordered by the stored key, nil last. |

Each part is optional, but a `finds` gives at least one.

Every query is checked once the program is read, whether or not anything calls it.

When a query needs more than that, give `finds` a block instead. It gets the aggregate’s live rows, with removed ones and other tenants’ already left out, and narrows them with SugarORM’s `where`, `where_null`, `order_by`, `limit` and `offset`; the aggregates are built from what it returns, so a caller cannot tell the two kinds apart. It is the one place a column name or a SQL fragment appears in a domain, so keep it for what `where:` cannot say. `sums` and `groups` add up one attribute in one statement; a projection keyed by what the sum groups by stays the choice when the same sum is read on every request. [Sum and group a context’s rows →](https://caramelize.dev/cookbook/0.23.0/sums-and-groups/index.md)

**app/domain/tea_shop.cr · a query with a block**

```crystal
finds holding(tea : Catalogue::Tea::Id) do |orders|
  orders.where("id IN (SELECT order_id FROM ordering_order_lines WHERE tea_id = ?)", tea.raw)
end
```

`find`, `find?`, `all` and every `finds` read one statement per table: the roots, then each list of entities, then each list inside those at every depth. So `placed_for` runs two queries however many orders it returns, and one more per nested list. `Order.find(id, entities: false)`, and `find?` likewise, reads the root alone in one statement, for a request that reads one order in several places and changes it in one: `order.lines` on it raises `SweetTalk::Unloaded`, and a command on it loads the lines under its lock as every command does. Entities come back by id, which is insertion order; an in-memory reorder is not persisted: store a position attribute for an order the domain owns. Code outside the domain, such as an action, reads through these queries too, and does not name `Rows`.

`remove` in a command retires the aggregate. Its row stays with `removed_at` set, so the lines and projection rows that name it stay valid. `find`, `find?`, `all`, every query and the command’s row lock skip it.

| Condition | Outcome |
| --- | --- |
| A query names a key, state or order the aggregate lacks | fails compilation |
| A `finds` or `counts` filters on a list of entities, or a `sums` or `groups` filters one whose attribute it does not add up | fails compilation |
| A query passes a value of the wrong type | fails compilation |
| A query passes an argument `finds` does not take | fails compilation |
| A `finds` block does more than narrow its rows: it counts, locks, deletes or names `Rows` or SugarORM | fails compilation |
| `find` of a removed or missing aggregate | raises “There is no Order 7.” |
| `order.lines` on an order found with `entities: false` | raises `SweetTalk::Unloaded`, “Order 7 was found without its lines: find it with entities”; an action answers it 500 |

## Name rules with specifications {#c-sweettalk-specifications}

A specification is a rule an aggregate satisfies or not, stated once and read twice: by Crystal on an aggregate in memory, and by PostgreSQL in a query. It lives in the context, after its aggregate, and joins the glossary.

**app/domain/tea_shop.cr · a specification**

```crystal
specification Astray, on: Order, where: {state: :cancelled, late_parcel: true},
  means: "a cancelled order whose parcel left anyway"

to forget do
  refuse "Only a cancelled order can be forgotten." unless cancelled?
  refuse "An order whose parcel left cannot be forgotten." if astray?
  remove
end
```

`Astray` is read in four ways:

| Call | Reads the rule |
| --- | --- |
| `order.astray?` | In Crystal, for `never`, `always`, guards and methods |
| `Ordering::Astray.satisfied_by?(order)` | In Crystal, on an aggregate in memory |
| `Order.all(satisfying: Astray)` | The same rule in one query |
| `satisfying: Astray` on a `finds` or a `counts` | The same rule in one query |

`where:` takes what `finds` takes, or earlier specifications on the same aggregate joined by `&`, `|` and `!`, as in `where: !Astray`. In PostgreSQL `!` reads as `IS NOT TRUE`, so an order whose column is NULL fails a rule and passes its negation in Crystal and in PostgreSQL alike.

A rule PostgreSQL cannot read stays a `never`, an `always` or a method: one over a list of entities, such as `lines.empty?`, or over a derived value made with `the`. A specification takes no arguments; a `finds` takes them, and adds a specification with `satisfying:`.

## Name operations with services {#c-sweettalk-services}

A service is an operation that belongs to no one aggregate. It lives in a context, carries `means:` and joins the glossary.

**app/domain/tea_shop.cr · a service**

```crystal
service requote(order : Order::Id), returns: Catalogue::Cents,
  means: "what an order would cost at today's prices" do
  Order.find(order).lines.sum do |line|
    Catalogue::Tea.find(line.tea).price * line.quantity.to_i
  end
end
```

Call it on its context: `Ordering.requote(order.id)`. A service changes at most one aggregate, by as many commands as it needs; a `create` or a factory counts as the first. To change two aggregates, emit an event and react to it in a `whenever`: a command’s event from the first, or the context’s own, declared beside the service and emitted from its body.

**Inside a context · its own event, emitted by a service**

```crystal
event Renamed, name : String, means: "the shop was given a new name"

service rename(name : String), means: "gives the shop a new name" do
  emit Renamed, name: name
end
```

| Condition | Outcome |
| --- | --- |
| A service runs two commands on one aggregate | allowed |
| A service changes a second aggregate | raises `SweetTalk::Boundary` and rolls both back |
| A `service` anywhere but a context | fails compilation |
| `returns:` omitted | defaults to `Nil` |
| `emit` of the context’s event in a service body | dispatches it when the service’s transaction commits, on `sweettalk.CONTEXT.EVENT` |
| `emit` in a context anywhere but a service body, or of an aggregate’s event | fails compilation |
| A context event with `carries:` | fails compilation |

## Change aggregates together with units {#c-sweettalk-units}

A unit is one transaction that changes the aggregates it names, their rows locked first. It lives in a context, carries `means:` and joins the glossary with kind `unit`. `changes:` lists the aggregates its commands may change, declared before it. `locks:` names the arguments whose rows it locks before the body runs: ids, aggregates, or arrays of either. A `never` or `always` line in its body is a rule over the set, checked after the body.

**app/domain/shelf.cr · a unit**

```crystal
unit fill_both(first : Box, second : Box, by : Int32),
  changes: [Box], locks: [first, second],
  means: "fills two boxes by one count in one transaction" do
  first.fill Count.new(by)
  second.fill Count.new(by)
  never "A box holds at most nine things." { first.count.raw > 9 || second.count.raw > 9 }
end
```

Call it on its context: `Shelf.fill_both(first, second, 2)`. It runs as one `SugarORM::Repo.transaction`:

1. `SweetTalk.lock` takes the locks, one statement per table with the tables in name order and the ids in order within each, `WHERE removed_at IS NULL AND id = ANY($1) ORDER BY id FOR UPDATE`, through the aggregate’s own rows, so the tenant predicate applies;
2. run the body: each command is a savepoint that loads its aggregate under the lock already held and dispatches its events as it does alone;
3. check the unit’s `never` and `always` lines;
4. commit.

Two units on the same rows wait on each other instead of deadlocking, whatever order their arguments come in. A refusal, a boundary or any other error rolls the whole unit back, every aggregate instance its commands touched reloads what is stored, and the error goes on. `SweetTalk.lock(*ids)` is the same ordered lock for a `SugarORM::Repo.transaction` of your own; a row locked twice is held once, and a call after a unit’s own is ordered within its own batch only.

Call a unit from an action, plain code, a service, a policy, a compensation, a deadline or a process step; inside a service or a handler it is that handling’s one change. An application that wrapped the seam itself, with hold commands that locked each aggregate before the real ones, moves those aggregates into `locks:` and drops the hold commands.

A client that retries a request must not run it twice. `once_by:` names the argument that names the operation, a `String` or a value that wraps one, and the unit runs once per key. The first run keeps the key, a fingerprint of the other arguments and what it returned in the context’s `<context>_operations` table, in the unit’s own transaction, so the claim and the change commit together.

**app/domain/ledger.cr · a unit that runs once**

```crystal
unit post(key : String, journal : Journal::Id, cents : Int64),
  changes: [Journal], locks: [journal], once_by: key, returns: Int64,
  otherwise: "That transfer was already recorded differently.",
  means: "posts one transfer once per request key and answers the new balance" do
  Journal.find(journal).post Cents.new(cents)
  Journal.find(journal).balance.raw
end
```

| Condition | Outcome |
| --- | --- |
| A repeat of the key with the same other arguments | answers the first run’s result without running; the locks, the body and the rules are skipped |
| A repeat of the key with other arguments | refuses with the `otherwise:` sentence, or “Ledger.post already ran under this key with other arguments” |
| A unit that raises, or a rule that refuses | rolls the claim back with the rest, so a retry runs again |
| Two requests with one key at the same moment | run once: the second waits for the first to commit, then answers its result |
| A tenanted context | keeps a key per tenant: two tenants may send one key |
| `once_by:` naming no argument or one that is not text, an aggregate in another argument or in `returns:`, or `otherwise:` without `once_by:` or not text | fails compilation |
| The operations rows | stay forever: nothing prunes them |

| Condition | Outcome |
| --- | --- |
| A command or `create` on a type outside `changes:` | raises `SweetTalk::Boundary`, naming the unit and its list, and rolls the unit back |
| A command on an existing row of an allowed type that `locks:` did not take | raises `SweetTalk::Boundary`, “lock it in locks:”, and rolls the unit back |
| A command on a row the unit created | allowed without a lock |
| A locked id with no live row | raises `SweetTalk::Missing` before the body runs |
| A `never` or `always` of the unit left true or false after the body | refuses and rolls the unit back |
| A unit inside a command, a factory or another unit | raises `SweetTalk::Boundary` |
| A unit inside a service or a handler that has changed nothing | counts as its one change; a command or a second unit after it raises `SweetTalk::Boundary` |
| `SweetTalk.lock` outside a transaction | raises `ArgumentError` |
| `changes:` naming another context’s aggregate | needs `follows:` or `shares:` and what that context publishes, as any name does; in a central context, a tenanted aggregate fails compilation |
| `returns:` omitted | defaults to `Nil` |
| A `unit` anywhere but a context, without `means:`, with `changes:` that is not a list of aggregates declared before it, or with `locks:` naming anything but its arguments | fails compilation |

## Name a calculation and its rules {#c-sweettalk-calculations}

A calculation is a typed function of a context: it splits, rounds or converts, and changes nothing. It lives in a context, carries `means:` and `returns:`, and joins the glossary with kind `calculation`. It opens no transaction and reaches no repository, so a command, a service, a unit, a handler or plain code may call it. The body is Crystal, and its last expression is the result. A `never` or `always` line in the body is a rule on `result`, checked after the body, over the result and the arguments.

**app/domain/lots.cr · a calculation**

```crystal
calculation consume(total : Cents, settlements : Array(Units)), returns: Array(Cents),
  means: "the carrying amount each settlement consumes, the lot being all of them" do
  always "settling every unit consumes the whole carrying amount" do
    result.sum(0_i64, &.raw) == total.raw
  end
  lot = settlements.sum(0_i64, &.raw)
  raise SweetTalk::Refusal.new("A lot settles at least one unit.") if lot.zero?
  settled = 0_i64
  settlements.map do |units|
    before = total.raw * settled // lot
    settled += units.raw
    Cents.new(total.raw * settled // lot - before)
  end
end
```

Call it on its context: `Carrying.consume(total, settlements)`. An input outside the calculation’s domain is the caller’s to fix, so the body raises `SweetTalk::Refusal`. A result that breaks the calculation’s own rule is not: it raises `SweetTalk::Broken`, whose `calculation` and `rule` name the calculation and the sentence. Like any other error it rolls back the transaction it runs in, and an action that does not rescue it answers 500 and reports it to Crema ([ADR 0062 ↗](https://github.com/caramelizedev/caramel/blob/main/docs/decisions/0062-sweettalk-calculations.md)). `SweetTalk.calculations` lists every calculation with its arguments, the type it returns and its rules, as `SweetTalk::Calculation` records.

| Condition | Outcome |
| --- | --- |
| A `never` left true or an `always` left false by the result | raises `SweetTalk::Broken`, “Carrying.consume broke its rule: …”; an action answers 500 |
| A `SweetTalk::Refusal` raised in the body | refuses before any rule runs; an action answers 422 |
| A broken rule inside a command, a service or a unit | rolls its transaction back |
| A calculation called from a command, a service, a unit or a handler | allowed: it changes nothing |
| A body or a rule that names `SugarORM`, `Repo`, `Rows` or `SweetTalk.lock`, emits, calls a method on an aggregate’s class such as `Lot.find`, or calls a service or a unit | fails compilation, at that line |
| An argument or a result that holds an aggregate, an entity, a projection or a process | fails compilation: take its id or what the calculation needs |
| `returns:` or `means:` omitted | fails compilation |

Stage 5 · React

## Follow events with policies {#c-sweettalk-events}

`event` declares one of the aggregate’s events, and `emit` queues one from a command with its facts; an aggregate emits only its own. A context declares events too, for a change no aggregate holds, and a service emits them: [Name operations with services](#c-sweettalk-services). An event holds its subject’s id (`placed.order_id`; a context’s event has none, or the tenant’s id under `caramel/tenancy`) and its fields as they were when it was emitted: column types, values, ids and an `Array` of the aggregate’s entity. An entity among them is written when the command dispatches, after its save, so it shows the entity as the command left it, with `id`: a handler reads `line.id`, for a factory’s new lines too, and a job queued before entities carried an id raises on it. No getter on an event loads an aggregate, so a handler reads what happened, not what is true now.

`whenever` in a context or a border is a policy, run as a Cold Brew job. The command enqueues one job per policy in its own transaction, so a job is never lost and never sent for a rolled-back change. A handler changes one aggregate too, by as many commands as it needs; a `create` or a factory counts as the first. With `each:` it runs once per element of a list in the event, each in its own job: the `Sales` projection below counts one order line per job.

The command enqueues the jobs in declaration order: the policies of the contexts and their borders, then the projections’ handlers, then the processes’ steps. That is the order Cold Brew starts them in, not the order they finish in: a policy that needs a projection’s row waits for no one, so it reads the event, not the read model. In a spec, `SweetTalk.emitted { … }` returns the events a block’s commands emitted, in that order, and `SweetTalk.emitted(Order::Placed) { … }` those of one class, typed; the jobs are enqueued all the same.

A handler that must see another’s row saved says so: `whenever Order::Placed, after: Sales do … end` names the projection, process or context whose handler of the same event comes first. The command does not enqueue such a handler; the predecessor’s job enqueues it, with the same event, in the transaction that saves its own work, so the follower starts only once that work is committed. A refused or permanently failed predecessor never releases its followers, and a rebuild of the predecessor releases none either ([ADR 0048 ↗](https://github.com/caramelizedev/caramel/blob/main/docs/decisions/0048-sweettalk-event-log.md)).

- A job carries the event as JSON. `whenever Event, attempts: 5, backoff: :linear, base: 2.seconds`, in a context, a border, a projection or a process, and the same keywords on `deadline`, set the job’s retry rule for errors other than a refusal.
- A job is named after its owner (a context and its border, a projection or a process) and the event, never after a line, because `caramel_jobs` stores the name.
- The command also publishes `{"subject": id}` on `sweettalk.CONTEXT.AGGREGATE.EVENT` for live pages, delivered on commit and at most once; a service publishes its context’s event on `sweettalk.CONTEXT.EVENT`, with the tenant’s id or null as the subject.

| Condition | Outcome |
| --- | --- |
| One line’s job fails | the other lines’ jobs still run |
| Two `whenever` blocks for one event in one owner | fails compilation |
| A rename whose old job name another job has or claims | fails compilation |
| A handler that runs two commands on one aggregate | allowed |
| A refusal, or a handler that changes a second aggregate | fails its job at the first attempt, unless a `compensate` answers the refusal; the command that emitted the event stays committed |
| Any other handler error | follows the `attempts:`, `backoff:` and `base:` the `whenever` or `deadline` declares, or Cold Brew’s default rule without them; a literal Cold Brew refuses fails compilation |
| `whenever Event, after: Sales` | runs once Sales’s handler of the same event has committed, enqueued by that job in its transaction, with the same subject, fields and metadata; the follower may take `each:` of its own |
| An `after:` naming an owner that does not follow the event, or whose handler takes `each:`, or a chain of `after:` that runs in a circle | fails compilation |

## Keep an event log {#c-sweettalk-event-log}

`event_log: true` on a context keeps every event it emits, from its aggregates’ commands and from its services, and every event of a kernel it shares, in `CONTEXT_events`: one row per event, written in the command’s or the service’s transaction, so a refused command logs nothing and a logged row never lacks its jobs. The table is part of the derived schema, so `frappe db diff` creates it. A kernel takes no `event_log:`: its events go to the log of each sharer that keeps one. A context without the keyword keeps no log and writes nothing ([ADR 0048 ↗](https://github.com/caramelizedev/caramel/blob/main/docs/decisions/0048-sweettalk-event-log.md), [ADR 0051 ↗](https://github.com/caramelizedev/caramel/blob/main/docs/decisions/0051-sweettalk-event-log-replay-and-retention.md)).

**app/domain/billing.cr · a context that keeps its log**

```crystal
context Invoicing, event_log: true, means: "raising and settling invoices" do
  # …
end
```

A row holds `event_id`, unique; `aggregate`, the aggregate’s stored name, led by the kernel’s for a kernel’s (`stock_crate`), or the context’s own name for a service’s event; `name`, the stored event name, the `renamed_from:` original as the channel says it; `subject_id`; `occurred_at`; `actor`; `cause_id`; `flow_id`; `fields`, the event’s facts as `jsonb`; and `created_at`. A row is never updated. Indexes cover `flow_id`, `cause_id`, `(aggregate, subject_id, id)` and `occurred_at`. Under `caramel/tenancy` the table carries the tenant column like every table of the context, so each tenant reads its own rows, and a central context’s log is shared.

`Invoicing.logged(Invoice::Raised, subject: id, since: time, before: moment, limit: 100)` reads the typed events of one class, oldest first and newest last, the first `limit` of them (100 by default); `subject:` keeps one aggregate’s, `since:` those that occurred at or after a time, and `before:` those that occurred before a moment ([Read what was known at a time](#c-sweettalk-known-at)). `Invoicing.logged(subject: id)` reads every class as `SweetTalk::Event`. A read event carries the metadata it was logged with, so `logged.first.actor` says who acted.

**Inside an action · invoice is a loaded Invoicing::Invoice**

```crystal
Invoicing.logged(Invoicing::Invoice::Settled, subject: invoice.id, since: 30.days.ago)
```

`Books.reached(event)` answers what an event led to. It walks every context’s log forward by `cause_id`: the events its handlers emitted, then the events those emitted, across every context that keeps a log, until none is new. It returns a `SweetTalk::Reached`: `events`, oldest first, the event asked about left out, and `by_subject`, which groups them by aggregate and id.

**Inside an action · opened is a logged Books::Journal::Opened**

```crystal
reached = Books.reached(opened)
reached.events.map(&.class.name)
reached.by_subject.each { |(aggregate, id), events| puts "#{aggregate} #{id}: #{events.size}" }
```

| Condition | Outcome |
| --- | --- |
| An event caused by a handler, a compensation, a deadline or a process step | is reached from the event that handler followed |
| A command, service or unit called outside a handler | starts a chain: nothing causes its events |
| An event of a context that keeps no log, or one a retention window pruned | ends its chain: the walk passes only through logged events |
| A tenanted log | is read for the bound tenant only, and raises `SugarORM::Tenancy::Missing` when none is bound |
| `reached` of an event its context’s log does not keep | raises `ArgumentError` |

`event_log: true` keeps every event. `event_log: 90.days`, or any whole number of days or weeks, keeps an event that many days: the context schedules `sweettalk:prune:CONTEXT_events` with `Caramel::ColdBrew.every`, once an hour, which deletes the rows that occurred before then, 1,000 a statement, across every tenant. A rebuild needs every event, so `SweetTalk.rebuild` of a projection whose context keeps them a number of days does not compile.

`SweetTalk.rebuild(Invoicing::Owed)` rebuilds a projection from the log. In one transaction it takes `pg_advisory_xact_lock` in Cold Brew’s namespace on the projection’s table name, leaves to its job every event, or element of `each:`, that a queued job of the projection’s handlers, or of a handler one says `after:`, still has to apply; that job applies it once the rebuild commits. A job of a projection’s handler takes the same lock, shared, so none runs while its projection rebuilds. It deletes the projection’s rows, replays the other events the projection follows, oldest first, through its own handlers, one unit of work per event and one per element with `each:`, and returns a `SweetTalk::Rebuilt`: `replayed`, `deferred`, the events it left to queued jobs, and `oldest`, when the oldest logged event occurred, which shows where a log turned on later begins. It enqueues nothing, so a handler that says `after:` the projection does not run again. Under `caramel/tenancy` it rebuilds the bound tenant’s rows from that tenant’s log: run it under `Caramel::Tenancy.with` for each tenant.

| Condition | Outcome |
| --- | --- |
| A refused command, or a service that raises | logs nothing |
| An event of a kernel the context shares | is logged by each sharer that keeps a log, as `KERNEL_AGGREGATE` |
| `logged` of an event class the log does not keep | raises `ArgumentError` |
| A logged row whose aggregate and name no event stores any more | raises `ArgumentError` when read, naming `renamed_from:` |
| A rebuild while a job of the projection’s handlers is queued | leaves that job’s event to it, so the event is applied once |
| A failed job of the projection’s handlers that is retried after a rebuild | writes its event a second time, because the rebuild replayed it: discard the job instead of retrying it |
| A rebuild of a projection whose handler reads present state, such as an aggregate’s row | reads what is true now, not what was when the event occurred: keep a handler to the event’s fields |
| A rebuild of a projection whose events predate `event_log: true` | starts from the first logged event; the rows the earlier events built are gone |
| `SweetTalk.rebuild` of a projection whose context keeps no log or keeps it a number of days, or that follows an event the log does not keep | fails compilation |
| An aggregate, projection or process whose table would be `CONTEXT_events` | fails compilation |

## Read what was known at a time {#c-sweettalk-known-at}

Rows hold what is in effect now. The event log holds what the program knew, and when. `before:` on `logged` reads the log as it stood at a moment: the events whose `occurred_at` is earlier than it. An event is stamped when it is emitted, so `before:` answers what was known then, not when what an event records took effect.

A correction changes what is in effect. Keep the result in effect on the aggregate, and let the command that finalises the correction set it, so a reader asks the row and never scans the corrections. Its event records the result it replaced.

**app/domain/billing.cr · an invoice whose total is corrected**

```crystal
aggregate Invoice, means: "what one customer owes for one order" do
  has customer : String
  has total : Cents
  moves open >> settled

  event Corrected, was : Cents, carries: [customer, total],
    means: "an invoice's total was corrected"

  to correct(amount : Cents) do
    refuse "A settled invoice keeps its total." if settled?
    was = total
    @total = amount
    emit Corrected, was: was
  end
end
```

`invoice.total` is what the customer owes now. The log says what the invoice said when the reminder went out: the last `Raised` or `Corrected` before that moment.

**Inside an action · invoice is a loaded Invoicing::Invoice**

```crystal
def total_known_at(invoice : Invoicing::Invoice, moment : Time) : Invoicing::Cents?
  Invoicing.logged(subject: invoice.id, before: moment).reverse_each do |event|
    case event
    when Invoicing::Invoice::Corrected, Invoicing::Invoice::Raised then return event.total
    end
  end
  nil
end
```

| Condition | Outcome |
| --- | --- |
| An event that occurred exactly at the moment | is not read: `before:` leaves its bound out and `since:` keeps it, so two reads split at one moment share no event and miss none |
| `since:` and `before:` together | read the events between the two |
| More events before the moment than `limit` | reads the oldest `limit` of them: raise `limit:`, or narrow the read with `since:` and `subject:` |
| A log kept a number of days, read before a moment older than its window | reads what remains, which holds no event older than the window |
| A moment before `event_log: true` was set | reads nothing: the log holds no earlier event |
| A tenanted log | is read for the bound tenant only, and raises `SugarORM::Tenancy::Missing` when none is bound |

## Record who acted {#c-sweettalk-metadata}

Every event records `event_id`, a UUID, `occurred_at`, `actor`, a `String?`, `cause_id`, the event whose handler emitted it, and `flow_id`, shared by every event one command leads to: the request’s trace id when it ran in one. Its jobs carry all five. No command takes an actor: wrap the call in `SweetTalk.acting` instead.

**Inside an action · order is a loaded Ordering::Order**

```crystal
SweetTalk.acting("member:7") { order.place }
```

Each policy, compensation and process step runs as its event’s actor, so the `Cancelled` event a refused hold leads to still names `member:7`. A deadline acts as `deadline Hold.lapse`.

A field may be nilable. `cancel` without a reason sends `reason` as JSON null:

**app/domain/tea_shop.cr · a nilable fact**

```crystal
event Cancelled, lines : Array(Line), reason : String?,
  means: "the order was given up, and why"

to cancel(reason : String? = nil) do
  unless cancelled?
    cancelled!
    emit Cancelled, lines: lines, reason: reason
  end
end
```

| Condition | Outcome |
| --- | --- |
| An event field named `event_id`, `occurred_at`, `actor`, `cause_id`, `flow_id` or like the subject’s id | fails compilation |
| An event field typed as a union of other types, such as `String \| Int32` | fails compilation |

An event can take its fields from the aggregate by name. `carries:` lists attributes and derived values declared above the event; the event has one field for each, of its type, and `emit` reads them from the aggregate as it is when `emit` runs, so no command restates them. A reference is carried as its id.

**app/domain/tea_shop.cr · an event that carries attributes**

```crystal
event Shipped, carries: [member, deliver_to, courier, total],
  means: "an order left, with what it said when it left"

to ship(courier : Courier) do
  shipped!
  @courier = courier
  emit Shipped
end
```

A command cannot give a carried field, as in `emit Shipped, total: refunded`: the event would say what the order does not hold, so it does not compile. An event that needs a value of its own declares a field of another name, as in `event Refunded, refunded : Cents, carries: [member]`. A carried field is an ordinary field: a handler reads `shipped.member` and `shipped.total` as emitted. A field typed `T?` that a job queued before the field existed lacks reads as nil. A required field added later takes `older:` on the event, as in `older: {till: "front"}`: a queued job or a logged row without the field reads that value, and one without `older:` raises when it is read.

`carries:` makes the event a snapshot of the aggregate, and a deliberate coupling. The event is stored in the job that delivers it, so renaming or retyping a carried attribute changes the payload of jobs already queued, and a worker reads every field of the event before a handler runs. A carried attribute is renamed safely only when the new one is optional: when `member` becomes `account : Account::Id?`, keep the old name for as long as jobs may be queued with `the member : Account::Id? = account`, a derived value named as the old attribute that the event carries too; a job queued under the old name reads `account` as nil. When the new attribute is required, emit a new event for the new shape. An event that must stay stable while the aggregate changes declares its own fields.

| Condition | Outcome |
| --- | --- |
| A `carries:` name that is not an attribute or derived value declared above the event, a name twice, or one named like the event’s metadata | fails compilation, listing what the aggregate has |
| A `carries:` that is not a list of names | fails compilation |
| An `emit` that gives a field the event carries | fails compilation |

A retried job carries the same `event_id`. A handler that sends mail or calls an API can key that side effect on it, so a retry can tell the side effect already happened.

## Keep read models {#c-sweettalk-projections}

A projection is a table with one row per key. Inside a `whenever` block, `Sales[tea]` reads the row locked and saves it when the handler returns. When the row is missing, an upsert on the key’s unique index inserts it with its defaults, so two handlers that insert one key at once keep one row. An attribute other than the key is optional or has a default its column takes as its SQL default: a literal, or a value built from one, as in `has takings : Catalogue::Cents = Catalogue::Cents.new(0_i64)`; a value with parts, a calendar day, a decimal or a JSON document takes none, so it is optional.

**app/domain/tea_shop.cr · a projection**

```crystal
projection Sales, means: "tins sold of one tea" do
  key tea : Catalogue::Tea
  has sold : Int32 = 0
  has takings : Catalogue::Cents = Catalogue::Cents.new(0_i64)
  has last_order : Order?

  whenever Order::Placed, each: :lines do |placed, line|
    row = Sales[line.tea]
    row.sold += line.quantity.to_i
    row.takings += line.cost
    row.last_order = placed.order_id
  end
end
```

A projection declares queries as an aggregate does. `finds` takes `where:`, `order:` and `first:`, or a block that narrows its rows, and `counts` takes `where:`. The keys are the projection’s attributes, its key included: `where: {tea: tea}` compares the tea’s id. A projection has no lifecycle and no specifications, so it takes neither `state:` nor `satisfying:`, and every row counts, since a projection removes none.

**app/domain/tea_shop.cr · projection queries**

```crystal
finds best_sellers(count : Int32), order: {sold: :desc}, first: count
counts sold_any, where: {sold: 1..}
```

`Sales.best_sellers(10)` reads the ten best-selling teas in one statement, and `Sales.sold_any` counts the teas that sold at least one tin without loading them.

## Run processes with deadlines and compensation {#c-sweettalk-processes}

A process is a workflow across aggregates. It keeps one row per `key`, with attributes, a lifecycle and deadlines, in a table such as `ordering_holds`. `Hold` holds the tins of one tea for one placed order until the parcel leaves, and gives them back when the order is cancelled or the parcel is late.

**app/domain/tea_shop.cr · a process**

```crystal
process Hold, means: "tins of one tea held on the shelf for one placed order" do
  key slot : Slot
  has tins : Int32 = 0
  moves waiting >> holding >> taken, waiting >> refused, waiting >> released,
    holding >> released

  whenever Order::Placed, each: :lines,
    key: Slot.new(order: placed.order_id.raw, tea: line.tea.raw) do |placed, line|
    if waiting?
      Catalogue::Tea.find(line.tea).hold Catalogue::Tins.new(line.quantity.to_i)
      @tins = line.quantity.to_i
      holding!
      arm lapse
    end
  end

  compensate Order::Placed do |placed, line, refusal|
    refused!
    Order.find(placed.order_id).cancel refusal.message
  end

  # whenever Order::Cancelled releases the tins; Fulfilment::Parcel::Dispatched takes them

  deadline lapse, after: 7.days do
    Order.find(Order::Id.new(slot.order)).cancel "not dispatched within 7 days" if holding?
  end
end
```

| Word | What it does |
| --- | --- |
| `whenever Event, key: expression` | A step. Its job inserts the row when it is missing, locks it and runs the block on it. A step changes at most one aggregate; its own row does not count. Attributes other than the key are nilable or have a literal default, or a value built from one, because a row starts from its key alone. |
| `compensate` | Runs when its `whenever` is refused. The handler’s work has already rolled back; the compensation gets the same arguments and the refusal, and runs in its own transaction. Here a tea that cannot be held cancels its order with “Only 1 tins of Gyokuro free.”. A refusal in the compensation fails the job. A context or a border may compensate its own `whenever` too: Ordering’s border notes a parcel that left after its order was cancelled. |
| `arm lapse`, `disarm lapse` | `arm lapse` sets `lapse_due` and enqueues a job for that time, and `disarm lapse` clears it. Cold Brew cannot cancel a job, so every arm and disarm counts up an arming counter: a stale deadline job finds a newer arming and does nothing. |
| `arm lapse, after: 2.days` | Arms the deadline for another span than its own. |
| `finds`, `counts` | A process declares queries as a projection does, over its attributes, its key and its `state:`, with `order:`, `first:` and the block; it takes no `satisfying:`, and every row counts. A dashboard lists stalled holds through them, not through SQL. |

A process may react to another context’s events outside a border. `Hold` follows `Fulfilment::Parcel::Dispatched`, which draws an event edge from Ordering to Fulfilment.

Stage 6 · Operate

## Split a context across files {#c-sweettalk-files}

A context is declared once, by `context` with its options. `within Picking do … end` continues it in another file: it takes the words a context’s body takes, and no option. Give a context that outgrows its file a directory, and each aggregate a file of its own with the values, events, queries and specifications only it uses.

**app/domain/estate.cr · the domain module requires its files in order**

```crystal
module Estate
  include SweetTalk
  ids Int64
end

require "./estate/garden"
require "./estate/garden/bush"
require "./estate/picking"
require "./estate/picking/basket"
require "./estate/picking/heavy"
```

A word reads the names it uses when it expands, so each file is required after the files whose names it uses: `picking/basket.cr` names `Garden::Bush`, which `garden/bush.cr` declares. A generated application’s `require "../app/domain/*"` loads only `estate.cr`, which requires the rest.

**app/domain/estate/picking/basket.cr · an aggregate in a file of its own**

```crystal
module Estate
  within Picking do
    aggregate Basket, means: "the leaves one picker brought in from one bush" do
      has bush : Garden::Bush
      has weight : Grams

      event Weighed, carries: [weight], means: "a basket was put on the scales"

      to weigh(grams : Grams) do
        @weight = grams
        emit Weighed
      end

      finds heavy_ones, satisfying: Heavy
    end

    unit weigh_once(key : String, basket : Basket::Id, grams : Int32), changes: [Basket],
      locks: [basket], once_by: key, returns: Int32,
      otherwise: "That weighing was already made with another basket.",
      means: "weighs a basket once per key and answers its weight" do
      Basket.find(basket).weigh Grams.new(grams)
      Basket.find(basket).weight.raw
    end
  end
end
```

| File | Holds |
| --- | --- |
| `app/domain/estate.cr` | The domain module with its `tenant`, `ids` and `requirements`, then the requires, each after the files whose names it uses |
| `app/domain/estate/<context>.cr` | The `context` with its options, the values the whole context uses, and its `publishes` |
| `app/domain/estate/<context>/<aggregate>.cr` | `within`, holding one aggregate with its own values, events, queries and specifications; a unit or a service goes in the file of the aggregate it changes |

Every block counts. A `follows:` or `shares:` that only a later file uses is used, a name published in a later block is published, and a foreign name in any block is refused as it is in the header. Queries wait for the whole program, so `heavy_ones` may name `Heavy`, which `picking/heavy.cr` declares after it. A context lists its `publishes` in one block and keeps one border for each other context or outside system.

## Rename without moving data {#c-sweettalk-renames}

A name SweetTalk stores, such as a table, a channel or a job name, comes from a domain name. When the model finds a better word, `renamed_from:` keeps the table and the channel the old name used, so no data moves.

**app/domain/tea_shop.cr · Tea renamed to Blend**

```crystal
aggregate Blend, renamed_from: Tea, means: "one tea we sell" do
  # still stored in catalogue_teas, still announced on sweettalk.catalogue.tea.*
end
```

A job’s name follows its owner and the event’s path as written. When a rename changes it, SweetTalk declares Cold Brew’s `renamed_from` on the job with the old name, so jobs queued before the rename keep running.

These are the names SweetTalk stores, which a deployed application depends on:

| Stored name | Form |
| --- | --- |
| Tables | `ordering_orders` and `ordering_order_lines`, with their `check_…`, `index_…` and `fk_…` names |
| Job class names | `TeaShop::Ordering::Sales::WhenOrderPlaced` and `TeaShop::Ordering::Hold::LapseDeadline` |
| Channels | `sweettalk.<context>.<aggregate>.<event>`, or `sweettalk.<context>.<event>` for a context’s event, behind a tenant’s `t<id>:` prefix |
| Event metadata keys | `id`, `at`, `by`, `cause` and `flow` |

`renamed_from:` keeps a table, a channel and queued jobs across a rename. While SweetTalk is experimental, a minor release may still change any of these names.

## Share a domain between tenants {#c-sweettalk-tenancy}

In a multi-tenant application, name the tenant model before the first context. It is the model the routes’ `tenant` block names, and SugarORM refuses another.

**app/domain/tenant_shop.cr · a domain shared by tenants**

```crystal
module TenantShop
  include SweetTalk

  tenant Account

  context Catalogue, central: true, means: "the teas every tenant sells" do
    aggregate Tea, means: "one tea on every tenant's shelf" do
      has name : String
    end
  end

  context Ordering, follows: Catalogue, means: "choosing teas and checking out" do
    aggregate Order, means: "one tea a tenant orders" do
      has tea : Catalogue::Tea
    end
  end
end
```

Every context belongs to the tenant unless it says `central: true`. Its aggregates, entities, projections and processes get a column named after the model, `account_id` here, and SugarORM scopes their reads, locks, keys and upserts by the bound tenant, so a projection or a process keeps one row per tenant per key. A policy, projection or process step runs in the tenant its event was emitted in, a deadline in the tenant that armed it, and a notification goes out on the tenant’s channel. A central context’s rows are shared by every tenant.

A tenanted aggregate may reference a central one, as an order line names a shared tea. Every aggregate of a tenanted context has `tenant_id`, of the tenant’s key type, its row’s, or the bound tenant’s before its first save, and `tenant`, the tenant model’s row: `Caramel::Tenancy.without { Ordering::Order.all }.map(&.tenant_id)` says whose each order is without SQL. `has tenant` and `has tenant_id` on such an aggregate fail compilation.

| Condition | Outcome |
| --- | --- |
| A tenanted aggregate references a central one | allowed |
| A domain without `tenant` in a program that requires `caramel/tenancy`, or `tenant` without that require, after a context, twice, or naming anything but a SugarORM schema | fails compilation |
| `central:` with anything but `true`, or without `caramel/tenancy` | fails compilation |
| A `has` in a central context that points at a tenanted aggregate or a tenanted schema of the application, whose rows every tenant would then see | fails compilation |
| A `whenever` in a tenanted context for a central context’s event, which carries no tenant (a central context may follow a tenanted one’s events, and its handler runs in the event’s tenant) | fails compilation |
| An event channel over 42 characters under an Int64 tenant, which leaves 21 for its `t<id>:` prefix, or over 36 under a UUID tenant, which leaves 27 | fails compilation |
| `ids` other than `UUID` or `Int64`, twice, after a context, or different from the tenant’s key type | fails compilation |
| A tenant index name over PostgreSQL’s 63 bytes | is shortened by SugarORM, as any index name is |
| A `has` that would store `account_id` or `account`, or an entity of an aggregate named like the tenant model | fails compilation |

A domain that already holds data follows Add tenancy to existing data in the multi-tenancy guide; `frappe db diff` names every SweetTalk table it halts on. [Read the multi-tenancy guide](https://caramelize.dev/docs/0.23.0/multi-tenancy/index.md)

## Read the glossary and the context map {#c-sweettalk-glossary}

`frappe glossary` prints every term with its meaning and the facts its declaration holds: a value’s bounds and words, an aggregate’s states and moves, an event’s handlers in the order they run, a unit’s `changes:` and `locks:`, a context’s `follows:` and `shares:`. `--json` prints the document the application’s `glossary` command answers, which Frappé keeps in `.caramel/glossary.json` until the source changes. `frappe contexts` prints each context with its edges, and `--mermaid` prints a flowchart. In code, `SweetTalk.report` returns the same entries.

**Terminal · inside the application**

```crystal
frappe glossary
frappe contexts --mermaid
```

**Expect:** `frappe glossary` prints `# Glossary`, then one section per context and kernel, as `## Seating (context, core)` in the Box Office path, with its meaning, its `follows:` and `shares:`, and a table of its terms, as `| Show | aggregate | one performance and the seats it sells | states: on_sale, closed; moves: on_sale >> closed |`. `frappe contexts --mermaid` prints `flowchart LR`, a line per context, then an arrow per edge, as `Waitlist -->|depends on| Seating`.

## Look up a word {#c-sweettalk-words}

`frappe words` prints every SweetTalk word with its kind and a one-line summary. `frappe words WORD` prints, for each place the word may be written, where that is, its usage, each option with the forms it takes, its default and what it does, an example that compiles, and the section of this guide that teaches it. `--json` prints the same as JSON. It works outside an application and reads the doc comments and parameters of the macros of the release you run, so it names no option a macro lacks. Where this guide and the command differ, the command is right.

**Terminal · anywhere**

```crystal
frappe words
frappe words whenever
frappe words valeu
```

**Expect:** `frappe words` prints `SweetTalk words in Caramel 0.23.0` and how many there are, then a group for each kind, as `query: reads rows` above `counts`, `finds`, `groups` and `sums`. `frappe words whenever` prints a block for each place the word may be written, as `In a process: Runs a step of a process when an event happens, on the row its key picks.`, then its `Options` and an `Example`. `frappe words valeu` exits 1 and prints `frappe words: unknown word valeu; nearest: value`.

## Trace requirements to rules and examples {#c-sweettalk-requirements}

A team that answers to numbered requirements lists them once, before the first context, and says which rule answers each. `requirements` names the ids; `assures:` on a `never`, an `always`, a `specification` or a `unit`, and on a rule in a unit’s or a calculation’s body, names the ids a line answers. An id is letters, digits, `.`, `_` and `-`, starting with a letter or a digit.

**app/domain/ledger.cr · requirements and what assures them**

```crystal
module Ledger
  include SweetTalk

  requirements "AC-12", "AC-13"

  context Journals, means: "the entries a book keeps" do
    aggregate Entry, means: "one line of the journal" do
      has debit : Int64
      has credit : Int64
      never "An entry must balance.", assures: "AC-12" { debit != credit }
    end
  end
end
```

`frappe requirements` lists each id with the lines that assure it, and `frappe requirements AC-12` shows one. A full `frappe corretto` run then fails while an id has no example that names it: write the id in the example’s name.

**spec/domain/ledger_spec.cr · an example that names its requirement**

```crystal
describe "Ledger" do
  it "refuses an unbalanced entry (AC-12)" do
    # …
  end
end
```

**Terminal · inside the application**

```crystal
frappe requirements
frappe requirements AC-13
frappe corretto
```

**Expect:** `frappe requirements` prints `AC-12` and, indented, `never Ledger::Journals::Entry: An entry must balance.`, then `AC-13` and `nothing assures it`. `frappe corretto` with no paths fails with `No example names requirement AC-13` until an example’s name holds `AC-13`.

| Condition | Outcome |
| --- | --- |
| `requirements` with no id, an id that is not text or has another shape, an id twice, a second `requirements` in one module, or one after a context | fails compilation |
| `assures:` that is not an id or a list of ids, in a module with no `requirements`, or naming an id the module does not list | fails compilation, naming the ids the module lists |
| `frappe requirements ID` for an id that is no requirement | exits 1, naming the requirements |
| A full `frappe corretto` run in which every worker passed and an id appears in no example’s name | fails, naming each such id |
| A run of chosen spec paths | checks no requirement |
| An id named as part of a longer one, such as `AC-1` in `AC-12` | is not named |

## Call the domain from actions {#c-sweettalk-actions}

An action’s contract may declare a value or an aggregate’s id as a field. The field binds from the type the value wraps, with that type’s grammar and JSON type, and the value’s refusal becomes the field’s error, so a form shows it beside its input. The example is the Box Office path’s: `Seats` is a value within 1..8, `Email` a string value, and The Tempest a show. [Build a box office →](https://caramelize.dev/docs/0.23.0/box-office/index.md)

**app/actions/holds/create.cr**

```crystal
module App::Holds
  struct Create < App::ApplicationAction
    contract do
      field show : BoxOffice::Seating::Show::Id
      field guest : BoxOffice::Seating::Email
      field seats : BoxOffice::Seating::Seats
    end

    def handle(contract : Contract)
      show = BoxOffice::Seating::Show.find(contract.show)
      show.hold(contract.guest, contract.seats)
      redirect_to("/shows/#{show.id.raw}/holds/#{show.issued}")
    end
  end
end
```

An id binds from its domain’s id type, `UUID` or `Int64`, and may bind a route parameter, as `:show` does; a UUID binds from its lowercase hyphenated form only. A `Day` binds from text written `YYYY-MM-DD`, in a form or in a JSON string, and a day the calendar lacks answers “Day must be a calendar day written YYYY-MM-DD, as in 2026-02-28” under its field. A value with parts is not a field: declare one field per part and build the value in `handle`. The contract reference says what else a field value may take.

| Condition | Outcome |
| --- | --- |
| The route `post "/shows/:show/holds", App::Holds::Create` with `seats=9` from a JSON client | answers 422 with `{"errors":{"seats":["Seats must be between 1 and 8"]}}`, before `handle` runs |
| `/shows/abc/holds`, since an id binds from a `UUID` | answers 404 |
| A refusal that `handle` does not rescue | answers 422 the way a failed contract does, with its message under the field its `on:` names when the contract declares that field, and under `_base` otherwise |
| `SweetTalk::Missing`, which `find` raises for an id that names no aggregate | answers 404 |
| `SweetTalk::Boundary`, a mistake in the code | answers 500 |

A refusal answers each client as follows:

| Client | Gets |
| --- | --- |
| JSON client | `{"errors":{"_base":["The Tempest is sold out."]}}` |
| Browser or htmx request | `contract_failure_page(contract)`, so a form that re-renders itself on a failed contract shows the refusal too |
| Any other client | Plain text that starts with `ERR INVALID:422` |

Override `render_refusal(contract, refusal)` to answer otherwise. Neither a refusal nor `SweetTalk::Missing` is reported to Crema as an error.

[Read the contract reference →](https://caramelize.dev/docs/0.23.0/routes-and-contracts/index.md)

## Show the domain on screens {#c-sweettalk-screens}

A screen that restates a closed set, comparing text or branching with an `else`, keeps compiling when the domain adds a member, and shows the new member the default arm’s words. Branch with `case … in` instead. Crystal refuses its `else`, so a `case … in` that misses a member fails compilation.

**app/views/teas/show.cr · a label per roast**

```crystal
private def roast_label(roast : Catalogue::Roast) : String
  case roast.member
  in .light?  then t.roast.light
  in .medium? then t.roast.medium
  in .dark?   then t.roast.dark
  end
end
```

Each member has a message in the catalogs, so a new roast fails compilation twice: at the `case` until it has an arm, and at the catalog until the default locale has its message. SweetTalk adds no word for labels. A kind with parts reads them in its member’s arm, as in `in .payment? then transfer.as_payment[:payee]`. [Translate the interface →](https://caramelize.dev/docs/0.23.0/internationalization/index.md)

Offer the commands the lifecycle allows. `Order.moves_from(order.state)` lists the states a mover may enter next, and the view maps each to the command that enters it. A state may be entered by two commands, so SweetTalk does not map states to commands; the `case` does, and a state added to `moves` fails compilation there.

**app/views/orders/show.cr · the commands an order offers**

```crystal
private def offers : Nil
  Ordering::Order.moves_from(@order.state).each do |state|
    case state
    in .open?      then nil
    in .placed?    then offer("place", "Place the order")
    in .shipped?   then offer("ship", "Ship it")
    in .cancelled? then offer("cancel", "Cancel the order")
    end
  end
end

private def offer(verb : String, label : String) : Nil
  form action: "/orders/#{@order.id.raw}/#{verb}", method: "post" do
    input type: "hidden", name: "_csrf", value: @csrf_token
    button(type: "submit") { label }
  end
end
```

| Condition | Outcome |
| --- | --- |
| `Order.moves_from(:placed)` | returns `[Order::State::Shipped, Order::State::Cancelled]` |
| `Order.moves_from(:shipped)`, a state no chain leaves | returns an empty array |
| `order.may_become?(:shipped)` while the order is open | returns `false` |
| A state added to `moves` that a `case … in` over the states does not name | fails compilation, naming the missing state |

Put a refusal beside its input. `on:` names the field a refusal is about, on `refuse`, `never`, `always` and a rule in a unit’s body, and a service raises `SweetTalk::Refusal.new("…", on: :tins)`. The domain does not know the action’s contract, so the action checks the field when it answers.

**app/domain/tea_shop.cr · a refusal about a field**

```crystal
to ship_free(tins : Tins) do
  refuse "Only #{stock - held} tins of #{name} free.", on: :tins if held + tins > stock
  @stock -= tins
end
```

| Condition | Outcome |
| --- | --- |
| An action whose contract declares `field tins : Int32` ships 5 of 3 free tins for a JSON client | answers 422 with `{"errors":{"tins":["Only 3 tins of Sencha free."]}}` |
| The same refusal through a contract without a `tins` field | answers 422 with the message under `_base` |
| A refusal without `on:` | answers 422 with the message under `_base` |

## Preview a change before it commits {#c-sweettalk-preview}

A person often must see what a change would record before it records it, and the world can move between the screen and the click. `SweetTalk.preview { … }` runs the body in a transaction that always rolls back, with the locks a commit takes, and answers what it would record. `SweetTalk.commit(expected) { … }` runs the same body again, compares what it records with the preview inside its transaction, and keeps it only when they agree. There is no second code path to keep in step.

**app/domain/till.cr · a unit with a warning**

```crystal
unit discount(tea : Tea::Id, price : Cents), changes: [Tea], locks: [tea],
  means: "lowers the price of one tea" do
  found = Tea.find(tea)
  was = found.price
  found.reprice price
  warn "The new price is less than half the old one." { price.raw * 2 < was.raw }
end
```

A `warn` line runs after the body with the unit’s `never` and `always` lines. When its block is true, a plain call refuses with its sentence, and a preview lists it under `warnings`. The sentence enters the fingerprint, so a person who saw the warning and sent the fingerprint back confirmed it. In a preview, a `never` or `always` line that fails does not end the run: its sentence joins `blockers`, the unit’s other lines run, and the preview keeps the events and changes. No fingerprint confirms a blocker: a commit and a plain call refuse with the first.

| Call | Answers |
| --- | --- |
| `preview.events` | Each event in dispatch order: its class, its subject as `Tea 4` or `new Receipt #1`, and its fields |
| `preview.changes` | Each aggregate the run changed, `before` and `after`, in the order it was first touched; one the run made has no `before` |
| `preview.warnings` | The sentences of the `warn` lines that held |
| `preview.blockers` | The sentences of the unit’s `never` and `always` lines that failed, in the order they ran |
| `preview.refusal` | The sentence a commit would be refused with, or nil: the body’s refusal, or the first blocker. A preview whose body was refused has no events and no changes |
| `preview.summary` | Groups of aggregate and what happened: removals and moves into a state no move leaves first, then each kind of event, then each change no event names |
| `preview.fingerprint` | A `SweetTalk::Fingerprint`: SHA-256 over the events, the after-state of every row the run touched, the warnings and the refusal |
| `preview.value` | What the block returned, typed, or nil when the body was refused; `SweetTalk.preview` answers a `SweetTalk::Preview::Of(T)`, a `Preview` that keeps it |
| `preview.to_json` | All of the above but `value`, for tooling |

The fingerprint leaves out what differs on every run. An event’s id, `occurred_at`, actor, cause and flow are left out, and so are row timestamps. A `Time` attribute or field reads as `"time"`. An id of a row the run made reads as `new Receipt #1`, numbered per type in the order the run made them. Two previews of one change therefore agree. A command that emits nothing still changes the after-state, so a new price makes a preview stale without a revision counter.

A form carries the fingerprint in a hidden field, as it carries `lock_version`. `SweetTalk::Fingerprint` is a contract field value that binds from a string of 64 lowercase hex digits; other text answers 422 with “is not a preview’s fingerprint” under the field. The fingerprint is no secret: an old one fails because the commit runs the body again.

**app/actions/prices.cr · preview on GET, commit on POST**

```crystal
module App::Prices
  struct Edit < App::ApplicationAction
    contract do
      field tea : Till::Tea::Id
      field price : Till::Cents
    end

    def handle(contract : Contract)
      confirm(SweetTalk.preview { Till.discount(contract.tea, contract.price) })
    end
  end

  struct Update < App::ApplicationAction
    contract do
      field tea : Till::Tea::Id
      field price : Till::Cents
      field expected : SweetTalk::Fingerprint
    end

    def handle(contract : Contract)
      SweetTalk.commit(contract.expected) { Till.discount(contract.tea, contract.price) }
      redirect_to("/teas/#{contract.tea.raw}")
    end

    # The form again, with what the change would record now and its fingerprint.
    def render_stale(contract : Caramel::RequestContract, stale : SweetTalk::Stale)
      return super unless @context.browser?
      confirm(stale.preview, 422)
    end
  end
end
```

`confirm` is the application’s: it renders `preview.summary` and `preview.warnings`, and a hidden input named `expected` holding `preview.fingerprint`.

| Condition | Outcome |
| --- | --- |
| Two previews of one change, though the clock and the id sequence moved | give one fingerprint |
| A preview’s events, job rows, event log rows, notifications and a unit’s `once_by:` claim | roll back with the preview |
| An aggregate instance a preview’s commands loaded or saved | reloads what is stored once the preview ends |
| A commit whose run records what the preview showed | keeps the change and answers the block’s value |
| A commit whose run records other events, leaves a row otherwise, or meets another warning | raises `SweetTalk::Stale` carrying the fresh preview, writes nothing and reloads the instances it touched |
| A refusal raised by a preview’s body | answers a preview whose `refusal` is the sentence, with no events, changes or blockers |
| A unit’s `never` or `always` line that fails in a preview | answers a preview listing its sentence under `blockers`; the unit’s other lines run |
| A unit line whose block raises in a preview that already holds a blocker | is skipped |
| A refusal in a commit | raises that refusal |
| A `SweetTalk::Stale` that `handle` does not rescue | answers 422 through `render_stale(contract, stale)`: a JSON client gets the refusal’s errors and the fresh preview under `preview`, any other client what `render_refusal` answers |
| A `warn` line whose block is true in a plain call | refuses with its sentence |
| A preview or commit inside another | raises `SweetTalk::Boundary` |

A preview takes the commit’s row locks and holds them while its body runs, so it waits on a commit of the same rows and a commit waits on it. Preview when a person reviews a change or submits it, not as they type. A panel that refreshes on every change loads its aggregates with `find`, without a lock or a transaction, and passes their values to the [calculation](#c-sweettalk-calculations) that works out its figures; the unit’s body calls the same calculation, so the panel and the record agree. `preview.value` carries those figures to the review when the unit returns them. It comes from a run that rolled back, so an id of a row the run made names nothing. A value not yet known, such as a rate still to arrive, is domain state: the preview shows what can be recorded now, and a commit that would record another number of events is stale. An approval by a second person is the application’s: store the approver’s fingerprint on an aggregate and compare it with a fresh preview.

Stage 7 · Limits

## What does not compile {#c-sweettalk-refusals}

Each mistake below stops the build. Most fail with a message that names the sentence and its fix; a row that says so fails with Crystal’s own message, such as an undefined method. `scripts/check sweet-talk-compilation` runs one fixture per mistake, and the website check holds this table to that list.

| Condition | Outcome |
| --- | --- |
| A calculation without `means:` or `returns:`, with an untyped argument, an argument named `result`, a type not declared before it, or an argument or a result that holds an aggregate | fails compilation |
| A calculation whose body or rule names `SugarORM`, `Repo`, `Rows` or `SweetTalk.lock`, emits, calls a method on an aggregate’s class, or calls a service or a unit | fails compilation |
| A calculation in an aggregate, an entity, a projection, a process or a kernel | fails compilation |
| `Corretto.property` of anything but a calculation, or of one with an argument it cannot draw | fails compilation |

| Condition | Outcome |
| --- | --- |
| A noun without `means:` | fails compilation |
| A `subdomain:` other than `:core`, `:supporting` or `:generic` | fails compilation |
| A foreign name or call outside a border, a border or `follows:` to an unknown context, or a cycle of dependency edges | fails compilation |
| A name or call another context does not publish, a `publishes` of a name the context does not declare, or of an expression | fails compilation |
| A `within` that names no context declared before it or names a kernel, or a `within` inside a context or a kernel | fails compilation |
| A `publishes` in two blocks of one context, or two borders with one context or outside system | fails compilation |
| A kernel whose `shared_by:` is not a list of two or more contexts or kernels that say `shares:`, that holds anything but values and aggregates or names a context, or that holds a word fewer than two of its sharers name | fails compilation |
| A `shares:` of anything but an earlier kernel that lists the context or kernel saying it, or a kernel named, followed or bordered by one that does not share it | fails compilation |
| A `follows: B` in a context that names no `B::` and calls no `B.verb` outside `border B`, or a `shares: K` in one that names nothing in K | fails compilation at the context’s line |
| `Caramel::Outbound` or `HTTP::Client` outside a border with an outside system, or such a border named like a context, holding a `whenever`, or without its `outside:` text | fails compilation |
| `emit` of another aggregate’s event | fails compilation |
| A mover the lifecycle does not declare | fails compilation, with Crystal’s own message |
| A lifecycle whose check name would pass PostgreSQL’s 63 bytes | fails compilation |
| `the` without a type | fails compilation |
| A value that wraps anything but `Int32`, `Int64`, `String`, `Date`, `Decimal(P, S)` or `Json(T)`, or has no parts | fails compilation |
| A value that takes an option its raw type does not, such as `matches:` on an integer or `at_least:` on a string, `database_check: true`, or `database_check: false` on a value with parts | fails compilation |
| A `one_of:` that is not a literal list of words, lists a word twice or one that is not a word, takes `matches:` or `length:`, or lists a word that names a method the value or every object already has, or a Crystal keyword | fails compilation |
| A `case … in` over a closed-set value’s `member`, or over a lifecycle’s states, that misses one | fails compilation, with Crystal’s own message, which names the missing members |
| An `on:` that is not a symbol, on `refuse`, `never` or `always` | fails compilation; on `refuse`, with Crystal’s own message |
| A `Date` value that takes a bound, a pattern, a length, a list or `database_check:` | fails compilation |
| `Day.today`, a day added to a day, or a query that gives text where a day is wanted | fails compilation, with Crystal’s own message |
| A bound that is not an integer literal, unless the value takes `database_check: false` | fails compilation |
| Two different values mixed in arithmetic, or multiplied without `times:` | fails compilation, with Crystal’s own message |
| A word out of its place: `whenever` or `service` in an aggregate, `key` outside a projection or a process, `deadline` outside a process, `specification` inside an aggregate, or `compensate` in a projection | fails compilation |
| `has` or `part` with a type that cannot be stored, a `has` of a `Hash`, or an attribute whose constraint name would pass PostgreSQL’s 63 bytes | fails compilation |
| A `key` that is optional, or a handler that assigns a projection’s key | fails compilation; the key has no writer |
| A command, factory, step, compensation or deadline that assigns `@name` for a reference attribute, which stores `@name_id` | fails compilation, naming `self.name =` |
| A `finds`, `counts` or `specification` that asks nil of an attribute that is not optional | fails compilation, naming the attribute |
| An event whose channel would pass PostgreSQL’s 63 characters | fails compilation |
| A `create` whose declared `Created` has fields, or whose `Created` channel would pass PostgreSQL’s limit | fails compilation |
| A `parts:` that cannot hold: an attribute that is not a required closed-set value, a member or part that does not exist, or an `as_` reader taken | fails compilation |
| A unit that runs once by something that is not a text argument, keeps an aggregate in its other arguments or result, takes `otherwise:` wrongly, or whose operations table is taken | fails compilation |
| A `pinned_at:` that is not a state, is outside an aggregate or on anything but a reference, or names a state the moves do not enter | fails compilation |
| A `requirements` that lists no id, an id that is not text or has an odd shape, an id twice, a second `requirements` in one module, or a `requirements` after a context | fails compilation |
| An `assures:` that is not an id or a list of ids, in a module with no `requirements`, or naming an id its module does not list | fails compilation |
| Two declarations whose names give one table | fails compilation |
| A context that names `Rows`, or code outside the domain that reads an aggregate’s rows | fails compilation |
| A projection or a process without `key`, a process step without `key:`, or a process attribute without a default its column takes | fails compilation |
| Two `whenever` blocks for one event in one place, or `each:` naming a field that is not a list | fails compilation |
| A handler that reads an aggregate from an event, as in `placed.order` | fails compilation, with Crystal’s own message |
| A factory that leaves an attribute unset, or named like a repository method | fails compilation |
| `create` on an aggregate that has a factory | fails compilation, with Crystal’s own message |
| A query on an unknown attribute, state or order, on a list of entities, with a value of the wrong type, with an argument it does not take, with nothing, with `where:` or `order:` that is not a tuple, or with a direction other than `:asc` or `:desc` | fails compilation |
| A `finds` with a block and an option, a block of more than one expression, or a block that does more than narrow its rows | fails compilation |
| A `counts` with `order:` or a block | fails compilation |
| A `sums` or `groups` without `of:`, with a block, or whose `of:` names an attribute the model lacks, another aggregate, a non-number, or a value with an upper bound or a lower bound other than 0 | fails compilation |
| A `groups` without `by:`, whose `by:` is not an attribute of the model `of:`, whose `by: :id` groups an attribute of the aggregate itself, or whose `by:` has no one-column key | fails compilation |
| A `sums` or `groups` that filters a list of entities in `where:` without adding up one of their attributes, filters another list, or names an attribute the entity lacks | fails compilation |
| A `groups` that adds up an amount whose currency is data | fails compilation |
| A query named `all` or like another query | fails compilation |
| A specification on an unknown attribute or state, on a list of entities or a derived value, with a block, without `on:`, outside a context, whose predicate the aggregate already has, or whose `where:` is neither a tuple nor specifications joined by `&`, `\|` and `!` | fails compilation |
| `satisfying:` with anything but a specification on that aggregate, or `satisfying:` and `state:` on a projection, or `satisfying:` on a process | fails compilation |
| A `compensate` without its `whenever` | fails compilation |
| `arm` of a deadline the process lacks | fails compilation |
| An event field named like its metadata, or typed as a union of other types | fails compilation |
| An event that `carries:` something that is not a list of names, a name that is not an attribute or derived value declared above it, a name twice, or one named like its metadata | fails compilation |
| An `emit` that gives a field its event carries | fails compilation |
| `renamed_from:` naming its own name, or a rename whose old job name another job has | fails compilation |
| A value with parts as a contract field | fails compilation, with Crystal’s own message |
| With `caramel/tenancy`, the mistakes listed under [Share a domain between tenants](#c-sweettalk-tenancy) | fails compilation |
| A command named `finalize`, which would replace the garbage collector’s | fails compilation |
| `has tenant` or `has tenant_id` on an aggregate of a tenanted context, which has those accessors | fails compilation |
| An `Array` of scalars | fails compilation, naming the entity form |
| A table name, or an entity’s key to its parent, over 63 bytes | fails compilation |
| A `Bool` attribute named like a lifecycle state, whose predicate `moves` defines | fails compilation |
| An attribute named like the tenant’s association, or an entity attribute named like its aggregate’s association or column | fails compilation |
| A projection or process attribute whose default is a value with parts or a calendar day, which have no SQL default | fails compilation |
| A command, factory or service whose body does not compile, called or not | fails compilation, with Crystal’s own message |
| An `emit` in a context outside a service body, or a context event with `carries:` | fails compilation |
| A `unique`, `index` or `check`, or a `has` with those options, in a projection or a process, whose key is its identity | fails compilation |
| A `unique` or `index` naming an attribute the aggregate does not have above it | fails compilation, listing the attributes it has |
| A `check` without `otherwise:`, a `has` whose `check:` is not a SQL and a sentence, a `unique:` that is neither `true` nor a sentence, or those options on a list of entities | fails compilation |
| A constraint declared twice over the same attributes, or a `check` whose name would pass PostgreSQL’s 63 bytes | fails compilation |
| A `unit` in an aggregate, an entity, a projection, a process or a kernel | fails compilation |
| A `unit` without `means:`, or whose `changes:` names another context’s aggregate without `follows:` | fails compilation |
| A central context’s `unit` whose `changes:` names a tenanted aggregate | fails compilation |
| A `warn` line with `assures:` | fails compilation |
| A command, a factory or a unit body that names an outside border’s module | fails compilation |
| A money word without `require "caramel/sweet_talk/money"`, a `currencies` that is not a list of three-capital codes, a code without its minor units, an `exponent:` for a code ISO 4217 lists or out of 0 to 9, or a `quote` without `currencies` before it or with another `rounding:` | fails compilation, naming the fix |
| An `allocation` named other than by a verb, without `of:` or `by:`, with a `remainder:` other than `:largest_fraction`, `:first`, `:last` or `:to`, a `ties:` other than `:key`, or a `Float64`, `to_f` or float literal in its types or block | fails compilation, naming the fix |
| An amount added to another currency’s, or two amounts whose currency is data added | fails compilation, with Crystal’s message naming both types |
| A `Decimal(P, S)` value without `require "caramel/sweet_talk/decimal"` | fails compilation, naming the require |
| A decimal bound that is not decimal text, such as `at_least: 0`, or one written past S decimals | fails compilation |
| A `Json` value with `at_least:` or any other option | fails compilation |
| `order:` on a `Json` value | fails compilation |
| A range in `where:` on a `Json` value | fails compilation, with Crystal’s own message |
| A projection or process attribute whose default is a decimal or JSON value, which take no SQL default | fails compilation |
| An `after:` naming a projection, a process or a context that does not follow the event, or whose handler takes `each:`, or a chain of `after:` that runs in a circle | fails compilation |
| `SweetTalk.rebuild` of a projection whose context keeps no event log or keeps it a number of days, or that follows an event the log does not keep | fails compilation |
| An `event_log:` other than `true` or a whole number of days or weeks | fails compilation |
| An `older:` that is not a named tuple, gives a field the event does not have or an optional one, or a value of another type | fails compilation; a value of another type with Crystal’s own message |
| An `event_log: true` context declaring an aggregate, projection or process whose table would be `CONTEXT_events` | fails compilation |
| An `otherwise:` that is not text, on a value without a bound, or on a value with parts | fails compilation |
| `ids` other than `UUID` or `Int64`, twice, after a context, or different from the tenant’s key type | fails compilation |

## Not covered yet {#c-sweettalk-limits}

SweetTalk covers the domain.

- A preview sees its own transaction: the policies, projections and processes that follow its events run after a commit, so it does not show what they would do.
- A preview lists a unit’s failing `never` and `always` lines; a refusal inside a command, an aggregate’s own rules among them, still ends the run and shows its sentence alone.
- Resources, representations and authorisation are the application’s: an action calls the domain, and SweetTalk answers only its refusals.
- String patterns and the `never` rules of values and aggregates are checked in Crystal only.
- A `Json` value is queried whole: `finds` and `specification` ask only whether it equals a document or is absent, and nothing reaches inside it (`@>`, a path, a GIN index), which waits on #280.
- A part of a value with parts cannot be optional by itself: make the whole value optional.
- An amount whose currency is data, `Money::Amount`, is no contract field, and a `groups` does not add one up: `sums` answers its total per currency.
- An optional attribute cannot be a projection’s or a process’s `key`, and a `finds` or `specification` asks of an optional value with parts only whether it is set, or whether it equals a value.
- Refusal messages are the domain’s English, even with `caramel/i18n`.
- An event log holds the events logged since `event_log: true` was set, so a rebuild covers those alone; nothing backfills earlier events from rows, and a context without the keyword keeps none.
- Nothing loads an aggregate as it stood at a time, and no query asks of past state: read its events with `logged(subject: id, before: moment)`. The log knows when an event was emitted; when what it records took effect is a field the application declares on the event.
- A process’s rows are never removed, so its table grows with every key it has seen.
- A `groups` takes one `by:` and counts nothing per group, and when it adds up an entity’s attribute it groups by that entity’s attributes or by `:id` only; neither `sums` nor `groups` reaches an attribute through a reference, adds up an expression or keeps only some totals: pass the ids another query returns as a list, add up each column and subtract, or filter the rows in Crystal ([Sum and group a context’s rows](https://caramelize.dev/cookbook/0.23.0/sums-and-groups/index.md)).
- A central context’s event reaches no tenanted handler, and the tenant column is always named after the tenant model (ADR 0033, deferred).
- A kernel takes no `renamed_from:`, `subdomain:` or `central:`, so renaming a kernel renames its tables and channels.
- A removed aggregate keeps its row, so a `unique` value it holds stays taken until an index can leave removed rows out (a partial index, #274); and a value’s own bound keeps the value’s sentence, so a command cannot give it another.
- A unit locks only what `locks:` names, before its body runs: a row the body finds by a query is locked by its own command, late and in the body’s order, and a `SweetTalk.lock` call after the unit’s own is ordered within its own batch only. A unit body cannot `emit` a context event; its commands emit theirs.
- A calculation’s check reads its own text: a method of the application it calls that reaches the database is not refused. A calculation lives in a context, not in a kernel.
- An aggregate, a kernel and a projection are each one block: `within` continues a context, not a word inside it.

Prove it

## Check the domain before it touches data. {#c-sweettalk-prove}

**Terminal · inside your application**

```bash
frappe check
frappe db diff --name create_shop
frappe migrate
frappe corretto
```

**Passing:** `frappe check` prints `✓ Type check passed`; the `SweetTalk.boot` line in `config/application.cr` makes it type every command, factory, service, unit and calculation body, called or not. `frappe db diff` prints `Wrote` and the path of the migration it derived; review it. `frappe migrate` prints `Applied 1 migrations.`, then `The database matches the declared schema.` `frappe corretto` runs the specs, `spec/domain/` included, against PostgreSQL and prints `Corretto: 1 of 1 workers passed`.

[← Multi-tenancy](https://caramelize.dev/docs/0.23.0/multi-tenancy/index.md) · [Read the Cold Brew reference →](https://caramelize.dev/docs/0.23.0/cold-brew/index.md)

Caramel 0.23.0 · https://caramelize.dev/docs/0.23.0/sweettalk/
