import { riteLevel } from './devAccess';
import * as THREE from 'three';
import {
  ABILITIES,
  BONE_FAN,
  BONE_MANTLE,
  BONE_PRISON,
  BONE_STORM,
  GRAVE_HANDS,
  SOUL_SIPHON,
  CARRION_SEED,
  DETONATE,
  GRAVE_OFFERING,
  IVORY_CLEAVE,
  RALLY,
  ROT_LANCE,
  VEIL_STEP,
  FRACTURE,
  GRAVE_FROST,
  GRAVE_STEP,
  NEEDLE_ESSENCE,
  SIGNATURE_KIND,
  SIGNATURE_LEVEL,
  SOUL_HARVEST,
  SPELL_FX,
  HOLLOW_CUT,
  SHIELD_BASH,
  GRAVE_SLAM,
  BULWARK,
  CORPSE_VIGIL,
  GRAVE_BRAND,
  OATH_UNBROKEN,
  WAILING_SKULL,
  unlockLevel,
  PRIMARIES,
  type AbilityId,
} from '../content/abilities';
import type { Discipline } from '../content/disciplines';
import type { Effects, Handle } from '../graphics/Effects';
import type { NecromancerAvatar } from '../graphics/Avatars';
import { fx } from '../graphics/fxTextures';
import { fxImage } from '../graphics/fxImages';
import { BOSS_RADIUS } from './sim/BossBrain';
import type { BossState, Corpse, Enemy, Intent, SimEvent, Thrall } from './sim/types';
import type { Player } from './Player';
import { LEGEND, effectiveWitheredCap, shatterDamage, wardReflectDamage } from './legendary';
import { audio } from '../audio/Audio';
import { HEMORRHAGE } from '../content/statuses';
import { CAST_FLOW } from '../content/combatFlow';
import { playFx } from '../graphics/binbun/presets';
import * as nf from '../graphics/necroFx';
import type { BinbunHandle, BinbunSpawn } from '../graphics/binbun/BinbunFX';
import type { BinbunId } from '../graphics/binbun/catalog';
import { NewBloodSystem } from './NewBloodSystem';
import { NECRO_WEAPON_TUNING } from '../content/necroWeapons';
import { abilityCooldownMs, abilityLockMs, abilityRange, pierceTargets, reapTargets } from './weaponLine';
import { RUNES, RUNE_TUNING, type RuneId, type RuneRite } from '../content/runes';
import { corpsesWithin, impaleTarget, ringCenter, ringHits, splinterTarget, volleyTargets } from './runeCast';

/**
 * Veil Step's destination: walk from (x, z) toward (tx, tz) in small steps and keep the last point
 * that is walkable and still in the starting hall (so it never crosses a sealed door or wall).
 */
export function veilTarget(nav: { blocked(x: number, z: number, r: number): boolean; areaAt(x: number, z: number): unknown }, x: number, z: number, tx: number, tz: number) {
  const area = nav.areaAt(x, z);
  const n = Math.max(1, Math.ceil(Math.hypot(tx - x, tz - z) / VEIL_STEP.stepM));
  let best = { x, z };
  for (let i = 1; i <= n; i++) {
    const px = x + ((tx - x) * i) / n;
    const pz = z + ((tz - z) * i) / n;
    if (nav.blocked(px, pz, 0.45) || nav.areaAt(px, pz) !== area) break;
    best = { x: px, z: pz };
  }
  return best;
}

/** Dead, or underground (a tunnelling or surfacing ghoul): the host refuses every blow, so no rite should draw a number on it. */
const gone = (e: Enemy) => e.state === 'dead' || e.state === 'burrow' || (e.erupting != null && e.state === 'windup');

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
  /** Floating text over the caster (heals, barriers). Optional for tests. */
  note?(text: string, kind: 'heal' | 'ward'): void;
  /** Scene clock (ms) — never this.ctx.now(), so QA stepping stays consistent. */
  now(): number;
  /** Thralls (Rally the Dead visuals follow them). Optional for tests. */
  thralls?(): Map<number, Thrall>;
  /** Veil Step: the furthest valid point toward (tx, tz), walked in small steps, never past a sealed door or out of the hall. */
  dash?(tx: number, tz: number): { x: number; z: number };
  /** Current ground cursor, for effects that follow the aim point. */
  aim?(): { x: number; z: number };
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
const LN = SPELL_FX.lance;
const VL = SPELL_FX.veil;
const RD = SPELL_FX.rend;
const BL = SPELL_FX.bloom;
const KN = SPELL_FX.knight;
const SI = SPELL_FX.siphon;
const PR = SPELL_FX.prison;
const GH = SPELL_FX.hands;
const BS = SPELL_FX.storm;

type Vec3 = { x: number; y: number; z: number };

/**
 * Casts the shared necromancer kit. Client-side targeting + VFX, then an
 * Intent to the authoritative sim (local when solo/host, relayed otherwise).
 * Scenes never branch on spell ids — they call cast().
 */
export class AbilitySystem {
  private newBlood: NewBloodSystem;
  /** Bone Mantle (client-owned): when it ends, the next shard tick, and its orbit visuals. */
  private mantleUntil = 0;
  private nextShardAt = 0;
  private mantleFx: Handle | null = null;
  /** Veil Step in flight (lerped in update). */
  private dashing: { fx: number; fz: number; tx: number; tz: number; start: number; dur: number; onArrive?: () => void } | null = null;
  /** Carrion Seed buds shown on corpses (any caster's), by corpse id. */
  private seeds = new Map<number, Handle>();
  /** Carrion Seed Binbun cores, by corpse id. */
  private seedCores = new Map<number, BinbunHandle>();
  /** Persistent client-resolved rites (Soul Siphon, Grave Hands, Bone Storm), ticked from update(). */
  private timed: { until: number; next: number; every: number; tick: (now: number) => boolean | void; end?: () => void }[] = [];
  /** Hollow Knight — Corpse Vigil regenerates until this time (scene ms). */
  private vigilUntil = 0;
  private lastVigilAt = 0;

  /** Bone Needle casts so far (the Volley rune fires on every 4th). */
  private needleCasts = 0;
  /** The last Exhume raised a Bone Colossus (its cooldown is longer). */
  private colossusCast = false;

  constructor(private ctx: AbilityContext) { this.newBlood = new NewBloodSystem(ctx); }

  /** The rune socketed in a rite, if any. Runes change the rite's behaviour; auto combat, hotkeys and the mouse all cast through here. */
  rune(rite: RuneRite): RuneId | undefined {
    const id = this.ctx.player.runes[rite];
    return id && RUNES[id]?.rite === rite ? id : undefined;
  }

  /** The realtime socket id replaces the provisional solo id once connected. */
  setSelf(id: string) {
    this.ctx.selfId = id;
  }

  /** Layer a Binbun effect (presets.ts). A no-op without the runtime (unit tests stub Effects). */
  private bb(id: BinbunId, x: number, z: number, o: Omit<BinbunSpawn, 'x' | 'z'> = {}): BinbunHandle | null {
    const b = this.ctx.effects.binbun;
    return b ? playFx(b, id, { x, z, ...o }) : null;
  }

  private get sp() {
    const p = this.ctx.player;
    // Oath Unbroken raises every blow for its window; 1 for every other family.
    const oath = this.ctx.now() < p.unbreakableUntil ? OATH_UNBROKEN.damageMult : 1;
    // The active elixir's damage effect (Forge-tempered +15%, Moonlit +25%, ...).
    const flask = 1 + p.brewValue('damage', this.ctx.now());
    return p.stats.spellPower * oath * flask;
  }

  ready(id: AbilityId, now: number) {
    const p = this.ctx.player;
    return p.alive && this.unlocked(id) && now >= p.castUntil && !p.onCooldown(id, now) && (this.empowered(id) || p.essence >= ABILITIES[id].essenceCost);
  }

  /** Grimoire and signature rites wait for their level. */
  unlocked(id: AbilityId) {
    return riteLevel(this.ctx.player.stats.level) >= unlockLevel(id);
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
    return Math.max(0, Math.hypot(t.x - p.x, t.z - p.z) - (abilityRange(id, def.range, p.loadout) + pad));
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
        result = p.loadout.reap ? this.reap(target) : this.needle(target);
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
      case 'bone_fan':
        result = this.fan(target);
        break;
      case 'rot_lance':
        result = this.lance(target);
        break;
      case 'grave_offering':
        result = this.offering(target);
        break;
      case 'ivory_cleave':
        result = this.cleave(target);
        break;
      case 'veil_step':
        result = this.veil(target);
        break;
      case 'rally_dead':
        result = this.rally(target);
        break;
      case 'carrion_seed':
        result = this.seed(target);
        break;
      case 'soul_siphon':
        result = this.siphon(target, now);
        break;
      case 'bone_prison':
        result = this.prison(target);
        break;
      case 'grave_hands':
        result = this.hands(target, now);
        break;
      case 'bone_storm':
        result = this.storm(target, now);
        break;
      case 'hollow_cut':
        result = this.hollowCut(target);
        break;
      case 'shield_bash':
        result = this.shieldBash(target);
        break;
      case 'grave_slam':
        result = this.graveSlam(target);
        break;
      case 'bulwark':
        result = this.bulwark(now);
        break;
      case 'corpse_vigil':
        result = this.corpseVigil(target);
        break;
      case 'grave_brand':
        result = this.graveBrand(target);
        break;
      case 'oath_unbroken':
        result = this.oathUnbroken(now);
        break;
      case 'ossuary_wall':
      case 'command_rend':
      case 'dirge':
      case 'plague_bloom':
        result = this.signature(id, target);
        break;
      default:
        result = this.newBlood.cast(id, target, now) ?? 'no_target';
        break;
    }
    if (result === 'ok') {
      p.castUntil = now + abilityLockMs(id, CAST_FLOW[id].lockMs, p.loadout);
      p.rootedUntil = Math.max(p.rootedUntil, p.castUntil);
      if (empowered) {
        p.spendSouls();
        this.soulRelease();
        this.wraithNova();
      } else p.essence -= def.essenceCost;
      // A Ritual Sickle gives back a share of Exhume's essence (none was spent on an empowered cast).
      if (id === 'exhume' && !empowered && p.loadout.exhumeRefund > 0) p.essence = Math.min(p.stats.maxEssence, p.essence + def.essenceCost * p.loadout.exhumeRefund);
      // Apply weapon cooldown changes and elixir haste when the cooldown starts.
      // Bone Colossus: raising a giant takes Exhume out of your hands for a while.
      const runeCool = id === 'exhume' && this.colossusCast ? RUNE_TUNING.colossus.cooldownMult : 1;
      p.cooldowns.set(id, now + (abilityCooldownMs(id, def.cooldownMs, p.loadout, PRIMARIES.includes(id)) * runeCool) / (1 + p.brewValue('haste', now)));
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
    // The harvested souls leave as a spiral of motes and two skull faces, rather than another flash.
    nf.soulMotes(effects, p.x, p.z, SOUL.pale, { r: 1.1, n: 10, y: 0.3, up: 2.2 });
    nf.skullWisps(effects, p.x, p.z, SOUL.pale, { n: 2, r: 0.7, y: 1.0, size: 0.55, rise: 1.2 });
    this.bb('soul_harvest_pillar', p.x, p.z);
    audio.play('soulRelease', p.x, p.z);
  }

  private needle(t: CastTarget): CastResult {
    const { player: p, effects, avatar } = this.ctx;
    if (t.enemyId === undefined && !t.boss) return 'no_target';
    if (this.shortfall('bone_needle', t) > 0) return 'range';
    p.face(t.x, t.z);
    avatar.cast('cast', 3.2, p.facing, CAST_FLOW.bone_needle.gestureSeconds, 'bone_needle');
    const from = avatar.tip();
    effects.flash({ x: from.x, y: from.y, z: from.z, color: N.trail, size: 0.7, duration: 0.14 });
    audio.play('needleCast', p.x, p.z);
    const lo = p.loadout;
    const rune = this.rune('bone_needle');
    // Weapon line: a wand's needle strikes softer (but faster); a sickle's leaves the target Withered; a staff's pierces on.
    // Marrow-Tap trades a third of the damage for essence; the Volley's needles each carry half.
    const volley = rune === 'rune_volley' && ++this.needleCasts % RUNE_TUNING.volley.every === 0;
    const runeMult = rune === 'rune_marrow_tap' ? RUNE_TUNING.marrowTap.damageMult : volley ? RUNE_TUNING.volley.damageFrac : 1;
    const dmg = this.sp * ABILITIES.bone_needle.power * lo.needleDamageMult * runeMult * (0.9 + Math.random() * 0.2);
    const essence = NEEDLE_ESSENCE + (rune === 'rune_marrow_tap' ? RUNE_TUNING.marrowTap.essenceBonus : 0);
    if (!volley) {
      this.launchNeedle(t, from, dmg, essence, rune === 'rune_splinter');
      return 'ok';
    }
    // Volley: this needle and two more, at the enemies nearest the target (or all at the target when it stands alone).
    const aim: CastTarget[] = [t];
    if (!t.boss && t.enemyId !== undefined) {
      const live = [...this.ctx.enemies().values()].filter((e) => !gone(e));
      const first = live.find((e) => e.id === t.enemyId);
      if (first) for (const e of volleyTargets({ x: p.x, z: p.z }, first, live).slice(1)) aim.push({ x: e.x, z: e.z, enemyId: e.id });
    }
    while (aim.length < RUNE_TUNING.volley.needles) aim.push(t);
    // The volley returns what one needle would (an even share each), so it is a damage rune, not an essence one.
    aim.forEach((tt, i) => {
      const spread = { x: from.x + (i - 1) * 0.12, y: from.y, z: from.z };
      this.launchNeedle(tt, spread, dmg, essence / RUNE_TUNING.volley.needles, false, i * 0.05);
    });
    nf.boneSplinters(effects, from.x, from.y, from.z, { n: 5, color: N.core, speed: 3.5 });
    effects.decal({ tex: fx.ring(), color: N.trail, x: p.x, z: p.z, r: 1.3, duration: 0.35, opacity: 0.55, growFrom: 0.4 });
    return 'ok';
  }

