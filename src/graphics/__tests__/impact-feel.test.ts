import { describe, expect, it } from 'vitest';
import { BUDGET_MAX, FRAME, HitStop, MIN_GAP, hitstopSeconds } from '../hitstop';
import { KNOCK_MAX, knockActive, knockImpulse, settleDepth, stepKnock, type Knock } from '../knockback';

describe('hitstop', () => {
  it('lasts 2-4 frames by weight', () => {
    expect(hitstopSeconds(0)).toBeCloseTo(2 * FRAME);
    expect(hitstopSeconds(1)).toBeCloseTo(4 * FRAME);
    expect(hitstopSeconds(5)).toBeCloseTo(4 * FRAME);
  });

  it('freezes the picture clock, then releases it, without eating real time', () => {
    const h = new HitStop();
    expect(h.request(1)).toBeGreaterThan(0);
    let frozen = 0;
    for (let i = 0; i < 10; i++) frozen += FRAME - h.tick(FRAME);
    expect(frozen).toBeCloseTo(4 * FRAME, 6);
    expect(h.frozen).toBe(false);
    expect(h.tick(FRAME)).toBeCloseTo(FRAME);
  });

  it('refuses a second freeze inside the gap and never stacks', () => {
    const h = new HitStop();
    h.request(0.5);
    expect(h.request(0.5)).toBe(0);
    for (let i = 0; i < 6; i++) h.tick(FRAME);
    expect(h.request(0.5)).toBe(0); // still inside MIN_GAP
    h.tick(MIN_GAP);
    expect(h.request(0.5)).toBeGreaterThan(0);
  });

  it('caps the share of time spent frozen in a sustained crowd fight', () => {
    const h = new HitStop();
    let frozen = 0;
    const secs = 60;
    for (let i = 0; i < secs * 60; i++) {
      h.request(1); // heavy hits every frame
      frozen += FRAME - h.tick(FRAME);
    }
    expect(frozen / secs).toBeLessThan(0.16);
    expect(frozen).toBeLessThanOrEqual(BUDGET_MAX + secs * 0.12 + 1e-6);
  });

  it('is off when disabled (reduced motion)', () => {
    const h = new HitStop();
    h.disabled = () => true;
    expect(h.request(1)).toBe(0);
    expect(h.tick(FRAME)).toBeCloseTo(FRAME);
  });

  it('scale is 0 while frozen and 1 otherwise', () => {
    const h = new HitStop();
    h.frame(FRAME);
    expect(h.scale).toBe(1);
    h.request(0);
    h.frame(FRAME);
    expect(h.scale).toBe(0);
  });
});

describe('knockback', () => {
  const run = (k: Knock, secs: number) => {
    let peak = 0;
    for (let t = 0; t < secs; t += 1 / 60) {
      stepKnock(k, 1 / 60);
      peak = Math.max(peak, Math.hypot(k.x, k.z));
    }
    return peak;
  };

  it('shoves away from the attacker and relaxes to exactly zero without overshoot', () => {
    const { vx, vz } = knockImpulse(0.3, 1, 1, 0);
    expect(vx).toBeGreaterThan(0);
    expect(vz).toBeCloseTo(0);
    const k: Knock = { x: 0, z: 0, vx, vz };
    let minX = 0;
    for (let t = 0; t < 1.5; t += 1 / 60) { stepKnock(k, 1 / 60); minX = Math.min(minX, k.x); }
    expect(minX).toBeGreaterThan(-0.02);
    expect(knockActive(k)).toBe(false);
  });

  it('is heavier for harder hits and lighter for heavy bodies, and stays bounded', () => {
    const soft = knockImpulse(0.05, 1, 1, 0).vx;
    const hard = knockImpulse(0.6, 1, 1, 0).vx;
    const boss = knockImpulse(0.6, 8, 1, 0).vx;
    expect(hard).toBeGreaterThan(soft);
    expect(boss).toBeLessThan(hard / 3);
    const k: Knock = { x: 0, z: 0, ...knockImpulse(5, 0.1, 0, 1) };
    expect(run(k, 1)).toBeLessThanOrEqual(KNOCK_MAX + 1e-6);
  });

  it('is framerate independent', () => {
    const a: Knock = { x: 0, z: 0, vx: 3, vz: 0 }, b: Knock = { x: 0, z: 0, vx: 3, vz: 0 };
    for (let i = 0; i < 12; i++) stepKnock(a, 1 / 60);
    for (let i = 0; i < 3; i++) stepKnock(b, 1 / 15);
    expect(a.x).toBeCloseTo(b.x, 2);
  });
});

describe('death settle', () => {
  it('eases from 0 to depth and holds', () => {
    expect(settleDepth(0, 0.1)).toBe(0);
    expect(settleDepth(0.225, 0.1)).toBeCloseTo(0.05, 3);
    expect(settleDepth(5, 0.1)).toBeCloseTo(0.1);
    expect(settleDepth(-1, 0.1)).toBe(0);
  });
});
