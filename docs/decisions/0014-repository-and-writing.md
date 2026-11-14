# ADR 0014: Each product has one source directory, each kind of writing one home, and each subject one decision record

Date: 2026-09-27

Status: accepted.

## Context

The repository is the shard `caramel`. Crystal resolves `require "caramel"` to `src/caramel.cr`, and applications vendor the framework and require it by that name. The CLI is `frappe` ([ADR 0013](0013-frappe.md)). Latte ships a native macOS menu app and installers, and build output is git-ignored.

Shards copies the whole tagged tree into every application's `lib/caramel`, and agents read and grep it. Status, measurements, investigation diaries and restated facts were half of the repository's markdown and most of what a repository-wide grep returned.

Decisions were recorded one per feature. A rule ended up spread over the records that amended it, and each record restated detail that the website and the doc comments already held.

## Decision

Application authors read the website ([site.html](../../website/source/site.html)) and contributors [CONTRIBUTING.md](../../CONTRIBUTING.md). This record states where code and writing live and how decisions are kept. Formatting, linting and the checks' lanes are in [ADR 0017](0017-style-and-checks.md).

1. **Each product owns a top-level source directory named after it.** `src/caramel/` is Core, `src/sugar_orm/` SugarORM, `src/latte/` Latte and `src/frappe/` Frappé. Cold Brew lives in `src/caramel/cold_brew/`, `cache.cr` and `sse.cr`, which `require "caramel"` loads into every application. Corretto lives in `src/caramel/corretto/`, reached by `require "caramel/corretto"` from specs only. SweetTalk lives in `src/caramel/sweet_talk/`, reached by its own require ([ADR 0030](sweettalk/0030-scope-and-modules.md)); its specs in `spec/sweet_talk/` run in `scripts/check integration`.
2. **`bin/` is build output.** `scripts/build-*` write `frappe`, `latte`, `latte-port-relay` and `Latte.app` there.
3. **`docs/` holds the decision records and nothing else.** A framework record is `docs/decisions/NNNN-name.md` and a SweetTalk record is `docs/decisions/sweettalk/NNNN-name.md`. The two directories share one series of numbers.
4. **The website is the application authors' contract, published per release.** It is `website/source/site.html`. Each release's edition stays at `/docs/X.Y.Z/` and `/cookbook/X.Y.Z/`: publishing adds the current edition and keeps every earlier one, and a release tag without an edition redirects to the newest edition of its minor. API detail is in doc comments at the code. Each page of an edition also has a Markdown edition for agents, `index.md` beside its `index.html`, which the website build converts from the same page and lists in `/docs/X.Y.Z/llms.txt` (`site#c-agents-orient`). A release tag without an edition gets copies of its target's `llms.txt` and `index.md` files.
5. **`CONTRIBUTING.md` is the contributors' contract.** `AGENTS.md` (which `CLAUDE.md` imports) holds only what an agent needs beyond it. How a website page is shaped and worded is the contributor skill `.claude/skills/caramel-docs/SKILL.md`, which links to the rules it applies rather than restating them. How to report a vulnerability, and which releases get security fixes, is `SECURITY.md`, where GitHub shows it to reporters.
6. **Status, measurements, investigations, incident timelines and history stay out of this repository.** They go to caramelizedev/caramel-notes, a pull request description or the CHANGELOG. There is no design RFC; the 2026 RFC is retired to caramelizedev/caramel-notes.
7. **A fact is stated once and linked from elsewhere.**
8. **Generated applications get a short README and an `AGENTS.md`, which `CLAUDE.md` imports.** The website renders its agent guide from that file (`site#c-agents-agentsmd`). A generator may also write a skill from `templates/skills/`: `frappe make domain` writes `.claude/skills/sweettalk/SKILL.md` from `templates/skills/sweettalk/SKILL.md` when the application has none. A skill states no rule the website does not, and each rule ends with a link to its section in the release's Markdown edition, which the website check verifies.
9. **A decision record covers one subject.** A record is an ADR for a whole subject, such as Cold Brew or SugarORM, not for one feature, so a rule is stated in the record that owns its subject and in no other. A record that merges others keeps the lowest of their numbers, a short subject filename and the earliest of their dates. The other numbers are retired and never reused. A record has no byte cap; a subject too long to scan is split into two records.
10. **A record states what is in force.** Line 1 is `# ADR NNNN: <title>`, followed by `Date: YYYY-MM-DD` and `Status: accepted.`, then three sections: Context (optional, the problem), Decision (the rules in force, in the present tense) and Reasons (why, and the options rejected). A change that alters a decision edits its record in the same commit. No record amends, extends or supersedes another, and the status line names no other record. A merge keeps every reason and every rejected option of the records it merges.
11. **A record names the home of a rule instead of restating it.** A rule is homed when the website, or a doc comment directly above a declaration in `src/`, states the same fact. A `:nodoc:` doc comment counts; a comment inside a method body does not. Migration SQL is a home for mechanics only: column lists, index column lists and constraint names. A homed rule's detail is left out of the record, whose entry states the choice and names the home. A rule with no such home is stated in the record in full.
12. **A record cites a site section by its anchor, and a check resolves the citation.** The citation is a code span holding `site#` and the section's id, as in `site#c-coldbrew-run`. `scripts/check website` fails, naming the record and the anchor, when a cited anchor is not an id in a built page of the current edition. A doc comment is cited by the name of its declaration.
13. **A citation names the rule, not its number.** Code, comments and other records cite a record as `ADR NNNN` and name the rule in a few words. An entry's number is for reading only.
14. **A framework record states no SweetTalk rule.** Where core has a mechanism SweetTalk uses (a hook, a protocol, a Frappé command, a lint exclusion), the framework record states the mechanism and may link the SweetTalk record in one clause; the SweetTalk record states how SweetTalk uses it.
15. **`scripts/check prose` enforces the homes.** It checks where markdown lives, each record's title, date, status and sections, every relative link, and a byte cap per file. A record and a skill have no byte cap.

