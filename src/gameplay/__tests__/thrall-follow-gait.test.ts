import { describe, expect, it } from 'vitest';
import { Nav } from '../nav';
import { WorldSim } from '../sim/WorldSim';
import { mulberry32 } from '../rng';
import { AREAS } from '../../../server/rules/content/areas';

/** Walk the owner in a line and count how often each following thrall flips between moving and standing. */
function flips(playerSpeed: number, seconds = 8, dt = 1 / 60, stopAfter = Infinity) {
  const nav = new Nav();
  nav.setUnlocked(['chapterhouse', 'graves']);
  const sim = new WorldSim(nav, mulberry32(5));
  const r = AREAS.graves.rect;
  let px = r.x0 + 6;
  const pz = (r.z0 + r.z1) / 2;
  sim.setPlayer({ id: 'p1', x: px, z: pz, alive: true, area: 'graves' });
  sim.step(0.05);
  for (const e of [...sim.enemies.values()]) sim.enemies.delete(e.id);
  for (let i = 0; i < 6; i++) {
    sim.addCorpse(px + i * 0.3, pz + 2, 'normal', 'robber', false, 0, 1, 'graves');
    const c = [...sim.corpses.values()].at(-1)!;
    sim.apply({ t: 'exhume', by: 'p1', x: c.x, z: c.z, r: 1, kind: 'warrior', cap: 6, hp: 100, damage: 10, attackSpeedMult: 1 });
  }
  const last = new Map<number, boolean>();
  let n = 0;
  let frames = 0;
  for (let f = 0; f < seconds / dt; f++) {
    if (f * dt < stopAfter) px += playerSpeed * dt;
    sim.setPlayer({ id: 'p1', x: px, z: pz, alive: true, area: 'graves' });
    for (const e of [...sim.enemies.values()]) sim.enemies.delete(e.id);
    sim.step(dt);
    if (f * dt < 2) continue; // settle into formation first
    frames++;
    for (const t of sim.thralls.values()) {
      if (last.has(t.id) && last.get(t.id) !== t.moving) n++;
      last.set(t.id, t.moving);
    }
  }
  return { flips: n, perSecond: n / (frames * dt), stillMoving: [...sim.thralls.values()].filter((t) => t.moving).length };
}

describe('thralls following a walking owner', () => {
  it('do not flap between walk and idle at any owner speed (was ~5-28 flips per thrall per second)', () => {
    for (const s of [3, 4, 5, 5.4, 5.6, 6.5]) expect(flips(s).flips, `owner speed ${s}`).toBe(0);
  });
  it('still stop once the owner stops', () => {
    const r = flips(4, 8, 1 / 60, 4);
    expect(r.stillMoving).toBe(0);
  });
  it('hold their steady gait at a jittery frame rate too', () => {
    // frame times of 12-33 ms alternating
    expect(flips(5.4, 8, 1 / 45).flips).toBe(0);
    expect(flips(4.5, 8, 1 / 30).flips).toBe(0);
  });
});
