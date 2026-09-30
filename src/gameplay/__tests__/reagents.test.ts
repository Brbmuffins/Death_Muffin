import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { AREAS } from '../../content/areas';
import { BOSSES, BOSS_IDS } from '../../content/bosses';
import { BREWS, type BrewKind } from '../../content/brews';
import { codexReagentRecipes, codexReagentRows } from '../../content/codex';
import { BUFF_FLASKS, ITEMS } from '../../content/items';
import { generateLayout } from '../../content/layout';
import {
  ALL_REAGENT_IDS, AREA_REAGENT_DROPS, BOSS_ICHOR, ENEMY_REAGENT_DROPS, ICHORS, MOB_REAGENTS, REAGENT_BREW_ITEMS, REAGENT_BREW_LIST, REAGENT_BREWS,
  REAGENT_ITEMS, REAGENT_RECIPES, reagentDropIds,
} from '../../content/reagents';
import { SEEDS } from '../../content/gardening';
import { TIPS } from '../../ui/Onboarding';
import { candidatesFor } from '../contractRules';
import { NODES, rollBatch } from '../gatheringRules';
import { rollBoss, rollKill, rollReagents } from '../loot';
import { mulberry32 } from '../rng';

const GRAVES_DUST_ID = 'reagent_grave_dust';
const dropIds = new Set(reagentDropIds());
const ingredientIds = new Set(REAGENT_RECIPES.flatMap((r) => r[6].map(([i]) => i)));

describe('reagents: catalogue', () => {
  it('every new item is known to the client, sells, and has an icon on disk', () => {
    expect(ALL_REAGENT_IDS.length).toBe(Object.keys(REAGENT_ITEMS).length + Object.keys(REAGENT_BREW_ITEMS).length);
    for (const id of ALL_REAGENT_IDS) {
      expect(ITEMS[id], id).toBeDefined();
      expect(ITEMS[id].sell, `${id} must sell`).toBeGreaterThan(0);
      expect(ITEMS[id].lore?.length ?? 0, `${id} lore`).toBeGreaterThan(20);
      expect(existsSync(`public/art/items/${id}.svg`), `${id} icon`).toBe(true);
      expect(ITEMS[id].icon).toBe(`art/items/${id}.svg`);
    }
  });

  it('the fixed id contract holds', () => {
    for (const id of ['reagent_grave_dust', 'reagent_wraith_ectoplasm', 'reagent_plague_bile', 'reagent_cinder_ash', 'herb_rot_cap', 'herb_ash_bloom', 'seed_rot_cap', 'seed_ash_bloom',
      'ichor_gravedigger', 'ichor_abbess', 'ichor_congregation', 'ichor_prelate', 'ichor_plague_saint', 'ichor_regent']) expect(REAGENT_ITEMS[id], id).toBeDefined();
    for (const id of ICHORS) expect(ITEMS[id].rarity).toBe('epic');
    expect(ITEMS.reagent_grave_dust.rarity).toBe('common');
    expect(ITEMS.reagent_wraith_ectoplasm.rarity).toBe('uncommon');
    expect(ITEMS.reagent_plague_bile.rarity).toBe('rare');
    expect(ITEMS.reagent_cinder_ash.rarity).toBe('rare');
    for (const id of Object.keys(REAGENT_ITEMS)) expect(ITEMS[id].stack, id).toBe(250);
  });

  it('no dead-end materials: every reagent, herb and ichor feeds a recipe; seeds are plantable; brews are drinkable', () => {
    for (const id of Object.keys(REAGENT_ITEMS)) {
      if (id.startsWith('seed_')) expect(SEEDS.some((s) => s.id === id), `${id} is not plantable`).toBe(true);
      else expect(ingredientIds.has(id), `${id} is a dead end`).toBe(true);
    }
    for (const id of Object.keys(REAGENT_BREW_ITEMS)) {
      expect(id in BREWS && id in BUFF_FLASKS, `${id} is not drinkable`).toBe(true);
      expect(REAGENT_RECIPES.some((r) => r[4] === id), `${id} has no recipe`).toBe(true);
    }
  });

  it('the zone herbs can be planted in the Acre at the planned levels', () => {
    const rot = SEEDS.find((s) => s.id === 'seed_rot_cap')!;
    const ash = SEEDS.find((s) => s.id === 'seed_ash_bloom')!;
    expect([rot.harvest, rot.level, rot.kind]).toEqual(['herb_rot_cap', 35, 'herb']);
    expect([ash.harvest, ash.level, ash.kind]).toEqual(['herb_ash_bloom', 50, 'herb']);
  });

  it('the codex lists every reagent and every recipe with real numbers', () => {
    const rows = codexReagentRows();
    for (const id of Object.keys(REAGENT_ITEMS).filter((i) => !i.startsWith('seed_'))) {
      const r = rows.find((x) => x.id === id)!;
      expect(r.from.length, `${id} source`).toBeGreaterThan(5);
      expect(r.usedIn.length, `${id} use`).toBeGreaterThan(0);
    }
    expect(codexReagentRecipes()).toHaveLength(REAGENT_RECIPES.length);
  });

  it('the first-pickup counsel tip points at the Workbench Alchemy tab', () => {
    expect(TIPS.reagent.body).toMatch(/Workbench/);
    expect(TIPS.reagent.body).toMatch(/Alchemy tab/);
  });
});

