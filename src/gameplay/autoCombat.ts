import { ABILITIES, DETONATE, GRAVE_FROST, IVORY_CLEAVE, WAILING_SKULL, type AbilityId } from '../content/abilities';
import type { CastTarget } from './AbilitySystem';
import { BOSS_RADIUS } from './sim/BossBrain';
import type { BossState, Corpse, Enemy } from './sim/types';
import type { ClassFamily } from '../../server/rules/content/disciplines';
import { AREAS, type AreaId } from '../../server/rules/content/areas';
import { dodgeStep, stepIntoHazard, type DodgeMemory, type Hazard } from './autoDodge';

export interface AutoCombatInput {
  /** hp/maxHp let Bone Mantle answer pressure; omitted, it only waits for corpse fuel. */
  player: { x: number; z: number; essence: number; maxEssence: number; hp?: number; maxHp?: number;
    area?: AreaId | null; veilForm?: boolean; bulwarkUntil?: number; betweenUntil?: number; unbreakableUntil?: number };
  enemies: Iterable<Enemy>;
  corpses: Iterable<Corpse>;
  boss: BossState;
  thrallCount: number;
  thrallCap: number;
  ready(id: AbilityId): boolean;
  /** The left-click primary the Grimoire equipped (default Bone Needle). */
  primary?: AbilityId;
  /** The primary's reach when a weapon changes it (staff needle +25%, scythe arc 3 m); default is the ability's own. */
  primaryRange?: number;
  /** Who is deciding (Carrion Seed keeps one seed per caster). */
  selfId?: string;
  family?: ClassFamily;
  signature?: AbilityId;
  now?: number;
}

export interface AutoCombatAction {
  id: AbilityId;
  target: CastTarget;
}

type Target = CastTarget & { radius: number; distance: number; elite?: boolean; hp?: number; maxHp?: number;
  state?: Enemy['state']; hexOwner?: string };
const distance = (a: { x: number; z: number }, b: { x: number; z: number }) => Math.hypot(a.x - b.x, a.z - b.z);

/** One Easy-auto combat decision. The scene owns its clock, movement and casts.
 * Work is capped even in a crowded co-op snapshot. `ready` restricts choices
 * to the equipped kit and unlocked rites.
 */
