import * as THREE from 'three';
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { afterEach, describe, expect, it, vi } from 'vitest';

afterEach(() => vi.restoreAllMocks());
import { Nav } from '../nav';
import { WorldSim, thrallWeight } from '../sim/WorldSim';
import { WorldMirror, makeSnapshot } from '../sim/snapshot';
import { mulberry32 } from '../rng';
import type { Corpse, Enemy, Intent, SimEvent } from '../sim/types';
import { AbilitySystem, type AbilityContext } from '../AbilitySystem';
import { Player } from '../Player';
import { Effects } from '../../graphics/Effects';
import { DISCIPLINES } from '../../../server/rules/content/disciplines';
import { ABILITIES } from '../../content/abilities';
import { AREAS, AREA_ORDER } from '../../../server/rules/content/areas';
import { BOSS_IDS } from '../../../server/rules/content/bosses';
import { ITEMS, RARITY_COLOR } from '../../../server/rules/content/items';
import {
  AREA_RUNE_POOL, BOSS_RUNE_POOL, ELITE_RUNE_CHANCE_BY_AREA, eliteRuneChance, RUNES, RUNE_IDS, RUNE_RITES, RUNE_TUNING, SURGE_RUNE_CHANCE, isRuneId, pickRune, runeSources, runesFor,
  type RuneId, type RuneRite,
} from '../../../server/rules/content/runes';
import { RUNE_BASE, RUNE_SLOT_COUNT, isRuneSlot, ownedRunes, runeEquippedSlot, runeFits, runeSlotIndex, runeSlotRite, socketsOf, socketsSignature } from '../../../server/rules/gameplay/runeRules';
import { corpsesWithin, impaleTarget, ringCenter, ringHits, splinterTarget, volleyTargets } from '../runeCast';
import { rollBossRune, rollEliteRune, rollKill, rollSurgeItem, addToSlots } from '../loot';
import { loadRunesFound, recordRunesFound } from '../runeJournal';
import { salvagePreview, salvageYield, isSalvageable, isSalvageGear } from '../../../server/rules/gameplay/salvageRules';
import { itemCap, itemRatePerMin } from '../../../server/rules/gameplay/authorityRules';
import { depositMany } from '../../../server/rules/gameplay/vaultRules';
import { CODEX_RUNES_COUNSEL, codexRuneRows } from '../../content/codex';
import { TIPS } from '../../ui/Onboarding';
import { kindOf } from '../../ui/counselCadence';
import { MOCK_ITEMS } from '../../net/mockBackend';
import type { InventorySlot } from '../../net/types';

vi.mock('../../audio/Audio', () => ({ audio: { play: vi.fn(), loop: vi.fn(() => () => undefined) } }));
vi.mock('../../graphics/fxTextures', () => ({
  fx: Object.fromEntries(['glow', 'smoke', 'disc', 'ring', 'cracks', 'sigil'].map((name) => [name, () => new THREE.Texture()])),
}));
vi.mock('../../graphics/fxImages', () => ({ fxImage: () => new THREE.Texture() }));

const root = join(__dirname, '../../..');

// --- data ----------------------------------------------------------------------------------------------------------

describe('Relic rune data', () => {
  it('eleven runes, ids equal their icon files, two or three per rite', () => {
    expect(RUNE_IDS).toHaveLength(11);
    for (const id of RUNE_IDS) expect(existsSync(join(root, 'public/art/items', `${id}.webp`)), id).toBe(true);
    for (const rite of RUNE_RITES) expect(runesFor(rite).length, rite).toBeGreaterThanOrEqual(2);
    expect(runesFor('exhume').map((r) => r.id)).toEqual(['rune_mass_grave', 'rune_bone_colossus']);
  });
  it('each rune names the exact change and, where it has one, the price', () => {
    for (const r of Object.values(RUNES)) {
      expect(r.lines.length, r.id).toBeGreaterThan(0);
      for (const l of r.lines) expect(l.length, r.id).toBeGreaterThan(30);
      expect(r.short.length).toBeLessThan(48);
      expect(ABILITIES[r.rite], r.id).toBeTruthy();
    }
    // The tooltip words are built from the tuning numbers, so they cannot drift from the game.
    expect(RUNES.rune_bone_colossus.lines.join(' ')).toContain(`up to ${RUNE_TUNING.colossus.corpses} of them`);
    expect(RUNES.rune_hollow_choir.cost).toContain('40%');
    expect(RUNES.rune_requiem.lines[0]).toContain('2 s later');
  });
  it('items: type rune, stackable, in the client catalogue and the offline mock', () => {
    for (const id of RUNE_IDS) {
      expect(ITEMS[id], id).toMatchObject({ type: 'rune', stack: 99, rarity: RUNES[id].rarity, sell: RUNES[id].sell });
      expect(MOCK_ITEMS[id]?.item_type, id).toBe('rune');
      expect(RARITY_COLOR[ITEMS[id].rarity]).toBeTruthy();
    }
  });
  it('migration 024 is generated from the content (run node tools/build-runes-sql.mjs if this fails)', () => {
    expect(() => execFileSync('node', ['tools/build-runes-sql.mjs', '--check'], { cwd: root, stdio: 'pipe' })).not.toThrow();
  });
  it('rune ids and fits', () => {
    expect(isRuneId('rune_requiem')).toBe(true);
    expect(isRuneId('rune_nope')).toBe(false);
    expect(runeFits('rune_requiem', 'black_litany')).toBe(true);
    expect(runeFits('rune_requiem', 'miasma')).toBe(false);
    expect(runeFits('sword_copper', 'miasma')).toBe(false);
    expect(runeFits('rune_splinter', 'wailing_skull')).toBe(false);
  });
});

describe('rune sockets (reserved inventory rows)', () => {
  it('five slots 130-134, clear of the kit (120-121), the belt (110-113), gear (100-108) and the bag', () => {
    expect(RUNE_BASE).toBe(130);
    expect(RUNE_SLOT_COUNT).toBe(5);
    expect([129, 130, 134, 135].map(isRuneSlot)).toEqual([false, true, true, false]);
    expect(RUNE_RITES.map(runeSlotIndex)).toEqual([130, 131, 132, 133, 134]);
    expect(runeSlotRite(132)).toBe('exhume');
    expect(runeSlotRite(48)).toBeNull();
    expect(runeEquippedSlot('miasma')).toBe('rune_miasma');
    // equipped_slot names are unique per rite (the live table has UNIQUE (character_id, equipped_slot))
    expect(new Set(RUNE_RITES.map(runeEquippedSlot)).size).toBe(5);
  });
  it('socketsOf reads only legal socket rows; ownedRunes counts only the bag', () => {
    const rows = [
      { slot_index: 130, item_id: 'rune_volley', quantity: 1 },
      { slot_index: 132, item_id: 'rune_bone_colossus', quantity: 1 },
      { slot_index: 133, item_id: 'rune_requiem', quantity: 1 }, // wrong rite for the slot: ignored
      { slot_index: 5, item_id: 'rune_splinter', quantity: 3 },
      { slot_index: 6, item_id: 'rune_splinter', quantity: 2 },
      { slot_index: 120, item_id: 'sword_copper', quantity: 1 },
    ];
    expect(socketsOf(rows)).toEqual({ bone_needle: 'rune_volley', exhume: 'rune_bone_colossus' });
    expect(ownedRunes(rows.map((r) => ({ ...r, equipped: r.slot_index >= 100 ? 1 : 0 })))).toEqual({ rune_splinter: 5 });
    expect(socketsSignature({ exhume: 'rune_mass_grave' })).not.toBe(socketsSignature({}));
  });
  it('a socketed rune is not gear: it never counts as worn equipment or a bag stack', () => {
    const slot = (i: number, id: string, q: number, eq: number) => ({ id: i, slot_index: i, quantity: q, equipped: eq, item_id: id, name: id, rarity: 'rare', item_type: 'rune', stat_bonus: {}, icon_id: null, sell_value: 60, crafted: 0 }) as unknown as InventorySlot;
    const bag = [slot(0, 'rune_volley', 2, 0), slot(130, 'rune_volley', 1, 1)];
    const next = addToSlots(bag, { item_id: 'rune_volley', quantity: 1 })!;
    expect(next.find((s) => s.slot_index === 0)!.quantity).toBe(3);
    expect(next.find((s) => s.slot_index === 130)!.quantity).toBe(1);
    // a full-stack bag slot overflows into a new slot, never into the socket
    const full = [slot(0, 'rune_volley', 99, 0), slot(130, 'rune_volley', 1, 1)];
    const over = addToSlots(full, { item_id: 'rune_volley', quantity: 1 })!;
    expect(over.filter((s) => s.item_id === 'rune_volley' && s.slot_index < 48).map((s) => s.quantity).sort()).toEqual([1, 99]);
  });
});

