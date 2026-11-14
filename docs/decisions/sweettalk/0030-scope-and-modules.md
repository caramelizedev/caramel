# ADR 0030: SweetTalk is an opt-in language for Domain-Driven Design, written as macros and checked across the whole program

Date: 2026-10-08

Status: accepted.

## Context

An application with a rich domain assembles Domain-Driven Design by hand from schemas, changesets, actions and jobs. No word names a bounded context, an invariant, a domain event or a policy, and nothing stops one context from reaching into another's types. Some words bring a dependency or serve one family of domains, and nothing said when a word gets a require of its own. A context in one block is one file of several hundred lines, and reopening its module in another file compiles but escapes every check.

## Decision

1. **SweetTalk is opt-in: a require brings it, and `include SweetTalk` scopes its words.** A plain application compiles none of it. No word is a top-level macro. What only an application with a domain needs outside its code, such as a lint exclusion and the lines that tell an agent where the domain is, arrives with the first domain; a new application carries none of it.
2. **Every word is a macro that expands into SugarORM and Cold Brew.** A context is a module in the application's one binary.
3. **Every noun carries its meaning, and the program lists them.** A declaration that names a concept without a meaning does not compile.
4. **A rename keeps what was stored.** A renamed concept names its old name, and its table, its channel and its queued jobs stay. No data moves.
5. **The context map is checked at compile time.** A context names another's types only where the map allows it ([ADR 0036](0036-strategic-design.md)).
6. **Every body is typed, called or not.** The whole-program checks reference each command, factory, service and unit body, so the compiler types it whether or not anything calls it.
7. **`within` continues a context in another file, and every check reads every block.** `within` takes no option: the `context` block is the one place a context's options are read. Each block keeps its own text, and the whole-program checks join them.
8. **A context publishes in one block, and has one border per other context or outside system.**
9. **The domain module requires its files in the order their names are used.** A word resolves names when it expands, so the order cannot be inferred.
10. **A word goes in a module, with a require of its own, when one of three tests holds.** It brings a dependency the core lacks; it is the vocabulary of one family of domains; or it adds a check some domains would reject. The core model is never a module. Decimal values ([ADR 0040](0040-values.md)) and money ([ADR 0063](0063-money.md)) are the modules.
11. **The require is the whole opt-in.** A module has no flag and no configuration. A program without the require holds none of the module's code, and a module's word used without it fails compilation and names the require. Absence is proven on the built binary.
12. **A module never changes what a core word means.** It adds words, and options that only its own types accept.
13. **A rule depends on what a domain declares or requires, never on its subdomain label.** A module word that a second family of domains needs moves to the core.

## Reasons

- A compiled glossary and a checked context map turn the drift Domain-Driven Design warns about into compile errors, with macros and no reflection. Contexts are modules in one binary, so one machine stays enough.
- `require` keeps SweetTalk out of an application that does not ask for it; `include` keeps the words out of every other module.
- An application that never asks for SweetTalk reads nothing about it, and the framework's application template names no library, so SweetTalk can leave the framework without changing what a new application holds.
- Expanding into SugarORM and Cold Brew keeps state in PostgreSQL and one way to migrate.
- Refactoring toward deeper insight renames concepts, but tables, channels and queued jobs keep the names they were stored under.
- A require is the cheapest opt-in Crystal has: an absent file is never parsed, declares nothing and links nothing, so a program pays only for the words it asks for.
- The three tests name the costs a word puts on programs that do not use it: a link-time library, a vocabulary they do not speak, a refusal they did not ask for.
- The core model is what every domain shares; a context without aggregates would not be SweetTalk.
- A flag beside a require would be a second switch for one choice, and a program could set one without the other.
- Proving absence on the built binary catches a module reached through a require nobody meant.
- A module that redefines a core word would make a domain's meaning depend on a line far from it. Adding words keeps every core sentence true in every program.
- A label measures nothing. What a domain declares or requires is what it uses.
- The checks are the language: a second file that the context map cannot see would let a context name another's types without a border, and nothing would say so.
- `within` keeps the header the one place a context's options are read, so two files cannot disagree about what the context follows or where its events are logged.
- One `publishes` per context: a context declared between two blocks that publish would be checked against half the list.
- Rejected: top-level words. They would catch any `context(…)` call in an application.
- Rejected: a separate repository. SweetTalk expands into macro contracts that [ADR 0016](../0016-versioning-and-releases.md) does not cover.
- Rejected: one require for everything. Every program would link every module's dependency and read every family's words in its glossary and errors.
- Rejected: reopening `module Name`. It compiles and escapes every check.
- Rejected: inlining files with `{{ read_file }}`. Errors would point into the expansion, and the text checks would see one node for the whole file.
- Rejected: a second `context Name` that merges. One word with two meanings, and two sets of options that may conflict.
- Rejected: `require "**"` without an order. A glob orders files by name, not by use.
- Rejected: an aggregate, a kernel or a projection across files. Each builds its storage or its words when its block closes, and one that outgrows a file is a signal to model it again.
- Rejected: `frappe make context`. A generator can follow once the layout has been used.
