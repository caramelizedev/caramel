# ADR 0014: Each product has one source directory, each kind of writing one home, and each subject one decision record

Date: 2026-09-27

Status: accepted.

## Context

Shards copies a repository's whole tagged tree into an application's `lib/`, where agents read and grep it. Status, measurements and restated facts were half of the repository's markdown. Decisions were recorded one per feature, so a choice ended up spread over records that amended one another, and the records filled with rules that the code, the website and the doc comments already state.

## Decision

1. **Each product owns a top-level source directory named after it.** Core, SugarORM, Latte and Frappé each have one under `src/`. Cold Brew lives inside Core's, so `require "caramel"` loads it into every application; Corretto lives there too, behind a require of its own. SweetTalk is a shard of its own ([ADR 0030](sweettalk/0030-scope-and-modules.md)), and its directory is `sweettalk/`, at the top of the repository.
2. **The website is the application authors' contract, published per release.** Every release's edition stays online. Each page also has a Markdown edition for agents, generated from the same page. API detail is in doc comments at the code.
3. **`CONTRIBUTING.md` is the contributors' contract.** `AGENTS.md` holds only what an agent needs beyond it. A skill, for contributors or written into an application, states no rule of its own: it links the page that states each rule, and a check resolves the link.
4. **Status, measurements, investigations and history stay out of the repository.** They go to caramel-notes, a pull request description or the CHANGELOG. There is no design RFC.
5. **A fact is stated once and linked from elsewhere.**
6. **A decision record states the choices that were made and why, and nothing else.** Rules, mechanics and reference detail live in the code, its tests, doc comments and the website; a record does not restate them. A sentence belongs in a record when a contributor who did not know it could reasonably design the thing differently, when it says why a choice was made, or when it names an alternative that was rejected.
7. **A record covers one subject and is edited in place.** There is one record per subject, not per feature, and the commit that changes a choice edits its record. No record amends, extends or supersedes another. A record that merges others keeps the lowest of their numbers, and the other numbers are never reused.
8. **SweetTalk's records sit in a directory of their own, and a framework record states no SweetTalk choice.** Where core has a mechanism SweetTalk uses, the framework record states the neutral choice and may link the SweetTalk record in one clause.
9. **`sweettalk/` holds what an application installs, and nothing else.** That is its `shard.yml`, the commands it declares to Frappé, its sources with the program that runs its tool commands, the skill its generator writes, a README and the licence. Its specs, fixtures and checks, its decision records and its guide stay with the framework's. No file of the framework's sources or templates names SweetTalk.
10. **`published.yml` is the one declaration of what a release publishes.** The framework's shard is the paths it lists, each where it is in this repository, and the SweetTalk shard is `sweettalk/` whole. An application's `lib/caramel` holds only what it compiles against, with the licences its notices cite. The tools, the templates, the website, the specs and these records stay here ([ADR 0016](0016-versioning-and-releases.md) for how a release publishes the trees).
11. **A citation names the choice in words.** Code and other records cite a record by its number and a few words, never by an entry's number. A record may cite a website section as a code span holding `site#` and the section's anchor, as in `site#c-coldbrew-run`, and the website check fails on an anchor no built page has.
12. **Checks hold the homes.** A check refuses markdown outside its homes, a record without its sections, a dead relative link, a file past its byte cap and a file of the framework that names SweetTalk. A record has no byte cap.

## Reasons

- Product-named directories match what applications and agents type.
- Cold Brew under the `caramel` require puts the queue, PubSub and cache in every application binary, because one machine is enough.
- Every byte a release publishes reaches every application that installs it, and every byte here reaches every search of this repository. Listing what an application compiles against keeps the rest out of its `lib/`.
- One declaration serves the release tool, `frappe new` and the checks, so what is tested, what a lock pins and what is published cannot differ.
- A fact stated once cannot drift. A Markdown edition generated from the pages, and a skill that links instead of restating, add no second source.
- Rejected: moving all documentation to another repository. Contracts must change in the same commit as the code, and the website's checks read the source at that commit.
- Rejected: hiding prose from search with ignore files. It would still ship in applications and still drift.
- Rejected: Markdown pages written by hand beside the site, which would drift from it.
- Rejected: one record per feature. A later feature amended the record of an earlier one, so a reader followed a chain of records to learn what was chosen.
- Rejected: records that restate the rules in force. They were a second source for what the code, its tests, the doc comments and the website state, and the choices were buried under the rules.
- Rejected: a byte cap on records. A subject that outgrew the cap continued in another record; a record that holds only choices is short without one.
- SweetTalk is a shard of its own. A directory that holds only what an application installs is published as it stands, with nothing to pick out of it and nothing to leave behind. Its records sit apart, and framework records state none of its choices, so a reader of either finds only that side's decisions.
- SweetTalk's specs, fixtures and checks run on the framework's database, fixtures and gate, and its guide is built and checked with the site. Beside the framework's, each runs on every change to either side.
- A framework that names no library cannot come to depend on one. The check holds that at the line that would break it.
- An entry's number changes when a record is edited, and a citation by number then points at another choice without failing any check. A cited anchor is checked for the same reason: a citation nothing resolves breaks silently when a section is renamed.
