---
name: caramel-docs
description: How Caramel's documentation is shaped and worded. Use whenever writing, adding, changing or reviewing Caramel documentation, such as a guide, reference page, cookbook recipe, learning step or upgrade note in website/source/site.html.
---

# Writing a page in website/source/site.html

Where writing lives, and the rule to state a fact once, are in
[CONTRIBUTING.md](../../../CONTRIBUTING.md) (Writing) and
[ADR 0026](../../../docs/decisions/0026-writing-homes.md). The build and its checks are in
[website/README.md](../../../website/README.md). Every page is also an `index.md` for
agents: anything that only works visually is lost to them.

## The framework's rules, applied to pages

1. Every fact has one page. Link to the page that states it; never copy it.
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
  `files()`, "Decide before you generate" for choices that change the output, numbered
  steps each with Expect, options, Prove it, a `note()` saying what the status means, `next()`.
- **Reference** (`Reference / Component`): contract, Limits at a glance, one h2 per rule in
  the present tense ("Views escape text and attributes"), each with its rules table;
  Prove it; `next()`.
- **Current release**: one h2 per version, "Upgrading to X.Y.Z", opening "Upgrade Caramel
  and Frappé together." then which of migrations, removals and edits apply, then one
  bullet per change saying what to do.

A guide and its reference link to each other: the guide teaches, the reference lists.

## Anatomy

- `heading(eyebrow, title, lede)`. The title is two to six words ending in a full stop, a
  promise or an instruction: "Give your data shape." Product names are proper nouns; docs
  make no coffee puns. The lede says what the reader will be able to do.
- **Contract**: a `<table class="c-map">` of three or four rows from Release, Needs, You
  will have, Covers, Status and Proved by. Every value is stated on the page.
- **Expect**: after each command, `<p><strong>Expect:</strong> …</p>`, what the release
  really does. Never invent output; leave the line out sooner.
- **Rules table**: Condition | Outcome, the outcome in the framework's verb: *fails
  compilation*, *refuses*, *answers 422*, *raises ArgumentError*.
- **Limits at a glance**: Limit | Value, each a number the page states again in its section.
- **Guide map**: a `<ul>` of stages ("Start", "Model", "React", "Limits"), each linking
  its sections' anchors.
- **Prove it**: the last h2 before `next()`: a snippet of the commands, then
  `<p><strong>Passing:</strong> …</p>`.
- **Sections**: h2 only, each `id="c-<page>-<topic>"`, short and stable.

## Voice

Short present-tense sentences, one thought each. Exact numbers and names. Say what
Caramel does and what the application must still do. No marketing adjectives or softeners.

- Write "Declaring the queue twice fails compilation.", not "Be careful not to declare the queue twice."
- Write "Payloads hold at most 8,000 bytes.", not "Keep payloads reasonably small."

## Components

Use the page script's helpers and this markup only; `website/markdown.mjs` throws on a
tag it cannot convert.

- `snippet(caption, code, language)`: captioned with the file path or where it runs
  (`Terminal · inside the application`). Real, copyable code.
- `files([[path, role], …])`: roles of two to four words ("Rules for writes").
- `note(title, body)`: rare; the title states the point as a sentence.
- `tags()` on recipes only; `tags('Recipe needs validation')` when Caramel lacks a part.
- `<ul class="c-status-list">` with `<small>` labels: what a recipe still has to show.
- `<button class="c-secondary cursor-interaction" data-page="KEY">Verb phrase →</button>`
  links another page.
- `<table class="c-map">` for contracts, rules, limits and lookups.

## Look

Colours, type and layout are the `light-dark()` tokens in `site.html` and the shell in
`website/source/docs.css`; reuse them. Code highlighting is built from the `--syntax-*`
tokens. One accent, both colour schemes, no icons in prose.

## Adding a page

Add its function to `pages` in `site.html`, map its key in `website/build.mjs`, list it
in the sidebar, in `searchIndex` and, for a recipe, in `recipes`, then link to it from
pages that would otherwise restate it.

## Before publishing

- The eyebrow names the type, and the sections follow its order.
- The contract is filled, and any fact another page states is a link.
- Every command has an Expect line; every limit is a number; every failure names its outcome.
- The status is honest: a recipe stays Draft until it has run end to end.
- `scripts/check website` passes, and the page's `index.md` in `website/dist` reads well.
