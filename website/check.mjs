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
// Each page follows its type (.claude/skills/caramel-docs/SKILL.md, "Page types"). The
// guards below read the built article: its eyebrow names the type, its h2s its sections.
const textOf = html => decodeCode(html.replace(/<[^>]*>/g, '')).replace(/\s+/g, ' ').trim();
const articles = paged.map(file => {
  const html = fs.readFileSync(path.join(root, file), 'utf8');
  const article = html.slice(html.indexOf('<article class="c-article">'), html.indexOf('</article>'));
  const [type, topic] = textOf(article.match(/<div class="c-eyebrow">(.*?)<\/div>/)[1]).split(' / ');
  const h2s = [...article.matchAll(/<h2 id="([^"]+)">(.*?)<\/h2>/g)].map(([, id, text]) => ({id, text: textOf(text)}));
  // The prose: the article without its code blocks and its contract table.
  const prose = textOf(article.replace(/<pre[\s\S]*?<\/pre>/g, ' ').replace(/<table class="c-contract">[\s\S]*?<\/table>/, ' '));
  return {file, key: pageKey(file), article, type, topic, h2s, prose, prove: article.indexOf('<div class="c-prove">')};
});
const TYPES = {Learn: 'a learning path', Guides: 'a guide', Cookbook: 'a recipe', Reference: 'a reference'};
for (const {file, key, article, type, topic, h2s, prove} of articles) {
  assert(TYPES[type], `${file}: the eyebrow "${type} / ${topic}" names none of ${Object.keys(TYPES).join(', ')}`);
  for (const {id} of h2s) assert(id.startsWith(`c-${key}-`), `${file}: the section id ${id} does not start with c-${key}-`);
  const titles = h2s.map(h2 => h2.text);
  const before = article.slice(0, prove);
  if (type === 'Learn') {
    for (const [, title] of before.matchAll(/<h2 id="[^"]+">(.*?)<\/h2>/g)) assert(/^\d\d · /.test(textOf(title)), `${file}: a learning path numbers its steps "01 · Verb the thing", not "${textOf(title)}"`);
  } else if (type === 'Guides' && topic === 'Current release') {
    assert(titles.includes(`Upgrading to ${version}`), `${file}: the current release guide has a section "Upgrading to ${version}"`);
  } else if (type === 'Guides') {
    for (const required of ['What does not compile', 'Not covered yet']) assert(titles.includes(required), `${file}: a guide has a section "${required}"`);
  } else if (type === 'Cookbook') {
    assert(article.includes('<div class="c-tagrow">'), `${file}: a recipe opens with tags()`);
  } else if (type === 'Reference') {
    assert(article.includes(`<h2 id="c-${key}-limits">Limits at a glance</h2><table class="c-limits">`), `${file}: a reference opens with limits()`);
    for (const section of before.split(/(?=<h2 id=")/).slice(1)) {
      const id = section.match(/<h2 id="([^"]+)"/)[1];
      assert(/<table class="c-(rules|map|limits)">|<div class="c-files" data-commands="/.test(section), `${file}: the reference section ${id} has no rules() or lookup() table`);
    }
  }
}
// Every command says what to expect: a Terminal snippet is followed by an Expect line, or
// sits in the Prove it block, whose Passing line is checked above.
for (const {file, article, prove} of articles) {
  for (const match of article.matchAll(/<div class="c-snippet"><header>(Terminal[^<]*)<\/header><pre>[\s\S]*?<\/pre><\/div>/g)) {
    if (match.index > prove) continue;
    assert(article.startsWith('<p class="c-expect">', match.index + match[0].length), `${file}: the snippet "${textOf(match[1])}" is not followed by an Expect line`);
  }
}
// A guide map names each section as its heading does.
for (const {file, article, h2s} of articles) {
  for (const [, id, label] of (article.match(/<div class="c-guidemap">([\s\S]*?)<\/div>/)?.[1] ?? '').matchAll(/<a href="#([^"]+)">([^<]*)<\/a>/g)) {
    assert.equal(textOf(label), h2s.find(h2 => h2.id === id)?.text, `${file}: the guide map calls ${id} "${textOf(label)}", not what its heading says`);
  }
}
// Every fact has one page: a sentence of 90 characters or more appears on one page only.
const said = {};
for (const {file, prose} of articles) {
  for (const sentence of new Set(prose.split(/(?<=\.) /).filter(sentence => sentence.length >= 90))) {
    assert(!said[sentence], `${said[sentence]} and ${file} both say: ${sentence}`);
    said[sentence] = file;
  }
}
// The voice says what Caramel does, without softeners (SKILL.md, "Voice").
for (const {file, prose} of articles) {
  for (const softener of [' simply ', ' be careful', ' reasonably ', ' you may want', ' easily ']) {
    const at = prose.toLowerCase().indexOf(softener);
    assert(at === -1, `${file}: "${softener.trim()}" softens: …${prose.slice(Math.max(0, at - 40), at + 40)}…`);
  }
}
// A rules table states each outcome in the framework's verb; an 'ok' row describes the
// plain path and may start with its subject.
const OUTCOME_VERBS = new Set(('fails fail refuses refuse answers answer raises raise runs run is are keeps keep kept ' +
  'stays stay does do returns return rolls allowed has have defaults follows adds add leaves leave checks checked ' +
  'sends send warns holds hold prints exits replaced continues counts revokes takes take queries saves re-renders ' +
  'never fires calls unmounts sets set draws uses use must commits writes write starts stops stop delivers vacuums ' +
  'ticks logs log becomes makes includes derives halts selects skips skip wraps turns clones goes splits lints shows ' +
  'overrides override resets reset binds bound fills omits converts routes brings escapes comes come carries carry ' +
  'renders passes changes weighs gets get ends works stores says folds fold aggregates traces loses falls builds ' +
  'installs forwards registers unregisters marks resolves waits refreshes refresh outlives undoes undo opens costs ' +
  'grants grant blocked reads read clears written stored ignored offered needs need moves also still not nothing').split(' '));
const VAGUE = /^(is|are) (an error|invalid|not allowed|rejected|missing|checked)\b/;
for (const {file, article} of articles) {
  for (const [, table] of article.matchAll(/<table class="c-rules">([\s\S]*?)<\/table>/g)) {
    for (const [, tone, cell] of table.matchAll(/<\/td><td( class="c-ok")?>([\s\S]*?)<\/td><\/tr>/g)) {
      const outcome = textOf(cell);
      assert(!VAGUE.test(outcome), `${file}: the outcome "${outcome}" names no framework verb; say what fails, refuses, answers or raises`);
      const verb = outcome.split(/[\s,;:(]/)[0];
      assert(tone || OUTCOME_VERBS.has(verb), `${file}: the outcome "${outcome.slice(0, 70)}" starts with "${verb}", not a framework verb (fails, refuses, answers, raises, …)`);
    }
  }
}
// A recipe's status: the catalog card (its recipes row), its tags() and its fixture agree,
// and a proved recipe names the check that ran it, which exists under scripts/checks.
const cards = Object.fromEntries([...read(`cookbook/${version}`).matchAll(/<a class="c-recipe" href="\/cookbook\/[^/]+\/([^/]+)\/"[^>]*><span class="c-recipe-meta"><span>[^<]*<\/span><span class="c-tag c-(draft|gap|proved)">/g)]
  .map(([, slug, status]) => [slug, status]));
for (const {file, key, type, article} of articles) {
  if (type !== 'Cookbook') continue;
  const status = cards[file.split(path.sep)[2]];
  assert(status, `${file}: no recipes row puts it on the cookbook catalog`);
  const tag = textOf(article.match(/<div class="c-tagrow"><span class="c-tag[^"]*">([^<]*)<\/span>/)?.[1] ?? '');
  const prover = tag.match(/^Proved by scripts\/check ([a-z-]+)$/)?.[1];
  if (status === 'proved') {
    assert(prover, `${file}: its recipes row says proved, so its tags() must say "Proved by scripts/check NAME", not "${tag}"`);
    assert(fs.existsSync(new URL(`../scripts/checks/${prover.replaceAll('-', '_')}.cr`, import.meta.url)), `${file}: tagged "${tag}", but scripts/checks/${prover.replaceAll('-', '_')}.cr does not exist`);
  } else {
    assert.equal(tag, status === 'gap' ? 'Recipe needs validation' : 'Draft recipe', `${file}: its recipes row says ${status}; its tags() says "${tag}"`);
  }
  assert(!pageFixtures[key] || status === 'proved', `${file}: spec/fixtures/pages/${key} exists, so its recipes row says proved`);
}
// The release guide's upgrade notes name everything the CHANGELOG's upgrade notes do.
const changelog = fs.readFileSync(new URL('../CHANGELOG.md', import.meta.url), 'utf8');
const released = changelog.slice(changelog.indexOf(`\n## ${version} `)).split('\n## ')[1] ?? '';
assert(released.startsWith(version), `CHANGELOG.md has no ## ${version} section`);
const upgradeNotes = released.split('\n### ').find(part => part.startsWith('Upgrade notes')) ?? '';
const releasesPage = markdownPage(`docs/${version}/releases`);
for (const [, token] of upgradeNotes.matchAll(/`([^`]+)`/g)) {
  assert(releasesPage.includes(token), `docs/${version}/releases/index.md: the CHANGELOG's ${version} upgrade notes name ${token}; the release guide does not`);
}
assert(markdownPage(`docs/${version}/agents`).includes('# Working in this Caramel application'), 'The agents page\'s Markdown omits the agent guide');
// Cases the pages do not emit yet, so a page that starts to cannot break the Markdown.
const converted = html => markdown(html, href => href);
assert.equal(converted('<p><a href="/x/?a=1&amp;b=(2)">x</a></p>'), '[x](/x/?a=1&b=%282%29)\n', 'A Markdown link keeps an entity or a parenthesis from its href');
assert.equal(converted('<p>Never &lt;script&gt; here, but <code>&lt;b&gt;</code></p>'), 'Never \\<script\\> here, but `<b>`\n', 'Prose < and > become raw HTML in Markdown');
assert.equal(converted('<p><code>check :dates, "starts_at < ends_at"</code> when a < b</p>'), '`check :dates, "starts_at < ends_at"` when a \\< b\n', 'A bare < in a code span or prose is dropped from the Markdown');
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
// The SweetTalk guide's "What does not compile" table covers every fixture of
// scripts/checks/sweet_talk_compilation.cr: each fixture name belongs to one row, named by a
// phrase of the row's condition, and every phrase is in the table.
const compilation = fs.readFileSync(new URL('../scripts/checks/sweet_talk_compilation.cr', import.meta.url), 'utf8');
const problems = compilation.slice(compilation.indexOf('PROBLEMS = ['), compilation.indexOf('\n]\n'));
const fixtureNames = new Set([...problems.matchAll(/\{"([a-z_]+)",/g)].map(match => match[1]));
assert(fixtureNames.size > 100, 'sweet_talk_compilation.cr lists fewer fixtures than expected');
const compileRows = {
  'A noun without means:': ['missing_meaning', 'specification_without_meaning'],
  'A subdomain: other than :core, :supporting or :generic': ['subdomain_unknown'],
  'A foreign name or call outside a border, a border or follows: to an unknown context, or a cycle of dependency edges': ['foreign_name', 'context_cycle', 'cycle_without_boot', 'unknown_border', 'call_outside_border'],
  'A name or call another context does not publish, a publishes of a name the context does not declare, or of an expression': ['unpublished_name', 'unpublished_call', 'unpublished_in_border', 'published_after_use', 'publishes_unknown', 'publishes_expression'],
  'Caramel::Outbound or HTTP::Client outside a border with an outside system, or such a border named like a context, holding a whenever, or without its outside: text': ['outbound_outside_border', 'client_in_context_border', 'outside_is_a_context', 'whenever_outside', 'outside_not_text', 'outside_nil'],
  'emit of another aggregate’s event': ['foreign_event'],
  'A mover the lifecycle does not declare': ['unknown_state'],
  'A lifecycle whose check name would pass PostgreSQL’s 63 bytes': ['state_check_long'],
  'the without a type': ['the_without_type'],
  'A value that wraps anything but Int32, Int64 or String, or has no parts': ['value_type', 'composite_without_parts'],
  'A value that takes an option its raw type does not, such as matches: on an integer or at_least: on a string, database_check: true, or database_check: false on a value with parts': ['value_string_bounds', 'value_int_matches', 'database_check_true', 'composite_database_check'],
  'A bound that is not an integer literal, unless the value takes database_check: false': ['bound_not_literal', 'length_not_literal'],
  'Two different values mixed in arithmetic, or multiplied without times:': ['value_mix', 'undeclared_times'],
  'A word out of its place: whenever or service in an aggregate, key outside a projection or a process, deadline outside a process, specification inside an aggregate, or compensate in a projection': ['whenever_in_aggregate', 'service_in_aggregate', 'key_outside_projection', 'deadline_outside_process', 'specification_in_aggregate', 'compensate_in_projection'],
  'has or part with a type that cannot be stored, a has of a Hash, or an attribute or key whose constraint or index name would pass PostgreSQL’s 63 bytes': ['unsupported_type', 'hash_attribute', 'composite_part_type', 'check_name_long', 'reference_index_long', 'key_index_long'],
  'An event whose channel would pass PostgreSQL’s 63 characters': ['channel_long'],
  'Two declarations whose names give one table': ['table_taken'],
  'A context that names Rows, or code outside the domain that reads an aggregate’s rows': ['rows_named', 'finds_block_rows', 'loader_outside'],
  'A projection or a process without key, a process step without key:, or a process attribute without a literal default': ['projection_without_key', 'process_without_key', 'process_whenever_without_key', 'process_attribute_default'],
  'Two whenever blocks for one event in one place, or each: naming a field that is not a list': ['duplicate_handler', 'each_not_list'],
  'A handler that reads an aggregate from an event, as in placed.order': ['event_loads_nothing'],
  'A factory that leaves an attribute unset, or named like a repository method': ['factory_unset_attribute', 'factory_repository_name'],
  'create on an aggregate that has a factory': ['create_beside_factory'],
  'A query on an unknown attribute, state or order, on a list of entities, with a value of the wrong type, with an argument it does not take, with nothing, with where: or order: that is not a tuple, or with a direction other than :asc or :desc': ['finds_unknown_attribute', 'finds_unknown_state', 'finds_uncalled_unknown_key', 'finds_order_unknown', 'finds_order_entities', 'finds_entities', 'finds_value_type', 'finds_unknown_argument', 'finds_nothing', 'finds_where_not_tuple', 'counts_where_not_tuple', 'finds_order_not_tuple', 'finds_order_direction', 'projection_finds_order_unknown'],
  'A finds with a block and an option, a block of more than one expression, or a block that does more than narrow its rows': ['finds_block_and_where', 'finds_block_two', 'finds_block_count', 'finds_block_delete', 'finds_block_sql', 'projection_finds_block_count'],
  'A counts with order: or a block': ['counts_with_order', 'counts_with_block'],
  'A query named all or like another query': ['query_name_taken', 'finds_name_taken', 'finds_named_all', 'counts_named_all', 'projection_finds_named_all'],
  'A specification on an unknown attribute or state, on a list of entities or a derived value, with a block, without on:, outside a context, whose predicate the aggregate already has, or whose where: is neither a tuple nor specifications joined by &, | and !': ['specification_entities', 'specification_block', 'specification_derived', 'specification_unknown_state', 'specification_predicate_taken', 'specification_joins_unknown', 'specification_without_on', 'specification_state_without_moves', 'specification_not_a_where', 'specification_value_type'],
  'satisfying: with anything but a specification on that aggregate, or satisfying: and state: on a projection': ['all_satisfying_other', 'finds_satisfying_value', 'projection_finds_satisfying', 'projection_counts_satisfying', 'projection_finds_state'],
  'A compensate without its whenever': ['compensate_without_whenever'],
  'arm of a deadline the process lacks': ['arm_unknown_deadline'],
  'An event field named like its metadata, or typed as a union of other types': ['event_reserved_field', 'event_reserved_flow', 'event_union_field'],
  'renamed_from: naming its own name, or a rename whose old job name another job has': ['renamed_from_itself', 'job_alias_taken'],
  'A value with parts as a contract field': ['composite_field'],
  'With caramel/tenancy, the mistakes listed under Share a domain between tenants': ['central_not_true', 'central_without_tenancy', 'tenant_unnamed', 'tenant_after_context', 'tenant_without_tenancy', 'tenant_not_schema', 'tenant_twice', 'tenant_mismatch', 'central_has_tenanted', 'central_event_tenanted_handler', 'channel_tenant_budget', 'tenant_index_long', 'tenant_column_taken', 'tenant_parent_column'],
};
const sweetTalkPage = read(`docs/${version}/sweettalk`);
const compileTable = textOf(sweetTalkPage.slice(sweetTalkPage.indexOf('<h2 id="c-sweettalk-refusals">'), sweetTalkPage.indexOf('<h2 id="c-sweettalk-limits">')));
const covered = new Set();
for (const [phrase, names] of Object.entries(compileRows)) {
  assert(compileTable.includes(phrase), `The SweetTalk guide's "What does not compile" lacks the row "${phrase}", which covers ${names.join(', ')}`);
  for (const name of names) {
    assert(fixtureNames.has(name), `check.mjs maps compile_${name}, which sweet_talk_compilation.cr no longer lists`);
    assert(!covered.has(name), `check.mjs maps compile_${name} to two rows`);
    covered.add(name);
  }
}
for (const name of fixtureNames) assert(covered.has(name), `The SweetTalk guide's "What does not compile" covers no row for compile_${name}: add it to compileRows in check.mjs`);
console.log(`Checked ${files.length} HTML documents and all local navigation/asset targets.`);