// --- drops, salvage, authority -------------------------------------------------------------------------------------

describe('where runes drop', () => {
  it('the first grounds shed uncommon runes only, rares start in the Ossuary, epics in the Sanctum; safe grounds shed none', () => {
    expect(AREA_RUNE_POOL.graves!.every((r) => RUNES[r].rarity === 'uncommon')).toBe(true);
    expect(AREA_RUNE_POOL.ossuary!.some((r) => RUNES[r].rarity === 'rare')).toBe(true);
    expect(AREA_RUNE_POOL.ossuary!.some((r) => RUNES[r].rarity === 'epic')).toBe(false);
    expect(AREA_RUNE_POOL.nave!.some((r) => RUNES[r].rarity === 'epic')).toBe(false);
    expect(AREA_RUNE_POOL.sanctum!.some((r) => RUNES[r].rarity === 'epic')).toBe(true);
    for (const a of AREA_ORDER) if (AREAS[a].safe) expect(AREA_RUNE_POOL[a], a).toBeUndefined();
    // every rune can be found somewhere ordinary play goes
    const everywhere = new Set(Object.values(AREA_RUNE_POOL).flat());
    for (const id of RUNE_IDS) expect(everywhere.has(id), id).toBe(true);
  });
  it('an elite sheds a rune about once in 1/eliteRuneChance(area) elite kills, a plain kill never', () => {
    const r = mulberry32(7);
    let drops = 0;
    for (let i = 0; i < 20000; i++) if (rollEliteRune('sanctum', 1, r)) drops++;
    expect(drops / 20000).toBeGreaterThan(eliteRuneChance('sanctum') * 0.7);
    expect(drops / 20000).toBeLessThan(eliteRuneChance('sanctum') * 1.3);
    expect(rollEliteRune('chapterhouse', 1000, r)).toBeNull();
    const plain = mulberry32(3);
    for (let i = 0; i < 3000; i++) expect(rollKill('robber', 'graves', 1, false, 0, plain).items.some((d) => isRuneId(d.item_id))).toBe(false);
    // an elite's kill carries it through the real reward roll (on its own stream, so the seeded harness keeps every other roll)
    const found = Array.from({ length: 4000 }, (_, i) => rollKill('robber', 'ossuary', 5, true, 0, mulberry32(i), 'medium', 1, Math.random, mulberry32(i + 9))).filter((k) => k.items.some((d) => isRuneId(d.item_id)));
    expect(found.length).toBeGreaterThan(5);
  });
  it('the runes of a given elite roll follow the weighted pool (epics rarer)', () => {
    const r = mulberry32(11);
    const counts: Record<string, number> = {};
    for (let i = 0; i < 20000; i++) {
      const id = pickRune(AREA_RUNE_POOL.sanctum!, r)!;
      counts[RUNES[id].rarity] = (counts[RUNES[id].rarity] ?? 0) + 1;
    }
    expect(counts.uncommon).toBeGreaterThan(counts.rare);
    expect(counts.rare / 3).toBeGreaterThan(counts.epic / 2);
    expect(pickRune([], r)).toBeNull();
  });
  it('a Grave Surge swaps its offering for a rune a quarter of the time', () => {
    const r = mulberry32(5);
    let runes = 0;
    for (let i = 0; i < 4000; i++) if (isRuneId(rollSurgeItem('ossuary', r).item_id)) runes++;
    expect(runes / 4000).toBeGreaterThan(SURGE_RUNE_CHANCE * 0.8);
    expect(runes / 4000).toBeLessThan(SURGE_RUNE_CHANCE * 1.2);
    // ...and still gives an ordinary item otherwise
    expect(rollSurgeItem('graves', () => 0.9).item_id).toBeTruthy();
  });
  it('the Prelate and a first kill always leave a rune from that boss pool; repeats roll about half', () => {
    for (const boss of BOSS_IDS) {
      const pool = BOSS_RUNE_POOL[boss];
      expect(pool?.length, boss).toBeGreaterThan(0);
      for (let i = 0; i < 20; i++) expect(pool).toContain(rollBossRune(boss, true, mulberry32(i))!.item_id);
    }
    for (let i = 0; i < 20; i++) expect(rollBossRune('prelate', false, mulberry32(i))).not.toBeNull();
    const r = mulberry32(2);
    let n = 0;
    for (let i = 0; i < 3000; i++) if (rollBossRune('abbess', false, r)) n++;
    expect(n / 3000).toBeGreaterThan(0.45);
    expect(n / 3000).toBeLessThan(0.55);
    expect(BOSS_RUNE_POOL.abbess).toContain('rune_bone_colossus');
  });
  it('every rune can be sourced in words for the Codex', () => {
    for (const id of RUNE_IDS) expect(runeSources(id).length, id).toBeGreaterThan(10);
    expect(runeSources('rune_bone_colossus')).toMatch(/Bone Abbess/);
    expect(runeSources('rune_splinter')).toMatch(/any hunting ground/);
    // The Catacomb Depths' chests hold runes too (epic ones from depth 10).
    expect(runeSources('rune_splinter')).toMatch(/chests in the Catacomb Depths$/);
    expect(runeSources('rune_requiem')).toMatch(/chests in the Catacomb Depths \(from depth 10\)$/);
  });
});

describe('runes in the bag: salvage, Vault and the authority guard', () => {
  it('can be ground to reagents only, one at a time; gear rules are unchanged', () => {
    expect(isSalvageable('rune')).toBe(true);
    expect(isSalvageGear('rune')).toBe(false);
    const p = salvagePreview({ id: 'rune_requiem', item_type: 'rune', rarity: 'epic' });
    expect(p.materials).toEqual([]);
    expect(p.reagents[0].id).toBe('reagent_grave_dust');
    for (let i = 0; i < 50; i++) {
      const y = salvageYield({ id: 'rune_volley', item_type: 'rune', rarity: 'rare' }, 10, mulberry32(i));
      expect(y.items.some((g) => g.item_id === 'reagent_grave_dust' && g.quantity >= 2)).toBe(true);
      expect(y.items.every((g) => /^(reagent_|bone_meal)/.test(g.item_id)), JSON.stringify(y.items)).toBe(true);
      expect(y.xp).toBeGreaterThan(0);
    }
    // gear still yields an ingot or plank
    expect(salvageYield({ id: 'helm_iron', item_type: 'armor_head', rarity: 'rare' }, 1, mulberry32(1)).items.some((g) => /^(ingot|plank)_/.test(g.item_id))).toBe(true);
  });
  it('the Vault treats runes as stackable material-like items (Deposit materials takes them)', () => {
    const info = (id: string) => ({ maxStack: id.startsWith('rune_') ? 99 : 1, itemType: id.startsWith('rune_') ? 'rune' : 'weapon', rarity: 'rare' });
    const r = depositMany([{ slot: 0, itemId: 'rune_volley', qty: 4 }, { slot: 1, itemId: 'sword_copper', qty: 1 }], [], 'materials', [], info);
    expect(r.ok).toBe(true);
    if (r.ok) {
      expect(r.vault.map((v) => v.itemId)).toEqual(['rune_volley']);
      expect(r.vault[0].qty).toBe(4);
      expect(r.bag.map((v) => v.itemId)).toEqual(['sword_copper']);
    }
  });
  it('the authority guard allows runes from the ground at a modest rate (a client save cannot conjure hundreds)', () => {
    for (const id of RUNE_IDS) {
      expect(itemRatePerMin(id), id).toBeGreaterThan(0);
      expect(itemCap(id), id).toBeGreaterThan(3);
      expect(itemCap(id), id).toBeLessThan(400);
    }
  });
});

