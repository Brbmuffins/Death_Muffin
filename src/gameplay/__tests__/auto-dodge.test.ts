import { describe, expect, it } from 'vitest';
import { Nav } from '../nav';
import { WorldSim } from '../sim/WorldSim';
import { mulberry32 } from '../rng';
import type { BossState, Enemy, SimEvent } from '../sim/types';
import { BOSSES, ABBESS, CONGREGATION, GRAVEDIGGER, MIRE, REGENT, SAINT, type BossId } from '../../../server/rules/content/bosses';
import { AREAS } from '../../../server/rules/content/areas';
import { BossTelegraphs, dodgeStep, hazardsFromBossEvent, inHazard, nearestSafePoint, poolHazard, stepIntoHazard, type DodgeMemory, type Hazard } from '../autoDodge';
import { selectAutoCombatMovement, type AutoMoveMemory } from '../autoCombat';

type BossEvent = Extract<SimEvent, { t: 'boss' }>;
const bossEv = (e: Partial<BossEvent> & { kind: BossEvent['kind']; x: number; z: number }): BossEvent => ({ phase: 1, ms: 1000, ...e }) as BossEvent;

// --- The shapes are the host's hit tests ------------------------------------------------------------------------------

/**
 * Wake the real brain, ask it for one telegraph, and drop a ring of bystanders around its centre. Whoever the brain hurts when the blow
 * lands must be exactly who `inHazard` says is inside the shape built from the event the brain emitted.
 */
function agree(id: BossId, kind: string, r: number, extra: { dir?: number; targets?: [number, number][] } = {}, cx?: number, cz?: number, phase = 1) {
  const nav = new Nav();
  nav.setUnlocked(['chapterhouse', 'graves', 'ossuary', 'nave', 'sanctum', 'cloister', 'pyre', 'fen']);
  const sim = new WorldSim(nav, mulberry32(7));
  const def = BOSSES[id];
  const spots: { id: string; x: number; z: number }[] = [];
  const ox = cx ?? def.arena.x;
  const oz = cz ?? def.arena.z;
  for (let gx = -9; gx <= 9; gx += 0.55) {
    for (let gz = -9; gz <= 9; gz += 0.55) {
      const x = ox + gx + 0.013;
      const z = oz + gz + 0.021;
      if (Math.hypot(x - def.arena.x, z - def.arena.z) < def.arena.r - 0.3) spots.push({ id: `p${spots.length}`, x, z });
    }
  }
  for (const s of spots) sim.setPlayer({ ...s, alive: true, area: def.area });
  sim.step(0.05);
  sim.apply({ t: 'summonBoss', by: 'p0', boss: id });
  const brain = (sim as unknown as { bosses: Record<string, { state: BossState; pending: unknown[]; telegraph(...a: unknown[]): void }> }).bosses[id];
  brain.state.phase = phase as BossState['phase'];
  brain.state.hp = brain.state.maxHp = 1e12;
  brain.pending = [];
  if (cx !== undefined) {
    brain.state.x = cx;
    brain.state.z = cz!;
  }
  brain.telegraph(kind, brain.state.x, brain.state.z, r, 300, extra);
  let tele: BossEvent | null = null;
  const hurt = new Set<string>();
  for (let i = 0; i < 12; i++) {
    for (const ev of sim.step(0.05)) {
      if (ev.t === 'boss' && ev.kind === kind && (ev.ms ?? 0) > 0 && !tele) tele = ev;
      if (ev.t === 'hurt' && tele) hurt.add(ev.player);
    }
  }
  expect(tele, `${id} ${kind} telegraph`).toBeTruthy();
  // The telegraph went out in the first step; its blow lands within the 12 steps.
  const hazards = hazardsFromBossEvent({ ...tele!, ms: 300 }, 0);
  expect(hazards.length, `${id} ${kind}`).toBeGreaterThan(0);
  let wrong = 0;
  let inside = 0;
  for (const s of spots) {
    const predicted = hazards.some((h) => inHazard(h, s.x, s.z, 0));
    if (predicted) inside++;
    if (predicted !== hurt.has(s.id)) wrong++;
  }
  return { wrong, inside, total: spots.length };
}

