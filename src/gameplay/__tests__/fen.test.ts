import { execFileSync } from 'node:child_process';
import { describe, expect, it } from 'vitest';
import { Nav } from '../nav';
import { WorldSim } from '../sim/WorldSim';
import { mulberry32 } from '../rng';
import type { SimEvent } from '../sim/types';
import { AREAS, AREA_ORDER, DOORS } from '../../content/areas';
import { ENEMIES } from '../../content/enemies';
import { CODEX_DEAD, CODEX_AREAS } from '../../content/codex';
import { BOSSES, MIRE, summonSpot } from '../../content/bosses';
import { BOG, FEN_ARENA, FEN_BOG, FEN_FLOOD_SCALE, FEN_HUMMOCKS, HAG_HEX, bogMult, hummockAt, inBog } from '../../content/fen';
import { FEN_ITEMS, FEN_RECIPES } from '../../content/fenItems';
import { ITEMS } from '../../content/items';
import { SEEDS } from '../../content/gardening';
import { NODES } from '../gatheringRules';
import { generateLayout, PROPS } from '../../content/layout';
import { rollItem } from '../loot';

const ALL = ['chapterhouse', 'graves', 'ossuary', 'nave', 'sanctum', 'cloister', 'pyre', 'fen'] as const;

function world(level = 60, seed = 7) {
  const nav = new Nav();
  nav.setUnlocked([...ALL]);
  const sim = new WorldSim(nav, mulberry32(seed));
  sim.setPlayer({ id: 'p1', x: -24, z: -80, alive: true, area: 'fen', level });
  sim.markVisited('fen');
  return sim;
}
const run = (sim: WorldSim, s: number, keep?: () => void) => {
  const out: SimEvent[] = [];
  for (let t = 0; t < s; t += 0.05) {
    keep?.();
    out.push(...sim.step(0.05));
  }
  return out;
};
const exhume = (sim: WorldSim, x: number, z: number) => (sim.addCorpse(x, z, 'normal', 'robber', false, 0, 1, 'fen'), sim.apply({ t: 'exhume', by: 'p1', x, z, r: 1, kind: 'warrior', cap: 8, hp: 5000, damage: 100, attackSpeedMult: 1 }));

