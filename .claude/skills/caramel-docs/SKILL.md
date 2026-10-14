---
name: caramel-docs
description: How Caramel's documentation pages are shaped and worded. Use when adding, changing or reviewing a guide, reference page, cookbook recipe, learning step or upgrade note in website/source/site.html.
---

# Writing a page in website/source/site.html

Where writing lives, and the rule to state a fact once, are in
[CONTRIBUTING.md](../../../CONTRIBUTING.md) (Writing) and
[ADR 0026](../../../docs/decisions/0026-writing-homes.md). The build and its checks are in
[website/README.md](../../../website/README.md). This skill covers how a page is shaped.
Every page is also an `index.md` for agents: anything that only works visually is lost to them.

## Page types

- **Learn** (`Learn / The Bookshelf path`): numbered h2 steps, `01 · Install the release`,
  each a short paragraph, one `Terminal` snippet and what to expect when it worked.
- **Guides** (`Guides / Topic`): one capability end to end; h2s are its tasks in order,
  imperative: "Follow one request", "Report errors".
- **Cookbook** (`Cookbook / Category`): one problem in an application. `tags()`, then
  "Where the change goes" as `files()`, the build steps, a test section ("Prove the
  behavior", "Test it", "Check the failure cases"), a `note()` and `next()`.
- **Reference** (`Reference / Component`): every name, field, flag, variable and limit; h2s
  state a rule in the present tense: "Views escape text and attributes".
- **Current release**: one h2 per version, "Upgrading to X.Y.Z", opening "Upgrade Caramel
  and Frappé together." then which of migrations, removals and edits apply, then one bullet
  per change saying what to do.

A guide and its reference page link to each other: the guide teaches, the reference lists.

## Anatomy

- `heading(eyebrow, title, lede)` opens every page.
- **Title**: two to six words ending in a full stop, a promise or an instruction:
  "Give your data shape.", "Every input, declared.", "Safe by default." Product names are
  proper nouns; the docs make no coffee puns (the landing page carries the metaphor).
- **Lede**: one or two sentences on what the reader will be able to do, naming the release
  when the page is version-specific.
- **Sections**: h2 only, each with a short, stable `id="c-<page>-<topic>"`, since skills and
  the Markdown edition link to them. Avoid h3.
- **Close**: an optional `note()`, then `next(page, label)` with the next step as an
  imperative: "Test the response and its effects".

## Voice

- Short present-tense sentences, one thought each, the reader addressed implicitly.
- Exact numbers and names: "1 to 63 characters", "for up to 25 s", `__Host-caramel_csrf`.
- Say what happens on failure: *fails compilation*, *refuses*, *answers 422*, *raises*.
- Separate what Caramel does from what the application must still do.
- Name gaps as gaps: what is supported today, what is missing. Never offer untested code
  as a finished recipe.
- No marketing adjectives or softeners ("simply", "just", "easy", "powerful").
- Follow a claim with the command that proves it: `frappe check`, `frappe corretto`.
- Put types, methods, files, flags, environment variables and statuses in `<code>`.

## Components

Use the helpers at the top of the page script and the markup below, nothing else:
`website/markdown.mjs` throws on a tag it cannot convert.

- `snippet(caption, code, language)`: the main device. The caption is the file path or the
  context: `app/jobs/send_invitation.cr`, `Terminal · inside the application`,
  `spec/requests/books_spec.cr · excerpt`. Name the language unless it is Crystal; only
  the grammars `website/highlight.mjs` vendors are highlighted. Examples are real and copyable.
- `files([[path, role], …])`: where a change goes, each role in two to four words:
  "Rules for writes", "Behavior checks". Also for Always on / Opt in / Development only.
- `note(title, body)`: rare. The title states the point as a sentence: "Plan for repeated
  delivery". For a prerequisite, a boundary of responsibility or a limit not to miss.
- `tags()` on recipes only; `tags('Recipe needs validation')` with the framework-gap
  status in `recipes` when Caramel lacks the capability.
- `<ul class="c-status-list">` with `<small>` labels ("Needs example", "Corretto spec"):
  what a recipe still has to show.
- `<button class="c-secondary cursor-interaction" data-page="KEY">Verb phrase →</button>`:
  a link to another page inside prose; the build turns it into a link.
- `<table class="c-map">` for reference lookups; plain `<ul>` for rules and changes, one
  complete sentence per item.

## Look

Colours, type and layout are the `light-dark()` tokens in `site.html` and the shell in
`website/source/docs.css`; reuse them, never new values. Keep one accent (caramel), both
colour schemes, no icons in prose and no illustrations on docs pages.

## Adding a page

1. Add its function to `pages` in `site.html`.
2. Map its key to `docs/<slug>` or `cookbook/<slug>` in `website/build.mjs`.
3. List it in the sidebar `<aside class="c-sidebar">`, in `searchIndex` and, for a recipe,
   in `recipes`.
4. Link to it from pages that would otherwise restate it.

Then run `scripts/check website` and read the page's `index.md` in `website/dist`.