// --- the host: Mass Grave, Bone Colossus, Impale, Creeping Rot, Contagion, Hollow Choir, Requiem -----------------------

function world(seed = 1) {
  const nav = new Nav();
  const sim = new WorldSim(nav, mulberry32(seed));
  sim.setPlayer({ id: 'p1', x: 0, z: -16, alive: true, area: 'graves' });
  return { nav, sim };
}
function corpse(sim: WorldSim, x: number, z: number, kind: Corpse['kind'] = 'normal', elite = false): Corpse {
  const enemy = kind === 'resonant' ? 'penitent' : kind === 'toxic' ? 'sac' : 'robber';
  sim.addCorpse(x, z, kind, enemy, elite, 0, 1, 'graves');
  return [...sim.corpses.values()].find((c) => c.x === x && c.z === z)!;
}
const of = <T extends SimEvent['t']>(ev: SimEvent[], t: T) => ev.filter((e): e is Extract<SimEvent, { t: T }> => e.t === t);
const exhume = (x: number, z: number, over: Partial<Extract<Intent, { t: 'exhume' }>> = {}): Intent => ({ t: 'exhume', by: 'p1', x, z, r: 0.8, kind: 'warrior', cap: 5, hp: 100, damage: 10, attackSpeedMult: 1, ...over });
const mine = (sim: WorldSim) => [...sim.thralls.values()].filter((t) => t.owner === 'p1');
/** Keep the world quiet: no wave walks into the test. */
const quiet = (sim: WorldSim) => sim.setPlayer({ id: 'p1', x: 0, z: -16, alive: true, area: null });

describe('Mass Grave (host)', () => {
  it('raises up to three corpses at once, each at 60% health and damage', () => {
    const { sim } = world();
    quiet(sim);
    corpse(sim, 0, -20);
    corpse(sim, 1, -20);
    corpse(sim, 2, -20);
    corpse(sim, 3, -20);
    sim.drain();
    sim.apply(exhume(0, -20, { r: 4, count: 3 }));
    const t = mine(sim);
    expect(t).toHaveLength(3);
    for (const th of t) {
      expect(th.maxHp).toBeCloseTo(100 * RUNE_TUNING.massGrave.statMult, 6);
      expect(th.damage).toBeCloseTo(10 * RUNE_TUNING.massGrave.statMult, 6);
    }
    expect(sim.corpses.size).toBe(1);
    expect(of(sim.drain(), 'exhumed').filter((e) => e.ok)).toHaveLength(3);
  });
  it('a lone corpse is raised at full strength, and the count is clamped to three', () => {
    const { sim } = world();
    quiet(sim);
    corpse(sim, 0, -20);
    sim.apply(exhume(0, -20, { r: 4, count: 3 }));
    expect(mine(sim)[0].maxHp).toBe(100);
    for (let i = 0; i < 6; i++) corpse(sim, i * 0.5, -22);
    sim.apply(exhume(0, -22, { r: 4, count: 99, cap: 9 }));
    expect(mine(sim).length).toBe(1 + 3);
  });
  it('without the count it is the plain Exhume (one corpse, full strength)', () => {
    const { sim } = world();
    quiet(sim);
    corpse(sim, 0, -20);
    corpse(sim, 1, -20);
    sim.apply(exhume(0, -20, { r: 4 }));
    expect(mine(sim)).toHaveLength(1);
    expect(mine(sim)[0].maxHp).toBe(100);
  });
  it('an empty field refunds the caster (exhumed ok:false)', () => {
    const { sim } = world();
    quiet(sim);
    sim.apply(exhume(0, -20, { r: 4, count: 3 }));
    expect(of(sim.drain(), 'exhumed')[0].ok).toBe(false);
  });
});

describe('Bone Colossus (host)', () => {
  const T = RUNE_TUNING.colossus;
  const fiveCorpses = (sim: WorldSim, x = 0, z = -20) => Array.from({ length: 5 }, (_, i) => corpse(sim, x + i * 0.6, z));

  it('consumes five corpses and raises one giant thrall: 4x health, 3.5x damage, wide reach, two legion places', () => {
    const { sim } = world();
    quiet(sim);
    fiveCorpses(sim);
    corpse(sim, 0, -26); // out of reach: stays
    sim.drain();
    sim.apply(exhume(1, -20, { r: T.pickRadius, colossus: true }));
    const t = mine(sim);
    expect(t).toHaveLength(1);
    expect(t[0].kind).toBe('colossus');
    expect(t[0].maxHp).toBeCloseTo(100 * T.hpPerCorpse * 5, 6);
    expect(t[0].maxHp).toBeCloseTo(400, 6);
    expect(t[0].damage).toBeCloseTo(10 * T.damagePerCorpse * 5, 6);
    expect(t[0].damage).toBeCloseTo(35, 6);
    expect(t[0].range).toBe(T.range);
    expect(thrallWeight('colossus')).toBe(T.slots);
    expect(thrallWeight('warrior')).toBe(1);
    expect(sim.corpses.size).toBe(1);
    const ev = sim.drain();
    expect(of(ev, 'thrall')[0]).toMatchObject({ kind: 'colossus', owner: 'p1' });
    expect(of(ev, 'corpseGone')).toHaveLength(5);
    expect(of(ev, 'exhumed')[0].ok).toBe(true);
  });
  it('three corpses is the least: fewer refuses with a reason and spends none', () => {
    const { sim } = world();
    quiet(sim);
    corpse(sim, 0, -20);
    corpse(sim, 1, -20);
    sim.drain();
    sim.apply(exhume(0, -20, { r: T.pickRadius, colossus: true }));
    const ev = sim.drain();
    expect(of(ev, 'exhumed')[0]).toMatchObject({ ok: false, why: 'few' });
    expect(mine(sim)).toHaveLength(0);
    expect(sim.corpses.size).toBe(2);
    corpse(sim, 2, -20);
    sim.apply(exhume(0, -20, { r: T.pickRadius, colossus: true }));
    const t = mine(sim)[0];
    expect(t.maxHp).toBeCloseTo(100 * T.hpPerCorpse * 3, 6);
    expect(t.damage).toBeCloseTo(10 * T.damagePerCorpse * 3, 6);
  });
  it('a player keeps only one: a second colossus replaces the first', () => {
    const { sim } = world();
    quiet(sim);
    fiveCorpses(sim);
    sim.apply(exhume(1, -20, { r: T.pickRadius, colossus: true, cap: 5 }));
    const first = mine(sim)[0];
    fiveCorpses(sim, 0, -24);
    sim.drain();
    sim.apply(exhume(1, -24, { r: T.pickRadius, colossus: true, cap: 5 }));
    const t = mine(sim);
    expect(t).toHaveLength(1);
    expect(t[0].id).not.toBe(first.id);
    expect(of(sim.drain(), 'thrallGone').some((e) => e.id === first.id)).toBe(true);
  });
  it('fills two places of the cap: ordinary thralls crumble first, the colossus last', () => {
    const { sim } = world();
    quiet(sim);
    for (let i = 0; i < 3; i++) corpse(sim, i, -30);
    for (let i = 0; i < 3; i++) sim.apply(exhume(i, -30, { cap: 3 }));
    expect(mine(sim)).toHaveLength(3);
    fiveCorpses(sim);
    sim.apply(exhume(1, -20, { r: T.pickRadius, colossus: true, cap: 3 }));
    // cap 3: the colossus (2) leaves room for one ordinary thrall
    expect(mine(sim).map((t) => t.kind).sort()).toEqual(['colossus', 'warrior']);
    // more ordinary raises replace the ordinary one, never the colossus
    for (let i = 0; i < 3; i++) corpse(sim, i, -34);
    for (let i = 0; i < 3; i++) sim.apply(exhume(i, -34, { cap: 3 }));
    const after = mine(sim);
    expect(after.filter((t) => t.kind === 'colossus')).toHaveLength(1);
    expect(after.reduce((n, t) => n + thrallWeight(t.kind), 0)).toBeLessThanOrEqual(3);
  });
  it('every blow cleaves what stands around its target', () => {
    const { sim } = world();
    fiveCorpses(sim);
    sim.apply(exhume(1, -20, { r: T.pickRadius, colossus: true }));
    const c = mine(sim)[0];
    c.state = 'idle';
    c.stateT = 5;
    c.x = 0; c.z = -17.5;
    const main = sim.spawnEnemy('robber', 'graves', 0, -16.6, false);
    const side = sim.spawnEnemy('robber', 'graves', 1.5, -16.6, false);
    const far = sim.spawnEnemy('robber', 'graves', 9, -16.6, false);
    for (const e of [main, side, far]) { e.state = 'move'; e.speed = 0; }
    const hp = [main.hp, side.hp, far.hp];
    c.target = main.id; c.attackCd = 0;
    for (let i = 0; i < 60 && side.hp === hp[1]; i++) sim.step(0.05);
    expect(main.hp).toBeLessThan(hp[0]);
    expect(side.hp).toBeLessThan(hp[1]);
    expect(far.hp).toBe(hp[2]);
    const lostMain = hp[0] - main.hp;
    const lostSide = hp[1] - side.hp;
    expect(lostSide / lostMain).toBeGreaterThan(T.cleaveFrac * 0.5);
    expect(lostSide).toBeLessThan(lostMain);
  });
});