describe('reagents: brews and recipes', () => {
  it('recipes reference existing items, rise in level across 1-85, and are unique', () => {
    let last = 0;
    const ids = new Set<string>();
    for (const [id, name, prof, level, result, qty, ings] of REAGENT_RECIPES) {
      expect(prof, id).toBe('alchemy');
      expect(name).toBeTruthy();
      expect(ids.has(id), `duplicate ${id}`).toBe(false);
      ids.add(id);
      expect(ITEMS[result], `${id} result`).toBeDefined();
      expect(qty).toBeGreaterThanOrEqual(1);
      for (const [item, n] of ings) {
        expect(ITEMS[item], `${id} ingredient ${item}`).toBeDefined();
        expect(n).toBeGreaterThan(0);
      }
      expect(level).toBeGreaterThanOrEqual(last);
      last = level;
    }
    expect(REAGENT_RECIPES[0][3]).toBe(1);
    expect(last).toBeLessThanOrEqual(85);
    expect(REAGENT_RECIPES.length).toBeGreaterThanOrEqual(10);
  });

  it('brew rows are valid: slots match effect kinds, magnitudes stay in bounds, lore states the numbers', () => {
    const tonicKinds: BrewKind[] = ['speed', 'essence', 'wisdom', 'fortune'];
    for (const [id, b] of REAGENT_BREW_LIST) {
      const def = BREWS[id];
      expect(def, id).toBe(REAGENT_BREWS[id]);
      expect(def.seconds).toBeGreaterThanOrEqual(30);
      expect(def.seconds).toBeLessThanOrEqual(90);
      expect(def.label.length).toBeGreaterThan(2);
      expect(def.glyph.length).toBeGreaterThan(0);
      for (const e of def.effects) {
        expect(tonicKinds.includes(e.kind), `${id} ${e.kind} is in the wrong slot`).toBe(def.slot === 'tonic');
        expect(e.value).toBeGreaterThan(0);
        if (e.kind === 'fortune') expect(e.value).toBeLessThanOrEqual(0.3);
        if (e.kind === 'wisdom') expect(e.value).toBeLessThanOrEqual(0.25);
        if (e.kind === 'lifesteal') expect(e.value).toBeLessThanOrEqual(0.08);
        // Every number in the effect appears in the lore as a percentage.
        expect(b.lore, `${id} lore`).toContain(`${Math.round(e.value * 100)}%`);
      }
      const lifesteal = def.effects.filter((e) => e.kind === 'lifesteal').reduce((s, e) => s + e.value, 0);
      expect(lifesteal).toBeLessThanOrEqual(0.08);
      const ward = def.effects.filter((e) => ['ward', 'resist_fire', 'resist_rot'].includes(e.kind)).reduce((s, e) => s + e.value, 0);
      expect(ward).toBeLessThanOrEqual(0.6);
      expect(b.lore).toContain(`${def.seconds} seconds`);
    }
  });

  it('covers every unused Brew kind at least once', () => {
    const kinds = new Set(REAGENT_BREW_LIST.flatMap(([id]) => BREWS[id].effects.map((e) => e.kind)));
    for (const k of ['haste', 'lifesteal', 'resist_fire', 'resist_rot', 'essence', 'wisdom', 'fortune', 'damage']) expect(kinds.has(k as BrewKind), k).toBe(true);
  });

  it('the starter brew is Alchemy 1 and needs only mob-drop inputs', () => {
    const starter = REAGENT_RECIPES[0];
    expect(starter[3]).toBe(1);
    expect(starter[6]).toEqual([[GRAVES_DUST_ID, 4]]);
    for (const [item] of starter[6]) expect(dropIds.has(item), `${item} is not a mob drop`).toBe(true);
    expect(AREA_REAGENT_DROPS.graves?.some((d) => d.item === GRAVES_DUST_ID)).toBe(true);
    expect(AREA_REAGENT_DROPS.warren?.some((d) => d.item === GRAVES_DUST_ID)).toBe(true);
    // A fresh Workbench craft makes a drinkable tonic.
    expect(BREWS[starter[4]].slot).toBe('tonic');
  });

  it('the top-tier elixirs need boss ichor, and every ichor is used', () => {
    for (const id of ['elixir_bloodmoon', 'elixir_hymnal', 'elixir_regent']) {
      const r = REAGENT_RECIPES.find((x) => x[4] === id)!;
      expect(r[3]).toBeGreaterThanOrEqual(70);
      expect(r[6].some(([i]) => ICHORS.includes(i)), id).toBe(true);
      expect(BREWS[id].effects.length).toBeGreaterThanOrEqual(2);
    }
    for (const id of ICHORS) expect(ingredientIds.has(id), id).toBe(true);
  });

  it('the server stat_bonus follows the ALCHEMY_ITEMS shape', () => {
    for (const [id, it] of Object.entries(REAGENT_BREW_ITEMS)) {
      expect(it.stat.value, id).toBe(BREWS[id].effects[0].value);
      expect(it.stat.duration).toBe(BREWS[id].seconds);
      expect(typeof it.stat.effect).toBe('string');
    }
  });

  it('every mob reagent and brew is reachable as a contract candidate at a sensible level', () => {
    const low = candidatesFor({ alchemy: 1 }).map((c) => c.itemId);
    expect(low).toContain(GRAVES_DUST_ID);
    expect(low).toContain('tonic_grave_dust');
    const top = candidatesFor({ alchemy: 99, gardening: 99 }).map((c) => c.itemId);
    for (const [id] of REAGENT_BREW_LIST) expect(top, id).toContain(id);
    for (const id of MOB_REAGENTS) expect(top, id).toContain(id);
    for (const id of ICHORS) expect(top, id).not.toContain(id);
  });
});

