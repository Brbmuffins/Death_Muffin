// node --test tools/git/merge-patch-notes.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { mergeNotes } from './merge-patch-notes.mjs';

const e = (date, title, items) => ({ date, title, items });
const base = [e('2026-10-10', 'Smoother', ['a']), e('2026-10-09', 'Older', ['x'])];

test('two branches append to the same entry: both lines kept, ours first', () => {
  const ours = [e('2026-10-10', 'Smoother', ['a', 'b']), base[1]];
  const theirs = [e('2026-10-10', 'Smoother', ['a', 'c']), base[1]];
  assert.deepEqual(mergeNotes(base, ours, theirs)[0].items, ['a', 'b', 'c']);
});

test('the same line added on both sides appears once', () => {
  const ours = [e('2026-10-10', 'Smoother', ['a', 'b']), base[1]];
  assert.deepEqual(mergeNotes(base, ours, ours)[0].items, ['a', 'b']);
});

test('a line the other side removed or reworded is not resurrected', () => {
  const ours = [e('2026-10-10', 'Smoother', ['a', 'b']), base[1]];
  const theirs = [e('2026-10-10', 'Smoother', ['a2']), base[1]];
  assert.deepEqual(mergeNotes(base, ours, theirs)[0].items, ['b', 'a2']);
});

test('new entries from either side are kept, newest date first', () => {
  const ours = [e('2026-10-11', 'Ours new', ['o']), ...base];
  const theirs = [e('2026-10-12', 'Theirs new', ['t']), ...base];
  assert.deepEqual(mergeNotes(base, ours, theirs).map((x) => x.title), ['Theirs new', 'Ours new', 'Smoother', 'Older']);
});

test('the other side renaming an entry wins when ours left it alone', () => {
  const ours = [e('2026-10-10', 'Smoother', ['a', 'b']), base[1]];
  const theirs = [{ ...e('2026-10-10', 'Smoother', ['a']), note: 'x' }, base[1]];
  assert.equal(mergeNotes(base, ours, theirs)[0].note, 'x');
});

test('as a git merge driver: a real same-entry collision merges cleanly', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pn-merge-'));
  const git = (...a) => execFileSync('git', ['-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@t', ...a], { encoding: 'utf8' });
  const driver = path.resolve('tools/git/merge-patch-notes.mjs');
  const write = (v) => fs.writeFileSync(path.join(dir, 'PATCH_NOTES.json'), JSON.stringify(v, null, 2) + '\n');
  git('init', '-q', '-b', 'main');
  fs.writeFileSync(path.join(dir, '.gitattributes'), 'PATCH_NOTES.json merge=patchnotes\n');
  git('config', 'merge.patchnotes.driver', `node ${driver} %O %A %B`);
  write(base); git('add', '.'); git('commit', '-qm', 'base');
  git('checkout', '-qb', 'job');
  write([e('2026-10-10', 'Smoother', ['a', 'job line']), base[1]]); git('commit', '-qam', 'job');
  git('checkout', '-q', 'main');
  write([e('2026-10-10', 'Smoother', ['a', 'shipped line']), base[1]]); git('commit', '-qam', 'shipped');
  git('merge', '-q', '--no-ff', '-m', 'merge job', 'job');
  const got = JSON.parse(fs.readFileSync(path.join(dir, 'PATCH_NOTES.json'), 'utf8'));
  assert.deepEqual(got[0].items, ['a', 'shipped line', 'job line']);
  fs.rmSync(dir, { recursive: true, force: true });
});
