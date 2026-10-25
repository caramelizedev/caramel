# caramelize.dev

Marketing site and docs for Caramel 0.19.0.
`source/site.html` holds the pages: templates, helpers and every page's content.
`build.mjs` renders them through `shell.mjs` (header, rail, outline) into crawlable HTML.
`source/site.css` is the look, and `source/site.js` the behaviour: theme toggle, search,
recipe finder and section outline. A recipe is Draft or Needs validation until a check
has built and run it end to end, when it is Proved.

`source/site.html` documents the current release. Its routes and metadata follow
`shard.yml`; update its release labels and guides before `scripts/release`, which
refuses a version the site does not name. `/docs/` and `/cookbook/` lead to the
current edition. `sections.mjs` maps each page key in `site.html` to the section and slug
it is published under; `build.mjs` writes `/<section>/<version>/<slug>/` and `check.mjs`
reads it back. `commands.mjs` reads the command lists from `src/frappe/commands.cr`,
`src/caramel/command_line.cr`, `src/caramel/crema/core_commands.cr` and `src/latte.cr` at
build time. `markdown.mjs` turns each page into Markdown, written as `index.md` beside its
`index.html` and listed in `/docs/X.Y.Z/llms.txt`; it throws on a tag it does not convert.

`check.mjs` holds the built pages to their sources and to the page types of
`.claude/skills/caramel-docs/SKILL.md`:

- Every command, framework catalog key, Crema metric, environment variable and editor
  preset in the source is on its page; the SweetTalk skill
  (`templates/skills/sweettalk/SKILL.md`) cites only sections the Markdown edition has; no
  page or skill still calls something planned for a release the edition has reached.
- A page that shows application code keeps those files, at their in-app paths, under
  `spec/fixtures/pages/<key>/`; `scripts/checks/page_<key>.cr` builds them with the page's
  commands in order (`scripts/check page-<key>`). Each file-captioned snippet is a block of
  that file, blocks come in file order, every fixture line is shown, and other captions
  start with `Terminal`; `quotes` lists pages that show another page's fixture.
- The type's sections: one contract table, Prove it with a Passing line last, ids
  `c-<key>-…`, a guide's "What does not compile" and "Not covered yet", the release guide's
  "Upgrading to X.Y.Z", a reference's Limits at a glance and a table per section, a
  learning path's numbered steps, a recipe's `tags()` matching its `recipes` row and
  naming an existing check when proved.
- An Expect line after each `Terminal` snippet outside Prove it; guide map labels equal to
  headings; outcomes starting with the framework's verb; no sentence of 90 characters or
  more on two pages; no softener (`simply`, `easily`, `reasonably`, `be careful`, `you
  may want`); every CHANGELOG upgrade-note token on the release page.

`source/mark.svg` is the Caramel mark, the latte's cup and caramel spiral: the header
inlines it beside the wordmark and the build sets it on a dark tile as the favicon.
`dist` is recreated on every build, so keep authored content under `source`.

Requires Node.js 22 or newer; no npm install is needed. Code examples declare
their language in `source/site.html`. `highlight.mjs` uses a pinned, vendored
Highlight.js core and grammars to highlight Crystal, Bash, YAML, and Markdown at
build time, in one dark palette; the browser loads no highlighting runtime. See
`vendor/highlightjs/README.md` for the upstream version, license, and update procedure.

`scripts/check website` runs `node website/build.mjs` and `node website/check.mjs`;
`python3 -m http.server 8768 --directory website/dist` serves the result.

Source lives on `main`; `node website/publish.mjs` builds, validates and publishes the
compiled HTML to the `gh-pages` branch with existing Git credentials.

The publisher refuses to run unless `HEAD` is the commit on origin's `main` and the
files the build reads (`website/`, `shard.yml`, `templates/application/AGENTS.md` and
`templates/skills/sweettalk/SKILL.md`) are committed, so every `gh-pages` commit names
a `main` commit that holds its source. Publish after the release push. It uses a temporary
Git index and touches neither the working branch nor the working index. It adds the
current edition and keeps every earlier `/docs/X.Y.Z/` and `/cookbook/X.Y.Z/` from
`gh-pages` history. Redirect pages are not editions: each run rewrites one for every
release tag with no edition, pointing at the newest edition of its minor, beside copies
of that edition's `llms.txt` and `index.md` files
([ADR 0026](../docs/decisions/0026-writing-homes.md) decision 1). `--dry-run` prints what
it keeps and publishes nothing. After pushing it waits up to 15 minutes until every
edition answers 200. Generated output is ignored on `main`.

`templates/github-pages.workflow.yml` is an optional GitHub Actions workflow that deploys
only `website/dist`, the current edition, so it cannot replace `publish.mjs`. To enable it,
authorize the `workflow` scope, move it to `.github/workflows/website.yml` and switch Pages
to GitHub Actions.

## Domain

GitHub Pages uses the root of `gh-pages` as its source and `caramelize.dev` as its
custom domain. In Namecheap, use Domain List → Manage → Advanced DNS:

| Type | Host | Value |
| --- | --- | --- |
| A | @ | 185.199.108.153 |
| A | @ | 185.199.109.153 |
| A | @ | 185.199.110.153 |
| A | @ | 185.199.111.153 |
| CNAME | www | caramelizedev.github.io |

TTL can stay Automatic. Replace conflicting parking/redirect records for those
two hosts; preserve email and unrelated records. Once DNS validates and GitHub
issues the certificate, enable Enforce HTTPS in the repository's Pages settings.

Sources: [GitHub custom domains](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site),
[Namecheap setup](https://www.namecheap.com/support/knowledgebase/article.aspx/9645/2208/how-do-i-link-my-domain-to-github-pages/).