describe('Impale and Creeping Rot (host)', () => {
  it('roots for the length asked, clamped to 1.5 s', () => {
    const { sim } = world();
    const a = sim.spawnEnemy('robber', 'graves', 2, -16, false);
    const b = sim.spawnEnemy('robber', 'graves', 4, -16, false);
    sim.apply({ t: 'hit', by: 'p1', ids: [a.id], dmg: 1, root: true, rootS: 1.5 });
    sim.apply({ t: 'hit', by: 'p1', ids: [b.id], dmg: 1, root: true, rootS: 99 });
    expect(a.rootT).toBe(RUNE_TUNING.impale.rootS);
    expect(b.rootT).toBe(RUNE_TUNING.impale.rootS);
  });
  it('a plain root claim (Bone Prison) still uses the host duration', () => {
    const { sim } = world();
    const a = sim.spawnEnemy('robber', 'graves', 2, -16, false);
    sim.apply({ t: 'hit', by: 'p1', ids: [a.id], dmg: 1, root: true });
    expect(a.rootT).toBeGreaterThan(1.5);
  });
  const miasma = (over: Record<string, unknown> = {}): Intent => ({ t: 'miasma', by: 'p1', x: 0, z: -20, r: 3, dps: 5, durationMs: 6000, witheredCap: 5, bloom: false, ...over }) as Intent;

  it('a creeping circle drifts toward the nearest enemy at the host-clamped speed and stops on it', () => {
    const { sim } = world();
    quiet(sim);
    const e = sim.spawnEnemy('robber', 'graves', 8, -20, false);
    e.state = 'move'; e.speed = 0;
    sim.apply(miasma({ creep: 99 }));
    const z = [...sim.zones.values()][0];
    expect(z.creep).toBe(RUNE_TUNING.creepingRot.speed);
    for (let i = 0; i < 20; i++) sim.step(0.05); // one second
    expect(z.x).toBeGreaterThan(1.2);
    expect(z.x).toBeLessThan(1.8);
    for (let i = 0; i < 100; i++) sim.step(0.05);
    expect(Math.hypot(e.x - z.x, e.z - z.z)).toBeLessThan(1);
  });
  it('a plain circle stays where it fell, and a far enemy does not pull it', () => {
    const { sim } = world();
    quiet(sim);
    const e = sim.spawnEnemy('robber', 'graves', 30, -20, false);
    e.state = 'move'; e.speed = 0;
    sim.apply(miasma());
    sim.apply(miasma({ creep: 1.5, x: -10 }));
    for (let i = 0; i < 40; i++) sim.step(0.05);
    const [plain, creeper] = [...sim.zones.values()];
    expect(plain.x).toBe(0);
    expect(creeper.x).toBe(-10);
  });
  it('a creeping circle\'s position rides every snapshot to the guests', () => {
    const { sim } = world();
    quiet(sim);
    const e = sim.spawnEnemy('robber', 'graves', 8, -20, false);
    e.state = 'move'; e.speed = 0;
    sim.apply(miasma({ creep: 1.5 }));
    const mirror = new WorldMirror();
    mirror.applySnapshot(makeSnapshot(sim, true));
    for (let i = 0; i < 20; i++) sim.step(0.05);
    const snap = makeSnapshot(sim, false);
    expect(snap.zones).toBeUndefined();
    expect(snap.zpos).toHaveLength(1);
    mirror.applySnapshot(snap);
    expect(mirror.zones.get([...sim.zones.keys()][0])!.x).toBeCloseTo([...sim.zones.values()][0].x, 1);
    // no creeping circle, no extra field
    const plain = world();
    plain.sim.apply(miasma());
    expect(makeSnapshot(plain.sim, false).zpos).toBeUndefined();
  });
});

describe('Contagion (host)', () => {
  it('a Contagion circle marks what it withers; the dead pass their stacks (minus one) to the two nearest', () => {
    const { sim } = world();
    quiet(sim);
    const a = sim.spawnEnemy('robber', 'graves', 0, -20, false);
    const b = sim.spawnEnemy('robber', 'graves', 2, -20, false);
    const c = sim.spawnEnemy('robber', 'graves', -2, -20, false);
    const d = sim.spawnEnemy('robber', 'graves', 0, -26, false); // too far to catch it
    for (const e of [a, b, c, d]) { e.state = 'move'; e.speed = 0; }
    sim.apply({ t: 'miasma', by: 'p1', x: 0, z: -20, r: 0.6, dps: 0, durationMs: 6000, witheredCap: 5, bloom: false, contagion: true });
    for (let i = 0; i < 80; i++) sim.step(0.05);
    expect(a.contagious).toBe(true);
    expect(b.contagious).toBeFalsy();
    sim.zones.clear(); // so no pulse adds a stack during the death step
    a.withered = 4;
    a.witheredT = 5;
    a.hp = 0;
    sim.drain();
    sim.step(0.05);
    expect(b.withered).toBe(3);
    expect(c.withered).toBe(3);
    expect(d.withered).toBe(0);
    expect(b.contagious).toBe(true);
  });
  it('emits an arc per neighbour, stops at one stack, and an ordinary Miasma never spreads', () => {
    const { sim } = world();
    quiet(sim);
    const a = sim.spawnEnemy('robber', 'graves', 0, -20, false);
    const b = sim.spawnEnemy('robber', 'graves', 2, -20, false);
    for (const e of [a, b]) { e.state = 'move'; e.speed = 0; }
    a.contagious = true; a.withered = 2; a.witheredT = 5; a.hp = 0;
    sim.drain();
    expect(of(sim.step(0.05), 'contagion')).toHaveLength(1);
    expect(b.withered).toBe(1);
    // one stack cannot jump
    const c = sim.spawnEnemy('robber', 'graves', 4, -20, false);
    c.contagious = true; c.withered = 1; c.witheredT = 5; c.hp = 0;
    expect(of(sim.step(0.05), 'contagion')).toHaveLength(0);
    // not marked: no spread
    const d = sim.spawnEnemy('robber', 'graves', 6, -20, false);
    const e2 = sim.spawnEnemy('robber', 'graves', 7, -20, false);
    d.withered = 5; d.witheredT = 5; d.hp = 0;
    sim.step(0.05);
    expect(e2.withered).toBe(0);
  });
});

