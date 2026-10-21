// Tests for tools/context/navigation.mjs: the documentation map, the client index's old-section anchors and the guides they moved to,
// links with fragments and quoted section references into them (node --test tools/context/test/*.test.mjs).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { REPO, checkNavigation, anchorsOf, labelsOf, slug } from '../navigation.mjs';

test('the repo\'s map, client index, moved guides and every reference into them resolve', () => {
  assert.deepEqual(checkNavigation(REPO), []);
});

// A small repo shaped like the real one: a map, an index with one old section's anchor, two homes, a doc and a script that point in.
function fixture() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-nav-'));
  const w = (f, t) => { fs.mkdirSync(path.join(dir, path.dirname(f)), { recursive: true }); fs.writeFileSync(path.join(dir, f), t); };
  w('README.md', '# Game\n\n## Documentation map\n\n| Task | Start |\n|---|---|\n| Client | [client/README.md](client/README.md) |\n\n## Layout\n');
  w('CLAUDE.md', 'Start from [README.md](README.md) "Documentation map".\n');
  w('AGENTS.md', 'Start from [README.md](README.md) "Documentation map".\n');
  w('client/README.md', '# Client\n\n## Guides by task\n\n| Task | Read |\n|---|---|\n| <a id="threads"></a>Threads | [THREADING.md](core/THREADING.md) |\n| <a id="sound"></a>Sound | [audio/](audio/README.md#sound) |\n');
  w('client/core/THREADING.md', '# Threads\n\n**The rule.** Workers compute data.\n\n```\n## not a heading\n```\n');
  w('client/audio/README.md', '# Audio\n\n## Sound\n\nCues.\n\n## Sound\n\nA second one.\n');
  w('tools/context/doc-moves.json', JSON.stringify({ from: 'client/README.md', rev: 'x', moves: [{ fragment: 'threads', title: 'Threads', to: ['client/core/THREADING.md'] }, { fragment: 'sound', title: 'Sound', to: ['client/audio/README.md#sound'] }], kept: [{ file: 'OLD.md', why: 'history' }], labels: { 'The rule': 'client/core/THREADING.md' } }));
  w('client/next/x/README.md', 'See [the rule](../../core/THREADING.md), [sound](../../audio/README.md#sound-1) and client/core/THREADING.md "The rule".\n');
  w('client/next/x/x.gd', '## Threads: client/core/THREADING.md, sounds: client/audio/README.md "Sound".\n');
  w('OLD.md', 'Then it was client/README.md "Threads".\n');
  return dir;
}
const edit = (dir, f, fn) => { const p = path.join(dir, f); fs.writeFileSync(p, fn(fs.readFileSync(p, 'utf8'))); };
const msgs = (dir) => checkNavigation(dir).map((p) => `${p.file}: ${p.msg}`);
const has = (dir, part) => { const m = msgs(dir); assert.ok(m.some((x) => x.includes(part)), `expected "${part}" in:\n${m.join('\n')}`); };

test('a fixture that is right passes', () => { assert.deepEqual(msgs(fixture()), []); });

test('deleting or renaming a moved guide, or dropping an old anchor, is caught', () => {
  let d = fixture(); fs.rmSync(path.join(d, 'client/core/THREADING.md'));
  has(d, 'moved to client/core/THREADING.md, which is missing or empty');
  has(d, 'link to ../../core/THREADING.md: client/core/THREADING.md does not exist');
  d = fixture(); edit(d, 'client/audio/README.md', (t) => t.replace(/## Sound/g, '## Cues'));
  has(d, 'has no heading for #sound');
  has(d, 'has no heading or anchor #sound-1');
  has(d, 'client/audio/README.md has no heading or bold label "Sound"');
  d = fixture(); edit(d, 'client/README.md', (t) => t.replace('<a id="threads"></a>', ''));
  has(d, 'the old link client/README.md#threads ("Threads") has no <a id="threads"> anchor');
  d = fixture(); edit(d, 'client/README.md', (t) => t.replace('[THREADING.md](core/THREADING.md)', 'core'));
  has(d, 'the row of the old link #threads does not link core/THREADING.md');
  d = fixture(); edit(d, 'client/core/THREADING.md', (t) => t.replace('**The rule.**', 'The rule:'));
  has(d, 'the label "The rule" (tools/context/doc-moves.json) is not in client/core/THREADING.md');
});

test('the old section form is refused except in a kept file, and the map must exist and resolve', () => {
  let d = fixture(); edit(d, 'client/next/x/x.gd', (t) => t + '## more: client/README.md "Sound".\n');
  has(d, 'client/next/x/x.gd: client/README.md "Sound" is an old section: point at client/audio/README.md#sound');
  assert.ok(!msgs(d).some((x) => x.startsWith('OLD.md')), 'a kept file may keep its old reference');
  d = fixture(); edit(d, 'README.md', (t) => t.replace('## Documentation map', '## Docs'));
  has(d, 'README.md has no "## Documentation map" section');
  has(d, 'CLAUDE.md: README.md has no heading or bold label "Documentation map"');
  d = fixture(); edit(d, 'README.md', (t) => t.replace('(client/README.md)', '(client/GONE.md)'));
  has(d, 'the documentation map links client/GONE.md, which does not exist');
});

test('slugs follow GitHub: punctuation dropped, repeats numbered, explicit anchors count, fenced headings do not', () => {
  assert.equal(slug("The HUD's budget"), 'the-huds-budget');
  assert.equal(slug('The look on Forward+'), 'the-look-on-forward');
  assert.equal(slug('The API rule (DECISIONS B38, B49)'), 'the-api-rule-decisions-b38-b49');
  const a = anchorsOf('# A\n## Sound\n## Sound\n```\n## Fenced\n```\n<a id="old-name"></a>\n');
  assert.deepEqual([...a].sort(), ['a', 'old-name', 'sound', 'sound-1']);
  const l = labelsOf('## Play reports (how a real session ran)\n- **Dropped players (DECISIONS D13).** x\n**Not yet.** y\n');
  for (const x of ['Play reports', 'Play reports (how a real session ran)', 'Dropped players', 'Not yet']) assert.ok(l.has(x), x);
});
