Guides / SweetTalk

# Speak the domain’s language.

SweetTalk is an opt-in language for Domain-Driven Design. Its words expand into SugarORM schemas and changesets and Cold Brew jobs, so the domain keeps its own vocabulary and Caramel keeps one way to store and run it.

Accepted · ADRs 0030, 0031, 0033 and 0034 to 0036 · Experimental · New in 0.13.0

> **Experimental**
>
> SweetTalk is new in Caramel 0.13.0. Until an application has run it in production, it is experimental: a minor release may change the names it stores, and its upgrade notes say how to move them. The examples are the tea shop that its specs run against PostgreSQL.

## Opt in {#c-sweettalk-enable}

Require SweetTalk after Caramel. A plain application compiles none of it.

**config/application.cr · excerpt**

```crystal
require "caramel"
require "caramel/sweet_talk"
```

Or let Frappé start one: `frappe make domain Shop Ordering --means="choosing teas and checking out"` adds both requires, writes `app/domain/shop.cr` with that context, and a spec in `spec/domain/`. When the application has no SweetTalk skill, it also writes `.claude/skills/sweettalk/SKILL.md`: the rules agents most often break, each ending with a link to its section here. An existing skill, edited or not, is left alone. In a multi-tenant application the domain names the tenant, and `--central` makes the context one every tenant shares.

Then include `SweetTalk` in the module that holds your domain. The words exist only there: a `context` or `has` anywhere else is an ordinary call.

**tea_shop.cr · opening**

```crystal
module TeaShop
  include SweetTalk

  context Catalogue, means: "the teas on our shelves" do
    # values, aggregates and projections
  end
end
```

## Find the Domain-Driven Design patterns {#c-sweettalk-ddd}

Most patterns of Domain-Driven Design have a SweetTalk word. The table names the word and the section that states its rules. A pattern SweetTalk lacks says so.

