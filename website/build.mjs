import fs from 'node:fs';
import path from 'node:path';
import { highlightCode } from './highlight.mjs';
import { commandRows } from './commands.mjs';

// The approved prototype is the design/content source. Export real documents,
// normal page scrolling, and shared assets without a client framework.
const source = fs.readFileSync(new URL('./source/site.html', import.meta.url), 'utf8');
const version = fs.readFileSync(new URL('../shard.yml', import.meta.url), 'utf8')
  .match(/^version: (\S+)$/m)[1];
if (!source.includes(`Caramel ${version}`)) throw new Error('Update the site for the current release.');
const out = new URL('./dist/', import.meta.url);
fs.rmSync(out, {recursive: true, force: true});
fs.mkdirSync(new URL('assets/', out), { recursive: true });
const sections = {
  learn: 'docs/getting-started', map: 'docs/project-map',
  agents: 'docs/agents', deploy: 'docs/deployment',
  testing: 'docs/testing-html', releases: 'docs/releases',
  i18n: 'docs/internationalization', tenancy: 'docs/multi-tenancy', crema: 'docs/observability', cremaref: 'docs/crema', practices: 'docs/best-practices',
  routing: 'docs/routes-and-contracts', actions: 'docs/actions-and-responses',
  views: 'docs/views', sugarorm: 'docs/sugarorm', coldbrew: 'docs/cold-brew',
  corretto: 'docs/corretto', security: 'docs/security', commands: 'docs/commands',
  local: 'docs/local-environment',
  crud: 'cookbook/create-a-resource', json: 'cookbook/return-json',
  uploads: 'cookbook/uploads', jobs: 'cookbook/background-jobs',
  islands: 'cookbook/third-party-components',
  webhooks: 'cookbook/webhooks',
  sessions: 'cookbook/revocable-sessions',
};
const routesFor = edition => ({home: '/', cookbook: `/cookbook/${edition.version}/`,
  ...Object.fromEntries(Object.keys(edition.pages).map(key => {
    const [section, slug] = sections[key].split('/');
    return [key, `/${section}/${edition.version}/${slug}/`];
  }))});
const script = source.match(/<script>([\s\S]*?)<\/script>/)[1];
const dataSource = script.slice(script.indexOf('  const escapeText'), script.indexOf('  function persist'));
const { pages, tasks, recipes, searchIndex } = Function(dataSource + '\nreturn {pages,tasks,recipes,searchIndex};')();
const current = {version, pages: Object.fromEntries(Object.entries(pages).map(([key, render]) => [key, render()])), tasks, recipes, searchIndex};
// The command lists are read from the sources that define the commands.
current.pages.commands = current.pages.commands.replace(/<div class="c-files" data-commands="(\w+)"><\/div>/g,
  (_, kind) => `<div class="c-files" data-commands="${kind}">${commandRows(kind)}</div>`);
// The agent guide is the AGENTS.md that frappe new writes into applications.
const agentGuide = fs.readFileSync(new URL('../templates/application/AGENTS.md', import.meta.url), 'utf8').trim();
const guideSlot = '<pre class="c-plain" id="c-agent-markdown" hidden><code class="language-markdown"></code></pre>';
if (!current.pages.agents.includes(guideSlot)) throw new Error('The agents page has no slot for the agent guide.');
const escapedGuide = agentGuide.replace(/[&<>]/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;'}[c]));
current.pages.agents = current.pages.agents.replace(guideSlot, () => guideSlot.replace('></code>', `>${escapedGuide}</code>`));
const routes = routesFor(current);
const links = (html, routes) => html.replace(/<button\b([^>]*\bdata-page="([^"]+)"[^>]*)>([\s\S]*?)<\/button>/g,
  (_, attrs, page, content) => `<a${attrs} href="${routes[page]}">${content}</a>`);
// The header and the favicon draw the same mark: the latte's cup and caramel spiral.
const mark = fs.readFileSync(new URL('./source/mark.svg', import.meta.url), 'utf8').trim();
const markSlot = '<span class="c-mark" aria-hidden="true"></span>';
if (!source.includes(markSlot)) throw new Error('The header has no slot for the mark.');
const template = source.slice(source.indexOf('<div id="caramel-site"'), source.indexOf('<script>'))
  .replace(markSlot, `<span class="c-mark" aria-hidden="true">${mark}</span>`)
  .replace('<i data-lucide="search" aria-hidden="true"></i>', '')
  .replaceAll('Design preview', 'Documentation preview');
