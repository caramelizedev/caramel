import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const website = path.dirname(fileURLToPath(import.meta.url));
const repo = path.dirname(website);
const run = (command, args, options = {}) => execFileSync(command, args, {cwd:repo, encoding:'utf8', ...options})?.trim() ?? '';
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
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'caramel-pages-'));
try {
  const env = {...process.env, GIT_INDEX_FILE:path.join(dir,'index')};
  const gitDir = run('git', ['rev-parse','--absolute-git-dir']);
  const git = args => run('git', [`--git-dir=${gitDir}`, `--work-tree=${path.join(website,'dist')}`, ...args], {env});
  git(['read-tree','--empty']);
  git(['add','--all']);
  const tree = git(['write-tree']);
  const source = run('git', ['rev-parse','HEAD']);
  const parent = remoteHead ? ['-p', remoteHead] : [];
  const commit = git(['commit-tree',tree,...parent,'-m',`Publish caramelize.dev from ${source}`]);
  run('git',['push','origin',`${commit}:refs/heads/gh-pages`],{stdio:'inherit'});
  console.log(`Published ${commit} to gh-pages.`);
} finally {
  fs.rmSync(dir,{recursive:true,force:true});
}