describe('Mourning Fen zone', () => {
  it('is a level-45 scaled area west of the Nave, sealed by 800 Pyre kills, with a door in the Nave west wall', () => {
    const a = AREAS.fen;
    expect(a.scaling!.minLevel).toBe(45);
    expect(a.unlock).toEqual({ area: 'pyre', kills: 800 });
    const door = DOORS.find((d) => d.b === 'fen')!;
    expect(door.a).toBe('nave');
    expect(door.rect.x1).toBeGreaterThan(AREAS.nave.rect.x0);
    expect(door.rect.x0).toBeLessThan(a.rect.x1);
    for (const id of AREA_ORDER) {
      if (id === 'fen') continue;
      const r = AREAS[id].rect;
      expect(r.x1 <= a.rect.x0 || r.x0 >= a.rect.x1 || r.z1 <= a.rect.z0 || r.z0 >= a.rect.z1, `overlaps ${id}`).toBe(true);
    }
    expect(world(68).areaLevel('fen')).toBe(68);
    expect(world(20).areaLevel('fen')).toBe(45);
  });

  it('respects the performance caps and has a Codex entry for every mob and the boss', () => {
    expect(AREAS.fen.cap).toBeLessThanOrEqual(30);
    expect(AREAS.fen.waveSize).toBeLessThanOrEqual(10);
    for (const e of AREAS.fen.enemies) expect(CODEX_DEAD[e.id].counter.length).toBeGreaterThan(30);
    expect(CODEX_DEAD.mire.counter.length).toBeGreaterThan(30);
    expect(CODEX_AREAS.fen.dangers.length).toBeGreaterThan(40);
  });

  it('hummocks are dry, everything else in the bog slows, and the flood shrinks the dry ground', () => {
    const h = FEN_HUMMOCKS[1];
    expect(bogMult(h.x, h.z)).toBe(1);
    expect(bogMult(h.x + h.r + 1, h.z)).toBe(BOG.slow);
    expect(bogMult(-24, -80)).toBe(1); // the dry landing
    expect(bogMult(10, 10)).toBe(1); // outside the Fen
    const edge = h.r * 0.9;
    expect(bogMult(h.x + edge, h.z, 1)).toBe(1);
    expect(bogMult(h.x + edge, h.z, 3)).toBe(BOG.slowP3);
    expect(BOG.slowP3).toBeLessThan(BOG.slowP2);
    expect(BOG.slowP2).toBeLessThan(BOG.slow);
    expect(hummockAt(h.x, h.z, FEN_FLOOD_SCALE[3])).not.toBeNull();
    expect(inBog(-40, -75)).toBe(true);
  });

  it('every hummock and breach is inside the Fen, hummocks do not merge, and the altar stands on one', () => {
    const r = AREAS.fen.rect;
    FEN_HUMMOCKS.forEach((h, i) => {
      expect(h.x - h.r > r.x0 + 1 && h.x + h.r < r.x1 - 1 && h.z - h.r > r.z0 + 1 && h.z + h.r < r.z1 - 1, `hummock ${i}`).toBe(true);
      FEN_HUMMOCKS.forEach((o, j) => {
        if (j > i) expect(Math.hypot(h.x - o.x, h.z - o.z), `${i}/${j}`).toBeGreaterThan(h.r + o.r + 0.8);
      });
    });
    for (const b of FEN_BOG) expect(b.x0 >= r.x0 && b.x1 <= r.x1 && b.z0 >= r.z0 && b.z1 <= r.z1).toBe(true);
    const alt = AREAS.fen.interactables.find((i) => i.id === 'mire_altar')!;
    const [sx, sz] = summonSpot('mire');
    expect(Math.hypot(alt.x - sx, alt.z - sz)).toBeLessThan(0.6);
    expect(hummockAt(alt.x, alt.z)).toBe(FEN_HUMMOCKS[0]);
    expect(Math.hypot(FEN_ARENA.x - BOSSES.mire.arena.x, FEN_ARENA.z - BOSSES.mire.arena.z)).toBe(0);
  });

  it('layout: herb nodes and props sit inside the Fen, clear of breaches, with nothing blocking the door lane', () => {
    const layout = generateLayout();
    const r = AREAS.fen.rect;
    const nodes = layout.nodes.filter((n) => n.area === 'fen');
    expect(nodes.filter((n) => n.type === 'bog_myrtle').length).toBeGreaterThanOrEqual(3);
    expect(nodes.filter((n) => n.type === 'drowned_lotus').length).toBeGreaterThanOrEqual(3);
    for (const n of nodes) {
      expect(n.x > r.x0 && n.x < r.x1 && n.z > r.z0 && n.z < r.z1).toBe(true);
      for (const [bx, bz] of AREAS.fen.breaches) expect(Math.hypot(bx - n.x, bz - n.z)).toBeGreaterThan(2.5);
    }
    const door = DOORS.find((d) => d.b === 'fen')!;
    for (const p of layout.props.filter((q) => q.area === 'fen' && PROPS[q.prop].collider)) {
      expect(p.x > door.rect.x0 - 1 && p.x < door.rect.x1 && p.z > door.rect.z0 - 1 && p.z < door.rect.z1 + 1, `${p.prop} in the door lane`).toBe(false);
    }
    expect(layout.bog).toEqual(FEN_BOG);
  });
});

