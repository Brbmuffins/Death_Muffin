import * as THREE from 'three';
import {
  ABILITIES,
  BONE_MANTLE,
  FRACTURE,
  GRAVE_FROST,
  GRAVE_STEP,
  NEEDLE_ESSENCE,
  SIGNATURE_KIND,
  SIGNATURE_LEVEL,
  SOUL_HARVEST,
  SPELL_FX,
  WAILING_SKULL,
  unlockLevel,
  type AbilityId,
} from '../content/abilities';
import type { Discipline } from '../content/disciplines';
import type { Effects, Handle } from '../graphics/Effects';
import type { NecromancerAvatar } from '../graphics/Avatars';
import { fx } from '../graphics/fxTextures';
import { fxImage } from '../graphics/fxImages';
import { BOSS_RADIUS } from './sim/BossBrain';
import type { BossState, Corpse, Enemy, Intent, SimEvent } from './sim/types';
import type { Player } from './Player';
import { audio } from '../audio/Audio';
import { HEMORRHAGE } from '../content/statuses';
import { CAST_FLOW } from '../content/combatFlow';

export type CastResult = 'ok' | 'busy' | 'cooldown' | 'essence' | 'range' | 'no_target' | 'no_corpse' | 'dead' | 'locked' | 'no_thralls';

export interface CastTarget {
  x: number;
  z: number;
  enemyId?: number;
  boss?: boolean;
}

export interface AbilityContext {
  selfId: string;
  player: Player;
  discipline: Discipline;
  avatar: NecromancerAvatar;
  effects: Effects;
  enemies(): Map<number, Enemy>;
  boss(): BossState;
  corpses(): Map<number, Corpse>;
  /** How many thralls the caster commands (Command: Rend needs one). */
  thrallCount(): number;
  send(intent: Intent): void;
  number(x: number, z: number, amount: number, kind: 'hit' | 'crit' | 'spear'): void;
  shake(amount: number): void;
  /** Scene clock (ms) — never this.ctx.now(), so QA stepping stays consistent. */
  now(): number;
}

const N = SPELL_FX.needle;
const S = SPELL_FX.spear;
const X = SPELL_FX.exhume;
const M = SPELL_FX.miasma;
const L = SPELL_FX.litany;
const D = SPELL_FX.detonate;
const SOUL = SPELL_FX.souls;
const SK = SPELL_FX.skull;
const ST = SPELL_FX.step;
const FR = SPELL_FX.frost;
const MN = SPELL_FX.mantle;

type Vec3 = { x: number; y: number; z: number };

/**
 * Casts the shared necromancer kit. Client-side targeting + VFX, then an
 * Intent to the authoritative sim (local when solo/host, relayed otherwise).
 * Scenes never branch on spell ids — they call cast().
 */
export class AbilitySystem {
  /** Bone Mantle (client-owned): when it ends, the next shard tick, and its orbit visuals. */
  private mantleUntil = 0;
  private nextShardAt = 0;
  private mantleFx: Handle | null = null;

  constructor(private ctx: AbilityContext) {}

  /** The realtime socket id replaces the provisional solo id once connected. */
  setSelf(id: string) {
    this.ctx.selfId = id;
  }

  private get sp() {
    return this.ctx.player.stats.spellPower;
  }

  ready(id: AbilityId, now: number) {
    const p = this.ctx.player;
    return p.alive && this.unlocked(id) && now >= p.castUntil && !p.onCooldown(id, now) && (this.empowered(id) || p.essence >= ABILITIES[id].essenceCost);
  }

  /** Grimoire and signature rites wait for their level. */
  unlocked(id: AbilityId) {
    return this.ctx.player.stats.level >= unlockLevel(id);
  }

  /** A full Soul Harvest meter makes this cast free and 50% larger. */
  empowered(id: AbilityId) {
    return this.ctx.player.soulsCharged && SOUL_HARVEST.spells.includes(id);
  }

  /** Distance the target is beyond the ability's reach (0 if in range). */
  shortfall(id: AbilityId, t: CastTarget): number {
    const p = this.ctx.player;
    const def = ABILITIES[id];
    if (def.targeting !== 'enemy') return 0;
    const pad = t.boss ? BOSS_RADIUS : 0.4;
    return Math.max(0, Math.hypot(t.x - p.x, t.z - p.z) - (def.range + pad));
  }

  cast(id: AbilityId, target: CastTarget, now: number): CastResult {
    const { player: p } = this.ctx;
    const def = ABILITIES[id];
    if (!p.alive) return 'dead';
    if (!this.unlocked(id)) return 'locked';
    if (now < p.castUntil) return 'busy';
    if (p.onCooldown(id, now)) return 'cooldown';
    const empowered = this.empowered(id);
    if (!empowered && p.essence < def.essenceCost) return 'essence';
    const mult = empowered ? SOUL_HARVEST.areaMult : 1;
    let result: CastResult;
    switch (id) {
      case 'bone_needle':
        result = this.needle(target);
        break;
      case 'marrow_spear':
        result = this.spear(target, mult);
        break;
      case 'exhume':
        result = this.exhume(target);
        break;
      case 'miasma':
        result = this.miasma(target, mult);
        break;
      case 'black_litany':
        result = this.litany(mult);
        break;
      case 'corpse_explosion':
        result = this.detonate(target);
        break;
      case 'wailing_skull':
        result = this.skull(target);
        break;
      case 'grave_step':
        result = this.step(target);
        break;
      case 'grave_frost':
        result = this.frost(target);
        break;
      case 'bone_mantle':
        result = this.mantle();
        break;
      case 'ossuary_wall':
      case 'command_rend':
      case 'dirge':
      case 'plague_bloom':
        result = this.signature(id, target);
        break;
    }
    if (result === 'ok') {
      p.castUntil = now + CAST_FLOW[id].lockMs;
      p.rootedUntil = Math.max(p.rootedUntil, p.castUntil);
      if (empowered) {
        p.spendSouls();
        this.soulRelease();
      } else p.essence -= def.essenceCost;
      p.cooldowns.set(id, now + def.cooldownMs);
    }
    return result;
  }

