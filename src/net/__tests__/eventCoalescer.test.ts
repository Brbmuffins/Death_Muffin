import { describe, expect, it } from 'vitest';
import { Nav } from '../../gameplay/nav';
import { WorldSim } from '../../gameplay/sim/WorldSim';
import { mulberry32 } from '../../gameplay/rng';
import { AREAS } from '../../content/areas';
import type { EventBatch } from '../contracts';
import { EventCoalescer } from '../eventCoalescer';

const RELAY_PER_SEC = 60; // LIMITS.eventsPerSec in server/realtime/server.js
const RELAY_MAX_EVENTS = 400;

/** A host fighting with a full legion: per-frame event lists from the real sim. */
function runFight(fps: number, seconds = 40) {
  const sim = new WorldSim(new Nav(), mulberry32(11));
  const r = AREAS.graves.rect;
  const cx = (r.x0 + r.x1) / 2;
  const cz = (r.z0 + r.z1) / 2;
  const me = { id: 'p1', x: cx, z: cz, alive: true, area: 'graves', level: 40 } as never;
  sim.setPlayer(me);
  sim.waveTier = 6;
  const frames: EventBatch[] = [];
  let peak = 0;
  const dt = 1 / fps;
  // Corpses are the raw material: raise thralls as they appear until the legion is 15 strong.
  for (let i = 0; i < seconds * fps; i++) {
    sim.setPlayer(me);
    if (sim.thralls.size < 15) {
      const corpse = [...sim.corpses.values()][0];
      const at = corpse ?? { x: cx + 2 + (i % 5), z: cz + 2 };
      sim.apply({ t: 'exhume', by: 'p1', x: at.x, z: at.z, r: 1, kind: i % 2 ? 'warrior' : 'hound', cap: 15, hp: 400, damage: 20, attackSpeedMult: 1 } as never);
    }
    if (i % 20 === 0) {
      const aim = [...sim.enemies.values()].filter((e) => Math.hypot(e.x - cx, e.z - cz) < 12).map((e) => e.id).slice(0, 6);
      if (aim.length) sim.apply({ t: 'hit', by: 'p1', ids: aim, dmg: 60, fracture: 0, boss: false } as never);
    }
    frames.push(sim.step(dt));
    peak = Math.max(peak, sim.thralls.size);
  }
  return { frames, thralls: peak };
}
const cache = new Map<number, ReturnType<typeof runFight>>();
const fight = (fps: number) => cache.get(fps) ?? (cache.set(fps, runFight(fps)), cache.get(fps)!);

/** Run frames through the send path; returns what went out and when. */
function deliver(frames: EventBatch[], fps: number, coalesce: boolean) {
  const sent: Array<{ at: number; batch: EventBatch }> = [];
  let now = 0;
  const co = new EventCoalescer((b) => sent.push({ at: now, batch: b }));
  frames.forEach((ev, i) => {
    now = (i * 1000) / fps;
    if (coalesce) co.push(ev, now);
    else if (ev.length) sent.push({ at: now, batch: ev });
  });
  now += 40;
  if (coalesce) co.push([], now);
  return sent;
}

const worstSecond = (sent: Array<{ at: number }>) => {
  let worst = 0;
  for (let i = 0, j = 0; i < sent.length; i++) {
    while (sent[i].at - sent[j].at >= 1000) j++;
    worst = Math.max(worst, i - j + 1);
  }
  return worst;
};

describe('host event batches vs the relay budget (15-thrall fight)', () => {
  for (const fps of [60, 144]) {
    it(`${fps} fps: stays under the relay limit with margin, loses nothing, keeps order`, () => {
      const { frames, thralls } = fight(fps);
      expect(thralls).toBe(15); // the legion reached 15 thralls
      const flat = frames.flat();
      expect(flat.length).toBeGreaterThan(100);
      const sent = deliver(frames, fps, true);
      expect(worstSecond(sent)).toBeLessThanOrEqual(45); // 25% margin under 60
      expect(sent.flatMap((s) => s.batch)).toEqual(flat);
      for (const s of sent) expect(s.batch.length).toBeLessThanOrEqual(RELAY_MAX_EVENTS);
    });

    it(`${fps} fps: no event waits more than one frame (60 fps) or one 25 ms gap (144 fps)`, () => {
      const { frames } = fight(fps);
      const sent = deliver(frames, fps, true);
      const frameAt: number[] = [];
      frames.forEach((ev, i) => ev.forEach(() => frameAt.push((i * 1000) / fps)));
      let k = 0;
      let worst = 0;
      for (const s of sent) for (let j = 0; j < s.batch.length; j++) worst = Math.max(worst, s.at - frameAt[k++]);
      expect(worst).toBeLessThanOrEqual(Math.max(1000 / fps, 1000 / 40) + 1e-6);
    });
  }

  it('reports the measured rates (uncoalesced vs coalesced)', () => {
    for (const fps of [60, 144]) {
      const { frames } = fight(fps);
      console.log(`fps ${fps}: raw worst second ${worstSecond(deliver(frames, fps, false))} batches/s, coalesced ${worstSecond(deliver(frames, fps, true))}`);
    }
  });

  it('a 144 fps host sending every frame would exceed the relay budget (the bug)', () => {
    expect(worstSecond(deliver(fight(144).frames, 144, false))).toBeGreaterThan(RELAY_PER_SEC);
  });

  it('at a calm pace every batch goes out the frame it happens (no added latency)', () => {
    let sent = 0;
    const co = new EventCoalescer(() => sent++);
    const ev = [{ t: 'x' }] as never;
    let n = 0;
    for (let i = 0; i < 120; i++) {
      if (i % 3 === 0) { co.push(ev, i * 16.7); n++; } else co.push([], i * 16.7);
      expect(co.waiting).toBe(0);
    }
    expect(sent).toBe(n);
  });
});