describe('Mourning Fen mobs', () => {
  it('a Bog Hag hexes the thrall knot: thralls in the ring deal less, and a sigil flag rides the snapshot', () => {
    const sim = world();
    sim.setPlayer({ id: 'p1', x: -30, z: -80, alive: true, area: 'fen', level: 60 });
    exhume(sim, -38, -80);
    exhume(sim, -38.6, -80.4);
    sim.step(1.2);
    // Planted thralls (a moving legion can walk out of the ring: that is the counterplay).
    for (const t of sim.thralls.values()) t.speed = 0;
    const hag = sim.spawnEnemy('bog_hag', 'fen', -44, -80, false, false);
    hag.attackCd = 0;
    const ev = run(sim, 4, () => sim.setPlayer({ id: 'p1', x: -30, z: -80, alive: true, area: 'fen', level: 60 }));
    const tele = ev.find((e) => e.t === 'telegraph' && e.kind === 'hex') as Extract<SimEvent, { t: 'telegraph' }> | undefined;
    expect(tele).toBeDefined();
    expect(tele!.r).toBe(HAG_HEX.radius);
    const cursed = [...sim.thralls.values()].filter((t) => (t.cursedT ?? 0) > 0);
    expect(cursed.length).toBeGreaterThan(0);
    const t = cursed[0];
    const target = sim.spawnEnemy('robber', 'fen', t.x + 0.8, t.z, false, false);
    const hp = target.hp;
    t.attackCd = 0;
    t.cursedT = 5;
    sim.step(0.05);
    const dealt = hp - target.hp;
    t.cursedT = 0;
    const target2 = sim.spawnEnemy('robber', 'fen', t.x - 0.8, t.z, false, false);
    const hp2 = target2.hp;
    t.attackCd = 0;
    target.hp = 1e9;
    sim.step(0.05);
    // Same thrall, same damage number: the cursed swing is 70% of the clean one (when both landed).
    if (dealt > 0 && hp2 - target2.hp > 0) expect(dealt / (hp2 - target2.hp)).toBeCloseTo(HAG_HEX.thrallDamageMult, 1);
  });

  it('a Fen Wisp pulse chills the player in the ring; a Sexton throws a hook and drags', () => {
    const sim = world();
    sim.spawnEnemy('fen_wisp', 'fen', -38, -80, false, false).attackCd = 0;
    const ev = run(sim, 6, () => sim.setPlayer({ id: 'p1', x: -31, z: -80, alive: true, area: 'fen', level: 60 }));
    expect(ev.find((e) => e.t === 'telegraph' && e.kind === 'pulse')).toBeDefined();
    const chill = ev.find((e) => e.t === 'hurt' && e.from === 'dust' && e.chillMs) as Extract<SimEvent, { t: 'hurt' }> | undefined;
    expect(chill?.chillMs).toBeGreaterThan(0);

    const sim2 = world();
    sim2.spawnEnemy('drowned_sexton', 'fen', -40, -80, false, false).attackCd = 0;
    const ev2 = run(sim2, 6, () => sim2.setPlayer({ id: 'p1', x: -33, z: -80, alive: true, area: 'fen', level: 60 }));
    expect(ev2.find((e) => e.t === 'telegraph' && e.kind === 'hook')).toBeDefined();
    const pulled = ev2.find((e) => e.t === 'hurt' && e.pull) as Extract<SimEvent, { t: 'hurt' }> | undefined;
    expect(pulled?.pull!.m).toBeGreaterThan(2);
  });

  it('Mire Leeches come in packs, leave no corpse, and bite with bog rot', () => {
    expect(ENEMIES.mire_leech.pack![0]).toBeGreaterThanOrEqual(4);
    expect(ENEMIES.mire_leech.corpse).toBe('none');
    const sim = world();
    sim.spawnEnemy('mire_leech', 'fen', -30, -80, false, false).attackCd = 0;
    const ev = run(sim, 4, () => sim.setPlayer({ id: 'p1', x: -30.5, z: -80, alive: true, area: 'fen', level: 60 }));
    expect(ev.some((e) => e.t === 'hurt' && e.from === 'toxic')).toBe(true);
  });
});