describe('reagents: drops', () => {
  it('every drop id is a known item, and every area/enemy named exists', () => {
    for (const id of dropIds) expect(ITEMS[id], id).toBeDefined();
    for (const area of Object.keys(AREA_REAGENT_DROPS)) expect(AREAS[area as keyof typeof AREAS], area).toBeDefined();
    for (const d of [...Object.values(AREA_REAGENT_DROPS), ...Object.values(ENEMY_REAGENT_DROPS)].flat()) {
      expect(d!.chance).toBeGreaterThan(0);
      expect(d!.chance).toBeLessThan(0.25);
      expect(d!.qty[0]).toBeGreaterThanOrEqual(1);
    }
  });

  it('about 4-8 Grave Dust per 10 minutes in the Graves at a steady 40 kills a minute', () => {
    const rand = mulberry32(7);
    let dust = 0;
    const RUNS = 40;
    for (let run = 0; run < RUNS; run++) for (let k = 0; k < 400; k++) dust += rollReagents('robber', 'graves', false, 1, rand).filter((d) => d.item_id === GRAVES_DUST_ID).reduce((s, d) => s + d.quantity, 0);
    const per10 = dust / RUNS;
    expect(per10).toBeGreaterThan(4);
    expect(per10).toBeLessThan(8);
  });

  it('ectoplasm drops only from spirits, wherever they spawn, and never from a Graves robber', () => {
    const rand = mulberry32(3);
    let fromWraith = 0;
    let fromRobber = 0;
    for (let i = 0; i < 2000; i++) {
      fromWraith += rollReagents('wraith', 'nave', false, 1, rand).length;
      fromRobber += rollReagents('robber', 'nave', false, 1, rand).length;
    }
    expect(fromWraith).toBeGreaterThan(100);
    expect(fromRobber).toBe(0);
    for (const area of ['nave', 'sanctum', 'coliseum'] as const) {
      expect(AREAS[area].enemies.some((e) => e.id in ENEMY_REAGENT_DROPS), area).toBe(true);
    }
    expect(rollReagents('wraith', 'coliseum', false, 1, () => 0).map((d) => d.item_id)).toEqual(['reagent_wraith_ectoplasm']);
  });

  it('bile drops in the Cloister and ash in the Pyre, nowhere else; elites roll more, fortune helps', () => {
    expect(rollReagents('plague_doctor', 'cloister', false, 1, () => 0).map((d) => d.item_id)).toContain('reagent_plague_bile');
    expect(rollReagents('cinder_husk', 'pyre', false, 1, () => 0).map((d) => d.item_id)).toContain('reagent_cinder_ash');
    expect(rollReagents('robber', 'ossuary', false, 1, () => 0)).toEqual([]);
    const count = (elite: boolean, mult: number) => {
      const rand = mulberry32(11);
      let n = 0;
      for (let i = 0; i < 20000; i++) n += rollReagents('robber', 'graves', elite, mult, rand).length;
      return n;
    };
    expect(count(true, 1)).toBeGreaterThan(count(false, 1) * 2.5);
    expect(count(false, 1.3)).toBeGreaterThan(count(false, 1) * 1.1);
  });

  it('rollKill does not disturb a seeded rand stream (balance harness stays comparable)', () => {
    const a = mulberry32(5);
    const b = mulberry32(5);
    const r1 = rollKill('robber', 'graves', 1, false, 0, a, 'medium', 1, () => 0);
    const r2 = rollKill('robber', 'graves', 1, false, 0, b, 'medium', 1, () => 0.999);
    expect(r1.gold).toBe(r2.gold);
    expect(a()).toBe(b());
    expect(r1.items.some((d) => d.item_id === GRAVES_DUST_ID)).toBe(true);
    expect(r2.items.some((d) => d.item_id === GRAVES_DUST_ID)).toBe(false);
  });

  it('every boss spoils include exactly one of its own ichor, guaranteed', () => {
    for (const boss of BOSS_IDS) {
      const def = BOSSES[boss];
      for (let seed = 1; seed <= 25; seed++) {
        const r = rollBoss(0, mulberry32(seed), 'medium', def.area, def.shards, boss);
        const ichors = r.items.filter((d) => ICHORS.includes(d.item_id));
        expect(ichors, `${boss} seed ${seed}`).toEqual([{ item_id: BOSS_ICHOR[boss], quantity: 1 }]);
      }
    }
    expect(new Set(Object.values(BOSS_ICHOR)).size).toBe(BOSS_IDS.length);
    // Without a boss id the spoils are as before.
    expect(rollBoss(0, mulberry32(1), 'medium').items.some((d) => ICHORS.includes(d.item_id))).toBe(false);
  });
});

