import { describe, expect, it } from 'vitest';
import { Nav } from '../nav';
import { WorldSim } from '../sim/WorldSim';
import { mulberry32 } from '../rng';
import { AREAS } from '../../../server/rules/content/areas';
import { DISCIPLINES } from '../../../server/rules/content/disciplines';
import { DAMAGE_UPGRADE, LEGION_UPGRADE, THRALL_REFRESH_MAX } from '../../../server/rules/content/upgrades';
import { deriveStats } from '../characterStats';
import { applyLegionMods, legionOf, thrallRefresh } from '../legionKit';
import { codexLegionExamples } from '../../content/codex';
import { TIPS } from '../../ui/Onboarding';

function world() {
  const nav = new Nav();
  nav.setUnlocked(['chapterhouse', 'graves']);
  const sim = new WorldSim(nav, mulberry32(5));
  const r = AREAS.graves.rect;
  const cx = (r.x0 + r.x1) / 2;
  const cz = (r.z0 + r.z1) / 2;
  sim.setPlayer({ id: 'p1', x: cx, z: cz, alive: true, area: 'graves' });
  sim.setPlayer({ id: 'p2', x: cx + 3, z: cz, alive: true, area: 'graves' });
  sim.step(0.05);
  for (const e of [...sim.enemies.values()]) sim.enemies.delete(e.id);
  const raise = (by: string, n: number) => {
    for (let i = 0; i < n; i++) {
      sim.addCorpse(cx + i, cz + 2, 'normal', 'robber', false, 0, 1, 'graves');
      const c = [...sim.corpses.values()].at(-1)!;
      sim.apply({ t: 'exhume', by, x: c.x, z: c.z, r: 1, kind: 'warrior', cap: 6, hp: 100, damage: 10, attackSpeedMult: 1 });
    }
  };
  return { sim, raise };
}
const mine = (sim: WorldSim, by: string) => [...sim.thralls.values()].filter((t) => t.owner === by);

describe('refreshThralls (a Damage or Reinforce purchase reaches the standing legion)', () => {
  it('bumps every living thrall of the buyer once: health keeps its fraction, damage and attack rate rise, the other player is untouched', () => {
    const { sim, raise } = world();
    raise('p1', 3);
    raise('p2', 1);
    const [a, b] = mine(sim, 'p1');
    a.hp = a.maxHp * 0.5; // hurt: must stay half-health, not be healed
    const before = mine(sim, 'p1').map((t) => ({ hp: t.hp, max: t.maxHp, dmg: t.damage, iv: t.attackInterval }));
    const other = mine(sim, 'p2')[0];
    const otherBefore = { hp: other.hp, dmg: other.damage };
    sim.apply({ t: 'refreshThralls', by: 'p1', hpMult: 1.1, damageMult: 1.08, speedMult: 1.05 });
    mine(sim, 'p1').forEach((t, i) => {
      expect(t.maxHp).toBeCloseTo(before[i].max * 1.1, 6);
      expect(t.hp).toBeCloseTo(before[i].hp * 1.1, 6);
      expect(t.hp / t.maxHp).toBeCloseTo(before[i].hp / before[i].max, 6);
      expect(t.damage).toBeCloseTo(before[i].dmg * 1.08, 6);
      expect(t.attackInterval).toBeCloseTo(before[i].iv / 1.05, 6);
    });
    expect(a.hp / a.maxHp).toBeCloseTo(0.5, 6);
    expect(b.hp).toBeCloseTo(b.maxHp, 6);
    expect(other.hp).toBe(otherBefore.hp);
    expect(other.damage).toBe(otherBefore.dmg);
  });

  it('is one-time: a thrall raised afterwards is not boosted again, and a dead thrall is skipped', () => {
    const { sim, raise } = world();
    raise('p1', 2);
    const dead = mine(sim, 'p1')[0];
    dead.state = 'dead';
    const deadDmg = dead.damage;
    sim.apply({ t: 'refreshThralls', by: 'p1', hpMult: 1, damageMult: 1.08, speedMult: 1 });
    expect(dead.damage).toBe(deadDmg);
    raise('p1', 1);
    const fresh = mine(sim, 'p1').at(-1)!;
    expect(fresh.damage).toBeLessThan(mine(sim, 'p1')[1].damage); // the standing one carries the bump, the new one starts from the raise value
  });

  it('the host clamps: below 1, NaN and absurd values cannot weaken or wildly strengthen anyone', () => {
    const { sim, raise } = world();
    raise('p1', 1);
    const t = mine(sim, 'p1')[0];
    const { maxHp, damage, attackInterval } = t;
    sim.apply({ t: 'refreshThralls', by: 'p1', hpMult: 0.2, damageMult: Number.NaN, speedMult: -4 });
    expect([t.maxHp, t.damage, t.attackInterval]).toEqual([maxHp, damage, attackInterval]);
    sim.apply({ t: 'refreshThralls', by: 'p1', hpMult: 50, damageMult: 50, speedMult: 50 });
    expect(t.maxHp).toBeCloseTo(maxHp * THRALL_REFRESH_MAX, 6);
    expect(t.damage).toBeCloseTo(damage * THRALL_REFRESH_MAX, 6);
    expect(t.attackInterval).toBeCloseTo(attackInterval / THRALL_REFRESH_MAX, 6);
  });
});

describe('thrallRefresh (what a purchase sends)', () => {
  const character = { id: 1, level: 20, class_index: 2 } as never;
  const d = DISCIPLINES.gravecaller;
  const numbers = (damageTier: number, legionTier: number) => {
    const disc = { ...d, mods: applyLegionMods(d.mods, legionOf([], legionTier)) };
    const s = deriveStats(character, [], disc, damageTier);
    return { hp: s.thrallHp, damage: s.thrallDamage, speedMult: disc.mods.thrallAttackSpeedMult };
  };

  it('a Damage tier raises thrall damage only (about the tier share), a Reinforce tier all three', () => {
    const dmg = thrallRefresh(numbers(3, 0), numbers(4, 0))!;
    expect(dmg.hpMult).toBe(1);
    expect(dmg.speedMult).toBe(1);
    expect(dmg.damageMult).toBeCloseTo((1 + DAMAGE_UPGRADE.perTier * 4) / (1 + DAMAGE_UPGRADE.perTier * 3), 5);
    const rf = thrallRefresh(numbers(0, 2), numbers(0, 3))!;
    expect(rf.damageMult).toBeCloseTo((1 + 3 * LEGION_UPGRADE.perTier) / (1 + 2 * LEGION_UPGRADE.perTier), 5);
    expect(rf.hpMult).toBeGreaterThan(1.02);
    expect(rf.speedMult).toBeGreaterThan(1.005);
  });

  it('null when nothing a thrall carries changed, and never a drop', () => {
    expect(thrallRefresh(numbers(2, 1), numbers(2, 1))).toBeNull();
    expect(thrallRefresh(numbers(5, 0), numbers(4, 0))).toBeNull();
  });

  it('even the largest single purchase sits well inside the host ceiling', () => {
    expect(thrallRefresh(numbers(0, 0), numbers(1, 0))!.damageMult).toBeLessThan(THRALL_REFRESH_MAX);
  });
});

describe('the words say it', () => {
  it('no player-facing text still says standing thralls are left behind by a Reinforce or Damage purchase', () => {
    expect(TIPS.legion.body).not.toMatch(/raise from then on/);
    expect(TIPS.legion.body).toMatch(/standing/);
    expect(codexLegionExamples().length).toBeGreaterThan(0);
  });
});
