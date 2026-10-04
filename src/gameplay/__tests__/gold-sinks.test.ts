import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { Nav } from '../nav';
import { WorldSim } from '../sim/WorldSim';
import { mulberry32 } from '../rng';
import type { SimEvent } from '../sim/types';
import { AREAS } from '../../content/areas';
import { BOSSES } from '../../content/bosses';
import { ITEMS } from '../../content/items';
import { DISCIPLINES } from '../../content/disciplines';
import { NODES } from '../gatheringRules';
import { parseKillReport } from '../killRules';
import { KillReporter } from '../../net/killReporter';
import { affixRange, AFFIXES, isAffixGear } from '../affixRules';
import { EMPOWER, EMPOWERABLE, REFORGE, canEmpower, empowerGold, empoweredLegendaryChance, empoweredLevel, reforgeCost, reforgeProblem, reforgeValue, rollEmpoweredInstance, rollEmpoweredPrize } from '../goldSinkRules';

const seeded = (seed: number) => mulberry32(seed);

describe('reforge price curve', () => {
  it('is 40 gold per item level, x1.25 per reforge of the same piece, capped', () => {
    expect(reforgeCost(20, 'uncommon', 1, 0)).toBe(800);
    expect(reforgeCost(20, 'uncommon', 1, 1)).toBe(1000);
    expect(reforgeCost(20, 'uncommon', 1, 2)).toBe(1250);
    expect(reforgeCost(99, 'epic', 3, 0)).toBe(9900);
    expect(reforgeCost(99, 'epic', 3, REFORGE.maxSteps + 50)).toBe(reforgeCost(99, 'epic', 3, REFORGE.maxSteps));
    expect(reforgeCost(99, 'legendary', 3, 30)).toBeLessThanOrEqual(REFORGE.cap);
  });

  it('only ever rises with reforges, item level and rarity', () => {
    for (const n of [0, 3, 10, 19]) expect(reforgeCost(40, 'rare', 2, n + 1)).toBeGreaterThan(reforgeCost(40, 'rare', 2, n));
    expect(reforgeCost(50, 'rare', 2, 4)).toBeGreaterThan(reforgeCost(40, 'rare', 2, 4));
    expect(reforgeCost(40, 'rare', 3, 4)).toBeGreaterThan(reforgeCost(40, 'rare', 2, 4));
  });

  it('is a sink, not a wall: against the live gold balances (7.6M and 174k on 3 Oct 2026)', () => {
    // A level-119 hero (174k gold) with an ilvl-45 epic piece: ten reforges of one piece cost most of their wallet, a few reforges of several pieces are cheap.
    let total = 0;
    for (let n = 0; n < 10; n++) total += reforgeCost(45, 'epic', 3, n);
    expect(reforgeCost(45, 'epic', 3, 0)).toBeLessThan(5_000);
    expect(total).toBeLessThan(174_000 * 1.0);
    // The owner's level-255 hero (7.6M gold) with ilvl-99 pieces: one piece reforged 20 times costs millions in all, so gold finally has a floor.
    let deep = 0;
    for (let n = 0; n < 20; n++) deep += reforgeCost(99, 'epic', 3, n);
    expect(deep).toBeGreaterThan(3_000_000);
  });
});

describe('reforge roll', () => {
  it('keeps the affix and draws inside the range the rules give today (read from affixRules, not hardcoded)', () => {
    for (const a of AFFIXES) {
      for (const ilvl of [1, 20, 60, 99]) {
        const [lo, hi] = affixRange(a.id, ilvl)!;
        expect(reforgeValue(a.id, ilvl, () => 0)).toBe(lo);
        expect(reforgeValue(a.id, ilvl, () => 0.999999)).toBe(hi);
        const r = seeded(ilvl);
        for (let i = 0; i < 20; i++) {
          const v = reforgeValue(a.id, ilvl, r);
          expect(v).toBeGreaterThanOrEqual(lo);
          expect(v).toBeLessThanOrEqual(hi);
        }
      }
    }
  });

  it('refuses a missing affix and a roll already at the top', () => {
    const [, hi] = affixRange('p_str', 30)!;
    expect(reforgeProblem({ ilvl: 30, affixes: [{ id: 'p_str', v: hi }] }, 0)).toMatch(/as high/);
    expect(reforgeProblem({ ilvl: 30, affixes: [{ id: 'p_str', v: hi - 1 }] }, 0)).toBeNull();
    expect(reforgeProblem({ ilvl: 30, affixes: [{ id: 'p_str', v: 1 }] }, 2)).toMatch(/Choose/);
    expect(reforgeProblem({ ilvl: 30, affixes: [{ id: 'nope', v: 1 }] }, 0)).toMatch(/cannot/);
  });
});

