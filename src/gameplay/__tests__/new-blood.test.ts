import { describe, expect, it } from 'vitest';
import { Nav } from '../nav';
import { mulberry32 } from '../rng';
import { WorldSim } from '../sim/WorldSim';
import type { Intent, SimEvent } from '../sim/types';
import { Player } from '../Player';
import { makeSnapshot } from '../sim/snapshot';

function room() {
  const sim = new WorldSim(new Nav(), mulberry32(5));
  sim.setPlayer({ id: 'p1', x: 0, z: -16, alive: true, area: 'graves' });
  return sim;
}
function sig(sim: WorldSim, name: Extract<Intent, { t: 'signature' }>['sig'], x = 1, z = -16, sp = 30) {
  sim.apply({ t: 'signature', by: 'p1', sig: name, x, z, dx: x, dz: z + 16, sp });
  return sim.drain();
}
const events = <T extends SimEvent['t']>(ev: SimEvent[], t: T) => ev.filter((e): e is Extract<SimEvent, { t: T }> => e.t === t);

describe('new blood host rites', () => {
  it('burns at most three real corpses and grants oil only for consumed bodies', () => {
    const sim = room();
    for (let x = 1; x <= 4; x++) sim.addCorpse(x, -16, 'normal', 'robber', false, 0, 1, 'graves');
    sim.drain();
    const first = sig(sim, 'burn_the_dead', 2, -16);
    expect(events(first, 'corpseGone')).toHaveLength(3);
    expect(events(first, 'newBlood').at(-1)).toMatchObject({ ok: true, amount: 60 });
    expect([...sim.zones.values()].filter((z) => z.kind === 'warden_fire')).toHaveLength(3);
    expect(sig(sim, 'burn_the_dead', 2, -16).find((e) => e.t === 'newBlood')).toMatchObject({ ok: true, amount: 20 });
    expect(sig(sim, 'burn_the_dead', 2, -16).find((e) => e.t === 'newBlood')).toMatchObject({ ok: false });
  });

  it("Watchman's Ward slows movement by 25% and marks the enemy slowed in snapshots", () => {
    const baseline = room();
    const warded = room();
    const baseEnemy = baseline.spawnEnemy('robber', 'graves', 5, -16, false, false);
    const wardEnemy = warded.spawnEnemy('robber', 'graves', 5, -16, false, false);
    baseline.drain(); warded.drain();
    sig(warded, 'watchmans_ward', 0, -16);
    baseline.step(0.1); warded.step(0.1);
    const baseTravel = 5 - baseEnemy.x;
    const wardTravel = 5 - wardEnemy.x;
    expect(baseTravel).toBeGreaterThan(0);
    expect(wardTravel / baseTravel).toBeCloseTo(0.75, 3);
    const row = makeSnapshot(warded, true).enemies.find((enemy) => enemy[0] === wardEnemy.id)!;
    expect(row[8] & 4).toBe(4);
  });

  it('sounds corpses, marks three Knell beats, and interrupts nearby casters', () => {
    const sim = room();
    const c = sim.addCorpse(1, -16, 'normal', 'robber', false, 0, 1, 'graves')!;
    sim.drain();
    sig(sim, 'sound_the_corpse');
    expect(c.kind).toBe('resonant');
    const e = sim.spawnEnemy('robber', 'graves', 2, -16, false);
    e.state = 'channel';
    sig(sim, 'toll', 0, -16, 2);
    expect(e.state).toBe('recover');
    sig(sim, 'knell', 2, -16);
    expect(e.knellBeats).toBe(3);
    expect(e.knellDamage).toBeGreaterThan(0);
  });

  it('harvests once and leaves three ally healing charms after Butcher', () => {
    const sim = room();
    sim.addCorpse(1, -16, 'normal', 'robber', false, 0, 1, 'graves');
    sim.drain();
    expect(events(sig(sim, 'harvest'), 'newBlood').at(-1)).toMatchObject({ ok: true, amount: 30 });
    expect(events(sig(sim, 'harvest'), 'newBlood').at(-1)).toMatchObject({ ok: false });
    sim.addCorpse(1, -16, 'normal', 'robber', false, 0, 1, 'graves');
    sim.drain(); sig(sim, 'butcher');
    expect([...sim.zones.values()].filter((z) => z.kind === 'witch_charm')).toHaveLength(3);
  });

  it('creates an echo on death, only Crossing uses an echo, and Echo expires', () => {
    const sim = room();
    sim.setPlayer({ id: 'p1', x: 0, z: -16, alive: true, area: 'graves', family: 'veil' });
    const e = sim.spawnEnemy('robber', 'graves', 2, -16, false);
    e.hp = 1; e.state = 'move';
    sim.drain();
    sim.apply({ t: 'hit', by: 'p1', ids: [e.id], dmg: 10 });
    sim.step(0.01);
    const echo = [...sim.corpses.values()].find((c) => c.echoOwner === '*')!;
    expect(echo).toBeDefined();
    expect(events(sig(sim, 'crossing', echo.x, echo.z), 'newBlood').at(-1)).toMatchObject({ ok: true });
    expect(events(sig(sim, 'echo', echo.x, echo.z), 'newBlood').at(-1)).toMatchObject({ ok: true });
    expect([...sim.thralls.values()].some((t) => t.echoUntil != null)).toBe(true);
  });

  it('Echo spends an eligible echo corpse, never a real or another player\'s echo', () => {
    const sim = room();
    sim.setPlayer({ id: 'p1', x: 0, z: -16, alive: true, area: 'graves', family: 'veil' });
    const real = sim.addCorpse(1, -16, 'normal', 'robber', false, 0, 1, 'graves')!;
    sim.drain();
    expect(events(sig(sim, 'echo'), 'newBlood').at(-1)).toMatchObject({ ok: false });
    expect(sim.corpses.has(real.id)).toBe(true);
    const foreign = sim.addCorpse(1, -16, 'normal', 'robber', false, 0, 1, 'graves')!;
    foreign.echoOwner = 'p2';
    sim.drain();
    expect(events(sig(sim, 'echo'), 'newBlood').at(-1)).toMatchObject({ ok: false });
    foreign.echoOwner = 'p1';
    expect(events(sig(sim, 'echo'), 'newBlood').at(-1)).toMatchObject({ ok: true });
    expect(sim.corpses.has(real.id)).toBe(true);
    expect(sim.corpses.has(foreign.id)).toBe(false);
  });
});

describe('family resources', () => {
  const stats = { level: 12, maxHp: 100, spellPower: 20, maxEssence: 150, essenceRegen: 5, moveSpeed: 5.4,
    thrallHp: 45, thrallDamage: 8, damageBonusPct: 0 };
  it('refills Oil, decays Resonance after idle, and drains Veil in form', () => {
    const nav = new Nav();
    const warden = new Player(stats, nav, 'warden'); warden.resource.value = 0;
    warden.update(1, 1000, null); expect(warden.resource.value).toBe(3);
    const monk = new Player(stats, nav, 'monk'); monk.resource.value = 50;
    monk.update(1, 3000, null); expect(monk.resource.value).toBe(45);
    const veil = new Player(stats, nav, 'veil'); veil.resource.value = 30; veil.veilForm = true;
    veil.update(1, 1000, null); expect(veil.resource.value).toBe(18);
    expect(veil.takeDamage(20, 0, 1000, undefined, 'melee')).toBe(0);
    expect(veil.takeDamage(20, 0, 1000, undefined, 'toxic')).toBeGreaterThan(0);
  });
});
