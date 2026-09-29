import fs from 'node:fs';
import path from 'node:path';

// The approved prototype is the design/content source. Export real documents,
// normal page scrolling, and shared assets without a client framework.
const source = fs.readFileSync(new URL('./source/site.html', import.meta.url), 'utf8');
const out = new URL('./dist/', import.meta.url);
fs.mkdirSync(new URL('assets/', out), { recursive: true });
const routes = {
  home: '/', cookbook: '/cookbook/0.4.0/',
  learn: '/docs/0.4.0/getting-started/', map: '/docs/0.4.0/project-map/',
  agents: '/docs/0.4.0/agents/', deploy: '/docs/0.4.0/deployment/',
  crud: '/cookbook/0.4.0/create-a-resource/', json: '/cookbook/0.4.0/return-json/',
  uploads: '/cookbook/0.4.0/uploads/', jobs: '/cookbook/0.4.0/background-jobs/',
  webhooks: '/cookbook/0.4.0/webhooks/',
};
const script = source.match(/<script>([\s\S]*?)<\/script>/)[1];
const dataSource = script.slice(script.indexOf('  const escapeText'), script.indexOf('  function persist'));
const { pages, tasks, recipes } = Function(dataSource + '\nreturn {pages,tasks,recipes};')();
const links = html => html.replace(/<button\b([^>]*\bdata-page="([^"]+)"[^>]*)>([\s\S]*?)<\/button>/g,
  (_, attrs, page, content) => `<a${attrs} href="${routes[page]}">${content}</a>`);
const template = source.slice(source.indexOf('<div id="caramel-site"'), source.indexOf('<script>'))
  .replace('<i data-lucide="search" aria-hidden="true"></i>', '')
  .replaceAll('Design preview', 'Documentation preview');