describe('Hollow Choir and Requiem (host)', () => {
  const litany = (over: Record<string, unknown> = {}): Intent => ({ t: 'litany', by: 'p1', x: 0, z: -20, r: 7, spellPower: 100, leaveCorpses: false, ...over }) as Intent;
  const stage = (sim: WorldSim) => {
    quiet(sim);
    for (let i = 0; i < 3; i++) corpse(sim, i - 1, -20);
    for (let i = 0; i < 2; i++) { corpse(sim, i - 1, -21); sim.apply(exhume(i - 1, -21, { r: 0.4 })); }
    const foe = sim.spawnEnemy('robber', 'graves', 3, -20, false);
    foe.state = 'move'; foe.speed = 0;
    sim.drain();
    return foe;
  };
  it('plain Black Litany sacrifices the thralls in range', () => {
    const { sim } = world();
    stage(sim);
    expect(mine(sim)).toHaveLength(2);
    sim.apply(litany());
    expect(mine(sim)).toHaveLength(0);
    expect(of(sim.drain(), 'litanyResult')[0]).toMatchObject({ thralls: 2, corpses: 3 });
  });
  it('Hollow Choir spares them, still counts their voices, and says so', () => {
    const { sim } = world();
    const foe = stage(sim);
    const hp = foe.hp;
    sim.apply(litany({ spare: true, spellPower: 100 * RUNE_TUNING.hollowChoir.powerMult }));
    expect(mine(sim)).toHaveLength(2);
    const ev = of(sim.drain(), 'litanyResult')[0];
    expect(ev).toMatchObject({ thralls: 0, spared: 2, corpses: 3 });
    // 100 * 0.6 * (1.5 + 3 * 0.6 + 2 * 1.4) damage reached the foe (the thralls' voices count)
    const lost = hp - foe.hp;
    expect(lost).toBeGreaterThan(100 * 0.6 * 1.5);
  });
  it('Hollow Choir deals less than the plain rite on the same field, and the thralls survive for the next', () => {
    const a = world();
    const fa = stage(a.sim);
    const b = world();
    const fb = stage(b.sim);
    a.sim.apply(litany());
    b.sim.apply(litany({ spare: true, spellPower: 100 * RUNE_TUNING.hollowChoir.powerMult }));
    expect(fb.maxHp - fb.hp).toBeLessThan(fa.maxHp - fa.hp);
    expect(mine(b.sim)).toHaveLength(2);
  });
  it('Requiem marks the ground, waits 2 s, then bursts over the wide circle and takes what is there THEN', () => {
    const { sim } = world();
    const foe = stage(sim);
    foe.x = 9; // inside the doubled radius, outside the plain one
    const hp = foe.hp;
    sim.apply(litany({ r: 14, delayMs: 2000 }));
    const mark = of(sim.drain(), 'requiem');
    expect(mark).toHaveLength(1);
    expect(mark[0]).toMatchObject({ x: 0, z: -20, r: 14, ms: 2000 });
    expect(sim.corpses.size).toBe(3);
    expect(mine(sim)).toHaveLength(2);
    expect(foe.hp).toBe(hp);
    // a fresh corpse laid during the wait is eaten by the burst
    for (let i = 0; i < 20; i++) sim.step(0.05);
    expect(foe.hp).toBe(hp);
    corpse(sim, 0, -23);
    let result: Extract<SimEvent, { t: 'litanyResult' }> | undefined;
    for (let i = 0; i < 40 && !result; i++) result = of(sim.step(0.05), 'litanyResult')[0];
    expect(result).toBeTruthy();
    expect(result!.corpses).toBe(4);
    expect(result!.thralls).toBe(2);
    expect(foe.hp).toBeLessThan(hp);
    expect(mine(sim)).toHaveLength(0);
    // it fires once
    expect(of(sim.step(0.05), 'litanyResult')).toHaveLength(0);
  });
  it('the delay is clamped by the host to 2 s', () => {
    const { sim } = world();
    stage(sim);
    sim.apply(litany({ delayMs: 60000 }));
    expect(of(sim.drain(), 'requiem')[0].ms).toBe(RUNE_TUNING.requiem.delayMs);
  });
});

// --- the caster: Bone Needle, Marrow Spear, Exhume, Miasma, Litany intents --------------------------------------------------

function client(runes: Partial<Record<RuneRite, RuneId>> = {}, overrides: Partial<AbilityContext> = {}) {
  const p = new Player({ level: 12, maxHp: 100, spellPower: 20, maxEssence: 150, essenceRegen: 5, moveSpeed: 5.4, thrallHp: 45, thrallDamage: 8, damageBonusPct: 0 }, new Nav());
  p.area = 'graves'; // the corpses these tests lay are in the Hollow Graves: the rites only reach the hall you stand in
  p.essence = 100;
  p.runes = runes;
  const effects = new Effects(new THREE.Scene());
  const enemies = new Map<number, Enemy>();
  const corpses = new Map<number, Corpse>();
  const send = vi.fn();
  const note = vi.fn();
  let clock = 1000;
  let boss = { active: false } as { active: boolean; x?: number; z?: number };
  const ctx = {
    selfId: 'solo', player: p, discipline: DISCIPLINES.gravecaller, avatar: { tip: () => new THREE.Vector3(0, 1.4, 0), cast: vi.fn() }, effects,
    enemies: () => enemies, boss: () => boss, corpses: () => corpses,
    thrallCount: () => 0, send, number: vi.fn(), shake: vi.fn(), note, now: () => clock,
    ...overrides,
  } as unknown as AbilityContext;
  const abilities = new AbilitySystem(ctx);
  const camera = new THREE.PerspectiveCamera();
  const step = (seconds: number) => {
    for (let i = 0; i < Math.ceil(seconds / 0.01); i++) {
      clock += 10;
      effects.update(0.01, camera, 720);
      abilities.update(clock);
    }
  };
  return { p, enemies, corpses, send, note, abilities, step, setBoss: (b: typeof boss) => (boss = b), clock: () => clock };
}
const foe = (id: number, x: number, z: number): Enemy => ({ id, x, z, state: 'move', radius: 0.4 }) as Enemy;
const body = (id: number, x: number, z: number): Corpse => ({ id, x, z, kind: 'normal', enemy: 'robber', elite: false, facing: 0, scale: 1, area: 'graves', bornAt: 0, expiresAt: 1e9, ruptureAt: 1e9 }) as Corpse;
const sent = (send: ReturnType<typeof vi.fn>) => send.mock.calls.map((c) => c[0] as Intent);

