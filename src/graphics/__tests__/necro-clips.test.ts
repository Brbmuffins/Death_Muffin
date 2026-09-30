import { describe, expect, it } from 'vitest';
// @ts-expect-error plain .mjs tool
import { measureFile } from '../../../tools/measure-clips.mjs';

interface Clip { name: string; dur: number; hipMin: number; hipEnd: number; travel: number }
const HEROES = ['hero_gravecaller', 'hero_ossuary', 'hero_mourner', 'hero_rotweaver'];

/** Numbers, not eyeballs: the shipped hero GLBs must not contain the lying `hurt` preset or a clip that falls. */
describe('shipped necro clips (measured)', () => {
  it.each(HEROES)('%s: flinches stand, deaths lie down, combat clips stay up and short', async (hero) => {
    const clips: Clip[] = await measureFile(`public/models/${hero}/character.glb`);
    const by = new Map(clips.map((c) => [c.name, c]));
    for (const n of ['hurt', 'hurt2']) {
      const c = by.get(n)!;
      expect(c.dur, `${hero} ${n}`).toBeLessThan(3);
      expect(c.hipMin, `${hero} ${n}`).toBeGreaterThan(0.85);
    }
    for (const n of ['death', 'death2']) expect(by.get(n)!.hipEnd, `${hero} ${n}`).toBeLessThan(0.45);
    for (const n of ['slam', 'sweep', 'flick', 'channel', 'summon']) {
      const c = by.get(n)!;
      expect(c.dur, `${hero} ${n}`).toBeLessThan(2.1);
      // Hip height is stored relative to standing, so the measured ratio is to the clip's own first frame.
      expect(c.hipMin, `${hero} ${n}`).toBeGreaterThan(0.55);
    }
  }, 60000);
});
