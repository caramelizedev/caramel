# caramelize.dev

Static marketing site and preview documentation for Caramel 0.4.0.
The approved design lives in `source/site.html`. `build.mjs` exports that design
to crawlable HTML pages with native links and ordinary window scrolling.
The full-window documentation shell uses `source/docs.css` and `source/docs.js`,
with sticky desktop navigation, a section outline, and a collapsible mobile menu.
Recipes retain their draft and framework-gap labels; publishing the site does
not mean the framework examples have been tested.

Requires Node.js 22 or newer, with no npm dependencies.

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

The publisher uses a temporary Git index, preserves deployment history, and does
not switch the working branch or alter the working index. It pushes without force.
Generated output is ignored on `main`.

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
