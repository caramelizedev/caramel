# ADR 0035: SweetTalk declares its reads and its rules once, and the compiler checks each whether or not anything calls it

Date: 2026-10-13

Status: accepted.

## Context

A rule written once as a `never` and again in the condition of each query that looks for it drifts. An application that needs a count, a page or a total loads every aggregate or reaches past its contexts into SQL, where a forgotten tenant predicate adds every tenant's rows together with no error ([#249](https://github.com/caramelizedev/caramel/issues/249)). Nothing says which numbered acceptance criteria no rule or example answers ([#264](https://github.com/caramelizedev/caramel/issues/264)). A calculation that splits or rounds has an identity, and with no word for a pure function it lives in prose.

## Decision

1. **A specification states a rule once, and Crystal and PostgreSQL both read it.** It is a declarative condition on one aggregate's stored attributes.
2. **The aggregate is its own repository, and its reads are declared queries.** A projection or a process declares its reads the same way.
3. **A query with a block is the escape hatch, and it can only narrow.** Its rows are already scoped, the aggregates are built from its result, and only the model builds itself from rows.
4. **Every query is checked whether or not anything calls it, and a wrong one does not compile.**
5. **A total is a declared read beside the count.** A sum, alone or grouped by one key, takes a count's conditions.
6. **A sum is one statement with no join, over one stored attribute of the aggregate or of an entity it holds directly.** It adds up no expression and reaches no attribute through a reference.
7. **A sum comes back as the attribute's type, built from the exact text PostgreSQL returns.** A sum takes only an attribute whose bounds no sum can break; any other does not compile. A total past its type raises.
8. **A domain module lists the requirement ids it answers to, and a rule names the ids it assures.** The application says which ids no rule assures. An example names an id in its description. SweetTalk declares the ids to the framework's registry of ids a full spec run must name, and that run fails on an id no example names ([ADR 0010](../0010-corretto.md)).
9. **A calculation is a typed function of a context that changes nothing.** It has no transaction, repository, event, command or span, and takes no aggregate. Its body is Crystal.
10. **A rule in a calculation's body is a rule on its result, checked on every call.** A broken rule raises `SweetTalk::Broken`, a defect and not a `SweetTalk::Refusal`. A calculation refuses an input outside its domain with a refusal in its body.
11. **Corretto's property runner runs a calculation, and what it needs from SweetTalk lives in a file of SweetTalk's own.** A calculation is a class method of its context, so the runner of [ADR 0010](../0010-corretto.md) runs it on generated cases. SweetTalk's generators for its values, and its registrations of `SweetTalk::Refusal` as outside the domain and of `SweetTalk::Broken` as a failure, live in a file that a spec requires after the domain. A value gets its generator when that file is required, not once the program's top level is complete.

## Reasons

- One declaration read two ways states a rule once. A predicate block and a query block state it twice, and a check that compares them passes on data that lacks the case where they differ.
- PostgreSQL cannot read a rule over entities or a derived value, so such a rule stays a `never` or a method, and no SQL enters a rule.
- Evans's repository offers roots only, by criteria named in the domain, as a collection. The aggregate with its declared queries already does.
- The block's rows are already scoped and its result always goes through the loader, so it cannot forget a removed row or return rows instead of aggregates.
- A wrong query must not compile, and a check inside its method waits for a call.
- A total is the first read a report asks for. Beside the count, the tenant predicate and the removed rows are handled once, not by every report.
- Text keeps a PostgreSQL sum exact without a Crystal type per column pair: only the caller knows which value to build.
- A sum of values each at least 0 is at least 0, while any other bound can be broken by the sum. A bound that a sum can break would make a declared query raise on data it was declared for.
- An entity's row holds its aggregate's id, so a total per aggregate needs no join. A statement reads one aggregate's rows, and another's columns stay private.
- A requirement nothing assures, or no example proves, is a promise no one is keeping. The check belongs where both are known: the compiler sees the rules, and the full run sees the examples.
- A full run is where "no example names it" is true; a run of one file would fail every id its neighbours name.
- A function that reads nothing must not take a connection to say so, and the command or service around it is timed already.
- A command needs an aggregate, so a calculation that takes none reaches no command.
- The caller did nothing wrong when a calculation breaks its own rule. A refusal tells the user to change the request, which would not help; a defect rolls back and is reported, so the author sees it.
- The generators live in a file of SweetTalk's, not in Corretto: the constants they read are SweetTalk's, and Corretto names no library.
- A value gets its generator when the file is required because Corretto reads the property's line, in an example, before any `finished` hook runs.
- Rejected: a storage block that may name `Rows`. Its read-only rule would be a text check, and its queries could forget removed rows.
- Rejected: parameters on a specification. A query takes arguments and adds a specification.
- Rejected: typed SugarORM sums. They need an overload per column type and per key type, when one text result and one conversion per declaration do the same.
- Rejected: SQL, an expression or a derived value in a declared read. It states a Crystal expression again in SQL.
- Rejected: requirement ids in a comment beside the rule, or as tags on the example. Nothing reads a comment, and the description is what a failure report shows.
- Rejected: `service` for calculations. It opens a transaction and may change an aggregate.
- Rejected: checking a calculation's rules only in specs. A rule that holds in every example and breaks on one production input would compute a wrong number silently.
- Rejected: rules outside the body. They read the result, which exists only after it.
