---
name: caramel-triage
description: How Caramel's GitHub issues are labelled. Use whenever filing, labelling, re-prioritising or reviewing issues in caramelizedev/caramel, or when asked to categorise new issues.
---

# Labelling an issue in caramelizedev/caramel

Every issue carries exactly one label from each of four axes, plus any flags that apply.
`gh label list` prints the set; add a label only through this file, in the same commit.

## The four axes

1. **Type.** `bug` (documented or intended behaviour does not happen), `enhancement` (a
   new capability or a change of behaviour), `documentation` (the code is right, the page
   is not). A missing capability that the docs call a limit is an `enhancement`, not a bug.
2. **Priority.** Ask what it blocks, not how bad it sounds.
   - `priority: P0`: a team cannot be recommended production use until it is fixed: data
     loss, a job redelivered forever, no way to run specs.
   - `priority: P1`: fix before the first production deployments: a security default a
     real app will meet, an operational gap a deploy will hit in week one.
   - `priority: P2`: planned; a team can work around it today with code or process.
   - `priority: P3`: backlog: hardening, polish, a limit rarely met.
3. **Effort.** An estimate of the change as the issue describes it, not of the ideal fix:
   `effort: XS` under 2 hours; `S` up to a day; `M` 2 to 4 days; `L` 1 to 2 weeks; `XL`
   over 2 weeks, or anything that needs an ADR or must be split. A bundle of several
   findings is sized as a whole and says so in a comment.
4. **Area.** The directory the fix lands in: `area: core` (`src/caramel`, SweetTalk
   included), `sugar-orm` (`src/sugar_orm`), `cold-brew` (`src/caramel/cold_brew`),
   `frappe` (`src/frappe`, generators, diagnostics), `corretto` (`src/caramel/corretto`,
   spec running), `latte` (`src/latte`, `latte/`, installers), `docs` (`website/`,
   `docs/`), `release` (`scripts/release`, tags, pinning, governance). One area: the one
   with the most lines to change.

## Flags, when they apply

- `security`: an attacker or a tenant gains something. Pair with a priority as above.
- `production-readiness`: a gap a production deployment meets; the October 2026 audit's
  findings also carry `audit-2026-10`.
- `tracking`: a checklist of other issues; closes when they do.
- `deferred`: postponed on purpose; the issue says what unblocks it.
- `duplicate`, `wontfix`, `invalid`: close the issue with a comment naming the reason.

## Doing it

1. Read the whole issue, then the source it names; size from the code, not the prose.
2. Compare with a labelled neighbour: #130 (P1, L, core), #126 (P2, M, cold-brew),
   #150 (bug, P2, S, frappe), #151 (enhancement, P3, M, corretto), #133 (P2, XL,
   sugar-orm), #153 (documentation, P2, S, docs).
3. Apply with one call per issue: `gh issue edit N --add-label "bug,priority: P2,effort: S,area: frappe"`.
4. When the choice was not obvious, leave one comment saying why, so the next reader
   does not guess again.

## Writing an issue

Title: what is wrong, as a sentence, with the product first (`SweetTalk: …`, `Latte: …`).
Body: `## What`, `## Where` (file and line), `## Failure scenario`, `## Suggested
resolution`, `## Confidence` (confirmed by running it, or a source review). One finding
per issue; a bundle gets a `tracking` issue and one issue per item.