describe('Bone Needle runes (cast)', () => {
  it('no rune: one needle, 6 essence', () => {
    const { p, enemies, send, abilities, step } = client();
    enemies.set(1, foe(1, 0, 6));
    enemies.set(2, foe(2, 3, 6));
    const before = p.essence;
    expect(abilities.cast('bone_needle', { x: 0, z: 6, enemyId: 1 }, 1000)).toBe('ok');
    step(1);
    expect(sent(send)).toHaveLength(1);
    expect(p.essence - before).toBe(6);
  });
  it('Splinters: a shard flies to the nearest other enemy for half the damage', () => {
    vi.spyOn(Math, 'random').mockReturnValue(0.5); // no crit, no damage spread: the ratios are exact
    const base = client();
    base.enemies.set(1, foe(1, 0, 6));
    base.abilities.cast('bone_needle', { x: 0, z: 6, enemyId: 1 }, 1000);
    base.step(1);
    const plain = (sent(base.send)[0] as Extract<Intent, { t: 'hit' }>).dmg;

    const { enemies, send, abilities, step } = client({ bone_needle: 'rune_splinter' });
    enemies.set(1, foe(1, 0, 6));
    enemies.set(2, foe(2, 2, 6));
    enemies.set(3, foe(3, 4, 6));
    enemies.set(4, foe(4, 20, 6)); // out of the splinter's reach
    abilities.cast('bone_needle', { x: 0, z: 6, enemyId: 1 }, 1000);
    step(1);
    const hits = sent(send) as Extract<Intent, { t: 'hit' }>[];
    expect(hits).toHaveLength(2);
    expect(hits[0].ids).toEqual([1]);
    expect(hits[1].ids).toEqual([2]);
    expect(hits[1].dmg / hits[0].dmg).toBeCloseTo(RUNE_TUNING.splinter.damageFrac, 6);
    expect(hits[0].dmg).toBeGreaterThan(plain * 0.8);
  });
  it('Splinters with nothing else near does nothing extra', () => {
    const { enemies, send, abilities, step } = client({ bone_needle: 'rune_splinter' });
    enemies.set(1, foe(1, 0, 6));
    enemies.set(2, foe(2, 30, 6));
    abilities.cast('bone_needle', { x: 0, z: 6, enemyId: 1 }, 1000);
    step(1);
    expect(sent(send)).toHaveLength(1);
  });
  it('Marrow-Tap: 4 more essence a hit, 30% less damage', () => {
    vi.spyOn(Math, 'random').mockReturnValue(0.5); // no crit, no damage spread: the ratios are exact
    const base = client();
    base.enemies.set(1, foe(1, 0, 6));
    const e0 = base.p.essence;
    base.abilities.cast('bone_needle', { x: 0, z: 6, enemyId: 1 }, 1000);
    base.step(1);
    const baseHit = (sent(base.send)[0] as Extract<Intent, { t: 'hit' }>).dmg;
    const { p, enemies, send, abilities, step } = client({ bone_needle: 'rune_marrow_tap' });
    enemies.set(1, foe(1, 0, 6));
    const before = p.essence;
    abilities.cast('bone_needle', { x: 0, z: 6, enemyId: 1 }, 1000);
    step(1);
    expect(p.essence - before).toBe(6 + RUNE_TUNING.marrowTap.essenceBonus);
    expect(base.p.essence - e0).toBe(6);
    const hit = (sent(send)[0] as Extract<Intent, { t: 'hit' }>).dmg;
    expect(hit / baseHit).toBeGreaterThan(RUNE_TUNING.marrowTap.damageMult * 0.75);
    expect(hit / baseHit).toBeLessThan(RUNE_TUNING.marrowTap.damageMult * 1.25);
  });
  it('Volley: every 4th needle is three needles at three different enemies, each at half damage', () => {
    const { p, enemies, send, abilities, step, clock } = client({ bone_needle: 'rune_volley' });
    enemies.set(1, foe(1, 0, 6));
    enemies.set(2, foe(2, 1.5, 6));
    enemies.set(3, foe(3, -1.5, 6));
    enemies.set(4, foe(4, 30, 6)); // beyond the volley's reach
    const counts: number[] = [];
    for (let i = 0; i < 4; i++) {
      send.mockClear();
      p.cooldowns.clear();
      p.castUntil = 0;
      expect(abilities.cast('bone_needle', { x: 0, z: 6, enemyId: 1 }, clock() + 1000 * (i + 1))).toBe('ok');
      step(1);
      counts.push(sent(send).length);
      if (i < 3) expect(sent(send)).toHaveLength(1);
    }
    expect(counts).toEqual([1, 1, 1, 3]);
    const volley = sent(send) as Extract<Intent, { t: 'hit' }>[];
    expect(volley.map((h) => h.ids[0]).sort()).toEqual([1, 2, 3]);
    expect(volley[0].dmg).toBeLessThan(20); // a plain needle here is about 20 (spell power 20), a volley needle half of that (a crit counts 1.8x)
  });
  it('Volley with a lone enemy sends all three needles at it', () => {
    const { p, enemies, send, abilities, step, clock } = client({ bone_needle: 'rune_volley' });
    enemies.set(1, foe(1, 0, 6));
    for (let i = 0; i < 4; i++) {
      send.mockClear();
      p.cooldowns.clear();
      p.castUntil = 0;
      abilities.cast('bone_needle', { x: 0, z: 6, enemyId: 1 }, clock() + 1000 * (i + 1));
      step(1);
    }
    expect(sent(send).map((h) => (h as Extract<Intent, { t: 'hit' }>).ids[0])).toEqual([1, 1, 1]);
  });
  it('a rune in the wrong rite (or a different primary) changes nothing', () => {
    const { enemies, send, abilities, step } = client({ marrow_spear: 'rune_impale' });
    enemies.set(1, foe(1, 0, 6));
    enemies.set(2, foe(2, 2, 6));
    abilities.cast('bone_needle', { x: 0, z: 6, enemyId: 1 }, 1000);
    step(1);
    expect(sent(send)).toHaveLength(1);
  });
  it('geometry helpers: nearest other, volley order, ring and impale', () => {
    const f = (id: number, x: number, z: number) => ({ id, x, z, radius: 0.4 });
    expect(splinterTarget(f(1, 0, 0), [f(1, 0, 0), f(2, 3, 0), f(3, 1, 0)])!.id).toBe(3);
    expect(splinterTarget(f(1, 0, 0), [f(1, 0, 0), f(2, 30, 0)])).toBeNull();
    expect(volleyTargets({ x: 0, z: -5 }, f(1, 0, 0), [f(1, 0, 0), f(2, 1, 0), f(3, 2, 0), f(4, 3, 0)]).map((e) => e.id)).toEqual([1, 2, 3]);
    expect(ringHits({ x: 0, z: 0 }, 3, [f(1, 2, 0), f(2, 3.3, 0), f(3, 4, 0)]).map((e) => e.id)).toEqual([1, 2]);
    expect(ringCenter({ x: 0, z: 0 }, { x: 0, z: 30 }, 12)).toEqual({ x: 0, z: 12 });
    expect(ringCenter({ x: 0, z: 0 }, { x: 0, z: 5 }, 12)).toEqual({ x: 0, z: 5 });
    expect(impaleTarget({ x: 0, z: 0 }, 0, 1, 12, 1, [f(1, 0, 8), f(2, 0.3, 4), f(3, 5, 3)])!.foe.id).toBe(2);
    expect(impaleTarget({ x: 0, z: 0 }, 0, 1, 12, 1, [f(1, 0, -4)])).toBeNull();
    expect(corpsesWithin({ x: 0, z: 0 }, 3, [{ x: 1, z: 0 }, { x: 5, z: 0 }, { x: 2, z: 0, echoOwner: 'x' }]).length).toBe(1);
  });
});

