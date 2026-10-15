import fs from 'node:fs';
import path from 'node:path';
import { highlightCode } from './highlight.mjs';
import { commandRows } from './commands.mjs';
import { markdown, llmsEntry } from './markdown.mjs';
import { header, layout, document } from './shell.mjs';
import { sections } from './sections.mjs';

// site.html holds the pages; shell.mjs, site.css and site.js hold the shell, look and behaviour.
// Export real documents with native links and ordinary window scrolling.
const source = fs.readFileSync(new URL('./source/site.html', import.meta.url), 'utf8');
const version = fs.readFileSync(new URL('../shard.yml', import.meta.url), 'utf8')
  .match(/^version: (\S+)$/m)[1];
if (!source.includes(`Caramel ${version}`)) throw new Error('Update the site for the current release.');
const out = new URL('./dist/', import.meta.url);
fs.rmSync(out, {recursive: true, force: true});
fs.mkdirSync(new URL('assets/', out), { recursive: true });
const routesFor = edition => ({home: '/', cookbook: `/cookbook/${edition.version}/`,
  ...Object.fromEntries(Object.keys(edition.pages).map(key => {
    const [section, slug] = sections[key].split('/');
    return [key, `/${section}/${edition.version}/${slug}/`];
  }))});
const fail = message => { throw new Error(message); };
const part = id => source.match(new RegExp(`<template id="${id}">([\\s\\S]*?)</template>`))?.[1] ?? fail(`site.html has no <template id="${id}">`);
const script = source.match(/<script>([\s\S]*?)<\/script>/)[1];
const { pages, rail, recipes, searchIndex } = Function(`${script}\nreturn {pages, rail, recipes, searchIndex};`)();
const current = {version, pages: Object.fromEntries(Object.entries(pages).map(([key, render]) => [key, render()])), recipes, searchIndex};
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

// The rail lists every page once.
const railKeys = rail.flatMap(([, items]) => items.map(([key]) => key));
for (const key of [...Object.keys(current.pages), ...railKeys.filter(key => key !== 'cookbook')]) {
  if (railKeys.filter(k => k === key).length !== 1 || (key !== 'cookbook' && !current.pages[key])) fail(`Rail: ${key} is missing or listed twice`);
}
// Each page ends in a link forward; the build adds the link back, to the page before it in the rail
// or, for a recipe, to the catalog.
const docOrder = rail.flatMap(([, items]) => items).filter(([key]) => current.pages[key]);
for (const [key, html] of Object.entries(current.pages)) {
  if (!html.includes('<div class="c-next">')) fail(`${key} has no next()`);
  const index = docOrder.findIndex(([page]) => page === key);
  const back = routes[key].startsWith('/cookbook/') ? ['cookbook', 'All recipes']
    : index > 0 ? [docOrder[index - 1][0], docOrder[index - 1][1]] : null;
  current.pages[key] = back ? html.replace('<div class="c-next">', `<div class="c-next"><button class="cursor-interaction c-back" data-page="${back[0]}">← ${back[1]}</button>`) : html;
}
// A recipe page lists the recipes by category; every other page lists the rail.
const cookbookRail = [['Cookbook', [['cookbook', 'All recipes']]], ...[...new Set(current.recipes.map(r => r.category))]
  .map(category => [category, current.recipes.filter(r => r.category === category && routes[r.page].startsWith('/cookbook/')).map(r => [r.page, r.title])])
  .filter(([, items]) => items.length)];

