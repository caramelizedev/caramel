# ADR 0065: SweetTalk contexts across files

Date: 2026-11-07

Status: accepted. Amends [ADR 0030](0030-sweettalk-domain-language.md) decisions 1 and 2,
[ADR 0035](0035-sweettalk-specifications-queries-and-state-checks.md) decision 2,
[ADR 0036](0036-sweettalk-strategic-design.md) decision 3 and
[ADR 0049](0049-sweettalk-sums-and-groups.md) decision 1.

## Context

A context is one `context Name … do … end` block, so it is one file. The macro reads its
block once and keeps what the whole-program checks read: its text, the events it reacts
to, what it publishes and its borders. A context with a dozen aggregates is a file of
several hundred lines. Reopening its module in another file compiles, but escapes every
check: the context map reads only the text the block kept.

## Decision

1. **`within Name do … end` continues context Name, declared before it in the same domain
   module.** It takes the words a context's body takes and no option: `follows:`,
   `shares:`, `means:`, `renamed_from:`, `central:`, `subdomain:` and `event_log:` belong
   to the `context` block.
2. **Every check reads every block.**
   - The whole-program checks read the text and the events reacted to of the header and
     of each `within`.
   - Each block's own statements are checked where they are written: names another
     context does not publish, HTTP outside an outside border, and a command, a factory or
     a unit that names an outside border declared by then.
   - A command, a factory or a unit that names an outside border a later block declares is
     refused by the whole-program check, which names its line.
   - Queries are checked once the program's top level is complete.
   - The event log reads the events declared in any block, and a `once_by:` unit in any
     block gets the operations table.
3. **A context publishes in one block, and has one border per other context or outside
   system.**
4. **The refusals.** A `within` of no context declared before it, of a kernel, or inside a
   context or a kernel does not compile; nor does `publishes` in two blocks of one context,
   or two borders with one context or outside system.
5. **The domain module requires its files in the order their names are used.** A word
   resolves names when it expands, so the order cannot be inferred. The guide's layout is a
   directory per context: `<context>.cr` holds the `context` with its options, the values
   the whole context uses and `publishes`; `<context>/<aggregate>.cr` holds one aggregate
   with its values, events, queries and specifications. `frappe make domain` still writes
   one file.
6. **Checks.** Each refusal above has a fixture in `sweet-talk-compilation`, and two more
   refuse a `within` that clashes with the event log's table or the operations table.
   `spec/sweet_talk/estate_spec.cr` runs a context split across files: events logged from
   its header and from a `within`, a `once_by:` unit declared in one, and a `finds` whose
   specification a later block declares.

## Reasons

- The checks are the language: a second file that the context map cannot see would let a
  context name another's types without a border, and nothing would say so.
- `within` keeps the header the one place a context's options are read, so two files
  cannot disagree about what the context follows or where its events are logged.
- Each block keeps its own text, so a refusal in a later file still names its line, and
  the whole-program checks join the texts, so `follows:` used only in a later file counts.
- One `publishes` per context: a context declared between two blocks that publish would be
  checked against half the list.
- A query names a specification that a later block may declare, so its check waits for the
  whole program, as a policy's tenancy check does.

Rejected:

- **Reopening `module Name`.** It compiles and escapes every check.
- **Inlining files with `{{ read_file }}`.** Errors would point into the expansion, and the
  text checks would see one node for the whole file.
- **A second `context Name` that merges.** One word with two meanings, and two sets of
  options that may conflict.
- **`require "**"` without an order.** Names resolve when a word expands
  ([ADR 0046](0046-sweettalk-units.md)), and a glob orders files by name, not by use.
- **An aggregate, a kernel or a projection across files.** Each builds its storage or its
  words when its block closes, and one that outgrows a file is a signal to model it again.
- **`frappe make context`.** The guide and the skill describe the layout; a generator can
  follow once the layout has been used.
