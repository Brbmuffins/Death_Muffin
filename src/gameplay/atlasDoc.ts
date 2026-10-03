import { AREAS, AREA_ORDER, type AreaId } from '../content/areas';
import { BOSSES, BOSS_IDS } from '../content/bosses';
import { DISCIPLINES, type DisciplineId } from '../content/disciplines';
import { ITEMS } from '../content/items';
import { LEGENDARY_BOSS_AREAS, LEGENDARY_DROP, LEGENDARY_SETS, LEGENDARY_SET_IDS, legendarySetFor } from '../content/legendarySets';
import { SEEDS } from '../content/gardening';
import { CHEST_KILLS, DEPTHS, FLOOR_DROP_CHANCE, chestDrops, chestRuneChance, floorKills } from '../content/depths';
import { AREA_REAGENT_DROPS, ELITE_REAGENT_MULT } from '../content/reagents';
import { ELITE_RUNE_CHANCE, SURGE_RUNE_CHANCE, BOSS_REPEAT_RUNE_CHANCE } from '../content/runes';
import { ALL_RECIPE_ROWS } from '../content/recipes';
import { ARMOR_PIECES } from '../content/armorSets';
import { AFFIXES, affixRange, affixText } from './affixRules';
import { NODES, SKILLS } from './gatheringRules';
import { KILL_LOOT } from './loot';
import { STAT_PRIORITY, RECOMMENDED_WEAPONS } from './gearStats';
import { NECRO_KIND_LABEL } from '../content/necroWeapons';
import { RELIC_ORDERS, RELIC_PREMIUM, RELIC_CHANCE } from './contractRules';
import { salvagePreview, SALVAGE_BONUS_PER_LEVEL, SALVAGE_AFFIX_BONUS, SALVAGE_ILVL_BONUS } from './salvageRules';
import {
  ILVL_OFFSETS, SCALING_NOTES, cosmeticsInfo, SOURCE_LABEL, affixCountOdds, depthBands, fmtChance, fmtQty, getAtlas, legendaryShare, oneIn, skillName, stationOf, tableShares,
  type DropSource,
} from './atlas';
import type { Rarity } from '../net/types';

/**
 * docs/LOOT-TABLES.md, generated from gameplay/atlas.ts by `npm run gen:loot`. A unit test fails when the committed file is stale,
 * so the page the owner reads can never drift from the tables the game rolls. Do not edit it by hand.
 */

const name = (id: string) => ITEMS[id]?.name ?? id;
const rarityMark = (r: Rarity) => r.charAt(0).toUpperCase() + r.slice(1);
const table = (head: string[], rows: string[][]) => [`| ${head.join(' | ')} |`, `|${head.map(() => '---').join('|')}|`, ...rows.map((r) => `| ${r.join(' | ')} |`)].join('\n');
const pct = (p: number) => fmtChance(p);
const withOdds = (p: number) => (oneIn(p) ? `${pct(p)} (${oneIn(p)})` : pct(p));
const ordinal = (x: number) => `${+(x * 100).toFixed(2)}%`;

function find(list: DropSource[] | undefined, pred: (s: DropSource) => boolean): DropSource | undefined {
  return (list ?? []).find(pred);
}

