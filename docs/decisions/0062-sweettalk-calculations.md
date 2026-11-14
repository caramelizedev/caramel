# ADR 0062: SweetTalk calculations

Date: 2026-11-07

Status: accepted. Amends [ADR 0030](0030-sweettalk-domain-language.md) decision 2,
[ADR 0036](0036-sweettalk-strategic-design.md) decision 3,
[ADR 0057](0057-sweettalk-requirements.md) decision 2,
[ADR 0061](0061-sweettalk-modules.md) decision 2, and
[ADR 0010](0010-corretto-harness.md) decision 8 and with decision 11.

## Context

A calculation that splits, rounds or converts has an identity: the parts sum to the whole,
and a full settlement consumes the full balance. Nothing in SweetTalk spoke about a
computation's result. A `service` opens a transaction, so a pure function had no word, and
its identity lived in prose and in hand-written spec loops.

## Decision

1. **`calculation verb(arg : Type, …), returns: T, means: "…" do … end` in a context is a
   calculation.** It declares `Context.verb`, a typed function with no transaction,
   repository, event or command, timed by nothing. The body is Crystal, and its last
   expression is the result. It joins the glossary with kind "calculation", and
   `publishes` may name it. A calculation without `means:`, without `returns:`, with an
   untyped argument, an argument named `result`, a type not declared before it, or an
   argument or a result that holds an aggregate, an entity, a projection or a process
   does not compile, nor does `calculation` in an aggregate, an entity, a projection, a
   process or a kernel.
2. **Its body reaches nothing, as far as its text shows.** A body or a rule that names
   `SugarORM`, `Repo`, `Rows` or `SweetTalk.lock`, emits, calls a method on an aggregate,
   an entity, a projection or a process class, such as `Invoice.find`, or calls a service
   or a unit does not compile, at the line that does it. A command needs an aggregate,
   which a calculation can neither take nor load.
3. **A `never` or `always` line in its body is a rule on `result`.** The rules run after
   the body, in the order written, over `result` and the arguments. `assures:` on such a
   line names the requirement ids it answers, as on a unit's.
4. **A broken rule is a defect: `SweetTalk::Broken`.** It is not a `SweetTalk::Refusal`.
   `Broken#calculation` names the calculation and `Broken#rule` the sentence, and its
   message is "Context.verb broke its rule: sentence". Like any other error it rolls back
   the transaction it runs in, and an action that does not rescue it answers 500 and
   reports it to Crema. A calculation refuses an input outside its domain by raising
   `SweetTalk::Refusal` in its body, before any rule runs.
5. **`SweetTalk.calculations`** returns each calculation as a `SweetTalk::Calculation`:
   its context, name, meaning, arguments as `{name, type}`, the type it returns and its
   rules as `{"never" or "always", sentence}`, each type its full name. It is read at
   compile time from `SWEETTALK_CALCULATION_<NAME>` constants, as the glossary is.
6. **Checks.** Each refusal above has a fixture in `sweet-talk-compilation`, and
   `spec/sweet_talk/calculations_spec.cr` runs the lots' calculations: a rule that holds,
   one that breaks, a refusal, a `never` line, and a broken rule inside a service that
   rolls back its write.
7. **Corretto runs a calculation's rules on generated cases.** A calculation is a class
   method of its context, so `Corretto.property(Context.verb)` runs it on 200 drawn cases
   ([ADR 0010](0010-corretto-harness.md) decision 11) in a spec that requires
   `caramel/sweet_talk/corretto` after the domain. That file gives each value declared
   before it a generator that draws from what the value declares: its bounds, its
   `one_of:` members, its day, its decimal precision, scale and bounds, and each part of a
   value with parts; an amount of `caramel/sweet_talk/money`
   ([ADR 0063](0063-sweettalk-money.md)) is a whole number of minor units. A value that
   wraps another type, such as JSON, gets none, so a property with such an argument does
   not compile unless the value defines `corretto_draw` itself. The file names
   `SweetTalk::Refusal` as outside the domain, so a case a value or the body refuses is
   skipped, and `SweetTalk::Broken` as an error whose message says what failed, so a
   broken rule fails with its own sentence and the seed that `CORRETTO_SEED` gives back.
   Required before any context is declared, the file does not compile.
   `spec/sweet_talk/calculations_spec.cr` runs it on the lots: the careless split breaks
   its rule within the 200 cases, and the same seed fails the same way twice.

## Reasons

- A rule on a result is still a rule, and rules are core ([ADR 0061](0061-sweettalk-modules.md)
  M2): a domain with no money still splits and rounds.
- A service opens `SugarORM::Repo.transaction`; a function that reads nothing must not take
  a connection to say so.
- The caller did nothing wrong when a calculation breaks its own rule. A refusal answers
  422 and tells the user to change the request, which would not help; a defect answers
  500, rolls back and is reported, so the author sees it.
- A refusal in the body keeps its meaning: the input lies outside the domain, and the
  caller may say so to the user.
- Refusing aggregates as arguments keeps every command out of reach of the text check,
  which cannot see a receiver's type: a calculation takes what it needs from an aggregate,
  or its id, and the caller loads it.
- No span: a calculation may run inside a loop of thousands, and the command or service
  around it is timed already.
- A Crystal body, not an expression language: expression bodies are a decision of their own
  for the whole language, and a calculation needs nothing a typed function lacks.
- A property case runs the real calculation on inputs no one chose, which an example
  cannot: the generators come from the constants the value macros already record, so a
  case needs no hand-written generator. A refusal skips the case, because the domain said
  the input lies outside it; only a broken rule is the calculation's fault.
- The runner needs no database, so it lives in Corretto beside the other spec helpers and
  runs in any example; a fixed count and a printed seed make a failure repeatable.
- The generators live in a file of SweetTalk's, not in Corretto: the constants they read
  are SweetTalk's, and Corretto runs any typed class method without naming a library. A
  value gets its generator when the file is required, not once the program's top level is
  complete: Corretto refuses an undrawable argument when it reads the property's line, in
  an example, which is before a `finished` hook runs.

Rejected:

- **`service` for calculations.** It opens a transaction and may change an aggregate.
- **A broken rule as a `Refusal`.** It would answer 422 and blame the request for the
  calculation's fault.
- **Checking a calculation's rules only in specs.** A rule that holds in every example and
  breaks on one production input would then compute a wrong number silently.
- **Rules outside the body.** They read `result`, which exists only after it, and a rule
  in the body sits beside the code that must keep it.
- **A plain-`spec` helper in `caramel/sweet_talk/spec`, or `frappe check properties`.**
  The first splits spec helpers across two products; the second runs specs outside
  `frappe corretto`, and its workers' settings.
- **Shrinking a failing case.** The case, its seed and its arguments are printed; the
  arrays hold at most 8 elements, so a failure reads as it is.
