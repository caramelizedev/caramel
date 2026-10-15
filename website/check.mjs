import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { Script } from 'node:vm';
import { highlightCode, decodeCode } from './highlight.mjs';
import { frappeCommands, applicationCommands, latteCommands } from './commands.mjs';
import { markdown, llmsEntry } from './markdown.mjs';
import { sections, pageKey } from './sections.mjs';
const root = new URL('./dist/', import.meta.url).pathname;
const files = fs.readdirSync(root, { recursive: true }).filter(p => p.endsWith('.html'));
for (const file of files) {
  const html = fs.readFileSync(path.join(root, file), 'utf8');
  assert(html.includes('<title>'), `${file}: missing title`);
  for (const [, url] of html.matchAll(/(?:href|src)="(\/[^"#]*)"/g)) {
    const target = path.join(root, url.endsWith('/') ? url + 'index.html' : url);
    assert(fs.existsSync(target), `${file}: missing local target ${url}`);
  }
  assert(!html.includes('href="undefined"'), `${file}: unknown page`);
  for (const [, block] of html.matchAll(/<pre\b[^>]*>([\s\S]*?)<\/pre>/g)) {
    assert(/^<code class="hljs language-[a-z]+">/.test(block), `${file}: unhighlighted code example`);
  }
  for (const [, id] of html.matchAll(/href="#([^"]+)"/g)) {
    assert(html.includes(`id="${id}"`), `${file}: missing anchor ${id}`);
  }
}
const fixture = 'section(class: "form-page") { h1 { "<Dune> & \\"Book\\" & a guest\'s" } }';
const escaped = fixture.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
const highlighted = highlightCode(`<code class="language-crystal">${escaped}</code>`);
assert(highlighted.includes('class="hljs-attr">class:</span>'), 'Blueprint class: mistaken for a declaration');
assert(highlighted.includes('class="hljs-string"'), 'Crystal strings are not highlighted');
assert.equal(decodeCode(highlighted.replace(/<[^>]*>/g, '')), fixture, 'Highlighting changed copyable code');
for (const file of fs.readdirSync(path.join(root, 'assets'), {recursive: true}).filter(file => file.endsWith('.js'))) {
  new Script(fs.readFileSync(path.join(root, 'assets', file), 'utf8'), {filename:file});
}
const version = fs.readFileSync(new URL('../shard.yml', import.meta.url), 'utf8').match(/^version: (\S+)$/m)[1];
const read = route => fs.readFileSync(path.join(root, route, 'index.html'), 'utf8');
const guide = read(`docs/${version}/getting-started`);
assert(guide.includes(`Caramel ${version}</title>`), 'Incorrect release metadata');
assert(!read(`cookbook/${version}/return-json`).includes('JSON request bodies are not supported'), 'JSON guide is stale');
const currentJS = fs.readFileSync(path.join(root, 'assets/site.js'), 'utf8');
assert(currentJS.includes(`/docs/${version}/testing-html/`), 'Current search omits HTML testing');
assert(currentJS.includes(`/docs/${version}/releases/`), 'Current search omits the release guide');
assert(currentJS.includes(`/docs/${version}/internationalization/`), 'Current search omits internationalization');
assert(currentJS.includes(`/docs/${version}/best-practices/`), 'Current search omits best practices');
assert(currentJS.includes(`/docs/${version}/crema/`), 'Current search omits the Crema reference');
// The references must keep up with the sources they document.
const escapeHTML = text => text.replace(/[&<>"]/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'}[c]));
const commandsPage = read(`docs/${version}/commands`);
for (const {syntax} of [...frappeCommands(), ...applicationCommands(), ...latteCommands()]) {
  assert(commandsPage.includes(`<code>${escapeHTML(syntax)}</code>`), `Command reference omits ${syntax}`);
}
// The Crema reference names every metric, environment variable and editor preset in the source.
const cremaDirectory = new URL('../src/caramel/crema/', import.meta.url);
const cremaSource = fs.readdirSync(cremaDirectory, {recursive: true}).filter(file => file.endsWith('.cr'))
  .map(file => fs.readFileSync(new URL(file, cremaDirectory), 'utf8')).join('\n');
const cremaPage = read(`docs/${version}/crema`);
const named = (pattern, text = cremaSource) => new Set([...text.matchAll(pattern)].map(match => match[1] ?? match[2]));
for (const [what, names] of [
  ['metric', named(/"(caramel_[a-z_]+)"/g, fs.readFileSync(new URL('prometheus.cr', cremaDirectory), 'utf8'))],
  ['environment variable', named(/"((?:CARAMEL|OTEL)_[A-Z_]+|LOG_LEVEL)"|ENV\["(CARAMEL_[A-Z_]+)"\]/g)],
]) {
  assert(names.size > 0, `No Crema ${what}s found in the source`);
  for (const name of names) assert(cremaPage.includes(name), `Crema reference omits ${what} ${name}`);
}
const editors = fs.readFileSync(new URL('editor.cr', cremaDirectory), 'utf8');
for (const preset of named(/^\s+"([a-z]+)"\s+=>/gm, editors.slice(editors.indexOf('PRESETS'), editors.indexOf('DEFAULT')))) {
  assert(cremaPage.includes(`<code>${preset}</code>`), `Crema reference omits editor ${preset}`);
}
assert(read(`docs/${version}/agents`).includes('# Working in this Caramel application'), 'The agents page omits the agent guide');
assert(read(`docs/${version}/sweettalk`).includes('<h2 id="c-sweettalk-ddd">'), 'The SweetTalk page omits its Domain-Driven Design map');
// A pattern the guide or the skill calls planned must be planned for a later release:
// an edition never calls its own release, or an earlier one, the future.
const reached = planned => {
  const [a, b] = [planned, version].map(v => v.split('.').map(Number));
  return a[0] < b[0] || (a[0] === b[0] && (a[1] < b[1] || (a[1] === b[1] && a[2] <= b[2])));
};
for (const file of files) {
  for (const [, planned] of fs.readFileSync(path.join(root, file), 'utf8').matchAll(/data-planned="(\d+\.\d+\.\d+)"/g)) {
    assert(!reached(planned), `${file}: still planned for ${planned} in the ${version} edition; say what ships instead`);
  }
}
const catalog = fs.readFileSync(new URL('../src/caramel/i18n/catalog.cr', import.meta.url), 'utf8');
const i18nPage = read(`docs/${version}/internationalization`);
for (const [, key] of catalog.matchAll(/\{"((?:errors|pages)\.[a-z_]+)", "::/g)) {
  assert(i18nPage.includes(`<code>${key}</code>`), `Internationalization reference omits caramel.${key}`);
}
const sitemap = fs.readFileSync(path.join(root, 'sitemap.xml'), 'utf8');
for (const [, route] of sitemap.matchAll(/<loc>https:\/\/caramelize\.dev([^<]+)<\/loc>/g)) {
  assert(fs.existsSync(path.join(root, route, 'index.html')), `Sitemap: missing ${route}`);
}
assert(fs.readFileSync(path.join(root, 'assets/site.css'), 'utf8').startsWith("@import url('https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,400;12..96,500;12..96,700;12..96,800&family=JetBrains+Mono:ital,wght@0,400;0,600;1,400&display=swap');"), 'Font import was corrupted');
// The Markdown edition: an index.md beside each docs and cookbook page, each listed in llms.txt.
const llms = fs.readFileSync(path.join(root, 'docs', version, 'llms.txt'), 'utf8');
assert(llms.startsWith(`# Caramel ${version}\n\n> `), 'llms.txt lacks its title and summary');
const paged = files.filter(file => file.split(path.sep).length === 4 && /^(docs|cookbook)\//.test(file) && file.split(path.sep)[1] === version);
assert(paged.length > 0, 'No pages in the current edition');
for (const file of paged) {
  const edition = file.replace(/index\.html$/, 'index.md');
  assert(fs.existsSync(path.join(root, edition)), `${file}: no Markdown edition`);
  assert(llms.includes(`](https://caramelize.dev/${edition}): `), `llms.txt omits ${edition}`);
}
// Every page declares its contract and ends in proof (.claude/skills/caramel-docs).
for (const file of paged) {
  const html = fs.readFileSync(path.join(root, file), 'utf8');
  const article = html.slice(html.indexOf('<article class="c-article">'), html.indexOf('</article>'));
  assert.equal(article.split('class="c-contract"').length - 1, 1, `${file}: one contract table`);
  const proof = article.indexOf('<div class="c-prove">');
  assert(proof !== -1, `${file}: no Prove it block`);
  assert.equal(article.indexOf('<h2', proof), article.lastIndexOf('<h2'), `${file}: Prove it is not the last section`);
  assert(article.includes('<strong>Passing:</strong>'), `${file}: Prove it has no Passing line`);
}
// A page with a directory under spec/fixtures/pages/<key>/ shows an application that
// scripts/checks/page_<key>.cr builds step by step. Each of its file snippets is a block
// of the fixture file its caption names, the blocks of one file come in order, and
// every line of every fixture file is shown. `quotes` lists pages that show a file of
// another page's fixture: their snippets are held to it too.
const quotes = {sweettalk: 'boxoffice'};
const fixturesRoot = new URL('../spec/fixtures/pages/', import.meta.url);
const fixtureOf = key => {
  const dir = new URL(`${key}/`, fixturesRoot);
  if (!fs.existsSync(dir)) return null;
  return Object.fromEntries(fs.readdirSync(dir, {recursive: true})
    .filter(file => file.endsWith('.cr'))
    .map(file => [file, fs.readFileSync(new URL(file, dir), 'utf8').replace(/\n$/, '').split('\n')]));
};
const pageFixtures = Object.fromEntries(fs.readdirSync(fixturesRoot).map(key => [key, fixtureOf(key)]));
for (const key of Object.keys(pageFixtures)) {
  assert(sections[key], `spec/fixtures/pages/${key} names no page`);
  assert(fs.existsSync(new URL(`../scripts/checks/page_${key}.cr`, import.meta.url)), `spec/fixtures/pages/${key} has no scripts/checks/page_${key}.cr`);
}
// Where *code* is a block of *lines* with its common indentation removed, or -1.
const blockAt = (lines, code) => {
  const wanted = code.replace(/\n$/, '').split('\n');
  for (let start = 0; start + wanted.length <= lines.length; start++) {
    const block = lines.slice(start, start + wanted.length);
    const indent = Math.min(...block.filter(line => line.trim()).map(line => line.match(/^ */)[0].length));
    if (block.every((line, i) => line.slice(indent) === wanted[i])) return start;
  }
  return -1;
};
const snippetsOf = html => [...html.matchAll(/<div class="c-snippet"><header>([^<]*)<\/header><pre><code class="hljs language-[a-z]+">([\s\S]*?)<\/code><\/pre><\/div>/g)]
  .map(([, caption, code]) => ({caption: decodeCode(caption), code: decodeCode(code.replace(/<[^>]*>/g, ''))}));
for (const file of paged) {
  const key = pageKey(file);
  const own = pageFixtures[key];
  const fixture = own ?? pageFixtures[quotes[key]];
  if (!fixture) continue;
  const where = `spec/fixtures/pages/${own ? key : quotes[key]}`;
  const shown = Object.fromEntries(Object.keys(fixture).map(name => [name, new Set()]));
  const last = {};
  for (const {caption, code} of snippetsOf(fs.readFileSync(path.join(root, file), 'utf8'))) {
    const name = caption.split(' · ')[0];
    if (!fixture[name]) {
      assert(!own || name.startsWith('Terminal'), `${file}: "${caption}" names no file in ${where}`);
      continue;
    }
    const start = blockAt(fixture[name], code);
    assert(start !== -1, `${file}: "${caption}" is not a block of ${where}/${name}`);
    if (!own) continue;
    assert(!(name in last) || start > last[name], `${file}: "${caption}" shows ${name} out of order`);
    code.split('\n').forEach((_, i) => shown[name].add(start + i));
    last[name] = start;
  }
  if (own) for (const [name, lines] of Object.entries(fixture)) {
    lines.forEach((line, i) => assert(!line.trim() || shown[name].has(i), `${where}/${name}: line ${i + 1} is not shown on ${file}`));
  }
}
const markdownPage = route => fs.readFileSync(path.join(root, route, 'index.md'), 'utf8');
assert(markdownPage(`docs/${version}/agents`).includes('# Working in this Caramel application'), 'The agents page\'s Markdown omits the agent guide');
// Cases the pages do not emit yet, so a page that starts to cannot break the Markdown.
const converted = html => markdown(html, href => href);
assert.equal(converted('<p><a href="/x/?a=1&amp;b=(2)">x</a></p>'), '[x](/x/?a=1&b=%282%29)\n', 'A Markdown link keeps an entity or a parenthesis from its href');
assert.equal(converted('<p>Never &lt;script&gt; here, but <code>&lt;b&gt;</code></p>'), 'Never \\<script\\> here, but `<b>`\n', 'Prose < and > become raw HTML in Markdown');
assert.equal(converted('<ul><li><p>One.</p><p>Two.</p></li></ul>'), '- One.\n\n  Two.\n', 'An item\'s paragraphs run together in Markdown');
assert.equal(llmsEntry('Read [this]', 'https://caramelize.dev/a b/', 'Why.'), '- [Read \\[this\\]](https://caramelize.dev/a%20b/): Why.', 'An llms.txt name ends its link early');
assert(!/&(lt|gt|quot|#39|amp);/.test(llms), 'llms.txt holds an undecoded entity');
// The SweetTalk skill that frappe make domain writes ends each rule with a section of
// the Markdown edition, and every section it cites exists.
const skill = fs.readFileSync(new URL('../templates/skills/sweettalk/SKILL.md', import.meta.url), 'utf8');
assert(skill.startsWith('---\nname: sweettalk\ndescription: '), 'The SweetTalk skill lacks its name and description');
const cited = / https:\/\/caramelize\.dev\/docs\/VERSION\/([a-z-]+)\/index\.md#([a-z0-9-]+)$/;
for (const rule of skill.split('\n').filter(line => line.startsWith('- '))) {
  assert(cited.test(rule), `The SweetTalk skill's rule cites no section: ${rule}`);
}
for (const [, page, anchor] of skill.matchAll(new RegExp(cited.source.slice(1, -1), 'g'))) {
  const edition = path.join(root, 'docs', version, page, 'index.md');
  assert(fs.existsSync(edition) && fs.readFileSync(edition, 'utf8').includes(`{#${anchor}}`), `The SweetTalk skill cites a missing section: ${page}#${anchor}`);
}
for (const line of skill.split('\n')) {
  const planned = line.match(/planned for (\d+\.\d+\.\d+)/)?.[1];
  assert(!planned || !reached(planned), `The SweetTalk skill still plans for ${planned} in ${version}: ${line}`);
}
console.log(`Checked ${files.length} HTML documents and all local navigation/asset targets.`);