| Pattern | In SweetTalk | Rules |
| --- | --- | --- |
| Bounded context | `context`, a module with its own vocabulary. | [Draw the contexts](#c-sweettalk-contexts) |
| Ubiquitous language | `means:` on every noun, and `SweetTalk.glossary`, which lists each with its kind and context. | [Give every noun a meaning](#c-sweettalk-meaning) |
| Entity | `entity`, which lives inside one aggregate and is saved with it. | [Declare aggregates and entities](#c-sweettalk-aggregates) |
| Value object | `value`: a number or a string with its bounds, or a value with parts, stored one column per part (`<attribute>_<part>`). | [Name the values](#c-sweettalk-values), [values with parts](#c-sweettalk-richer-values) |
| Aggregate | `aggregate`, a root with an id that only its commands change. Its entities reach the database only through it: a context that names `Rows` does not compile. | [Declare aggregates and entities](#c-sweettalk-aggregates), [commands](#c-sweettalk-commands) |
| Repository | The aggregate’s own `create`, `find`, `find?` and `all`, and the queries `finds` and `counts` declare: filtered by attributes, states and specifications, sorted with `order:`, limited with `first:`, or narrowed by a block that never names `Rows` and always returns aggregates. | [Find, count and retire aggregates](#c-sweettalk-queries) |
| Factory | `factory`. | [Make aggregates with factories](#c-sweettalk-factories) |
| Domain service | `service`, which changes at most one aggregate. | [Name operations with services](#c-sweettalk-services) |
| Domain event | `event` and `emit`. Each event records who acted and what caused it. | [Follow events with policies](#c-sweettalk-events), [Record who acted](#c-sweettalk-metadata) |
| Event handler (policy) | `whenever`, run as a Cold Brew job. | [Follow events with policies](#c-sweettalk-events) |
| Side-effect-free function | `the`, a derived value computed on every read, and plain Crystal methods in an aggregate’s or an entity’s body. | [Guard the lifecycle and the invariants](#c-sweettalk-lifecycle) |
| Specification | `specification`, a rule stated once in `where:` and read both in Crystal, as a predicate such as `order.astray?`, and in PostgreSQL, by `satisfying:`. | [Name rules with specifications](#c-sweettalk-specifications) |
| Lifecycle (state machine) | `moves`, checked in Crystal and held in PostgreSQL by a `CHECK` constraint on the state column. A PostgreSQL enum type is not used, because `ALTER TYPE` cannot drop a value. | [Guard the lifecycle and the invariants](#c-sweettalk-lifecycle) |
| Process manager or saga | `process`, with `deadline` and `compensate`. | [Run processes](#c-sweettalk-processes) |
| Read model | `projection`, queried with `finds` and `counts`. | [Keep read models](#c-sweettalk-projections) |
| Transactional outbox | Built in: a command enqueues its policies’, projections’ and processes’ jobs in its own transaction, and publishes its notification with `pg_notify`, which PostgreSQL delivers when that transaction commits. | [Follow events with policies](#c-sweettalk-events) |
| Conformist | `follows:`, which adopts another context’s types as they are. | [Draw the contexts](#c-sweettalk-contexts) |
| Anticorruption layer | `border Other`, which translates another context’s events, values and ids into this one’s. Code in it may also read `Other::` directly, or call `Other.price_of`, which draws a dependency edge. `border Cards, outside: "…"` is the border with a system outside the program, the only code that may name `Caramel::Outbound` or `HTTP::Client`, a check on the code as written. | [Draw the contexts](#c-sweettalk-contexts), [Translate outside systems at a border](#c-sweettalk-outside) |
| Open-host service | The services a context lists in `publishes`: in one binary, a set of calls other contexts may make. | [Publish a language](#c-sweettalk-published) |
| Published language | `publishes`, the types and services other contexts may name; any other name of the context does not compile outside it. | [Publish a language](#c-sweettalk-published) |
| Shared kernel | Not planned. `central: true` is tenancy, not a shared kernel. | [Share a domain between tenants](#c-sweettalk-tenancy) |
| Partnership | Not planned. Two contexts may react to each other’s events, but their dependency edges may not form a cycle. | [Draw the contexts](#c-sweettalk-contexts) |
| Customer/supplier | Not planned. A supplier’s promise to its customers is what it `publishes`. | [Publish a language](#c-sweettalk-published) |
| Distillation (core, supporting and generic subdomains) | `subdomain:` on `context`, carried by every glossary term. The label changes no rule the compiler checks. | [Mark the core domain](#c-sweettalk-subdomains) |
| Event sourcing | Not planned. State lives in rows, and there is no event log. | [Not covered yet](#c-sweettalk-limits) |

Some differences from the patterns as usually described are deliberate:

- **The repository lives on the aggregate.** The aggregate already meets the repository’s rules: it reaches roots only, offers a collection’s interface (`create`, `find`, `find?`, `all`), and names its queries in domain terms with `finds`, whose keys are attributes and states the compiler checks, never SQL or SugarORM’s query syntax; a separate repository word would add a second name for the same thing (ADR 0030 decision 2, ADR 0031 decision 3).
- **One aggregate per transaction, services included.** A command, a service, a policy and a process step each change at most one aggregate, so each lock and each invariant stays its aggregate’s own; work across aggregates is a process, or a policy that reacts to an event (ADR 0030 decision 5, ADR 0031 decision 5).
- **Events belong to their aggregate.** An aggregate emits only its own events and an entity emits none, because the aggregate guards the invariants its entities share; an entity changes through its aggregate’s commands (ADR 0030 decision 2).
- **Contexts are modules of one binary.** Contexts call each other in the same process and react to each other’s events through Cold Brew jobs, so one machine stays enough and there is no RPC or HTTP transport between them (ADR 0030, Reasons).
- **`central: true` is tenancy.** It shares a context’s rows between the tenants of a multi-tenant application; it shares no types between contexts, so it is not a shared kernel (ADR 0033 decision 2).
- **State lives in rows.** An event drives its policies, projections and processes and is not kept, because SweetTalk expands into SugarORM tables and keeps state in PostgreSQL; there is no event store, and none is planned; [Not covered yet](#c-sweettalk-limits) says what that leaves out (ADR 0030 decisions 4 and 6).

Specs run the domain against real PostgreSQL. Each Corretto example rolls back, and `drain_queue!` runs the jobs a command enqueued at once, so a spec of a policy, a projection or a process waits for no worker.

## Give every noun a meaning {#c-sweettalk-meaning}

Every context, value, aggregate, entity, event, projection, specification, service and process carries `means:`. A noun without one does not compile, and `SweetTalk.glossary` lists every entry with its kind, its context and that context’s subdomain, so the ubiquitous language is part of the program. The same word may mean different things in two contexts: Catalogue’s `Tins` is “a count of tins on the shelf”, and Fulfilment’s is “tins of one tea packed in a parcel”.

## Draw the contexts {#c-sweettalk-contexts}

A `context` is a bounded context: a module with its own vocabulary. `follows:` adopts another context’s types as they are. A `border` is the one place where a context may name a context it does not follow, and it translates that context’s values and ids into its own. Here each context reacts to the other’s event:

**tea_shop.cr · two contexts**

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

The context map is checked when the program compiles. `follows: B` draws a dependency edge to B, and so does anything in `border B` other than the event a `whenever` names; reacting to one of B’s events draws an event edge. A context names `B::`, or calls `B.price_of`, anywhere when it follows B, and only inside `border B` otherwise; a call in a border draws a dependency edge too. A foreign name anywhere else, an edge to an unknown context, or a cycle of dependency edges stops the build, for example with “Shop::Ordering names Catalogue:: outside a border: move that code into border Catalogue do … end, or declare follows: Catalogue”. So Ordering and Fulfilment may react to each other’s events, but may not follow each other. `SweetTalk.context_map` returns the edges.

## Mark the core domain {#c-sweettalk-subdomains}

`subdomain:` on a context says which part of the business it serves: `:core` for what sets the business apart, `:supporting` for what the core needs but could be built by anyone, and `:generic` for a problem many businesses share. It is optional and changes no rule, because no check can measure how carefully a core is modelled. Every glossary term carries its context’s subdomain, so `SweetTalk.glossary.select { |term| term.subdomain == "core" }` lists the core domain’s language. Any other value does not compile.

**tea_house.cr · subdomains**

```crystal
context Pricing, subdomain: :supporting, means: "what each tea costs" do
  # …
end

context Billing, follows: Pricing, subdomain: :core,
  means: "charging members for their teas" do
  # …
end
```

## Publish a language {#c-sweettalk-published}

An upstream context can promise less than all of its model. `publishes` lists the types and services other contexts may name: its published language, and, in one binary, its open-host service. Naming a type publishes what it contains, so publishing `Tea` would publish `Tea::Id` and its commands too. Once a context publishes, every other context names only those, whether it follows the context or reads it in a border; its events stay open to every context that may name it, because a follower reacts to them and a reaction depends on an event’s fields. `publishes` comes after the names it lists. A context that does not publish keeps the rules above.

**tea_house.cr · a published language**

```crystal
context Pricing, subdomain: :supporting, means: "what each tea costs" do
  value Cents, Int64, at_least: 0, means: "an amount of money"

  aggregate Tea, means: "one tea and its price" do
    # …
  end

  service price_of(tea : Tea::Id), returns: Cents, means: "what one tea costs today" do
    Tea.find(tea).price
  end

  publishes Cents, Tea::Id, price_of
end

context Billing, follows: Pricing, subdomain: :core,
  means: "charging members for their teas" do
  service bill(tea : Pricing::Tea::Id), returns: Bill::Id,
    means: "bill a member for one tea at today's price" do
    Bill.open(Pricing.price_of(tea)).id
  end
end
```

A name the publisher leaves out stops the build at the line that names it, for example with “TeaHouse::Insurance names Pricing::Tea, which Pricing does not publish; it publishes Cents, Tea::Id, price_of: use one of those, or publish Tea in Pricing”. When the publisher is declared after the context that names it, the program’s checks find the name instead, without a line.

## Translate outside systems at a border {#c-sweettalk-outside}

A payment gateway or a carrier has a model of its own. `border Cards, outside: "…"` declares a module `Cards` in the context: the only code in it that may name `Caramel::Outbound` or `HTTP::Client`, and the place that turns the system’s answers into the context’s values and refusals. The check reads the code as written, as the `Rows::` and `Other::` checks do, so an alias or a method defined outside the context escapes it. `outside:` is the line its glossary entry shows, and the context map gains an `outside` edge. An outside system emits no events, so the border holds no `whenever`; a webhook arrives through an action, which runs a command. Call the system from a `whenever`, after the command that needs it commits, so that a slow answer never holds an aggregate’s row lock. Specs fake it at the wire with `Corretto.stub_wire`, as the Corretto guide’s “Fake third parties at the wire” shows.

**tea_house.cr · an outside system**

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

  def self.charge(bill : Int64, amount : Pricing::Cents) : Reference
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

## Name the values {#c-sweettalk-values}

**tea_shop.cr · values**

```crystal
value Tins, Int32, at_least: 0, means: "a count of tins on the shelf"
value Cents, Int64, at_least: 0, means: "an amount of money"
value Quantity, Int32, within: 1..10, means: "tins of one tea in one order"
```

A value wraps an `Int32`, an `Int64` or a `String`, or has parts. An integer value takes `at_least:`, `at_most:`, `within:` and `times:`. It is validated when it is built and by every arithmetic result, so `@stock -= tins` refuses to go below zero with “Tins must be at least 0”. `+` and `-` take the same value or an integer, and `*` takes an integer: tins plus cents does not compile. `times: Quantity` on `Cents` would let `*` take a quantity. A value is stored as a column of its raw type and rebuilt, and so validated again, when it is loaded.

PostgreSQL checks the bounds too. Every column that stores `Tins` gets a `CHECK` constraint, such as `check_catalogue_teas_stock`, so a write that goes around SweetTalk, through SQL or another service, is refused when it is written. Bounds are therefore integer literals. `database_check: false` keeps a value’s bounds in Crystal only, where they may name a constant.

## Name strings and values with parts {#c-sweettalk-richer-values}

**tea_shop.cr · string and composite values**

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

A string value takes `matches:` and `length:`, and has no arithmetic. `Email.new("ada")` refuses with “Email must match /\A[^@\s]+@[^@\s]+\z/” before anything is written. It is stored as a text column. Its length is a `CHECK` constraint too, `check_ordering_orders_receipt_to_length_3_254`; its pattern is checked in Crystal only, because PostgreSQL reads regular expressions differently.

A value with parts is built with one keyword per part, as in `Address.new(street: "1 Leaf Lane", city: "Camellia", postcode: Postcode.new("CA1 1TE"))`. It checks its `never` and `always` when it is built, and equals another address with the same parts. A part is a column type or a value that wraps one. `has deliver_to : Address` stores one column per part: `deliver_to_street`, `deliver_to_city` and `deliver_to_postcode`. A part’s value brings its constraints to its column.

## Declare aggregates and entities {#c-sweettalk-aggregates}

An aggregate is a root with an id, such as `Order::Id`, and a repository: `find`, `find?`, `all`, and `create` unless it has a factory. An entity lives inside one aggregate and is saved with it. Given to another aggregate’s `create` or factory, it is stored again as that aggregate’s own row, and the first aggregate keeps its own.

**tea_shop.cr · an aggregate**

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

- `String`, `Int32`, `Int64`, `Bool`, `Float64` or `Time` is a column.
- A value that wraps a number or a string is a column of its raw type.
- A value with parts is one column per part.
- Another aggregate is a foreign key, and its getter returns that aggregate’s id: `line.tea` is a `Catalogue::Tea::Id`. Load the tea with `Catalogue::Tea.find` when you need it.
- One of the application’s own SugarORM schemas, as in `has member : Account`, is a foreign key too. Its getter returns a `SweetTalk::RecordId(Account)`, and `order.member.load` reads the account.
- An `Array` of the aggregate’s own entity is a child table, loaded with `preload`.

`has name : Type = expression` gives an attribute a default, as in `has held : Tins = Tins.zero`. The column gets a SQL default when the expression is a literal, as in `has late_parcel : Bool = false`.

Any other type does not compile; a `Hash` is refused with a pointer to the entity form. The schemas live in each context’s `Rows` module, and a context that names `Rows` does not compile, so every change goes through a command. Table names take English plurals. The tea shop’s tables are `catalogue_teas`, `ordering_orders`, `ordering_order_lines`, `ordering_sales`, `ordering_holds`, `fulfilment_parcels` and `fulfilment_parcel_packings`. They are ordinary schemas, so `frappe db diff` derives their migrations.

## Guard the lifecycle and the invariants {#c-sweettalk-lifecycle}

`moves` lists one or more chains of states, and the first state is the initial one. `moves open >> placed >> shipped, open >> cancelled, placed >> cancelled` stores the state and adds `open?`, `placed?`, `shipped?` and `cancelled?`, and the private movers `placed!`, `shipped!` and `cancelled!`. A mover refuses unless the current state comes just before it in a chain: “Order cannot become shipped while cancelled”. `never` refuses a command that leaves its condition true, and `always` one that leaves it false. `the` is a derived value, computed on every read and never stored.

PostgreSQL holds the lifecycle too. The `state` column stores each state as `moves` spells it, such as `out_for_delivery`, and a `CHECK` constraint such as `check_ordering_orders_state_ef9524ce` refuses any other text, so a write around SweetTalk cannot leave a row no state names. The eight hex digits change with the list of states, so `frappe db diff` replaces the constraint when you add or remove one, and `frappe migrate` stops, naming the constraint, while a row still holds a state you removed.

## Change state with commands {#c-sweettalk-commands}

`to verb(arg : Type) do … end` is a command, and it runs as one transaction:

1. load the aggregate with its row locked through SugarORM’s `lock`, so commands on one aggregate run one after another and the body sees the last committed state;
2. run the body;
3. check every `never` and `always`;
4. save the root through its changeset, then its entities;
5. dispatch the queued events.

`refuse "message"` raises `SweetTalk::Refusal`. The transaction rolls back and the aggregate reloads what is stored, so neither the table nor the object keeps half a change. `create` and a factory check the invariants before they insert. Each command, factory and service is a `domain` span in its trace, named like `Ordering::Order#place`; a refused one is marked failed.

A command changes one aggregate. Running another aggregate’s command, a `create` or a factory while a command runs raises `SweetTalk::Boundary` and rolls the command back. A command may read another aggregate it is given: `add` copies the tea’s price into the line, so repricing the tea later does not change the order.

## Make aggregates with factories {#c-sweettalk-factories}

`factory verb(args) do … end` makes an aggregate. Arguments named like attributes set them, and the body runs as the aggregate’s first change and may `emit`. The aggregate is checked, saved and its events dispatched in one transaction, and each event names the new aggregate’s id.

**tea_shop.cr · a factory**

```crystal
factory open(member : Account, receipt_to : Email, deliver_to : Address) do
  emit Opened, receipt_to: receipt_to
end
```

`Ordering::Order.open(account, Email.new("ada@example.com"), address)` opens an order. An aggregate with a factory has no `create`, so every order starts with `Opened`. A factory that leaves an attribute unset, when no default covers it, does not compile, and neither does one named like a repository method, such as `factory find`.

## Find, count and retire aggregates {#c-sweettalk-queries}

**tea_shop.cr · queries and a removal**

```crystal
finds placed_for(member : Account), where: {member: member, state: :placed}
finds newest_for(member : Account, count : Int32), where: {member: member},
  order: {id: :desc}, first: count
counts placed_count_for(member : Account), where: {member: member, state: :placed}

to forget do
  refuse "Only a cancelled order can be forgotten." unless cancelled?
  remove
end
```

The aggregate is its own repository: `find`, `find?`, `all`, `create` or its factory, and the queries it declares. `finds` defines a query that returns aggregates. `where:` keeps the ones whose columns equal the expressions: a list matches any of its members and a range its span, and `state:` takes a state or a list of states. `satisfying:` adds a specification. `order: {placed_on: :desc}` sorts by `id` or by attributes stored in one column, and id breaks ties; `first:` returns at most that many. Each part is optional, but a `finds` gives at least one. `counts` takes `where:` and `satisfying:` and returns how many, in one statement, without loading them.

A context checks every query when it closes, whether or not anything calls it: a key, a state or an order the aggregate lacks, a list of entities, a value of the wrong type or an argument `finds` does not take does not compile.

When a query needs more than that, give `finds` a block instead. It gets the aggregate’s live rows, with removed ones and other tenants’ already left out, and narrows them with SugarORM’s `where`, `where_null`, `order_by`, `limit` and `offset`; the aggregates are built from what it returns, so a caller cannot tell the two kinds apart. It is the one place a column name or a SQL fragment appears in a domain, so keep it for what `where:` cannot say. It reads only: it cannot count, lock, delete or name `Rows` or SugarORM.

**tea_shop.cr · a query with a block**

```crystal
finds holding(tea : Catalogue::Tea::Id) do |orders|
  orders.where("id IN (SELECT order_id FROM ordering_order_lines WHERE tea_id = ?)", tea.raw)
end
```

`find`, `find?`, `all` and every `finds` read one statement per table: the roots, then each list of entities through `preload`. So `placed_for` runs two queries however many orders it returns. Code outside the domain, such as an action, reads through these queries too, and does not name `Rows`.

`remove` in a command retires the aggregate. Its row stays with `removed_at` set, so the lines and projection rows that name it stay valid. `find`, `find?`, `all`, every query and the command’s row lock skip it: `find` raises “There is no Order 7.”.

## Name rules with specifications {#c-sweettalk-specifications}

A specification is a rule an aggregate satisfies or not, stated once and read twice: by Crystal on an aggregate in memory, and by PostgreSQL in a query. It lives in the context, after its aggregate, and joins the glossary.

**tea_shop.cr · a specification**

```crystal
specification Astray, on: Order, where: {state: :cancelled, late_parcel: true},
  means: "a cancelled order whose parcel left anyway"

to forget do
  refuse "Only a cancelled order can be forgotten." unless cancelled?
  refuse "An order whose parcel left cannot be forgotten." if astray?
  remove
end
```

`Astray` adds `order.astray?`, for `never`, `always`, guards and methods, and `Ordering::Astray.satisfied_by?(order)`. `Order.all(satisfying: Astray)` reads the same rule in one query, and so does `satisfying: Astray` on a `finds` or a `counts`. `where:` takes what `finds` takes, or earlier specifications on the same aggregate joined by `&`, `|` and `!`, as in `where: Dispatchable & !Astray`. In PostgreSQL `!` reads as `IS NOT TRUE`, so an order whose column is NULL fails a rule and passes its negation in both.

A rule PostgreSQL cannot read stays a `never`, an `always` or a method: one over a list of entities, such as `lines.empty?`, or over a derived value made with `the`. A specification takes no arguments; a `finds` takes them, and adds a specification with `satisfying:`.

## Name operations with services {#c-sweettalk-services}

A service is an operation that belongs to no one aggregate. It lives in a context, carries `means:` and joins the glossary.

**tea_shop.cr · a service**

```crystal
service requote(order : Order::Id), returns: Catalogue::Cents,
  means: "what an order would cost at today's prices" do
  Order.find(order).lines.sum do |line|
    Catalogue::Tea.find(line.tea).price * line.quantity.to_i
  end
end
```

Call it on its context: `Ordering.requote(order.id)`. `returns:` defaults to `Nil`. A service runs in one transaction and changes at most one aggregate: a second raises `SweetTalk::Boundary` and rolls both back. To change two, emit an event and react to it in a `whenever`. A `service` anywhere but a context does not compile.

## Follow events with policies {#c-sweettalk-events}

`event` declares one of the aggregate’s events, and `emit` queues one from a command with its facts; an aggregate emits only its own. An event holds its subject’s id (`placed.order_id`) and its fields as they were when it was emitted: column types, values, ids and an `Array` of the aggregate’s entity. No getter on an event loads an aggregate, so a handler reads what happened, not what is true now.

`whenever` in a context or a border is a policy, run as a Cold Brew job. The command enqueues one job per policy in its own transaction, so a job is never lost and never sent for a rolled-back change. A handler changes one aggregate too. With `each:` it runs once per element of a list in the event, each in its own job: the `Sales` projection below counts one order line per job.

- A job carries the event as JSON. When one line’s job fails, the other lines’ jobs still run.
- A job is named after its owner (a context and its border, a projection or a process) and the event, never after a line, because `caramel_jobs` stores the name. Two `whenever` blocks for one event in one owner do not compile. Nor does a rename whose old job name another job has or claims.
- A refusal, or a handler that changes a second aggregate, fails its job at the first attempt, unless a `compensate` answers the refusal; other errors follow Cold Brew’s retry rules. The command that emitted the event stays committed.
- The command also publishes `{"subject": id}` on `sweettalk.CONTEXT.AGGREGATE.EVENT` for live pages, delivered on commit and at most once.

## Record who acted {#c-sweettalk-metadata}

Every event records `event_id`, a UUID, `occurred_at`, `actor`, a `String?`, `cause_id`, the event whose handler emitted it, and `flow_id`, shared by every event one command leads to: the request’s trace id when it ran in one. Its jobs carry all five. No command takes an actor: wrap the call in `SweetTalk.acting` instead.

**Inside an action · order is a loaded Ordering::Order**

```crystal
SweetTalk.acting("member:7") { order.place }
```

Each policy, compensation and process step runs as its event’s actor, so the `Cancelled` event a refused hold leads to still names `member:7`. A deadline acts as `deadline Hold.lapse`. A field named `event_id`, `occurred_at`, `actor`, `cause_id`, `flow_id` or like the subject’s id does not compile.

A field may be nilable. `cancel` without a reason sends `reason` as JSON null:

**tea_shop.cr · a nilable fact**

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

A union of other types, such as `String | Int32`, does not compile.

A retried job carries the same `event_id`. A handler that sends mail or calls an API can key that side effect on it, so a retry can tell the side effect already happened.

## Keep read models {#c-sweettalk-projections}

A projection is a table with one row per key. Inside a `whenever` block, `Sales[tea]` reads the row locked and saves it when the handler returns. When the row is missing, an upsert on the key’s unique index inserts it with its defaults, so two handlers that insert one key at once keep one row.

**tea_shop.cr · a projection**

```crystal
projection Sales, means: "tins sold of one tea" do
  key tea : Catalogue::Tea
  has sold : Int32 = 0

  whenever Order::Placed, each: :lines do |placed, line|
    Sales[line.tea].sold += line.quantity.to_i
  end
end
```

A projection declares queries as an aggregate does. `finds` takes `where:`, `order:` and `first:`, or a block that narrows its rows, and `counts` takes `where:`. The keys are the projection’s attributes, its key included: `where: {tea: tea}` compares the tea’s id. A projection has no lifecycle and no specifications, so it takes neither `state:` nor `satisfying:`, and every row counts, since a projection removes none.

**tea_shop.cr · projection queries**

```crystal
finds best_sellers(count : Int32), order: {sold: :desc}, first: count
counts sold_any, where: {sold: 1..}
```

`Sales.best_sellers(10)` reads the ten best-selling teas in one statement, and `Sales.sold_any` counts the teas that sold at least one tin without loading them.

## Run processes with deadlines and compensation {#c-sweettalk-processes}

A process is a workflow across aggregates. It keeps one row per `key`, with attributes, a lifecycle and deadlines, in a table such as `ordering_holds`. `Hold` holds the tins of one tea for one placed order until the parcel leaves, and gives them back when the order is cancelled or the parcel is late.

**tea_shop.cr · a process**

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

- `whenever Event, key: expression` is a step. Its job inserts the row when it is missing, locks it and runs the block on it. A step changes at most one aggregate; its own row does not count. Attributes other than the key are nilable or have a literal default, because a row starts from its key alone.
- A process may react to another context’s events outside a border. `Hold` follows `Fulfilment::Parcel::Dispatched`, which draws an event edge from Ordering to Fulfilment.
- `compensate` runs when its `whenever` is refused. The handler’s work has already rolled back; the compensation gets the same arguments and the refusal, and runs in its own transaction. Here a tea that cannot be held cancels its order with “Only 1 tins of Gyokuro free.”. A refusal in the compensation fails the job. A context or a border may compensate its own `whenever` too: Ordering’s border notes a parcel that left after its order was cancelled.
- `arm lapse` sets `lapse_due` and enqueues a job for that time, and `disarm lapse` clears it. Cold Brew cannot cancel a job, so every arm and disarm counts up an arming counter: a stale deadline job finds a newer arming and does nothing.

`arm lapse, after: 2.days` arms the deadline for another span than its own.

## Rename without moving data {#c-sweettalk-renames}

A name SweetTalk stores, such as a table, a channel or a job name, comes from a domain name. When the model finds a better word, `renamed_from:` keeps the table and the channel the old name used, so no data moves.

**tea_shop.cr · a renamed aggregate**

```crystal
aggregate Blend, renamed_from: Tea, means: "one tea we sell" do
  # still stored in catalogue_teas, still announced on sweettalk.catalogue.tea.*
end
```

A job’s name follows its owner and the event’s path as written. When a rename changes it, SweetTalk declares Cold Brew’s `renamed_from` on the job with the old name, so jobs queued before the rename keep running.

These are the names SweetTalk stores, which a deployed application depends on: tables such as `ordering_orders` and `ordering_order_lines`, with their `check_…`, `index_…` and `fk_…` names; job class names such as `TeaShop::Ordering::Sales::WhenOrderPlaced` and `TeaShop::Ordering::Hold::LapseDeadline`; channels `sweettalk.<context>.<aggregate>.<event>`, behind a tenant’s `t<id>:` prefix; and the event metadata keys `id`, `at`, `by`, `cause` and `flow`. `renamed_from:` keeps a table, a channel and queued jobs across a rename. While SweetTalk is experimental, a minor release may still change any of these names.

## Share a domain between tenants {#c-sweettalk-tenancy}

In a multi-tenant application, name the tenant model before the first context. It is the model the routes’ `tenant` block names, and SugarORM refuses another.

**tenant_shop.cr · a domain shared by tenants**

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
    # aggregates, projections and processes that belong to one tenant
  end
end
```

Every context belongs to the tenant unless it says `central: true`. Its aggregates, entities, projections and processes get a column named after the model, `account_id` here, and SugarORM scopes their reads, locks, keys and upserts by the bound tenant, so a projection or a process keeps one row per tenant per key. A policy, projection or process step runs in the tenant its event was emitted in, a deadline in the tenant that armed it, and a notification goes out on the tenant’s channel. A central context’s rows are shared by every tenant.

A tenanted aggregate may reference a central one, as an order line names a shared tea. The rest of these do not compile:

- a domain without `tenant` in a program that requires `caramel/tenancy`, or `tenant` without that require, after a context, twice, or naming anything but a SugarORM schema;
- `central:` with anything but `true`, or without `caramel/tenancy`;
- a `has` in a central context that points at a tenanted aggregate or a tenanted schema of the application, whose rows every tenant would then see;
- a `whenever` in a tenanted context for a central context’s event, which carries no tenant; a central context may follow a tenanted one’s events, and its handler runs in the event’s tenant;
- an event channel over 42 characters, which leaves 21 for a tenant’s `t<id>:` prefix, or a tenant index name over PostgreSQL’s 63 bytes;
- a `has` that would store `account_id`, or an entity of an aggregate named like the tenant model.

A domain that already holds data follows Add tenancy to existing data in the multi-tenancy guide; `frappe db diff` names every SweetTalk table it halts on. [Read the multi-tenancy guide](https://caramelize.dev/docs/0.14.0/multi-tenancy/index.md)

## Call the domain from actions {#c-sweettalk-actions}

An action’s contract may declare a value or an aggregate’s id as a field. The field binds from the type the value wraps, with that type’s grammar and JSON type, and the value’s refusal becomes the field’s error, so a form shows it beside its input.

**app/actions/orders/add_line.cr**

```crystal
struct AddLine < App::ApplicationAction
  contract do
    field order : Shop::Ordering::Order::Id
    field tea : Shop::Catalogue::Tea::Id
    field quantity : Shop::Ordering::Quantity
  end

  def handle(contract : Contract)
    order = Shop::Ordering::Order.find(contract.order)
    order.add(Shop::Catalogue::Tea.find(contract.tea), contract.quantity)
    redirect_to("/orders/#{order.id}")
  end
end
```

With the route `post "/orders/:order/lines", AddLine`, `quantity=11` answers 422 with `quantity: Quantity must be between 1 and 10` before `handle` runs. An id binds from an `Int64` and may bind a route parameter, as `:order` does; `/orders/abc/lines` answers 404. A value with parts is not a field: declare one field per part and build the value in `handle`. The contract reference says what else a field value may take.

A refusal that `handle` does not rescue answers 422 the way a failed contract does, with its message under `_base`. A JSON client gets `{"errors": {"_base": ["Teas can be added only while the order is open."]}}`. A browser or an htmx request gets `contract_failure_page(contract)`, so a form that re-renders itself on a failed contract shows the refusal too. Any other client gets plain text that starts with `ERR INVALID:422`. Override `render_refusal(contract, refusal)` to answer otherwise. `SweetTalk::Missing`, which `find` raises for an id that names no aggregate, answers 404. Neither is reported to Crema as an error. `SweetTalk::Boundary` is a mistake in the code, and answers 500.

[Read the contract reference →](https://caramelize.dev/docs/0.14.0/routes-and-contracts/index.md)

## What does not compile {#c-sweettalk-refusals}

Each mistake below stops the build with a message that names the sentence and its fix:

- a noun without `means:`;
- a `subdomain:` other than `:core`, `:supporting` or `:generic`;
- a foreign name or call outside a border, a border or `follows:` to an unknown context, or a cycle of dependency edges;
- a name or call another context does not publish, or a `publishes` of a name the context does not declare;
- `Caramel::Outbound` or `HTTP::Client` outside a border with an outside system, or such a border named like a context or holding a `whenever`;
- `emit` of another aggregate’s event;
- a mover the lifecycle does not declare;
- a lifecycle whose check name would pass PostgreSQL’s 63 bytes;
- `the` without a type;
- a value that wraps anything but `Int32`, `Int64` or `String`, or has no parts;
- a bound that is not an integer literal, unless the value takes `database_check: false`;
- two different values mixed in arithmetic without `times:`;
- `whenever` inside an aggregate;
- `has` with a type that cannot be stored, or whose constraint or index name would pass PostgreSQL’s 63 bytes;
- an event whose channel would pass PostgreSQL’s 63 characters;
- two declarations whose names give one table;
- a context that names `Rows`;
- a projection or a process without `key`, or a process step without `key:`;
- two `whenever` blocks for one event in one place;
- a factory that leaves an attribute unset;
- a query on an unknown attribute, state or order, with an argument `finds` does not take, or whose block does more than narrow its rows;
- a specification on an unknown attribute or state, on a list of entities or a derived value, with a block, outside a context, or whose predicate the aggregate already has;
- a `compensate` without its `whenever`;
- a `deadline` outside a process;
- an event field named like its metadata;
- with `caramel/tenancy`, the mistakes listed under Share a domain between tenants.

## Not covered yet {#c-sweettalk-limits}

SweetTalk covers the domain. Resources, representations and guards for the web are not part of it. String patterns and the `never` rules of values and aggregates are checked in Crystal only. Refusal messages are the domain’s English, even with `caramel/i18n`.

There is no event log: a projection keeps its rows, not the events that built them, so a projection added later starts empty and cannot be rebuilt from past events. A process’s rows are never removed, so its table grows with every key it has seen.

[Read the Cold Brew reference →](https://caramelize.dev/docs/0.14.0/cold-brew/index.md)

Caramel 0.14.0 · https://caramelize.dev/docs/0.14.0/sweettalk/
