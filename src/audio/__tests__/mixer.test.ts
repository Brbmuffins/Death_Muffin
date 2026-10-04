import { describe, expect, it } from 'vitest';
import {
  BUS_CAP, BUS_IDS, BUS_TRIM, GLOBAL_CAP, PROFILES, VoiceLimiter, WindowCounter, busGain, culled, distanceGain,
  effectiveCap, masterGain, pickVariant, profileOf, repeatDropped, repeatGain, sliderGain,
} from '../mixer';

const vol = { volume: 1, combatVolume: 1, ambienceVolume: 1, interfaceVolume: 1 };

describe('bus gain math', () => {
  it('maps sliders through the power curve and clamps bad input', () => {
    expect(sliderGain(0)).toBe(0);
    expect(sliderGain(1)).toBe(1);
    expect(sliderGain(0.5)).toBeCloseTo(0.3536, 3);
    expect(sliderGain(7)).toBe(1);
    expect(sliderGain(-1)).toBe(0);
    expect(sliderGain(NaN)).toBe(1);
  });
  it('routes each bus to its own slider and trim', () => {
    const s = { ...vol, combatVolume: 0.5, ambienceVolume: 0, interfaceVolume: 1 };
    expect(busGain('combat', s)).toBeCloseTo(sliderGain(0.5) * BUS_TRIM.combat);
    expect(busGain('thralls', s)).toBeCloseTo(sliderGain(0.5) * BUS_TRIM.thralls);
    expect(busGain('enemies', s)).toBeCloseTo(sliderGain(0.5) * BUS_TRIM.enemies);
    expect(busGain('ambience', s)).toBe(0);
    expect(busGain('ui', s)).toBeCloseTo(BUS_TRIM.ui);
  });
  it('keeps master separate and below unity', () => {
    expect(masterGain({ ...vol, volume: 0 })).toBe(0);
    expect(masterGain(vol)).toBeLessThanOrEqual(0.9);
  });
  it('keeps thralls quieter than the player bus', () => {
    expect(BUS_TRIM.thralls).toBeLessThan(BUS_TRIM.enemies);
    expect(BUS_TRIM.enemies).toBeLessThan(BUS_TRIM.combat);
  });
});

describe('profiles', () => {
  it('ranks hurt and casts over boss tells over deaths over thrall hits over ambience', () => {
    const p = (n: Parameters<typeof profileOf>[0]) => profileOf(n).priority;
    expect(p('hurt')).toBeGreaterThan(p('bossSlam'));
    expect(p('needleCast')).toBeGreaterThan(p('bossToll'));
    expect(p('bossToll')).toBeGreaterThan(p('eliteDeath'));
    expect(p('eliteDeath')).toBeGreaterThan(p('enemyDeath'));
    expect(p('enemyDeath')).toBeGreaterThan(p('thrallMelee'));
    expect(p('thrallMelee')).toBeGreaterThan(p('distantBell'));
  });
  it('puts thrall hits on the thinned thralls bus and only duck for hurt and boss tells', () => {
    for (const n of ['thrallMelee', 'thrallShot', 'thrallMagic'] as const) {
      expect(PROFILES[n]!.bus).toBe('thralls');
      expect(PROFILES[n]!.thin?.max).toBeGreaterThan(0);
    }
    const ducking = Object.keys(PROFILES).filter((k) => profileOf(k as Parameters<typeof profileOf>[0]).duck).sort();
    // The map's MIX_RULES add the boss wind-ups and the surge to the list; nothing else ducks.
    expect(ducking).toEqual(['bossAwaken', 'bossDefeat', 'bossSlam', 'bossToll', 'hurt', 'playerDeath']);
    const mapped = ['bossTell', 'bossTellEarth', 'bossTellWater', 'bossTellRot', 'bossTellFire', 'surgeStart'] as const;
    for (const n of mapped) expect(profileOf(n).duck, n).toBeDefined();
  });
});

describe('distance falloff', () => {
  it('is 1 at the listener, falls monotonically, and crowd buses fall faster', () => {
    expect(distanceGain(0, 'combat')).toBe(1);
    expect(distanceGain(10, 'combat')).toBeLessThan(distanceGain(5, 'combat'));
    expect(distanceGain(10, 'thralls')).toBeLessThan(distanceGain(10, 'enemies'));
    expect(distanceGain(10, 'enemies')).toBeLessThan(distanceGain(10, 'combat'));
  });
  it('culls far crowd sounds but never boss sounds', () => {
    expect(culled(40, 'thralls', 3)).toBe(true);
    expect(culled(4, 'thralls', 3)).toBe(false);
    expect(culled(120, 'combat', 8)).toBe(false);
  });
});