describe('autoDodge shapes match BossBrain.resolve', () => {
  const cases: [BossId, string, number, { dir?: number; targets?: [number, number][] }, number?][] = [
    ['prelate', 'toll', 6.5, {}],
    ['prelate', 'slam', 2.6, {}],
    ['gravedigger', 'sweep', GRAVEDIGGER.sweep.r, { dir: 0.7 }],
    ['gravedigger', 'bury', GRAVEDIGGER.burial.hd, { targets: [[1, 4], [-3, 2]] }],
    ['abbess', 'lance', ABBESS.lance.len, { dir: 2.1 }],
    ['abbess', 'chorus', ABBESS.chorus.len, { dir: 0.3 }],
    ['abbess', 'grasp', ABBESS.grasp.r, { dir: -1.2 }],
    ['congregation', 'hymn', CONGREGATION.hymn.reach, { dir: 1.1 }],
    ['congregation', 'maul', CONGREGATION.melee.r, { dir: -2.0 }],
    ['congregation', 'grasp', CONGREGATION.grasp.r, { targets: [[0, 0], [3, 2]] }],
    ['saint', 'rotRain', SAINT.rain.r, { targets: [[1, 1], [-3, 2]] }],
    ['saint', 'swing', SAINT.swing.r, { dir: 0.2 }],
    ['regent', 'coals', REGENT.coals.r, { targets: [[2, 1], [-2, -3]] }],
    ['regent', 'cleave', REGENT.cleave.r, { dir: 2.6 }],
    ['mire', 'hands', MIRE.hands.r, { targets: [[1, 2], [-3, -1]] }],
    ['mire', 'maul', MIRE.maul.r, { dir: 1.5 }],
  ];
  for (const [id, kind, r, extra] of cases) {
    it(`${id} ${kind}: who is hurt is who the shape says`, () => {
      // Targets are offsets from the arena centre in the table; make them absolute.
      const c = BOSSES[id].arena;
      const targets = extra.targets?.map(([x, z]) => [c.x + x, c.z + z] as [number, number]);
      const res = agree(id, kind, r, { ...extra, ...(targets ? { targets } : {}) });
      expect(res.inside).toBeGreaterThan(0);
      expect(res.inside).toBeLessThan(res.total);
      // Grid points exactly on an edge may differ by float noise; none do at this spacing.
      expect(res.wrong).toBe(0);
    });
  }
});

// --- Geometry ---------------------------------------------------------------------------------------------------------

describe('inHazard margins', () => {
  it('a cone widens by the margin and keeps its apex covered', () => {
    const h: Hazard = { k: 'cone', x: 0, z: 0, dir: 0, r: 10, half: Math.PI / 6, until: 1 };
    expect(inHazard(h, 0, 5)).toBe(true);
    expect(inHazard(h, 5, 5)).toBe(false); // 45 degrees off
    expect(inHazard(h, 5, 5, 3)).toBe(true);
    expect(inHazard(h, 0, -0.2, 0.5)).toBe(true);
    expect(inHazard(h, 0, 10.4)).toBe(false);
    expect(inHazard(h, 0, 10.4, 0.5)).toBe(true);
  });
  it('Conflagration burns everywhere inside the arena except on an ash circle', () => {
    const h: Hazard = { k: 'except', x: 0, z: 0, r: 11.5, spots: [[4, 0]], safeR: 2.7, until: 1 };
    expect(inHazard(h, -4, 0)).toBe(true);
    expect(inHazard(h, 4, 0)).toBe(false);
    expect(inHazard(h, 4 + 2.5, 0, 0.5)).toBe(true); // too near the circle's edge for comfort
    expect(inHazard(h, 20, 0)).toBe(false); // outside the arena nothing burns
  });
});