const taskHTML = task => `<strong>${task.title}</strong>${task.files.map(f => `<code>${f}</code>`).join('')}<p>${task.detail}</p><small>${task.proof}</small>`;
let css = [...source.matchAll(/<style>([\s\S]*?)<\/style>/g)].map(m => m[1]).join('\n');
// Imports must precede all style rules, including those from the base design.
const imports = [...css.matchAll(/@import url\([^\n]+?\);/g)].map(m => m[0]).join('\n');
css = css.replace(/@import url\([^\n]+?\);/g, '').replaceAll('button', ':is(button,a[data-page])');
css = imports + '\n' + css + `
html{color-scheme:light dark;background:light-dark(#f1eee6,#201d18);scroll-padding-top:110px}
body{margin:0}button,a{cursor:pointer}a{font:inherit}
#caramel-site.c-scroll{height:auto;overflow:visible;max-width:1440px;margin:auto}
#caramel-site a[data-page]{color:inherit;text-decoration:none}
#caramel-site .c-brand{color:var(--ink)}
#caramel-site .c-doccontent p,#caramel-site .c-doccontent .c-lede{font-size:16px}
#caramel-site .c-doccontent code,#caramel-site .c-snippet pre{font-size:13px}
#caramel-site .c-sidebar a[data-page],#caramel-site .c-nav a[data-page]{font-size:14px}
#caramel-site .c-doccontent h2{scroll-margin-top:110px}
#caramel-site.c-scroll{--stage-height:max(500px,calc(100svh - var(--header-height,85px)));--step-travel:clamp(340px,60svh,620px)}
#caramel-site.c-scroll .l-sticky{height:var(--stage-height)}
#caramel-site.c-scroll #l-story{height:calc(var(--stage-height) + 5 * var(--step-travel))}
#caramel-site.c-scroll .l-feature{align-items:center}
#caramel-site.c-scroll .l-art{height:min(650px,calc(var(--stage-height) - 64px))}
#caramel-site.c-scroll .l-diagram{width:min(100%,460px,calc((var(--stage-height) - 64px) * .766))}
#caramel-site.c-scroll .l-copy{min-height:350px}
#caramel-site.c-scroll .l-chapter[data-chapter="0"] p{font-size:16px}
#caramel-site .c-recipe{display:flex;text-align:left}
#caramel-site .c-results a{display:block}
@container(max-width:700px){
  #caramel-site.c-scroll .l-feature{height:min(740px,calc(var(--stage-height) - 60px));grid-template-rows:170px minmax(0,1fr) 55px}
  #caramel-site.c-scroll .l-art{height:100%;min-height:0}
  #caramel-site.c-scroll .l-diagram{width:min(90%,300px);max-height:100%}
  #caramel-site.c-scroll .l-copy{min-height:0}
  #caramel-site.c-scroll .l-chapter[data-chapter="0"] p{font-size:14px}
  #caramel-site.c-scroll .l-scroll-hint{bottom:12px}
}
@media(prefers-reduced-motion:reduce){html{scroll-behavior:auto}}
`;
fs.writeFileSync(new URL('assets/site.css', out), css);

