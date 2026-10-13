# ADR 0026: Every kind of writing has one home, and only contracts ship in the framework

Date: 2026-10-03

Status: accepted.

## Context

Shards copies the whole tagged tree into every application's `lib/caramel`, and agents
read and grep it. Status, measurements, investigation diaries and restated facts were
half of the repository's markdown and most of what a repository-wide grep returned.

## Decision

1. Application authors' contract is the website (`website/source/site.html`), published
   per release (each release's edition stays at `/docs/X.Y.Z/` and `/cookbook/X.Y.Z/`:
   publishing adds the current edition and keeps every earlier one, and a release tag
   without an edition redirects to the newest edition of its minor); API detail is in doc comments at the code.
   Each page of an edition also has a Markdown edition for agents, `index.md` beside its
   `index.html`, which the website build converts from the same page and lists in
   `/docs/X.Y.Z/llms.txt`. A release tag without an edition gets copies of its target's
   `llms.txt` and `index.md` files, since agents build those URLs from `shard.lock`.
2. Contributors' contract is `CONTRIBUTING.md`. `AGENTS.md` (which `CLAUDE.md` imports)
   holds only what an agent needs beyond it.
3. How to report a vulnerability, and which releases get security fixes, is
   `SECURITY.md`, where GitHub shows it to reporters.
4. Decisions are ADRs with three sections: Context (optional, the problem), Decision (the
   rules in force) and Reasons (why, and the options rejected). A change that alters a
   decision edits its ADR in the same commit, so the ADR states only what is in force.
5. There is no design RFC; the 2026 RFC is retired to caramelizedev/caramel-notes.
6. Status, measurements, investigations, incident timelines and history stay out of this
   repository: they go to caramelizedev/caramel-notes, a pull request description or the
   CHANGELOG.
7. A fact is stated once and linked from elsewhere.
8. Generated applications get a short README and an `AGENTS.md` (which `CLAUDE.md`
   imports); the website renders its agent guide from that file. `frappe make domain`
   writes the SweetTalk skill, `.claude/skills/sweettalk/SKILL.md` from
   `templates/skills/sweettalk/SKILL.md`, when the application has none. The skill states
   no rule the website does not, and each rule ends with a link to its section in the
   release's Markdown edition, which the website check verifies.
9. `scripts/check prose` enforces where markdown lives, the ADR sections, relative links
   and a byte cap per file.

## Reasons

- Every byte in the tagged tree reaches every application and every repository search.
- A rule stated once cannot drift. A Markdown edition generated from the pages, and a skill
  whose every rule links the page that states it, add no second source.
- Rejected: moving all documentation to another repository, because contracts must change
  in the same commit as the code, and the website's checks read the source at that commit.
- Rejected: hiding prose from search with ignore files, because it would still ship in
  applications and still drift.
- Rejected: Markdown pages written by hand beside the site, which would drift from it.
