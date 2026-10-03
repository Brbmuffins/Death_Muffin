import { describe, expect, it } from 'vitest';
import { AREAS } from '../../content/areas';
import { runBalance, type BalanceRun } from '../balance/harness';

/**
 * New Blood leveling audit (BALANCE.md, 2026-10-03). The New Blood bot used to under-measure its classes: it cast rites its
 * hero had not unlocked, measured reach centre to centre (a Hollow Knight stood in a dead zone), never cast most of the kit
 * and never stepped out of a telegraph. These tests pin the harness fixes, not any class's power.
 */
const graves = (classIndex: number, extra: Partial<BalanceRun> = {}): BalanceRun =>
  ({ area: 'graves', level: 1, classIndex, damageTier: 1, waveTier: 0, gearStats: 1, minutes: 1.5, seed: 42, ...extra });
const L = AREAS.sanctum.level;
const sanctum = (classIndex: number, seed: number): BalanceRun =>
  ({ area: 'sanctum', level: 20, classIndex, damageTier: Math.round(L * 0.6), waveTier: 0, gearStats: Math.round(L * 0.8), minutes: 1.5, seed });
const sum = (rows: Record<string, number>[], id: string) => rows.reduce((s, c) => s + (c[id] ?? 0), 0);

describe('New Blood bot fidelity', () => {
  it('casts only rites the hero has unlocked (level 1 has no Burn the Dead or Veil Tear)', () => {
    const warden = runBalance(graves(5, { minutes: 0.15 }));
    const veil = runBalance(graves(9, { minutes: 0.15 }));
    expect(warden.levelsGained).toBe(0);
    expect(veil.levelsGained).toBe(0);
    expect(warden.casts.burn_the_dead ?? 0).toBe(0);
    expect(veil.casts.veil_tear ?? 0).toBe(0);
    // ...and the level-1 kit is used.
    expect(warden.casts.flail_swing).toBeGreaterThan(0);
    expect(veil.casts.spirit_bolt).toBeGreaterThan(0);
  });

  it('a Hollow Knight keeps up with a Grave Warden (reach counts the body radius, so no dead zone at the edge of the cut)', () => {
    const rate = (c: number) => [42, 43, 44].reduce((s, seed) => s + runBalance(graves(c, { seed })).killsPerMin, 0) / 3;
    expect(rate(8)).toBeGreaterThan(rate(5) * 0.6);
  });

  it('casts the whole kit once it is unlocked, not just the first two or three rites', () => {
    const seeds = [42, 43];
    const cast = (c: number) => seeds.map((s) => runBalance(sanctum(c, s)).casts);
    const warden = cast(5);
    const monk = cast(6);
    const witch = cast(7);
    const knight = cast(8);
    const veil = cast(9);
    expect(sum(warden, 'cremate')).toBeGreaterThan(0);
    expect(sum(monk, 'resonant_step')).toBeGreaterThan(0);
    expect(sum(monk, 'knell')).toBeGreaterThan(0);
    expect(sum(witch, 'hex_charm')).toBeGreaterThan(0);
    expect(sum(knight, 'shield_bash')).toBeGreaterThan(0);
    expect(sum(knight, 'grave_slam')).toBeGreaterThan(0);
    expect(sum(veil, 'lay_to_rest')).toBeGreaterThan(0);
  });

  it('steps out of telegraphed attacks: dodging dies less often than standing still', () => {
    const deaths = (dodge: boolean) => [42, 43, 44].reduce((s, seed) => s + runBalance(graves(5, { seed, dodge })).deaths, 0);
    expect(deaths(true)).toBeLessThan(deaths(false));
  });

  it('the necromancer bot is unchanged by the New Blood fixes (never dodges, same rotation)', () => {
    const a = runBalance(graves(1, { dodge: true }));
    const b = runBalance(graves(1, { dodge: false }));
    expect(a.killsPerMin).toBe(b.killsPerMin);
    expect(a.xpPerMin).toBe(b.xpPerMin);
  });
});