## Reasons

- Product-named directories match what applications and agents type (`require "caramel"`, `SugarORM::…`, `frappe`, `latte`).
- Keeping Cold Brew under the `caramel` require means the job queue, PubSub and cache ship in every application binary, because one machine is enough.
- Every byte in the tagged tree reaches every application and every repository search.
- A rule stated once cannot drift. A Markdown edition generated from the pages, and a skill whose every rule links the page that states it, add no second source. That link, which the website check verifies, is what keeps a skill from drifting; a byte cap on it only pushed rules out of the skill or made reviewers trade one rule for another.
- Agents build a guide's URL from the release that `shard.lock` pins, so a release tag without an edition gets the `llms.txt` and `index.md` files of the edition it redirects to.
- Rejected: moving all documentation to another repository, because contracts must change in the same commit as the code, and the website's checks read the source at that commit.
- Rejected: hiding prose from search with ignore files, because it would still ship in applications and still drift.
- Rejected: Markdown pages written by hand beside the site, which would drift from it.
- Rejected: one record per feature. A later feature amended the record of an earlier one, so a reader followed a chain of records to learn what is in force, and the amended record went on stating what no longer held. A record per subject, edited in place, states each rule once.
- A record that restates the website or a doc comment is a second source and drifts like any other. Naming the home leaves the record with what has no other home: the choice, the rules nothing else states, and the reasons.
- A cited anchor is checked for the reason a skill's link is: a citation that nothing resolves breaks without notice when a section is renamed.
- An entry's number changes when a record is edited or merged, and a citation by number then points at another rule without failing any check. Words name the rule for as long as it exists.
- SweetTalk is to become a shard of its own. Its records sit in their own directory, and framework records state none of its rules, so its decisions can leave with it and no framework record loses a part.
- Rejected: a byte cap on records. A subject that outgrew the cap continued in another record, which is how one subject came to be spread over several. A record is read for its subject, not loaded whole into every application or session as a capped file is.