function areaSection(areaId: AreaId): string {
  const a = AREAS[areaId];
  const atlas = getAtlas();
  const out: string[] = [];
  const pO = Math.min(1, a.itemChance * KILL_LOOT.itemChanceMult);
  const pE = Math.min(1, a.itemChance * 6);
  out.push(`### ${a.name}`);
  out.push(`*Level ${a.level}${a.scaling ? ` (scaled: its dead match the highest-level player, never below ${a.scaling.minLevel})` : ''}${a.unlock ? `, opens after ${a.unlock.kills} kills in ${AREAS[a.unlock.area].name}` : ''}. Area item chance ${ordinal(a.itemChance)}: an ordinary kill rolls ${ordinal(pO)}, an elite kill ${ordinal(pE)}, then picks from the table by weight. ${ordinal(a.eliteChance)} of spawns are elites.*`);
  out.push('');
  const shares = [...tableShares(areaId)].sort((x, y) => y[1] - x[1]);
  const rows = shares.map(([id, share]) => {
    const list = atlas.sources.get(id);
    const k = find(list, (s) => s.placeId === areaId && s.kind === 'kill' && s.event === 'Ordinary kill');
    const e = find(list, (s) => s.placeId === areaId && s.kind === 'elite' && s.event === 'Elite kill');
    const su = find(list, (s) => s.placeId === areaId && s.kind === 'surge');
    return [name(id), rarityMark(ITEMS[id]?.rarity ?? 'common'), pct(share), withOdds(k!.chance), pct(e!.chance), pct(su!.chance), fmtQty(k!.qty)];
  });
  out.push(table(['Item', 'Rarity', 'Share of table', 'Ordinary kill', 'Elite kill', 'Grave Surge', 'Qty (ordinary)'], rows));
  const reagents = AREA_REAGENT_DROPS[areaId] ?? [];
  if (reagents.length) {
    out.push('');
    out.push(`**Reagents** (separate roll per kill): ${reagents.map((d) => `${name(d.item)} ${pct(d.chance)} per kill, ${pct(Math.min(1, d.chance * ELITE_REAGENT_MULT))} per elite (${fmtQty(d.qty)})`).join('; ')}.`);
  }
  const runes = [...atlas.sources].filter(([id, list]) => ITEMS[id]?.type === 'rune' && list.some((s) => s.placeId === areaId && s.kind === 'elite'));
  if (runes.length) {
    const tot = runes.reduce((n, [, list]) => n + find(list, (s) => s.placeId === areaId && s.kind === 'elite')!.chance, 0);
    out.push('');
    out.push(`**Relic runes**: an elite sheds one ${pct(ELITE_RUNE_CHANCE)} of the time, a Grave Surge ${pct(SURGE_RUNE_CHANCE)} of the time (instead of the item). Pool of ${runes.length} (${pct(tot)} per elite in all):`);
    out.push('');
    out.push(table(['Rune', 'Rarity', 'Per elite kill', 'Per Grave Surge'], runes.map(([id, list]) => [name(id), rarityMark(ITEMS[id].rarity), pct(find(list, (s) => s.placeId === areaId && s.kind === 'elite')!.chance), pct(find(list, (s) => s.placeId === areaId && s.kind === 'surge')!.chance)])));
  }
  if (a.scaling && a.loot.length) out.push(`\n**Legendary armor**: a ${pct(LEGENDARY_DROP.eliteChance)} roll per elite kill here (any set; your discipline's own set is ${pct(LEGENDARY_DROP.ownShare)} of them). See [Legendary sets](#legendary-armor-sets).`);
  const bosses = BOSS_IDS.filter((b) => BOSSES[b].area === areaId);
  for (const b of bosses) out.push('', bossSection(b));
  return out.join('\n');
}

function bossSection(b: (typeof BOSS_IDS)[number]): string {
  const def = BOSSES[b];
  const atlas = getAtlas();
  const out: string[] = [];
  out.push(`#### ${def.name} (${def.title})`);
  out.push(`Costs ${def.shards} soul shards to summon. Spoils: three rolls of the ${AREAS[def.area].name.replace(/^The /, '')} table, **${name(`ichor_${b === 'saint' ? 'plague_saint' : b}`)} always**${LEGENDARY_BOSS_AREAS.includes(def.area) ? `, and a ${pct(LEGENDARY_DROP.bossChance)} legendary roll` : ' (no legendary roll: the Hollow Graves are too early for build-defining gear)'}. ${b === 'prelate' ? 'The Prelate always leaves a rune' : `First kill per character: a guaranteed rare-or-better item and a rune; repeats leave a rune ${pct(BOSS_REPEAT_RUNE_CHANCE)} of the time`}.`);
  out.push('');
  const rows: string[][] = [];
  const ids = [...tableShares(def.area).keys()];
  for (const id of ids) {
    const list = atlas.sources.get(id);
    const boss = find(list, (s) => s.placeId === b && s.kind === 'boss');
    const first = find(list, (s) => s.placeId === b && s.kind === 'first_kill');
    rows.push([name(id), rarityMark(ITEMS[id]?.rarity ?? 'common'), boss ? pct(boss.chance) : '-', first ? pct(first.chance) : '-']);
  }
  rows.sort((x, y) => parseFloat(y[2]) - parseFloat(x[2]));
  out.push(table(['Item', 'Rarity', 'At least one in the 3 rolls', 'First kill (the guaranteed item)'], rows));
  const runes = [...atlas.sources].filter(([id, list]) => ITEMS[id]?.type === 'rune' && list.some((s) => s.placeId === b));
  if (runes.length) {
    out.push('');
    out.push(`Runes from this boss: ${runes.map(([id, list]) => `${name(id)} ${pct(list.find((s) => s.placeId === b && s.kind === 'boss')?.chance ?? list.find((s) => s.placeId === b)!.chance)}`).join(', ')} (per repeat kill${b === 'prelate' ? '' : '; the first kill always leaves one, at the same relative odds'}).`);
  }
  return out.join('\n');
}

