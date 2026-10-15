---
name: caramel-docs
description: How Caramel's documentation is shaped and worded. Use whenever writing, adding, changing or reviewing Caramel documentation, such as a guide, reference page, cookbook recipe, learning step or upgrade note in website/source/site.html.
---

# Writing a page in website/source/site.html

`CONTRIBUTING.md` (Writing) and ADR 0026 (`docs/decisions`) say where writing lives;
`website/README.md` describes the build and its checks. Every page is also an `index.md`
for agents: what only works visually is lost to them.

## The rules, applied to pages

1. Every fact has one page. Link to the page that states it; never copy it. A guide
   teaches; its reference lists.
2. Every page declares its contract, in a table under the lede.
3. Every page follows its type: the type fixes the order of sections.
4. Nothing is claimed unless it ran. Status says how far a page is tested; gaps get a section.
5. Every step is safe to run twice: each command is followed by what to expect.
6. Every page ends in proof: the commands that check it, and what passing looks like.

## Page types, in section order

- **Learn** (`Learn / The Bookshelf path`): contract, then `01 · Verb the thing` steps,
  each a `Terminal` snippet and an Expect line; Prove it; `next()`.
- **Guide** (`Guides / Topic`): contract; a guide map when it has more than eight
  sections; its tasks in order, imperative ("Follow one request"); What does not compile;
  Not covered yet; Prove it; `next()`.
- **Recipe** (`Cookbook / Category`): `tags()`, contract, "Where the change goes" as
  `files()`, "Decide before you generate" for choices that change the output, `steps()`
  each with Expect, options, Prove it, a `note()` saying what the status means, `next()`.
- **Reference** (`Reference / Component`): contract, Limits at a glance, one h2 per rule in
  the present tense ("Views escape text and attributes"), each with its rules table;
  Prove it; `next()`.
- **Current release**: one h2 per version, "Upgrading to X.Y.Z", opening "Upgrade Caramel
  and Frappé together." then which of migrations, removals and edits apply, and one
  bullet per change.

## Anatomy

- `heading(eyebrow, title, lede)`. The title is two to six words ending in a full stop, a
  promise or an instruction: "Give your data shape." Product names are proper nouns; no
  coffee puns. The lede says what the reader will be able to do.
- **Contract**: `contract(rows)`: three or four rows from Release, Needs, You will have,
  Covers, Status and Proved by. Every value is stated on the page.
- **Expect**: `expect(html)` after each command: what the release does. Never invent
  output; leave the line out sooner.
- **Rules table**: `rules(rows)`: Condition | Outcome, the outcome in the framework's
  verb: *fails compilation*, *refuses*, *answers 422*, *raises ArgumentError*; `'ok'`
  marks a neutral outcome.
- **Limits at a glance**: `limits(page, rows)`: Limit | Value, each a number the page
  states again in its section.
- **Guide map**: `guideMap(page, stages)`: stages, each linking its sections' anchors;
  `kicker('Stage N · Name')` above each stage's first h2.
- **Prove it**: `prove(id, title, html)`: the last h2 before `next()`: a snippet of the
  commands, then `passing(html)`.
- **Sections**: h2 only, each `id="c-<page>-<topic>"`, short and stable.

## Voice

Short present-tense sentences, one thought each. Exact numbers and names. Say what
Caramel does and what the application must still do. No marketing adjectives or softeners.

- Write "Declaring the queue twice fails compilation.", not "Be careful not to declare the queue twice."
- Write "Payloads hold at most 8,000 bytes.", not "Keep payloads reasonably small."

## Components

Use the page helpers; `website/markdown.mjs` throws on any other tag.

- `snippet(caption, code, language)`: captioned with the file path or where it runs
  (`Terminal · inside the application`).
- `files([[path, role], …])` when each role is two to four words; `lookup(columns, rows)`
  for settings, calls and flags.
- `steps([[title, html], …])`: a recipe's numbered commands, each a snippet and its Expect.
- `choices([[title, html], …])`: Decide before you generate.
- `note(title, body, label)`: rare; the title states the point as a sentence; a recipe's
  status note is labelled `Draft` or `Needs validation`.
- `tags()` on recipes only; `tags('Recipe needs validation')` when Caramel lacks a part,
  `tags('Proved by scripts/check page-KEY')` once that check runs it, and the `recipes`
  row's `status` to match.
- `<ul class="c-status-list">` with `<small>` labels: what a recipe still has to show.
- `<button class="c-secondary cursor-interaction" data-page="KEY">Verb phrase →</button>`
  links another page.

## Look

Reuse the `light-dark()` tokens and components in `website/source/site.css` and the header,
rail and outline from `website/shell.mjs`. Code uses the `--syntax-*` tokens and stays dark
in both colour schemes. One accent, no icons in prose.

## Adding a page

Add its function to `pages` in `site.html`, its key to `website/sections.mjs`, its entry
to `rail` and `searchIndex` and, for a recipe, to `recipes`; then link to it from pages
that would restate it.

## Before publishing

- The contract is filled, every limit is a number, every failure names its outcome, and
  any fact another page states is a link.
- The status is honest: a recipe is Proved only once its page check has run it.
- A page's application code lives in `spec/fixtures/pages/<key>/` at its in-app paths;
  `scripts/checks/page_<key>.cr` builds it with the page's commands, and each file snippet
  is a block of its file, in file order, every line shown.
- Quote output as the source prints it where the reader runs it: `frappe check` prints
  `OK check N files` when piped, `✓ Type check passed` on a terminal.
- `scripts/check website` passes (`website/README.md` lists its guards), and the page's
  `index.md` in `website/dist` reads well.
