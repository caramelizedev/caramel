import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { Script } from 'node:vm';
import { highlightCode, decodeCode } from './highlight.mjs';
import { frappeCommands, applicationCommands, latteCommands } from './commands.mjs';
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
const fixture = 'section(class: "form-page") { h1 { "<Dune> & \\"Book\\"" } }';
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
// The references must keep up with the sources they document.
const escapeHTML = text => text.replace(/[&<>"]/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'}[c]));
const commandsPage = read(`docs/${version}/commands`);
for (const {syntax} of [...frappeCommands(), ...applicationCommands(), ...latteCommands()]) {
  assert(commandsPage.includes(`<code>${escapeHTML(syntax)}</code>`), `Command reference omits ${syntax}`);
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
const js = fs.readFileSync(path.join(root, 'assets/site.js'), 'utf8');
assert(!/window\.openai|globalThis\.Tweak/.test(js), 'Standalone site still requires prototype host');
assert(fs.readFileSync(path.join(root, 'assets/site.css'), 'utf8').startsWith("@import url('https://fonts.googleapis.com/css2?family=DM+Sans:wght@400;500;600;700&display=swap');"), 'Font import was corrupted');
console.log(`Checked ${files.length} HTML documents and all local navigation/asset targets.`);