function legendarySection(): string {
  const out: string[] = ['## Legendary armor sets', ''];
  out.push(`Legendary pieces are not in any area table. Each **boss kill past the Hollow Graves** (${LEGENDARY_BOSS_AREAS.map((a) => AREAS[a].name).join(', ')}) rolls ${pct(LEGENDARY_DROP.bossChance)} for one, and each **elite kill in a level-scaled ground** (Plague Cloister, Cinder Pyre, Mourning Fen, and Depths floors that drop from them) rolls ${pct(LEGENDARY_DROP.eliteChance)}. When one drops it is a random piece (1 of 5) of a set chosen by "smart loot": ${pct(LEGENDARY_DROP.ownShare)} your own discipline's set when it has one, the rest split evenly over the others (an even split with no own set).`);
  out.push('');
  out.push('Chance per boss kill (the Abbess onward) that you get a particular piece, by the discipline you play:');
  out.push('');
  const discs = Object.keys(DISCIPLINES) as DisciplineId[];
  const rows = discs.map((d) => {
    const own = legendarySetFor(d);
    const per = (setId: string) => legendaryShare(setId, d) * LEGENDARY_DROP.bossChance / 5;
    return [DISCIPLINES[d].name, own ? LEGENDARY_SETS[own].name : '(none yet)', own ? `${pct(per(own))} (${oneIn(per(own))})` : '-', `${pct(per(LEGENDARY_SET_IDS.find((s) => s !== own)!))} (${oneIn(per(LEGENDARY_SET_IDS.find((s) => s !== own)!))})`];
  });
  out.push(table(['You play', 'Own set', 'Each piece of your own set', 'Each piece of another set'], rows));
  out.push('');
  out.push(`The same shares apply to the elite roll, scaled by ${pct(LEGENDARY_DROP.eliteChance)} instead of ${pct(LEGENDARY_DROP.bossChance)}. A Gravecaller sees any given piece of their own set about once per ${Math.round(1 / (LEGENDARY_DROP.bossChance * LEGENDARY_DROP.ownShare / 5))} boss kills.`);
  out.push('');
  for (const id of LEGENDARY_SET_IDS) {
    const s = LEGENDARY_SETS[id];
    out.push(`- **${s.name}** (${s.wearer}): ${Object.values(s.pieces).join(', ')}.`);
  }
  return out.join('\n');
}

function depthsSection(): string {
  const out: string[] = ['## The Catacomb Depths', ''];
  out.push(`Each floor asks for ${floorKills(1)}-${floorKills(99)} kills before the stair opens. A Depths kill drops from the table of the hunting ground whose gear matches the depth, so there is no table of its own: use the matching ground's table above. Clearing a floor leaves an item on the stair ${pct(FLOOR_DROP_CHANCE)} of the time; every ${DEPTHS.chestEvery}th floor holds a chest (its first drop is always gear; ${chestDrops(5)} drops at floor 5, one more every 10 floors; ${CHEST_KILLS} kills' worth of gold and XP).`);
  out.push('');
  const rows = depthBands().map((b) => {
    const a = AREAS[b.area];
    const floors = b.to === Infinity ? `${b.from}+` : b.from === b.to ? `${b.from}` : `${b.from}-${b.to}`;
    const first = Math.ceil(b.from / DEPTHS.chestEvery) * DEPTHS.chestEvery;
    const chest = first <= b.to ? `floor ${first}: ${chestDrops(first)} drops, ${pct(chestRuneChance(first))} rune` : 'none';
    return [floors, a.name, pct(Math.min(1, a.itemChance * KILL_LOOT.itemChanceMult)), pct(Math.min(1, a.itemChance * 6)), chest];
  });
  out.push(table(['Floors', 'Drops from the table of', 'Ordinary kill', 'Elite kill', 'First chest in the band'], rows));
  out.push('');
  out.push(`Runes in chests: ${pct(chestRuneChance(5))} at floor 5, +2 points per chest, ${pct(chestRuneChance(999))} at most; epic runes join from floor 10. Elites on floors that drop from a level-scaled ground (floor 15 onward) can also drop legendary armor.`);
  return out.join('\n');
}