// --- Choosing where to stand ------------------------------------------------------------------------------------------

describe('dodgeStep', () => {
  const ring: Hazard = { k: 'circle', x: 0, z: 0, r: 3, until: 1e9 };
  it('does nothing when there is nothing to leave, or when already clear', () => {
    expect(dodgeStep({ x: 0, z: 0 }, [], undefined, 0)).toBeNull();
    expect(dodgeStep({ x: 8, z: 0 }, [ring], undefined, 0)).toBeNull();
  });
  it('steps out of a ring by the shortest way', () => {
    const d = dodgeStep({ x: 1, z: 0.2 }, [ring], undefined, 0)!;
    expect(d.x).toBeGreaterThan(0.9); // nearest edge is east
    const goal = nearestSafePoint({ x: 1, z: 0.2 }, [ring])!;
    expect(Math.hypot(goal.x, goal.z)).toBeGreaterThan(3.75 - 0.01);
    expect(Math.hypot(goal.x - 1, goal.z - 0.2)).toBeLessThan(3.6); // about the shortest way out (2.8 m plus the standing room)
  });
  it('leaves a cone sideways, not the length of it', () => {
    const cone: Hazard = { k: 'cone', x: 0, z: 0, dir: 0, r: 15, half: (60 * Math.PI) / 180, until: 1e9 };
    const goal = nearestSafePoint({ x: 0, z: 8 }, [cone])!;
    expect(Math.hypot(goal.x - 0, goal.z - 8)).toBeLessThan(10);
    expect(inHazard(cone, goal.x, goal.z, 0.7)).toBe(false);
  });
  it('commits to its exit: two equally near ways out never make it wobble', () => {
    const mem: DodgeMemory = {};
    const p = { x: 0, z: 0 }; // dead centre: every exit is equally near
    const first = dodgeStep(p, [ring], mem, 0)!;
    const goal = { ...mem.goal! };
    // Walk it for a second of game time; every step keeps the same goal and heads for it.
    let t = 0;
    let steps = 0;
    while (steps++ < 200) {
      t += 16;
      const d = dodgeStep(p, [ring], mem, t);
      if (!d) break;
      expect(mem.goal!.x).toBe(goal.x);
      expect(mem.goal!.z).toBe(goal.z);
      expect(d.x * first.x + d.z * first.z).toBeGreaterThan(0.99);
      p.x += d.x * 0.09;
      p.z += d.z * 0.09;
    }
    expect(Math.hypot(p.x, p.z)).toBeGreaterThan(3.3); // out of the ring
    expect(dodgeStep(p, [ring], mem, t + 16)).toBeNull(); // and then it stops
  });
  it('re-plans when a new shape lands on its goal', () => {
    const mem: DodgeMemory = {};
    const p = { x: 0.5, z: 0 };
    dodgeStep(p, [ring], mem, 0);
    const g = { ...mem.goal! };
    const second: Hazard = { k: 'circle', x: g.x, z: g.z, r: 2, until: 1e9 };
    dodgeStep(p, [ring, second], mem, 16);
    expect(inHazard(second, mem.goal!.x, mem.goal!.z, 0.5)).toBe(false);
  });
  it('stays inside the area and will not pick a spot behind a wall', () => {
    const rect = { x0: -7, z0: -6, x1: 6, z1: 6 };
    const goal = nearestSafePoint({ x: 0, z: 0 }, [ring], { rect, nav: { clearLine: (_a, _b, x1) => x1 <= 0 || x1 > 5.5 } })!;
    expect(goal).toBeTruthy();
    expect(goal.x).toBeLessThanOrEqual(5); // inside the rect
    expect(goal.x <= 0 || goal.x > 5.5).toBe(true);
  });
  it('heads for an ash circle when Conflagration is winding up', () => {
    const h: Hazard = { k: 'except', x: 0, z: 0, r: 11.5, spots: [[-6, 2], [5, 5]], safeR: 2.7, until: 1e9 };
    const goal = nearestSafePoint({ x: 0, z: 0 }, [h])!;
    const onAsh = h.spots.some(([sx, sz]) => Math.hypot(goal.x - sx, goal.z - sz) <= 2.7 - 0.7);
    expect(onAsh).toBe(true);
    expect(Math.hypot(goal.x, goal.z)).toBeLessThan(6.5); // the nearest circle's edge, not its middle or the far one
  });
  it('never walks back into a telegraph, but may still attack from where it stands', () => {
    expect(stepIntoHazard({ x: 4.2, z: 0 }, { x: -1, z: 0 }, [ring])).toBe(true);
    expect(stepIntoHazard({ x: 9, z: 0 }, { x: -1, z: 0 }, [ring])).toBe(false);
    expect(stepIntoHazard({ x: 9, z: 0 }, { x: -1, z: 0 }, [])).toBe(false);
  });
});

