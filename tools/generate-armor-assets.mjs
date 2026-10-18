/**
 * Armor sets end to end, from the server rules (server/rules/content/armorSets.ts + legendarySets.ts) to every copy that must match them:
 *   - the game's hand-kept data copies (client/data/README.md "Merged and overlapping data"): content/{armorSets,legendarySets,items,
 *     setBonuses,computed,gameplay_atlas,gameplay_authorityRules}.json, combat/armor.json, gathering/gathering.json, panels_a/{codex_rows,atlas}.json
 *   - the inventory icons (client/assets/ui_art/art/items/<id>.svg, and the same file under public/art/items/, which the item catalogue test reads)
 *   - the server's `items` rows: pieces no migration inserts yet get a NEW additive migration (applied ones are never rewritten)
 *
 *   node tools/generate-armor-assets.mjs           write everything that is missing or stale, print what changed
 *   node tools/generate-armor-assets.mjs --check   exit 1 (and list the files) when anything is out of date
 *
 * A new set: add it to legendarySets.ts (or armorSets.ts), add its bonuses to client/data/content/setBonuses.json SET_BONUSES (an effect the game
 * folds, or `{"text": "..."}` for a bonus coded elsewhere, e.g. DmReaperSet), run this, then `npm run build:server-rules`. The new migration ships
 * with the change (the Discord agent's ship applies it). Gear Atlas rows of a new piece copy the drop sources of the same slot of an existing set in
 * its collection (the Atlas has no generator; its rates are those sources').
 */
