import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { AREAS, type AreaId } from '../../../server/rules/content/areas';
import { BED_FILES, ZONE_ACCENTS, ZONE_BEDS, accentGap, bedReady, pickAccent } from '../ambience';
import {
  CombatActivity, PROFILES, accentsAllowed, activityWeight, bedDuckGain, lootSfx, profileOf,
} from '../mixer';
import { LEGACY, legacyNames, legacyUrl } from '../samples';
import { clipFile, packClips, ALL_PACKS } from '../packs';

const AREA_IDS = Object.keys(AREAS) as AreaId[];

describe('zone ambience data', () => {
  it('covers every area with a bed and a detail palette', () => {
    for (const id of AREA_IDS) {
      expect(ZONE_BEDS[id], id).toBeDefined();
      expect(ZONE_ACCENTS[id], id).toBeDefined();
    }
    expect(AREA_IDS.length).toBe(13); // 11 hunting/safe areas + the Alchemist's Wing + the Catacomb Depths
  });
  it('keeps beds low, from real loops, with a synth fallback', () => {
    for (const id of AREA_IDS) {
      const bed = ZONE_BEDS[id];
      expect(bed.loops.length, id).toBeGreaterThan(0);
      expect(bed.wind.length + bed.drones.length, `${id} fallback`).toBeGreaterThan(0);
      const total = bed.loops.reduce((s, l) => s + l.gain, 0);
      expect(total, id).toBeLessThan(0.6);
      for (const l of bed.loops) expect(BED_FILES as readonly string[], id).toContain(l.file);
    }
  });
  it('uses details that exist, live on the ambience bus at priority 0, with long gaps', () => {
    for (const id of AREA_IDS) {
      const { gap, sounds } = ZONE_ACCENTS[id];
      expect(gap[0], id).toBeGreaterThanOrEqual(8);
      expect(gap[1], id).toBeGreaterThan(gap[0]);
      for (const [name, w] of sounds) {
        expect(w).toBeGreaterThan(0);
        expect(profileOf(name).bus, `${id}:${name}`).toBe('ambience');
        expect(profileOf(name).priority, `${id}:${name}`).toBe(0);
      }
    }
  });
  it('picks weighted details and spreads gaps across the range', () => {
    expect(accentGap('graves', 0)).toBe(ZONE_ACCENTS.graves.gap[0]);
    expect(accentGap('graves', 1)).toBe(ZONE_ACCENTS.graves.gap[1]);
    expect(accentGap('graves', 5)).toBe(ZONE_ACCENTS.graves.gap[1]);
    const seen = new Set<string>();
    for (let i = 0; i < 100; i++) seen.add(pickAccent('fen', i / 100));
    expect(seen).toEqual(new Set(ZONE_ACCENTS.fen.sounds.map(([n]) => n)));
    expect(pickAccent('pyre', 0)).toBe('emberCrackle');
    expect(pickAccent('pyre', 1)).toBe(ZONE_ACCENTS.pyre.sounds.at(-1)![0]);
    expect(pickAccent('pyre', NaN as number)).toBeDefined();
  });
  it('plays the recorded bed only when every loop has loaded', () => {
    expect(bedReady('graves', () => true)).toBe(true);
    expect(bedReady('graves', () => false)).toBe(false);
    expect(bedReady('cloister', (f) => f === 'bed_water')).toBe(false);
  });
});

describe('sample files', () => {
  it('older clips resolve to folders by prefix', () => {
    expect(legacyUrl('bed_wind')).toBe('audio/ambience/bed_wind.ogg');
    expect(legacyUrl('amb_bell_1')).toBe('audio/world/amb_bell_1.ogg');
    expect(legacyUrl('boss_toll_1')).toBe('audio/combat/boss_toll_1.ogg');
  });
  it('every older clip still referenced exists on disk and is credited in AUDIO-SOURCES.md', () => {
    const credits = readFileSync(resolve(__dirname, '../../../docs/AUDIO-SOURCES.md'), 'utf8') as string;
    for (const name of legacyNames()) {
      const file = resolve(__dirname, '../../../public', legacyUrl(name));
      expect(existsSync(file), file).toBe(true);
      const base = name.replace(/_\d+$/, '');
      expect(credits.includes(name) || credits.includes(base), `${name} credited`).toBe(true);
    }
  });
  it('every pack clip exists on disk', () => {
    for (const pack of ALL_PACKS) {
      for (const name of packClips(pack)) {
        expect(existsSync(resolve(__dirname, '../../../public', clipFile(name))), name).toBe(true);
      }
    }
  });
  it('every older-clip entry has a profile and sane gain', () => {
    for (const [name, spec] of Object.entries(LEGACY)) {
      expect(profileOf(name as Parameters<typeof profileOf>[0]).bus, name).toBeDefined();
      expect(spec!.gain).toBeGreaterThan(0);
      expect(spec!.gain).toBeLessThanOrEqual(1);
      expect(spec!.synthMix).toBeGreaterThanOrEqual(0);
    }
  });
});

describe('combat activity and ambience ducking', () => {
  it('rises with combat sounds and decays by half every 2.5 s', () => {
    const a = new CombatActivity();
    expect(a.level(0)).toBe(0);
    a.bump(0, 0.8);
    expect(a.level(0)).toBeCloseTo(0.8);
    expect(a.level(CombatActivity.HALF_LIFE)).toBeCloseTo(0.4);
    expect(a.level(30)).toBeLessThan(0.01);
    a.reset();
    expect(a.level(0)).toBe(0);
  });
  it('saturates and counts only fight buses', () => {
    const a = new CombatActivity();
    for (let i = 0; i < 100; i++) a.bump(0, 0.5);
    expect(a.level(0)).toBeLessThanOrEqual(1.5);
    expect(activityWeight('ui', 9)).toBe(0);
    expect(activityWeight('ambience', 9)).toBe(0);
    expect(activityWeight('combat', 9)).toBeGreaterThan(activityWeight('enemies', 9));
    expect(activityWeight('enemies', 5)).toBeGreaterThan(activityWeight('thralls', 3));
  });
  it('pulls the bed down by at most half and brings it back', () => {
    expect(bedDuckGain(0)).toBe(1);
    expect(bedDuckGain(1)).toBeCloseTo(0.5);
    expect(bedDuckGain(1.5)).toBeCloseTo(0.5);
    expect(bedDuckGain(-1)).toBe(1);
    expect(bedDuckGain(0.4)).toBeGreaterThan(bedDuckGain(0.8));
  });
  it('holds sparse details back while a fight is on', () => {
    const a = new CombatActivity();
    expect(accentsAllowed(a.level(0))).toBe(true);
    for (let i = 0; i < 6; i++) a.bump(0, activityWeight('combat', 9));
    expect(accentsAllowed(a.level(0))).toBe(false);
    expect(accentsAllowed(a.level(12))).toBe(true);
  });
});

describe('loot sound', () => {
  it('is distinct only for rare and above', () => {
    expect(lootSfx([])).toBe('item');
    expect(lootSfx(['common', 'uncommon'])).toBe('item');
    expect(lootSfx(['common', 'rare'])).toBe('lootRare');
    expect(lootSfx(['rare', 'epic', 'common'])).toBe('lootEpic');
  });
  it('keeps the interface sounds short and quiet in priority', () => {
    expect(profileOf('panelOpen').dur).toBeLessThan(0.5);
    expect(profileOf('panelOpen').priority).toBeLessThan(profileOf('levelUp').priority);
    expect(profileOf('lootEpic').priority).toBeGreaterThan(profileOf('lootRare').priority);
  });
});