// --- The tracker (the scene's feed) -----------------------------------------------------------------------------------

describe('BossTelegraphs', () => {
  it('records telegraphs, clears the one that landed (a second sweep at another angle stays) and expires stragglers', () => {
    const t = new BossTelegraphs();
    const a = bossEv({ boss: 'gravedigger', kind: 'sweep', x: 10, z: 5, r: 4.5, dir: 0.5, ms: 900 });
    const b = bossEv({ boss: 'gravedigger', kind: 'sweep', x: 10, z: 5, r: 4.5, dir: 0.5 + Math.PI / 3, ms: 1550 });
    t.onEvent(a, 0);
    t.onEvent(b, 0);
    expect(t.active(100)).toHaveLength(2);
    t.onEvent({ ...a, ms: 0 }, 900);
    expect(t.active(950)).toHaveLength(1);
    expect(t.active(950)[0].k === 'cone' && (t.active(950)[0] as { dir: number }).dir).toBeCloseTo(0.5 + Math.PI / 3, 6);
    expect(t.active(1550 + 2500 + 1)).toHaveLength(0);
  });
  it('keeps the open pits until the boss is gone', () => {
    const t = new BossTelegraphs();
    t.onEvent(bossEv({ boss: 'gravedigger', kind: 'pits', x: 0, z: 0, r: 1.2, ms: undefined, targets: [[1, 1], [5, 5]] }), 0);
    expect(t.active(1e7)).toHaveLength(2);
    t.onEvent(bossEv({ boss: 'gravedigger', kind: 'defeated', x: 0, z: 0, ms: undefined }), 5);
    expect(t.active(6)).toHaveLength(0);
  });
  it('ignores events that warn of nothing you can leave', () => {
    const t = new BossTelegraphs();
    for (const kind of ['summon', 'communion', 'link', 'rite', 'blessed', 'flood'] as const) t.onEvent(bossEv({ kind, x: 0, z: 0, ms: 2000, targets: [[1, 1]] }), 0);
    expect(t.active(1)).toHaveLength(0);
  });
});

// --- The movement ----------------------------------------------------------------------------------------------------

