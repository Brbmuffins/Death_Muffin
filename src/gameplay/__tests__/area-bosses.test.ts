import { describe, expect, it } from 'vitest';
import { Nav } from '../nav';
import { WorldSim } from '../sim/WorldSim';
import { WorldMirror, makeSnapshot } from '../sim/snapshot';
import { mulberry32 } from '../rng';
import type { SimEvent } from '../sim/types';
import { AbbessBrain, CongregationBrain, segmentHitsBox } from '../sim/BossBrain';
import { ABBESS, BOSSES, CONGREGATION, GRAVEDIGGER, type BossId } from '../../content/bosses';
import { AREAS } from '../../content/areas';
import { CODEX_DEAD } from '../../content/codex';

function world(boss: BossId, seed = 3) {
  const nav = new Nav();
  nav.setUnlocked(['chapterhouse', 'graves', 'ossuary', 'nave', 'sanctum']);
  const sim = new WorldSim(nav, mulberry32(seed));
  const a = BOSSES[boss].arena;
  sim.setPlayer({ id: 'p1', x: a.x, z: a.z + 6, alive: true, area: BOSSES[boss].area });
  sim.markVisited(BOSSES[boss].area);
  return sim;
}
const of = <T extends SimEvent['t']>(ev: SimEvent[], t: T) => ev.filter((e): e is Extract<SimEvent, { t: T }> => e.t === t);
const run = (sim: WorldSim, s: number) => {
  const out: SimEvent[] = [];
  for (let t = 0; t < s; t += 0.05) out.push(...sim.step(0.05));
  return out;
};

describe('Area bosses', () => {
  it('every boss has a summon object in its area, a Codex entry and its own arena', () => {
    for (const id of Object.keys(BOSSES) as BossId[]) {
      const b = BOSSES[id];
      expect(AREAS[b.area].interactables.some((i) => i.id === b.summonId && i.kind === 'boss')).toBe(true);
      expect(CODEX_DEAD[id].counter.length).toBeGreaterThan(30);
    }
  });

  it('only one boss wakes per world, and the snapshot carries which one', () => {
    const sim = world('gravedigger');
    sim.apply({ t: 'summonBoss', by: 'p1', boss: 'gravedigger' });
    expect(sim.bossState.active).toBe(true);
    expect(sim.bossState.id).toBe('gravedigger');
    sim.apply({ t: 'summonBoss', by: 'p1', boss: 'abbess' });
    expect(sim.bossState.id).toBe('gravedigger');
    expect(sim.bosses.abbess.state.active).toBe(false);
    const m = new WorldMirror();
    m.applySnapshot(makeSnapshot(sim, true));
    expect(m.bossState?.id).toBe('gravedigger');
    // An old client's summon (no boss) still means the Prelate.
    const old = world('prelate');
    old.apply({ t: 'summonBoss', by: 'p1' });
    expect(old.bossState.id).toBe('prelate');
  });

  it("the Gravedigger's Burial buries (roots) only whoever stays on the outline", () => {
    const sim = world('gravedigger');
    sim.apply({ t: 'summonBoss', by: 'p1', boss: 'gravedigger' });
    let bury: Extract<SimEvent, { t: 'boss' }> | undefined;
    const ev: SimEvent[] = [];
    for (let i = 0; i < 400 && !bury; i++) {
      const e = sim.step(0.05);
      ev.push(...e);
      bury = of(e, 'boss').find((b) => b.kind === 'bury' && (b.ms ?? 0) === 0);
    }
    expect(bury).toBeDefined();
    const tele = of(ev, 'boss').filter((b) => b.kind === 'bury' && (b.ms ?? 0) > 0).at(-1)!;
    expect(tele.ms).toBe(GRAVEDIGGER.burial.windupMs);
    // The player stood still on the mark: caught and rooted.
    expect(bury!.players).toContain('p1');
    expect(bury!.root).toBe(GRAVEDIGGER.burial.rootS);
  });

  it("the Abbess heals while niches stand; breaking all four stops it and Fractures her", () => {
    const sim = world('abbess');
    sim.apply({ t: 'summonBoss', by: 'p1', boss: 'abbess' });
    const brain = sim.bosses.abbess as AbbessBrain;
    expect(brain.standingNiches).toBe(ABBESS.niches);
    const b = sim.bossState;
    b.hp = b.maxHp * 0.8;
    const before = b.hp;
    sim.step(1);
    expect(b.hp).toBeGreaterThan(before);
    for (const id of brain.nicheIds) sim.apply({ t: 'hit', by: 'p1', ids: [id], dmg: 1e7 });
    sim.step(0.1);
    expect(brain.standingNiches).toBe(0);
    expect(b.fracture).toBeGreaterThan(0);
    const after = b.hp;
    sim.step(1);
    expect(b.hp).toBeLessThanOrEqual(after);
  });

  it('Bone Communion devours the arena corpses and heals her for each', () => {
    const sim = world('abbess');
    sim.apply({ t: 'summonBoss', by: 'p1', boss: 'abbess' });
    const b = sim.bossState;
    const a = BOSSES.abbess.arena;
    for (let i = 0; i < 5; i++) sim.addCorpse(a.x + i - 2, a.z - 3, 'normal', 'robber', false, 0, 1, 'ossuary');
    b.hp = b.maxHp * 0.2; // phase 3
    const ev = run(sim, 25);
    const comm = of(ev, 'boss').find((e) => e.kind === 'communion' && (e.ms ?? 0) === 0);
    expect(comm).toBeDefined();
    expect(comm!.r).toBeGreaterThan(0);
    expect([...sim.corpses.values()].filter((c) => Math.hypot(c.x - a.x, c.z - a.z) <= a.r).length).toBe(0);
  });

  it('a pew between you and the Congregation blocks the Flood Hymn', () => {
    const sim = world('congregation');
    const a = BOSSES.congregation.arena;
    sim.setCover([{ x0: a.x - 1.4, z0: a.z + 2.6, x1: a.x + 1.4, z1: a.z + 3.3 }]);
    sim.apply({ t: 'summonBoss', by: 'p1', boss: 'congregation' });
    const brain = sim.bosses.congregation as CongregationBrain;
    expect(brain.covered(a.x, a.z + 6)).toBe(true);
    expect(brain.covered(a.x + 5, a.z + 4)).toBe(false);
    expect(segmentHitsBox(0, 0, 10, 0, { x0: 4, z0: -1, x1: 5, z1: 1 })).toBe(true);
    expect(segmentHitsBox(0, 0, 10, 0, { x0: 4, z0: 2, x1: 5, z1: 3 })).toBe(false);
    // Standing behind the pew through a whole Hymn: the step it lands in hurts nobody.
    let landed = false;
    for (let i = 0; i < 200 && !landed; i++) {
      const e = sim.step(0.05);
      if (of(e, 'boss').some((b) => b.kind === 'hymn' && (b.ms ?? 0) === 0)) {
        landed = true;
        expect(of(e, 'hurt').filter((h) => h.player === 'p1').length).toBe(0);
      }
    }
    expect(landed).toBe(true);
    // Out in the open, the same Hymn lands.
    sim.setCover([]);
    let hit = false;
    for (let i = 0; i < 300 && !hit; i++) {
      const e = sim.step(0.05);
      if (of(e, 'boss').some((b) => b.kind === 'hymn' && (b.ms ?? 0) === 0)) hit = of(e, 'hurt').some((h) => h.player === 'p1');
    }
    expect(hit).toBe(true);
    expect(CONGREGATION.hymn.windupMs).toBeGreaterThan(1500);
  });
});
