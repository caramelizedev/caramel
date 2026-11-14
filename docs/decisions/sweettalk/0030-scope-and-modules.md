# ADR 0030: SweetTalk is an opt-in language for Domain-Driven Design, written as macros over SugarORM and Cold Brew and checked across the whole program

Date: 2026-10-08

Status: accepted.

## Context

An application with a rich domain assembles Domain-Driven Design by hand from schemas, changesets, actions and jobs. No word names a bounded context, an invariant, a domain event or a policy, and nothing stops one context from reaching into another's types.

Two further things needed a rule:

- **Modules.** Every SweetTalk word ships to every program that requires `caramel/sweet_talk`. Some words bring a dependency, some serve one family of domains, and some add a strictness other domains would read as noise. Five requires followed an unwritten rule: i18n ([ADR 0024](../0024-internationalization.md)), tenancy ([ADR 0025](../0025-tenancy.md)), the recorder and OTLP ([ADR 0027](../0027-crema.md)) and decimal values ([ADR 0040](0040-values.md)). Nothing said when the next word gets a require of its own.
- **Files.** A context declared by one `context Name … do … end` block is one file, and a context with a dozen aggregates is a file of several hundred lines. The macro reads its block once and keeps what the whole-program checks read: its text, the events it reacts to, what it publishes and its borders. Reopening the context's module in another file compiles, but escapes every check: the context map reads only the text the block kept.

## Decision

The rules an application relies on are stated on the website ([site.html](../../../website/source/site.html)), chiefly its SweetTalk guide, in the sections cited below by anchor, and in the doc comments under [src/caramel/sweet_talk](../../../src/caramel/sweet_talk). This record states what was chosen for SweetTalk as a whole; each family of words has a record of its own, named in the second entry.

1. **`require "caramel/sweet_talk"` is the way in, and `include SweetTalk` scopes the words.** A plain application compiles none of SweetTalk. A module that includes `SweetTalk` may use `context` and `within`, and a context's body the other words. No word is a top-level macro. A module's words come by the module's own require (the module entries below). `frappe make domain NAME CONTEXT --means=TEXT` starts a domain in `app/domain/`, required after the models; what it writes is in `site#c-sweettalk-enable` and `site#c-commands-frappe`. In a program that requires `caramel/tenancy` the domain also names its tenant ([ADR 0033](0033-framework-boundary.md)). The application's lint rule set excludes `app/domain/**` from `Lint/UnusedArgument` ([ADR 0017](../0017-style-and-checks.md)): a SweetTalk block's parameters name what the handler the macro writes receives, and a process step's `key:` reads them outside the block.
2. **Each word is a macro, and each family of words has its record.** This record owns `context` as a declaration, `within`, `means:`, `renamed_from:` and the modules. The other rules are stated once, by their owners:
   - **Contexts and their relations.** `context Name, follows: Other, means: "…" do … end` is a bounded context, a module. `follows:`, `border`, `publishes`, kernels, subdomains and outside systems: [ADR 0036](0036-strategic-design.md).
   - **Values.** `value` and its arithmetic: [ADR 0040](0040-values.md). Money: [ADR 0063](0063-money.md).
   - **Aggregates.** `aggregate`, `entity`, `has`, `the`, the repository, factories, and the lifecycle and invariants (`moves`, `never`, `always`): [ADR 0039](0039-aggregates.md). `unique`, `index`, `check` and the constraints the database holds: [ADR 0045](0045-database-constraints.md).
   - **Commands.** `to`, `refuse`, services and units: [ADR 0046](0046-transactions.md). `preview` and `commit`: [ADR 0060](0060-preview-and-commit.md).
   - **Events.** `event`, `emit`, the policies `whenever` declares, and projections with their `key`: [ADR 0041](0041-events.md). The event log: [ADR 0048](0048-event-log.md).
   - **Processes.** `process`, `deadline` and `compensate`: [ADR 0031](0031-processes.md).
   - **Reads and rules.** Specifications, `finds`, `counts`, sums and groups, calculations and requirements: [ADR 0035](0035-reads-and-rules.md).
   - **The framework's boundary.** Refusals in actions, tenancy and id types: [ADR 0033](0033-framework-boundary.md).

   `frappe words` prints this vocabulary from the macros that define it ([ADR 0013](../0013-frappe.md), `site#c-sweettalk-words`). Every SweetTalk macro, and each method an author calls as a word, carries a block of tags in its doc comment: `@word KIND | summary`, `@usage`, one `@option NAME | forms | default | what it does` for each parameter with a default or `@internal` for one authors never write, `@guide` and a compiling `@example` (the tags are in `Caramel::Frappe::WordDoc`). A refusing macro, whose body only raises, has none.
