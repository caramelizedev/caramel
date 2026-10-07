# caramelize.dev

Static marketing site and preview documentation for Caramel 0.8.0.
The approved design lives in `source/site.html`. `build.mjs` exports that design
to crawlable HTML pages with native links and ordinary window scrolling.
The full-window documentation shell uses `source/docs.css` and `source/docs.js`,
with sticky desktop navigation, a section outline, and a collapsible mobile menu.
Recipes retain their draft and framework-gap labels; publishing the site does
not mean the framework examples have been tested.

The site documents the current framework state only. Its routes and metadata
follow `shard.yml`; update the release labels and guides in `source/site.html`
when the framework ships. `/docs/` and `/cookbook/` lead to the current edition.
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
`source/mark.svg` is the Caramel mark, the latte's cup and caramel spiral: the build
inlines it beside the wordmark in the header and sets it on a dark tile as the
favicon. `dist` is recreated on every build, so keep authored content under `source`.

Requires Node.js 22 or newer; no npm install is needed. Code examples declare
their language in `source/site.html`. `highlight.mjs` uses a pinned, vendored
Highlight.js core and grammars to highlight Crystal, Bash, YAML, and Markdown at
build time. Token colors follow the site's light and dark palettes; the browser
does not load a syntax-highlighting runtime. See `vendor/highlightjs/README.md`
for the upstream version, license, and update procedure.

```sh
node website/build.mjs
node website/check.mjs
python3 -m http.server 8768 --directory website/dist
```

Source lives on `main`; compiled HTML is published from the `gh-pages` branch.
To build, validate, and publish the current website with existing Git credentials:

```sh
node website/publish.mjs
```

The publisher refuses to run while `website/` has uncommitted changes, so every
`gh-pages` commit names a `main` commit that holds its source. It uses a temporary
Git index, preserves deployment history, and does not switch the working branch or
alter the working index. It pushes without force. Generated output is ignored on
`main`.

`templates/github-pages.workflow.yml` is an optional GitHub Actions workflow for
automatic builds on main. The current GitHub credential cannot upload workflows.
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