describe('Empowered summons', () => {
  it('cost 7,500 gold x shards squared, and never the Prelate', () => {
    expect(EMPOWERABLE.map(empowerGold)).toEqual([30000, 67500, 120000, 187500, 270000, 367500]);
    expect(canEmpower('prelate')).toBe(false);
    expect(EMPOWERABLE.every((b) => BOSSES[b].area !== 'sanctum')).toBe(true);
  });

  it('prizes are gear the area drops (or a legendary), never a material, and legendaries come at 2.5x the ordinary odds', () => {
    const ids = Object.keys(DISCIPLINES);
    for (const boss of EMPOWERABLE) {
      const loot = new Set(AREAS[BOSSES[boss].area].loot.map((e) => e.item));
      const r = seeded(boss.length * 7);
      let legendary = 0;
      const N = 1500;
      for (let i = 0; i < N; i++) {
        const prize = rollEmpoweredPrize(boss, ids[i % ids.length], r);
        expect(ITEMS[prize.item_id], prize.item_id).toBeTruthy();
        expect(isAffixGear(ITEMS[prize.item_id].type), prize.item_id).toBe(true);
        if (prize.legendary) legendary++;
        else expect(loot.has(prize.item_id), `${boss}: ${prize.item_id}`).toBe(true);
      }
      expect(legendary / N).toBeGreaterThan(empoweredLegendaryChance(boss) - 0.04);
      expect(legendary / N).toBeLessThan(empoweredLegendaryChance(boss) + 0.04);
    }
    expect(empoweredLegendaryChance('gravedigger')).toBe(0.075);
    expect(empoweredLegendaryChance('abbess')).toBe(0.375);
  });

  it('a non-legendary prize always carries three affixes (it shows epic) and a legal roll', () => {
    const r = seeded(5);
    for (let i = 0; i < 300; i++) {
      const inst = rollEmpoweredInstance({ item_id: 'helm_iron', legendary: false }, 'common', 1 + (i % 90), r);
      expect(inst.affixes).toHaveLength(EMPOWER.prizeAffixes);
      expect(new Set(inst.affixes.map((a) => a.id)).size).toBe(3);
      for (const a of inst.affixes) {
        const [lo, hi] = affixRange(a.id, inst.ilvl)!;
        expect(a.v).toBeGreaterThanOrEqual(lo);
        expect(a.v).toBeLessThanOrEqual(hi);
      }
    }
  });

  it('the Seal has real sources: Crypt Collapse (Gravedigging 40), the Barrow-King\'s Tomb (70) and the Coelacanth (Fishing 80)', () => {
    const from = Object.values(NODES).filter((n) => n.extras?.some((e) => e.item === 'covenant_seal')).map((n) => `${n.skill} ${n.level}`).sort();
    expect(from).toEqual(['fishing 80', 'gravedigging 40', 'gravedigging 70']);
  });
});

describe('the BossBrain level knob', () => {
  function world() {
    const nav = new Nav();
    nav.setUnlocked(['chapterhouse', 'graves', 'ossuary', 'nave', 'sanctum', 'cloister', 'pyre', 'fen']);
    const sim = new WorldSim(nav, seeded(1));
    const r = AREAS.graves.rect;
    sim.setPlayer({ id: 'p1', x: (r.x0 + r.x1) / 2, z: (r.z0 + r.z1) / 2, alive: true, area: 'graves' });
    sim.step(0.05);
    return sim;
  }
  it('an Empowered boss fights at a higher level with more health, and says so in its events and state', () => {
    const plain = world();
    plain.apply({ t: 'summonBoss', by: 'p1', boss: 'gravedigger' });
    const emp = world();
    const events: SimEvent[] = [];
    emp.apply({ t: 'summonBoss', by: 'p1', boss: 'gravedigger', empowered: true });
    events.push(...emp.step(0.05));
    const a = plain.boss.state;
    const b = emp.boss.state;
    expect(a.empowered).toBeFalsy();
    expect(b.empowered).toBe(true);
    expect(b.level).toBe(empoweredLevel(a.level));
    expect(b.maxHp).toBeGreaterThan(a.maxHp * EMPOWER.hpMult);
    expect(events.some((e) => e.t === 'boss' && e.kind === 'awaken' && e.empowered)).toBe(true);
  });

  it('the flag cannot empower the Prelate, and the next ordinary summon is plain again', () => {
    const sim = world();
    sim.apply({ t: 'summonBoss', by: 'p1', empowered: true });
    expect(sim.boss.state.empowered).toBeFalsy();
    const again = world();
    again.apply({ t: 'summonBoss', by: 'p1', boss: 'gravedigger', empowered: true });
    again.boss.state.hp = 0;
    again.step(0.05);
    again.apply({ t: 'summonBoss', by: 'p1', boss: 'gravedigger' });
    expect(again.boss.state.empowered).toBe(false);
  });
});

describe('the docs and the SQL agree with the rules', () => {
  it('migration 035 only adds tables', () => {
    const sql = readFileSync(new URL('../../../server/death-muffin/backend/migrations/035-gold-sinks.sql', import.meta.url), 'utf8');
    expect(sql).toMatch(/CREATE TABLE IF NOT EXISTS loot_reforges/);
    expect(sql).toMatch(/CREATE TABLE IF NOT EXISTS empowered_summons/);
    expect(sql).not.toMatch(/^\s*(ALTER|DROP|DELETE|UPDATE|TRUNCATE)\b/im);
  });
});

describe('the boss kill report names the Empowered summon', () => {
  it('survives parsing, and an Empowered kill is its own group in the reporter', () => {
    const rep = parseKillReport({ seq: 1, groups: [], floors: [], bosses: [{ boss: 'abbess', tier: 0, diff: 'medium', first: false, summon: 7, n: 1 }] })!;
    expect(rep.bosses[0].summon).toBe(7);
    const r = new KillReporter(() => 1000);
    r.boss({ boss: 'abbess', tier: 0, diff: 'medium', first: false });
    r.boss({ boss: 'abbess', tier: 0, diff: 'medium', first: false, summon: 7 });
    expect(r.batches()[0].bosses).toHaveLength(2);
  });
});
