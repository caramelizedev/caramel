import fs from 'node:fs';

// The header, the rail, the outline and the document around a page. build.mjs decides
// what a page says; this file decides what surrounds it.
const mark = fs.readFileSync(new URL('./source/mark.svg', import.meta.url), 'utf8').trim();
const icon = paths => `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths}</svg>`;
const SEARCH = icon('<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>');
const SUN = icon('<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>');
const escapeAttr = str => str.replaceAll('&', '&amp;').replaceAll('"', '&quot;');

export function header(key, {routes, version}) {
  const cookbook = key === 'cookbook' || routes[key]?.startsWith('/cookbook/');
  const pill = key === 'home' ? `release · ${version}` : cookbook ? `cookbook · ${version}` : `docs · ${version}`;
  const searchable = key !== 'home' && key !== 'cookbook';
  const search = searchable ? `<div class="c-search" role="search"><label class="c-field">${SEARCH}<input id="c-search" type="search" autocomplete="off" placeholder="Search the docs" aria-label="Search Caramel ${version} documentation" aria-controls="c-search-results" aria-expanded="false"><kbd>⌘K</kbd></label><div class="c-search-results" id="c-search-results" hidden></div></div>` : '';
  // The top-level section stays selected while one of its child pages is read.
  const section = key === 'home' ? null : key === 'agents' ? 'agents' : cookbook ? 'cookbook' : 'learn';
  const link = (page, label) => `<a href="${routes[page]}"${section === page ? ` aria-current="${key === page ? 'page' : 'true'}"` : ''}>${label}</a>`;
  return `<header class="c-header"><a class="c-brand" href="/" aria-label="Caramel home"><span class="c-mark" aria-hidden="true">${mark}</span>caramel</a><span class="c-edition">${pill}</span>${search}<nav class="c-nav" aria-label="Primary">${link('learn', 'Docs')}${link('cookbook', 'Cookbook')}${link('agents', 'For agents')}<a href="https://github.com/caramelizedev/caramel">GitHub</a></nav><button class="c-theme" type="button" aria-label="Switch theme">${SUN}</button></header>`;
}

export function layout({key, content, routes, groups, route}) {
  const rail = groups.map(([group, items]) => `<h3>${group}</h3>${items.map(([page, label, child]) => `<a href="${routes[page]}"${child ? ' class="c-child"' : ''}${page === key ? ' aria-current="page"' : ''}>${label}</a>`).join('')}`).join('');
  const outline = [...content.matchAll(/<h2 id="([^"]+)">(.*?)<\/h2>/g)].map(m => `<a href="#${m[1]}">${m[2]}</a>`).join('');
  const skill = key === 'sweettalk' ? '<a href="https://github.com/caramelizedev/caramel/blob/main/templates/skills/sweettalk/SKILL.md">The SweetTalk skill</a>' : '';
  return `<div class="c-layout"><details class="c-railnav" open><summary>Browse documentation</summary><nav class="c-rail" aria-label="Documentation">${rail}</nav></details><main id="c-main" class="c-doc" tabindex="-1"><article class="c-article">${content}</article></main><aside class="c-outline" aria-label="On this page"><p>On this page</p>${outline}<div class="c-outline-more"><a href="${route}index.md">This page as Markdown</a><a href="https://github.com/caramelizedev/caramel/blob/main/website/source/site.html">Edit the source</a>${skill}</div></aside></div>`;
}

export function document({title, description, canonical, key, body, markdown}) {
  const theme = `<script>try{const t=localStorage.getItem('caramel-theme');if(t==='light'||t==='dark')document.documentElement.dataset.theme=t}catch(e){}</script>`;
  return `<!doctype html>\n<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title}</title><meta name="description" content="${escapeAttr(description)}"><link rel="canonical" href="${canonical}"><meta property="og:title" content="${escapeAttr(title)}"><meta property="og:description" content="${escapeAttr(description)}"><meta property="og:url" content="${canonical}"><meta property="og:type" content="website"><meta name="color-scheme" content="light dark"><link rel="icon" href="/favicon.svg" type="image/svg+xml">${theme}<link rel="stylesheet" href="/assets/site.css"><script src="/assets/site.js" defer></script>${markdown ? `<link rel="alternate" type="text/markdown" href="${markdown}">` : ''}</head><body data-page="${key}"><a class="c-skip" href="#c-main">Skip to content</a>${body}</body></html>\n`;
}
