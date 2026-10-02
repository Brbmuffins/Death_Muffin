import { describe, expect, it } from 'vitest';
import { CREATURE_MODELS } from '../modelPaths';
import {
  angleDelta, DEFAULT_WALK, LOCO_MIN, planLocomotion, RUN_DOWN, RUN_MAX, RUN_UP, smoothSpeed, STRIDES, stepSpeed, turnToward, walkCap, WALK_MAX,
} from '../locomotion';

const ROW = { walk: 0.7, run: 2.1 };

describe('planLocomotion', () => {
  it('matches the walk clip to the ground speed when it can', () => {
    const p = planLocomotion(ROW, 1.8, 1.26 * 1.5, true);
    expect(p.clip).toBe('walk');
    expect(p.stride).toBeCloseTo(1.26);
    expect(p.timeScale).toBeCloseTo(1.5);
    expect(p.residual).toBeCloseTo(0, 6);
  });

  it('switches to the run clip once walking would need about twice its pace, with hysteresis', () => {
    const walkU = 0.7 * 1.8;
    expect(planLocomotion(ROW, 1.8, walkU * (RUN_UP - 0.05), true, false).clip).toBe('walk');
    expect(planLocomotion(ROW, 1.8, walkU * (RUN_UP + 0.05), true, false).clip).toBe('run');
    // Already running: it stays a run until the pace falls under RUN_DOWN.
    expect(planLocomotion(ROW, 1.8, walkU * (RUN_UP - 0.05), true, true).clip).toBe('run');
    expect(planLocomotion(ROW, 1.8, walkU * (RUN_DOWN - 0.05), true, true).clip).toBe('walk');
  });

  it('never picks a run clip the rig does not have', () => {
    const p = planLocomotion(ROW, 1.8, 6, false);
    expect(p.clip).toBe('walk');
    expect(p.timeScale).toBeLessThanOrEqual(walkCap(1.8));
    expect(p.residual).toBeGreaterThan(0.3);
  });

  it('clamps playback: crawling is not frozen, sprinting does not flail', () => {
    expect(planLocomotion(ROW, 1.8, 0.01, true).timeScale).toBe(LOCO_MIN);
    expect(planLocomotion(ROW, 1.8, 40, true).timeScale).toBe(RUN_MAX);
    expect(planLocomotion(ROW, 1.8, 40, false).timeScale).toBe(walkCap(1.8));
  });

  it('keeps a heavier cadence for a big body than a small one', () => {
    expect(walkCap(0.5)).toBe(WALK_MAX);
    expect(walkCap(4.6)).toBeLessThan(walkCap(1.8));
    expect(walkCap(100)).toBeGreaterThanOrEqual(1.6);
  });

  it('falls back to the typical biped stride for an unmeasured rig', () => {
    expect(planLocomotion(undefined, 2, DEFAULT_WALK * 2, true).timeScale).toBeCloseTo(1);
  });

  it('scales with the creature: a bigger body strides faster in world units', () => {
    expect(planLocomotion(ROW, 3.6, 2, false).stride).toBeCloseTo(planLocomotion(ROW, 1.8, 2, false).stride * 2);
  });
});

describe('measured strides (src/content/strideSpeeds.json)', () => {
  it('has a positive walk for every rigged creature and run only where a clip exists', () => {
    for (const slug of Object.keys(CREATURE_MODELS)) {
      const row = STRIDES[slug];
      if (!row) continue; // static meshes carry no clips
      expect(row.walk, slug).toBeGreaterThan(0.3);
      expect(row.walk, slug).toBeLessThan(2);
      if (row.run !== undefined) expect(row.run, slug).toBeGreaterThan(row.walk! * 2);
    }
  });

  it('covers the heroes and every biped enemy model', () => {
    for (const slug of ['hero_gravecaller', 'hero_mourner', 'grave_robber', 'penitent', 'bone_golem', 'boss_plague_saint', 'skeleton_thrall']) {
      expect(STRIDES[slug]?.walk, slug).toBeGreaterThan(0.3);
    }
    for (const slug of ['bone_hound', 'skull_rat', 'cinderhound']) expect(STRIDES[slug]?.walk, slug).toBeGreaterThan(0.3);
  });
});

describe('speed and turn helpers', () => {
  it('smooths toward a sample without overshooting, independent of the frame rate', () => {
    let a = 0;
    for (let i = 0; i < 6; i++) a = smoothSpeed(a, 4, 1 / 60);
    let b = 0;
    for (let i = 0; i < 3; i++) b = smoothSpeed(b, 4, 1 / 30);
    expect(a).toBeCloseTo(b, 6);
    expect(a).toBeGreaterThan(0);
    expect(a).toBeLessThan(4);
    expect(smoothSpeed(1, 5, 0)).toBe(1);
  });

  it('reads a teleport as standing still', () => {
    expect(stepSpeed(0.1, 0, 0.05)).toBeCloseTo(2);
    expect(stepSpeed(40, 0, 0.016)).toBe(0);
    expect(stepSpeed(1, 1, 0)).toBe(0);
  });

  it('turns the short way round and never faster than the limit', () => {
    expect(angleDelta(3.0, -3.0)).toBeCloseTo(2 * Math.PI - 6.0);
    const next = turnToward(0, Math.PI, 1 / 60, 50, 10);
    expect(next).toBeCloseTo(10 / 60, 6);
    expect(turnToward(0, -Math.PI + 0.1, 1 / 60, 50, 10)).toBeLessThan(0);
    // A tiny correction eases in without a cap.
    expect(turnToward(0, 0.01, 1 / 60, 10, 10)).toBeCloseTo(0.01 / 6, 4);
    // It converges.
    let a = 0;
    for (let i = 0; i < 120; i++) a = turnToward(a, 2.5, 1 / 60, 12, 13);
    expect(a).toBeCloseTo(2.5, 2);
  });
});
