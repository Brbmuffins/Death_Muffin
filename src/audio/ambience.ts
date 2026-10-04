/**
 * Zone ambience data and pure rules: which looping bed layers each area plays,
 * which sparse details drift in over it, and how long the gaps between details are.
 * The beds are low and quiet on purpose ("immersive, not overwhelming"). No WebAudio here.
 */
import type { AreaId } from '../content/areas';
import type { Sfx } from './Audio';

export interface BedLayer {
  /** Basename of a loop in public/audio/ambience/. */
  file: string;
  /** Linear gain under the bed bus. */
  gain: number;
  /** Playback-rate multiplier (also shifts pitch; a cheap way to vary one loop per zone). */
  rate?: number;
  /** Optional low-pass to push a layer further away. */
  lp?: number;
}

export interface ZoneBed {
  /** Recorded-noise loops used when they have loaded. */
  loops: readonly BedLayer[];
  /** Synthesised wind used when the loops are unavailable: [low-pass Hz, gain]. */
  wind: readonly (readonly [number, number])[];
  /** Low drones (Hz, gain) under either path. */
  drones: readonly (readonly [number, number])[];
}

const L = (file: string, gain: number, rate?: number, lp?: number): BedLayer => ({ file, gain, rate, lp });

/** Overall trim on the recorded loops: they sit well under the fight, ~-3 dB from the first measured level. */
export const LOOP_TRIM = 0.7;

export const BED_FILES = ['bed_wind', 'bed_hollow', 'bed_water', 'bed_fire', 'bed_murmur', 'bed_rain', 'bed_flame'] as const;

export const ZONE_BEDS: Record<AreaId, ZoneBed> = {
  chapterhouse: { loops: [L('bed_hollow', 0.2), L('bed_wind', 0.06, 0.8, 500)], wind: [[300, 0.06]], drones: [[55, 0.018]] },
  acre: { loops: [L('bed_wind', 0.28)], wind: [[900, 0.14], [320, 0.07]], drones: [] },
  graves: { loops: [L('bed_wind', 0.28), L('bed_wind', 0.1, 0.78), L('bed_rain', 0.18, 1, 2600)], wind: [[700, 0.22], [260, 0.12]], drones: [] },
  ossuary: { loops: [L('bed_hollow', 0.26, 0.9)], wind: [[350, 0.08]], drones: [[49, 0.03]] },
  nave: { loops: [L('bed_hollow', 0.22, 0.85), L('bed_water', 0.1, 0.7, 1800)], wind: [[450, 0.1]], drones: [[41.2, 0.026], [61.7, 0.014]] },
  sanctum: { loops: [L('bed_hollow', 0.28, 0.7), L('bed_wind', 0.08, 0.7, 700)], wind: [[380, 0.08]], drones: [[36.7, 0.034]] },
  cloister: { loops: [L('bed_water', 0.09, 0.8, 2200), L('bed_hollow', 0.12, 0.95), L('bed_wind', 0.05, 0.9, 800), L('bed_rain', 0.28, 1, 3000)], wind: [[520, 0.1], [200, 0.08]], drones: [[43.7, 0.02]] },
  pyre: { loops: [L('bed_flame', 0.24), L('bed_fire', 0.12), L('bed_hollow', 0.12, 0.8)], wind: [[650, 0.16], [240, 0.14]], drones: [[46.2, 0.03]] },
  warren: { loops: [L('bed_hollow', 0.26, 0.75)], wind: [[240, 0.05]], drones: [[41.2, 0.024]] },
  // Deep under the Warren: the same hollow bed, lower and slower, with a drone a fifth below the Warren's.
  depths: { loops: [L('bed_hollow', 0.3, 0.62)], wind: [[200, 0.04]], drones: [[34.6, 0.03]] },
  coliseum: { loops: [L('bed_murmur', 0.28), L('bed_wind', 0.1, 1, 900)], wind: [[1100, 0.09], [420, 0.1]], drones: [[55, 0.018]] },
  fen: { loops: [L('bed_wind', 0.12, 1.2, 1500), L('bed_water', 0.08, 0.6, 1600), L('bed_hollow', 0.08, 1.1), L('bed_rain', 0.28)], wind: [[900, 0.07], [300, 0.09]], drones: [[38.9, 0.026]] },
  // A warm, close workshop: hearth breath and a low simmering drone (the Alchemist's Wing).
  alchemist_wing: { loops: [L('bed_fire', 0.08, 0.7, 900), L('bed_flame', 0.06, 0.7, 900), L('bed_hollow', 0.12)], wind: [[260, 0.04]], drones: [[58.3, 0.02]] },
};

export interface ZoneAccents {
  /** Seconds between details: uniform in [min, max]. Long on purpose. */
  gap: readonly [number, number];
  /** Weighted details; the weights need not sum to 1. */
  sounds: readonly (readonly [Sfx, number])[];
}

export const ZONE_ACCENTS: Record<AreaId, ZoneAccents> = {
  chapterhouse: { gap: [18, 40], sounds: [['distantBell', 2], ['graveCreak', 2], ['waterDrip', 1]] },
  acre: { gap: [14, 34], sounds: [['crowCaw', 3], ['distantBell', 1], ['graveCreak', 1], ['windGust', 1]] },
  graves: { gap: [12, 30], sounds: [['crowCaw', 3], ['windGust', 2], ['distantBell', 1], ['graveCreak', 1]] },
  ossuary: { gap: [14, 34], sounds: [['waterDrip', 3], ['graveCreak', 1], ['dustFall', 2]] },
  nave: { gap: [12, 30], sounds: [['waterDrip', 3], ['distantBell', 2], ['crowdMoan', 1]] },
  sanctum: { gap: [16, 36], sounds: [['distantBell', 3], ['graveCreak', 1], ['crowdMoan', 1]] },
  cloister: { gap: [12, 28], sounds: [['bogBubble', 2], ['waterDrip', 2], ['graveCreak', 1]] },
  pyre: { gap: [8, 20], sounds: [['emberCrackle', 4], ['graveCreak', 1], ['windGust', 1]] },
  warren: { gap: [12, 30], sounds: [['waterDrip', 3], ['dustFall', 3], ['graveCreak', 1]] },
  depths: { gap: [10, 26], sounds: [['waterDrip', 3], ['dustFall', 3], ['graveCreak', 2]] },
  coliseum: { gap: [14, 32], sounds: [['crowdMoan', 3], ['distantBell', 2], ['windGust', 1]] },
  fen: { gap: [10, 26], sounds: [['bogBubble', 4], ['waterDrip', 2], ['crowCaw', 1], ['graveCreak', 1]] },
  alchemist_wing: { gap: [10, 24], sounds: [['waterDrip', 2], ['emberCrackle', 2]] },
};

export function accentGap(area: AreaId, rnd: number): number {
  const [lo, hi] = ZONE_ACCENTS[area].gap;
  return lo + (hi - lo) * Math.min(1, Math.max(0, rnd));
}

export function pickAccent(area: AreaId, rnd: number): Sfx {
  const list = ZONE_ACCENTS[area].sounds;
  const total = list.reduce((s, [, w]) => s + w, 0);
  let r = Math.min(0.999999, Math.max(0, rnd)) * total;
  for (const [name, w] of list) {
    r -= w;
    if (r < 0) return name;
  }
  return list[list.length - 1][0];
}

/** True when every loop of a zone's bed has loaded (otherwise the synthesised bed plays). */
export function bedReady(area: AreaId, has: (file: string) => boolean): boolean {
  const loops = ZONE_BEDS[area].loops;
  return loops.length > 0 && loops.every((l) => has(l.file));
}