  /** One needle in flight: damage on arrival, essence back, and (Splinters) a shard to the nearest other enemy. */
  private launchNeedle(t: CastTarget, from: Vec3, dmg: number, essence: number, splinters: boolean, delayS = 0) {
    const { player: p, effects } = this.ctx;
    const lo = p.loadout;
    const enemyId = t.enemyId;
    const withered = lo.needleWithered > 0 ? { withered: lo.needleWithered, witheredCap: effectiveWitheredCap(this.ctx.discipline.mods) } : {};
    const crit = Math.random() < 0.08;
    const go = () => effects.projectile({
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
          this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: [enemyId!], dmg: amount, ...withered });
          if (lo.needlePierce > 0) this.pierceBeyond(enemyId!, pos, dmg * NECRO_WEAPON_TUNING.staff.pierceDamageMult, lo.needlePierce, withered);
          if (splinters) this.splinter(enemyId!, pos, dmg);
        }
        p.essence = Math.min(p.stats.maxEssence, p.essence + essence);
        audio.play('needleHit', pos.x, pos.z, crit ? 1.4 : 1);
        effects.flash({ x: pos.x, y: pos.y, z: pos.z, color: N.impact, size: crit ? 1.7 : 1.05, duration: 0.2 });
        effects.emit({ x: pos.x, y: pos.y, z: pos.z, count: crit ? 16 : 8, color: N.dust, spread: 0.1, speed: 3.2, up: 1.2, life: 0.4, size: 0.13, gravity: 7 });
        if (crit) effects.emit({ x: pos.x, y: pos.y, z: pos.z, count: 10, color: N.trail, spread: 0.2, speed: 4, up: 0.5, life: 0.3, size: 0.3 });
        // Bone splinters spit off the struck body (the needle is a sliver of bone).
        nf.boneSplinters(effects, pos.x, pos.y, pos.z, { n: crit ? 7 : 3, color: N.core });
        // Needles fire constantly (auto combat): only crits get the extra layer, so farming stays calm.
        if (crit) this.bb('crit_hit', pos.x, pos.z, { y: pos.y });
        this.ctx.number(pos.x, pos.z, amount, crit ? 'crit' : 'hit');
      },
    });
    if (delayS > 0) this.timed.push({ until: this.ctx.now() + delayS * 1000 + 50, next: this.ctx.now() + delayS * 1000, every: 1e9, tick: () => { go(); return true; } });
    else go();
  }

  /** Splinters rune: a shard of the needle flies to the nearest other enemy for half the damage. */
  private splinter(firstId: number, at: { x: number; z: number }, dmg: number) {
    const { effects } = this.ctx;
    const first = this.ctx.enemies().get(firstId);
    const pool = [...this.ctx.enemies().values()].filter((e) => !gone(e));
    const e = splinterTarget(first ?? { id: firstId, x: at.x, z: at.z }, pool);
    if (!e) return;
    const amount = dmg * RUNE_TUNING.splinter.damageFrac;
    this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: [e.id], dmg: amount });
    effects.beam({ x: at.x, y: 1, z: at.z }, () => ({ x: e.x, y: 1, z: e.z }), N.core, 0.03, 0.16);
    effects.flash({ x: e.x, y: 1, z: e.z, color: N.core, size: 0.7, duration: 0.16 });
    nf.boneSplinters(effects, e.x, 1, e.z, { n: 3, color: N.core });
    nf.boneSplinters(effects, at.x, 1, at.z, { n: 6, color: N.core, speed: 4.5 });
    this.ctx.number(e.x, e.z, amount, 'hit');
  }

  /** Staff needle: it carries on through the nearest enemy behind its target, in its lane. */
  private pierceBeyond(firstId: number, at: { x: number; z: number }, dmg: number, count: number, extra: { withered?: number; witheredCap?: number }) {
    const { player: p, effects } = this.ctx;
    const pool = [];
    for (const e of this.ctx.enemies().values()) if (!gone(e)) pool.push(e);
    const next = pierceTargets({ x: p.x, z: p.z }, { x: at.x, z: at.z, id: firstId }, pool, count);
    if (!next.length) return;
    this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: next.map((e) => e.id), dmg, ...extra });
    for (const e of next) {
      effects.beam({ x: at.x, y: 1, z: at.z }, () => ({ x: e.x, y: 1, z: e.z }), N.trail, 0.02, 0.12);
      effects.flash({ x: e.x, y: 1, z: e.z, color: N.impact, size: 0.8, duration: 0.16 });
      effects.emit({ x: e.x, y: 1, z: e.z, count: 6, color: N.dust, spread: 0.1, speed: 3, up: 1, life: 0.35, size: 0.12, gravity: 7 });
      nf.boneSplinters(effects, e.x, 1, e.z, { n: 3, color: N.core });
      this.ctx.number(e.x, e.z, dmg, 'hit');
    }
    audio.play('needleHit', next[0].x, next[0].z, 0.8);
  }

  /** Enemy ids struck by a scythe arc, with the scene time they count as reaped until. */
  private reaped = new Map<number, number>();

  /** Extra souls for a kill the scythe arc delivered (the scene calls this from its death handler). */
  reapedSouls(enemyId: number): number {
    const until = this.reaped.get(enemyId);
    if (until === undefined) return 0;
    this.reaped.delete(enemyId);
    return this.ctx.now() <= until ? NECRO_WEAPON_TUNING.scythe.soulsPerKill : 0;
  }

  /**
   * Scythe: the left click becomes a close reaping arc, client-resolved like Ivory Cleave (the caster's client picks the
   * targets from its own view and sends one hit intent, so a relayed cast never double-hits or desyncs). Kills the arc
   * delivers are remembered so the death handler can pay the bonus soul.
   */
  private reap(t: CastTarget): CastResult {
    const { player: p, effects, avatar } = this.ctx;
    const T = NECRO_WEAPON_TUNING.scythe;
    if (t.enemyId === undefined && !t.boss) return 'no_target';
    if (this.shortfall('bone_needle', t) > 0) return 'range';
    let dx = t.x - p.x;
    let dz = t.z - p.z;
    const l = Math.hypot(dx, dz) || 1;
    dx /= l;
    dz /= l;
    p.face(p.x + dx, p.z + dz);
    avatar.cast('attack', 2.6, p.facing, T.gestureSeconds);
    const dmg = this.sp * ABILITIES.bone_needle.power * T.damageMult * (0.9 + Math.random() * 0.2);
    const pool = [];
    for (const e of this.ctx.enemies().values()) if (!gone(e)) pool.push(e);
    const struck = reapTargets({ x: p.x, z: p.z }, { x: t.x, z: t.z }, pool);
    const b = this.ctx.boss();
    const hitBoss = b.active && reapTargets({ x: p.x, z: p.z }, { x: t.x, z: t.z }, [{ x: b.x, z: b.z, radius: BOSS_RADIUS }]).length > 0;
    const now = this.ctx.now();
    if (this.reaped.size > 64) for (const [id, until] of this.reaped) if (until < now) this.reaped.delete(id);
    // The boss takes a slot of the three if it is nearer than the last enemy; keep the cap honest.
    const slots = Math.max(0, T.maxHits - (hitBoss ? 1 : 0));
    const hits = struck.slice(0, slots);
    if (hits.length) this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: hits.map((e) => e.id), dmg });
    if (hitBoss) this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: [], dmg, boss: true });
    for (const e of hits) {
      this.reaped.set(e.id, now + T.reapWindowMs);
      this.ctx.number(e.x, e.z, dmg, 'hit');
      effects.emit({ x: e.x, y: 0.9, z: e.z, count: 7, color: N.dust, spread: 0.2, speed: 3, up: 1.2, life: 0.4, size: 0.13, gravity: 7 });
      effects.flash({ x: e.x, y: 1, z: e.z, color: N.impact, size: 0.9, duration: 0.16 });
      nf.boneSplinters(effects, e.x, 0.9, e.z, { n: 4, color: N.core });
    }
    if (hitBoss) {
      this.ctx.number(b.x, b.z, dmg, 'hit');
      effects.flash({ x: b.x, y: 1.6, z: b.z, color: N.impact, size: 1.2, duration: 0.18 });
    }
    const landed = hits.length + (hitBoss ? 1 : 0);
    if (landed) p.essence = Math.min(p.stats.maxEssence, p.essence + T.essencePerHit * landed);
    const rot = Math.atan2(dx, dz);
    effects.decal({ tex: fxImage('crescent'), color: N.trail, x: p.x + dx * 1.3, z: p.z + dz * 1.3, r: 2.0, rot, duration: 0.32, opacity: 0.95, growFrom: 0.6, fadeOut: 0.25 });
    effects.lightFlash(p.x + dx * 1.3, 1, p.z + dz * 1.3, N.trail, 10, 0.16);
    // The scythe drags the grave with it: dirt and dust kicked up along the arc's edge.
    nf.graveDirt(effects, p.x + dx * 1.5, p.z + dz * 1.5, { r: 0.7, n: 5 });
    audio.play('spear', p.x, p.z, 1.1);
    if (landed) audio.play('boneHit', p.x + dx * 1.8, p.z + dz * 1.8);
    return 'ok';
  }

  /** `mult` > 1 when Soul Harvest empowers the cast (longer, wider line). */
  private spear(t: CastTarget, mult = 1): CastResult {
    const { player: p, effects, avatar } = this.ctx;
    const def = ABILITIES.marrow_spear;
    const rune = this.rune('marrow_spear');
    const ring = rune === 'rune_ossuary_ring';
    const impale = rune === 'rune_impale';
    const range = def.range * mult;
    const radius = def.radius * mult;
    // Ossuary Ring: the spear flies to the cursor (within its reach) and bursts there in a ring instead of a line.
    const centre = ring ? ringCenter({ x: p.x, z: p.z }, { x: t.x, z: t.z }, RUNE_TUNING.ring.maxCastRange * mult) : null;
    let dx = (centre?.x ?? t.x) - p.x;
    let dz = (centre?.z ?? t.z) - p.z;
    const len = Math.hypot(dx, dz) || 1;
    dx /= len;
    dz /= len;
    p.face(p.x + dx, p.z + dz);
    avatar.cast('cast', 2.4, p.facing, CAST_FLOW.marrow_spear.gestureSeconds, 'marrow_spear');
    const origin = { x: p.x, z: p.z };
    const dmg = this.sp * def.power;
    const end = centre ? { x: centre.x, y: 0.3, z: centre.z } : { x: origin.x + dx * range, y: 0.3, z: origin.z + dz * range };
    const tip = avatar.tip();
    // A clean ivory release precedes the eruption. Resolve the live line on
    // impact, rather than hurting enemies before any bone reaches them.
    effects.flash({ x: tip.x, y: tip.y, z: tip.z, color: S.bone, size: 0.65, duration: 0.12 });
    effects.beam(tip, () => end, S.bone, 0.025, 0.16);
    effects.projectile({
      from: tip, to: () => end, kind: 'needle', color: S.bone, speed: 48,
      onArrive: () => {
        if (!p.alive) return;
        if (centre) return this.spearRing(centre, RUNE_TUNING.ring.radius * mult, dmg * RUNE_TUNING.ring.damageMult);
        const halfW = radius + 0.2;
        if (impale) return this.spearImpale(origin, dx, dz, range, halfW, dmg * RUNE_TUNING.impale.damageMult, end);
        const ids: number[] = [];
        for (const e of this.ctx.enemies().values()) {
          if (gone(e)) continue;
          const rx = e.x - origin.x;
          const rz = e.z - origin.z;
          const along = rx * dx + rz * dz;
          if (along > 0 && along < range && Math.abs(rx * dz - rz * dx) < halfW + e.radius) {
            ids.push(e.id);
            this.ctx.number(e.x, e.z, dmg, 'spear');
            effects.flash({ x: e.x, y: 0.8, z: e.z, color: S.bone, size: 0.65, duration: 0.14 });
          }
        }
        const rally = this.ctx.discipline.mods.spearRally > 0 ? { spear: true } : {};
        if (ids.length) this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids, dmg, fracture: 1, bleed: dmg * HEMORRHAGE.dpsFrac, ...rally });
        const b = this.ctx.boss();
        if (b.active) {
          const rx = b.x - origin.x;
          const rz = b.z - origin.z;
          const along = rx * dx + rz * dz;
          if (along > 0 && along < range + BOSS_RADIUS && Math.abs(rx * dz - rz * dx) < halfW + BOSS_RADIUS) {
            this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: [], dmg, fracture: 1, boss: true, ...(ids.length ? {} : rally) });
            this.ctx.number(b.x, b.z, dmg, 'spear');
          }
        }
        effects.spikeLine(origin.x, origin.z, dx, dz, range, radius * 1.3, false);
        effects.decal({ tex: fx.cracks(), color: S.crack, x: origin.x + dx * range * 0.5, z: origin.z + dz * range * 0.5, r: range * 0.5, sx: 0.16 * mult, rot: Math.atan2(dx, dz), duration: 0.65, opacity: 0.55 });
        for (let i = 1; i <= 6; i++) {
          const x = origin.x + dx * (i / 6) * range;
          const z = origin.z + dz * (i / 6) * range;
          effects.emit({ x, y: 0.3, z, count: 3, color: S.bone, spread: 0.25, speed: 1.4, up: 2.1, life: 0.4, size: 0.12, gravity: 9 });
          // Grave dirt thrown up where the bone breaks the ground, and chips off the spike tips.
          if (i % 2 === 0) nf.graveDirt(effects, x, z, { r: radius * 0.8, n: 4 * mult });
        }
        nf.boneSplinters(effects, end.x, 0.6, end.z, { n: 6, color: S.bone, speed: 4.5 });
        effects.lightFlash(origin.x + dx * 4, 1, origin.z + dz * 4, S.crack, 12, 0.22);
        audio.play('spear', origin.x + dx * 3, origin.z + dz * 3);
        this.ctx.shake(0.055);
      },
    });
    return 'ok';
  }

  /** Ossuary Ring rune: bone erupts in a ring around `c`, striking everything inside it (Fracture and Hemorrhage as for the line). */
  private spearRing(c: { x: number; z: number }, r: number, dmg: number) {
    const { effects } = this.ctx;
    const foes = [...this.ctx.enemies().values()].filter((e) => !gone(e));
    const hit = ringHits(c, r, foes);
    for (const e of hit) {
      this.ctx.number(e.x, e.z, dmg, 'spear');
      effects.flash({ x: e.x, y: 0.8, z: e.z, color: S.bone, size: 0.65, duration: 0.14 });
    }
    if (hit.length) this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: hit.map((e) => e.id), dmg, fracture: 1, bleed: dmg * HEMORRHAGE.dpsFrac, ...(this.ctx.discipline.mods.spearRally > 0 ? { spear: true } : {}) });
    const b = this.ctx.boss();
    if (b.active && Math.hypot(b.x - c.x, b.z - c.z) <= r + BOSS_RADIUS) {
      this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: [], dmg, fracture: 1, boss: true, ...(hit.length ? {} : (this.ctx.discipline.mods.spearRally > 0 ? { spear: true } : {})) });
      this.ctx.number(b.x, b.z, dmg, 'spear');
    }
    // A rim of tall spikes, an inner ring, a spoke cracked into the ground and a hard shake: a circle of bone, not a line.
    effects.spikeRing(c.x, c.z, r * 0.95, Math.round(10 + r * 3), 1.1);
    effects.spikeRing(c.x, c.z, r * 0.5, 6, 0.9);
    effects.decal({ tex: fx.ring(), color: S.bone, x: c.x, z: c.z, r: r * 1.05, duration: 0.7, opacity: 0.85, growFrom: 0.3 });
    effects.decal({ tex: fx.cracks(), color: S.crack, x: c.x, z: c.z, r, duration: 0.8, opacity: 0.6, rot: Math.random() * 6 });
    nf.graveDirt(effects, c.x, c.z, { r: r * 0.8, n: 8, up: 3 });
    nf.boneSplinters(effects, c.x, 0.6, c.z, { n: 8, color: S.bone, speed: 4.5 });
    effects.lightFlash(c.x, 1, c.z, S.crack, 14, 0.25);
    audio.play('spear', c.x, c.z);
    this.ctx.shake(0.07);
  }

  /** Impaling rune: the spear stops at the first enemy it meets, skewers it for more and roots it. */
  private spearImpale(origin: { x: number; z: number }, dx: number, dz: number, range: number, halfW: number, dmg: number, end: { x: number; z: number }) {
    const { effects } = this.ctx;
    const foes = [...this.ctx.enemies().values()].filter((e) => !gone(e));
    const hit = impaleTarget(origin, dx, dz, range, halfW, foes);
    const b = this.ctx.boss();
    let bossAlong = Infinity;
    if (b.active) {
      const rx = b.x - origin.x;
      const rz = b.z - origin.z;
      const along = rx * dx + rz * dz;
      if (along > 0 && along < range + BOSS_RADIUS && Math.abs(rx * dz - rz * dx) < halfW + BOSS_RADIUS) bossAlong = along;
    }
    if (!hit && bossAlong === Infinity) {
      // Nothing to skewer: the spear sinks into the ground at the end of its reach.
      effects.spikeLine(origin.x, origin.z, dx, dz, 2, 0.6, false);
      nf.graveDirt(effects, end.x, end.z, { r: 0.6, n: 4 });
      audio.play('spear', end.x, end.z);
      return;
    }
    let tx: number, tz: number, along: number;
    if (hit && hit.along <= bossAlong) {
      const e = hit.foe;
      this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: [e.id], dmg, fracture: 1, bleed: dmg * HEMORRHAGE.dpsFrac, root: true, rootS: RUNE_TUNING.impale.rootS, ...(this.ctx.discipline.mods.spearRally > 0 ? { spear: true } : {}) });
      this.ctx.number(e.x, e.z, dmg, 'spear');
      [tx, tz, along] = [e.x, e.z, hit.along];
      // The roots that hold it: a cage of bone around the body.
      effects.spikeRing(e.x, e.z, 0.95, 9, RUNE_TUNING.impale.rootS + 0.1);
      effects.decal({ tex: fx.ring(), color: S.crack, x: e.x, z: e.z, r: 1.3, duration: RUNE_TUNING.impale.rootS, opacity: 0.7, growFrom: 0.5, fadeOut: 0.4 });
    } else {
      // A boss shrugs the root off but takes the blow.
      this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: [], dmg, fracture: 1, boss: true, ...(this.ctx.discipline.mods.spearRally > 0 ? { spear: true } : {}) });
      this.ctx.number(b.x, b.z, dmg, 'spear');
      [tx, tz, along] = [b.x, b.z, bossAlong];
    }
    effects.spikeLine(origin.x, origin.z, dx, dz, Math.max(1.5, along), 0.5, false);
    effects.flash({ x: tx, y: 1, z: tz, color: S.bone, size: 1.4, duration: 0.2 });
    nf.boneSplinters(effects, tx, 1, tz, { n: 8, color: S.bone, speed: 4.5 });
    effects.lightFlash(tx, 1, tz, S.crack, 14, 0.25);
    audio.play('spear', tx, tz);
    this.ctx.shake(0.06);
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
    // Only the dead of the hall you stand in: a body behind a wall is out of reach (a thrall raised there would be stranded).
    const here = (c: Corpse) => !p.area || !c.area || c.area === p.area;
    for (const c of this.ctx.corpses().values()) {
      if (!here(c)) continue;
      const d = Math.hypot(c.x - t.x, c.z - t.z);
      if (d < bestD && Math.hypot(c.x - p.x, c.z - p.z) <= range) {
        bestD = d;
        best = c;
      }
    }
    if (best) return best;
    bestD = 7;
    for (const c of this.ctx.corpses().values()) {
      if (!here(c)) continue;
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
    const rune = this.rune('exhume');
    const mass = rune === 'rune_mass_grave';
    // Bone Colossus needs company: at least three corpses lying within reach of the one you named, and no Colossus standing already.
    // Otherwise the rite raises an ordinary thrall, so the legion can still be filled around the giant.
    const company = rune === 'rune_bone_colossus' ? corpsesWithin(c, RUNE_TUNING.colossus.pickRadius, this.ctx.corpses().values()).slice(0, RUNE_TUNING.colossus.corpses) : [];
    const standing = [...(this.ctx.thralls?.().values() ?? [])].some((t) => t.owner === this.ctx.selfId && t.kind === 'colossus' && t.state !== 'dead');
    const colossus = company.length >= RUNE_TUNING.colossus.minCorpses && !standing;
    this.colossusCast = colossus;
    p.face(c.x, c.z);
    avatar.cast('dig', 2.6, p.facing, CAST_FLOW.exhume.gestureSeconds, 'exhume');
    const m = discipline.mods;
    this.ctx.send({
      t: 'exhume',
      by: this.ctx.selfId,
      x: c.x,
      z: c.z,
      r: colossus ? RUNE_TUNING.colossus.pickRadius : mass ? RUNE_TUNING.massGrave.pickRadius : 0.8,
      kind: m.thrallKind,
      cap: m.thrallCap,
      hp: p.stats.thrallHp,
      damage: p.stats.thrallDamage,
      attackSpeedMult: m.thrallAttackSpeedMult,
      ...(p.loadout.bellAllyHeal > 0 ? { allyHeal: p.loadout.bellAllyHeal } : {}),
      ...(mass ? { count: RUNE_TUNING.massGrave.count } : {}),
      ...(colossus ? { colossus: true } : {}),
    });
    effects.beam(avatar.tip(), () => ({ x: c.x, y: 0.3, z: c.z }), X.beam, 0.06, 0.4);
    audio.play('exhume', c.x, c.z);
    effects.emit({ x: c.x, y: 0.2, z: c.z, count: 26, color: X.spirit, spread: 0.6, speed: 0.4, up: 3.4, life: 1, size: 0.34, gravity: -0.5 });
    effects.decal({ tex: fx.cracks(), color: X.deep, x: c.x, z: c.z, r: 1.4, rot: Math.random() * 6, duration: 1.3, opacity: 0.9, growFrom: 0.3 });
    // Clawing the dead out of the earth: thrown soil, reaching hands, a soul-light that lifts away.
    nf.graveDirt(effects, c.x, c.z, { r: 0.6, n: 9, up: 3 });
    nf.spectralHands(effects, c.x, c.z, { n: 3, r: 0.6, duration: 1.2 });
    nf.spiritWisps(effects, c.x, c.z, X.spirit, { n: 2, r: 0.3, y: 0.5, size: 0.7 });
    this.bb('exhume_lift', c.x, c.z);
    if (mass) {
      // Mass Grave: the other graves in reach open too (jade beams from the caster to each).
      for (const o of corpsesWithin(c, RUNE_TUNING.massGrave.pickRadius, this.ctx.corpses().values()).slice(0, RUNE_TUNING.massGrave.count)) {
        if (o.id === c.id) continue;
        effects.beam(avatar.tip(), () => ({ x: o.x, y: 0.3, z: o.z }), X.beam, 0.04, 0.35);
        effects.decal({ tex: fx.cracks(), color: X.deep, x: o.x, z: o.z, r: 1.2, rot: Math.random() * 6, duration: 1.2, opacity: 0.9, growFrom: 0.3 });
        nf.graveDirt(effects, o.x, o.z, { r: 0.5, n: 6, up: 2.6 });
        nf.spectralHands(effects, o.x, o.z, { n: 2, r: 0.5, duration: 1.1 });
        effects.emit({ x: o.x, y: 0.2, z: o.z, count: 18, color: X.spirit, spread: 0.5, speed: 0.4, up: 3, life: 1, size: 0.3, gravity: -0.5 });
      }
    } else if (colossus) {
      // The bones are drawn together: a jade thread from each corpse to the centre, motes streaming in, a ring of the Covenant's colour.
      const cx = company.reduce((a, o) => a + o.x, 0) / company.length;
      const cz = company.reduce((a, o) => a + o.z, 0) / company.length;
      for (const o of company) {
        effects.beam({ x: o.x, y: 0.4, z: o.z }, () => ({ x: cx, y: 1.2, z: cz }), X.beam, 0.05, 0.7);
        effects.emit({ x: o.x, y: 0.3, z: o.z, count: 14, color: X.spirit, spread: 0.4, speed: 2.2, up: 1.2, life: 0.8, size: 0.3 });
        nf.boneSplinters(effects, o.x, 0.4, o.z, { n: 5, color: N.core, speed: 3 });
      }
      effects.decal({ tex: fx.sigil(), color: X.spirit, x: cx, z: cz, r: 3.2, duration: 1.4, opacity: 0.8, growFrom: 1.4, spin: 0.8 });
      effects.decal({ tex: fx.ring(), color: X.beam, x: cx, z: cz, r: 3.6, duration: 0.9, opacity: 0.9, growFrom: 0.4 });
      effects.emit({ x: cx, y: 0.4, z: cz, count: 36, color: X.spirit, spread: 3, speed: 5, up: 0.4, life: 0.5, size: 0.3, inward: true, drag: 0 });
      effects.lightFlash(cx, 1.5, cz, X.spirit, 34, 0.9);
      this.ctx.shake(0.1);
    }
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
    avatar.cast('cast', 2.2, p.facing, CAST_FLOW.miasma.gestureSeconds, 'miasma');
    const rune = this.rune('miasma');
    // Creeping Rot gives up a little width for a circle that walks to its prey.
    const r = def.radius * discipline.mods.miasmaRadiusMult * mult * (rune === 'rune_creeping_rot' ? RUNE_TUNING.creepingRot.radiusMult : 1);
    const intent: Intent = {
      t: 'miasma',
      by: this.ctx.selfId,
      x,
      z,
      r,
      dps: this.sp * def.power,
      durationMs: 6000,
      witheredCap: effectiveWitheredCap(discipline.mods),
      bloom: discipline.mods.miasmaBurstsCorpses,
      ...(rune === 'rune_creeping_rot' ? { creep: RUNE_TUNING.creepingRot.speed } : {}),
      ...(rune === 'rune_contagion' ? { contagion: true } : {}),
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
        // Rot spores drift up out of the cloud and hang in the air.
        nf.rotSpores(effects, x, z, M.rot, { r: r * 0.75, n: Math.round(8 + r * 2) });
        // A creeping circle gets its cloud from the zone view, which follows it as it drifts.
        if (rune !== 'rune_creeping_rot') this.bb('miasma_cloud', x, z, { scale: r / 3.8 });
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
        if (e.state === 'dead' || (e.state === 'rising' || e.state === 'burrow') || e.hp <= 0) continue;
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
    avatar.cast('cast', 2.8, p.facing, CAST_FLOW.wailing_skull.gestureSeconds, 'wailing_skull');
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
    const shot = effects.projectile({
      from,
      kind: 'sprite',
      tex: fxImage('skull'),
      size: 0.95,
      color: SK.jade,
      speed: W.speed,
      // A wail of soul-light motes hangs in the air behind the skull.
      onTrail: (pos) => nf.soulMotes(effects, pos.x, pos.z, SK.jade, { r: 0.1, n: 1, y: pos.y - 0.1, up: 0.5 }),
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
          nf.boneSplinters(effects, pos.x, pos.y, pos.z, { n: killed ? 6 : 3, color: SK.pale });
          this.ctx.number(pos.x, pos.z, dmg, killed ? 'crit' : 'hit');
        }
        const left = budget - 1 + (killed ? 1 : 0);
        if (left <= 0 || hop >= W.maxHops) return;
        // Leap on to the nearest enemy the skull hasn't bitten yet.
        let next: CastTarget | null = null;
        let bestD = W.leapRange;
        for (const e of this.ctx.enemies().values()) {
          if (e.state === 'dead' || (e.state === 'rising' || e.state === 'burrow') || e.hp <= 0 || struck.has(e.id)) continue;
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
    this.bb('wailing_skull_projectile', from.x, from.z, { y: from.y, follow: shot.pos });
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
    // You leave the earth scuffed and a few red soul-lights where you stood.
    nf.graveDirt(effects, ox, oz, { r: 0.5, n: 6 });
    nf.soulMotes(effects, ox, oz, ST.blood, { r: 0.4, n: 4, up: 1.4 });
    this.bb('grave_step_smoke', ox, oz, { duration: 1.4 });
    p.teleport(c.x, c.z);
    p.face(p.x + (p.x - ox), p.z + (p.z - oz));
    avatar.cast('cast', 3, p.facing, CAST_FLOW.grave_step.gestureSeconds, 'grave_step');
    effects.beam({ x: ox, y: 1, z: oz }, () => ({ x: p.x, y: 1, z: p.z }), ST.blood, 0.07, 0.22);
    // …and re-forms in a marrow burst that bleeds what stands around the corpse.
    const r = GRAVE_STEP.burstRadius;
    const dmg = this.sp * def.power;
    const ids: number[] = [];
    for (const e of this.ctx.enemies().values()) {
      if (gone(e) || Math.hypot(e.x - p.x, e.z - p.z) > r + e.radius) continue;
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
    // You tear up out of the grave: dirt, and bone chips knocked off the corpse.
    nf.graveDirt(effects, p.x, p.z, { r: r * 0.5, n: 8, up: 3 });
    nf.boneSplinters(effects, p.x, 0.5, p.z, { n: 6 });
    // (Played once: without a duration the converted smoke loops until culled and was leaving a red blob behind.)
    this.bb('grave_step_smoke', p.x, p.z, { scale: 1.2, duration: 1.4 });
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
    avatar.cast('cast', 2.4, p.facing, CAST_FLOW.grave_frost.gestureSeconds, 'grave_frost');
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
    // Hoarfrost cracks the ground along the breath, and the cold carries a whisper of grave mist.
    nf.crackedGround(effects, origin.x + dx * len * 0.5, origin.z + dz * len * 0.5, len * 0.5, FR.pale, { rot, sx: 0.5, duration: 1.8, opacity: 0.4 });
    for (let i = 1; i <= 3; i++) nf.mistWhisper(effects, origin.x + dx * len * i * 0.28, origin.z + dz * len * i * 0.28, 0x8fa6c8, { r: 0.5 + i * 0.5, n: 2 });
    this.bb('grave_frost_mist', origin.x + dx * len * 0.45, origin.z + dz * len * 0.45, { rot });
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
          if (gone(e)) continue;
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
              if (shown <= 3) this.bb('frost_shard_hit', e.x, e.z);
              effects.flash({ x: e.x, y: 1, z: e.z, color: FR.pale, size: 1.2, duration: 0.18 });
              effects.emit({ x: e.x, y: 1, z: e.z, count: 10, color: FR.pale, spread: 0.2, speed: 3.4, up: 2, life: 0.5, size: 0.13, gravity: 10 });
              if (shown <= 4) nf.boneSplinters(effects, e.x, 1, e.z, { n: 4, color: FR.pale });
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

  // --- Grimoire expansion: Soul Siphon, Bone Prison, Grave Hands, Bone Storm ---

  private tickTimed(now: number) {
    if (!this.timed.length) return;
    const alive = this.ctx.player.alive;
    for (let i = this.timed.length - 1; i >= 0; i--) {
      const t = this.timed[i];
      let done = !alive || now >= t.until;
      while (!done && now >= t.next) {
        t.next += t.every;
        if (t.tick(now) === false) done = true;
      }
      if (done) {
        t.end?.();
        this.timed.splice(i, 1);
      }
    }
  }

  /** Clamp a ground aim to the rite's reach. */
  private groundAim(id: AbilityId, t: CastTarget) {
    const p = this.ctx.player;
    const range = ABILITIES[id].range;
    let x = t.x;
    let z = t.z;
    const d = Math.hypot(x - p.x, z - p.z);
    if (d > range) {
      x = p.x + ((x - p.x) / d) * range;
      z = p.z + ((z - p.z) / d) * range;
    }
    return { x, z };
  }

  /** Enemy ids within r of a point (capped like every client-resolved hit), plus whether the Prelate is in it. */
  private inCircle(x: number, z: number, r: number) {
    const ids: number[] = [];
    for (const e of this.ctx.enemies().values()) {
      if (e.state === 'dead' || (e.state === 'rising' || e.state === 'burrow') || Math.hypot(e.x - x, e.z - z) > r + e.radius) continue;
      ids.push(e.id);
      if (ids.length >= 64) break;
    }
    const b = this.ctx.boss();
    return { ids, boss: b.active && b.hp > 0 && Math.hypot(b.x - x, b.z - z) <= r + BOSS_RADIUS };
  }

  private corpsesIn(x: number, z: number, r: number) {
    let n = 0;
    for (const c of this.ctx.corpses().values()) if (!c.echoOwner && Math.hypot(c.x - x, c.z - z) <= r) n++;
    return n;
  }

  /** Soul Siphon: a jade tether that follows the target, draining every half second into health and essence. */
  private siphon(t: CastTarget, now: number): CastResult {
    const { player: p, effects, avatar } = this.ctx;
    const def = ABILITIES.soul_siphon;
    const S = SOUL_SIPHON;
    if (t.enemyId === undefined && !t.boss) return 'no_target';
    if (this.shortfall('soul_siphon', t) > 0) return 'range';
    p.face(t.x, t.z);
    avatar.cast('cast', 2.4, p.facing, CAST_FLOW.soul_siphon.gestureSeconds, 'soul_siphon');
    const breakR = def.range * S.breakMult + (t.boss ? BOSS_RADIUS : 0);
    let ended = false;
    const target = () => {
      if (ended || !p.alive) return null;
      let q: Vec3 | null = null;
      if (t.boss) {
        const b = this.ctx.boss();
        if (b.active && b.hp > 0) q = { x: b.x, y: 2.2, z: b.z };
      } else {
        const e = this.ctx.enemies().get(t.enemyId!);
        // A ghoul that digs in breaks the tether (the host would refuse every drain anyway).
        if (e && e.state !== 'dead' && e.state !== 'burrow') q = { x: e.x, y: 1.1, z: e.z };
      }
      return q && Math.hypot(q.x - p.x, q.z - p.z) <= breakR ? q : null;
    };
    const caster = () => (ended || !p.alive ? null : { x: p.x, y: 1.4, z: p.z });
    const beams = [effects.beam(caster, target, SI.deep, 0.1, S.durationS), effects.beam(caster, target, SI.jade, 0.055, S.durationS), effects.beam(caster, target, SI.pale, 0.02, S.durationS)];
    const first = target();
    const core = first ? this.bb('soul_orb', first.x, first.z, { follow: () => target(), duration: S.durationS, colors: [SI.jade, SI.pale, SI.deep] }) : null;
    this.bb('soul_siphon_beam', p.x, p.z, { follow: () => caster(), duration: S.durationS });
    audio.play('siphon', p.x, p.z);
    const dmg = this.sp * def.power;
    let drains = 0;
    this.timed.push({
      until: now + S.durationS * 1000,
      next: now + S.tickS * 1000,
      every: S.tickS * 1000,
      tick: () => {
        const q = target();
        if (!q) return false;
        if (t.boss) this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: [], dmg, boss: true });
        else this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: [t.enemyId!], dmg });
        this.ctx.number(q.x, q.z, dmg, 'hit');
        p.heal(dmg * S.healFrac);
        p.addResource(S.essencePerTick);
        // Motes strung along the tether, drifting toward the caster: the drain reads even at a glance.
        for (let k = 0; k < 6; k++) {
          const f = (k + Math.random()) / 6;
          effects.emit({ x: q.x + (p.x - q.x) * f, y: q.y + (1.4 - q.y) * f, z: q.z + (p.z - q.z) * f, count: 1, color: k % 2 ? SI.pale : SI.jade, spread: 0.08, speed: 0.2, up: 0.1, life: 0.3, size: 0.22 });
        }
        effects.emit({ x: q.x, y: q.y, z: q.z, count: 5, color: SI.pale, spread: 0.25, speed: 0.6, up: 0.3, life: 0.35, size: 0.16 });
        effects.emit({ x: p.x, y: 1.3, z: p.z, count: 3, color: SI.jade, spread: 0.2, speed: 0.3, up: 0.6, life: 0.4, size: 0.18 });
        // The soul is drawn up out of the body: a faint skull above the target on every other pull.
        if (++drains % 2 === 1) nf.skullWisps(effects, q.x, q.z, SI.pale, { n: 1, y: q.y + 0.3, size: 0.5, rise: 0.9, duration: 0.7 });
      },
      end: () => {
        ended = true;
        beams.forEach((b) => b.kill());
        core?.kill();
      },
    });
    return 'ok';
  }

  /** Bone Prison: a caging ring of spikes; everything inside is rooted (host-owned duration) and Fractured. */
  private prison(t: CastTarget): CastResult {
    const { player: p, effects, avatar } = this.ctx;
    const def = ABILITIES.bone_prison;
    const P = BONE_PRISON;
    const { x, z } = this.groundAim('bone_prison', t);
    p.face(x, z);
    avatar.cast('cast', 2.3, p.facing, CAST_FLOW.bone_prison.gestureSeconds, 'bone_prison');
    const r = def.radius;
    effects.spikeRing(x, z, r, P.spikes, P.rootS + 0.1);
    effects.decal({ tex: fx.cracks(), color: PR.dust, x, z, r: r * 1.1, rot: Math.random() * 6, duration: P.rootS + 0.4, opacity: 0.8, growFrom: 0.6, fadeOut: 0.4 });
    effects.decal({ tex: fxImage('boneRing'), color: PR.amber, x, z, r: r + 0.3, duration: P.rootS, opacity: 0.4, growFrom: 0.8, fadeOut: 0.3 });
    effects.emitSmoke({ x, y: 0.3, z, count: 6, color: PR.dust, spread: r * 0.8, speed: 0.9, up: 0.5, life: 0.9, size: 1.1 });
    effects.emit({ x, y: 0.4, z, count: 18, color: PR.bone, spread: r, speed: 1.8, up: 2.2, life: 0.5, size: 0.12, gravity: 9 });
    // The cage tears up the grave: soil at the foot of every spike, and splinters off the bars.
    for (let i = 0; i < 6; i++) {
      const a = (i / 6) * Math.PI * 2;
      nf.graveDirt(effects, x + Math.cos(a) * r * 0.9, z + Math.sin(a) * r * 0.9, { r: 0.35, n: 3 });
    }
    nf.boneSplinters(effects, x, 0.9, z, { n: 10, color: PR.bone, speed: r * 1.6 });
    this.bb('bone_prison_burst', x, z, { scale: r / 2.4 });
    audio.play('prison', x, z);
    this.ctx.shake(0.06);
    const dmg = this.sp * def.power;
    const { ids, boss } = this.inCircle(x, z, r);
    if (ids.length) {
      this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids, dmg, fracture: P.fracture, root: true });
      for (const id of ids.slice(0, 6)) {
        const e = this.ctx.enemies().get(id);
        if (e) this.ctx.number(e.x, e.z, dmg, 'hit');
      }
    }
    if (boss) this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: [], dmg, boss: true, fracture: P.fracture });
    return 'ok';
  }

  /** Grave Hands: a slowing field of clawing hands; corpses inside at cast time add hands and damage. */
  private hands(t: CastTarget, now: number): CastResult {
    const { player: p, effects, avatar } = this.ctx;
    const def = ABILITIES.grave_hands;
    const G = GRAVE_HANDS;
    const { x, z } = this.groundAim('grave_hands', t);
    p.face(x, z);
    avatar.cast('dig', 2.2, p.facing, CAST_FLOW.grave_hands.gestureSeconds, 'grave_hands');
    const r = def.radius;
    const corpses = Math.min(G.maxCorpses, this.corpsesIn(x, z, r));
    const hands = Math.min(G.maxHands, G.hands + corpses * G.handsPerCorpse);
    const visual = effects.graveHands(x, z, r, hands, G.durationS);
    const ground = effects.decal({ tex: fx.disc(), color: GH.earth, x, z, r, duration: G.durationS, opacity: 0.7, growFrom: 0.5, fadeOut: 0.4 });
    const seep = effects.decal({ tex: fx.cracks(), color: GH.seep, x, z, r: r * 0.95, rot: Math.random() * 6, duration: G.durationS, opacity: 0.35, pulse: 2, fadeOut: 0.4 });
    effects.emitSmoke({ x, y: 0.2, z, count: 8, color: GH.earth, spread: r * 0.7, speed: 0.8, up: 0.6, life: 1, size: 1.2 });
    // The ground heaves where the hands break through.
    for (let i = 0; i < 5; i++) {
      const a = i * 2.4;
      nf.graveDirt(effects, x + Math.cos(a) * r * 0.55, z + Math.sin(a) * r * 0.55, { r: 0.4, n: 3 });
    }
    this.bb('grave_hands_pulse', x, z, { scale: r / 3.5 });
    audio.play('hands', x, z);
    const dmg = this.sp * def.power * (1 + G.perCorpse * corpses);
    this.timed.push({
      until: now + G.durationS * 1000,
      next: now + 60,
      every: G.tickS * 1000,
      tick: () => {
        const { ids, boss } = this.inCircle(x, z, r);
        if (ids.length) this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids, dmg, slow: true });
        if (boss) this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: [], dmg, boss: true });
        for (const id of ids.slice(0, 4)) {
          const e = this.ctx.enemies().get(id);
          if (e) effects.emit({ x: e.x, y: 0.4, z: e.z, count: 3, color: GH.bone, spread: 0.3, speed: 1.2, up: 1.2, life: 0.35, size: 0.1, gravity: 8 });
        }
        // A spirit seeps up through the earth between the hands.
        const a = Math.random() * Math.PI * 2;
        const d = Math.sqrt(Math.random()) * r * 0.85;
        nf.soulMotes(effects, x + Math.cos(a) * d, z + Math.sin(a) * d, GH.seep, { r: 0.25, n: 2, y: 0.15, up: 0.9 });
      },
      end: () => {
        visual.kill();
        ground.kill();
        seep.kill();
      },
    });
    return 'ok';
  }

  /** Bone Storm: a funnel of real bone fragments that drifts toward the nearest enemy, shredding what it passes. */
  private storm(t: CastTarget, now: number): CastResult {
    const { player: p, effects, avatar } = this.ctx;
    const def = ABILITIES.bone_storm;
    const B = BONE_STORM;
    const start = this.groundAim('bone_storm', t);
    p.face(start.x, start.z);
    avatar.cast('cast', 2, p.facing, CAST_FLOW.bone_storm.gestureSeconds, 'bone_storm');
    const r = def.radius;
    const extra = Math.min(B.maxExtraS, this.corpsesIn(start.x, start.z, r) * B.perCorpseS);
    const life = B.durationS + extra;
    const c = { x: start.x, z: start.z };
    let ended = false;
    const follow = () => (ended ? null : c);
    const bones = effects.boneOrbit({ fallbackTex: fxImage('boneShard'), fallbackColor: BS.bone, count: B.shards, radius: r * 0.8, y: 0.25, size: 0.34, duration: life, speed: 7, follow, funnel: true });
    const dust = this.bb('bone_storm_dust', c.x, c.z, { follow, duration: life, colors: [BS.bone, BS.ash, BS.dust] });
    const ring = effects.decal({ tex: fx.ring(), color: BS.ash, x: c.x, z: c.z, r, duration: life, opacity: 0.35, spin: 2, fadeOut: 0.4, follow });
    audio.play('storm', c.x, c.z);
    const dmg = this.sp * def.power;
    let last = now;
    this.timed.push({
      until: now + life * 1000,
      next: now + B.tickS * 1000,
      every: B.tickS * 1000,
      tick: (tNow) => {
        // Drift toward the nearest living enemy within seekR (walkable space is the ground it sweeps).
        const dt = Math.min(1, (tNow - last) / 1000);
        last = tNow;
        let best: { x: number; z: number } | null = null;
        let bestD = B.seekR;
        for (const e of this.ctx.enemies().values()) {
          if (e.state === 'dead' || e.state === 'rising' || e.state === 'burrow') continue;
          const d = Math.hypot(e.x - c.x, e.z - c.z);
          if (d < bestD) (bestD = d), (best = e);
        }
        if (best && bestD > 0.3) {
          const step = Math.min(bestD, B.drift * dt);
          c.x += ((best.x - c.x) / bestD) * step;
          c.z += ((best.z - c.z) / bestD) * step;
        }
        const { ids, boss } = this.inCircle(c.x, c.z, r);
        if (ids.length) this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids, dmg });
        if (boss) this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: [], dmg, boss: true });
        if (ids.length) audio.play('boneHit', c.x, c.z);
        effects.emitSmoke({ x: c.x, y: 0.4, z: c.z, count: 3, color: BS.ash, spread: r * 0.4, speed: 0.9, up: 1.4, life: 0.9, size: 1.1, shrink: -0.4 });
        // Splinters shed off the funnel, and grave dirt is sucked up with it.
        nf.boneSplinters(effects, c.x, 0.8, c.z, { n: ids.length ? 6 : 3, color: BS.bone, speed: r * 1.2 });
        nf.graveDirt(effects, c.x, c.z, { r: r * 0.5, n: 3, up: 3 });
      },
      end: () => {
        ended = true;
        bones.kill();
        dust?.kill();
        ring.kill();
      },
    });
    return 'ok';
  }

  /** Bone Mantle: ask the host for the corpses; the barrier arrives with its answer. */
  private mantle(): CastResult {
    const { player: p, avatar, effects } = this.ctx;
    avatar.cast('cast', 1.8, p.facing, CAST_FLOW.bone_mantle.gestureSeconds, 'bone_mantle');
    this.ctx.send({ t: 'signature', by: this.ctx.selfId, sig: 'mantle', x: p.x, z: p.z, dx: 0, dz: 0, sp: this.sp });
    effects.emit({ x: p.x, y: 1.3, z: p.z, count: 18, color: MN.bone, spread: 0.5, speed: 1.4, up: 1, life: 0.5, size: 0.2 });
    nf.graveDirt(effects, p.x, p.z, { r: 0.8, n: 5 });
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
      // The dead are stripped to the bone: a few chips fly toward their new owner.
      nf.boneSplinters(effects, x, 0.5, z, { n: 3, color: MN.bone, origin: mine ? 'player' : 'thrall' });
    }
    // Real bone fragments (instanced, lit, matte) rather than tinted sprites, which read as a ring of bananas.
    const handle = effects.boneOrbit({
      fallbackTex: fxImage('boneShard'),
      fallbackColor: MN.bone,
      count: Math.min(15, 6 + ev.corpses * 2),
      radius: M.orbitRadius,
      y: 0.7,
      size: 0.5,
      duration: M.durationS,
      speed: 3.4,
      follow,
    });
    const ring = effects.decal({ tex: fxImage('boneRing'), color: MN.amber, x: ev.x, z: ev.z, r: M.orbitRadius + 0.5, duration: M.durationS, opacity: 0.45, growFrom: 0.4, spin: 0.5, fadeOut: 0.4, follow });
    effects.lightFlash(ev.x, 1.4, ev.z, MN.gold, 26, 0.4);
    audio.play('mantle', ev.x, ev.z);
    if (!mine) return;
    const p = this.ctx.player;
    if (ev.corpses > 0) this.onCorpseConsumed();
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

  // ---------------------------------------------------------------------------
  // Legendary set mechanics that resolve on the caster's own client (docs/LEGENDARY-SETS.md). Damage goes out as ordinary
  // 'hit' intents, so a co-op guest's set works against the host's sim with no extra protocol. Every number is a mod or LEGEND.
  // ---------------------------------------------------------------------------

  /** Requiem wisps (client-owned): each orbits the caster and heals; at most LEGEND.wispCap at once. */
  private wisps: { born: number; until: number; nextHeal: number; speed: number; radius: number; fx: Handle }[] = [];

  get wispCount() {
    return this.wisps.length;
  }

  /** A corpse of yours was consumed (Exhume, Litany, Offering, Mantle, Corpse Explosion): Requiem 4 summons a healing wisp. */
  onCorpseConsumed() {
    const { player: p, effects } = this.ctx;
    const secs = this.ctx.discipline.mods.corpseWisp;
    if (!(secs > 0) || !p.alive) return;
    const now = this.ctx.now();
    if (this.wisps.length >= LEGEND.wispCap) {
      // At the cap a new corpse renews the wisp that would fade first instead of adding another.
      const w = this.wisps.reduce((a, b) => (a.until <= b.until ? a : b));
      w.until = now + secs * 1000;
      w.fx.kill();
      w.fx = this.wispFx(w, secs, p);
      return;
    }
    const n = this.wisps.length;
    const w = { born: now, until: now + secs * 1000, nextHeal: now + 1000, speed: 2.1 + n * 0.45, radius: 1.15 + n * 0.28, fx: null as unknown as Handle };
    w.fx = this.wispFx(w, secs, p);
    this.wisps.push(w);
    effects.emit({ x: p.x, y: 1.2, z: p.z, count: 6, color: SOUL.pale, spread: 0.3, speed: 1.2, up: 0.8, life: 0.45, size: 0.16 });
  }

  /** One orbiting wisp: a single additive sprite (no light). */
  private wispFx(w: { speed: number; radius: number }, secs: number, p: Player): Handle {
    return this.ctx.effects.orbit({ tex: fxImage('wisp'), color: SOUL.jade, count: 1, radius: w.radius, y: 1.5, size: 0.6, duration: secs, speed: w.speed, follow: () => ({ x: p.x, z: p.z }) });
  }

  /** Where a wisp is now (for the nova it releases). */
  private wispAt(w: { born: number; speed: number; radius: number }, now: number) {
    const p = this.ctx.player;
    const t = Math.max(0, (now - w.born) / 1000);
    const a = t * w.speed;
    const r = w.radius * Math.min(1, 0.25 + t * 3);
    return { x: p.x + Math.cos(a) * r, z: p.z + Math.sin(a) * r };
  }

  private tickWisps(now: number) {
    if (!this.wisps.length) return;
    const p = this.ctx.player;
    let heal = 0;
    for (let i = this.wisps.length - 1; i >= 0; i--) {
      const w = this.wisps[i];
      if (!p.alive || now >= w.until) {
        w.fx.kill();
        this.wisps.splice(i, 1);
        continue;
      }
      while (now >= w.nextHeal && w.nextHeal < w.until) {
        heal += p.stats.maxHp * LEGEND.wispHealFrac;
        w.nextHeal += 1000;
      }
    }
    if (heal > 0 && p.alive) {
      p.heal(heal);
      if (heal >= 1) this.ctx.note?.(`+${Math.round(heal)}`, 'heal');
    }
  }

  /** Requiem 5: Soul Harvest empowered a rite, so every wraith (thrall) and wisp of yours releases a nova (capped, one sound). */
  private wraithNova() {
    const k = this.ctx.discipline.mods.wraithNova;
    const { player: p, effects } = this.ctx;
    if (!(k > 0) || !p.alive) return;
    const now = this.ctx.now();
    const src: { x: number; z: number }[] = this.wisps.map((w) => this.wispAt(w, now));
    for (const t of this.ctx.thralls?.().values() ?? []) if (t.owner === this.ctx.selfId && t.kind === 'wraith' && t.state !== 'dead' && t.state !== 'rising') src.push({ x: t.x, z: t.z });
    if (!src.length) return;
    const dmg = this.sp * k;
    const struck = new Set<number>();
    let shown = 0;
    for (const s of src.slice(0, LEGEND.novaMax)) {
      const ids: number[] = [];
      for (const e of this.ctx.enemies().values()) {
        if (e.state === 'dead' || e.state === 'burrow' || Math.hypot(e.x - s.x, e.z - s.z) > LEGEND.novaR + e.radius) continue;
        ids.push(e.id);
        if (!struck.has(e.id) && shown < 12) {
          struck.add(e.id);
          shown++;
          this.ctx.number(e.x, e.z, dmg, 'hit');
        }
      }
      if (ids.length) this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids, dmg });
      const b = this.ctx.boss();
      if (b.active && Math.hypot(b.x - s.x, b.z - s.z) <= LEGEND.novaR + BOSS_RADIUS) this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: [], dmg, boss: true });
      effects.decal({ tex: fx.ring(), color: SOUL.jade, x: s.x, z: s.z, r: LEGEND.novaR, duration: 0.45, opacity: 0.8, growFrom: 0.15 });
      effects.emit({ x: s.x, y: 0.9, z: s.z, count: 8, color: SOUL.pale, spread: 0.4, speed: 3.2, up: 0.6, life: 0.4, size: 0.16 });
    }
    audio.play('soulRelease', p.x, p.z, 0.8);
  }

  /** Colossus Mantle 5: the Litany barrier broke under damage; it bursts into bone shards around the caster. */
  litanyShatter(barrierSize: number) {
    const { player: p, effects } = this.ctx;
    const dmg = shatterDamage(barrierSize, this.ctx.discipline.mods.litanyShatter);
    if (dmg <= 0 || !p.alive) return;
    const ids: number[] = [];
    for (const e of this.ctx.enemies().values()) {
      if (e.state === 'dead' || e.state === 'burrow' || Math.hypot(e.x - p.x, e.z - p.z) > LEGEND.shatterR + e.radius) continue;
      ids.push(e.id);
      if (ids.length <= 12) this.ctx.number(e.x, e.z, dmg, 'hit');
    }
    if (ids.length) this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids, dmg });
    const b = this.ctx.boss();
    if (b.active && Math.hypot(b.x - p.x, b.z - p.z) <= LEGEND.shatterR + BOSS_RADIUS) this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: [], dmg, boss: true });
    effects.decal({ tex: fx.ring(), color: S.bone, x: p.x, z: p.z, r: LEGEND.shatterR, duration: 0.5, opacity: 1, growFrom: 0.1 });
    nf.boneSplinters(effects, p.x, 1.0, p.z, { n: 12, color: S.bone, speed: 6 });
    effects.emit({ x: p.x, y: 0.8, z: p.z, count: 14, color: S.bone, spread: 0.5, speed: 5, up: 1.2, life: 0.5, size: 0.16, gravity: 6 });
    audio.play('boneHit', p.x, p.z, 1.1);
    this.ctx.shake(0.07);
  }

  /**
   * Colossus Mantle 4: Bone Ward turned `boneWard` of a blow; `wardReflect` of that is dealt back at whatever struck it. (x, z) is where
   * the sim says the blow came from: the attacker's position for melee and ranged enemies, so the nearest body within a body-width of it
   * is the attacker. A blow with no single owner (a zone, a boss pit) reflects nothing.
   */
  reflectWard(raw: number, boneWard: number, x: number, z: number) {
    const dmg = wardReflectDamage(raw, boneWard, this.ctx.discipline.mods.wardReflect);
    if (dmg < 1) return;
    let best: Enemy | null = null;
    let bestD = 0.6;
    for (const e of this.ctx.enemies().values()) {
      if (e.state === 'dead' || e.state === 'burrow') continue;
      const d = Math.hypot(e.x - x, e.z - z);
      if (d <= bestD + e.radius * 0.5 && (!best || d < bestD)) (best = e), (bestD = d);
    }
    const b = this.ctx.boss();
    if (best) {
      this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: [best.id], dmg });
      this.ctx.number(best.x, best.z, dmg, 'hit');
      this.ctx.effects.emit({ x: best.x, y: 1, z: best.z, count: 5, color: S.bone, spread: 0.2, speed: 2.4, up: 0.8, life: 0.3, size: 0.12 });
    } else if (b.active && Math.hypot(b.x - x, b.z - z) <= BOSS_RADIUS + 0.6) {
      this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: [], dmg, boss: true });
      this.ctx.number(b.x, b.z, dmg, 'hit');
    }
  }

  /** Per frame: the Veil Step glide, then the caster's mantle shreds enemies beside them (client-resolved, like Marrow Spear). */
  update(now: number) {
    this.newBlood.update(now);
    this.tickTimed(now);
    this.tickWisps(now);
    if (this.dashing) {
      const d = this.dashing;
      const k = Math.min(1, (now - d.start) / d.dur);
      const e = 1 - (1 - k) * (1 - k);
      if (this.ctx.player.alive) this.ctx.player.teleport(d.fx + (d.tx - d.fx) * e, d.fz + (d.tz - d.fz) * e);
      if (k >= 1) {
        this.dashing = null;
        d.onArrive?.();
      }
    }
    // Corpse Vigil: regenerate while the vigil holds. Uses the same frame clock
    // as the dash above, so it ticks whether or not the Knight is moving.
    if (now < this.vigilUntil) {
      const { player: kp } = this.ctx;
      const dt = Math.min(0.25, Math.max(0, (now - this.lastVigilAt) / 1000));
      this.lastVigilAt = now;
      if (kp.alive && dt > 0) kp.heal(kp.stats.maxHp * CORPSE_VIGIL.regenFracPerS * dt);
    } else {
      this.lastVigilAt = now;
    }
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
      if (gone(e) || Math.hypot(e.x - p.x, e.z - p.z) > reach + e.radius) continue;
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

  // --- Spell variety (docs/agent-briefs/spell-variety-first-session.md §4) ---

  /** Bone Fan: three slivers, each homing on a distinct enemy in a narrow cone (the Prelate takes one). */
  private fan(t: CastTarget): CastResult {
    const { player: p, effects, avatar } = this.ctx;
    const def = ABILITIES.bone_fan;
    if (t.enemyId === undefined && !t.boss) return 'no_target';
    if (this.shortfall('bone_fan', t) > 0) return 'range';
    p.face(t.x, t.z);
    avatar.cast('cast', 3.2, p.facing, CAST_FLOW.bone_fan.gestureSeconds, 'bone_fan');
    const aim = Math.atan2(t.x - p.x, t.z - p.z);
    const cone = (BONE_FAN.coneHalfDeg * Math.PI) / 180;
    const angleOff = (x: number, z: number) => {
      let d = Math.atan2(x - p.x, z - p.z) - aim;
      while (d > Math.PI) d -= Math.PI * 2;
      while (d < -Math.PI) d += Math.PI * 2;
      return d;
    };
    // The clicked target first, then the others in the cone (distinct), nearest the aim line first.
    type Pick = { boss?: true; id?: number; off: number };
    const picks: Pick[] = [t.boss ? { boss: true, off: 0 } : { id: t.enemyId!, off: 0 }];
    const others: (Pick & { d: number })[] = [];
    for (const e of this.ctx.enemies().values()) {
      if (e.state === 'dead' || (e.state === 'rising' || e.state === 'burrow') || e.id === t.enemyId) continue;
      const d = Math.hypot(e.x - p.x, e.z - p.z);
      if (d > def.range + 0.4) continue;
      const off = angleOff(e.x, e.z);
      if (Math.abs(off) <= cone) others.push({ id: e.id, off, d });
    }
    others.sort((a, b) => Math.abs(a.off) - Math.abs(b.off) || a.d - b.d);
    picks.push(...others.slice(0, BONE_FAN.slivers - 1));
    const from = avatar.tip();
    effects.flash({ x: from.x, y: from.y, z: from.z, color: N.trail, size: 0.8, duration: 0.14 });
    audio.play('needleCast', p.x, p.z);
    const dmg = this.sp * def.power;
    let refunded = 0;
    const spread = (BONE_FAN.spreadDeg * Math.PI) / 180;
    const angles = [0, -spread, spread];
    for (let k = 0; k < BONE_FAN.slivers; k++) {
      const pick = picks[k];
      const a = aim + angles[k];
      const miss = { x: p.x + Math.sin(a) * def.range, y: 1, z: p.z + Math.cos(a) * def.range };
      effects.projectile({
        from,
        kind: 'needle',
        color: N.trail,
        speed: BONE_FAN.speed,
        to: () => {
          if (pick?.boss) {
            const b = this.ctx.boss();
            return b.active ? { x: b.x, y: 2.2, z: b.z } : miss;
          }
          const e = pick?.id !== undefined ? this.ctx.enemies().get(pick.id) : undefined;
          return e && e.state !== 'dead' ? { x: e.x, y: 1, z: e.z } : miss;
        },
        onArrive: (pos) => {
          if (!p.alive || !pick) return effects.emit({ x: pos.x, y: pos.y, z: pos.z, count: 4, color: N.dust, spread: 0.1, speed: 1.5, up: 0.6, life: 0.3, size: 0.1, gravity: 6 });
          if (pick.boss) {
            if (!this.ctx.boss().active) return;
            this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: [], dmg, boss: true });
          } else {
            const e = this.ctx.enemies().get(pick.id!);
            if (!e || e.state === 'dead') return;
            this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: [pick.id!], dmg });
          }
          if (refunded < BONE_FAN.essenceCap) {
            const add = Math.min(BONE_FAN.essencePerHit, BONE_FAN.essenceCap - refunded);
            refunded += add;
            p.essence = Math.min(p.stats.maxEssence, p.essence + add);
          }
          audio.play('needleHit', pos.x, pos.z, 0.8);
          effects.flash({ x: pos.x, y: pos.y, z: pos.z, color: N.impact, size: 0.8, duration: 0.16 });
          effects.emit({ x: pos.x, y: pos.y, z: pos.z, count: 6, color: N.dust, spread: 0.1, speed: 3, up: 1.1, life: 0.35, size: 0.12, gravity: 7 });
          this.ctx.number(pos.x, pos.z, dmg, 'hit');
        },
      });
    }
    return 'ok';
  }

  /** Rot Lance: pierces the first two enemies in a narrow lane; the host adds one Withered stack each. */
  private lance(t: CastTarget): CastResult {
    const { player: p, effects, avatar, discipline } = this.ctx;
    const def = ABILITIES.rot_lance;
    if (t.enemyId === undefined && !t.boss) return 'no_target';
    if (this.shortfall('rot_lance', t) > 0) return 'range';
    let dx = t.x - p.x;
    let dz = t.z - p.z;
    const len = Math.hypot(dx, dz) || 1;
    dx /= len;
    dz /= len;
    p.face(p.x + dx, p.z + dz);
    avatar.cast('cast', 2.8, p.facing, CAST_FLOW.rot_lance.gestureSeconds, 'rot_lance');
    const origin = { x: p.x, z: p.z };
    const tip = avatar.tip();
    const end = { x: origin.x + dx * def.range, y: 1, z: origin.z + dz * def.range };
    const dmg = this.sp * def.power;
    const cap = effectiveWitheredCap(discipline.mods) ?? DETONATE.rotWitheredCap;
    effects.flash({ x: tip.x, y: tip.y, z: tip.z, color: LN.rot, size: 0.7, duration: 0.14 });
    audio.play('needleCast', p.x, p.z, 0.8);
    effects.beam(tip, () => end, LN.deep, 0.03, 0.18);
    const lanceShot = effects.projectile({
      from: tip, to: () => end, kind: 'orb', color: LN.rot, speed: ROT_LANCE.speed,
      onArrive: () => {
        if (!p.alive) return;
        const lane: { along: number; id?: number; boss?: boolean; x: number; z: number }[] = [];
        for (const e of this.ctx.enemies().values()) {
          if (gone(e)) continue;
          const rx = e.x - origin.x;
          const rz = e.z - origin.z;
          const along = rx * dx + rz * dz;
          if (along > 0 && along < def.range + e.radius && Math.abs(rx * dz - rz * dx) < ROT_LANCE.halfWidth + e.radius) lane.push({ along, id: e.id, x: e.x, z: e.z });
        }
        const b = this.ctx.boss();
        if (b.active) {
          const rx = b.x - origin.x;
          const rz = b.z - origin.z;
          const along = rx * dx + rz * dz;
          if (along > 0 && along < def.range + BOSS_RADIUS && Math.abs(rx * dz - rz * dx) < ROT_LANCE.halfWidth + BOSS_RADIUS) lane.push({ along, boss: true, x: b.x, z: b.z });
        }
        lane.sort((a, c) => a.along - c.along);
        const hits = lane.slice(0, ROT_LANCE.pierce);
        const ids = hits.filter((h) => h.id !== undefined).map((h) => h.id!);
        if (ids.length) this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids, dmg, withered: ROT_LANCE.withered, witheredCap: cap });
        if (hits.some((h) => h.boss)) this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: [], dmg, boss: true });
        if (hits.length) p.essence = Math.min(p.stats.maxEssence, p.essence + ROT_LANCE.essence);
        for (const h of hits) {
          this.ctx.number(h.x, h.z, dmg, 'hit');
          effects.emitSmoke({ x: h.x, y: 0.9, z: h.z, count: 2, color: LN.spore, spread: 0.3, speed: 0.5, up: 0.5, life: 0.6, size: 0.8, shrink: -0.3 });
          effects.emit({ x: h.x, y: 1, z: h.z, count: 8, color: LN.rot, spread: 0.2, speed: 2, up: 0.8, life: 0.45, size: 0.14, gravity: 3 });
        }
        if (hits.length) audio.play('needleHit', hits[0].x, hits[0].z, 0.7);
      },
    });
    void lanceShot; // primaries repeat too often for a Binbun core; the lance keeps its light orb + beam
    return 'ok';
  }

  /** Grave Offering: the host consumes the corpse; essence + health arrive with its answer (onOffering). */
  private offering(t: CastTarget): CastResult {
    const { player: p, avatar } = this.ctx;
    const def = ABILITIES.grave_offering;
    const c = this.pickCorpse(t, def.radius, def.range);
    if (!c || (p.area && c.area !== p.area)) return 'no_corpse';
    p.face(c.x, c.z);
    avatar.cast('cast', 2.4, p.facing, CAST_FLOW.grave_offering.gestureSeconds, 'grave_offering');
    this.ctx.send({ t: 'signature', by: this.ctx.selfId, sig: 'offering', x: c.x, z: c.z, dx: 0, dz: 0, sp: this.sp });
    return 'ok';
  }

  onOffering(ev: Extract<SimEvent, { t: 'offering' }>, mine: boolean, follow: () => { x: number; z: number } | null) {
    const { effects, player: p, discipline } = this.ctx;
    if (!ev.ok) return;
    if (mine) this.onCorpseConsumed();
    // A jade wisp flies corpse → caster (Exhume's beam runs the other way).
    effects.decal({ tex: fx.ring(), color: X.spirit, x: ev.x, z: ev.z, r: 1.1, duration: 0.5, opacity: 0.9, growFrom: 0.3 });
    effects.emit({ x: ev.x, y: 0.5, z: ev.z, count: 14, color: X.spirit, spread: 0.3, speed: 1, up: 2.2, life: 0.6, size: 0.18 });
    this.bb('grave_offering_ripple', ev.x, ev.z);
    effects.projectile({
      from: { x: ev.x, y: 0.8, z: ev.z },
      to: () => {
        const f = follow();
        return f ? { x: f.x, y: 1.2, z: f.z } : null;
      },
      kind: 'sprite', tex: fxImage('wisp'), size: 0.9, color: X.beam, speed: 14,
      onArrive: (pos) => {
        effects.flash({ x: pos.x, y: pos.y, z: pos.z, color: X.spirit, size: 1.2, duration: 0.2 });
        this.bb('grave_offering_orb', pos.x, pos.z);
        if (!mine || !p.alive) return;
        const essence = (GRAVE_OFFERING.essence + (ev.corpseKind === 'resonant' ? GRAVE_OFFERING.resonantBonus : 0)) * (ev.elite ? GRAVE_OFFERING.eliteMult : 1);
        p.essence = Math.min(p.stats.maxEssence, p.essence + essence);
        const heal = p.stats.maxHp * (GRAVE_OFFERING.healFrac + (discipline.mods.corpseHeal ?? 0));
        p.hp = Math.min(p.stats.maxHp, p.hp + heal);
        audio.play('shard', pos.x, pos.z);
      },
    });
    audio.play('exhume', ev.x, ev.z);
  }

  /** Ivory Cleave: a 120° crescent resolved instantly (client-resolved like Grave Frost), Fracturing what it cuts. */
  private cleave(t: CastTarget): CastResult {
    const { player: p, effects, avatar } = this.ctx;
    const def = ABILITIES.ivory_cleave;
    let dx = t.x - p.x;
    let dz = t.z - p.z;
    const l = Math.hypot(dx, dz) || 1;
    dx /= l;
    dz /= l;
    p.face(p.x + dx, p.z + dz);
    avatar.cast('cast', 3, p.facing, CAST_FLOW.ivory_cleave.gestureSeconds, 'ivory_cleave');
    const cosMax = Math.cos((IVORY_CLEAVE.halfAngleDeg * Math.PI) / 180);
    const dmg = this.sp * def.power;
    const inArc = (x: number, z: number, r: number) => {
      const rx = x - p.x;
      const rz = z - p.z;
      const d = Math.hypot(rx, rz);
      if (d > IVORY_CLEAVE.reach + r) return false;
      return d < r || (rx * dx + rz * dz) / d >= cosMax;
    };
    const ids: number[] = [];
    for (const e of this.ctx.enemies().values()) {
      if (gone(e) || !inArc(e.x, e.z, e.radius)) continue;
      ids.push(e.id);
      if (ids.length <= 10) {
        this.ctx.number(e.x, e.z, dmg, 'hit');
        effects.emit({ x: e.x, y: 0.9, z: e.z, count: 5, color: S.bone, spread: 0.2, speed: 2.4, up: 1.1, life: 0.35, size: 0.12, gravity: 8 });
        if (ids.length <= 2) this.bb('ivory_cleave_hit', e.x, e.z);
      }
      if (ids.length >= 64) break;
    }
    if (ids.length) this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids, dmg, fracture: IVORY_CLEAVE.fracture });
    const b = this.ctx.boss();
    if (b.active && inArc(b.x, b.z, BOSS_RADIUS)) {
      this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: [], dmg, fracture: IVORY_CLEAVE.fracture, boss: true });
      this.ctx.number(b.x, b.z, dmg, 'hit');
    }
    effects.decal({ tex: fxImage('crescent'), color: S.bone, x: p.x + dx * 1.5, z: p.z + dz * 1.5, r: 2.2, rot: Math.atan2(dx, dz), duration: 0.45, opacity: 1, growFrom: 0.6, fadeOut: 0.3 });
    effects.decal({ tex: fxImage('crescent'), color: S.crack, x: p.x + dx * 1.6, z: p.z + dz * 1.6, r: 2.4, rot: Math.atan2(dx, dz), duration: 0.35, opacity: 0.6, growFrom: 0.7 });
    effects.lightFlash(p.x + dx * 1.5, 1, p.z + dz * 1.5, S.crack, 14, 0.2);
    audio.play('spear', p.x, p.z, 1.3);
    if (ids.length) audio.play('boneHit', p.x + dx * 2, p.z + dz * 2);
    this.ctx.shake(0.05);
    return 'ok';
  }

  /** Veil Step: a short, lerped slip toward the cursor that stops at the last valid point. */
  private veil(t: CastTarget): CastResult {
    const { player: p, effects, avatar } = this.ctx;
    const def = ABILITIES.veil_step;
    let dx = t.x - p.x;
    let dz = t.z - p.z;
    const l = Math.hypot(dx, dz);
    if (l < 0.3) return 'no_target';
    const reach = Math.min(def.range, l);
    dx /= l;
    dz /= l;
    const goal = { x: p.x + dx * reach, z: p.z + dz * reach };
    const to = this.ctx.dash ? this.ctx.dash(goal.x, goal.z) : goal;
    if (Math.hypot(to.x - p.x, to.z - p.z) < VEIL_STEP.stepM) return 'no_target';
    p.face(to.x, to.z);
    avatar.cast('cast', 3.4, p.facing, CAST_FLOW.veil_step.gestureSeconds);
    p.stop();
    const from = { x: p.x, z: p.z };
    this.dashing = { fx: from.x, fz: from.z, tx: to.x, tz: to.z, start: this.ctx.now(), dur: VEIL_STEP.durationS * 1000 };
    const dist = Math.hypot(to.x - from.x, to.z - from.z);
    effects.decal({ tex: fxImage('veilStreak'), color: VL.jade, x: (from.x + to.x) / 2, z: (from.z + to.z) / 2, r: dist / 2 + 0.4, sx: 0.35, rot: Math.atan2(to.x - from.x, to.z - from.z), duration: 0.6, opacity: 0.85, fadeOut: 0.45 });
    effects.emitSmoke({ x: from.x, y: 0.9, z: from.z, count: 4, color: VL.deep, spread: 0.4, speed: 0.5, up: 0.5, life: 0.6, size: 1, shrink: -0.3 });
    effects.emit({ x: from.x, y: 1, z: from.z, count: 12, color: VL.pale, spread: 0.3, speed: 1.6, up: 0.8, life: 0.4, size: 0.14 });
    this.bb('veil_step_trail', from.x, from.z, { duration: 0.6, rot: Math.atan2(to.x - from.x, to.z - from.z) });
    effects.decal({ tex: fx.ring(), color: VL.jade, x: to.x, z: to.z, r: 1, duration: 0.45, opacity: 0.9, growFrom: 0.2 });
    effects.lightFlash(to.x, 1.2, to.z, VL.jade, 14, 0.25);
    audio.play('bloodStep', from.x, from.z, 1.3);
    return 'ok';
  }

  /** Rally the Dead: the host buffs and retargets the legion; everyone sees the tethers (onRally). */
  private rally(t: CastTarget): CastResult {
    const { player: p, avatar, discipline, effects } = this.ctx;
    if (!this.ctx.thrallCount()) return 'no_thralls';
    avatar.cast('cast', 2, p.facing, CAST_FLOW.rally_dead.gestureSeconds, 'rally_dead');
    const dur = RALLY.durationS + (discipline.id === 'gravecaller' ? RALLY.gravecallerBonusS : 0);
    this.ctx.send({ t: 'signature', by: this.ctx.selfId, sig: 'rally', x: t.x, z: t.z, dx: 0, dz: 0, sp: this.sp, dur });
    effects.decal({ tex: fxImage('rallySigil'), color: RD.jade, x: p.x, z: p.z, r: 2.4, duration: 0.8, opacity: 0.9, growFrom: 0.4, spin: 1 });
    return 'ok';
  }

  onRally(ev: Extract<SimEvent, { t: 'rally' }>, follow: () => { x: number; z: number } | null) {
    const { effects } = this.ctx;
    const thralls = this.ctx.thralls?.();
    const dur = RALLY.durationS + RALLY.gravecallerBonusS;
    for (const id of ev.ids) {
      const at = () => {
        const th = thralls?.get(id);
        return th && th.state !== 'dead' && (th.rallyT ?? 1) > 0 ? { x: th.x, z: th.z } : null;
      };
      const f = follow() ?? { x: ev.x, z: ev.z };
      effects.beam(
        { x: f.x, y: 1.2, z: f.z },
        () => {
          const a = at();
          return a ? { x: a.x, y: 1, z: a.z } : null;
        },
        RD.jade,
        0.04,
        0.45,
      );
      effects.decal({ tex: fxImage('rallySigil'), color: RD.jade, x: 0, z: 0, r: 0.7, duration: dur, opacity: 0.7, spin: 1.4, fadeOut: 0.4, follow: at });
      const a0 = at();
      if (a0) this.bb('rally_thrall_rim', a0.x, a0.z, { follow: at, duration: dur });
    }
    effects.lightFlash(ev.x, 1.2, ev.z, RD.jade, 18, 0.3);
    this.bb('rally_area', ev.x, ev.z);
    audio.play('thrallRise', ev.x, ev.z);
  }

  /** Carrion Seed: plant on the corpse nearest the cursor; the host arms and bursts it. */
  private seed(t: CastTarget): CastResult {
    const { player: p, avatar, discipline } = this.ctx;
    const def = ABILITIES.carrion_seed;
    const c = this.pickCorpse(t, 2.5, def.range);
    if (!c || (p.area && c.area !== p.area)) return 'no_corpse';
    p.face(c.x, c.z);
    avatar.cast('cast', 2.4, p.facing, CAST_FLOW.carrion_seed.gestureSeconds, 'carrion_seed');
    const cap = discipline.mods.miasmaBurstsCorpses ? Math.max(CARRION_SEED.witheredCap, effectiveWitheredCap(discipline.mods)) : CARRION_SEED.witheredCap;
    this.ctx.send({ t: 'signature', by: this.ctx.selfId, sig: 'seed', x: c.x, z: c.z, dx: 0, dz: 0, sp: this.sp, cap });
    audio.play('miasma', c.x, c.z, 1.2);
    return 'ok';
  }

  onSeeded(ev: Extract<SimEvent, { t: 'seeded' }>) {
    const { effects } = this.ctx;
    this.seeds.get(ev.corpseId)?.kill();
    this.seedCores.get(ev.corpseId)?.kill();
    const core = this.bb('carrion_seed_armed', ev.x, ev.z, { duration: CARRION_SEED.lifeS + 1 });
    if (core) this.seedCores.set(ev.corpseId, core);
    effects.emit({ x: ev.x, y: 0.4, z: ev.z, count: 10, color: BL.petal, spread: 0.3, speed: 0.8, up: 1.2, life: 0.5, size: 0.14 });
    this.seeds.set(ev.corpseId, effects.decal({ tex: fxImage('seedBud'), color: BL.petal, x: ev.x, z: ev.z, r: 0.75, duration: CARRION_SEED.lifeS + 1, opacity: 0.95, growFrom: 0.2, pulse: 3, fadeIn: ev.armMs / 1000 }));
  }

  /** A seed withered, burst or its corpse was used by another rite. */
  onSeedGone(corpseId: number) {
    this.seeds.get(corpseId)?.kill();
    this.seeds.delete(corpseId);
    this.seedCores.get(corpseId)?.kill();
    this.seedCores.delete(corpseId);
  }

  onSeedBurst(ev: Extract<SimEvent, { t: 'seedBurst' }>) {
    const { effects } = this.ctx;
    effects.decal({ tex: fx.ring(), color: BL.petal, x: ev.x, z: ev.z, r: ev.r, duration: 0.5, opacity: 1, growFrom: 0.2 });
    effects.decal({ tex: fx.disc(), color: BL.rot, x: ev.x, z: ev.z, r: ev.r * 0.9, duration: 1.5, opacity: 0.55, fadeOut: 0.8 });
    effects.emit({ x: ev.x, y: 0.5, z: ev.z, count: 30, color: BL.petal, spread: 0.4, speed: ev.r * 2.4, up: 1.6, life: 0.6, size: 0.22, drag: 1.4 });
    effects.emitSmoke({ x: ev.x, y: 0.6, z: ev.z, count: 6, color: BL.spore, spread: ev.r * 0.4, speed: 1, up: 0.6, life: 1, size: 1.4, shrink: -0.4 });
    effects.lightFlash(ev.x, 1, ev.z, BL.petal, 22, 0.3);
    this.bb('carrion_seed_burst', ev.x, ev.z, { scale: ev.r / 3 });
    this.bb('toxic_puddle', ev.x, ev.z, { scale: ev.r / 3, duration: 1.5 });
    audio.play('burst', ev.x, ev.z);
    this.ctx.shake(0.06);
  }

  /** Discipline signature rites: aim + spell power to the host, a cast flourish here. */
  // ── Hollow Knight ──────────────────────────────────────────────────────────
  // Rage is built by Hollow Cut hits (here), by damage taken and by perfect
  // blocks (Player.takeDamage). Corpse rites and the stun go through the host.

  /** Hollow Cut: a short sword arc, client-resolved like Ivory Cleave, paying Rage per body cut. */
  private hollowCut(t: CastTarget): CastResult {
    const { player: p, effects, avatar } = this.ctx;
    const def = ABILITIES.hollow_cut;
    let dx = t.x - p.x;
    let dz = t.z - p.z;
    const l = Math.hypot(dx, dz) || 1;
    dx /= l;
    dz /= l;
    p.face(p.x + dx, p.z + dz);
    avatar.cast('attack', 3, p.facing, CAST_FLOW.hollow_cut.gestureSeconds);
    const cosMax = Math.cos((HOLLOW_CUT.halfAngleDeg * Math.PI) / 180);
    const dmg = this.sp * def.power;
    const inArc = (x: number, z: number, r: number) => {
      const rx = x - p.x;
      const rz = z - p.z;
      const d = Math.hypot(rx, rz);
      if (d > HOLLOW_CUT.reach + r) return false;
      return d < r || (rx * dx + rz * dz) / d >= cosMax;
    };
    const ids: number[] = [];
    for (const e of this.ctx.enemies().values()) {
      if (gone(e) || !inArc(e.x, e.z, e.radius)) continue;
      ids.push(e.id);
      if (ids.length <= 10) {
        this.ctx.number(e.x, e.z, dmg, 'hit');
        effects.emit({ x: e.x, y: 1, z: e.z, count: 4, color: KN.pale, spread: 0.2, speed: 2.2, up: 1, life: 0.3, size: 0.1, gravity: 8 });
      }
      if (ids.length >= 64) break;
    }
    if (ids.length) this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids, dmg });
    const b = this.ctx.boss();
    if (b.active && inArc(b.x, b.z, BOSS_RADIUS)) {
      this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: [], dmg, boss: true });
      this.ctx.number(b.x, b.z, dmg, 'hit');
      p.addResource(HOLLOW_CUT.rage);
    }
    // Rage per body cut — the reason to open on a clump.
    p.addResource(HOLLOW_CUT.rage * ids.length);
    effects.decal({ tex: fxImage('crescent'), color: KN.steel, x: p.x + dx * 1.2, z: p.z + dz * 1.2, r: HOLLOW_CUT.reach, rot: Math.atan2(dx, dz), duration: 0.32, opacity: 0.95, growFrom: 0.7, fadeOut: 0.22 });
    effects.lightFlash(p.x + dx * 1.2, 1, p.z + dz * 1.2, KN.pale, 10, 0.16);
    audio.play('spear', p.x, p.z, 1.45);
    if (ids.length) audio.play('boneHit', p.x + dx * 1.6, p.z + dz * 1.6);
    return 'ok';
  }

  /** Shield Bash: a short client dash; the host owns the strike and the stun (sig 'bash'). */
  private shieldBash(t: CastTarget): CastResult {
    const { player: p, effects, avatar } = this.ctx;
    let dx = t.x - p.x;
    let dz = t.z - p.z;
    const l = Math.hypot(dx, dz);
    if (l < 0.3) return 'no_target';
    dx /= l;
    dz /= l;
    const goal = { x: p.x + dx * SHIELD_BASH.dashM, z: p.z + dz * SHIELD_BASH.dashM };
    const to = this.ctx.dash ? this.ctx.dash(goal.x, goal.z) : goal;
    p.face(p.x + dx, p.z + dz);
    avatar.cast('attack', 3.2, p.facing, CAST_FLOW.shield_bash.gestureSeconds);
    p.stop();
    const from = { x: p.x, z: p.z };
    this.dashing = { fx: from.x, fz: from.z, tx: to.x, tz: to.z, start: this.ctx.now(), dur: SHIELD_BASH.durationS * 1000 };
    // The host finds the first body along the charge, damages and stuns it.
    this.ctx.send({ t: 'signature', by: this.ctx.selfId, sig: 'bash', x: from.x, z: from.z, dx, dz, sp: this.sp });
    const mid = { x: (from.x + to.x) / 2, z: (from.z + to.z) / 2 };
    effects.decal({ tex: fx.glow(), color: KN.steel, x: mid.x, z: mid.z, r: 1.3, duration: 0.3, opacity: 0.7, fadeOut: 0.2 });
    effects.emitSmoke({ x: from.x, y: 0.4, z: from.z, count: 4, color: KN.dust, spread: 0.4, speed: 0.6, up: 0.3, life: 0.5, size: 0.8 });
    audio.play('bloodStep', from.x, from.z, 1.2);
    this.ctx.shake(0.04);
    return 'ok';
  }

  /** Grave Slam: a nav-valid leap that resolves its slam on landing (client-resolved damage). */
  private graveSlam(t: CastTarget): CastResult {
    const { player: p, effects, avatar } = this.ctx;
    const def = ABILITIES.grave_slam;
    let dx = t.x - p.x;
    let dz = t.z - p.z;
    const l = Math.hypot(dx, dz);
    if (l < 0.5) return 'no_target';
    const reach = Math.min(GRAVE_SLAM.leapM, l);
    dx /= l;
    dz /= l;
    const goal = { x: p.x + dx * reach, z: p.z + dz * reach };
    const to = this.ctx.dash ? this.ctx.dash(goal.x, goal.z) : goal;
    if (Math.hypot(to.x - p.x, to.z - p.z) < 0.5) return 'no_target';
    p.face(to.x, to.z);
    avatar.cast('attack', 2.6, p.facing, CAST_FLOW.grave_slam.gestureSeconds);
    p.stop();
    const from = { x: p.x, z: p.z };
    const dmg = this.sp * def.power;
    this.dashing = {
      fx: from.x, fz: from.z, tx: to.x, tz: to.z,
      start: this.ctx.now(), dur: GRAVE_SLAM.durationS * 1000,
      onArrive: () => this.slamLanding(to, dmg),
    };
    effects.emitSmoke({ x: from.x, y: 0.4, z: from.z, count: 5, color: KN.dust, spread: 0.5, speed: 0.8, up: 0.6, life: 0.5, size: 0.9 });
    audio.play('bloodStep', from.x, from.z, 0.9);
    return 'ok';
  }

  /** The slam itself: everything within GRAVE_SLAM.slamR of where the Knight came down. */
  private slamLanding(at: { x: number; z: number }, dmg: number) {
    const { effects } = this.ctx;
    const r = GRAVE_SLAM.slamR;
    const ids: number[] = [];
    for (const e of this.ctx.enemies().values()) {
      if (gone(e)) continue;
      if (Math.hypot(e.x - at.x, e.z - at.z) > r + e.radius) continue;
      ids.push(e.id);
      if (ids.length <= 10) this.ctx.number(e.x, e.z, dmg, 'hit');
      if (ids.length >= 64) break;
    }
    if (ids.length) this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids, dmg });
    const b = this.ctx.boss();
    if (b.active && Math.hypot(b.x - at.x, b.z - at.z) <= r + BOSS_RADIUS) {
      this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids: [], dmg, boss: true });
      this.ctx.number(b.x, b.z, dmg, 'hit');
    }
    effects.decal({ tex: fx.ring(), color: KN.steel, x: at.x, z: at.z, r, duration: 0.5, opacity: 1, growFrom: 0.2, fadeOut: 0.3 });
    effects.decal({ tex: fx.glow(), color: KN.oath, x: at.x, z: at.z, r: r * 0.7, duration: 0.4, opacity: 0.55, fadeOut: 0.3 });
    effects.emit({ x: at.x, y: 0.4, z: at.z, count: 20, color: KN.dust, spread: 0.6, speed: 3.4, up: 1.6, life: 0.5, size: 0.18, gravity: 10 });
    effects.lightFlash(at.x, 1, at.z, KN.pale, 18, 0.22);
    this.bb('rend_impact', at.x, at.z);
    audio.play('boneHit', at.x, at.z, 0.8);
    this.ctx.shake(0.12);
  }

  /** Bulwark: raise the shield. Mitigation and the perfect-block window live on Player. */
  private bulwark(now: number): CastResult {
    const { player: p, effects, avatar } = this.ctx;
    avatar.cast('cast', 1.6, p.facing, CAST_FLOW.bulwark.gestureSeconds);
    p.bulwarkUntil = now + BULWARK.holdS * 1000;
    p.bulwarkPerfectUntil = now + BULWARK.perfectWindowS * 1000;
    const follow = () => ({ x: p.x, z: p.z });
    effects.decal({ tex: fx.ring(), color: KN.steel, x: p.x, z: p.z, r: 1.15, duration: BULWARK.holdS, opacity: 0.8, growFrom: 0.4, follow });
    effects.emit({ x: p.x, y: 1.1, z: p.z, count: 12, color: KN.pale, spread: 0.4, speed: 1.2, up: 0.8, life: 0.4, size: 0.16 });
    audio.play('shard', p.x, p.z, 0.8);
    return 'ok';
  }

  /** Corpse Vigil: the host spends the body (sig 'vigil'); the regen lands in onVigil. */
  private corpseVigil(t: CastTarget): CastResult {
    const { player: p, avatar } = this.ctx;
    const def = ABILITIES.corpse_vigil;
    const c = this.pickCorpse(t, def.radius, def.range);
    if (!c || (p.area && c.area !== p.area)) return 'no_corpse';
    p.face(c.x, c.z);
    avatar.cast('cast', 1.8, p.facing, CAST_FLOW.corpse_vigil.gestureSeconds);
    this.ctx.send({ t: 'signature', by: this.ctx.selfId, sig: 'vigil', x: c.x, z: c.z, dx: 0, dz: 0, sp: this.sp });
    return 'ok';
  }

  /** Grave Brand: the host spends the body and owns the trap (sig 'brand'). */
  private graveBrand(t: CastTarget): CastResult {
    const { player: p, avatar } = this.ctx;
    const def = ABILITIES.grave_brand;
    const c = this.pickCorpse(t, def.radius, def.range);
    if (!c || (p.area && c.area !== p.area)) return 'no_corpse';
    p.face(c.x, c.z);
    avatar.cast('cast', 2.2, p.facing, CAST_FLOW.grave_brand.gestureSeconds);
    this.ctx.send({ t: 'signature', by: this.ctx.selfId, sig: 'brand', x: c.x, z: c.z, dx: 0, dz: 0, sp: this.sp });
    return 'ok';
  }

  /** Oath Unbroken: the death floor, the damage bonus and the Rage refill are all local. */
  private oathUnbroken(now: number): CastResult {
    const { player: p, effects, avatar } = this.ctx;
    avatar.cast('cast', 2, p.facing, CAST_FLOW.oath_unbroken.gestureSeconds);
    p.unbreakableUntil = now + OATH_UNBROKEN.durationS * 1000;
    p.resource.value = p.resource.max;
    const follow = () => ({ x: p.x, z: p.z });
    effects.decal({ tex: fx.ring(), color: KN.oath, x: p.x, z: p.z, r: 1.6, duration: OATH_UNBROKEN.durationS, opacity: 0.75, growFrom: 0.3, follow, spin: 0.6 });
    effects.decal({ tex: fx.glow(), color: KN.oath, x: p.x, z: p.z, r: 2.4, duration: OATH_UNBROKEN.durationS, opacity: 0.3, growFrom: 0.5, follow });
    effects.emit({ x: p.x, y: 1.3, z: p.z, count: 24, color: KN.oath, spread: 0.5, speed: 2, up: 1.4, life: 0.7, size: 0.2 });
    effects.lightFlash(p.x, 1.4, p.z, KN.oath, 22, 0.35);
    audio.play('litany', p.x, p.z, 0.9);
    this.ctx.shake(0.08);
    return 'ok';
  }

  /**
   * The host spent a body on Corpse Vigil. Only the caster regenerates; everyone
   * sees the vigil light.
   */
  onVigil(ev: { x: number; z: number; ok?: boolean }, mine: boolean, follow: () => { x: number; z: number } | null) {
    const { effects, player: p } = this.ctx;
    if (ev.ok === false) return;
    effects.decal({ tex: fx.ring(), color: KN.pale, x: ev.x, z: ev.z, r: 1.2, duration: 0.6, opacity: 0.9, growFrom: 0.3 });
    effects.emit({ x: ev.x, y: 0.6, z: ev.z, count: 14, color: KN.pale, spread: 0.3, speed: 1, up: 2, life: 0.7, size: 0.16 });
    audio.play('exhume', ev.x, ev.z, 0.9);
    if (!mine || !p.alive) return;
    this.vigilUntil = this.ctx.now() + CORPSE_VIGIL.durationS * 1000;
    const f = follow();
    if (f) {
      effects.decal({
        tex: fx.glow(), color: KN.pale, x: f.x, z: f.z, r: 1.4,
        duration: CORPSE_VIGIL.durationS, opacity: 0.4, growFrom: 0.5,
        follow: () => follow() ?? { x: f.x, z: f.z },
      });
    }
  }

  /** The host armed or sprung a Grave Brand. */
  onBrand(ev: { x: number; z: number; sprung?: boolean }) {
    const { effects } = this.ctx;
    if (ev.sprung) {
      effects.decal({ tex: fx.ring(), color: KN.oath, x: ev.x, z: ev.z, r: GRAVE_BRAND.triggerR, duration: 0.45, opacity: 1, growFrom: 0.3 });
      effects.emit({ x: ev.x, y: 0.5, z: ev.z, count: 16, color: KN.oath, spread: 0.4, speed: 2.4, up: 1, life: 0.5, size: 0.16, gravity: 8 });
      audio.play('boneHit', ev.x, ev.z, 1.1);
      return;
    }
    effects.decal({ tex: fxImage('graveOutline'), color: KN.oath, x: ev.x, z: ev.z, r: GRAVE_BRAND.triggerR, duration: GRAVE_BRAND.lifeS, opacity: 0.5, growFrom: 0.6, fadeOut: 0.5 });
    effects.emit({ x: ev.x, y: 0.4, z: ev.z, count: 10, color: KN.oath, spread: 0.3, speed: 1, up: 0.6, life: 0.5, size: 0.14 });
    audio.play('shard', ev.x, ev.z, 0.7);
  }

  onNewBlood(ev: Extract<SimEvent, { t: 'newBlood' }>, mine: boolean) {
    this.newBlood.onEvent(ev, mine);
  }

  private signature(id: AbilityId, t: CastTarget): CastResult {
    const { player: p, avatar, effects } = this.ctx;
    const sig = SIGNATURE_KIND[id]!;
    if (riteLevel(p.stats.level) < SIGNATURE_LEVEL) return 'locked';
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
    avatar.cast('cast', 1.8, p.facing, CAST_FLOW[id].gestureSeconds, id);
    this.ctx.send({ t: 'signature', by: this.ctx.selfId, sig, x, z, dx: x - p.x, dz: z - p.z, sp: this.sp });
    const color = sig === 'wall' ? SPELL_FX.wall.amber : sig === 'rend' ? SPELL_FX.rend.jade : sig === 'dirge' ? SPELL_FX.dirge.frost : SPELL_FX.bloom.petal;
    effects.emit({ x: p.x, y: 1.4, z: p.z, count: 24, color, spread: 0.4, speed: 1.6, up: 1.2, life: 0.6, size: 0.24 });
    effects.lightFlash(p.x, 1.8, p.z, color, 24, 0.4);
    audio.play(sig === 'wall' ? 'sigWall' : sig === 'rend' ? 'sigRend' : sig === 'dirge' ? 'sigDirge' : 'sigBloom', p.x, p.z);
    return 'ok';
  }

  private litany(mult = 1): CastResult {
    const { player: p, avatar, discipline } = this.ctx;
    const def = ABILITIES.black_litany;
    const rune = this.rune('black_litany');
    avatar.cast('cast', 1.6, p.facing, CAST_FLOW.black_litany.gestureSeconds, 'black_litany');
    this.ctx.send({
      t: 'litany',
      by: this.ctx.selfId,
      x: p.x,
      z: p.z,
      // Requiem doubles the radius (the burst lands later); Hollow Choir hits softer and spares the thralls.
      r: def.radius * mult * (rune === 'rune_requiem' ? RUNE_TUNING.requiem.radiusMult : 1),
      spellPower: this.sp * (rune === 'rune_hollow_choir' ? RUNE_TUNING.hollowChoir.powerMult : 1),
      leaveCorpses: discipline.mods.sacrificeLeavesCorpse,
      ...(rune === 'rune_hollow_choir' ? { spare: true } : {}),
      ...(rune === 'rune_requiem' ? { delayMs: RUNE_TUNING.requiem.delayMs } : {}),
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
    avatar.cast('cast', 3, p.facing, CAST_FLOW.corpse_explosion.gestureSeconds, 'corpse_explosion');
    this.ctx.send({ t: 'detonate', by: this.ctx.selfId, corpseId: c.id, dmg: this.sp * def.power });
    const tip = avatar.tip();
    effects.flash({ x: tip.x, y: tip.y, z: tip.z, color: D.hot, size: 0.7, duration: 0.14 });
    effects.beam(tip, () => ({ x: c.x, y: 0.4, z: c.z }), D.ember, 0.05, 0.2);
    effects.decal({ tex: fx.glow(), color: D.ember, x: c.x, z: c.z, r: 1.1, duration: 0.25, opacity: 0.9, growFrom: 0.4 });
    return 'ok';
  }

  /** Everyone sees the blast when the host reports it (ember burst + bone shrapnel). */
  onDetonated(ev: Extract<SimEvent, { t: 'detonated' }>, mine: boolean) {
    if (mine && ev.ok) this.onCorpseConsumed();
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
    // The body bursts out of its grave: thrown earth, a spray of bone, and its last breath leaving as a skull.
    const who = mine ? 'player' : 'thrall';
    nf.graveDirt(effects, x, z, { r: r * 0.4, n: 9, up: 3.2, origin: who });
    nf.boneSplinters(effects, x, 0.8, z, { n: 8, color: D.bone, speed: r * 1.8, origin: who });
    nf.skullWisps(effects, x, z, D.hot, { n: 1, y: 0.8, size: 0.7, rise: 1.2, origin: who });
    effects.lightFlash(x, 1.2, z, D.ember, ev.elite ? 55 : 38, 0.45);
    this.bb('corpse_explosion', x, z, { scale: r / 3 });
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
  onLitany(ev: { x: number; z: number; r: number; corpses: number; resonant: number; thralls: number; spared?: number; tethers: [number, number][] }, mine: boolean) {
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
    effects.decal({ tex: fx.sigil(), color: L.core, x: ev.x, z: ev.z, r: ev.r, duration: 0.7, opacity: 0.5, growFrom: 0.1, spin: 0.35 });
    this.bb('litany_pulse', ev.x, ev.z, { scale: ev.r / 7 });
    effects.decal({ tex: fx.ring(), color: L.hot, x: ev.x, z: ev.z, r: ev.r * 1.15, duration: 0.55, opacity: 1, growFrom: 0.05, delay: 0.18 });
    effects.emit({ x: ev.x, y: 0.5, z: ev.z, count: 48, color: L.core, spread: 1, speed: 9, up: 1.8, life: 0.55, size: 0.23 });
    effects.emit({ x: ev.x, y: 0.8, z: ev.z, count: 16, color: L.hot, spread: 0.6, speed: 5, up: 3, life: 0.45, size: 0.2 });
    effects.flash({ x: ev.x, y: 1.5, z: ev.z, color: L.core, size: Math.min(2.0, ev.r * 0.24), duration: 0.3 });
    // A litany is sung over the dead: a ring of skulls stands on the circle, and each body gives up a soul-light.
    nf.skullRing(effects, ev.x, ev.z, Math.min(ev.r * 0.62, 5), L.hot, { n: Math.min(8, 4 + ev.corpses + ev.thralls), origin: mine ? 'player' : 'thrall' });
    for (const [x, z] of ev.tethers.slice(0, 5)) nf.soulMotes(effects, x, z, L.hot, { r: 0.3, n: 3, up: 1.8, origin: mine ? 'player' : 'thrall' });
    effects.lightFlash(ev.x, 2, ev.z, L.core, 32, 0.4);
    // Hollow Choir: the spared thralls glow where they stand (a jade halo and soul-lights rising from each).
    if (ev.spared) {
      for (const th of this.ctx.thralls?.().values() ?? []) {
        if (th.owner !== (mine ? this.ctx.selfId : th.owner) || Math.hypot(th.x - ev.x, th.z - ev.z) > ev.r) continue;
        effects.decal({ tex: fx.ring(), color: X.spirit, x: th.x, z: th.z, r: 1.2, duration: 0.9, opacity: 0.9, growFrom: 0.3 });
        nf.soulMotes(effects, th.x, th.z, X.beam, { r: 0.35, n: 4, up: 2.2, origin: 'thrall' });
      }
    }
    audio.play('litany', ev.x, ev.z, 1 + Math.min(0.6, (ev.corpses + ev.thralls) * 0.05));
    this.ctx.shake(0.08 + Math.min(0.08, (ev.corpses + ev.thralls) * 0.008));
    if (!mine) return;
    const consumed = ev.corpses + ev.resonant + ev.thralls;
    if (ev.corpses + ev.resonant > 0) this.onCorpseConsumed();
    if (discipline.mods.litanyBarrier) {
      const barrier = p.stats.maxHp * discipline.mods.litanyBarrier * consumed;
      p.barrier += barrier;
      if (barrier > 0) p.barrierPeak = Math.max(p.barrierPeak, p.barrier);
      if (barrier >= 1) this.ctx.note?.(`+${Math.round(barrier)} barrier`, 'ward');
    }
    if (discipline.mods.corpseHeal) {
      const healed = p.stats.maxHp * discipline.mods.corpseHeal * (ev.corpses + ev.resonant) * 0.5;
      p.heal(healed);
      if (healed >= 1) this.ctx.note?.(`+${Math.round(healed)}`, 'heal');
    }
  }
}
