/**
 * Generate the necro weapon line's server migration and inventory icons from src/content/necroWeapons.ts, so the
 * server rows, the offline catalogue and the client cannot drift (same pattern as generate-armor-assets.mjs).
 *   node tools/generate-necro-weapons.mjs          (write 013-necro-weapons.sql + 35 SVG icons)
 *   node tools/generate-necro-weapons.mjs --check  (exit 1 if either is stale; the tests run this)
 * The SQL is additive and idempotent (INSERT IGNORE). Apply it to the Death Muffin database after a backup and before
 * publishing a client that can drop these ids.
 */
import { build } from 'esbuild';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
export const SQL_OUT = join(root, 'server/death-muffin/backend/migrations/013-necro-weapons.sql');
const ICON_DIR = join(root, 'public/art/items');

async function load() {
  const res = await build({ entryPoints: [join(root, 'src/content/necroWeapons.ts')], bundle: true, platform: 'node', format: 'esm', write: false });
  return import('data:text/javascript;base64,' + Buffer.from(res.outputFiles[0].text).toString('base64'));
}

const hex = (n) => `#${n.toString(16).padStart(6, '0')}`;
const quote = (s) => `'${String(s).replace(/\\/g, '\\\\').replace(/'/g, "''")}'`;
const dark = '#17151f';

/** Silhouettes on a 128 grid, upright like the in-hand props. */
const shapes = {
  staff: '<path d="M60 112 66 38l4-2-2 76z"/><path d="M50 24c0-10 8-16 14-16s14 6 14 16c0 8-5 12-7 14H57c-2-2-7-6-7-14z"/><path d="M48 30c-7 4-9 13-2 19M80 30c7 4 9 13 2 19" fill="none"/><circle cx="64" cy="22" r="5" fill="#17151f"/><path d="M56 62h14M57 82h14" fill="none"/>',
  scythe: '<path d="M60 118 66 18h5L67 118z"/><path d="M68 18C92 8 112 14 118 44c-14-16-34-18-50-12z"/><path d="M68 28c14-2 26 2 34 12" fill="none"/><path d="M56 30h20" fill="none"/><circle cx="68" cy="30" r="4" fill="#17151f"/>',
  wand: '<path d="M66 12 72 24 68 40h-8L58 24z"/><path d="M58 40h16l-2 14h-12zM62 54h8l-2 50h-4z"/><path d="M64 104l-7 12M64 104l7 12" fill="none"/><path d="M59 66c8 4 8 10 0 14M69 76c-8 4-8 10 0 14" fill="none"/>',
  sickle: '<path d="M58 118 66 72h8l-6 46z"/><path d="M64 74C28 70 20 34 46 16c-6 18 4 34 28 40z"/><path d="M40 34c4 14 14 22 26 26" fill="none"/><circle cx="64" cy="120" r="5" fill="none"/><path d="M56 74h22" fill="none"/>',
  skull_focus: '<path d="M64 12c-20 0-32 14-32 32 0 10 4 16 10 20v10h44V64c6-4 10-10 10-20 0-18-12-32-32-32z"/><circle cx="51" cy="44" r="8" fill="#17151f"/><circle cx="77" cy="44" r="8" fill="#17151f"/><path d="M64 52 59 62h10z" fill="#17151f"/><path d="M52 74v8M60 74v8M68 74v8M76 74v8" fill="none"/><path d="M58 84h12l2 30H56z"/>',
  grimoire: '<path d="M30 14h64a6 6 0 0 1 6 6v82a6 6 0 0 1-6 6H30z"/><path d="M30 14v94" fill="none"/><path d="M26 18v92a6 6 0 0 0 6 6h66" fill="none"/><path d="M62 38a10 10 0 1 1 0 .1z" fill="#17151f"/><path d="M48 62c10 8 24 8 34 0M50 72c10 6 22 6 32 0M52 82c8 4 18 4 26 0" fill="none"/><path d="M92 54h8v14h-8z"/>',
  mourning_bell: '<path d="M58 14h12v18H58z"/><path d="M46 38c0-10 8-16 18-16s18 6 18 16c0 14 6 28 14 40H32c8-12 14-26 14-40z"/><path d="M28 82h72v8H28z"/><circle cx="64" cy="102" r="8"/><path d="M48 40c-2 12-6 22-12 34M80 40c2 12 6 22 12 34" fill="none"/><path d="M70 28c16 2 22 12 26 26" fill="none"/>',
};

