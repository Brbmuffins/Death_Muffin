import * as THREE from 'three';
import { ABILITIES, NEEDLE_ESSENCE, SOUL_HARVEST, SPELL_FX, type AbilityId } from '../content/abilities';
import type { Discipline } from '../content/disciplines';
import type { Effects } from '../graphics/Effects';
import type { NecromancerAvatar } from '../graphics/Avatars';
import { fx } from '../graphics/fxTextures';
import { BOSS_RADIUS } from './sim/BossBrain';
import type { BossState, Corpse, Enemy, Intent, SimEvent } from './sim/types';
import type { Player } from './Player';
import { audio } from '../audio/Audio';

export type CastResult = 'ok' | 'cooldown' | 'essence' | 'range' | 'no_target' | 'no_corpse' | 'dead';

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

/**
 * Casts the shared necromancer kit. Client-side targeting + VFX, then an
 * Intent to the authoritative sim (local when solo/host, relayed otherwise).
 * Scenes never branch on spell ids — they call cast().
 */
export class AbilitySystem {
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
    return p.alive && !p.onCooldown(id, now) && (this.empowered(id) || p.essence >= ABILITIES[id].essenceCost);
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
    }
    if (result === 'ok') {
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
    effects.emit({ x: p.x, y: 0.4, z: p.z, count: 36, color: SOUL.jade, spread: 0.6, speed: 1.2, up: 3.2, life: 0.8, size: 0.3 });
    effects.emit({ x: p.x, y: 1.4, z: p.z, count: 14, color: SOUL.pale, spread: 0.3, speed: 2.4, up: 1, life: 0.5, size: 0.22 });
    effects.lightFlash(p.x, 1.6, p.z, SOUL.jade, 26, 0.45);
    audio.play('shard', p.x, p.z);
  }

  private needle(t: CastTarget): CastResult {
    const { player: p, effects, avatar } = this.ctx;
    if (t.enemyId === undefined && !t.boss) return 'no_target';
    if (this.shortfall('bone_needle', t) > 0) return 'range';
    p.face(t.x, t.z);
    p.rootedUntil = this.ctx.now() + 120;
    avatar.cast('cast', 3.2);
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
    p.rootedUntil = this.ctx.now() + 220;
    avatar.cast('cast', 2.4);
    const halfW = radius + 0.2;
    const ids: number[] = [];
    for (const e of this.ctx.enemies().values()) {
      if (e.state === 'dead') continue;
      const rx = e.x - p.x;
      const rz = e.z - p.z;
      const along = rx * dx + rz * dz;
      const across = Math.abs(rx * dz - rz * dx);
      if (along > 0 && along < range && across < halfW + e.radius) ids.push(e.id);
    }
    const dmg = this.sp * def.power;
    if (ids.length) this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids, dmg, fracture: 1 });
    const b = this.ctx.boss();
    if (b.active) {
      const rx = b.x - p.x;
      const rz = b.z - p.z;
      const along = rx * dx + rz * dz;
      if (along > 0 && along < range + BOSS_RADIUS && Math.abs(rx * dz - rz * dx) < halfW + BOSS_RADIUS) {
        this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: [], dmg, fracture: 1, boss: true });
        this.ctx.number(b.x, b.z, dmg, 'spear');
      }
    }
    for (const id of ids) {
      const e = this.ctx.enemies().get(id);
      if (e) this.ctx.number(e.x, e.z, dmg, 'spear');
    }
    effects.spikeLine(p.x, p.z, dx, dz, range, radius * 1.6);
    effects.decal({ tex: fx.cracks(), color: S.crack, x: p.x + dx * range * 0.5, z: p.z + dz * range * 0.5, r: range * 0.5, sx: 0.22 * mult, rot: Math.atan2(dx, dz), duration: 1.1, opacity: 0.75 });
    for (let i = 1; i < 11; i++) {
      const x = p.x + dx * i * 1.1 * mult;
      const z = p.z + dz * i * 1.1 * mult;
      effects.emitSmoke({ x, y: 0.2, z, count: 2, color: S.dust, spread: 0.5, speed: 0.9, up: 0.9, life: 1.1, size: 1.1, shrink: -0.6 });
      effects.emit({ x, y: 0.3, z, count: 3, color: i % 3 ? S.bone : S.marrow, spread: 0.3, speed: 1.6, up: 3, life: 0.6, size: 0.14, gravity: 9 });
    }
    effects.lightFlash(p.x + dx * 4, 1, p.z + dz * 4, S.crack, 16, 0.35);
    audio.play('spear', p.x + dx * 3, p.z + dz * 3);
    this.ctx.shake(0.15);
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
    p.rootedUntil = this.ctx.now() + 250;
    avatar.cast('dig', 2.6);
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
    p.rootedUntil = this.ctx.now() + 200;
    avatar.cast('cast', 2.2);
    const r = def.radius * discipline.mods.miasmaRadiusMult * mult;
    this.ctx.send({
      t: 'miasma',
      by: this.ctx.selfId,
      x,
      z,
      r,
      dps: this.sp * def.power,
      durationMs: 6000,
      witheredCap: discipline.mods.witheredMaxStacks,
      bloom: discipline.mods.miasmaBurstsCorpses,
    });
    effects.projectile({
      from: avatar.tip(),
      to: () => ({ x, y: 0.2, z }),
      kind: 'orb',
      color: M.rot,
      speed: 18,
      arc: 30,
      onArrive: () => {
        audio.play('miasma', x, z);
        effects.emitSmoke({ x, y: 0.4, z, count: 14, color: M.spore, spread: r * 0.6, speed: 1.2, up: 0.5, life: 2.2, size: 2.2, shrink: -0.8, drag: 0.8 });
        effects.emit({ x, y: 0.3, z, count: 30, color: M.rot, spread: r * 0.5, speed: 1.5, up: 1, life: 1.2, size: 0.25 });
      },
    });
    return 'ok';
  }

  private litany(mult = 1): CastResult {
    const { player: p, avatar, discipline } = this.ctx;
    const def = ABILITIES.black_litany;
    p.rootedUntil = this.ctx.now() + 450;
    avatar.cast('cast', 1.6);
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
    p.rootedUntil = this.ctx.now() + 150;
    avatar.cast('cast', 3);
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
    effects.emit({ x, y: 0.6, z, count: 46, color: D.ember, spread: 0.3, speed: r * 2.8, up: 1.6, life: 0.5, size: 0.34, drag: 1.5 });
    // Bone shrapnel: ivory flecks that arc out and rain down.
    effects.emit({ x, y: 0.7, z, count: 30, color: D.bone, spread: 0.25, speed: r * 2.3, up: 4.5, life: 0.9, size: 0.14, gravity: 14 });
    effects.emit({ x, y: 0.4, z, count: 14, color: D.crimson, spread: 0.3, speed: 2, up: 2.4, life: 0.8, size: 0.26, gravity: 6 });
    effects.emitSmoke({ x, y: 0.4, z, count: 7, color: D.smoke, spread: r * 0.35, speed: 1.4, up: 0.8, life: 1.3, size: 1.5, shrink: -0.8 });
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
    this.ctx.shake((mine ? 0.18 : 0.08) + (ev.elite ? 0.1 : 0));
    if (mine && ev.targets && ev.dmg) this.ctx.number(x, z, ev.dmg, ev.elite ? 'crit' : 'hit');
  }

  /** VFX + self-effects when the host reports the litany outcome. */
  onLitany(ev: { x: number; z: number; r: number; corpses: number; resonant: number; thralls: number; tethers: [number, number][] }, mine: boolean) {
    const { effects, avatar, player: p, discipline } = this.ctx;
    const tip = mine ? avatar.tip() : new THREE.Vector3(ev.x, 1.6, ev.z);
    for (const [x, z] of ev.tethers) {
      effects.beam({ x, y: 0.6, z }, () => ({ x: tip.x, y: tip.y, z: tip.z }), L.core, 0.045, 0.5);
      effects.emit({ x, y: 0.5, z, count: 8, color: L.core, spread: 0.3, speed: 0.6, up: 1.5, life: 0.6, size: 0.3 });
    }
    // Implosion: the ring of the dead pulled in…
    effects.emit({ x: ev.x, y: 0.6, z: ev.z, count: 90, color: L.core, spread: ev.r, speed: 7, up: 0.2, life: 0.35, size: 0.4, inward: true, drag: 0 });
    effects.emitSmoke({ x: ev.x, y: 0.5, z: ev.z, count: 10, color: L.void, spread: 1, speed: 0.5, up: 0.4, life: 1.2, size: 2.6, shrink: -1 });
    // …then the shockwave.
    effects.decal({ tex: fx.sigil(), color: L.core, x: ev.x, z: ev.z, r: ev.r, duration: 1.2, opacity: 1, growFrom: 0.1, spin: 1.5 });
    effects.decal({ tex: fx.ring(), color: L.hot, x: ev.x, z: ev.z, r: ev.r * 1.15, duration: 0.55, opacity: 1, growFrom: 0.05, delay: 0.18 });
    effects.decal({ tex: fx.ring(), color: L.core, x: ev.x, z: ev.z, r: ev.r * 1.3, duration: 0.7, opacity: 0.7, growFrom: 0.05, delay: 0.26 });
    effects.emit({ x: ev.x, y: 0.5, z: ev.z, count: 140, color: L.core, spread: 1, speed: 9, up: 1.8, life: 0.9, size: 0.42 });
    effects.emit({ x: ev.x, y: 0.8, z: ev.z, count: 40, color: L.hot, spread: 0.6, speed: 5, up: 3, life: 0.7, size: 0.3 });
    effects.flash({ x: ev.x, y: 1.5, z: ev.z, color: L.core, size: ev.r * 0.55, duration: 0.3 });
    effects.lightFlash(ev.x, 2, ev.z, L.core, 70, 0.8);
    audio.play('litany', ev.x, ev.z, 1 + Math.min(0.6, (ev.corpses + ev.thralls) * 0.05));
    this.ctx.shake(0.35 + Math.min(0.4, (ev.corpses + ev.thralls) * 0.04));
    if (!mine) return;
    const consumed = ev.corpses + ev.resonant + ev.thralls;
    if (discipline.mods.litanyBarrier) p.barrier += p.stats.maxHp * discipline.mods.litanyBarrier * consumed;
    if (discipline.mods.corpseHeal) p.heal(p.stats.maxHp * discipline.mods.corpseHeal * (ev.corpses + ev.resonant) * 0.5);
  }
}
