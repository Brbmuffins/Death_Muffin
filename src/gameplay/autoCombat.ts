import { ABILITIES, DETONATE, GRAVE_FROST, WAILING_SKULL, type AbilityId } from '../content/abilities';
import type { CastTarget } from './AbilitySystem';
import { BOSS_RADIUS } from './sim/BossBrain';
import type { BossState, Corpse, Enemy } from './sim/types';

export interface AutoCombatInput {
  /** hp/maxHp let Bone Mantle answer pressure; omitted, it only waits for corpse fuel. */
  player: { x: number; z: number; essence: number; maxEssence: number; hp?: number; maxHp?: number };
  enemies: Iterable<Enemy>;
  corpses: Iterable<Corpse>;
  boss: BossState;
  thrallCount: number;
  thrallCap: number;
  ready(id: AbilityId): boolean;
  /** The left-click primary the Grimoire equipped (default Bone Needle). */
  primary?: AbilityId;
}

export interface AutoCombatAction {
  id: AbilityId;
  target: CastTarget;
}

type Target = CastTarget & { radius: number; distance: number; elite?: boolean };
const distance = (a: { x: number; z: number }, b: { x: number; z: number }) => Math.hypot(a.x - b.x, a.z - b.z);

/** One stationary combat decision. The scene owns its clock, movement and casts.
 * Work is capped even in a crowded co-op snapshot; signatures remain manual, and
 * Grave Step never fires on its own (auto combat never moves the player). `ready`
 * decides what is on the bar, so it only reaches for the player's Grimoire rites.
 */
export function selectAutoCombatAction(input: AutoCombatInput): AutoCombatAction | null {
  const { player: p, boss, thrallCount, thrallCap } = input;
  const targets: Target[] = [];
  let inspected = 0;
  for (const e of input.enemies) {
    if (++inspected > 512) break;
    if (e.hp <= 0 || e.state === 'dead' || e.state === 'rising') continue;
    const d = distance(p, e);
    if (d <= ABILITIES.miasma.range) targets.push({ x: e.x, z: e.z, enemyId: e.id, radius: e.radius, distance: d, elite: e.elite });
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
  const primary = input.primary ?? 'bone_needle';
  const inReach = targets.filter((t) => t.distance <= ABILITIES[primary].range + (t.boss ? BOSS_RADIUS : 0.4));
  const needle = primaryTarget(primary, inReach);
  if (p.essence < p.maxEssence * 0.35 && needle && input.ready(primary)) return action(primary, needle);

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
  // Bone Mantle: armour up when the pack is on you and you are hurt, or when the dead lie thick.
  if (canSpend('bone_mantle') && countAround(p, 3) >= 2) {
    const hurt = p.hp !== undefined && p.maxHp ? p.hp < p.maxHp * 0.6 : false;
    const fuel = corpses.filter((c) => distance(p, c) <= ABILITIES.bone_mantle.radius).length;
    if (hurt || fuel >= 3) return action('bone_mantle', p);
  }
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
  if (canSpend('grave_frost')) {
    const slope = Math.tan((GRAVE_FROST.halfAngleDeg * Math.PI) / 180);
    const len = ABILITIES.grave_frost.range;
    let best: Target | null = null;
    let hits = 2;
    for (const t of candidates) {
      if (t.distance > len || t.distance < 0.01) continue;
      const dx = (t.x - p.x) / t.distance;
      const dz = (t.z - p.z) / t.distance;
      const count = targets.reduce((n, e) => {
        const rx = e.x - p.x, rz = e.z - p.z;
        const along = rx * dx + rz * dz;
        return n + (along >= -e.radius && along <= len + e.radius && Math.abs(rx * dz - rz * dx) <= slope * Math.max(0, along) + e.radius ? 1 : 0);
      }, 0);
      if (count > hits) { best = t; hits = count; }
    }
    if (best) return action('grave_frost', best);
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
  if (canSpend('wailing_skull')) {
    // The skull earns its cost on a boss, an elite, or a knot it can leap through.
    const reach = (t: Target) => t.distance <= ABILITIES.wailing_skull.range + (t.boss ? BOSS_RADIUS : 0.4);
    const prize = candidates.find((t) => reach(t) && (t.boss || t.elite));
    const chain = prize ?? candidates.find((t) => reach(t) && countAround(t, WAILING_SKULL.leapRange) >= 3);
    if (chain) return action('wailing_skull', chain);
  }
  return needle && input.ready(primary) ? action(primary, needle) : null;
}

/**
 * Where the primary aims: the nearest target, except pack primaries (Bone Fan) take the densest
 * knot in reach. Auto combat never walks closer for any of them.
 */
function primaryTarget(primary: AbilityId, inReach: Target[]): Target | undefined {
  if (!inReach.length) return undefined;
  if (primary !== ('bone_fan' as AbilityId)) return inReach[0];
  let best = inReach[0];
  let bestN = -1;
  for (const t of inReach) {
    const n = inReach.filter((o) => Math.hypot(o.x - t.x, o.z - t.z) <= 3).length;
    if (n > bestN) (best = t), (bestN = n);
  }
  return best;
}
