import { describe, expect, it } from 'vitest';
import { Nav } from '../nav';
import { WorldSim } from '../sim/WorldSim';
import { mulberry32 } from '../rng';
import type { SimEvent } from '../sim/types';
import { ENEMIES, type EnemyId } from '../../content/enemies';
import { AREAS } from '../../content/areas';

function world(seed = 1) {
  const nav = new Nav();
  nav.setUnlocked(['chapterhouse', 'graves', 'ossuary', 'nave', 'sanctum', 'cloister', 'pyre', 'fen']);
  const sim = new WorldSim(nav, mulberry32(seed));
  const r = AREAS.graves.rect;
  sim.setPlayer({ id: 'p1', x: (r.x0 + r.x1) / 2, z: (r.z0 + r.z1) / 2, alive: true, area: 'graves' });
  sim.step(0.05);
  for (const e of [...sim.enemies.values()]) sim.enemies.delete(e.id);
  return sim;
}
const of = <T extends SimEvent['t']>(ev: SimEvent[], t: T) => ev.filter((e): e is Extract<SimEvent, { t: T }> => e.t === t);

describe('enemy telegraphs are honest', () => {
  const TELEGRAPHED: EnemyId[] = ['wraith', 'plague_doctor', 'pyre_priest', 'bog_hag', 'fen_wisp', 'moth', 'penitent', 'golem', 'slag_brute', 'acolyte'];
  for (const id of TELEGRAPHED) {
    for (const elite of [false, true]) {
      it(`${id}${elite ? ' (elite)' : ''}: the telegraph lasts as long as the windup`, () => {
        const sim = world(3);
        const p = sim.players.get('p1')!;
        const e = sim.spawnEnemy(id, 'graves', p.x + 3, p.z, elite, false);
        e.attackCd = 0;
        let ms: number | null = null;
        let started = -1;
        let t = 0;
        let endedAt = -1;
        for (let i = 0; i < 160 && endedAt < 0; i++) {
          const ev = sim.step(0.025);
          t += 0.025;
          if (ms === null) {
            const tele = of(ev, 'telegraph').find((x) => x.id === e.id && x.kind !== 'raise');
            if (tele) {
              ms = tele.ms;
              started = t;
            }
          } else if (e.state !== 'windup' && e.state !== 'channel') endedAt = t;
        }
        if (ms === null) return; // this enemy telegraphs nothing at this range (a plain melee windup)
        expect(endedAt).toBeGreaterThan(0);
        expect(Math.abs((endedAt - started) * 1000 - ms)).toBeLessThan(60);
        expect(ms).toBeCloseTo(ENEMIES[id].windupMs * (elite ? 0.85 : 1), 3);
      });
    }
  }
});