function gatheringSection(): string {
  const rows = Object.values(NODES).map((n) => {
    const extras = n.extras.filter((e) => !ITEMS[e.item]?.name.includes('Charm')).map((e) => `${name(e.item)} ${withOdds(e.chance)}`).join(', ');
    return [n.name, `${SKILLS[n.skill].name} ${n.level}`, name(n.item), `${n.yields[0]}-${n.yields[1]}`, extras || '-'];
  });
  return ['## Gathering nodes', '', 'Chance is per successful action; each node yields its main item every success, plus the rare finds below (each skill\'s pet charm also has a small chance, not listed).', '', table(['Node', 'Skill', 'Main item', 'Successes before depleted', 'Rare finds'], rows)].join('\n');
}

function gardenSection(): string {
  const rows = SEEDS.map((s) => [name(s.id), `Gardening ${s.level}`, `${s.growMin} min`, `${name(s.harvest)} x${fmtQty(s.yields)}`, pct(s.seedBack)]);
  return ['## Grave Gardening', '', table(['Seed', 'Level', 'Grows in', 'Harvest', 'Seed back'], rows)].join('\n');
}

function recipesSection(): string {
  const out: string[] = ['## Crafting, brewing and processing', '', 'Level is the skill level needed. Stations: the Workbench in the Chapterhouse does everything except brewing; the Sexton\'s Acre stations (Sawpit, Bone Kiln, Cooking Fire) each do their own recipes; brewing happens at the Great Cauldron in the Alchemist\'s Wing.', ''];
  const groups = new Map<string, typeof ALL_RECIPE_ROWS>();
  for (const r of ALL_RECIPE_ROWS) (groups.get(r[2]) ?? groups.set(r[2], []).get(r[2])!).push(r);
  for (const [prof, rows] of groups) {
    out.push(`### ${skillName(prof)}${prof === 'mining' ? ' (smelting and smithing)' : prof === 'woodcutting' ? ' (carpentry)' : prof === 'fishing' ? ' (cooking)' : prof === 'gravedigging' ? ' (bonework)' : ''}`);
    out.push('');
    out.push(table(['Makes', 'Level', 'Ingredients', 'Where'], [...rows].sort((x, y) => x[3] - y[3] || x[4].localeCompare(y[4])).map((r) => [`${name(r[4])}${r[5] > 1 ? ` x${r[5]}` : ''}`, String(r[3]), r[6].map(([i, n]) => `${n} ${name(i)}`).join(', '), stationOf({ id: r[0], profession: r[2] })])));
    out.push('');
  }
  return out.join('\n');
}

function cosmeticsSection(): string {
  const c = cosmeticsInfo();
  const out: string[] = ['## Capes and pets', ''];
  for (const n of c.notes) out.push(`- ${n}`);
  out.push('', '### Capes', '');
  out.push(table(['Cape', 'How to earn it', 'Notes'], c.capes.map((x) => [x.name, x.requirement, x.lore])));
  out.push('', '### Pets', '');
  const rows = c.pets.map((p) => {
    const g = p.sources.filter((x) => x.kind === 'gather').map((x) => x.chance);
    const h = p.sources.find((x) => x.kind === 'garden');
    const parts = [`any ${p.skill} node, ${g.length} in all: ${withOdds(Math.min(...g))} on the lowest tier to ${withOdds(Math.max(...g))} on the highest`];
    if (h) parts.push(`${h.place}: ${h.event.toLowerCase()} ${withOdds(h.chance)}`);
    return [p.name, rarityMark(p.rarity), `${name(p.charm)} (${p.skill})`, parts.join('; ')];
  });
  out.push(table(['Pet', 'Rarity', 'Charm', 'Where the charm turns up (per successful action)'], rows));
  return out.join('\n');
}

