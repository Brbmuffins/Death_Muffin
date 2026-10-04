// Generates public/soundboard.html: one self-contained listening page for every game sound (AUDIO_MAP), so the owner can
// audition the clips by ear before release. Deterministic (no timestamps). Run through vite-node so the TS map imports as-is:
//   npm run build:soundboard
// The page references clips relatively (audio/esm/<file>.opus), so publish soundboard.html next to public/audio/esm/.
// It is excluded from the game's precache (tools/build-asset-manifest.mjs SKIP).
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const { AUDIO_MAP, AREA_SURFACE, ENEMY_VOICE, BOSS_TELL, MIX_RULES } = await import('../../src/content/audioMap.ts');
const { packOf, clipFile } = await import('../../src/audio/packs.ts');
const manifest = JSON.parse(readFileSync(path.join(root, 'public/audio/esm/manifest.json'), 'utf8'));
const report = readFileSync(path.join(root, 'docs/audio/esm-sanity-report.txt'), 'utf8');

// ---- sanity report: "<clip>\n    users: a,b\n    - reason" blocks
const flags = {};
{
  let cur = null;
  for (const line of report.split('\n')) {
    if (!line.trim() || line.startsWith('#')) continue;
    if (!line.startsWith(' ')) flags[(cur = line.trim())] = [];
    else if (line.trim().startsWith('- ') && cur) flags[cur].push(line.trim().slice(2));
  }
}
const mclip = new Map(manifest.clips.map((c) => [c.clip, c]));

// ---- categories
const GROUPS = ['Spells & rites', 'Combat & hits', 'Enemies', 'Bosses & danger tells', 'Loot & gold', 'Gathering & crafting', 'UI', 'Footsteps by surface', 'Ambience accents', 'Other'];
const LOOT = new Set('lootRare lootEpic lootLegendary lootDrop lootDropRare lootDropEpic lootDropLegendary goldPileDrop coin shard item chestOpen vaultOpen vaultClose equip buy'.split(' '));
const ELITE = new Set('eliteAggro eliteDeath tellStrike affixTell'.split(' '));
const OTHER = new Set('lowHealth drinkFlask drinkElixir eatMeal recallStart recallCancel waystoneTravel gate runeSocket'.split(' '));
function groupOf(id) {
  const pack = packOf(id);
  if (pack.startsWith('foot_')) return 'Footsteps by surface';
  if (pack.startsWith('fam_') || ELITE.has(id)) return 'Enemies';
  if (LOOT.has(id)) return 'Loot & gold';
  if (OTHER.has(id)) return 'Other';
  if (pack === 'amb') return 'Ambience accents';
  if (pack === 'boss') return 'Bosses & danger tells';
  if (pack === 'rites') return 'Spells & rites';
  if (pack === 'core') return 'Combat & hits';
  if (pack === 'world') return 'Gathering & crafting';
  return 'UI';
}
function subOf(id, g) {
  const pack = packOf(id);
  if (g === 'Footsteps by surface') return pack === 'foot_stone' ? 'stone' : pack.slice(5);
  if (pack.startsWith('fam_')) return pack.slice(4);
  if (g === 'Enemies') return 'elites';
  return '';
}
const bossesFor = (id) => Object.entries(BOSS_TELL).filter(([, s]) => s === id).map(([b]) => b);
const familyEnemies = (f) => Object.entries(ENEMY_VOICE).filter(([, v]) => v === f).map(([e]) => e);
const surfaceAreas = (s) => Object.entries(AREA_SURFACE).filter(([, v]) => v === s).map(([a]) => a);

const missing = [];
const clipSet = new Set();
const sounds = Object.keys(AUDIO_MAP).sort().map((id) => {
  const d = AUDIO_MAP[id];
  const group = groupOf(id);
  const sub = subOf(id, group);
  const mk = (name) => {
    clipSet.add(name);
    const file = clipFile(name);
    if (!existsSync(path.join(root, 'public', file))) missing.push(name);
    const m = mclip.get(name);
    return { name, file, dur: m?.dur ?? null, flags: flags[name] ?? [] };
  };
  const ctx = [];
  if (sub && group === 'Enemies' && sub !== 'elites') ctx.push(`${sub} voice: ${familyEnemies(sub).join(', ')}`);
  if (group === 'Footsteps by surface') ctx.push(`areas: ${surfaceAreas(sub).join(', ')}`);
  const b = bossesFor(id);
  if (b.length) ctx.push(`boss tell for: ${b.join(', ')}`);
  return {
    id, group, sub, pack: packOf(id), bus: d.bus, status: d.status ?? 'mapped', priority: d.priority,
    volume: d.volume, jitter: d.pitchJitter, rate: d.rate ?? 1, voices: d.maxVoices, cooldown: d.cooldownMs, loopMs: d.loopMs ?? 0,
    trim: d.trim ?? null, site: d.site ?? '', notes: d.notes ?? '', ctx: ctx.join(' | '),
    clips: d.files.map(mk),
    layer: d.layer ? { volume: d.layer.volume, delayMs: d.layer.delayMs, clips: d.layer.files.map(mk) } : null,
  };
});
if (missing.length) throw new Error(`clips with no encoded file: ${[...new Set(missing)].join(', ')}`);

const flaggedClips = [...clipSet].filter((c) => (flags[c] ?? []).length);
const data = {
  groups: GROUPS, sounds,
  counts: { ids: sounds.length, clips: clipSet.size, flagged: flaggedClips.length, partial: sounds.filter((s) => s.status === 'partial').length, keep: sounds.filter((s) => s.status === 'keep').length },
  mix: { partnerSpellGain: MIX_RULES.partnerSpellGain },
};
const json = JSON.stringify(data).replace(/</g, '\\u003c').replace(/\u2028/g, '\\u2028').replace(/\u2029/g, '\\u2029');

const html = readFileSync(path.join(root, 'tools/audio/soundboard.template.html'), 'utf8').replace('/*__DATA__*/null', () => json);
writeFileSync(path.join(root, 'public/soundboard.html'), html);
console.log(`soundboard.html: ${data.counts.ids} ids, ${data.counts.clips} clips, ${data.counts.flagged} flagged, ${data.counts.partial} partial, ${data.counts.keep} keep (no clip), ${(html.length / 1024).toFixed(0)} KB`);
