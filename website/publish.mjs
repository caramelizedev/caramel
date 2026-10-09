import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const website = path.dirname(fileURLToPath(import.meta.url));
const repo = path.dirname(website);
const run = (command, args, options = {}) => execFileSync(command, args, {cwd:repo, encoding:'utf8', ...options})?.trim() ?? '';
const dryRun = process.argv.slice(2).includes('--dry-run');
if (process.argv.slice(2).some(arg => arg !== '--dry-run')) {
  console.error('usage: node website/publish.mjs [--dry-run]');
  process.exit(1);
}
// gh-pages names the main commit it was built from, so that commit must hold
// the website's whole source.
const pending = run('git', ['status', '--porcelain', '--', 'website']);
if (pending) {
  console.error(`website/ has uncommitted changes; commit them before publishing:\n${pending}`);
  process.exit(1);
}
run(process.execPath, [path.join(website, 'build.mjs')], {stdio:'inherit'});
run(process.execPath, ['--check', path.join(website, 'dist/assets/site.js')]);
run(process.execPath, [path.join(website, 'check.mjs')], {stdio:'inherit'});
const remoteHead = run('git', ['ls-remote','--heads','origin','gh-pages']).split(/\s/)[0];
if(remoteHead) run('git', ['fetch','origin','gh-pages']);
run('git', ['fetch','--tags','--quiet','origin']);
const semver = /^\d+\.\d+\.\d+$/;
const compare = (a, b) => {
  const [x, y] = [a, b].map(v => v.split('.').map(Number));
  return x[0] - y[0] || x[1] - y[1] || x[2] - y[2];
};
const current = fs.readFileSync(path.join(repo, 'shard.yml'), 'utf8').match(/^version:\s*(\S+)/m)[1];
// The dist tree holds only the current edition; every earlier edition stays as
// its newest gh-pages commit published it. Alias pages written by an earlier
// publish are not editions: they are recomputed from the tags below.
const redirectOnly = new Map();
const isRedirectOnly = (section, tree) => {
  if (!redirectOnly.has(tree)) {
    const files = run('git', ['ls-tree', '-r', '--name-only', tree]).split('\n').filter(Boolean).sort();
    const shape = section === 'docs' ? ['agents/index.html', 'index.html'] : ['index.html'];
    redirectOnly.set(tree, files.join() === shape.join() && files.every(file =>
      run('git', ['show', `${tree}:${file}`]).includes('<meta http-equiv="refresh"')));
  }
  return redirectOnly.get(tree);
};
const preserved = new Map();
if (remoteHead) {
  for (const commit of run('git', ['rev-list', remoteHead]).split('\n').filter(Boolean)) {
    const listed = run('git', ['ls-tree', commit, 'docs/', 'cookbook/']).split('\n');
    for (const line of listed.filter(Boolean)) {
      const [info, entry] = line.split('\t');
      const [section, version] = entry.split('/');
      if (!semver.test(version ?? '') || version === current || preserved.has(entry)) continue;
      if (!isRedirectOnly(section, info.split(' ')[2])) preserved.set(entry, {section, version, commit});
    }
  }
}
const editions = [...new Set([current, ...[...preserved.values()].filter(p => p.section === 'docs').map(p => p.version)])];
const aliases = [];
for (const tag of run('git', ['tag', '--list', 'v[0-9]*']).split('\n')) {
  const match = /^v(\d+\.\d+\.\d+)$/.exec(tag);
  if (!match || editions.includes(match[1])) continue;
  const minor = match[1].split('.').slice(0, 2).join('.');
  const sharing = editions.filter(v => v.split('.').slice(0, 2).join('.') === minor).sort(compare);
  if (sharing.length) aliases.push({version: match[1], target: sharing[sharing.length - 1]});
}
const redirect = target => `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Caramel documentation</title><link rel="canonical" href="https://caramelize.dev${target}"><meta http-equiv="refresh" content="0;url=${target}"></head><body><a href="${target}">Read Caramel ${target.split('/')[2]} documentation</a></body></html>`;
const dist = path.join(website, 'dist');
for (const {version, target} of aliases) {
  for (const [route, to] of [[`docs/${version}`, `/docs/${target}/getting-started/`], [`docs/${version}/agents`, `/docs/${target}/agents/`], [`cookbook/${version}`, `/cookbook/${target}/`]]) {
    fs.mkdirSync(path.join(dist, route), {recursive:true});
    fs.writeFileSync(path.join(dist, route, 'index.html'), redirect(to));
  }
}
for (const {section, version, commit} of preserved.values()) console.log(`Keeping ${section}/${version} from ${commit.slice(0, 7)}`);
for (const {version, target} of aliases) console.log(`Redirecting ${version} to ${target}`);
const waitFor = [`/docs/${current}/agents/`, `/cookbook/${current}/`];
for (const {section, version, commit} of preserved.values()) {
  const first = run('git', ['ls-tree', '-r', '--name-only', commit, `${section}/${version}/`]).split('\n').filter(f => f.endsWith('/index.html')).sort()[0];
  waitFor.push(`/${first.slice(0, -'index.html'.length)}`);
}
for (const {version} of aliases) waitFor.push(`/docs/${version}/`, `/docs/${version}/agents/`, `/cookbook/${version}/`);
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'caramel-pages-'));
try {
  const env = {...process.env, GIT_INDEX_FILE:path.join(dir,'index')};
  const gitDir = run('git', ['rev-parse','--absolute-git-dir']);
  const git = args => run('git', [`--git-dir=${gitDir}`, `--work-tree=${dist}`, ...args], {env});
  git(['read-tree','--empty']);
  git(['add','--all']);
  for (const {section, version, commit} of preserved.values()) {
    git(['read-tree', `--prefix=${section}/${version}/`, `${commit}:${section}/${version}`]);
  }
  const tree = git(['write-tree']);
  if (dryRun) {
    console.log(`Tree ${tree}`);
  } else {
    const source = run('git', ['rev-parse','HEAD']);
    const parent = remoteHead ? ['-p', remoteHead] : [];
    const commit = git(['commit-tree',tree,...parent,'-m',`Publish caramelize.dev from ${source}`]);
    run('git',['push','origin',`${commit}:refs/heads/gh-pages`],{stdio:'inherit'});
    console.log(`Published ${commit} to gh-pages.`);
  }
} finally {
  fs.rmSync(dir,{recursive:true,force:true});
}
if (!dryRun) {
  const last = new Map(waitFor.map(url => [url, 0]));
  const deadline = Date.now() + 15 * 60_000;
  for (;;) {
    for (const url of waitFor) {
      if (last.get(url) === 200) continue;
      try {
        last.set(url, (await fetch(`https://caramelize.dev${url}`, {redirect:'manual'})).status);
      } catch (error) {
        last.set(url, String(error.cause?.code ?? error.message));
      }
    }
    if ([...last.values()].every(status => status === 200)) break;
    if (Date.now() > deadline) {
      console.error('Not available after 15 minutes:');
      for (const [url, status] of last) if (status !== 200) console.error(`  ${url} ${status}`);
      process.exit(1);
    }
    await new Promise(resolve => setTimeout(resolve, 15_000));
  }
  console.log(`Available: ${waitFor.length} URLs`);
}