function salvageSection(): string {
  const out: string[] = ['## Salvage (the Bone Grinder)', ''];
  out.push(`Gear and runes grind into materials. Metal gear gives ingots; staffs, wands, grimoires and books give planks. Each Salvaging level adds ${pct(SALVAGE_BONUS_PER_LEVEL)} of one extra material; a rolled piece adds ${pct(SALVAGE_AFFIX_BONUS)} per affix and ${pct(SALVAGE_ILVL_BONUS)} per item level to a second extra-material chance.`);
  out.push('');
  const rows = (['common', 'uncommon', 'rare', 'epic', 'legendary'] as Rarity[]).map((r) => {
    const m = salvagePreview({ id: 'sword', item_type: 'weapon', rarity: r });
    const w = salvagePreview({ id: 'staff', item_type: 'weapon', rarity: r });
    return [rarityMark(r), `${m.materials.map(name).join(' or ')} x${fmtQty(m.materialQty)}`, `${w.materials.map(name).join(' or ')} x${fmtQty(w.materialQty)}`, m.reagents.map((x) => `${name(x.id)} ${pct(x.chance)}`).join(', '), String(m.xp)];
  });
  out.push(table(['Gear rarity', 'Metal gear', 'Staffs, wands, books', 'Reagents', 'Salvaging XP'], rows));
  return out.join('\n');
}

function relicSection(): string {
  const rows = RELIC_ORDERS.map((r) => [name(r.itemId), rarityMark(ITEMS[r.itemId].rarity), `${skillName(r.skill)} ${r.level}`, String(r.qty), String(Math.round(r.qty * ITEMS[r.itemId].sell * RELIC_PREMIUM))]);
  return ['## Trade goods and the Sexton', '', `Reliquary Fragments, Covenant Seals and the Void Sapphire have no recipe, and Grave Garnets and Bone Opals have only one each (the Workbench's Garnet Ring and Opal Flask, never worth more at the vendor than what they eat), so the Sexton's Contracts (O) buy them: on about ${pct(RELIC_CHANCE)} of days the hard order is a relic order for a fixed handful, paid at ${RELIC_PREMIUM}x the sell price (and one Grave Garnet back; the rarer gems are never paid out). Tin and Bronze Ingots are ordered like any smelted good, and also make a Tin Augment and a Bronze Warden Kit at the Workbench. Pet charms are adopted, seeds and saplings are planted, and everything else is a recipe ingredient.`, '', table(['Item', 'Rarity', 'Order unlocks at', 'Quantity asked', 'Gold paid (before the slot fee)'], rows)].join('\n');
}

function upgradeSection(): string {
  const out: string[] = ['## How to upgrade gear', ''];
  out.push('There is no upgrade bench: gear gets better by **item level** and **affixes**, both rolled by the server when it drops, and by **set bonuses** when you wear matching pieces. Replace a piece when a better roll or a better set comes along; salvage or sell the rest.');
  out.push('');
  out.push('### Item level');
  out.push('');
  out.push(`Item level is the level of the ground (or boss) that dropped it plus a bonus for how it dropped, capped at ${99}: ${(Object.keys(ILVL_OFFSETS) as (keyof typeof ILVL_OFFSETS)[]).map((k) => `${SOURCE_LABEL[k].toLowerCase()} +${ILVL_OFFSETS[k]}`).join(', ')}. Ordinary kills and elites both roll as "elite" (see the scaling notes). Higher item level means bigger affix numbers.`);
  out.push('');
  out.push('### How many affixes');
  out.push('');
  out.push('Odds of 0 / 1 / 2 / 3 affixes, by the base item\'s rarity and how it dropped (bosses always give at least 1, a first kill at least 2):');
  out.push('');
  const rows: string[][] = [];
  for (const r of ['common', 'uncommon', 'rare', 'epic', 'legendary']) {
    for (const s of ['elite', 'surge', 'boss', 'first_kill'] as const) rows.push([rarityMark(r as Rarity), SOURCE_LABEL[s], ...affixCountOdds(r, s).map(pct)]);
  }
  out.push(table(['Base rarity', 'Dropped as', '0', '1', '2', '3'], rows));
  out.push('');
  out.push('### The affixes');
  out.push('');
  out.push('Violet lines in the game (necromancer levers) are marked "levers". Ranges are at item level 10 and 40.');
  out.push('');
  out.push(table(['Affix', 'Kind', 'Weight', 'Item level 10', 'Item level 40'], AFFIXES.map((a) => {
    const r10 = affixRange(a.id, 10)!;
    const r40 = affixRange(a.id, 40)!;
    return [`${a.word}${a.necro ? ' (levers)' : ''}`, a.kind, String(a.weight), `${affixText({ id: a.id, v: r10[0] })} to ${affixText({ id: a.id, v: r10[1] }).replace(/^[^0-9+]*/, '')}`, `${affixText({ id: a.id, v: r40[0] })} to ${affixText({ id: a.id, v: r40[1] }).replace(/^[^0-9+]*/, '')}`];
  })));
  out.push('');
  out.push('### Armor set bonuses');
  out.push('');
  const atlas = getAtlas();
  for (const s of atlas.sets) {
    out.push(`- **${s.name}** (${s.collection === 1 ? 'first' : s.collection === 2 ? 'ascended' : 'legendary'} set, ${DISCIPLINES[s.disciplineId as DisciplineId]?.name ?? s.disciplineId}): ${s.bonuses.map((b) => `${b.pieces} pieces${b.name ? ` "${b.name}"` : ''}: ${b.lines.join('; ')}`).join(' | ')}`);
  }
  return out.join('\n');
}