  /** The harvested souls pour out of the caster into the empowered spell. */
  private soulRelease() {
    const { player: p, effects } = this.ctx;
    effects.decal({ tex: fx.ring(), color: SOUL.jade, x: p.x, z: p.z, r: 1.8, duration: 0.5, opacity: 1, growFrom: 0.3 });
    effects.emit({ x: p.x, y: 0.4, z: p.z, count: 20, color: SOUL.jade, spread: 0.6, speed: 1.2, up: 3.2, life: 0.8, size: 0.3 });
    effects.emit({ x: p.x, y: 1.4, z: p.z, count: 8, color: SOUL.pale, spread: 0.3, speed: 2.4, up: 1, life: 0.5, size: 0.22 });
    effects.lightFlash(p.x, 1.6, p.z, SOUL.jade, 26, 0.45);
    audio.play('shard', p.x, p.z);
  }

  private needle(t: CastTarget): CastResult {
    const { player: p, effects, avatar } = this.ctx;
    if (t.enemyId === undefined && !t.boss) return 'no_target';
    if (this.shortfall('bone_needle', t) > 0) return 'range';
    p.face(t.x, t.z);
    avatar.cast('cast', 3.2, p.facing, CAST_FLOW.bone_needle.gestureSeconds);
    const from = avatar.tip();
    effects.flash({ x: from.x, y: from.y, z: from.z, color: N.trail, size: 0.7, duration: 0.14 });
    audio.play('needleCast', p.x, p.z);
    const enemyId = t.enemyId;
    const dmg = this.sp * ABILITIES.bone_needle.power * (0.9 + Math.random() * 0.2);
    const crit = Math.random() < 0.08;
    effects.projectile({
      from,
      kind: 'needle',
      color: N.trail,
      speed: 26,
      to: () => {
        if (t.boss) {
          const b = this.ctx.boss();
          return b.active ? { x: b.x, y: 2.2, z: b.z } : null;
        }
        const e = this.ctx.enemies().get(enemyId!);
        return e ? { x: e.x, y: 1.0, z: e.z } : null;
      },
      onArrive: (pos) => {
        if (!p.alive) return;
        const amount = crit ? dmg * 1.8 : dmg;
        if (t.boss) {
          if (!this.ctx.boss().active) return;
          this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: [], dmg: amount, boss: true });
        } else {
          if (!this.ctx.enemies().has(enemyId!)) return;
          this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: [enemyId!], dmg: amount });
        }
        p.essence = Math.min(p.stats.maxEssence, p.essence + NEEDLE_ESSENCE);
        audio.play('needleHit', pos.x, pos.z, crit ? 1.4 : 1);
        effects.flash({ x: pos.x, y: pos.y, z: pos.z, color: N.impact, size: crit ? 1.7 : 1.05, duration: 0.2 });
        effects.emit({ x: pos.x, y: pos.y, z: pos.z, count: crit ? 16 : 8, color: N.dust, spread: 0.1, speed: 3.2, up: 1.2, life: 0.4, size: 0.13, gravity: 7 });
        if (crit) effects.emit({ x: pos.x, y: pos.y, z: pos.z, count: 10, color: N.trail, spread: 0.2, speed: 4, up: 0.5, life: 0.3, size: 0.3 });
        this.ctx.number(pos.x, pos.z, amount, crit ? 'crit' : 'hit');
      },
    });
    return 'ok';
  }

  /** `mult` > 1 when Soul Harvest empowers the cast (longer, wider line). */
  private spear(t: CastTarget, mult = 1): CastResult {
    const { player: p, effects, avatar } = this.ctx;
    const def = ABILITIES.marrow_spear;
    const range = def.range * mult;
    const radius = def.radius * mult;
    let dx = t.x - p.x;
    let dz = t.z - p.z;
    const len = Math.hypot(dx, dz) || 1;
    dx /= len;
    dz /= len;
    p.face(p.x + dx, p.z + dz);
    avatar.cast('cast', 2.4, p.facing, CAST_FLOW.marrow_spear.gestureSeconds);
    const origin = { x: p.x, z: p.z };
    const dmg = this.sp * def.power;
    const end = { x: origin.x + dx * range, y: 0.3, z: origin.z + dz * range };
    const tip = avatar.tip();
    // A clean ivory release precedes the eruption. Resolve the live line on
    // impact, rather than hurting enemies before any bone reaches them.
    effects.flash({ x: tip.x, y: tip.y, z: tip.z, color: S.bone, size: 0.65, duration: 0.12 });
    effects.beam(tip, () => end, S.bone, 0.025, 0.16);
    effects.projectile({
      from: tip, to: () => end, kind: 'needle', color: S.bone, speed: 48,
      onArrive: () => {
        if (!p.alive) return;
        const halfW = radius + 0.2;
        const ids: number[] = [];
        for (const e of this.ctx.enemies().values()) {
          if (e.state === 'dead') continue;
          const rx = e.x - origin.x;
          const rz = e.z - origin.z;
          const along = rx * dx + rz * dz;
          if (along > 0 && along < range && Math.abs(rx * dz - rz * dx) < halfW + e.radius) {
            ids.push(e.id);
            this.ctx.number(e.x, e.z, dmg, 'spear');
            effects.flash({ x: e.x, y: 0.8, z: e.z, color: S.bone, size: 0.65, duration: 0.14 });
          }
        }
        if (ids.length) this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids, dmg, fracture: 1, bleed: dmg * HEMORRHAGE.dpsFrac });
        const b = this.ctx.boss();
        if (b.active) {
          const rx = b.x - origin.x;
          const rz = b.z - origin.z;
          const along = rx * dx + rz * dz;
          if (along > 0 && along < range + BOSS_RADIUS && Math.abs(rx * dz - rz * dx) < halfW + BOSS_RADIUS) {
            this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: [], dmg, fracture: 1, boss: true });
            this.ctx.number(b.x, b.z, dmg, 'spear');
          }
        }
        effects.spikeLine(origin.x, origin.z, dx, dz, range, radius * 1.3, false);
        effects.decal({ tex: fx.cracks(), color: S.crack, x: origin.x + dx * range * 0.5, z: origin.z + dz * range * 0.5, r: range * 0.5, sx: 0.16 * mult, rot: Math.atan2(dx, dz), duration: 0.65, opacity: 0.55 });
        for (let i = 1; i <= 6; i++) {
          const x = origin.x + dx * (i / 6) * range;
          const z = origin.z + dz * (i / 6) * range;
          effects.emit({ x, y: 0.3, z, count: 3, color: S.bone, spread: 0.25, speed: 1.4, up: 2.1, life: 0.4, size: 0.12, gravity: 9 });
        }
        effects.lightFlash(origin.x + dx * 4, 1, origin.z + dz * 4, S.crack, 12, 0.22);
        audio.play('spear', origin.x + dx * 3, origin.z + dz * 3);
        this.ctx.shake(0.055);
      },
    });
    return 'ok';
  }

  /**
   * Nearest corpse to the cursor (within `pickRadius`, and within `range` of
   * the caster), else the nearest one to the player. Shared by Exhume and
   * Corpse Explosion.
   */
  pickCorpse(t: CastTarget, pickRadius = ABILITIES.exhume.radius, range = ABILITIES.exhume.range): Corpse | null {
    const p = this.ctx.player;
    let best: Corpse | null = null;
    let bestD = pickRadius;
    for (const c of this.ctx.corpses().values()) {
      const d = Math.hypot(c.x - t.x, c.z - t.z);
      if (d < bestD && Math.hypot(c.x - p.x, c.z - p.z) <= range) {
        bestD = d;
        best = c;
      }
    }
    if (best) return best;
    bestD = 7;
    for (const c of this.ctx.corpses().values()) {
      const d = Math.hypot(c.x - p.x, c.z - p.z);
      if (d < bestD) {
        bestD = d;
        best = c;
      }
    }
    return best;
  }

  private exhume(t: CastTarget): CastResult {
    const { player: p, discipline, avatar, effects } = this.ctx;
    const c = this.pickCorpse(t);
    if (!c) return 'no_corpse';
    p.face(c.x, c.z);
    avatar.cast('dig', 2.6, p.facing, CAST_FLOW.exhume.gestureSeconds);
    const m = discipline.mods;
    this.ctx.send({
      t: 'exhume',
      by: this.ctx.selfId,
      x: c.x,
      z: c.z,
      r: 0.8,
      kind: m.thrallKind,
      cap: m.thrallCap,
      hp: p.stats.thrallHp,
      damage: p.stats.thrallDamage,
      attackSpeedMult: m.thrallAttackSpeedMult,
    });
    effects.beam(avatar.tip(), () => ({ x: c.x, y: 0.3, z: c.z }), X.beam, 0.06, 0.4);
    audio.play('exhume', c.x, c.z);
    effects.emit({ x: c.x, y: 0.2, z: c.z, count: 26, color: X.spirit, spread: 0.6, speed: 0.4, up: 3.4, life: 1, size: 0.34, gravity: -0.5 });
    effects.decal({ tex: fx.cracks(), color: X.deep, x: c.x, z: c.z, r: 1.4, rot: Math.random() * 6, duration: 1.3, opacity: 0.9, growFrom: 0.3 });
    return 'ok';
  }

  private miasma(t: CastTarget, mult = 1): CastResult {
    const { player: p, discipline, avatar, effects } = this.ctx;
    const def = ABILITIES.miasma;
    let x = t.x;
    let z = t.z;
    const d = Math.hypot(x - p.x, z - p.z);
    if (d > def.range) {
      x = p.x + ((x - p.x) / d) * def.range;
      z = p.z + ((z - p.z) / d) * def.range;
    }
    p.face(x, z);
    avatar.cast('cast', 2.2, p.facing, CAST_FLOW.miasma.gestureSeconds);
    const r = def.radius * discipline.mods.miasmaRadiusMult * mult;
    const intent: Intent = {
      t: 'miasma',
      by: this.ctx.selfId,
      x,
      z,
      r,
      dps: this.sp * def.power,
      durationMs: 6000,
      witheredCap: discipline.mods.witheredMaxStacks,
      bloom: discipline.mods.miasmaBurstsCorpses,
    };
    effects.projectile({
      from: avatar.tip(),
      to: () => ({ x, y: 0.2, z }),
      kind: 'orb',
      color: M.rot,
      speed: 18,
      arc: 12,
      onArrive: () => {
        if (!p.alive) return;
        this.ctx.send(intent);
        effects.decal({ tex: fx.ring(), color: M.rot, x, z, r, duration: 0.45, opacity: 0.7, growFrom: 0.2 });
        audio.play('miasma', x, z);
        effects.emitSmoke({ x, y: 0.4, z, count: 6, color: M.spore, spread: r * 0.6, speed: 0.5, up: 0.3, life: 0.9, size: 1.1, shrink: -0.3, drag: 0.8 });
        effects.emit({ x, y: 0.3, z, count: 16, color: M.rot, spread: r * 0.5, speed: 1.1, up: 0.6, life: 0.65, size: 0.18 });
      },
    });
    return 'ok';
  }

  // ---------------------------------------------------------------------------
  // Grimoire rites. Each follows the flow of a shipped rite so they feel the same:
  // the skull flies and hits on arrival like Bone Needle, Grave Frost resolves its
  // shape on impact like Marrow Spear, Grave Step picks corpses like Corpse Explosion,
  // and Bone Mantle lets the host consume corpses like Black Litany.
  // ---------------------------------------------------------------------------

  /** Wailing Skull: marks the enemy under (or nearest) the cursor and chains from there. */
  private skull(t: CastTarget): CastResult {
    const { player: p, effects, avatar } = this.ctx;
    const def = ABILITIES.wailing_skull;
    let target: CastTarget | null = t.enemyId !== undefined || t.boss ? t : null;
    if (!target) {
      // A ground cast still finds its mark: the living enemy nearest the cursor.
      let bestD = def.radius;
      for (const e of this.ctx.enemies().values()) {
        if (e.state === 'dead' || e.state === 'rising' || e.hp <= 0) continue;
        const d = Math.hypot(e.x - t.x, e.z - t.z);
        if (d < bestD) {
          bestD = d;
          target = { x: e.x, z: e.z, enemyId: e.id };
        }
      }
    }
    if (!target) return 'no_target';
    if (this.shortfall('wailing_skull', target) > 0) return 'range';
    p.face(target.x, target.z);
    avatar.cast('cast', 2.8, p.facing, CAST_FLOW.wailing_skull.gestureSeconds);
    const from = avatar.tip();
    effects.flash({ x: from.x, y: from.y, z: from.z, color: SK.jade, size: 0.9, duration: 0.18 });
    audio.play('wail', p.x, p.z);
    this.skullLeap({ x: from.x, y: from.y, z: from.z }, target, this.sp * def.power, 1, WAILING_SKULL.hops, new Set());
    return 'ok';
  }

  /**
   * One flight of the skull. `budget` is the leaps left including this one; a leap
   * that kills earns another, never past WAILING_SKULL.maxHops in total.
   */
  private skullLeap(from: Vec3, t: CastTarget, dmg: number, hop: number, budget: number, struck: Set<number>) {
    const { player: p, effects } = this.ctx;
    const W = WAILING_SKULL;
    const enemyId = t.enemyId;
    effects.projectile({
      from,
      kind: 'sprite',
      tex: fxImage('skull'),
      size: 0.95,
      color: SK.jade,
      speed: W.speed,
      to: () => {
        if (t.boss) {
          const b = this.ctx.boss();
          return b.active ? { x: b.x, y: 2.2, z: b.z } : null;
        }
        const e = this.ctx.enemies().get(enemyId!);
        return e ? { x: e.x, y: 1.1, z: e.z } : null;
      },
      onArrive: (pos) => {
        if (!p.alive) return;
        let killed = false;
        let landed = false;
        if (t.boss) {
          if (this.ctx.boss().active) {
            this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: [], dmg, boss: true });
            landed = true;
          }
        } else {
          const e = this.ctx.enemies().get(enemyId!);
          if (e && e.state !== 'dead' && e.hp > 0) {
            killed = e.hp <= dmg * (1 + FRACTURE.perStack * e.fracture);
            this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: [enemyId!], dmg });
            landed = true;
          }
          struck.add(enemyId!);
        }
        if (landed) {
          audio.play('needleHit', pos.x, pos.z, 1.2);
          effects.flash({ x: pos.x, y: pos.y, z: pos.z, color: SK.pale, size: killed ? 1.9 : 1.3, duration: 0.22, tex: fxImage('skull') });
          effects.decal({ tex: fx.ring(), color: SK.jade, x: pos.x, z: pos.z, r: 0.9, duration: 0.4, opacity: 0.9, growFrom: 0.3 });
          effects.emit({ x: pos.x, y: pos.y, z: pos.z, count: killed ? 18 : 10, color: SK.jade, spread: 0.2, speed: 2.4, up: 1.4, life: 0.5, size: 0.22, gravity: -1 });
          this.ctx.number(pos.x, pos.z, dmg, killed ? 'crit' : 'hit');
        }
        const left = budget - 1 + (killed ? 1 : 0);
        if (left <= 0 || hop >= W.maxHops) return;
        // Leap on to the nearest enemy the skull hasn't bitten yet.
        let next: CastTarget | null = null;
        let bestD = W.leapRange;
        for (const e of this.ctx.enemies().values()) {
          if (e.state === 'dead' || e.state === 'rising' || e.hp <= 0 || struck.has(e.id)) continue;
          const d = Math.hypot(e.x - pos.x, e.z - pos.z);
          if (d < bestD) {
            bestD = d;
            next = { x: e.x, z: e.z, enemyId: e.id };
          }
        }
        if (!next) return;
        audio.play('wail', pos.x, pos.z, 0.6);
        this.skullLeap({ x: pos.x, y: pos.y, z: pos.z }, next, dmg * W.falloff, hop + 1, left, struck);
      },
    });
  }

  /** Grave Step: blood-mist blink onto a corpse in your own area; the corpse stays. */
  private step(t: CastTarget): CastResult {
    const { player: p, effects, avatar } = this.ctx;
    const def = ABILITIES.grave_step;
    const c = this.pickCorpse(t, ABILITIES.exhume.radius, def.range);
    // Never across a sealed door: the corpse must lie in the area you stand in.
    if (!c || !p.area || c.area !== p.area || Math.hypot(c.x - p.x, c.z - p.z) > def.range) return 'no_corpse';
    const ox = p.x;
    const oz = p.z;
    // The body comes apart where it stood…
    effects.emitSmoke({ x: ox, y: 0.9, z: oz, count: 6, color: ST.mist, spread: 0.45, speed: 0.7, up: 0.7, life: 0.75, size: 1.2, shrink: -0.4 });
    effects.emit({ x: ox, y: 1, z: oz, count: 18, color: ST.blood, spread: 0.4, speed: 2.2, up: 1.2, life: 0.45, size: 0.2, gravity: 6 });
    effects.decal({ tex: fxImage('bloodSigil'), color: ST.crimson, x: ox, z: oz, r: 1.2, duration: 0.8, opacity: 0.85, growFrom: 0.6 });
    p.teleport(c.x, c.z);
    p.face(p.x + (p.x - ox), p.z + (p.z - oz));
    avatar.cast('cast', 3, p.facing, CAST_FLOW.grave_step.gestureSeconds);
    effects.beam({ x: ox, y: 1, z: oz }, () => ({ x: p.x, y: 1, z: p.z }), ST.blood, 0.07, 0.22);
    // …and re-forms in a marrow burst that bleeds what stands around the corpse.
    const r = GRAVE_STEP.burstRadius;
    const dmg = this.sp * def.power;
    const ids: number[] = [];
    for (const e of this.ctx.enemies().values()) {
      if (e.state === 'dead' || Math.hypot(e.x - p.x, e.z - p.z) > r + e.radius) continue;
      ids.push(e.id);
      if (ids.length <= 12) {
        this.ctx.number(e.x, e.z, dmg, 'hit');
        effects.flash({ x: e.x, y: 0.9, z: e.z, color: ST.blood, size: 0.7, duration: 0.16 });
      }
      if (ids.length >= 64) break;
    }
    if (ids.length) this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids, dmg, bleed: dmg * HEMORRHAGE.dpsFrac });
    const b = this.ctx.boss();
    if (b.active && Math.hypot(b.x - p.x, b.z - p.z) <= r + BOSS_RADIUS) {
      this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: [], dmg, boss: true });
      this.ctx.number(b.x, b.z, dmg, 'hit');
    }
    effects.decal({ tex: fxImage('bloodSigil'), color: ST.blood, x: p.x, z: p.z, r: r * 1.15, duration: 0.9, opacity: 1, growFrom: 0.25, spin: 0.8 });
    effects.decal({ tex: fx.ring(), color: ST.crimson, x: p.x, z: p.z, r: r * 1.05, duration: 0.4, opacity: 0.9, growFrom: 0.15 });
    effects.emit({ x: p.x, y: 0.6, z: p.z, count: 26, color: ST.blood, spread: 0.3, speed: r * 2.6, up: 1.4, life: 0.5, size: 0.26, drag: 1.5 });
    effects.emit({ x: p.x, y: 0.8, z: p.z, count: 8, color: ST.hot, spread: 0.2, speed: 2, up: 2.2, life: 0.35, size: 0.18 });
    effects.emitSmoke({ x: p.x, y: 0.5, z: p.z, count: 5, color: ST.mist, spread: r * 0.4, speed: 1.2, up: 0.5, life: 0.8, size: 1.2, shrink: -0.4 });
    effects.lightFlash(p.x, 1.2, p.z, ST.blood, 30, 0.35);
    audio.play('bloodStep', p.x, p.z);
    this.ctx.shake(0.05);
    return 'ok';
  }

  /** Grave Frost: a cold bolt runs the cone's centre line; the cone resolves when it lands. */
  private frost(t: CastTarget): CastResult {
    const { player: p, effects, avatar } = this.ctx;
    const def = ABILITIES.grave_frost;
    const G = GRAVE_FROST;
    let dx = t.x - p.x;
    let dz = t.z - p.z;
    const l = Math.hypot(dx, dz) || 1;
    dx /= l;
    dz /= l;
    p.face(p.x + dx, p.z + dz);
    avatar.cast('cast', 2.4, p.facing, CAST_FLOW.grave_frost.gestureSeconds);
    const origin = { x: p.x, z: p.z };
    const len = def.range;
    const rot = Math.atan2(dx, dz);
    const dmg = this.sp * def.power;
    const tip = avatar.tip();
    effects.flash({ x: tip.x, y: tip.y, z: tip.z, color: FR.pale, size: 0.8, duration: 0.14 });
    // The fan of frost spreads over the ground (apex at the caster) with the breath.
    effects.decal({ tex: fxImage('frostFan'), color: FR.frost, x: origin.x + dx * len * 0.5, z: origin.z + dz * len * 0.5, r: len * 0.5, rot: rot + Math.PI, duration: 0.9, opacity: 0.95, growFrom: 0.35, fadeIn: 0.08, fadeOut: 0.45 });
    for (let i = 1; i <= 4; i++) {
      const k = i / 4;
      effects.emitSmoke({ x: origin.x + dx * len * k * 0.8, y: 0.7, z: origin.z + dz * len * k * 0.8, count: 2, color: 0xb9cbe6, spread: 0.4 + k * 1.4, speed: 0.6, up: 0.3, life: 0.7, size: 1 + k * 0.6, shrink: -0.4, drag: 1 });
      effects.emit({ x: origin.x + dx * len * k * 0.85, y: 0.8, z: origin.z + dz * len * k * 0.85, count: 5, color: FR.pale, spread: 0.3 + k * 1.2, speed: 1.2, up: 0.4, life: 0.45, size: 0.14 });
    }
    audio.play('frost', origin.x + dx * 2, origin.z + dz * 2);
    const end = { x: origin.x + dx * len, y: 0.9, z: origin.z + dz * len };
    effects.projectile({
      from: tip, to: () => end, kind: 'orb', color: FR.pale, speed: G.speed,
      onArrive: () => {
        if (!p.alive) return;
        const slope = Math.tan((G.halfAngleDeg * Math.PI) / 180);
        const chilled: number[] = [];
        const shattered: number[] = [];
        let shown = 0;
        for (const e of this.ctx.enemies().values()) {
          if (e.state === 'dead') continue;
          const rx = e.x - origin.x;
          const rz = e.z - origin.z;
          const along = rx * dx + rz * dz;
          if (along < -e.radius || along > len + e.radius) continue;
          if (Math.abs(rx * dz - rz * dx) > slope * Math.max(0, along) + e.radius) continue;
          const shatter = (e.chillT ?? 0) > 0;
          (shatter ? shattered : chilled).push(e.id);
          if (shown++ < 14) {
            effects.decal({ tex: fxImage('rime'), color: FR.frost, x: e.x, z: e.z, r: 0.75 * e.scale, rot: Math.random() * 6, duration: 1.4, opacity: 0.9, growFrom: 0.4 });
            if (shatter) {
              effects.flash({ x: e.x, y: 1, z: e.z, color: FR.pale, size: 1.2, duration: 0.18 });
              effects.emit({ x: e.x, y: 1, z: e.z, count: 10, color: FR.pale, spread: 0.2, speed: 3.4, up: 2, life: 0.5, size: 0.13, gravity: 10 });
            }
            this.ctx.number(e.x, e.z, shatter ? dmg * G.shatterMult : dmg, shatter ? 'crit' : 'hit');
          }
          if (chilled.length + shattered.length >= 64) break;
        }
        if (chilled.length) this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: chilled, dmg, chill: true });
        if (shattered.length) this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: shattered, dmg: dmg * G.shatterMult, chill: true });
        const b = this.ctx.boss();
        if (b.active) {
          const rx = b.x - origin.x;
          const rz = b.z - origin.z;
          const along = rx * dx + rz * dz;
          if (along > -BOSS_RADIUS && along < len + BOSS_RADIUS && Math.abs(rx * dz - rz * dx) <= slope * Math.max(0, along) + BOSS_RADIUS) {
            this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: [], dmg, boss: true });
            this.ctx.number(b.x, b.z, dmg, 'hit');
          }
        }
        effects.lightFlash(origin.x + dx * len * 0.5, 1, origin.z + dz * len * 0.5, FR.frost, 18, 0.3);
        if (shattered.length) audio.play('needleHit', end.x, end.z, 1.4);
        this.ctx.shake(0.04);
      },
    });
    return 'ok';
  }

  /** Bone Mantle: ask the host for the corpses; the barrier arrives with its answer. */
  private mantle(): CastResult {
    const { player: p, avatar, effects } = this.ctx;
    avatar.cast('cast', 1.8, p.facing, CAST_FLOW.bone_mantle.gestureSeconds);
    this.ctx.send({ t: 'signature', by: this.ctx.selfId, sig: 'mantle', x: p.x, z: p.z, dx: 0, dz: 0, sp: this.sp });
    effects.emit({ x: p.x, y: 1.3, z: p.z, count: 18, color: MN.bone, spread: 0.5, speed: 1.4, up: 1, life: 0.5, size: 0.2 });
    return 'ok';
  }

  /**
   * The host drew corpses in. Everyone sees the tethers and the whirling shards
   * (`follow` tracks the caster); only the caster gains the barrier and the shard ticks.
   */
  onMantle(ev: Extract<SimEvent, { t: 'mantle' }>, mine: boolean, follow: () => { x: number; z: number } | null) {
    const { effects } = this.ctx;
    const M = BONE_MANTLE;
    for (const [x, z] of ev.tethers) {
      effects.beam({ x, y: 0.4, z }, () => {
        const f = follow();
        return f ? { x: f.x, y: 1.1, z: f.z } : null;
      }, MN.bone, 0.05, 0.4);
      effects.emit({ x, y: 0.4, z, count: 10, color: MN.bone, spread: 0.4, speed: 1.2, up: 1.6, life: 0.5, size: 0.16, gravity: 4 });
      effects.emitSmoke({ x, y: 0.3, z, count: 2, color: MN.dust, spread: 0.4, speed: 0.5, up: 0.4, life: 0.8, size: 0.9 });
    }
    const handle = effects.orbit({
      tex: fxImage('boneShard'),
      color: MN.bone,
      count: Math.min(14, 6 + ev.corpses * 2),
      radius: M.orbitRadius,
      y: 0.75,
      size: 0.6,
      duration: M.durationS,
      speed: 3.4,
      follow,
    });
    const ring = effects.decal({ tex: fxImage('boneRing'), color: MN.amber, x: ev.x, z: ev.z, r: M.orbitRadius + 0.5, duration: M.durationS, opacity: 0.75, growFrom: 0.4, spin: 0.5, fadeOut: 0.4, follow });
    effects.lightFlash(ev.x, 1.4, ev.z, MN.gold, 26, 0.4);
    audio.play('mantle', ev.x, ev.z);
    if (!mine) return;
    const p = this.ctx.player;
    if (!p.alive) {
      handle.kill();
      ring.kill();
      return;
    }
    const now = this.ctx.now();
    const frac = Math.min(M.barrierCap, M.barrierBase + M.barrierPerCorpse * ev.corpses);
    p.barrier = Math.max(p.barrier, p.stats.maxHp * frac);
    p.barrierHoldUntil = now + M.durationS * 1000;
    this.mantleUntil = now + M.durationS * 1000;
    this.nextShardAt = now + M.tickS * 1000;
    this.mantleFx?.kill();
    this.mantleFx = { kill: () => (handle.kill(), ring.kill()), get alive() { return handle.alive; } };
    this.ctx.shake(0.04);
  }

  /** Per frame: the caster's mantle shreds enemies beside them (client-resolved, like Marrow Spear). */
  update(now: number) {
    if (now >= this.mantleUntil) return;
    const { player: p, effects } = this.ctx;
    if (!p.alive) {
      this.mantleUntil = 0;
      p.barrierHoldUntil = 0;
      this.mantleFx?.kill();
      this.mantleFx = null;
      return;
    }
    if (now < this.nextShardAt) return;
    this.nextShardAt = now + BONE_MANTLE.tickS * 1000;
    const reach = BONE_MANTLE.orbitRadius + 0.4;
    const dmg = this.sp * ABILITIES.bone_mantle.power;
    const ids: number[] = [];
    for (const e of this.ctx.enemies().values()) {
      if (e.state === 'dead' || Math.hypot(e.x - p.x, e.z - p.z) > reach + e.radius) continue;
      ids.push(e.id);
      if (ids.length <= 6) {
        effects.emit({ x: e.x, y: 0.9, z: e.z, count: 4, color: MN.bone, spread: 0.2, speed: 2.2, up: 1, life: 0.3, size: 0.12, gravity: 8 });
        this.ctx.number(e.x, e.z, dmg, 'hit');
      }
      if (ids.length >= 64) break;
    }
    if (ids.length) {
      this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids, dmg });
      audio.play('boneHit', p.x, p.z);
    }
    const b = this.ctx.boss();
    if (b.active && Math.hypot(b.x - p.x, b.z - p.z) <= reach + BOSS_RADIUS) this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: [], dmg, boss: true });
  }

  /** Discipline signature rites: aim + spell power to the host, a cast flourish here. */
  private signature(id: AbilityId, t: CastTarget): CastResult {
    const { player: p, avatar, effects } = this.ctx;
    const sig = SIGNATURE_KIND[id]!;
    if (p.stats.level < SIGNATURE_LEVEL) return 'locked';
    if (sig === 'rend' && !this.ctx.thrallCount()) return 'no_thralls';
    const def = ABILITIES[id];
    let x = t.x;
    let z = t.z;
    const d = Math.hypot(x - p.x, z - p.z);
    if (def.range > 0 && d > def.range) {
      x = p.x + ((x - p.x) / d) * def.range;
      z = p.z + ((z - p.z) / d) * def.range;
    }
    if (sig === 'dirge') [x, z] = [p.x, p.z];
    else p.face(x, z);
    avatar.cast('cast', 1.8, p.facing, CAST_FLOW[id].gestureSeconds);
    this.ctx.send({ t: 'signature', by: this.ctx.selfId, sig, x, z, dx: x - p.x, dz: z - p.z, sp: this.sp });
    const color = sig === 'wall' ? SPELL_FX.wall.amber : sig === 'rend' ? SPELL_FX.rend.jade : sig === 'dirge' ? SPELL_FX.dirge.frost : SPELL_FX.bloom.petal;
    effects.emit({ x: p.x, y: 1.4, z: p.z, count: 24, color, spread: 0.4, speed: 1.6, up: 1.2, life: 0.6, size: 0.24 });
    effects.lightFlash(p.x, 1.8, p.z, color, 24, 0.4);
    return 'ok';
  }

  private litany(mult = 1): CastResult {
    const { player: p, avatar, discipline } = this.ctx;
    const def = ABILITIES.black_litany;
    avatar.cast('cast', 1.6, p.facing, CAST_FLOW.black_litany.gestureSeconds);
    this.ctx.send({
      t: 'litany',
      by: this.ctx.selfId,
      x: p.x,
      z: p.z,
      r: def.radius * mult,
      spellPower: this.sp,
      leaveCorpses: discipline.mods.sacrificeLeavesCorpse,
    });
    return 'ok';
  }

  /** Corpse Explosion: name the corpse; the host owns radius and modifiers. */
  private detonate(t: CastTarget): CastResult {
    const { player: p, avatar, effects } = this.ctx;
    const def = ABILITIES.corpse_explosion;
    const c = this.pickCorpse(t, ABILITIES.exhume.radius, def.range);
    if (!c) return 'no_corpse';
    p.face(c.x, c.z);
    avatar.cast('cast', 3, p.facing, CAST_FLOW.corpse_explosion.gestureSeconds);
    this.ctx.send({ t: 'detonate', by: this.ctx.selfId, corpseId: c.id, dmg: this.sp * def.power });
    const tip = avatar.tip();
    effects.flash({ x: tip.x, y: tip.y, z: tip.z, color: D.hot, size: 0.7, duration: 0.14 });
    effects.beam(tip, () => ({ x: c.x, y: 0.4, z: c.z }), D.ember, 0.05, 0.2);
    effects.decal({ tex: fx.glow(), color: D.ember, x: c.x, z: c.z, r: 1.1, duration: 0.25, opacity: 0.9, growFrom: 0.4 });
    return 'ok';
  }

  /** Everyone sees the blast when the host reports it (ember burst + bone shrapnel). */
  onDetonated(ev: Extract<SimEvent, { t: 'detonated' }>, mine: boolean) {
    if (!ev.ok) return;
    const { effects } = this.ctx;
    const { x, z, r } = ev;
    audio.play('burst', x, z);
    effects.flash({ x, y: 0.7, z, color: D.hot, size: r * 0.8, duration: 0.2 });
    effects.decal({ tex: fx.ring(), color: D.ember, x, z, r, duration: 0.45, opacity: 1, growFrom: 0.15 });
    effects.decal({ tex: fx.glow(), color: D.crimson, x, z, r: r * 0.9, duration: 0.7, opacity: 0.85, growFrom: 0.4 });
    effects.decal({ tex: fx.cracks(), color: D.crimson, x, z, r: r * 0.75, rot: Math.random() * 6, duration: 1.6, opacity: 0.85, growFrom: 0.5 });
    effects.emit({ x, y: 0.6, z, count: 24, color: D.ember, spread: 0.3, speed: r * 2.8, up: 1.6, life: 0.5, size: 0.34, drag: 1.5 });
    // Bone shrapnel: ivory flecks that arc out and rain down.
    effects.emit({ x, y: 0.7, z, count: 16, color: D.bone, spread: 0.25, speed: r * 2.3, up: 4.5, life: 0.9, size: 0.14, gravity: 14 });
    effects.emit({ x, y: 0.4, z, count: 8, color: D.crimson, spread: 0.3, speed: 2, up: 2.4, life: 0.8, size: 0.26, gravity: 6 });
    effects.emitSmoke({ x, y: 0.4, z, count: 4, color: D.smoke, spread: r * 0.35, speed: 1.4, up: 0.8, life: 0.75, size: 1.0, shrink: -0.3 });
    effects.lightFlash(x, 1.2, z, D.ember, ev.elite ? 55 : 38, 0.45);
    if (ev.corpseKind === 'resonant') {
      // A resonant corpse rings as it goes — the wider blast gets a bronze echo.
      effects.decal({ tex: fx.ring(), color: SPELL_FX.enemy.toll, x, z, r: r * 1.05, duration: 0.6, opacity: 0.8, growFrom: 0.2, delay: 0.06 });
      audio.play('tollSmall', x, z);
    }
    if (ev.corpseKind === 'toxic') {
      effects.emit({ x, y: 0.4, z, count: 24, color: M.rot, spread: 0.5, speed: 3, up: 1.4, life: 0.8, size: 0.3 });
    }
    if (ev.elite) {
      effects.decal({ tex: fx.ring(), color: D.hot, x, z, r: r * 1.2, duration: 0.5, opacity: 0.9, growFrom: 0.1, delay: 0.08 });
    }
    this.ctx.shake((mine ? 0.055 : 0.025) + (ev.elite ? 0.035 : 0));
    if (mine && ev.targets && ev.dmg) this.ctx.number(x, z, ev.dmg, ev.elite ? 'crit' : 'hit');
  }

  /** VFX + self-effects when the host reports the litany outcome. */
  onLitany(ev: { x: number; z: number; r: number; corpses: number; resonant: number; thralls: number; tethers: [number, number][] }, mine: boolean) {
    const { effects, avatar, player: p, discipline } = this.ctx;
    const tip = mine ? avatar.tip() : new THREE.Vector3(ev.x, 1.6, ev.z);
    for (const [x, z] of ev.tethers.slice(0, 10)) {
      effects.beam({ x, y: 0.6, z }, () => ({ x: tip.x, y: tip.y, z: tip.z }), L.core, 0.045, 0.5);
      effects.emit({ x, y: 0.5, z, count: 8, color: L.core, spread: 0.3, speed: 0.6, up: 1.5, life: 0.6, size: 0.3 });
    }
    // Implosion: the ring of the dead pulled in…
    effects.emit({ x: ev.x, y: 0.6, z: ev.z, count: 32, color: L.core, spread: ev.r, speed: 7, up: 0.2, life: 0.25, size: 0.22, inward: true, drag: 0 });
    effects.emitSmoke({ x: ev.x, y: 0.5, z: ev.z, count: 4, color: L.void, spread: 1, speed: 0.4, up: 0.2, life: 0.65, size: 1.3, shrink: -0.3 });
    // …then the shockwave.
    effects.decal({ tex: fx.sigil(), color: L.core, x: ev.x, z: ev.z, r: ev.r, duration: 0.7, opacity: 0.65, growFrom: 0.1, spin: 0.35 });
    effects.decal({ tex: fx.ring(), color: L.hot, x: ev.x, z: ev.z, r: ev.r * 1.15, duration: 0.55, opacity: 1, growFrom: 0.05, delay: 0.18 });
    effects.decal({ tex: fx.ring(), color: L.core, x: ev.x, z: ev.z, r: ev.r * 1.3, duration: 0.7, opacity: 0.7, growFrom: 0.05, delay: 0.26 });
    effects.emit({ x: ev.x, y: 0.5, z: ev.z, count: 48, color: L.core, spread: 1, speed: 9, up: 1.8, life: 0.55, size: 0.23 });
    effects.emit({ x: ev.x, y: 0.8, z: ev.z, count: 16, color: L.hot, spread: 0.6, speed: 5, up: 3, life: 0.45, size: 0.2 });
    effects.flash({ x: ev.x, y: 1.5, z: ev.z, color: L.core, size: Math.min(2.0, ev.r * 0.24), duration: 0.3 });
    effects.lightFlash(ev.x, 2, ev.z, L.core, 32, 0.4);
    audio.play('litany', ev.x, ev.z, 1 + Math.min(0.6, (ev.corpses + ev.thralls) * 0.05));
    this.ctx.shake(0.08 + Math.min(0.08, (ev.corpses + ev.thralls) * 0.008));
    if (!mine) return;
    const consumed = ev.corpses + ev.resonant + ev.thralls;
    if (discipline.mods.litanyBarrier) p.barrier += p.stats.maxHp * discipline.mods.litanyBarrier * consumed;
    if (discipline.mods.corpseHeal) p.heal(p.stats.maxHp * discipline.mods.corpseHeal * (ev.corpses + ev.resonant) * 0.5);
  }
}
