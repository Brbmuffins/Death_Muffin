import { ABILITIES, DETONATE, type AbilityId } from '../content/abilities';
import type { CastTarget } from './AbilitySystem';
import { BOSS_RADIUS } from './sim/BossBrain';
import type { BossState, Corpse, Enemy } from './sim/types';

export interface AutoCombatInput {
  player: { x: number; z: number; essence: number; maxEssence: number };
  enemies: Iterable<Enemy>;
  corpses: Iterable<Corpse>;
  boss: BossState;
  thrallCount: number;
  thrallCap: number;
  ready(id: AbilityId): boolean;
}

export interface AutoCombatAction {
  id: AbilityId;
  target: CastTarget;
}

type Target = CastTarget & { radius: number; distance: number };
const distance = (a: { x: number; z: number }, b: { x: number; z: number }) => Math.hypot(a.x - b.x, a.z - b.z);

/** One stationary combat decision. The scene owns its clock, movement and casts.
 * Work is capped even in a crowded co-op snapshot; signatures remain manual.
 */
export function selectAutoCombatAction(input: AutoCombatInput): AutoCombatAction | null {
  const { player: p, boss, thrallCount, thrallCap } = input;
  const targets: Target[] = [];
  let inspected = 0;
  for (const e of input.enemies) {
    if (++inspected > 512) break;
    if (e.hp <= 0 || e.state === 'dead' || e.state === 'rising') continue;
    const d = distance(p, e);
    if (d <= ABILITIES.miasma.range) targets.push({ x: e.x, z: e.z, enemyId: e.id, radius: e.radius, distance: d });
  }
  targets.sort((a, b) => a.distance - b.distance);
  targets.length = Math.min(targets.length, 64);
  if (boss.active && boss.hp > 0 && boss.state !== 'dead') {
    const d = distance(p, boss);
    if (d <= ABILITIES.miasma.range) targets.push({ x: boss.x, z: boss.z, boss: true, radius: BOSS_RADIUS, distance: d });
  }
  if (!targets.length) return null;
  targets.sort((a, b) => a.distance - b.distance);
  const aim = (t: CastTarget): CastTarget => ({ x: t.x, z: t.z, ...(t.boss ? { boss: true } : t.enemyId !== undefined ? { enemyId: t.enemyId } : {}) });
  const action = (id: AbilityId, t: CastTarget): AutoCombatAction => ({ id, target: aim(t) });
  // Always retain a little essence for player-directed spells. Low essence
  // uses the free generator rather than continually draining regeneration.
  const reserve = Math.max(12, p.maxEssence * 0.2);
  const canSpend = (id: AbilityId) => input.ready(id) && p.essence >= ABILITIES[id].essenceCost + reserve;
  const needle = targets.find((t) => t.distance <= ABILITIES.bone_needle.range + (t.boss ? BOSS_RADIUS : 0.4));
  if (p.essence < p.maxEssence * 0.35 && needle && input.ready('bone_needle')) return action('bone_needle', needle);

  const corpses: Corpse[] = [];
  inspected = 0;
  for (const c of input.corpses) {
    if (++inspected > 256) break;
    if (c.kind !== 'none' && distance(p, c) <= ABILITIES.exhume.range) corpses.push(c);
  }
  corpses.sort((a, b) => distance(p, a) - distance(p, b));
  corpses.length = Math.min(corpses.length, 32);
  if (thrallCount < thrallCap && corpses.length && canSpend('exhume')) return action('exhume', corpses[0]);

  const countAround = (point: CastTarget, radius: number) => targets.reduce((n, t) => n + (distance(point, t) <= radius + t.radius ? 1 : 0), 0);
  // The automatic ritual never destroys the player's army. Save this expensive
  // burst for a large fight with actual corpse fuel, rather than one straggler.
  const litany = ABILITIES.black_litany;
  if (thrallCount === 0 && corpses.filter((c) => distance(p, c) <= litany.radius).length >= 2 &&
      countAround(p, litany.radius) >= 6 && canSpend('black_litany')) {
    return action('black_litany', p);
  }
  if (canSpend('corpse_explosion')) {
    let best: Corpse | null = null;
    let hits = 1;
    for (const c of corpses) {
      const r = DETONATE.radius * (c.kind === 'resonant' ? DETONATE.resonantRadiusMult : 1);
      const count = countAround(c, r);
      if (count > hits) { best = c; hits = count; }
    }
    if (best) return action('corpse_explosion', best);
  }
  const candidates = targets.slice(0, 12);
  if (canSpend('miasma')) {
    let best: Target | null = null;
    let hits = 2;
    for (const t of candidates) {
      const count = countAround(t, ABILITIES.miasma.radius);
      if (count > hits) { best = t; hits = count; }
    }
    if (best) return action('miasma', best);
  }
  if (canSpend('marrow_spear')) {
    let best: Target | null = null;
    let hits = 1;
    for (const t of candidates) {
      if (t.distance > ABILITIES.marrow_spear.range || t.distance < 0.01) continue;
      const dx = (t.x - p.x) / t.distance;
      const dz = (t.z - p.z) / t.distance;
      const count = targets.reduce((n, e) => {
        const rx = e.x - p.x, rz = e.z - p.z;
        const along = rx * dx + rz * dz;
        return n + (along >= 0 && along <= ABILITIES.marrow_spear.range &&
          Math.abs(rx * dz - rz * dx) <= ABILITIES.marrow_spear.radius + e.radius ? 1 : 0);
      }, 0);
      if (count > hits) { best = t; hits = count; }
    }
    if (best) return action('marrow_spear', best);
    const single = candidates.find((t) => t.distance <= ABILITIES.marrow_spear.range &&
      p.essence >= p.maxEssence * (t.boss ? 0.6 : 0.8));
    if (single) return action('marrow_spear', single);
  }
  return needle && input.ready('bone_needle') ? action('bone_needle', needle) : null;
}