import { readFileSync, writeFileSync, existsSync, readdirSync } from 'node:fs';
import { resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
const CHECK = process.argv.includes('--check');
const { build } = await import('esbuild');
const entry = "export * as A from './server/rules/content/armorSets.ts'; export * as L from './server/rules/content/legendarySets.ts'; export * as I from './server/rules/content/items.ts'; export * as R from './server/rules/gameplay/authorityRules.ts';";
const js = (await build({ stdin: { contents: entry, resolveDir: root, loader: 'ts' }, bundle: true, write: false, format: 'esm', platform: 'node', logLevel: 'error' })).outputFiles[0].text;
const { A, L, I, R } = await import(`data:text/javascript,${encodeURIComponent(js)}`);
const PIECES = A.ARMOR_PIECES;

const stale = [];
const p = (rel) => resolve(root, rel);
const readJson = (rel) => JSON.parse(readFileSync(p(rel), 'utf8'));
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
/** Write `text` to `rel` when it differs (or list it under --check). */
function put(rel, text) {
  if (existsSync(p(rel)) && readFileSync(p(rel), 'utf8') === text) return;
  stale.push(rel);
  if (!CHECK) writeFileSync(p(rel), text);
}
/** Load a JSON file, let `edit` change it in place, and write it back in its own style (indent, trailing newline, \u escapes). */
function editJson(rel, edit) {
  const raw = readFileSync(p(rel), 'utf8');
  const data = JSON.parse(raw);
  edit(data);
  const indent = /^\{\n( +)"/.exec(raw)?.[1].length ?? 0;
  let out = JSON.stringify(data, null, indent || undefined);
  if (/\\u[0-9a-f]{4}/.test(raw)) out = out.replace(/[\u007f-￿]/g, (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, '0')}`);
  put(rel, out + (raw.endsWith('\n') ? '\n' : ''));
}
/** Rebuild an object keyed by `ids`: existing rows keep their place and content, new ids get `make(id)`, ids no longer known are kept as they are. */
function withRows(obj, ids, make) {
  const out = { ...obj };
  for (const id of ids) if (!(id in out)) out[id] = make(id);
  return out;
}

// ---- first: every set needs its (hand-written) bonuses, or nothing is written ----------------------------------------------
const setIds = [...new Set(PIECES.map((x) => x.setId))];
const setName = Object.fromEntries(PIECES.map((x) => [x.setId, x.setName]));
const bonusSrc = readJson('client/data/content/setBonuses.json').SET_BONUSES;
const noBonus = setIds.filter((id) => !bonusSrc[id]);
if (noBonus.length) {
  console.error(`No bonuses for set(s) ${noBonus.join(', ')}: add them to client/data/content/setBonuses.json SET_BONUSES first, e.g.\n` +
    `  "${noBonus[0]}": [{"pieces": 2, "effect": {"text": "..."}}, {"pieces": 4, "name": "...", "effect": {"text": "..."}}, {"pieces": 5, "name": "...", "effect": {"text": "..."}}]`);
  process.exit(2);
}
// ---- content/* : straight copies of the TS exports ------------------------------------------------------------------------------------
editJson('client/data/content/armorSets.json', (d) => { for (const k of Object.keys(d)) if (k in A) d[k] = A[k]; });
editJson('client/data/content/legendarySets.json', (d) => { for (const k of Object.keys(d)) if (k in L) d[k] = L[k]; });
editJson('client/data/content/items.json', (d) => { for (const k of Object.keys(d)) if (k in I) d[k] = I[k]; });
editJson('client/data/content/computed.json', (d) => { d.itemIds = Object.keys(I.ITEMS); });
editJson('client/data/content/gameplay_authorityRules.json', (d) => { d.GROUND_RATES = R.GROUND_RATES; });
editJson('client/data/content/gameplay_atlas.json', (d) => { d.ARMOR_BY_ID = A.ARMOR_BY_ID; d.LEGENDARY_SETS = L.LEGENDARY_SETS; });

// ---- content/manifest.json: the export counts the rules-core suite checks (array length / key count, 1 for a scalar) -------------------
editJson('client/data/content/manifest.json', (m) => {
  for (const name of ['armorSets', 'legendarySets', 'items', 'setBonuses', 'computed', 'gameplay_authorityRules', 'gameplay_atlas']) {
    const file = name === 'setBonuses' ? { ...readJson(`client/data/content/${name}.json`), SET_NAMES: setName, SET_IDS: setIds } : readJson(`client/data/content/${name}.json`);
    for (const [k, v] of Object.entries(file)) m.files[name].counts[k] = v && typeof v === 'object' ? Object.keys(v).length : 1;
    m.files[name].keys = Object.keys(file).length;
  }
  m.summary.items = Object.keys(I.ITEMS).length;
});

// ---- set bonuses: names and ids follow the sets ------------------------------------------------------------------------------------
editJson('client/data/content/setBonuses.json', (d) => { d.SET_NAMES = setName; d.SET_IDS = setIds; });
const PIECE_KEYS = ['id', 'setId', 'disciplineId', 'collection', 'part', 'stats', 'area', 'name', 'setName'];
editJson('client/data/combat/armor.json', (d) => {
  d.pieces = PIECES.map((x) => Object.fromEntries(PIECE_KEYS.map((k) => [k, x[k]])));
  d.set_bonuses = bonusSrc;
  d.set_names = setName;
});

// ---- gathering items subset -------------------------------------------------------------------------------------------------------------
editJson('client/data/gathering/gathering.json', (d) => {
  d.items = withRows(d.items, PIECES.map((x) => x.id), (id) => {
    const m = I.ITEMS[id];
    return { name: m.name, type: m.type, rarity: m.rarity, sell: m.sell, offlineStats: m.offlineStats };
  });
});

// ---- Codex rows and the Gear Atlas (panels_a) -----------------------------------------------------------------------------------------
/** The plain lines of one bonus effect, the way DmSetText.describe_effect words the effects the codex already lists (text-only effects as written). */
function bonusText(b, sibling) {
  if (b.effect?.text) return b.effect.text;
  if (sibling) return sibling;
  throw new Error(`set bonus ${JSON.stringify(b)} has no text and no existing codex row to copy it from: give it an effect "text"`);
}
const wearerSuffix = { 1: 'Drops in its areas.', 2: 'Drops in its areas.', 3: 'Drops from area bosses.' };
editJson('client/data/panels_a/codex_rows.json', (d) => {
  const have = new Set(d.sets.map((s) => s.setId));
  for (const id of setIds) {
    if (have.has(id)) continue;
    const pcs = PIECES.filter((x) => x.setId === id);
    d.sets.push({
      setId: id, name: setName[id], wearer: pcs[0].wearer, collection: pcs[0].collection,
      drops: `${pcs.map((x) => x.name).join(', ')}. ${wearerSuffix[pcs[0].collection]}`,
      bonuses: bonusSrc[id].map((b) => ({ pieces: b.pieces, ...(b.name ? { name: b.name } : {}), text: bonusText(b) })),
    });
  }
});
editJson('client/data/panels_a/atlas.json', (d) => {
  const sibling = (x) => PIECES.find((o) => o.collection === x.collection && o.part === x.part && o.setId !== x.setId && d.items[o.id]);
  for (const x of PIECES) {
    if (d.items[x.id]) continue;
    const sib = sibling(x);
    if (!sib) throw new Error(`no Atlas row to model ${x.id} on`);
    const m = I.ITEMS[x.id];
    d.items[x.id] = { ...d.items[sib.id], id: x.id, name: x.name, stats: x.stats, lore: x.lore, icon: `art/items/${x.id}.svg`, set_id: x.setId, sell: m.sell };
    const at = d.item_order.indexOf(PIECES.filter((o) => o.setId === x.setId && d.item_order.includes(o.id)).at(-1)?.id ?? PIECES.filter((o) => o.collection === x.collection && d.item_order.includes(o.id)).at(-1)?.id);
    d.item_order.splice(at + 1, 0, x.id);
    if (d.sources[sib.id]) d.sources[x.id] = d.sources[sib.id];
    for (const v of Object.values(d.source_variants)) if (v[sib.id]) v[x.id] = v[sib.id];
    for (const disc of Object.values(d.by_disc)) if (disc.band && sib.id in disc.band) disc.band[x.id] = disc.band[sib.id];
  }
  const haveSets = new Set(d.sets.map((s) => s.id));
  for (const id of setIds) {
    if (haveSets.has(id)) continue;
    const pcs = PIECES.filter((x) => x.setId === id);
    d.sets.push({ id, name: setName[id], collection: pcs[0].collection, disciplineId: pcs[0].disciplineId, pieces: pcs.map((x) => x.id),
      bonuses: bonusSrc[id].map((b) => ({ pieces: b.pieces, ...(b.name ? { name: b.name } : {}), lines: [bonusText(b)] })) });
  }
});

// ---- icons ------------------------------------------------------------------------------------------------------------------------------
const shapes = {
  head: '<path d="M28 71V53a36 36 0 0 1 72 0v18l-12 5V57H40v19z"/><path d="M25 75h78v10H25z"/>',
  chest: '<path d="m44 23 20 9 20-9 24 15-9 21-11-6v48H40V53l-11 6-9-21z"/><path d="M64 33v67" fill="none"/>',
  hands: '<path d="m21 34 13-5 10 11 9-9 10 9-4 27-14 30-18-5-5-32z"/><path d="m72 40 10-9 9 9 10-11 13 5-1 26-5 32-18 5-14-30z"/>',
  legs: '<path d="M33 23h62l-5 35-10 45H61l-4-39-4 39H34L24 58z"/><path d="M57 36v29" fill="none"/>',
  feet: '<path d="M25 39h28v35l13 12-3 15H17V87l8-14z"/><path d="M75 39h28v34l8 14v14H65l-3-15 13-12z"/>',
};
const hex = (n) => `#${n.toString(16).padStart(6, '0')}`;
for (const x of PIECES) {
  const dark = '#17151f';
  const legendaryFrame = x.collection === 3 ? `<rect x="5" y="5" width="118" height="118" rx="15" fill="none" stroke="#ff9a2e" stroke-width="3"/><rect x="10" y="10" width="108" height="108" rx="12" fill="none" stroke="${hex(x.accent)}" stroke-width="1.5" opacity=".8"/><path d="m64 5 9 11-9 11-9-11z" fill="#ff9a2e"/><path d="M30 113h68" stroke="#ff9a2e" stroke-width="3"/>` : '';
  const ascendedFrame = x.collection === 2 ? `<rect x="7" y="7" width="114" height="114" rx="14" fill="none" stroke="${hex(x.accent)}" stroke-width="2" opacity=".9"/><path d="m64 8 8 10-8 10-8-10z" fill="${hex(x.accent)}"/><path d="M34 112h60" stroke="${hex(x.accent)}" stroke-width="2"/>` : '';
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128"><defs><radialGradient id="bg"><stop stop-color="${hex(x.color)}" stop-opacity=".34"/><stop offset="1" stop-color="${dark}"/></radialGradient><linearGradient id="metal" x2="1" y2="1"><stop stop-color="${hex(x.accent)}"/><stop offset=".48" stop-color="${hex(x.color)}"/><stop offset="1" stop-color="${dark}"/></linearGradient></defs><rect width="128" height="128" rx="17" fill="url(#bg)"/><path d="M12 19h21M95 19h21M12 109h21M95 109h21" stroke="${hex(x.accent)}" stroke-width="3" opacity=".8"/>${ascendedFrame}${legendaryFrame}<g fill="url(#metal)" stroke="${hex(x.accent)}" stroke-width="3" stroke-linejoin="round">${shapes[x.part]}</g><circle cx="64" cy="58" r="7" fill="${hex(x.accent)}" stroke="${dark}" stroke-width="2"/></svg>\n`;
  for (const dir of ['client/assets/ui_art/art/items', 'public/art/items']) put(`${dir}/${x.id}.svg`, svg);
}

// ---- server items rows: a new additive migration for pieces no migration inserts --------------------------------------------------------
const migDir = 'server/death-muffin/backend/migrations';
const migs = readdirSync(p(migDir)).filter((f) => f.endsWith('.sql')).sort();
const inserted = migs.map((f) => readFileSync(p(`${migDir}/${f}`), 'utf8')).join('\n');
const missing = PIECES.filter((x) => !inserted.includes(`'${x.id}'`));
if (missing.length) {
  const quote = (s) => `'${String(s).replaceAll("'", "''")}'`;
  const rows = missing.map((x) => `  (${[x.id, x.name, x.rarity, x.type, x.part, 0, JSON.stringify(x.stats), `art/items/${x.id}.svg`, x.sell, 0, 0, 1]
    .map((v) => typeof v === 'number' ? String(v) : quote(v)).join(', ')})`);
  const sets = [...new Set(missing.map((x) => x.setId))];
  const next = String(Number(migs.at(-1).slice(0, 3)) + 1).padStart(3, '0');
  const file = `${migDir}/${next}-armor-${sets.join('-').replaceAll('_', '-')}.sql`;
  put(file, `-- Armor set item rows (${sets.map((s) => setName[s]).join(', ')}; ${missing.length} pieces), written by tools/generate-armor-assets.mjs; additive and safe to rerun.\n` +
    `INSERT IGNORE INTO items\n  (id, name, rarity, item_type, equipment_slot, two_handed, stat_bonus, icon_id, sell_value, crafted, stackable, max_stack_size)\nVALUES\n${rows.join(',\n')};\n`);
}

if (CHECK) {
  if (stale.length) { console.error(`Armor data out of date (run node tools/generate-armor-assets.mjs):\n  ${stale.join('\n  ')}`); process.exit(1); }
  console.log('Armor data up to date.');
} else {
  console.log(stale.length ? `Updated:\n  ${stale.join('\n  ')}` : 'Armor data already up to date.');
}