describe('reagents: zone herb patches', () => {
  const layout = generateLayout();
  const patches = layout.nodes.filter((n) => NODES[n.type]?.kind === 'herb');

  it('the Cloister holds Rot-cap patches and the Pyre Ash-bloom patches, off the boss arenas', () => {
    for (const [type, area, item] of [['rot_cap_patch', 'cloister', 'herb_rot_cap'], ['ash_bloom_patch', 'pyre', 'herb_ash_bloom']] as const) {
      const here = patches.filter((n) => n.type === type);
      expect(here.length, type).toBeGreaterThanOrEqual(2);
      for (const n of here) {
        expect(n.area).toBe(area);
        for (const b of Object.values(BOSSES)) if (b.area === area) expect(Math.hypot(n.x - b.arena.x, n.z - b.arena.z), `${n.id} in the arena`).toBeGreaterThan(b.arena.r + 1.5);
      }
      expect(NODES[type].item).toBe(item);
      expect(NODES[type].skill).toBe('gardening');
    }
  });

  it('a level-1 gardener can forage them, gains gardening XP and sometimes a seed', () => {
    const def = NODES.rot_cap_patch;
    let s = 1;
    const rng = () => ((s = (s * 16807) % 2147483647) / 2147483647);
    const r = rollBatch(def, { level: 1, xp: 0 }, 400, rng);
    expect(r.successes).toBeGreaterThan(100);
    expect(r.xp).toBeGreaterThan(1000);
    expect(r.items.find((i) => i.itemId === 'herb_rot_cap')!.qty).toBe(r.successes);
    expect(r.items.some((i) => i.itemId === 'seed_rot_cap')).toBe(true);
  });
});

describe('reagents: server migration', () => {
  it('014-alchemy-reagents.sql is generated from the content (run node tools/build-alchemy-reagents-sql.mjs if this fails)', () => {
    expect(() => execFileSync('node', ['tools/build-alchemy-reagents-sql.mjs', '--check'], { stdio: 'pipe' })).not.toThrow();
  });

  it('the icons are generated (run node tools/build-reagent-icons.mjs if this fails)', () => {
    expect(() => execFileSync('node', ['tools/build-reagent-icons.mjs', '--check'], { stdio: 'pipe' })).not.toThrow();
  });

  it('inserts every item and recipe, idempotently, and leaves the applied migrations alone', () => {
    const sql = readFileSync('server/death-muffin/backend/migrations/014-alchemy-reagents.sql', 'utf8');
    for (const id of ALL_REAGENT_IDS) expect(sql, id).toContain(`VALUES ('${id}'`);
    for (const r of REAGENT_RECIPES) expect(sql).toContain(`VALUES ('${r[0]}'`);
    for (const line of sql.split('\n').filter((l) => /^(INSERT|UPDATE|DELETE|CREATE|ALTER)/.test(l))) expect(line.startsWith('INSERT IGNORE')).toBe(true);
    expect(sql).not.toMatch(/^(DROP|TRUNCATE|DELETE|UPDATE|ALTER)/im);
    for (const old of ['007-gardening.sql', '009-alchemy.sql']) {
      const txt = readFileSync(`server/death-muffin/backend/migrations/${old}`, 'utf8');
      expect(txt, `${old} must stay as applied`).not.toMatch(/reagent_|ichor_|rot_cap|ash_bloom/);
    }
  });
});
