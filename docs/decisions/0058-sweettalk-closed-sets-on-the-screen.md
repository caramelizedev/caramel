# ADR 0058: SweetTalk closed sets on the screen

Date: 2026-11-07

Status: accepted. Amends [ADR 0040](0040-sweettalk-closed-set-values.md) decision 4 and its
rejection of an enum, and [ADR 0030](0030-sweettalk-domain-language.md) decision 2.

## Context

A closed set is declared once in the domain, and Crystal and PostgreSQL both check it. The
screens then restated it: they compared text, branched on members with a default arm, and
decided which actions to offer by restating the lifecycle. When the domain added a member,
nothing failed; the new member fell into the default arm.

## Decision

1. **A closed-set value has a member enum.** `value Kind, String, one_of: %w[payment
   receipt net_settlement]` also writes `enum Kind::Member` with `Payment`, `Receipt` and
   `NetSettlement`, one member per word in the order the list gives them. `kind.member`
   returns the value's member and `Kind.new(member)` builds the value of one, as does
   `Kind.new(:receipt)`. A member's name is the camel case of its underscored word, so its
   predicate is the value's own, `net_settlement?`; a word whose camel case would lose an
   underscore keeps it, so `x_1` gives `X_1`. The column, its check and the check's hash
   keep the words.
2. **A `case … in` over the member names every one.** `case kind.member in .payment? …
   end` that misses a member fails compilation with Crystal's "case is not exhaustive for
   enum Kind::Member", which lists the missing members. A kind with parts reads its parts
   in the member's arm, `in .payment? then transfer.as_payment[:payee]`
   ([ADR 0054](0054-sweettalk-kinds-with-parts.md)).
3. **Labels take no word.** A screen labels each member with such a `case` and one catalog
   message per member ([ADR 0024](0024-internationalization.md)), so a new member fails
   compilation at the `case` and a missing message at the catalog.
4. **A lifecycle's graph is public to read.** `moves` also writes `Order.moves_from(state)`,
   the states a mover may enter from `state` in the order `moves` first names them, and
   `order.may_become?(state)`, whether the mover of `state` may run from the current state.
   The movers stay private. A screen maps each state it offers to its command in a
   `case … in` over the states, which fails compilation when a state is added.

## Reasons

- ADR 0040 rejected an enum because it would store numbers or need a column mapping. An
  enum that only mirrors the text in memory needs neither: `moves` has kept that pair since
  [ADR 0035](0035-sweettalk-specifications-queries-and-state-checks.md) decision 3.
- Crystal proves a `case … in` exhaustive and refuses its `else`, so a member added to the
  list fails compilation at every screen that branches on it. A `when` with an `else`
  sends the new member to the default arm in silence.
- The enum belongs to the value, so kinds with parts and later declared subsets build on
  it, and each subset method's body becomes exhaustive too.
- Labels need no new word while a `case` and a catalog already fail compilation on a gap.
- The graph is read, not mapped to commands, because states and commands are not one to
  one: one state can be entered by two commands. `may_become?` answers for the graph only;
  a command may still refuse for another rule.

Rejected:

- **An enum as the stored type.** It would store numbers or need a column mapping, and the
  words in existing data would not map (ADR 0040).
- **A label word**, `means:` per member or a `label` read from a catalog group named for the
  value. The first is a second list; the second ties `caramel/i18n` to SweetTalk.
- **`to ship(…), moves: :shipped`.** It is another declared list beside the body, and
  reading the movers from a body is inference.