describe('Marrow Spear runes (cast)', () => {
  it('no rune: a line piercing everything on it', () => {
    const { enemies, send, abilities, step } = client();
    enemies.set(1, foe(1, 0, 4));
    enemies.set(2, foe(2, 0, 9));
    enemies.set(3, foe(3, 6, 4));
    expect(abilities.cast('marrow_spear', { x: 0, z: 10 }, 1000)).toBe('ok');
    step(1);
    expect((sent(send)[0] as Extract<Intent, { t: 'hit' }>).ids.sort()).toEqual([1, 2]);
  });
  it('Ossuary Ring: everything within 3.2 m of the cursor, nothing along the line to it', () => {
    const { enemies, send, abilities, step } = client({ marrow_spear: 'rune_ossuary_ring' });
    enemies.set(1, foe(1, 0, 3)); // on the line, nowhere near the ring
    enemies.set(2, foe(2, 0.5, 10));
    enemies.set(3, foe(3, 4, 10));
    enemies.set(4, foe(4, -2.5, 11));
    enemies.set(5, foe(5, 9, 10));
    expect(abilities.cast('marrow_spear', { x: 0, z: 10 }, 1000)).toBe('ok');
    step(1);
    const h = sent(send)[0] as Extract<Intent, { t: 'hit' }>;
    expect(h.ids.sort()).toEqual([2, 4]);
    expect(h.fracture).toBe(1);
    expect(h.bleed).toBeGreaterThan(0);
  });
  it('Ossuary Ring lands at the spear\'s reach when the cursor is farther', () => {
    const { enemies, send, abilities, step } = client({ marrow_spear: 'rune_ossuary_ring' });
    enemies.set(1, foe(1, 0, 12));
    enemies.set(2, foe(2, 0, 20));
    abilities.cast('marrow_spear', { x: 0, z: 20 }, 1000);
    step(1);
    expect((sent(send)[0] as Extract<Intent, { t: 'hit' }>).ids).toEqual([1]);
  });
  it('Impaling: only the first enemy on the line, 25% harder, rooted', () => {
    vi.spyOn(Math, 'random').mockReturnValue(0.5); // no crit, no damage spread: the ratios are exact
    const base = client();
    base.enemies.set(1, foe(1, 0, 4));
    base.abilities.cast('marrow_spear', { x: 0, z: 10 }, 1000);
    base.step(1);
    const plain = (sent(base.send)[0] as Extract<Intent, { t: 'hit' }>).dmg;
    const { enemies, send, abilities, step } = client({ marrow_spear: 'rune_impale' });
    enemies.set(1, foe(1, 0, 9));
    enemies.set(2, foe(2, 0.2, 4));
    enemies.set(3, foe(3, 0, 6));
    abilities.cast('marrow_spear', { x: 0, z: 10 }, 1000);
    step(1);
    const hits = sent(send) as Extract<Intent, { t: 'hit' }>[];
    expect(hits).toHaveLength(1);
    expect(hits[0].ids).toEqual([2]);
    expect(hits[0].root).toBe(true);
    expect(hits[0].rootS).toBe(RUNE_TUNING.impale.rootS);
    expect(hits[0].dmg / plain).toBeCloseTo(RUNE_TUNING.impale.damageMult, 6);
  });
  it('Impaling a boss: the blow lands, no root is claimed', () => {
    const { send, abilities, step, setBoss } = client({ marrow_spear: 'rune_impale' });
    setBoss({ active: true, x: 0, z: 6 });
    abilities.cast('marrow_spear', { x: 0, z: 10 }, 1000);
    step(1);
    const h = sent(send)[0] as Extract<Intent, { t: 'hit' }>;
    expect(h.boss).toBe(true);
    expect(h.root).toBeUndefined();
  });
});

describe('Exhume, Miasma and Black Litany runes (cast)', () => {
  const exhumeIntent = (send: ReturnType<typeof vi.fn>) => sent(send).find((i) => i.t === 'exhume') as Extract<Intent, { t: 'exhume' }>;

  it('Mass Grave asks for three corpses within 4 m; plain Exhume asks for one', () => {
    const plain = client();
    plain.corpses.set(1, body(1, 0, 4));
    plain.abilities.cast('exhume', { x: 0, z: 4 }, 1000);
    expect(exhumeIntent(plain.send)).toMatchObject({ r: 0.8 });
    expect(exhumeIntent(plain.send).count).toBeUndefined();
    expect(exhumeIntent(plain.send).colossus).toBeUndefined();
    const m = client({ exhume: 'rune_mass_grave' });
    m.corpses.set(1, body(1, 0, 4));
    m.corpses.set(2, body(2, 1, 4));
    m.abilities.cast('exhume', { x: 0, z: 4 }, 1000);
    expect(exhumeIntent(m.send)).toMatchObject({ count: 3, r: RUNE_TUNING.massGrave.pickRadius });
  });
  it('Bone Colossus needs three corpses near the one you name; with fewer Exhume raises an ordinary thrall as usual', () => {
    const { p, corpses, send, abilities } = client({ exhume: 'rune_bone_colossus' });
    corpses.set(1, body(1, 0, 4));
    corpses.set(2, body(2, 1, 4));
    const before = p.essence;
    expect(abilities.cast('exhume', { x: 0, z: 4 }, 1000)).toBe('ok');
    expect(p.essence).toBeLessThan(before);
    expect(exhumeIntent(send).colossus).toBeUndefined();
    expect(exhumeIntent(send).r).toBe(0.8);
    // ...and the ordinary raise keeps the short cooldown
    expect(p.onCooldown('exhume', 1000 + 700)).toBe(false);
    send.mockClear();
    p.cooldowns.clear();
    p.castUntil = 0;
    corpses.set(3, body(3, 2, 4));
    corpses.set(4, body(4, 30, 4)); // far away: not company
    expect(abilities.cast('exhume', { x: 0, z: 4 }, 2000)).toBe('ok');
    expect(exhumeIntent(send)).toMatchObject({ colossus: true, r: RUNE_TUNING.colossus.pickRadius });
  });
  it('a Colossus that already stands is not raised twice: Exhume fills the legion around it', () => {
    const thralls = new Map<number, unknown>([[7, { owner: 'solo', kind: 'colossus', state: 'idle' }]]);
    const { corpses, send, abilities } = client({ exhume: 'rune_bone_colossus' }, { thralls: () => thralls } as never);
    for (let i = 0; i < 4; i++) corpses.set(i + 1, body(i + 1, i * 0.5, 4));
    expect(abilities.cast('exhume', { x: 0, z: 4 }, 1000)).toBe('ok');
    expect(exhumeIntent(send).colossus).toBeUndefined();
    // another player's colossus does not count
    thralls.set(7, { owner: 'someone-else', kind: 'colossus', state: 'idle' });
    const again = client({ exhume: 'rune_bone_colossus' }, { thralls: () => thralls } as never);
    for (let i = 0; i < 4; i++) again.corpses.set(i + 1, body(i + 1, i * 0.5, 4));
    again.abilities.cast('exhume', { x: 0, z: 4 }, 1000);
    expect(exhumeIntent(again.send).colossus).toBe(true);
  });
  it('Bone Colossus takes Exhume out of your hands for 4 s; other casts and runes leave the 500 ms cooldown alone', () => {
    const c = client({ exhume: 'rune_bone_colossus' });
    for (let i = 0; i < 3; i++) c.corpses.set(i + 1, body(i + 1, i, 4));
    c.abilities.cast('exhume', { x: 0, z: 4 }, 1000);
    expect(c.p.onCooldown('exhume', 1000 + 3000)).toBe(true);
    expect(c.p.onCooldown('exhume', 1000 + 4100)).toBe(false);
    const m = client({ exhume: 'rune_mass_grave' });
    m.corpses.set(1, body(1, 0, 4));
    m.abilities.cast('exhume', { x: 0, z: 4 }, 1000);
    expect(m.p.onCooldown('exhume', 1000 + 700)).toBe(false);
  });
  it('Creeping Rot narrows the circle and asks the host to drift it; Contagion asks for the spread', () => {
    const plain = client();
    plain.abilities.cast('miasma', { x: 0, z: 8 }, 1000);
    plain.step(2);
    const base = sent(plain.send)[0] as Extract<Intent, { t: 'miasma' }>;
    expect(base.creep).toBeUndefined();
    expect(base.contagion).toBeUndefined();
    const c = client({ miasma: 'rune_creeping_rot' });
    c.abilities.cast('miasma', { x: 0, z: 8 }, 1000);
    c.step(2);
    const m = sent(c.send)[0] as Extract<Intent, { t: 'miasma' }>;
    expect(m.creep).toBe(RUNE_TUNING.creepingRot.speed);
    expect(m.r / base.r).toBeCloseTo(RUNE_TUNING.creepingRot.radiusMult, 6);
    const k = client({ miasma: 'rune_contagion' });
    k.abilities.cast('miasma', { x: 0, z: 8 }, 1000);
    k.step(2);
    expect(sent(k.send)[0]).toMatchObject({ contagion: true });
    expect((sent(k.send)[0] as Extract<Intent, { t: 'miasma' }>).r).toBeCloseTo(base.r, 6);
  });
  it('Hollow Choir spares the thralls at 60% power; Requiem delays the burst and widens the radius', () => {
    const plain = client();
    plain.abilities.cast('black_litany', { x: 0, z: 0 }, 1000);
    const base = sent(plain.send)[0] as Extract<Intent, { t: 'litany' }>;
    expect(base.spare).toBeUndefined();
    expect(base.delayMs).toBeUndefined();
    const ch = client({ black_litany: 'rune_hollow_choir' });
    ch.abilities.cast('black_litany', { x: 0, z: 0 }, 1000);
    const choir = sent(ch.send)[0] as Extract<Intent, { t: 'litany' }>;
    expect(choir.spare).toBe(true);
    expect(choir.spellPower / base.spellPower).toBeCloseTo(RUNE_TUNING.hollowChoir.powerMult, 6);
    expect(choir.r).toBe(base.r);
    const rq = client({ black_litany: 'rune_requiem' });
    rq.abilities.cast('black_litany', { x: 0, z: 0 }, 1000);
    const req = sent(rq.send)[0] as Extract<Intent, { t: 'litany' }>;
    expect(req.delayMs).toBe(2000);
    expect(req.r / base.r).toBeCloseTo(RUNE_TUNING.requiem.radiusMult, 6);
    expect(req.spellPower).toBe(base.spellPower);
  });
});

