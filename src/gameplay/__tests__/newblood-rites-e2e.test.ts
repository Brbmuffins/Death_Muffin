import * as THREE from 'three';
import { describe, expect, it, vi } from 'vitest';
import { Nav } from '../nav';
import { mulberry32 } from '../rng';
import { WorldSim } from '../sim/WorldSim';
import { AbilitySystem, type AbilityContext } from '../AbilitySystem';
import { Player } from '../Player';
import { Effects } from '../../graphics/Effects';
import { DISCIPLINES } from '../../content/disciplines';
import { ABILITIES } from '../../content/abilities';
import type { Intent, SimEvent } from '../sim/types';

vi.mock('../../audio/Audio', () => ({ audio: { play: vi.fn() } }));
vi.mock('../../graphics/fxTextures', () => ({
  fx: Object.fromEntries(['glow', 'smoke', 'disc', 'ring', 'cracks', 'sigil'].map((name) => [name, () => new THREE.Texture()])),
}));
vi.mock('../../graphics/fxImages', () => ({ fxImage: () => new THREE.Texture() }));

type Family = 'warden' | 'witch' | 'veil' | 'monk';
const DISC = { warden: 'grave_warden', witch: 'carrion_witch', veil: 'veilwalker', monk: 'bell_monk' } as const;

/** The real client cast path (AbilitySystem -> NewBloodSystem) wired to a real WorldSim host, as WorldScene wires them. */
function rig(family: Family, level = 20) {
  const sim = new WorldSim(new Nav(), mulberry32(5));
  const stats = { level, maxHp: 400, spellPower: 20, maxEssence: 200, essenceRegen: 0, moveSpeed: 5.4, thrallHp: 45, thrallDamage: 8, damageBonusPct: 0 };
  const player = new Player(stats, new Nav(), family);
  player.x = 0; player.z = -16; player.area = 'graves';
  player.resource.value = 100;
  sim.setPlayer({ id: 'p1', x: 0, z: -16, alive: true, area: 'graves', family });
  let now = 10_000;
  const events: SimEvent[] = [];
  let abilities: AbilitySystem;
  const send = (i: Intent) => { sim.apply(i); for (const ev of sim.drain()) { events.push(ev); if (ev.t === 'newBlood') abilities.onNewBlood(ev, ev.by === 'p1'); } };
  const ctx = {
    selfId: 'p1', player, discipline: DISCIPLINES[DISC[family]], avatar: { tip: () => new THREE.Vector3(0, 1.4, 0), cast: vi.fn() },
    effects: new Effects(new THREE.Scene()), enemies: () => sim.enemies, boss: () => ({ active: false }), corpses: () => sim.corpses,
    thrallCount: () => 0, send, number: vi.fn(), shake: vi.fn(), now: () => now,
  } as unknown as AbilityContext;
  abilities = new AbilitySystem(ctx);
  const last = (kind: string) => [...events].reverse().find((e) => e.t === 'newBlood' && e.kind === kind) as Extract<SimEvent, { t: 'newBlood' }> | undefined;
  return { sim, player, abilities, events, last, cast: (id: Parameters<AbilitySystem['cast']>[0], x: number, z: number, enemyId?: number) => {
    now += 20_000; // clear every cooldown
    player.castUntil = 0;
    return abilities.cast(id, { x, z, ...(enemyId == null ? {} : { enemyId }) }, now);
  } };
}