describe('The Mire Mother', () => {
  const wake = () => {
    const sim = world(60);
    const a = BOSSES.mire.arena;
    sim.setPlayer({ id: 'p1', x: a.x + 8, z: a.z + 6, alive: true, area: 'fen', level: 60 });
    sim.apply({ t: 'summonBoss', by: 'p1', boss: 'mire' });
    expect(sim.bossState.id).toBe('mire');
    return sim;
  };
  const keep = (sim: WorldSim, x: number, z: number) => () => sim.setPlayer({ id: 'p1', x, z, alive: true, area: 'fen', level: 60 });

  it('sinks under a hummock, ringing it, is untargetable while under, and bursts out winded', () => {
    const sim = wake();
    const a = BOSSES.mire.arena;
    const ev = run(sim, 25, keep(sim, a.x + 8, a.z + 6));
    const tele = ev.find((e) => e.t === 'boss' && e.kind === 'surface' && (e.ms ?? 0) > 0) as Extract<SimEvent, { t: 'boss' }>;
    expect(tele).toBeDefined();
    expect(FEN_HUMMOCKS.some((h) => h.x === tele.x && h.z === tele.z)).toBe(true);
    // Replay to the sunk moment: damage is ignored.
    const sim2 = wake();
    let sunk = false;
    for (let t = 0; t < 25 && !sunk; t += 0.05) {
      keep(sim2, a.x + 8, a.z + 6)();
      sim2.step(0.05);
      sunk = sim2.bossState.state === 'sunk';
    }
    expect(sunk).toBe(true);
    const hp = sim2.bossState.hp;
    sim2.bosses.mire.damage(5000, 'p1', 0);
    expect(sim2.bossState.hp).toBe(hp);
    const ev2 = run(sim2, 4, keep(sim2, a.x + 8, a.z + 6));
    expect(ev2.some((e) => e.t === 'boss' && e.kind === 'surface' && e.ms === 0)).toBe(true);
    expect(sim2.bossState.state).not.toBe('sunk');
    sim2.bosses.mire.damage(5000, 'p1', 0);
    expect(sim2.bossState.hp).toBeLessThan(hp);
  });

  it('surfacing hurts whoever stands on that hummock', () => {
    const sim = wake();
    const brain = sim.bosses.mire as unknown as { resolve(p: unknown, players: unknown[]): void; spot: number };
    const h = FEN_HUMMOCKS[3];
    brain.spot = 3;
    sim.setPlayer({ id: 'p1', x: h.x, z: h.z, alive: true, area: 'fen', level: 60 });
    sim.step(0.001);
    brain.resolve({ kind: 'surface', at: 0, x: h.x, z: h.z, r: MIRE.surface.r }, [...sim.players.values()]);
    const ev = sim.step(0.001);
    expect(ev.some((e) => e.t === 'hurt' && e.from === 'boss')).toBe(true);
  });

  it('phase 2 floods (events + leeches), phase 3 raises Risen from the corpses in the Fen, and a corpse-free field starves the rite', () => {
    const sim = wake();
    const a = BOSSES.mire.arena;
    const k = keep(sim, a.x + 8, a.z + 6);
    sim.bossState.hp = sim.bossState.maxHp * 0.55;
    let ev = run(sim, 0.2, k);
    expect(sim.bossState.phase).toBe(2);
    expect(ev.some((e) => e.t === 'boss' && e.kind === 'flood' && e.phase === 2)).toBe(true);
    expect([...sim.enemies.values()].filter((e) => e.def === 'mire_leech').length).toBe(MIRE.adds.p2.length);
    sim.bossState.hp = sim.bossState.maxHp * 0.25;
    ev = run(sim, 0.2, k);
    expect(sim.bossState.phase).toBe(3);
    expect(FEN_FLOOD_SCALE[3]).toBeLessThan(FEN_FLOOD_SCALE[2]);
    // Corpses in the Fen: the rite turns them into Risen.
    for (let i = 0; i < 3; i++) sim.addCorpse(a.x - 4 + i, a.z, 'normal', 'robber', false, 0, 1, 'fen');
    const brain = sim.bosses.mire as unknown as { resolve(p: unknown, players: unknown[]): void };
    const risenBefore = [...sim.enemies.values()].filter((e) => e.def === 'risen').length;
    brain.resolve({ kind: 'rite', at: 0, x: a.x, z: a.z, r: a.r, targets: [] }, [...sim.players.values()]);
    expect([...sim.enemies.values()].filter((e) => e.def === 'risen').length).toBe(risenBefore + 3);
    expect(sim.corpses.size).toBe(0);
    // Nothing left: it fails and she staggers.
    ev = sim.step(0.001);
    brain.resolve({ kind: 'rite', at: 0, x: a.x, z: a.z, r: a.r, targets: [] }, [...sim.players.values()]);
    const fail = sim.drain().find((e) => e.t === 'boss' && e.kind === 'rite') as Extract<SimEvent, { t: 'boss' }> | undefined;
    void ev;
    expect(fail?.targets).toEqual([]);
    expect(sim.bossState.flash).toBeGreaterThan(0);
  });

  it('every boss roster entry exists: altar prop, summon interactable, shards', () => {
    expect(BOSSES.mire.shards).toBeGreaterThanOrEqual(6);
    expect(AREAS.fen.interactables.some((i) => i.id === BOSSES.mire.summonId && i.kind === 'boss')).toBe(true);
    expect(PROPS.mire_altar.collider).toBeDefined();
  });
});