const escapeAttr = str => str.replaceAll('&', '&amp;').replaceAll('"', '&quot;');
// The text of a heading or lede, without tags or entities, for llms.txt.
const content = html => html.replace(/<[^>]*>/g, '').replace(/&(lt|gt|quot|#39|amp);/g, (_, e) => ({lt: '<', gt: '>', quot: '"', '#39': "'", amp: '&'}[e]));
const recipeCards = current.recipes.map(r => {
  const gap = r.status === 'gap';
  const search = `${r.title} ${r.text} ${r.keywords} ${r.category}`.toLowerCase();
  return `<a class="c-recipe" href="${routes[r.page]}" data-search="${escapeAttr(search)}"><span class="c-recipe-meta"><span>${r.category}</span><span class="c-tag ${gap ? 'c-gap' : 'c-draft'}">${gap ? 'Needs validation' : 'Draft recipe'}</span></span><h2>${r.title}</h2><p>${r.text}</p></a>`;
}).join('');
const generatedRoutes = [];
const llms = {};
for (const [key, route] of Object.entries(routes)) {
  generatedRoutes.push(route);
  const context = {routes, version};
  let title = 'Caramel — A little structure. A lot of possibility.';
  let description = 'A Crystal web framework with PostgreSQL, typed HTML, and a clear place for every change.';
  let body;
  if (current.pages[key]) {
    const page = current.pages[key];
    title = page.match(/<h1>(.*?)<\/h1>/)[1] + ` · Caramel ${current.version}`;
    description = page.match(/<p class="c-lede">(.*?)<\/p>/)[1];
    body = header(key, context) + layout({key, content: page, routes, route, groups: route.startsWith('/cookbook/') ? cookbookRail : rail});
  } else if (key === 'cookbook') {
    title = `Cookbook · Caramel ${current.version}`;
    description = 'Each recipe takes one change from the files it touches to a passing spec. Every recipe says how far it has been tested.';
    body = header(key, context) + `<main id="c-main" tabindex="-1">${part('c-cookbook').replace('<!-- recipes -->', recipeCards).replace('<!-- recipe-count -->', `${current.recipes.length} recipes`)}</main>`;
  } else {
    body = header(key, context) + `<main id="c-main" tabindex="-1">${part('c-home')}</main>`;
  }
  const canonical = `https://caramelize.dev${route}`;
  const html = document({title, description, canonical, key, body: highlightCode(links(body, routes)), markdown: current.pages[key] ? `${route}index.md` : ''});
  const dest = new URL('.' + route + 'index.html', out);
  fs.mkdirSync(path.dirname(dest.pathname), {recursive:true});
  fs.writeFileSync(dest, html);
  // The Markdown edition: the same page for agents, beside its index.html.
  if (current.pages[key]) {
    const pageFor = Object.fromEntries(Object.entries(routes).map(([page, at]) => [at, page]));
    const link = href => {
      if (!href.startsWith('/')) return href;
      const [at, anchor] = href.split('#');
      const target = current.pages[pageFor[at]] ? `${at}index.md` : at;
      return `https://caramelize.dev${target}${anchor ? `#${anchor}` : ''}`;
    };
    const page = markdown(links(current.pages[key], routes), link) + `\nCaramel ${version} · https://caramelize.dev${route}\n`;
    fs.writeFileSync(new URL('.' + route + 'index.md', out), page);
    const eyebrow = current.pages[key].match(/<div class="c-eyebrow">(.*?)<\/div>/)[1].split(' / ');
    const heading = route.startsWith('/cookbook/') ? 'Cookbook' : content(eyebrow[0]);
    const name = route.startsWith('/cookbook/') ? content(current.pages[key].match(/<h1>(.*?)<\/h1>/)[1]).replace(/\.$/, '') : content(eyebrow[1]);
    (llms[heading] ??= []).push(llmsEntry(name, `https://caramelize.dev${route}index.md`, content(description)));
  }
}
fs.copyFileSync(new URL('./source/site.css', import.meta.url), new URL('assets/site.css', out));
fs.writeFileSync(new URL('assets/site.js', out), `const CARAMEL = ${JSON.stringify({routes, searchIndex: current.searchIndex, version})};\n` + fs.readFileSync(new URL('./source/site.js', import.meta.url), 'utf8'));
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
fs.writeFileSync(new URL('404.html', out), '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Page not found · Caramel</title><link rel="icon" href="/favicon.svg" type="image/svg+xml"><body style="background:#17110D;color:#F2E9DC;font:18px/1.6 system-ui;padding:10vw"><h1>This page has moved on.</h1><p><a style="color:#E3A857" href="/">Back to Caramel</a></p></body></html>');
// llms.txt (https://llmstxt.org) indexes this edition's Markdown pages for agents.
fs.writeFileSync(new URL(`docs/${version}/llms.txt`, out), `# Caramel ${version}\n\n` +
  `> Caramel is a Crystal web framework with PostgreSQL, typed HTML, and a clear place for every change. ` +
  `These are the Markdown editions of the ${version} guides, references and recipes; each page's HTML is the same URL without index.md.\n\n` +
  Object.entries(llms).map(([heading, pages]) => `## ${heading}\n\n${pages.join('\n')}\n`).join('\n'));
console.log(`Built ${generatedRoutes.length} pages for ${version} in dist.`);
