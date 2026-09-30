import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import type { AbilityId } from '../abilities';
import { ABILITIES } from '../abilities';
import { ABILITY_ROLE, CLIP_RELEASE, RELEASE_LEAD_S, WEAPON_CLIPS, castClipFor, planGesture, type GestureKey } from '../castClips';
import { CAST_FLOW } from '../combatFlow';
import { kitFor } from '../kits';
import type { WeaponKind } from '../gear';

const HEROES = ['hero_gravecaller', 'hero_ossuary', 'hero_mourner', 'hero_rotweaver'] as const;
const clipsOf = (h: string) => JSON.parse(readFileSync(`public/models/${h}/clips.json`, 'utf8')) as { clips: string[]; release?: Record<string, number> };
const WEAPONS: GestureKey[] = ['none', 'sword', 'dagger', 'staff', 'bow', 'mace', 'tome', 'scythe', 'wand', 'sickle'];

const kit = kitFor('necromancer');
const NECRO_RITES: AbilityId[] = [...new Set([...kit.hotbar, ...kit.grimoire, ...kit.primaries, kit.rmb, ...Object.values(kit.signatures)])] as AbilityId[];

describe('necro cast clips', () => {
  it('every necromancer rite has a gesture role', () => {
    for (const id of NECRO_RITES) expect(ABILITY_ROLE[id], id).toBeDefined();
  });

  it('every clip the table can pick exists in every necro hero GLB', () => {
    for (const hero of HEROES) {
      const have = clipsOf(hero).clips;
      for (const w of WEAPONS) for (const id of NECRO_RITES) {
        const c = castClipFor(w, id);
        if (c) expect(have, `${hero} ${w} ${id}`).toContain(c.clip);
      }
      // The legacy fallbacks the code still calls must also exist.
      for (const legacy of ['cast', 'attack', 'dig', 'hurt', 'death']) expect(have).toContain(legacy);
    }
  });

  it('CLIP_RELEASE matches what the build wrote into clips.json', () => {
    for (const hero of HEROES) {
      const rel = clipsOf(hero).release ?? {};
      for (const [clip, at] of Object.entries(CLIP_RELEASE)) expect(rel[clip], `${hero} ${clip}`).toBeCloseTo(at, 2);
    }
  });

  it('weapons steer the gesture and unmapped ones fall back to today\'s clips', () => {
    expect(castClipFor('scythe', 'bone_needle')?.clip).toBe('sweep');
    expect(castClipFor('wand', 'bone_needle')?.clip).toBe('flick');
    expect(castClipFor('sickle', 'marrow_spear')?.clip).toBe('flick');
    expect(castClipFor('staff', 'corpse_explosion')?.clip).toBe('slam');
    expect(castClipFor('none', 'black_litany')?.clip).toBe('channel');
    expect(castClipFor('staff', 'exhume')?.clip).toBe('summon');
    expect(castClipFor('staff', 'bone_needle')).toBeNull();
    for (const w of ['sword', 'dagger', 'bow', 'mace', 'tome'] as WeaponKind[]) expect(castClipFor(w, 'black_litany')).toBeNull();
    // Other families' rites never resolve.
    expect(castClipFor('staff', 'hollow_cut' as AbilityId)).toBeNull();
    for (const table of Object.values(WEAPON_CLIPS)) for (const c of Object.values(table!)) if (c) expect(CLIP_RELEASE[c]).toBeGreaterThan(0);
  });

  it('planGesture lands the release frame just after the rite fires, within the clip', () => {
    for (const id of NECRO_RITES) for (const w of WEAPONS) {
      const c = castClipFor(w, id);
      if (!c) continue;
      const dur = 1.0 + (c.releaseAt * 2);
      const p = planGesture(c, CAST_FLOW[id].gestureSeconds, dur);
      expect(p.startAt).toBeGreaterThanOrEqual(0);
      expect(p.startAt).toBeLessThan(dur);
      expect(p.speed).toBeGreaterThanOrEqual(0.7);
      expect(p.speed).toBeLessThanOrEqual(3.2);
      // The release never comes later than half a second after the spawn.
      expect(p.releaseDelayS).toBeLessThan(0.5);
      expect(p.releaseDelayS).toBeGreaterThanOrEqual(0);
    }
    const c = castClipFor('staff', 'corpse_explosion')!;
    const p = planGesture(c, 0.24, 2.0);
    expect(p.releaseDelayS).toBeCloseTo(RELEASE_LEAD_S, 3);
    // Plays no longer than its minimum once started.
    expect((2.0 - p.startAt) / p.speed).toBeLessThan(0.6);
  });

  it('rites that fire at the cast (bolts) skip the wind-up instead of delaying the spell', () => {
    expect(ABILITIES.bone_needle).toBeDefined();
    const c = castClipFor('wand', 'bone_needle')!;
    const p = planGesture(c, CAST_FLOW.bone_needle.gestureSeconds, 1.05);
    expect(p.startAt).toBeGreaterThan(0.2);
  });
});
