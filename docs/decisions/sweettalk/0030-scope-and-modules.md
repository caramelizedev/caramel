# ADR 0030: SweetTalk is an opt-in language for Domain-Driven Design, written as macros, checked across the whole program and shipped as a shard of its own

Date: 2026-10-08

Status: accepted.

## Context

An application with a rich domain assembles Domain-Driven Design by hand from schemas, changesets, actions and jobs. No word names a bounded context, an invariant, a domain event or a policy, and nothing stops one context from reaching into another's types. Some words bring a dependency or serve one family of domains, and nothing said when a word gets a require of its own. A context in one block is one file of several hundred lines, and reopening its module in another file compiles but escapes every check.

## Decision

1. **SweetTalk is opt-in: a dependency and a require bring it, and `include SweetTalk` scopes its words.** A plain application compiles none of it, and a new application does not depend on it. No word is a top-level macro. What only an application with a domain needs outside its code, such as a lint exclusion and the lines that tell an agent where the domain is, arrives with the first domain; a new application carries none of it.
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
14. **SweetTalk is a shard of its own, written in the framework's repository.** An application adds it beside the framework (`site#c-sweettalk-enable`). The framework's shard holds none of it and names it nowhere ([ADR 0014](../0014-repository-and-writing.md)).
15. **The shard has the framework's version number and depends on exactly that release.**
16. **No file of the shard requires the framework; the program that compiles it requires the framework first.** The shard refuses, with the line to add, a program that has not. Two files require the framework by its shard name. One is the program that runs the shard's tool commands, which only an application compiles. The other is the decimal module, for the one file of the framework it needs that no require of an application loads, and only in a program that has not loaded it.
17. **SweetTalk's commands are the shard's own, declared to Frappé as any shard's are ([ADR 0013](../0013-frappe.md)).** The commands that read a domain run in the application. The generator and the vocabulary run in the shard's program, before the application requires the shard.
18. **The vocabulary is printed from the macros that define it.** The shard reads each macro's parameters and the tags in its doc comment with Crystal's parser. No word is listed anywhere apart from its macro, and the checks fail when the macros, their tags and the guide disagree.

## Reasons

- A compiled glossary and a checked context map turn the drift Domain-Driven Design warns about into compile errors, with macros and no reflection. Contexts are modules in one binary, so one machine stays enough.
- `require` keeps SweetTalk out of an application that does not ask for it; `include` keeps the words out of every other module.
- An application that never asks for SweetTalk reads nothing about it and installs none of it. The framework's application template names no library, so adding the shard changes nothing a new application holds.
- While SweetTalk lived in the framework's shard, every application installed all of it, and Frappé held its commands for applications that had no domain.
- One version number says which framework a release of the shard was proven against. Only that pair passed the checks together, so the shard asks for that release and not for a range.
- A file of the shard is compiled in two places: in an application, where the framework is `lib/caramel`, and in this repository, where it is `src/`. A require of the framework written in that file would resolve in one place and not in the other, or would load one file of the framework by two paths and define everything in it twice. The program knows where its framework is, so the require is the program's.
- A program that forgot the framework would fail at the first name the shard does not define. A refusal with the line to add costs one check when the file is read.
- The decimal codec links GMP, so no require an application already writes loads it. A second line for every application with a decimal value would break the rule that a module's require is the whole opt-in.
- A generator is how the shard reaches an application's code, and the vocabulary is what an author reads before writing a domain. Both run before the application requires the shard, so neither may need the application to build.
- A vocabulary reference kept beside the macros drifts from them. Reading the macro itself leaves one place to edit and a check that fails when it is not edited.
- Rejected: a list of words in the tool program, which would be a second copy of what each macro states.
- Rejected: generating the guide's tables from the macros, because the guide teaches and the reference lists.
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
- Rejected: a separate repository. SweetTalk expands into macro contracts that [ADR 0016](../0016-versioning-and-releases.md) does not cover, so a change to one and the change to SweetTalk that follows it land in one commit and pass one set of checks.
- Rejected: commands of Frappé's own for SweetTalk. Frappé would hold code for a shard most applications do not install, and would need a release for every change to it.
- Rejected: one copy of each file for the application and another for this repository, or a compile-time flag that picks the require. Either is a second thing to keep in step, and neither proves in this repository the file an application compiles.
- Rejected: one require for everything. Every program would link every module's dependency and read every family's words in its glossary and errors.
- Rejected: reopening `module Name`. It compiles and escapes every check.
- Rejected: inlining files with `{{ read_file }}`. Errors would point into the expansion, and the text checks would see one node for the whole file.
- Rejected: a second `context Name` that merges. One word with two meanings, and two sets of options that may conflict.
- Rejected: `require "**"` without an order. A glob orders files by name, not by use.
- Rejected: an aggregate, a kernel or a projection across files. Each builds its storage or its words when its block closes, and one that outgrows a file is a signal to model it again.
- Rejected: `frappe make context`. A generator can follow once the layout has been used.