describe('New Blood rites that the bot never cast, driven through the real client + host path', () => {
  it('Chain Pull drags the target to the Warden, damages and roots it, and costs Oil', () => {
    const r = rig('warden');
    const e = r.sim.spawnEnemy('robber', 'graves', 8, -16, false, false);
    const hp = e.hp;
    expect(r.cast('chain_pull', e.x, e.z, e.id)).toBe('ok');
    expect(Math.hypot(e.x - r.player.x, e.z - r.player.z)).toBeLessThan(2);
    expect(e.hp).toBeLessThan(hp);
    expect(e.rootT).toBeGreaterThan(0);
    expect(r.player.resource.value).toBe(100 - ABILITIES.chain_pull.essenceCost);
    expect(r.last('chain_pull')).toMatchObject({ ok: true, targetId: e.id });
    // beyond its 10 m reach: refused on the client, nothing moves
    const far = r.sim.spawnEnemy('robber', 'graves', 14, -16, false, false);
    expect(r.cast('chain_pull', far.x, far.z, far.id)).toBe('no_target');
    expect(far.x).toBe(14);
  });

  it('Hook Pull drags the target to the Witch and damages it', () => {
    const r = rig('witch');
    const e = r.sim.spawnEnemy('robber', 'graves', 7, -16, false, false);
    const hp = e.hp;
    expect(r.cast('hook_pull', e.x, e.z, e.id)).toBe('ok');
    expect(Math.hypot(e.x - r.player.x, e.z - r.player.z)).toBeLessThan(2);
    expect(e.hp).toBeLessThan(hp);
    expect(r.player.resource.value).toBe(100 - ABILITIES.hook_pull.essenceCost);
  });

  it('Butcher consumes one real corpse into three charms, and a charm heals whoever touches it 5%', () => {
    const r = rig('witch');
    const c = r.sim.addCorpse(1, -16, 'normal', 'robber', false, 0, 1, 'graves')!;
    const echo = r.sim.addCorpse(1, -16, 'normal', 'robber', false, 0, 1, 'graves')!;
    echo.echoOwner = '*';
    r.sim.drain();
    expect(r.cast('butcher', c.x, c.z)).toBe('ok');
    expect(r.sim.corpses.has(c.id)).toBe(false);
    expect(r.sim.corpses.has(echo.id)).toBe(true); // an echo is not a body
    const charms = [...r.sim.zones.values()].filter((z) => z.kind === 'witch_charm');
    expect(charms).toHaveLength(3);
    // an ally walks onto one
    r.player.hp = 100;
    r.sim.setPlayer({ id: 'p1', x: charms[0].x, z: charms[0].z, alive: true, area: 'graves', family: 'witch' });
    const heal = r.sim.step(0.1).find((e) => e.t === 'newBlood' && e.kind === 'heal');
    expect(heal).toMatchObject({ amount: 0.05, player: 'p1' });
    expect([...r.sim.zones.values()].filter((z) => z.kind === 'witch_charm')).toHaveLength(2);
    expect(r.cast('butcher', 5, -16)).toBe('no_corpse');
  });

  it('Echo raises an echo corpse into a ten-second wraith, and is refused on a real corpse', () => {
    const r = rig('veil');
    const real = r.sim.addCorpse(1, -16, 'normal', 'robber', false, 0, 1, 'graves')!;
    r.sim.drain();
    expect(r.cast('echo', real.x, real.z)).toBe('no_corpse');
    const e = r.sim.addCorpse(1.5, -16, 'normal', 'robber', false, 0, 0.7, 'graves')!;
    e.echoOwner = 'p1'; e.expiresAt = r.sim.time + 20;
    expect(r.cast('echo', e.x, e.z)).toBe('ok');
    expect(r.sim.corpses.has(e.id)).toBe(false);
    const w = [...r.sim.thralls.values()].find((t) => t.echoUntil != null)!;
    expect(w).toMatchObject({ owner: 'p1', kind: 'wraith' });
    r.sim.step(10.2);
    expect([...r.sim.thralls.values()].some((t) => t.echoUntil != null && t.state !== 'dead')).toBe(false);
  });

  it('Crossing blinks the Veilwalker to an echo within 12 m, keeps the echo, and refuses real corpses', () => {
    const r = rig('veil');
    const real = r.sim.addCorpse(5, -16, 'normal', 'robber', false, 0, 1, 'graves')!;
    r.sim.drain();
    expect(r.cast('crossing', real.x, real.z)).toBe('no_corpse');
    const e = r.sim.addCorpse(10, -16, 'normal', 'robber', false, 0, 0.7, 'graves')!;
    e.echoOwner = '*'; e.expiresAt = r.sim.time + 20;
    expect(r.cast('crossing', e.x, e.z)).toBe('ok');
    expect(Math.hypot(r.player.x - 10, r.player.z + 16)).toBeLessThan(1.2);
    expect(r.sim.corpses.has(e.id)).toBe(true);
    expect(r.player.resource.value).toBe(100 - ABILITIES.crossing.essenceCost);
  });

  it('Knell lands three independent beats, 1.2 s apart, each for the same damage', () => {
    const r = rig('monk');
    const e = r.sim.spawnEnemy('robber', 'graves', 6, -16, false, false);
    e.hp = e.maxHp = 1e6; e.state = 'recover'; e.stateT = 1e6;
    expect(r.cast('knell', e.x, e.z, e.id)).toBe('ok');
    const hp = e.hp;
    const dmg = e.knellDamage!;
    expect(dmg).toBeGreaterThan(0);
    for (let i = 0; i < 4; i++) { r.sim.step(1.25); }
    expect(hp - e.hp).toBeGreaterThanOrEqual(dmg * 2.9);
    expect(hp - e.hp).toBeLessThanOrEqual(dmg * 3.1 + 1e-6);
    expect(e.knellBeats).toBe(0);
  });
});