function icon(w) {
  const c = hex(w.color);
  const a = hex(w.accent);
  const frame = w.tier === 'moon' || w.tier === 'hell'
    ? `<rect x="7" y="7" width="114" height="114" rx="14" fill="none" stroke="${a}" stroke-width="2" opacity=".9"/><path d="m64 8 8 10-8 10-8-10z" fill="${a}"/>`
    : '';
  const slotBadge = w.twoHanded ? `<path d="M14 110h10M14 104h10" stroke="${a}" stroke-width="3" opacity=".8"/>` : '';
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128"><defs><radialGradient id="bg"><stop stop-color="${c}" stop-opacity=".34"/><stop offset="1" stop-color="${dark}"/></radialGradient><linearGradient id="metal" x2="1" y2="1"><stop stop-color="${a}"/><stop offset=".48" stop-color="${c}"/><stop offset="1" stop-color="${dark}"/></linearGradient></defs><rect width="128" height="128" rx="17" fill="url(#bg)"/><path d="M12 19h21M95 19h21M12 109h21M95 109h21" stroke="${a}" stroke-width="3" opacity=".8"/>${frame}${slotBadge}<g fill="url(#metal)" stroke="${a}" stroke-width="3" stroke-linejoin="round" stroke-linecap="round">${shapes[w.kind]}</g></svg>\n`;
}

export async function render() {
  const { NECRO_WEAPONS, NECRO_RECIPES } = await load();
  const rows = NECRO_WEAPONS.map((w) => `  (${[
    w.id, w.name, w.rarity, w.type, w.slot, w.twoHanded ? 1 : 0, JSON.stringify(w.stats), `art/items/${w.id}.svg`, w.sell, 0, 0, 1,
  ].map((v) => (typeof v === 'number' ? String(v) : quote(v))).join(', ')})`);
  const lines = [
    '-- 013-necro-weapons.sql: the necromancer weapon line (4 main-hand kinds + 3 off-hands x 5 tiers) and its Workbench recipes.',
    '-- GENERATED by tools/generate-necro-weapons.mjs from src/content/necroWeapons.ts. Do not edit by hand.',
    '-- Additive and idempotent (INSERT IGNORE): safe to rerun. Apply to the Death Muffin database after a backup, before publishing the client.',
    'INSERT IGNORE INTO items',
    '  (id, name, rarity, item_type, equipment_slot, two_handed, stat_bonus, icon_id, sell_value, crafted, stackable, max_stack_size)',
    'VALUES',
    rows.join(',\n') + ';',
    '',
  ];
  for (const [id, name, prof, level, result, qty, ings] of NECRO_RECIPES) {
    lines.push(`INSERT IGNORE INTO recipes (id, name, profession_id, skill_level_required, result_item_id, recipe_type, craft_time_seconds, result_quantity) VALUES (${[
      id, name, prof, level, result, 'craft', 6, qty,
    ].map((v) => (typeof v === 'number' ? String(v) : quote(v))).join(', ')});`);
    for (const [item, n] of ings) lines.push(`INSERT IGNORE INTO recipe_ingredients (recipe_id, item_id, quantity) VALUES (${[quote(id), quote(item), n].join(', ')});`);
  }
  return { sql: lines.join('\n') + '\n', icons: NECRO_WEAPONS.map((w) => [w.id, icon(w)]) };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const { sql, icons } = await render();
  if (process.argv.includes('--check')) {
    const stale = [];
    if ((existsSync(SQL_OUT) ? readFileSync(SQL_OUT, 'utf8') : '') !== sql) stale.push('013-necro-weapons.sql');
    for (const [id, svg] of icons) {
      const f = join(ICON_DIR, `${id}.svg`);
      if (!existsSync(f) || readFileSync(f, 'utf8') !== svg) stale.push(`${id}.svg`);
    }
    if (stale.length) {
      console.error(`stale: ${stale.slice(0, 6).join(', ')}${stale.length > 6 ? ` (+${stale.length - 6})` : ''} — run node tools/generate-necro-weapons.mjs`);
      process.exit(1);
    }
    console.log('necro weapons migration and icons are up to date');
  } else {
    mkdirSync(ICON_DIR, { recursive: true });
    writeFileSync(SQL_OUT, sql);
    for (const [id, svg] of icons) writeFileSync(join(ICON_DIR, `${id}.svg`), svg);
    console.log(`wrote ${SQL_OUT} and ${icons.length} icons`);
  }
}