function wantsSection(): string {
  const out: string[] = ['## What each discipline wants', ''];
  const rows = (Object.keys(DISCIPLINES) as DisciplineId[]).map((d) => {
    const rec = RECOMMENDED_WEAPONS[d];
    return [DISCIPLINES[d].name, STAT_PRIORITY[d].order.map((k) => k.replace('stat_', '').toUpperCase()).join(' > '), rec ? rec.kinds.map((k) => NECRO_KIND_LABEL[k]).join(', ') : 'any (the necromancer weapon mechanics only apply to necromancers)'];
  });
  out.push('The in-game Gear Atlas ranks every piece for your discipline with the same gear score the Character sheet uses (`npm run balance:score`).');
  out.push('');
  out.push(table(['Discipline', 'Stat priority', 'Weapon kinds'], rows));
  return out.join('\n');
}

function setsDropSection(): string {
  const out: string[] = ['## Where armor sets drop', ''];
  out.push('Armor pieces sit in the area tables above with equal weight within a set collection. First-collection sets: head and grips from the Hollow Graves, chest from the Marrow Ossuary, legs from the Drowned Nave, feet from the Bell Sanctum (Cloister and Pyre drop the chest/legs/feet too). Ascended sets: head and grips from the Bell Sanctum, chest and legs from the Plague Cloister, feet from the Cinder Pyre; the Mourning Fen drops the whole ascended collection.');
  out.push('');
  const rows = ARMOR_PIECES.filter((p) => p.collection !== 3 && p.disciplineId === 'gravecaller').map((p) => [p.name, p.setName, `${p.collection === 1 ? 'first' : 'ascended'}`, `${rarityMark(p.rarity)}`, Object.entries(p.stats).map(([k, v]) => `+${v} ${k.replace('stat_', '').toUpperCase()}`).join(' ')]);
  out.push('Example (the Gravecaller\'s pieces; every discipline has the same shape with its own two stats):');
  out.push('');
  out.push(table(['Piece', 'Set', 'Collection', 'Rarity', 'Stats'], rows));
  return out.join('\n');
}

export function renderLootTables(): string {
  const out: string[] = [];
  out.push('# Loot tables and gear atlas');
  out.push('');
  out.push('> Generated by `npm run gen:loot` from `src/gameplay/atlas.ts`, which reads the same tables the game rolls. **Do not edit by hand**; a test fails when this file is stale. In game, the **Gear Atlas** (the **.** key, Atlas in the Menu on a phone) shows all of this for your discipline, with an upgrade arrow against what you wear.');
  out.push('');
  out.push('Percentages are per event at default settings (Medium difficulty, Wave Speed tier 0, no fortune tonic). "1 in N" is shown for rare drops.');
  out.push('');
  out.push('## What moves these numbers');
  out.push('');
  for (const n of SCALING_NOTES) out.push(`- ${n}`);
  out.push('');
  out.push('## Hunting grounds and bosses');
  out.push('');
  for (const id of AREA_ORDER) if (AREAS[id].loot.length) out.push(areaSection(id), '');
  out.push(setsDropSection(), '');
  out.push(legendarySection(), '');
  out.push(depthsSection(), '');
  out.push(gatheringSection(), '');
  out.push(gardenSection(), '');
  out.push(recipesSection());
  out.push(cosmeticsSection(), '');
  out.push(salvageSection(), '');
  out.push(relicSection(), '');
  out.push(upgradeSection(), '');
  out.push(wantsSection(), '');
  return out.join('\n').replace(/\n{3,}/g, '\n\n').trimEnd() + '\n';
}
