// Each page's key in site.html and the section and slug it is published under.
// build.mjs writes `/<section>/<version>/<slug>/`; check.mjs reads it back.
export const sections = {
  learn: 'docs/getting-started', map: 'docs/project-map',
  agents: 'docs/agents', deploy: 'docs/deployment',
  testing: 'docs/testing-html', releases: 'docs/releases',
  i18n: 'docs/internationalization', tenancy: 'docs/multi-tenancy', crema: 'docs/observability', cremaref: 'docs/crema', practices: 'docs/best-practices',
  routing: 'docs/routes-and-contracts', actions: 'docs/actions-and-responses',
  views: 'docs/views', sugarorm: 'docs/sugarorm', coldbrew: 'docs/cold-brew',
  corretto: 'docs/corretto', security: 'docs/security', commands: 'docs/commands',
  local: 'docs/local-environment', boxoffice: 'docs/box-office', sweettalk: 'docs/sweettalk',
  crud: 'cookbook/create-a-resource', json: 'cookbook/return-json',
  forms: 'cookbook/rendered-forms',
  uploads: 'cookbook/uploads', jobs: 'cookbook/background-jobs',
  islands: 'cookbook/third-party-components',
  webhooks: 'cookbook/webhooks',
  sessions: 'cookbook/revocable-sessions',
  sums: 'cookbook/sums-and-groups',
};
// The page key of a built file such as docs/0.15.0/box-office/index.html.
export const pageKey = file => {
  const [section, , slug] = file.split('/');
  return Object.keys(sections).find(key => sections[key] === `${section}/${slug}`);
};