3. **Every noun carries its meaning, and the program lists them.** A declaration that names a concept takes `means: "…"`, and one without it does not compile. `SweetTalk.glossary` lists each with its kind and its context. The nouns that carry it are listed in `site#c-sweettalk-meaning`; the entry's shape is `SweetTalk::Term`.
4. **A rename keeps what was stored.** `renamed_from: Old` on a context, aggregate, entity, event or projection keeps its table, its channel and its queued jobs, so no data moves (`site#c-sweettalk-renames`, and the `renamed_from` option of each word's doc comment). A process takes it as a projection does ([ADR 0031](0031-processes.md)). How a job is named, and how a renamed job claims its old name, is the job-name rule of [ADR 0041](0041-events.md).
5. **The context map is checked at compile time.** A context names another's types only where the map allows it, and an unknown context, a foreign name elsewhere or a cycle of dependency edges does not compile. The edges and every rule of the map are in [ADR 0036](0036-strategic-design.md).
6. **The whole-program checks run once, at the first use and at `SweetTalk.boot`.** The checks that need every declaration (the context map, the glossary, the bodies below) run at the first `find?`, dispatch or job, and at `SweetTalk.boot` (`SweetTalk.__sweettalk_checked`, `SweetTalk.boot`). `frappe make domain` writes `SweetTalk.boot` after `require "../app/domain/*"`, so `frappe check` ([ADR 0013](../0013-frappe.md)) reaches them (`site#c-sweettalk-prove`).
7. **Every body is typed, called or not.** Each `to`, `factory`, `service` and `unit` also emits `self.__sweettalk_touch_<name>`, a never-run proc literal that calls it. The checks call each of them (`SweetTalk.__sweettalk_touch`), so `crystal build --no-codegen` types each body whether or not anything calls it. A calculation's body ([ADR 0035](0035-reads-and-rules.md)) and an event's `older:` defaults ([ADR 0041](0041-events.md)) are typed the same way.
8. **`within Name do … end` continues context Name in another file.** The context is declared before it in the same domain module. `within` takes the words a context's body takes and no option: `follows:`, `shares:`, `means:`, `renamed_from:`, `central:`, `subdomain:` and `event_log:` belong to the `context` block (`within`, `site#c-sweettalk-files`).
9. **Every check reads every block of a context.**
   - The whole-program checks read the text and the events reacted to of the header and of each `within` (`SweetTalk.context_map`).
   - Each block's own statements are checked where they are written: names another context does not publish, HTTP outside an outside border, and a command, a factory or a unit that names an outside border declared by then.
   - A command, a factory or a unit that names an outside border a later block declares is refused by the whole-program check, which names its line.
   - Queries (`finds`, `counts`, `sums`, `groups`) are checked once the program's top level is complete, so a query may name a specification a later block declares.
   - The event log ([ADR 0048](0048-event-log.md)) reads the events declared in any block, and a `once_by:` unit in any block gets the operations table ([ADR 0046](0046-transactions.md)).
10. **A context publishes in one block, and has one border per other context or outside system.**
11. **A misplaced `within`, a second `publishes` and a second border do not compile.** The cases are two rows of `site#c-sweettalk-refusals`: a `within` of no context declared before it, of a kernel, or inside a context or a kernel; and `publishes` in two blocks of one context, or two borders with one context or outside system.
12. **The domain module requires its files in the order their names are used.** A word resolves names when it expands, so the order cannot be inferred. The guide's layout is a directory per context, with a file for the `context` and a file per aggregate (`site#c-sweettalk-files`). `frappe make domain` writes one file.
13. **A word goes in a module, `require "caramel/sweet_talk/<name>"`, when at least one of three tests holds.** It brings a dependency the core lacks; it is the vocabulary of one family of domains; or it adds a check some domains would reject, attached to its own words (`site#c-sweettalk-enable`).
14. **The core model is never a module.** The core is contexts, kernels, values, aggregates, entities, events, commands, services, units, calculations, `never`, `always`, the context map and the glossary.
15. **The require is the whole opt-in.** A module requires its dependencies and the core. It has no flag and no configuration.
16. **A module's word used without its require fails compilation and names the require.** A word a module adds as a macro is a stub in the core: a macro that only raises, naming the require, which the module's file redefines (the comment that opens `src/caramel/sweet_talk/modules.cr`). The refusal rows are in `site#c-sweettalk-refusals`.
17. **A program without the require holds none of the module's code.** `scripts/check sweet-talk-compilation` builds one application per module and the same application without it, and fails when a string only the module holds is in the binary without the require, or missing with it.
18. **A module never changes what a core word means.** It adds words, and options that only its own types accept.
19. **A rule depends on what a domain declares or requires, never on `subdomain:`.** A module word that a second family of domains needs moves to the core, and its record is edited in the same change.
20. **There are two modules.**
    - `caramel/sweet_talk/decimal` ([ADR 0040](0040-values.md)): `Decimal(P, S)` values. Its dependency is GMP, through `big`.
    - `caramel/sweet_talk/money` ([ADR 0063](0063-money.md)): currencies, amounts, quotes and allocations, the vocabulary of domains that keep books. It requires `caramel/sweet_talk/decimal`.
21. **Every refusal has a fixture, and the lanes run the core alone, each module alone, and all modules together.**
    - SweetTalk's specs run against real PostgreSQL in `scripts/check integration`.
    - Every refusal the records of SweetTalk promise has a fixture in the `sweet-talk-compilation` check that must fail to compile with its message. That covers each refusal of a split context, and two more fixtures refuse a `within` that clashes with the event log's table or the operations table.
    - `scripts/check sweet-talk-compilation` compiles the `@example` of every word. `scripts/check website` fails when the guide or the skill writes an option no word takes, the guide names no word or option, or a `@guide` is no section of it (`Caramel::Frappe::WordDrift`).
    - The core alone is `sweet-talk-compilation`'s fixtures and its application without modules; all modules together are `spec/sweet_talk`, under `scripts/check integration`. A pair of modules runs on its own only when one module names the other.
    - `spec/sweet_talk/estate_spec.cr` runs a context split across files: events logged from its header and from a `within`, a `once_by:` unit declared in one, and a `finds` whose specification a later block declares.
    - `frappe-project` derives a generated domain's tables with `frappe db diff` and runs its spec in `frappe corretto`.
    - `page-boxoffice` builds the Box Office path's application and runs its specs.

## Reasons

- A compiled glossary and a checked context map turn the drift Domain-Driven Design warns about into compile errors, with macros and no reflection. Contexts are modules in one binary, so one machine stays enough.
- `require` keeps SweetTalk out of an application that does not ask for it; `include` keeps the words out of every other module.
- Expanding into SugarORM and Cold Brew keeps state in PostgreSQL and one way to migrate.
- Refactoring toward deeper insight renames concepts, but tables, channels and queued jobs keep the names they were stored under; `renamed_from:` lets the code move on.
- **Rejected: top-level words.** They would catch any `context(…)` call in an application.
- **Rejected: a separate repository.** SweetTalk expands into macro contracts that [ADR 0016](../0016-versioning-and-releases.md) does not cover.
- A require is the cheapest opt-in Crystal has: an absent file is never parsed, declares nothing and links nothing, so a program pays only for the words it asks for.
- The three tests for a module name the costs a word puts on programs that do not use it: a link-time library, a vocabulary they do not speak, a refusal they did not ask for.
- The core model is what every domain shares; a context without aggregates, or an aggregate without `never`, would not be SweetTalk.
- A flag beside a require would be a second switch for one choice, and a program could set one without the other.
- Naming the require in the compile error turns a missing line into a one-line fix, as the decimal module does for `Decimal(…)` ([ADR 0040](0040-values.md)).
- Proving absence on the built binary, not on the source, catches a module reached through a require nobody meant.
- A module that redefines a core word would make a domain's meaning depend on a line far from it. Adding words keeps every core sentence true in every program.
- Running every pair would grow the lanes with the square of the modules; two modules that do not name each other meet only through the core, which each lane already runs.
- A label measures nothing ([ADR 0036](0036-strategic-design.md) rejects rules that depend on the subdomain). What a domain declares or requires is what it uses.
- **Rejected: one require for everything.** Every program would link GMP and read every family's words in its glossary and errors.
- **Rejected: stating the module rules in the record of the decimal values.** They govern every module, and decimal is one.
- **Rejected: deciding per module.** The five requires agreed; writing the rule down keeps the next one from deciding differently by accident.
- The checks are the language: a second file that the context map cannot see would let a context name another's types without a border, and nothing would say so.
- `within` keeps the header the one place a context's options are read, so two files cannot disagree about what the context follows or where its events are logged.
- Each block keeps its own text, so a refusal in a later file still names its line, and the whole-program checks join the texts, so `follows:` used only in a later file counts.
- One `publishes` per context: a context declared between two blocks that publish would be checked against half the list.
- A query names a specification that a later block may declare, so its check waits for the whole program, as a policy's tenancy check does.
- **Rejected: reopening `module Name`.** It compiles and escapes every check.
- **Rejected: inlining files with `{{ read_file }}`.** Errors would point into the expansion, and the text checks would see one node for the whole file.
- **Rejected: a second `context Name` that merges.** One word with two meanings, and two sets of options that may conflict.
- **Rejected: `require "**"` without an order.** Names resolve when a word expands ([ADR 0046](0046-transactions.md)), and a glob orders files by name, not by use.
- **Rejected: an aggregate, a kernel or a projection across files.** Each builds its storage or its words when its block closes, and one that outgrows a file is a signal to model it again.
- **Rejected: `frappe make context`.** The guide and the skill describe the layout; a generator can follow once the layout has been used.