const taskHTML = task => `<strong>${task.title}</strong>${task.files.map(f => `<code>${f}</code>`).join('')}<p>${task.detail}</p><small>${task.proof}</small>`;
const recipeHTML = recipes.map(r => `<a class="c-recipe" data-page="${r.page}" href="${routes[r.page]}"><span class="c-tag ${r.status === 'gap' ? 'c-draft' : ''}">${r.status === 'gap' ? 'Framework gap' : 'Draft recipe'}</span><h2>${r.title}</h2><p>${r.text}</p><footer><span>${r.category} · 0.4.0</span></footer></a>`).join('');
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
#caramel-site.c-scroll .l-sticky{height:clamp(540px,calc(100svh - 85px),780px)}
#caramel-site.c-scroll #l-story{height:calc(clamp(540px,100svh - 85px,780px) + 1200px)}
#caramel-site.c-scroll .l-chapter[data-chapter="0"] p{font-size:16px}
#caramel-site .c-recipe{display:flex;text-align:left}
#caramel-site .c-results a{display:block}
@container(max-width:700px){#caramel-site.c-scroll .l-sticky{height:clamp(590px,calc(100svh - 120px),700px)}#caramel-site.c-scroll .l-chapter[data-chapter="0"] p{font-size:14px}}
@media(prefers-reduced-motion:reduce){html{scroll-behavior:auto}}
`;
fs.writeFileSync(new URL('assets/site.css', out), css);

let client = script
  .replace("let currentPage = 'home';", 'let currentPage = document.body.dataset.page;')
  .replace('root.scrollTop/', 'window.scrollY/')
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
// Static HTML already contains documentation; omit its duplicate copy from JS.
client = client.replace(dataSource, dataSource.slice(dataSource.indexOf('  const tasks')));
fs.writeFileSync(new URL('assets/site.js', out), client);

const escapeAttr = str => str.replaceAll('&', '&amp;').replaceAll('"', '&quot;');
for (const [key, route] of Object.entries(routes)) {
  let body = template;
  let title = 'Caramel — A little structure. A lot of possibility.';
  let description = 'A Crystal web framework with PostgreSQL, typed HTML, and a clear place for every change.';
  if (pages[key]) {
    const content = pages[key]().replace('The prototype does not run these commands.', 'Run these checks in your application; the examples are not yet recipe-tested.')
      .replace('Draft guide. Versioned site links will be added\nwhen the documentation is published.', 'Documentation: https://caramelize.dev/docs/0.4.0/agents/\nCookbook: https://caramelize.dev/cookbook/0.4.0/');
    title = content.match(/<h1>(.*?)<\/h1>/)[1] + ' · Caramel 0.4.0';
    description = content.match(/<p class="c-lede">(.*?)<\/p>/)[1];
    body = body.replace('<article class="c-doccontent" id="c-article"></article>', `<article class="c-doccontent" id="c-article">${content}</article>`)
      .replace('<div id="c-map-result" class="c-route-map" aria-live="polite"></div>', `<div id="c-map-result" class="c-route-map" aria-live="polite">${taskHTML(tasks.endpoint)}</div>`)
      .replace('<aside class="c-toc" aria-label="On this page" id="c-toc"></aside>', `<aside class="c-toc" aria-label="On this page" id="c-toc"><p>ON THIS PAGE</p>${[...content.matchAll(/<h2 id="([^"]+)">(.*?)<\/h2>/g)].map(m => `<a href="#${m[1]}">${m[2]}</a>`).join('')}</aside>`);
  }
  if (key === 'cookbook') { title = 'Cookbook · Caramel 0.4.0'; description = 'Task-based recipes, intended extension points, and a way to prove the result. Explore the draft collection and current framework gaps.'; }
  if(key !== 'home') body = body.replace(/    <div id="c-home">[\s\S]*?(?=    <div id="c-book")/, '');
  if(key !== 'cookbook') body = body.replace(/    <div id="c-book" hidden>[\s\S]*?(?=    <div id="c-doc")/, '');
  else body = body.replace('<div id="c-book" hidden>', '<div id="c-book">').replace('<div class="c-recipe-grid" id="c-recipes"></div>', `<div class="c-recipe-grid" id="c-recipes">${recipeHTML}</div>`);
  if(!pages[key]) body = body.replace(/    <div id="c-doc" hidden>[\s\S]*?(?=  <\/main>)/, '');
  else body = body.replace('<div id="c-doc" hidden>', '<div id="c-doc">');
  body = links(body).replaceAll(`data-page="${key}"`, `data-page="${key}" aria-current="page"`);
  const canonical = `https://caramelize.dev${route}`;
  const html = `<!doctype html>\n<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title}</title><meta name="description" content="${escapeAttr(description)}"><link rel="canonical" href="${canonical}"><meta property="og:title" content="${escapeAttr(title)}"><meta property="og:description" content="${escapeAttr(description)}"><meta property="og:url" content="${canonical}"><meta property="og:type" content="website"><meta name="color-scheme" content="light dark"><link rel="icon" href="/favicon.svg" type="image/svg+xml"><link rel="stylesheet" href="/assets/site.css"><script src="/assets/site.js" defer></script></head><body data-page="${key}">${body}</body></html>\n`;
  const dest = new URL('.' + route + 'index.html', out);
  fs.mkdirSync(path.dirname(dest.pathname), {recursive:true});
  fs.writeFileSync(dest, html);
}
fs.writeFileSync(new URL('favicon.svg', out), '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#201d18"/><text x="16" y="47" font-family="Arial,sans-serif" font-size="52" font-weight="bold" fill="#e9a278">c</text></svg>');
fs.writeFileSync(new URL('robots.txt', out), 'User-agent: *\nAllow: /\nSitemap: https://caramelize.dev/sitemap.xml\n');
fs.writeFileSync(new URL('.nojekyll', out), '');
fs.writeFileSync(new URL('CNAME', out), 'caramelize.dev\n');
fs.writeFileSync(new URL('sitemap.xml', out), `<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">${Object.values(routes).map(r=>`<url><loc>https://caramelize.dev${r}</loc></url>`).join('')}</urlset>`);
fs.writeFileSync(new URL('404.html', out), '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Page not found · Caramel</title><body style="background:#201d18;color:#eee8dd;font:18px/1.6 system-ui;padding:10vw"><h1>This page has moved on.</h1><p><a style="color:#e9a278" href="/">Back to Caramel</a></p></body></html>');
console.log(`Built ${Object.keys(routes).length} pages in dist.`);