const foe = (id: number, x: number, z: number): Enemy => ({ id, x, z, hp: 10, maxHp: 10, radius: 0.4, state: 'move', area: 'nave' }) as Enemy;
describe('Easy auto movement with telegraphs', () => {
  const area = AREAS.nave.rect;
  const cx = (area.x0 + area.x1) / 2;
  const cz = (area.z0 + area.z1) / 2;
  const hymn = (dir: number): Hazard => ({ k: 'cone', x: cx, z: cz, dir, r: 15, half: (60 * Math.PI) / 180, until: 1e9 });
  const input = (p: { x: number; z: number }, hazards: Hazard[], enemies: Enemy[] = [], primaryRange?: number) =>
    ({ player: { x: p.x, z: p.z, area: 'nave' as const, essence: 100, maxEssence: 100 }, enemies, primary: 'bone_needle' as const, hazards, primaryRange });

  it('walks out of a hymn cone with no enemy near, and then holds still', () => {
    const mem: AutoMoveMemory = {};
    const p = { x: cx, z: cz + 6 };
    const cone = hymn(0);
    let now = 0;
    let moved = 0;
    for (let i = 0; i < 400; i++) {
      now += 16;
      const d = selectAutoCombatMovement(input(p, [cone]), mem, now, 0.016);
      if (!d) break;
      p.x += d.x * 5.4 * 0.016;
      p.z += d.z * 5.4 * 0.016;
      moved++;
    }
    expect(moved).toBeGreaterThan(3);
    expect(inHazard(cone, p.x, p.z, 0)).toBe(false);
    expect(moved * 0.016).toBeLessThan(1.6); // a cone is left sideways in about a second, not run the length of
  });

  it('does not oscillate at the edge: heading changes sign at most a handful of times over a whole dodge', () => {
    const mem: AutoMoveMemory = {};
    const p = { x: cx + 0.5, z: cz + 4 };
    const cone = hymn(0);
    let now = 0;
    let flips = 0;
    let last = 0;
    for (let i = 0; i < 300; i++) {
      now += 16;
      const d = selectAutoCombatMovement(input(p, [cone], [foe(1, cx, cz + 9)]), mem, now, 0.016);
      if (!d) continue;
      if (last && Math.sign(d.x) !== Math.sign(last) && Math.abs(d.x) > 0.2) flips++;
      last = d.x;
      p.x += d.x * 5.4 * 0.016;
      p.z += d.z * 5.4 * 0.016;
    }
    expect(flips).toBeLessThanOrEqual(1);
  });

  it('closing on a target stops at the telegraph and resumes once it has landed', () => {
    const ring: Hazard = { k: 'circle', x: cx, z: cz, r: 3, until: 1e9 };
    const p = { x: cx + 12, z: cz };
    const target = foe(1, cx, cz);
    const mem: AutoMoveMemory = {};
    let now = 0;
    for (let i = 0; i < 300; i++) {
      now += 16;
      const d = selectAutoCombatMovement(input(p, [ring], [target], 2), mem, now, 0.016);
      if (!d) break;
      p.x += d.x * 5.4 * 0.016;
      p.z += d.z * 5.4 * 0.016;
    }
    expect(inHazard(ring, p.x, p.z, 0)).toBe(false);
    expect(Math.hypot(p.x - cx, p.z - cz)).toBeLessThan(6.5); // it did close in, up to the ring
    // The blow lands: the ring is gone and the hero walks on.
    const d = selectAutoCombatMovement(input(p, [], [target], 2), mem, now + 16, 0.016);
    expect(d).not.toBeNull();
  });

  it('is unchanged without hazards (the ordinary engagement still runs)', () => {
    const mem: AutoMoveMemory = {};
    const d = selectAutoCombatMovement(input({ x: cx, z: cz }, [], [foe(1, cx + 12, cz)]), mem, 0, 0);
    expect(d).not.toBeNull();
    expect(d!.x).toBeGreaterThan(0.9);
  });

  it('a hostile pool is left like any other shape', () => {
    const pool = poolHazard({ x: cx, z: cz, r: 2 }, 0.45);
    expect(pool.k === 'circle' && pool.r).toBeCloseTo(2.45, 6);
    const d = selectAutoCombatMovement(input({ x: cx + 0.5, z: cz }, [pool]), {}, 0, 0);
    expect(d).not.toBeNull();
    expect(d!.x).toBeGreaterThan(0.9);
  });
});

// --- End to end: Easy auto against the real brains --------------------------------------------------------------------

/**
 * A hero who stands 5 m from the boss (Easy auto only fights what it can reach: it never walks up to a boss itself) for two minutes of
 * game time, with and without the dodge. Hits taken are counted from the brain's own `hurt` events; HP is not simulated (nobody dies),
 * so the numbers are the raw count of blows that would have landed.
 */
