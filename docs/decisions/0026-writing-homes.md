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
2. Contributors' contract is `CONTRIBUTING.md`. `AGENTS.md` (which `CLAUDE.md` imports)
   holds only what an agent needs beyond it.
3. Decisions are ADRs with three sections: Context (optional, the problem), Decision (the
   rules in force) and Reasons (why, and the options rejected). A change that alters a
   decision edits its ADR in the same commit, so the ADR states only what is in force.
4. There is no design RFC; the 2026 RFC is retired to caramelizedev/caramel-notes.
5. Status, measurements, investigations, incident timelines and history stay out of this
   repository: they go to caramelizedev/caramel-notes, a pull request description or the
   CHANGELOG.
6. A fact is stated once and linked from elsewhere.
7. Generated applications get a short README and an `AGENTS.md` (which `CLAUDE.md`
   imports); the website renders its agent guide from that file.
8. `scripts/check prose` enforces where markdown lives, the ADR sections, relative links
   and a byte cap per file.

## Reasons

- Every byte in the tagged tree reaches every application and every repository search.
- A rule stated once cannot drift.
- Rejected: moving all documentation to another repository, because contracts must change
  in the same commit as the code, and the website's checks read the source at that commit.
- Rejected: hiding prose from search with ignore files, because it would still ship in
  applications and still drift.
