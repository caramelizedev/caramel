import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
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
}
const js = fs.readFileSync(path.join(root, 'assets/site.js'), 'utf8');
assert(!/window\.openai|globalThis\.Tweak/.test(js), 'Standalone site still requires prototype host');
assert(fs.readFileSync(path.join(root, 'assets/site.css'), 'utf8').startsWith("@import url('https://fonts.googleapis.com/css2?family=DM+Sans:wght@400;500;600;700&display=swap');"), 'Font import was corrupted');
console.log(`Checked ${files.length} HTML documents and all local navigation/asset targets.`);
