# caramelize.dev

Static marketing site and preview documentation for Caramel 0.15.0.
`source/site.html` holds the pages: the landing and catalog templates, the page helpers
and every page's content. `build.mjs` renders them through `shell.mjs` (header, rail,
outline) into crawlable HTML pages with native links and ordinary window scrolling.
`source/site.css` is the look, and `source/site.js` the behaviour: theme toggle, search,
recipe finder and section outline. Recipes keep their Draft and Needs validation labels;
publishing the site does not mean the framework examples have been tested.

`source/site.html` documents the current release. Its routes and metadata follow
`shard.yml`; update its release labels and guides before `scripts/release`, which
refuses a version the site does not name. `/docs/` and `/cookbook/` lead to the
current edition.
The internationalization guide covers opt-in catalogs, typed messages, locale
selection, formatting, framework wording, explicit locale scopes for jobs, and the
catalog's reserved keys. Best practices and the Reference pages (routes and
contracts, actions, views, SugarORM, Cold Brew, Corretto, Crema, security defaults,
commands, and the local environment) document the current APIs. `commands.mjs`
reads the command lists from `src/frappe/commands.cr`,
`src/caramel/command_line.cr`, `src/caramel/crema/core_commands.cr`, and `src/latte.cr` at
build time, and `check.mjs`
fails when a command, a framework catalog key, or a Crema metric, environment
variable or editor preset is missing from its page.
`markdown.mjs` turns each docs and cookbook page into Markdown, written as `index.md`
beside its `index.html` and listed in `/docs/X.Y.Z/llms.txt`; it throws on a tag it
does not convert. `check.mjs` also fails when the SweetTalk skill
(`templates/skills/sweettalk/SKILL.md`) cites a section the Markdown edition lacks, and
when the guide or the skill still calls something planned for a release the edition
has reached.
`source/mark.svg` is the Caramel mark, the latte's cup and caramel spiral: the header
inlines it beside the wordmark and the build sets it on a dark tile as the favicon.
`dist` is recreated on every build, so keep authored content under `source`.

Requires Node.js 22 or newer; no npm install is needed. Code examples declare
their language in `source/site.html`. `highlight.mjs` uses a pinned, vendored
Highlight.js core and grammars to highlight Crystal, Bash, YAML, and Markdown at
build time. Code keeps one dark palette in both colour schemes; the browser
does not load a syntax-highlighting runtime. See `vendor/highlightjs/README.md`
for the upstream version, license, and update procedure.

```sh
node website/build.mjs
node website/check.mjs
python3 -m http.server 8768 --directory website/dist
```

`scripts/check website` runs the build and the checks.

Source lives on `main`; compiled HTML is published from the `gh-pages` branch.
To build, validate, and publish the current website with existing Git credentials:

```sh
node website/publish.mjs
```

The publisher refuses to run unless `HEAD` is the commit on origin's `main` and the
files the build reads (`website/`, `shard.yml`, `templates/application/AGENTS.md` and
`templates/skills/sweettalk/SKILL.md`) are committed, so every `gh-pages` commit names
a `main` commit that holds its source. Publish after the release push. It uses a temporary
Git index, preserves deployment history, and does not switch the working branch or
alter the working index. It adds the current edition and keeps every earlier
`/docs/X.Y.Z/` and `/cookbook/X.Y.Z/` from `gh-pages` history. Redirect pages are
not editions: each run drops them and rewrites one for every release tag with no
edition, pointing at the newest edition of its minor, beside copies of that edition's
`llms.txt` and `index.md` files ([ADR 0026](../docs/decisions/0026-writing-homes.md)
decision 1). `--dry-run` prints what it keeps and the tree, and publishes nothing.
After pushing without force it waits up to 15 minutes until every edition answers 200;
republishing a live version answers at once. Generated output is ignored on `main`.

`templates/github-pages.workflow.yml` is an optional GitHub Actions workflow for
automatic builds on main. It deploys only `website/dist`, the current edition, so it
must not replace `publish.mjs`, which keeps the earlier editions. The current GitHub credential cannot upload workflows.
To enable it later, authorize the `workflow` scope, move the template to
`.github/workflows/website.yml`, and switch Pages to GitHub Actions.

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