const generatedRoutes = [];
const recipeHTML = current.recipes.map(r => `<a class="c-recipe" data-page="${r.page}" href="${routes[r.page]}"><span class="c-tag ${r.status === 'gap' ? 'c-draft' : ''}">${r.status === 'gap' ? 'Framework gap' : 'Draft recipe'}</span><h2>${r.title}</h2><p>${r.text}</p><footer><span>${r.category} · ${current.version}</span></footer></a>`).join('');
const clientData = `  const tasks = ${JSON.stringify(current.tasks)};\n  const recipes = ${JSON.stringify(current.recipes)};\n  const searchIndex = ${JSON.stringify(current.searchIndex)};\n`;
let client = script.replace(dataSource, clientData)
  .replace("let currentPage = 'home';", 'let currentPage = document.body.dataset.page;')
  .replace('root.scrollTop-storyStart', 'window.scrollY-storyStart')
  .replace("root.addEventListener('scroll'", "window.addEventListener('scroll'")
  .replace(/  function persist\(\)\{[^\n]+\}/, '  function persist(){}')
  .replace(/  function showPage\([^\n]+\n/, '')
  .replace(/  function restore\([^\n]+\n/, '')
  .replace(/  restore\(window.openai[^\n]+\n/, '  renderTask(); if(currentPage === "cookbook") renderRecipes(); queueScrollUpdate();\n')
  .replace(/  if\(globalThis.Tweak\)[^\n]+\n/, '')
  .replace("if(b.dataset.page){showPage(b.dataset.page);if(b.dataset.searchResult)toggleSearch(false);}", '')
  .replaceAll(".addEventListener('input',renderRecipes)", "?.addEventListener('input',renderRecipes)");
// Navigation remains native after dynamic search and recipe rendering.
const clientLinks = `
  const routes = ${JSON.stringify(routes)};
  function linkify(){root.querySelectorAll('button[data-page]').forEach(button=>{const a=document.createElement('a');for(const attr of button.attributes)a.setAttribute(attr.name,attr.value);a.href=routes[button.dataset.page];a.innerHTML=button.innerHTML;button.replaceWith(a);});}
  new MutationObserver(linkify).observe(root,{childList:true,subtree:true});
  linkify();
`;
client = client.replace('  const main =', clientLinks + '\n  const main =');
fs.writeFileSync(new URL('assets/site.js', out), client);


const sidebar = template.match(/<aside class="c-sidebar"[\s\S]*?<\/aside>/)[0]
  .replace('<aside', '<nav').replace('</aside>', '</nav>')
  .replace('<h3>Start here</h3>', `<div class="c-sidebar-edition"><strong>Documentation</strong><span>${version}</span></div><h3>Start here</h3>`)
  .replace('<h3>Build something</h3>', `<h3>Build something</h3><a data-page="cookbook" href="${routes.cookbook}">All recipes</a>`);
const docNavigation = `<details class="c-docnav" open><summary>Browse documentation <span aria-hidden="true">+</span></summary>${sidebar}</details>`;

const escapeAttr = str => str.replaceAll('&', '&amp;').replaceAll('"', '&quot;');
for (const [key, route] of Object.entries(routes)) {
  generatedRoutes.push(route);
  let body = template;
  let title = 'Caramel — A little structure. A lot of possibility.';
  let description = 'A Crystal web framework with PostgreSQL, typed HTML, and a clear place for every change.';
  if (current.pages[key]) {
    const content = current.pages[key];
    title = content.match(/<h1>(.*?)<\/h1>/)[1] + ` · Caramel ${current.version}`;
    description = content.match(/<p class="c-lede">(.*?)<\/p>/)[1];
    body = body.replace('<article class="c-doccontent" id="c-article"></article>', `<article class="c-doccontent" id="c-article">${content}</article>`)
      .replace('<div id="c-map-result" class="c-route-map" aria-live="polite"></div>', `<div id="c-map-result" class="c-route-map" aria-live="polite">${taskHTML(current.tasks.endpoint)}</div>`)
      .replace('<aside class="c-toc" aria-label="On this page" id="c-toc"></aside>', `<aside class="c-toc" aria-label="On this page" id="c-toc"><p>ON THIS PAGE</p>${[...content.matchAll(/<h2 id="([^"]+)">(.*?)<\/h2>/g)].map(m => `<a href="#${m[1]}">${m[2]}</a>`).join('')}</aside>`);
  }
  if (key === 'cookbook') { title = `Cookbook · Caramel ${current.version}`; description = 'Task-based recipes, supported application APIs, and proof commands. Explore the draft collection and remaining framework gaps.'; }
  if(key !== 'home') body = body.replace(/    <div id="c-home">[\s\S]*?(?=    <div id="c-book")/, '');
  if(key !== 'cookbook') body = body.replace(/    <div id="c-book" hidden>[\s\S]*?(?=    <div id="c-doc")/, '');
  else body = body.replace('<div id="c-book" hidden>', '<div id="c-book">').replace('<div class="c-recipe-grid" id="c-recipes"></div>', `<div class="c-recipe-grid" id="c-recipes">${recipeHTML}</div>`);
  if(!current.pages[key]) body = body.replace(/    <div id="c-doc" hidden>[\s\S]*?(?=  <\/main>)/, '');
  else body = body.replace('<div id="c-doc" hidden>', '<div id="c-doc">');
  if (key !== 'home') {
    body = body.replace('class="c-awards c-zed c-scroll"', 'class="c-awards c-zed c-scroll c-documentation"')
      .replace('aria-label="Caramel website. Scroll to explore the latte."', 'aria-label="Caramel documentation"')
      .replace(/<div class="c-docbar">[\s\S]*?<\/div>/, '');
    if (current.pages[key]) body = body.replace(/<aside class="c-sidebar"[\s\S]*?<\/aside>/, docNavigation);
    else body = body.replace('<div id="c-book">', `<div id="c-book" class="c-catalog-layout">${docNavigation}<div class="c-catalog">`)
      .replace('    </div>\n  </main>', '    </div></div>\n  </main>');
    const contentId = current.pages[key] ? 'c-article' : 'c-catalog-content';
    body = body.replace('<main id="c-main">', `<a class="c-skip" href="#${contentId}">Skip to content</a><main id="c-main">`)
      .replace('id="c-article"', 'id="c-article" tabindex="-1"')
      .replace('<div class="c-catalog">', '<div class="c-catalog" id="c-catalog-content" tabindex="-1">');
  }
  body = highlightCode(links(body, routes)).replaceAll(`data-page="${key}"`, `data-page="${key}" aria-current="page"`);
  // Keep the top-level section selected when reading one of its child pages.
  const navSection = key === 'home' ? null : key === 'agents' ? 'agents'
    : (key === 'cookbook' || route.startsWith('/cookbook/')) ? 'cookbook' : 'map';
  body = body.replace(/<nav class="c-nav"[\s\S]*?<\/nav>/, nav => {
    nav = nav.replace(/ aria-current="[^"]+"/g, '');
    return navSection ? nav.replace(`data-page="${navSection}"`, `data-page="${navSection}" aria-current="${key === navSection ? 'page' : 'true'}"`) : nav;
  });
  const canonical = `https://caramelize.dev${route}`;
  const docsAssets = key === 'home' ? '' : '<link rel="stylesheet" href="/assets/docs.css"><script src="/assets/docs.js" defer></script>';
  const html = `<!doctype html>\n<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title}</title><meta name="description" content="${escapeAttr(description)}"><link rel="canonical" href="${canonical}"><meta property="og:title" content="${escapeAttr(title)}"><meta property="og:description" content="${escapeAttr(description)}"><meta property="og:url" content="${canonical}"><meta property="og:type" content="website"><meta name="color-scheme" content="light dark"><link rel="icon" href="/favicon.svg" type="image/svg+xml"><link rel="stylesheet" href="/assets/site.css"><script src="/assets/site.js" defer></script></head><body data-page="${key}">${body}</body></html>\n`;
  const dest = new URL('.' + route + 'index.html', out);
  fs.mkdirSync(path.dirname(dest.pathname), {recursive:true});
  fs.writeFileSync(dest, html.replace('</head>', `${docsAssets}</head>`));
}
for (const asset of ['docs.css', 'docs.js']) {
  fs.copyFileSync(new URL(`./source/${asset}`, import.meta.url), new URL(`assets/${asset}`, out));
}
for (const [route, target] of Object.entries({'/docs/': `/docs/${version}/getting-started/`, [`/docs/${version}/`]: `/docs/${version}/getting-started/`, '/cookbook/': `/cookbook/${version}/`})) {
  const dest = new URL('.' + route + 'index.html', out);
  fs.mkdirSync(path.dirname(dest.pathname), {recursive: true});
  fs.writeFileSync(dest, `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Caramel documentation</title><link rel="canonical" href="https://caramelize.dev${target}"><meta http-equiv="refresh" content="0;url=${target}"></head><body><a href="${target}">Read Caramel ${version} documentation</a></body></html>`);
}
// The favicon sets the mark on the dark glass tile of the GitHub avatar.
const tileGlow = '<radialGradient id="tile-glow" cx=".5" cy=".5" r=".64"><stop offset="0" stop-color="#4c3223"/><stop offset=".58" stop-color="#2b211a"/><stop offset="1" stop-color="#1d1a17"/></radialGradient>';
const glass = '<circle cx="256" cy="256" r="218" fill="none" stroke="#efdbb9" stroke-opacity=".32" stroke-width="3"/><path d="M51.1 181.4A218 218 0 0 1 181.4 51.1" fill="none" stroke="#fff8ea" stroke-opacity=".55" stroke-width="3" stroke-linecap="round"/>';
const cup = mark.replace('<svg ', '<svg x="51" y="51" width="410" height="410" ');
fs.writeFileSync(new URL('favicon.svg', out), `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"><defs>${tileGlow}</defs><rect width="512" height="512" rx="112" fill="url(#tile-glow)"/>${glass}${cup}</svg>\n`);
fs.writeFileSync(new URL('robots.txt', out), 'User-agent: *\nAllow: /\nSitemap: https://caramelize.dev/sitemap.xml\n');
fs.writeFileSync(new URL('.nojekyll', out), '');
fs.writeFileSync(new URL('CNAME', out), 'caramelize.dev\n');
fs.writeFileSync(new URL('sitemap.xml', out), `<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">${generatedRoutes.map(r=>`<url><loc>https://caramelize.dev${r}</loc></url>`).join('')}</urlset>`);
fs.writeFileSync(new URL('404.html', out), '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Page not found · Caramel</title><link rel="icon" href="/favicon.svg" type="image/svg+xml"><body style="background:#201d18;color:#eee8dd;font:18px/1.6 system-ui;padding:10vw"><h1>This page has moved on.</h1><p><a style="color:#e9a278" href="/">Back to Caramel</a></p></body></html>');
console.log(`Built ${generatedRoutes.length} pages for ${version} in dist.`);