export function selectAutoCombatAction(input: AutoCombatInput): AutoCombatAction | null {
  const { player: p, boss, thrallCount, thrallCap } = input;
  const targets: Target[] = [];
  let inspected = 0;
  for (const e of input.enemies) {
    if (++inspected > 512) break;
    if (e.hp <= 0 || e.state === 'dead' || (e.state === 'rising' || e.state === 'burrow') || (p.area && e.area && e.area !== p.area)) continue;
    const d = distance(p, e);
    if (d <= ABILITIES.miasma.range) targets.push({ x: e.x, z: e.z, enemyId: e.id, radius: e.radius, distance: d,
      elite: e.elite, hp: e.hp, maxHp: e.maxHp, state: e.state, hexOwner: e.hexOwner });
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
  if (input.family && input.family !== 'necromancer') return newBloodAutoAction(input, targets, action);
  // Always retain a little essence for player-directed spells. Low essence
  // uses the free generator rather than continually draining regeneration.
  const reserve = Math.max(12, p.maxEssence * 0.2);
  const canSpend = (id: AbilityId) => input.ready(id) && p.essence >= ABILITIES[id].essenceCost + reserve;
  const primary = input.primary ?? 'bone_needle';
  const inReach = targets.filter((t) => t.distance <= (input.primaryRange ?? ABILITIES[primary].range) + (t.boss ? BOSS_RADIUS : 0.4));
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
  // Grave Offering: only when essence is low AND the legion is full (otherwise Exhume wants the body);
  // resonant corpses are kept back for Litany.
  if (p.essence < p.maxEssence * 0.3 && thrallCount >= thrallCap && input.ready('grave_offering')) {
    const body = corpses.find((c) => c.kind !== 'resonant' && !c.seedOwner && distance(p, c) <= ABILITIES.grave_offering.range);
    if (body) return action('grave_offering', body);
  }
  // Rally the Dead: a legion of three or more with the enemy close.
  if (thrallCount >= 3 && canSpend('rally_dead') && targets[0].distance <= 8) return action('rally_dead', targets[0]);
  // Carrion Seed: one live seed; plant it on the corpse nearest the approaching pack.
  if (canSpend('carrion_seed') && !corpses.some((c) => c.seedOwner && c.seedOwner === input.selfId)) {
    let best: Corpse | null = null;
    let bestD = 6;
    for (const c of corpses) {
      if (c.seedOwner) continue;
      const d = distance(c, targets[0]);
      if (d > 1.5 && d < bestD) (best = c), (bestD = d);
    }
    if (best) return action('carrion_seed', best);
  }

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
  // Ivory Cleave: two or more within the crescent in front of the nearest enemy.
  if (canSpend('ivory_cleave') && targets[0].distance <= IVORY_CLEAVE.reach + targets[0].radius) {
    const t0 = targets[0];
    const d0 = Math.max(0.01, t0.distance);
    const cos = Math.cos((IVORY_CLEAVE.halfAngleDeg * Math.PI) / 180);
    const inArc = targets.filter((e) => {
      const d = e.distance;
      if (d > IVORY_CLEAVE.reach + e.radius) return false;
      return d < e.radius || ((e.x - p.x) * (t0.x - p.x) + (e.z - p.z) * (t0.z - p.z)) / (d * d0) >= cos;
    }).length;
    if (inArc >= 2) return action('ivory_cleave', t0);
  }
  if (canSpend('miasma')) {
    let best: Target | null = null;
    let hits = 2;
    for (const t of candidates) {
      const count = countAround(t, ABILITIES.miasma.radius);
      if (count > hits) { best = t; hits = count; }
    }
    if (best) return action('miasma', best);
  }
  // Grimoire expansion: a cage, a field and a storm want a knot of three or more; the siphon wants a
  // sturdy target, or answers pressure when hurt.
  const knot = (id: AbilityId, r: number, min: number) => {
    let best: Target | null = null;
    let hits = min - 1;
    for (const t of candidates) {
      if (t.boss || t.distance > ABILITIES[id].range + 0.4) continue;
      const n = countAround(t, r);
      if (n > hits) (best = t), (hits = n);
    }
    return best;
  };
  if (canSpend('bone_prison')) {
    const t = knot('bone_prison', ABILITIES.bone_prison.radius, 3);
    if (t) return action('bone_prison', t);
  }
  if (canSpend('grave_hands')) {
    const t = knot('grave_hands', ABILITIES.grave_hands.radius, 3);
    if (t) return action('grave_hands', t);
  }
  if (canSpend('bone_storm')) {
    const t = knot('bone_storm', ABILITIES.bone_storm.radius + 1, 3);
    if (t) return action('bone_storm', t);
  }
  if (canSpend('soul_siphon')) {
    const hurtNow = p.hp !== undefined && p.maxHp ? p.hp < p.maxHp * 0.7 : false;
    const reach = (t: Target) => t.distance <= ABILITIES.soul_siphon.range + (t.boss ? BOSS_RADIUS : 0.4);
    const prey = candidates.find((t) => reach(t) && (t.boss || t.elite)) ?? (hurtNow ? candidates.find(reach) : undefined);
    if (prey) return action('soul_siphon', prey);
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
  if (input.signature && input.ready(input.signature) && targets.length >= 3) {
    if (input.signature === 'command_rend' && thrallCount >= 2) return action(input.signature, targets[0]);
    if (input.signature === 'plague_bloom' && countAround(targets[0], 4) >= 3) return action(input.signature, targets[0]);
    if (input.signature === 'ossuary_wall' && countAround(p, 5) >= 3) return action(input.signature, targets[0]);
    if (input.signature === 'dirge' && p.hp !== undefined && p.maxHp && p.hp < p.maxHp * 0.65) return action(input.signature, p);
  }
  return needle && input.ready(primary) ? action(primary, needle) : null;
}

function newBloodAutoAction(input: AutoCombatInput, targets: Target[], action: (id: AbilityId, t: CastTarget) => AutoCombatAction): AutoCombatAction | null {
  const p = input.player, family = input.family, nearest = targets[0];
  const primary = input.primary ?? 'bone_needle';
  const ready = (id: AbilityId) => input.ready(id) && p.essence >= ABILITIES[id].essenceCost;
  const inRange = (id: AbilityId, t: { x: number; z: number }) => distance(p, t) <= ABILITIES[id].range + 0.4;
  const count = (t: { x: number; z: number }, r: number) => targets.filter((e) => distance(t, e) <= r + e.radius).length;
  const real = [...input.corpses].filter((c) => !c.echoOwner && (!p.area || !c.area || c.area === p.area));
  const echo = [...input.corpses].find((c) => (c.echoOwner === '*' || c.echoOwner === input.selfId) && inRange('echo', c));
  const body = (id: AbilityId) => real.find((c) => inRange(id, c));
  const hurt = p.hp !== undefined && p.maxHp ? p.hp / p.maxHp : 1;
  const now = input.now ?? 0;
  if (family === 'warden') {
    if (hurt < 0.7 && nearest?.distance <= 12 && ready('last_light')) return action('last_light', p);
    if (nearest?.distance <= 5 && (hurt < 0.75 || count(p, 5) >= 3) && ready('watchmans_ward')) return action('watchmans_ward', p);
    const burning = real.find((c) => inRange('burn_the_dead', c) && count(c, 4) >= 2);
    if (burning && ready('burn_the_dead')) return action('burn_the_dead', burning);
    const cremation = real.find((c) => inRange('cremate', c) && count(c, 2) >= 1);
    if (cremation && ready('cremate')) return action('cremate', cremation);
    if (nearest?.distance <= 7 && (count(p, 7) >= 2 || nearest.elite || nearest.boss) && ready('lantern_cone')) return action('lantern_cone', nearest);
    if (nearest?.distance > 3 && inRange('chain_pull', nearest) && ready('chain_pull') && !nearest.boss) return action('chain_pull', nearest);
  } else if (family === 'monk') {
    if (nearest?.distance <= 9 && count(p, 9) >= 3 && ready('great_toll')) return action('great_toll', p);
    if (nearest?.distance <= 4 && count(p, 4) >= 2 && ready('choir_of_one')) return action('choir_of_one', p);
    const resonant = real.find((c) => inRange('sound_the_corpse', c) && count(c, 3) >= 2 && c.kind !== 'resonant');
    if (resonant && ready('sound_the_corpse')) return action('sound_the_corpse', resonant);
    if (nearest && inRange('knell', nearest) && (nearest.elite || nearest.boss || (nearest.maxHp && (nearest.hp ?? 0) > nearest.maxHp * 0.7)) && ready('knell')) return action('knell', nearest);
    if (nearest?.distance <= 4 && (count(p, 4) >= 2 || nearest.state === 'windup' || nearest.state === 'channel') && ready('toll')) return action('toll', p);
    if (nearest?.distance > 2 && nearest?.distance <= 5 && ready('resonant_step')) return action('resonant_step', nearest);
  } else if (family === 'witch') {
    const harvest = body('harvest');
    if (harvest && p.essence < 70 && ready('harvest')) return action('harvest', harvest);
    const charm = body('butcher');
    if (charm && hurt < 0.65 && ready('butcher')) return action('butcher', charm);
    if (nearest && inRange('murder_of_crows', nearest) && count(nearest, 4) >= 3 && ready('murder_of_crows')) return action('murder_of_crows', nearest);
    if (nearest && inRange('hex_charm', nearest) && !nearest.boss && !nearest.hexOwner && count(nearest, 4) >= 2 && ready('hex_charm')) return action('hex_charm', nearest);
    if (nearest && inRange('crow_swarm', nearest) && count(nearest, 3) >= 2 && ready('crow_swarm')) return action('crow_swarm', nearest);
    if (nearest?.distance > 4 && inRange('hook_pull', nearest) && ready('hook_pull') && !nearest.boss) return action('hook_pull', nearest);
  } else if (family === 'veil') {
    if (nearest?.distance <= 6 && ready('between_worlds') && p.essence < 45) return action('between_worlds', p);
    const pressured = nearest?.distance <= 5 && (hurt < 0.7 || count(p, 5) >= 3);
    if (pressured && !p.veilForm && p.essence >= 45 && now >= (p.betweenUntil ?? 0) && ready('veil_form')) return action('veil_form', p);
    if (p.veilForm && (p.essence <= 15 || !nearest || nearest.distance > 8 || (!pressured && hurt > 0.9)) && ready('veil_form')) return action('veil_form', p);
    if (echo && input.thrallCount < 5 && ready('echo')) return action('echo', echo);
    const rest = body('lay_to_rest');
    if (rest && (hurt < 0.8 || !echo) && ready('lay_to_rest')) return action('lay_to_rest', rest);
    if (nearest && inRange('veil_tear', nearest) && count(nearest, 3) >= 2 && ready('veil_tear')) return action('veil_tear', nearest);
    if (echo && nearest?.distance > 8 && distance(echo, nearest) < 5 && ready('crossing')) return action('crossing', echo);
  } else if (family === 'knight') {
    if (hurt < 0.35 && nearest?.distance <= 8 && now >= (p.unbreakableUntil ?? 0) && ready('oath_unbroken')) return action('oath_unbroken', p);
    const vigil = body('corpse_vigil');
    if (hurt < 0.7 && vigil && distance(p, vigil) <= 2 && ready('corpse_vigil')) return action('corpse_vigil', vigil);
    if (nearest?.distance <= 3 && (hurt < 0.65 || nearest.state === 'windup') && now >= (p.bulwarkUntil ?? 0) && ready('bulwark')) return action('bulwark', nearest);
    const brand = real.find((c) => inRange('grave_brand', c) && count(c, 1.5) >= 1);
    if (brand && ready('grave_brand')) return action('grave_brand', brand);
    if (nearest && inRange('grave_slam', nearest) && count(nearest, 3) >= 2 && ready('grave_slam')) return action('grave_slam', nearest);
    if (nearest && inRange('shield_bash', nearest) && nearest.distance <= 3 && ready('shield_bash')) return action('shield_bash', nearest);
  }
  return nearest && nearest.distance <= ABILITIES[primary].range + (nearest.boss ? BOSS_RADIUS : 0.4) && ready(primary)
    ? action(primary, nearest) : null;
}

/**
 * Movement memory for Easy auto, owned by the scene. Without it the bot re-decides from scratch each
 * frame and looks choppy: it flickers walk/stop at the edge of its reach, snaps between two equally
 * near targets, and re-picks a dodge side every frame. Tests may omit it (stateless decisions).
 */
export interface AutoMoveMemory {
  targetId?: number | null;
  /** Closing distance (hysteresis: keep walking until comfortably inside reach). */
  closing?: boolean;
  /** A committed dodge/retreat direction and when it may be re-chosen (ms). */
  evade?: { x: number; z: number; until: number } | null;
  /** Last output direction, for smoothed turning. */
  dir?: { x: number; z: number } | null;
  /** Walking around a prop to reach the target: waypoints, whose they are, and when to re-plan (ms). */
  route?: { x: number; z: number }[] | null;
  routeFor?: number;
  routeAt?: number;
  /** Line-of-sight check cadence (ms) and its last answer. */
  sightAt?: number;
  blocked?: boolean;
  /** The safe spot chosen when leaving a boss telegraph or a hostile pool (autoDodge.ts). */
  dodge?: DodgeMemory;
}
/** The nav queries movement needs to walk around props instead of into them (optional for tests). */
export interface AutoMoveNav {
  clearLine(x0: number, z0: number, x1: number, z1: number, r?: number): boolean;
  findPath(fx: number, fz: number, tx: number, tz: number): { x: number; z: number }[];
}
/** What Easy auto's movement reads: where the hero and the enemies are, and (optionally) the live shapes to stay out of. */
export type AutoMoveInput = Pick<AutoCombatInput, 'player' | 'enemies' | 'primary' | 'primaryRange' | 'family'> & { nav?: AutoMoveNav; hazards?: readonly Hazard[] };
const STICKY_TARGET_M = 2;
const CLOSE_START = 0.2;
const CLOSE_STOP = 1.1;
const EVADE_COMMIT_MS = 450;
const TURN_SECONDS = 0.1;

/** A local engagement direction; manual movement, panels and gathering gate its use in the scene. */
export function selectAutoCombatMovement(
  input: AutoMoveInput,
  mem?: AutoMoveMemory,
  now = 0,
  dt = 0,
): { x: number; z: number } | null {
  const want = rawAutoMovement(input, mem, now);
  if (!mem) return want;
  if (!want) {
    mem.dir = null;
    return null;
  }
  // Smoothed turning: blend from the last heading instead of snapping (a reversal still turns fast).
  const prev = mem.dir;
  let out = want;
  if (prev && dt > 0) {
    const k = 1 - Math.exp(-dt / TURN_SECONDS);
    const x = prev.x + (want.x - prev.x) * k;
    const z = prev.z + (want.z - prev.z) * k;
    const len = Math.hypot(x, z);
    out = len > 0.2 ? { x: x / len, z: z / len } : want;
  }
  mem.dir = out;
  return out;
}

function rawAutoMovement(input: AutoMoveInput, mem: AutoMoveMemory | undefined, now: number): { x: number; z: number } | null {
  const p = input.player;
  // Boss telegraphs, hymn cones and hostile pools come first: step out to the nearest safe spot, and (below) never walk back in.
  const hazards = input.hazards;
  if (hazards?.length || mem?.dodge?.goal) {
    const rect = p.area ? AREAS[p.area].rect : null;
    const out = dodgeStep(p, hazards ?? [], mem ? (mem.dodge ??= {}) : undefined, now, { rect, nav: input.nav });
    if (out) {
      if (mem) mem.evade = null; // the ordinary dodge must not resume a stale side
      return out;
    }
  }
  const enemies = [...input.enemies].filter((e) => e.hp > 0 && e.state !== 'dead' && (e.state !== 'rising' && e.state !== 'burrow') && (!p.area || e.area === p.area))
    .sort((a, b) => distance(p, a) - distance(p, b));
  let nearest = enemies[0];
  if (!nearest) {
    if (mem) (mem.targetId = null), (mem.closing = false), (mem.evade = null);
    return null;
  }
  // Sticky target: keep the one we were engaging unless another is clearly closer.
  if (mem?.targetId != null) {
    const kept = enemies.find((e) => e.id === mem.targetId);
    if (kept && distance(p, kept) - distance(p, nearest) < STICKY_TARGET_M) nearest = kept;
  }
  if (mem) mem.targetId = nearest.id;
  const d = distance(p, nearest);
  if (d > 36 || d < 0.01) return null;
  const dx = (nearest.x - p.x) / d, dz = (nearest.z - p.z) / d;
  const rect = p.area ? AREAS[p.area].rect : null;
  const cx = rect ? (rect.x0 + rect.x1) / 2 - p.x : 0;
  const cz = rect ? (rect.z0 + rect.z1) / 2 - p.z : 0;
  const centerD = Math.hypot(cx, cz) || 1;
  const center = { x: cx / centerD, z: cz / centerD };
  const safe = (choices: { x: number; z: number }[]) => {
    if (!rect) return choices[0];
    return choices.find((v) => p.x + v.x * 2 > rect.x0 + 1 && p.x + v.x * 2 < rect.x1 - 1 &&
      p.z + v.z * 2 > rect.z0 + 1 && p.z + v.z * 2 < rect.z1 - 1) ?? choices.at(-1)!;
  };
  // A committed dodge holds its direction briefly so the hero doesn't wobble between sides.
  const evade = (choices: { x: number; z: number }[]) => {
    if (mem?.evade && now < mem.evade.until) return { x: mem.evade.x, z: mem.evade.z };
    const v = safe(choices);
    if (mem) mem.evade = { ...v, until: now + EVADE_COMMIT_MS };
    return v;
  };
  const lowHp = p.hp !== undefined && p.maxHp && p.hp < p.maxHp * 0.32;
  if (lowHp && d < 5) return evade([{ x: -dx, z: -dz }, { x: -dz, z: dx }, { x: dz, z: -dx }, center]);
  const threatened = enemies.some((e) => distance(p, e) < 4 && (e.state === 'windup' || e.state === 'channel'));
  if (threatened && d < 3.5) return evade([{ x: -dz, z: dx }, { x: dz, z: -dx }, { x: -dx, z: -dz }, center]);
  if (mem?.evade && now < mem.evade.until) return { x: mem.evade.x, z: mem.evade.z };
  if (mem) mem.evade = null;
  const reach = input.primaryRange ?? ABILITIES[input.primary ?? 'bone_needle'].range;
  // Hysteresis: start closing just past reach, keep closing until comfortably inside it.
  const startAt = Math.max(1.1, reach - (mem ? CLOSE_START : 0.4));
  const stopAt = Math.max(0.9, reach - CLOSE_STOP);
  const closing = mem?.closing ? d > stopAt : d > startAt;
  if (mem) mem.closing = closing;
  if (closing) {
    // A straight line into a tombstone makes the hero grind against it (the wall resolve pushes it
    // back every frame). When the target is out of sight, walk the nav path around instead.
    if (mem && input.nav) {
      if (now >= (mem.sightAt ?? 0)) {
        mem.sightAt = now + 200;
        mem.blocked = !input.nav.clearLine(p.x, p.z, nearest.x, nearest.z, 0.45);
      }
      if (mem.blocked) {
        if (!mem.route?.length || mem.routeFor !== nearest.id || now >= (mem.routeAt ?? 0)) {
          mem.route = input.nav.findPath(p.x, p.z, nearest.x, nearest.z);
          mem.routeFor = nearest.id;
          mem.routeAt = now + 800;
        }
        while (mem.route.length && Math.hypot(mem.route[0].x - p.x, mem.route[0].z - p.z) < 0.5) mem.route.shift();
        const wp = mem.route[0];
        if (wp) {
          const l = Math.hypot(wp.x - p.x, wp.z - p.z) || 1;
          const step = { x: (wp.x - p.x) / l, z: (wp.z - p.z) / l };
          return hazards && stepIntoHazard(p, step, hazards) ? null : step;
        }
      } else mem.route = null;
    }
    // Hold here, still attacking, rather than walking into a ring, cone or pool; the way clears when the blow lands.
    const step = safe([{ x: dx, z: dz }, center]);
    return hazards && stepIntoHazard(p, step, hazards) ? null : step;
  }
  if (reach >= 7 && d < 3 && enemies.filter((e) => distance(p, e) < 3.5).length >= 2) return evade([{ x: -dx, z: -dz }, center]);
  return null;
}

/**
 * Where the primary aims: the nearest target, except pack primaries (Bone Fan) take the densest
 * knot in reach. Movement into range is selected separately.
 */
function primaryTarget(primary: AbilityId, inReach: Target[]): Target | undefined {
  if (!inReach.length) return undefined;
  if (primary !== 'bone_fan') return inReach[0];
  let best = inReach[0];
  let bestN = -1;
  for (const t of inReach) {
    const n = inReach.filter((o) => Math.hypot(o.x - t.x, o.z - t.z) <= 3).length;
    if (n > bestN) (best = t), (bestN = n);
  }
  return best;
}
