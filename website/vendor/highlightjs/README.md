# Highlight.js

Build-time files from the `highlight.js@11.12.0` npm package:
`lib/core.js` and the Crystal, Bash, YAML, Markdown, and JavaScript grammars under
`lib/languages/`, renamed to `.cjs` for explicit CommonJS imports.
Trailing whitespace is removed; the upstream code is otherwise unchanged.

Package integrity (SHA-512):
`nbfWpyRMcMrPMmDwJB+dhX/eiaPKtc2RB+0QZskqJ3WjRA/FDS0e9hZrx8EC/lbEv8gXy98FcDbNa/dspAaJMg==`

Upstream: https://github.com/highlightjs/highlight.js
License: BSD-3-Clause; see `LICENSE`.

The site build uses these local files without an npm install or browser runtime.
When updating, download the pinned npm package with `npm pack --ignore-scripts`,
replace these files and the license, and run the site build and checks.
