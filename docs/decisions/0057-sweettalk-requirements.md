# ADR 0057: SweetTalk requirements

Date: 2026-11-07

Status: accepted. Amends [ADR 0030](0030-sweettalk-domain-language.md) decision 2,
[ADR 0035](0035-sweettalk-specifications-queries-and-state-checks.md) decision 1,
[ADR 0046](0046-sweettalk-units.md) decision 1 and
[ADR 0010](0010-corretto-harness.md) with decision 10.

## Context

A team that answers to numbered acceptance criteria wrote each id in a comment beside the
rule and in a spreadsheet beside the spec. Nothing said which criteria no rule or example
answered, and a renamed id left both comments wrong (#264).

## Decision

1. **`requirements "AC-01", "AC-02"` lists the ids a domain module answers to.** It sits in
   the module that includes `SweetTalk`, before its first context. An id is text of
   letters, digits, `.`, `_` and `-`, starting with a letter or a digit. A module with no
   ids, an id twice, a second `requirements` in one module, or one after a context does not
   compile. Each context and kernel copies the list as `SWEETTALK_REQUIREMENTS`.
2. **`assures:` names the ids a line answers.** `never`, `always`, `specification` and `unit`
   take `assures: "AC-12"` or `assures: ["AC-12", "D04"]`, and so does a `never` or an
   `always` in a unit's body. An `assures:` of anything but ids, in a module that declares
   no requirements, or naming an id its module does not list, does not compile, and says
   which ids the module lists.
3. **`SweetTalk.declared_requirements`** returns each id, in declaration order across the
   modules and merged when two list one, as a `SweetTalk::Requirement` with the
   `SweetTalk::Assurance` lines (`kind`, `text`, `owner`) that assure it, read from the
   contexts, aggregates, entities and values at compile time. `SweetTalk.boot` calls it.
   `requirements` is the macro that declares them, so the method has another name.
4. **`frappe requirements [ID]` lists them.** It compiles the application and runs
   `requirements`: per id a line, then `  <kind> <owner>: <text>` for each line that assures
   it, or `  nothing assures it`; one id's block for an `ID`, which exits 1 when it is no
   requirement. `requirements --ids` prints the ids alone. An application that does not
   require `caramel/sweet_talk` answers with its usage, and Frappé says it declares none.
5. **A full `frappe corretto` run fails on an id no example names.** After every worker
   passes a run of every spec, Corretto reads the ids and the descriptions of the examples
   that ran, the groups' and the example's own joined by spaces, and fails naming each id
   that no description holds as a token: `AC-1` is not named by `AC-12`. A run of chosen
   paths checks nothing.

## Reasons

- A requirement is a promise; one nothing assures, or no example proves, is a promise no
  one is keeping. The check belongs where both are known: the compiler sees the rules, and
  the full run sees the examples.
- Naming the id in the example, as in `it "refuses an unbalanced entry (AC-12)"`, costs one
  word, and the id then shows in every spec report.
- A full run is where "no example names it" is true; a run of one file would fail every id
  its neighbours name.

Rejected:

- **A comment beside the rule.** Nothing reads it.
- **Tags on the example.** The description is what a failure report shows, and one more
  syntax is one more place for a renamed id to go stale.
- **Checking a partial run.** It would make `frappe corretto path` fail on requirements it
  was not asked about.
