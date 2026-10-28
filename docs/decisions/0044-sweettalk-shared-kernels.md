# ADR 0044: SweetTalk shared kernels

Date: 2026-10-27

Status: accepted. Amends [ADR 0030](0030-sweettalk-domain-language.md) decision 3, reverses
the rejection of a shared kernel word in [ADR 0036](0036-sweettalk-strategic-design.md), and
applies [ADR 0033](0033-sweettalk-multi-tenancy.md) to kernels.

## Context

ADR 0036 rejected a shared kernel word: a small context that several contexts follow already
shares a model. Following is one-way. The followed context owns the model, any context may
follow it, and nothing records who must agree to a change. Two contexts that own part of a
model together, such as a voucher Pricing gives and Billing spends, either put it in one of
them, so the other follows a model it has no say in, or keep two copies that drift. A model
shared this way also grows: a word one context needed lands beside the shared ones.

## Decision

1. **A kernel is part of a model that named contexts share.** `kernel Money, shared_by:
   [Pricing, Billing], means: "…" do … end`, in a module that includes `SweetTalk`, declares
   a module `Money` that holds `value` and `aggregate` declarations; an aggregate keeps its
   entities, events, commands, factories and queries. Anything else in its body does not
   compile. `shared_by:` is a list of two or more different names of contexts or kernels,
   and anything else does not compile; nor does a kernel without `means:`. A kernel takes
   no `central:`, `subdomain:` or `renamed_from:`.
2. **Both sides say it.** A context or a kernel says `shares: Money`, or `shares: [Money,
   Calendar]`, naming kernels declared before it whose `shared_by:` lists it; anything else
   does not compile, at the line that says it. A kernel whose `shared_by:` lists an unknown
   name, or one that does not say `shares:` of it, does not compile when the program's
   checks run.
3. **Only sharers name a kernel** (amends ADR 0030 decision 3). A sharer names the kernel's
   types anywhere, runs its aggregates' commands and reacts to its events. A context or
   kernel that names `Money::` without sharing it, or a context that follows `Money` or has
   a border with it, does not compile, and neither does a kernel that names a context or
   reaches `Caramel::Outbound` or `HTTP::Client`. The context map draws a `kernel` edge
   from each sharer to the kernel. A kernel edge is not a dependency edge, and a kernel
   shares only kernels declared before it, so sharing never runs in a circle.
4. **Every word of a kernel is shared.** Each value or aggregate of a kernel that no other
   word of the same kernel uses must be named, as `Money::Voucher`, by two or more of its
   sharers; one named by a single sharer, or by none, does not compile, and the message
   names where it belongs. The check reads the code as written, as the `Other::` checks
   do: a sharer that only passes a value along without writing its name does not count.
5. **A kernel stores like a context.** Its module includes `SweetTalk::BoundedContext`, so
   its tables and channels take its name, as in `money_vouchers`. In a program that
   requires `caramel/tenancy` its rows belong to the tenant, as a context's do without
   `central: true` (ADR 0033 decision 1). The glossary lists each kernel with kind
   "kernel", and its values, aggregates and events with the kernel as their context.
6. **Checks.** Each refusal above has a fixture in `sweet-talk-compilation`.
   `spec/sweet_talk` runs the tea house's `Calendar` and `Money` kernels against PostgreSQL,
   with a kernel's day in a `date` column, optional, carried in an event and read in a
   range, and `spec/sweet_talk_tenancy` runs a tenanted kernel.

## Reasons

- A closed list on the kernel makes joint ownership a compile-time fact: a context that
  starts to use the kernel edits it, where every owner reviews the change.
- `shares:` on the sharer keeps its dependencies in its head, beside `follows:`.
- Aggregates and events belong in a kernel because what two contexts must agree on often
  has a lifecycle. Services, policies, projections and processes act for one context, so a
  sharer holds them.
- A kernel that shares an earlier kernel lets kernels split by who uses them, a calendar
  apart from money, without merging them or copying a value; declaration order keeps that
  sharing acyclic.
- A list of sharers says who owns a kernel, not that each word is shared. Counting who
  names each word keeps one context's word out of a kernel and says where it belongs.
- Including `BoundedContext` reuses tables, tenancy, queries and their checks; a kernel
  differs from a context only in the words its body holds and in who may name it.
- `shared_by:` takes a list literal, as `carries:` does.

Rejected:

- **One side only.** `shared_by:` alone hides the dependency from the sharer's head;
  `shares:` alone lets any context join, which is `follows:` again.
- **Independent kernels.** A value of one kernel that needs another's, such as a voucher's
  expiry day, would force the two to merge or the value to be copied.
- **Checking only that each sharer names the kernel.** It misses a word only one sharer
  uses.
- **`context Money, kernel: true`.** A kernel holds fewer words and is named by other rules;
  one word per idea keeps each refusal precise.
- **A central kernel.** A kernel is shared between contexts, not between tenants; `central:`
  stays a context's word.