function standAgainst(id: BossId, seed: number, dodge: boolean, seconds = 90) {
  const nav = new Nav();
  nav.setUnlocked(['chapterhouse', 'graves', 'ossuary', 'nave', 'sanctum', 'cloister', 'pyre', 'fen']);
  const sim = new WorldSim(nav, mulberry32(seed));
  const def = BOSSES[id];
  const p = { x: def.arena.x + 5, z: def.arena.z, id: 'p1' };
  sim.setPlayer({ id: 'p1', x: p.x, z: p.z, alive: true, area: def.area });
  sim.step(0.05);
  sim.apply({ t: 'summonBoss', by: 'p1', boss: id });
  sim.boss.state.hp = sim.boss.state.maxHp = 1e12; // never dies: phases need hp; keep phase 1 and force 2 / 3 below
  const tele = new BossTelegraphs();
  const mem: AutoMoveMemory = {};
  const rect = AREAS[def.area].rect;
  let hits = 0;
  let now = 0;
  const dt = 0.05;
  for (let i = 0; i < seconds / dt; i++) {
    now += dt * 1000;
    // Walk the fight through its phases so every attack is seen: 1 for the first 30 s, 2 for the next 30, 3 for the rest.
    const want = now < 30000 ? 1 : now < 60000 ? 2 : 3;
    if (sim.boss.state.phase !== want) sim.boss.state.hp = sim.boss.state.maxHp * (want === 2 ? 0.5 : 0.2);
    for (const ev of sim.step(dt)) {
      if (ev.t === 'boss') tele.onEvent(ev, now);
      // The boss's own blows and the pools it (and its casters) leave; the adds' melee is not what a telegraph dodge is for.
      if (ev.t === 'hurt' && ev.player === 'p1' && (ev.from === 'boss' || ev.from === 'ember' || ev.from === 'burn' || (ev.from === 'toxic' && id !== 'mire'))) hits++; // (the Fen's toxic is a leech's bite, not a pool)
    }
    if (!dodge) continue;
    const hazards: Hazard[] = [...tele.active(now)];
    for (const z of sim.zones.values()) if (z.hostile && z.dps > 0) hazards.push(poolHazard(z, 0.45));
    const d = selectAutoCombatMovement({ player: { x: p.x, z: p.z, area: def.area, essence: 100, maxEssence: 100 }, enemies: [], primary: 'bone_needle', hazards }, mem, now, dt);
    if (d) {
      p.x = Math.min(rect.x1 - 1, Math.max(rect.x0 + 1, p.x + d.x * 5.4 * dt));
      p.z = Math.min(rect.z1 - 1, Math.max(rect.z0 + 1, p.z + d.z * 5.4 * dt));
      sim.setPlayer({ id: 'p1', x: p.x, z: p.z, alive: true, area: def.area });
    }
  }
  return hits;
}

describe('Easy auto against the real bosses (ninety game-seconds standing 5 m from the boss, blows taken)', () => {
  const rows: string[] = [];
  for (const id of ['prelate', 'gravedigger', 'abbess', 'congregation', 'saint', 'regent', 'mire'] as BossId[]) {
    it(`${id}: the dodge takes fewer blows than standing still`, () => {
      let still = 0;
      let dodged = 0;
      for (const seed of [1, 2]) {
        still += standAgainst(id, seed, false);
        dodged += standAgainst(id, seed, true);
      }
      rows.push(`${id.padEnd(13)} still ${String(still).padStart(3)}  dodging ${String(dodged).padStart(3)}`);
      console.log(`[easy-auto dodge] ${rows.at(-1)}`);
      expect(dodged).toBeLessThanOrEqual(still);
      if (still >= 6) expect(dodged).toBeLessThanOrEqual(Math.ceil(still * 0.25));
    });
  }
});