// --- co-op relay: caster client -> realtime clamps -> host sim --------------------------------------------------------------

describe('co-op relay: what a guest casts survives the realtime server and works on the host', () => {
  process.env.DEV_TRUST_TOKENS = '1';
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { validIntent } = require('../../../server/realtime/server.js') as { validIntent: (i: Record<string, unknown>) => Intent | null };
  /** The guest's cast, as the host receives it (the server stamps the real sender). */
  const relayed = (send: ReturnType<typeof vi.fn>, type: Intent['t']): Intent => {
    const raw = sent(send).find((i) => i.t === type)!;
    const clean = validIntent({ ...raw })!;
    expect(clean, `the ${type} intent passes validation`).toBeTruthy();
    return { ...clean, by: 'p1' } as Intent;
  };

  it('Mass Grave raises three at 75%, the Colossus raises one giant, and the plain Exhume is unchanged', () => {
    const mass = client({ exhume: 'rune_mass_grave' });
    const { sim } = world();
    quiet(sim);
    for (let i = 0; i < 4; i++) { mass.corpses.set(i + 1, body(i + 1, i * 0.8, 4)); corpse(sim, i * 0.8, 4); }
    mass.abilities.cast('exhume', { x: 0, z: 4 }, 1000);
    sim.apply(relayed(mass.send, 'exhume'));
    expect(mine(sim)).toHaveLength(3);
    expect(new Set(mine(sim).map((t) => Math.round(t.maxHp)))).toEqual(new Set([Math.round(45 * RUNE_TUNING.massGrave.statMult)]));

    const col = client({ exhume: 'rune_bone_colossus' });
    const w = world();
    quiet(w.sim);
    for (let i = 0; i < 6; i++) { col.corpses.set(i + 1, body(i + 1, i * 0.8, 4)); corpse(w.sim, i * 0.8, 4); }
    col.abilities.cast('exhume', { x: 0, z: 4 }, 1000);
    w.sim.apply(relayed(col.send, 'exhume'));
    expect(mine(w.sim).map((t) => t.kind)).toEqual(['colossus']);
    expect(mine(w.sim)[0].maxHp).toBeCloseTo(45 * RUNE_TUNING.colossus.hpPerCorpse * 5, 4);

    const plain = client();
    const p2 = world();
    quiet(p2.sim);
    plain.corpses.set(1, body(1, 0, 4)); corpse(p2.sim, 0, 4); corpse(p2.sim, 0.8, 4);
    plain.abilities.cast('exhume', { x: 0, z: 4 }, 1000);
    p2.sim.apply(relayed(plain.send, 'exhume'));
    expect(mine(p2.sim)).toHaveLength(1);
    expect(mine(p2.sim)[0].maxHp).toBe(45);
  });
  it('Creeping Rot and Contagion reach the host as flags it honours', () => {
    const rot = client({ miasma: 'rune_creeping_rot' });
    const { sim } = world();
    quiet(sim);
    rot.abilities.cast('miasma', { x: 0, z: 8 }, 1000);
    rot.step(2);
    sim.apply(relayed(rot.send, 'miasma'));
    expect([...sim.zones.values()][0].creep).toBe(RUNE_TUNING.creepingRot.speed);
    const con = client({ miasma: 'rune_contagion' });
    const w = world();
    quiet(w.sim);
    con.abilities.cast('miasma', { x: 0, z: 8 }, 1000);
    con.step(2);
    w.sim.apply(relayed(con.send, 'miasma'));
    expect([...w.sim.zones.values()][0].contagion).toBe(true);
  });
  it('Hollow Choir spares the guest\'s thralls and Requiem waits two seconds (radius within the realtime clamp even at Soul Harvest size)', () => {
    const choir = client({ black_litany: 'rune_hollow_choir' });
    const { sim } = world();
    quiet(sim);
    for (let i = 0; i < 2; i++) { corpse(sim, i, -22); sim.apply(exhume(i, -22, { r: 0.4 })); }
    choir.p.x = 0; choir.p.z = -16;
    choir.abilities.cast('black_litany', { x: 0, z: 0 }, 1000);
    sim.apply(relayed(choir.send, 'litany'));
    expect(mine(sim)).toHaveLength(2);
    const rq = client({ black_litany: 'rune_requiem' });
    const w = world();
    quiet(w.sim);
    rq.abilities.cast('black_litany', { x: 0, z: 0 }, 1000);
    const intent = relayed(rq.send, 'litany') as Extract<Intent, { t: 'litany' }>;
    expect(intent.delayMs).toBe(2000);
    expect(intent.r).toBeCloseTo(7 * RUNE_TUNING.requiem.radiusMult, 6);
    w.sim.apply(intent);
    expect(of(w.sim.drain(), 'requiem')).toHaveLength(1);
    // Soul Harvest makes a litany 50% larger: still inside the clamp
    expect((validIntent({ t: 'litany', x: 0, z: 0, r: 7 * 1.5 * RUNE_TUNING.requiem.radiusMult, spellPower: 5, delayMs: 2000 }) as Extract<Intent, { t: 'litany' }>).r).toBeCloseTo(7 * 1.5 * RUNE_TUNING.requiem.radiusMult, 6);
  });
  it('Impaling roots the first enemy on the host and a boss shrugs it off', () => {
    const imp = client({ marrow_spear: 'rune_impale' });
    imp.enemies.set(1, foe(1, 0, 4));
    imp.abilities.cast('marrow_spear', { x: 0, z: 10 }, 1000);
    imp.step(1);
    const { sim } = world();
    const e = sim.spawnEnemy('robber', 'graves', 0, -12, false);
    const hit = relayed(imp.send, 'hit') as Extract<Intent, { t: 'hit' }>;
    sim.apply({ ...hit, ids: [e.id] });
    expect(e.rootT).toBe(RUNE_TUNING.impale.rootS);
    expect(hit.rootS).toBe(RUNE_TUNING.impale.rootS);
  });
});

// --- help ------------------------------------------------------------------------------------------------------------

describe('help for runes', () => {
  it('has counsel tips with sensible kinds, a Codex tab\'s rows and a found record', () => {
    expect(TIPS.rune.body).toMatch(/Grimoire/);
    expect(TIPS.runeSocketed.body).toMatch(/badge/);
    expect(kindOf('rune')).toBe('calm');
    expect(kindOf('runeSocketed')).toBe('calm'); // waits for the Grimoire to close rather than covering its first socket
    const rows = codexRuneRows();
    expect(rows.map((g) => g.runes.length).reduce((a, b) => a + b, 0)).toBe(11);
    expect(CODEX_RUNES_COUNSEL).toMatch(/Bone Colossus|Grimoire/);
    const store = new Map<string, string>();
    const mem = { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => void store.set(k, v), removeItem: (k: string) => void store.delete(k) };
    expect(recordRunesFound(mem, 1, ['sword_copper', 'rune_volley']).grew).toBe(true);
    expect(recordRunesFound(mem, 1, ['rune_volley']).grew).toBe(false);
    expect([...loadRunesFound(mem, 1)]).toEqual(['rune_volley']);
    expect([...loadRunesFound(mem, 2)]).toEqual([]);
  });
});
