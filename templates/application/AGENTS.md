# Working in this Caramel application

shard.lock pins this application's Caramel release. Use the documentation for that
release: https://caramelize.dev/docs/VERSION/agents/, with VERSION from shard.lock.
Every page of it in Markdown: https://caramelize.dev/docs/VERSION/llms.txt
lib/caramel holds the part of the framework this application compiles against: read
it, never edit it. frappe setup restores it from shard.lock.

Routes: config/routes.cr
Actions and contracts: app/actions/
Data: app/models/ and app/changesets/
HTML: app/views/
Jobs: app/jobs/
Translations: app/locales/ (enable with frappe make locale CODE)
Tenants: the tenant block in config/routes.cr (enable with frappe make tenancy MODEL)
Request specs: spec/requests/

Discover: frappe agent-manifest; frappe routes
Verify: frappe check; frappe corretto; frappe lint
Diagnose: frappe check --agent (apply its PATCH lines); frappe expand FILE:LINE:COL
Debug: frappe errors --agent; frappe traces --agent; frappe trace last-error --md; frappe db diagnose
With i18n: frappe translations

Surface unsupported requirements before editing framework internals, and link the
matching task recipe: https://caramelize.dev/cookbook/VERSION/