describe('repeat attenuation', () => {
  it('gets quieter for each identical sound inside the window', () => {
    expect(repeatGain(0)).toBe(1);
    for (let n = 1; n < 8; n++) expect(repeatGain(n)).toBeLessThanOrEqual(repeatGain(n - 1));
    expect(repeatGain(99)).toBeGreaterThan(0);
  });
  it('drops floods of low-priority repeats but never the player\'s own casts', () => {
    expect(repeatDropped(10, 3)).toBe(true);
    expect(repeatDropped(10, 9)).toBe(false);
    expect(repeatDropped(1, 3)).toBe(false);
  });
  it('WindowCounter counts only events inside the window', () => {
    const w = new WindowCounter();
    w.add('a', 0);
    w.add('a', 0.05);
    w.add('b', 0.05);
    expect(w.count('a', 0.1, 0.15)).toBe(2);
    expect(w.count('a', 0.16, 0.15)).toBe(1);
    expect(w.count('a', 0.3, 0.15)).toBe(0);
    expect(w.count('none', 0.3, 0.15)).toBe(0);
  });
});

describe('voice caps and priority', () => {
  it('low priority hits the ceiling before high priority', () => {
    for (const bus of BUS_IDS) {
      expect(effectiveCap(bus, 1)).toBeLessThan(effectiveCap(bus, 9));
      expect(effectiveCap(bus, 9)).toBeLessThanOrEqual(BUS_CAP[bus] + 3);
      expect(effectiveCap(bus, 8)).toBeGreaterThan(BUS_CAP[bus]);
    }
  });
  it('refuses low-priority sounds when the bus is full but still admits important ones', () => {
    const l = new VoiceLimiter();
    let admitted = 0;
    for (let i = 0; i < 40; i++) if (l.request('thralls', 3, 0, 1).ok) admitted++;
    expect(admitted).toBe(effectiveCap('thralls', 3));
    expect(l.request('thralls', 9, 0, 1).ok).toBe(true);
    expect(l.droppedByBus.thralls).toBe(40 - admitted);
    expect(l.dropped).toBe(40 - admitted);
  });
  it('buses are independent', () => {
    const l = new VoiceLimiter();
    for (let i = 0; i < 30; i++) l.request('thralls', 3, 0, 1);
    expect(l.request('combat', 9, 0, 1).ok).toBe(true);
    expect(l.request('ui', 3, 0, 1).ok).toBe(true);
  });
  it('frees voices as their sounds end', () => {
    const l = new VoiceLimiter();
    for (let i = 0; i < 30; i++) l.request('enemies', 5, 0, 0.5);
    expect(l.active('enemies', 0.1)).toBe(effectiveCap('enemies', 5));
    expect(l.active('enemies', 0.6)).toBe(0);
    expect(l.request('enemies', 5, 0.6, 0.5).ok).toBe(true);
  });
  it('a global cap stops everything except the player\'s own sounds', () => {
    const l = new VoiceLimiter();
    const buses = ['combat', 'enemies', 'thralls', 'ui', 'ambience'] as const;
    for (let i = 0; i < 200; i++) l.request(buses[i % 5], 8, 0, 10);
    expect(l.total(0)).toBe(GLOBAL_CAP);
    expect(l.request('ui', 3, 0, 1).ok).toBe(false);
    expect(l.request('combat', 9, 0, 1).ok).toBe(true);
  });
  it('simulated 40-enemy fight stays inside the budget', () => {
    const l = new VoiceLimiter();
    const rate = new WindowCounter();
    let t = 0;
    let thrallPlays = 0;
    for (let tick = 0; tick < 200; tick++, t += 0.025) {
      for (let k = 0; k < 6; k++) {
        const { thin } = PROFILES.thrallMelee!;
        if (rate.count('thin:thralls', t, thin!.window) >= thin!.max) continue;
        if (l.request('thralls', 3, t, 0.3).ok) {
          rate.add('thin:thralls', t);
          thrallPlays++;
        }
      }
      for (let k = 0; k < 3; k++) l.request('enemies', 5, t, 0.5);
      expect(l.active('thralls', t)).toBeLessThanOrEqual(BUS_CAP.thralls);
      expect(l.active('enemies', t)).toBeLessThanOrEqual(BUS_CAP.enemies);
    }
    // At most 3 per 100 ms for 5 seconds.
    expect(thrallPlays).toBeLessThanOrEqual(3 * 50 + 3);
  });
});

describe('variant picking', () => {
  it('stays in range and avoids the previous pick', () => {
    for (let count = 1; count <= 4; count++) {
      for (let last = -1; last < count; last++) {
        for (const rnd of [0, 0.25, 0.5, 0.99, 1]) {
          const i = pickVariant(count, last, rnd);
          expect(i).toBeGreaterThanOrEqual(0);
          expect(i).toBeLessThan(count);
          if (count > 1 && last >= 0) expect(i).not.toBe(last);
        }
      }
    }
  });
});