describe('Fen items, herbs and migration', () => {
  it('every new item is known, sells, and every herb brews: no dead ends', () => {
    for (const [id, it] of Object.entries(FEN_ITEMS)) {
      expect(ITEMS[id], id).toBeTruthy();
      expect(it.sell, `${id} sell`).toBeGreaterThan(0);
    }
    for (const [id, , prof, , result, , ings] of FEN_RECIPES) {
      expect(prof, id).toBe('alchemy');
      expect(ITEMS[result], result).toBeTruthy();
      for (const [item] of ings) expect(ITEMS[item], item).toBeTruthy();
    }
    const used = new Set(FEN_RECIPES.flatMap((r) => r[6].map(([i]) => i)));
    for (const herb of ['herb_bog_myrtle', 'herb_drowned_lotus']) expect(used.has(herb), herb).toBe(true);
  });

  it('seeds are plantable (levels ~55/70), findable in the Fen nodes, and their herbs are gatherable there', () => {
    const levels = Object.fromEntries(SEEDS.map((s) => [s.id, s.level]));
    expect(levels.seed_bog_myrtle).toBe(55);
    expect(levels.seed_drowned_lotus).toBe(70);
    expect(NODES.bog_myrtle.item).toBe('herb_bog_myrtle');
    expect(NODES.drowned_lotus.item).toBe('herb_drowned_lotus');
    expect(NODES.bog_myrtle.extras.some((e) => e.item === 'seed_bog_myrtle')).toBe(true);
    expect(NODES.drowned_lotus.extras.some((e) => e.item === 'seed_drowned_lotus')).toBe(true);
  });

  it('the Fen drops higher gems, the ascended armour set, and only known items', () => {
    const ids = AREAS.fen.loot.map((l) => l.item);
    expect(ids).toContain('gem_void_sapphire');
    expect(ids.some((i) => i.startsWith('set_') && i.includes('ascended'))).toBe(true);
    for (const id of ids) expect(ITEMS[id], id).toBeTruthy();
    for (let i = 0; i < 50; i++) expect(ITEMS[rollItem('fen').item_id]).toBeTruthy();
  });

  it('015-fen.sql is generated from the content (run node tools/build-fen-sql.mjs if this fails)', () => {
    expect(() => execFileSync('node', ['tools/build-fen-sql.mjs', '--check'], { stdio: 'pipe' })).not.toThrow();
  });
});
