#!/usr/bin/env node
// Git merge driver for PATCH_NOTES.json (set up by tools/git/install-merge-drivers.sh; .gitattributes names it).
// Every change appends its line to the same top entry, so two branches always collided there as text. This merges the
// entries three-way instead: entries match by (date, title); an entry's items = ours, minus the ones the other side removed,
// plus the ones only the other side added. Entries only one side added are kept, newest date first.
// Usage (git): merge-patch-notes.mjs %O %A %B   -> writes the result to %A, exit 0. Anything it cannot read: exit 1 (git keeps the conflict).
import fs from 'node:fs';

const key = (e) => `${e.date}\u0000${e.title}`;
const has = (list, x) => list.some((y) => JSON.stringify(y) === JSON.stringify(x));

function read(path, allowEmpty) {
  const s = fs.existsSync(path) ? fs.readFileSync(path, 'utf8') : '';
  if (allowEmpty && s.trim() === '') return [];
  const v = JSON.parse(s);
  if (!Array.isArray(v) || !v.every((e) => e && typeof e === 'object' && typeof e.date === 'string' && typeof e.title === 'string' && Array.isArray(e.items)))
    throw new Error('not a patch notes list');
  return v;
}

export function mergeNotes(base, ours, theirs) {
  const byKey = (list) => new Map(list.map((e) => [key(e), e]));
  const B = byKey(base); const O = byKey(ours); const T = byKey(theirs);
  const out = [];
  for (const e of ours) {
    const k = key(e);
    const b = B.get(k); const t = T.get(k);
    if (b && !t) continue;                           // the other side deleted this entry
    if (!t) { out.push(e); continue; }
    const bi = b ? b.items : [];
    const items = e.items.filter((x) => !(has(bi, x) && !has(t.items, x)))
      .concat(t.items.filter((x) => !has(bi, x) && !has(e.items, x)));
    const merged = { ...t, ...e, items };              // other fields: ours wins, unless ours left them as they were
    for (const f of Object.keys(t)) if (f !== 'items' && b && JSON.stringify(e[f]) === JSON.stringify(b[f])) merged[f] = t[f];
    out.push(merged);
  }
  const added = theirs.filter((e) => !O.has(key(e)) && !B.has(key(e)));
  // newest first; a stable sort keeps each side's own order within one date, the other side's new entries first
  return added.concat(out).map((e, i) => [e, i]).sort((a, b) => (a[0].date < b[0].date ? 1 : a[0].date > b[0].date ? -1 : a[1] - b[1])).map(([e]) => e);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const [basePath, oursPath, theirsPath] = process.argv.slice(2);
  try {
    const result = mergeNotes(read(basePath, true), read(oursPath, false), read(theirsPath, false));
    fs.writeFileSync(oursPath, JSON.stringify(result, null, 2) + '\n');
    process.exit(0);
  } catch (err) {
    console.error(`merge-patch-notes: ${err.message}; leaving the conflict for a person`);
    process.exit(1);
  }
}
