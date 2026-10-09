import { ABILITIES, DETONATE } from '../../content/abilities';
import { disciplineFor } from '../../../server/rules/content/disciplines';
import { HEALING_FLASKS } from '../../../server/rules/content/items';
import { deriveStats } from '../characterStats';
import { Nav } from '../nav';
import { mulberry32 } from '../rng';
import { BOSS_RADIUS } from '../sim/BossBrain';
import { BOSSES, CONGREGATION, type BossId } from '../../../server/rules/content/bosses';
import { FEN_HUMMOCKS, bogMult } from '../../../server/rules/content/fen';
import type { Enemy, SimEvent } from '../sim/types';
import { WorldSim } from '../sim/WorldSim';
import { botCharacter } from './harness';
import { EQUIP_SLOTS, equippedBySlot } from '../../content/gear';
import { withSetBonuses } from '../setBonuses';
import { NO_LOADOUT, abilityCooldownMs, abilityRange, pierceTargets, reapTargets, resolveWeaponLoadout } from '../weaponLine';
import { NECRO_WEAPON_TUNING } from '../../../server/rules/content/necroWeapons';
import { colossusActive, effectiveWitheredCap } from '../legendary';
import { Player } from '../Player';
import { resolveKit, type KitName, type KitRequest } from './kits';
import type { Difficulty } from '../../../server/rules/content/difficulty';

/**
 * Headless Prelate fight: the same scripted necromancer as the farming
 * harness, summoning the Bell-Sworn Prelate with a legion already raised and
 * fighting until the Prelate dies, the bot dies (solo death resets the boss),
 * or time runs out. Unlike the farming bot it can dodge the Prelate's
 * telegraphs after a human-ish reaction delay, so both a careful and a
 * careless player can be measured.
 */
export interface BossRun {
  level: number;
  classIndex: number;
  damageTier: number;
  gearStats: number;
  /** Step out of boss telegraphs (after `reactionS`). */
  dodge: boolean;
  reactionS?: number;
  /** Major healing flasks carried (70% each, 1.5 s cooldown). */
  flasks?: number;
  maxMinutes?: number;
  seed?: number;
  difficulty?: Difficulty;
  ascension?: number;
  /** Gear kit worn (balance/kits.ts); replaces the share of the `gearStats` stand-in its slots cover, as in the farming harness. Default none. */
  kit?: KitName;
  /** Experiments: change the kit's weapon pair / tier (kits.ts KitRequest.override), e.g. `{ main: 'scythe' }`. Needs a kit other than none. */
  kitOverride?: KitRequest['override'];
  /** Which boss (default the Prelate). */
  boss?: BossId;
}

export interface BossResult {
  run: BossRun;
  outcome: 'win' | 'wipe' | 'timeout';
  seconds: number;
  /** Seconds at which phase 2 / 3 began (-1 = never). */
  phase2At: number;
  phase3At: number;
  bossHpLeftPct: number;
  bossMaxHp: number;
  dmgPctPerMin: number;
  /** Damage taken by source, as % of max HP over the whole fight. */
  bySource: Record<string, number>;
  minHpPct: number;
  flasksUsed: number;
  /** Litany barrier raised / soaked over the fight, as % of max HP (0 without a Reliquary set). */
  barrierMadePct: number;
  barrierAbsorbedPct: number;
  /** Share of the fight spent slowed by open water (the Fen's bog, the nave's flood) and seconds spent rooted by hands / grasps / burial. */
  wadingPct: number;
  rootedS: number;
  /** Player-side damage per second into the boss (all sources). */
  dps: number;
}

interface Danger {
  x: number;
  z: number;
  r: number;
  at: number;
  seenAt: number;
}

const DT = 0.05;

export function runBossFight(run: BossRun): BossResult {
  const rand = mulberry32(run.seed ?? 42);
  const nav = new Nav();
  nav.setUnlocked(['chapterhouse', 'graves', 'ossuary', 'nave', 'sanctum', 'cloister', 'pyre', 'warren', 'coliseum', 'fen']);
  const bossId: BossId = run.boss ?? 'prelate';
  const area = BOSSES[bossId].area;
  const BOSS_ARENA = BOSSES[bossId].arena;
  const sim = new WorldSim(nav, rand);
  sim.difficulty = run.difficulty ?? 'medium';
  sim.ascension = run.ascension ?? 0;
  const baseDisc = disciplineFor(run.classIndex);
  const worn = resolveKit({ kit: run.kit ?? 'none', discipline: baseDisc.id, area: BOSSES[bossId].area, override: run.kitOverride, seed: run.seed });
  const loadout = baseDisc.family === 'necromancer' ? resolveWeaponLoadout(equippedBySlot(worn), baseDisc.id) : NO_LOADOUT;
  const withGear = withSetBonuses(baseDisc, worn);
  const disc = loadout.thrallBonus ? { ...withGear, mods: { ...withGear.mods, thrallCap: withGear.mods.thrallCap + loadout.thrallBonus } } : withGear;
  const covered = new Set(Object.keys(equippedBySlot(worn))).size;
  const standIn = run.gearStats * (1 - covered / EQUIP_SLOTS.length);
  const stats = deriveStats(botCharacter(run.classIndex, run.level, standIn), worn, disc, run.damageTier);
  const sp = stats.spellPower;
  /** The real Player body, used for what it owns in a fight: incoming damage (Bone Ward, guard, Litany barrier). Position, health and essence stay the bot's. */
  const body = new Player(stats, nav, 'necromancer');
  const reaction = run.reactionS ?? 0.35;
  const p = { id: 'bot', x: BOSS_ARENA.x, z: BOSS_ARENA.z + 9, hp: stats.maxHp, essence: stats.maxEssence };
  const cds = new Map<string, number>();
  const ready = (id: string, t: number) => (cds.get(id) ?? 0) <= t;
  const use = (id: keyof typeof ABILITIES, t: number) => {
    const a = ABILITIES[id];
    if (!ready(id, t) || p.essence < a.essenceCost) return false;
    p.essence -= a.essenceCost;
    // A grimoire shortens every rite (the left click is exempt), exactly as the player's cooldowns do.
    cds.set(id, t + abilityCooldownMs(id, a.cooldownMs, loadout, false) / 1000);
    return true;
  };
  /** How close a scythe bot stands to the boss's centre (arc reach + body, with a margin so a step back still lands). */
  const meleeReach = abilityRange('bone_needle', ABILITIES.bone_needle.range, loadout, true) + BOSS_RADIUS - 0.4;
  const place = (alive = true) => sim.setPlayer({ id: p.id, x: p.x, z: p.z, alive, area: alive ? area : null, level: run.level });

  // Arrive with a full legion (raised during the Sanctum trash).
  place();
  for (let i = 0; i < disc.mods.thrallCap; i++) {
    const cx = p.x - 1.5 + i * 0.8;
    const cz = p.z + 1;
    sim.addCorpse(cx, cz, 'normal', 'robber', false, 0, 1, area);
    sim.apply({ t: 'exhume', by: p.id, x: cx, z: cz, r: 0.8, kind: disc.mods.thrallKind, cap: disc.mods.thrallCap, hp: stats.thrallHp, damage: stats.thrallDamage, attackSpeedMult: disc.mods.thrallAttackSpeedMult });
  }
  for (let i = 0; i < 25; i++) sim.step(DT);
  // Clear the trash that climbed out while the legion rose; the fight starts clean.
  for (const e of [...sim.enemies.values()]) sim.enemies.delete(e.id);
  sim.apply({ t: 'summonBoss', by: p.id, boss: bossId });
  const b = sim.boss.state;
  const bossMaxHp = b.maxHp;

  const dangers: Danger[] = [];
  const bySource: Record<string, number> = {};
  let minHp = 1;
  let barrierAbsorbed = 0;
  let barrierMade = 0;
  let wadingSteps = 0;
  let rootedSteps = 0;
  let flasks = run.flasks ?? 4;
  let flasksUsed = 0;
  let flaskCd = 0;
  let lastHurt = -99;
  let dmgTaken = 0;
  let phase2At = -1;
  let phase3At = -1;
  let outcome: BossResult['outcome'] = 'timeout';
  const maxSteps = Math.round(((run.maxMinutes ?? 6) * 60) / DT);
  let t = 0;
  let steps = 0;

  /** Rooted (Drowning Grasp, the Mire Mother's hands, Burial): the bot stands still and keeps casting (WorldScene.rootedUntil). */
  let rootedUntil = 0;
  /** Water slows the player the way WorldScene sets `moveMult`: the Fen's bog (hummocks are dry; the flood shrinks them) and the Congregation's rising nave water. */
  const wade = () => {
    const phase = b.active ? b.phase : 0;
    if (bossId === 'mire') return bogMult(p.x, p.z, phase);
    if (bossId === 'congregation' && phase >= 2) {
      const d = Math.hypot(p.x - BOSS_ARENA.x, p.z - BOSS_ARENA.z);
      if (d <= BOSS_ARENA.r && d > CONGREGATION.water.dais) return phase >= 3 ? CONGREGATION.water.slowP3 : CONGREGATION.water.slowP2;
    }
    return 1;
  };
  const move = (tx: number, tz: number, away = false) => {
    if (t < rootedUntil) return;
    const dx = tx - p.x;
    const dz = tz - p.z;
    const d = Math.hypot(dx, dz) || 1;
    const k = ((away ? -1 : 1) * stats.moveSpeed * wade() * DT) / d;
    [p.x, p.z] = nav.resolve(p.x + dx * k, p.z + dz * k, 0.45);
  };
  /**
   * The Mourning Fen, played carefully: stand on a dry hummock at casting range (or at the scythe's reach) from the Mire Mother, off the
   * hummock she is about to surface under, and hop to another when the ripple ring is drawn. The hummocks shrink as she floods the marsh.
   */
  let spot = -1;
  let spotAt = -9;
  const fenSpotCost = (i: number) => {
    const h = FEN_HUMMOCKS[i];
    const want = loadout.reap ? meleeReach - 0.7 : 7; // 3.5 m at the old 3 m arc; follows the scythe's boss reach
    const unsafe = dangers.some((d) => t < d.at && Math.hypot(h.x - d.x, h.z - d.z) < d.r + 0.5);
    return Math.abs(Math.hypot(h.x - b.x, h.z - b.z) - want) + 0.2 * Math.hypot(h.x - p.x, h.z - p.z) + (unsafe ? 50 : 0);
  };
  const fenSpot = () => {
    if (t - spotAt >= 0.5) {
      spotAt = t;
      let best = 0;
      for (let i = 1; i < FEN_HUMMOCKS.length; i++) if (fenSpotCost(i) < fenSpotCost(best)) best = i;
      if (spot < 0 || fenSpotCost(best) < fenSpotCost(spot) - 1.5) spot = best;
    }
    return FEN_HUMMOCKS[spot];
  };

  for (; steps < maxSteps; steps++) {
    t = steps * DT;
    // The barrier melts at 4% of max health a second (Player.update).
    if (body.barrier > 0) body.barrier = Math.max(0, body.barrier - stats.maxHp * 0.04 * DT);
    else body.barrierPeak = 0;
    const inCombat = t - lastHurt < 5;
    p.hp = Math.min(stats.maxHp, p.hp + stats.maxHp * (inCombat ? 0.004 : 0.045) * DT);
    p.essence = Math.min(stats.maxEssence, p.essence + stats.essenceRegen * DT);
    if (p.hp < stats.maxHp * 0.4 && flasks > 0 && t >= flaskCd) {
      p.hp = Math.min(stats.maxHp, p.hp + stats.maxHp * HEALING_FLASKS.flask_hp_major);
      flasks--;
      flasksUsed++;
      flaskCd = t + 1.5;
    }

    if (wade() < 1) wadingSteps++;
    if (t < rootedUntil) rootedSteps++;
    // --- Movement: dodge first, otherwise hold a casting distance from the Prelate ---
    const bd = Math.hypot(b.x - p.x, b.z - p.z);
    const threat = run.dodge
      ? dangers.find((d) => t - d.seenAt >= reaction && t < d.at && Math.hypot(p.x - d.x, p.z - d.z) < d.r + 0.9)
      : undefined;
    // Standing in a rot pool (the Plague Saint's rain, plague flasks): a dodging player walks out.
    const pool = run.dodge && !threat ? [...sim.zones.values()].find((z) => z.hostile && sim.time - z.bornAt >= reaction && Math.hypot(p.x - z.x, p.z - z.z) < z.r + 0.5) : undefined;
    if (pool) {
      if (Math.hypot(p.x - pool.x, p.z - pool.z) < 0.2) move(p.x + 1, p.z);
      else move(pool.x, pool.z, true);
    } else if (threat) {
      // Step straight out of the circle (sideways if standing on its centre).
      if (Math.hypot(p.x - threat.x, p.z - threat.z) < 0.2) move(p.x + 1, p.z);
      else move(threat.x, threat.z, true);
    } else if (bossId === 'mire' && run.dodge && b.active) {
      const h = fenSpot();
      if (Math.hypot(h.x - p.x, h.z - p.z) > 0.6) move(h.x, h.z);
    } else if (loadout.reap) {
      // A scythe is a 3 m arc: the reaper walks up to the boss and stays there (the rites reach from anywhere).
      if (bd > meleeReach) move(b.x, b.z);
    } else if (bd > 9) move(b.x, b.z);
    else if (bd < 5.5) move(b.x, b.z, true);

    // --- Spells ---
    const adds = [...sim.enemies.values()].filter((e) => e.state !== 'dead' && (e.state !== 'rising' && e.state !== 'burrow'));
    let nearAdd: Enemy | null = null;
    let nad = 8;
    for (const e of adds) {
      const d = Math.hypot(e.x - p.x, e.z - p.z);
      if (d < nad) {
        nad = d;
        nearAdd = e;
      }
    }
    const corpses = [...sim.corpses.values()];
    const myThralls = [...sim.thralls.values()].filter((th) => th.owner === p.id);
    const corpseNear = corpses.find((c) => Math.hypot(c.x - p.x, c.z - p.z) <= ABILITIES.exhume.range);
    const corpseByBoss = corpses.find((c) => Math.hypot(c.x - b.x, c.z - b.z) <= DETONATE.radius + BOSS_RADIUS);
    if (b.active) {
      if (corpseNear && myThralls.length < disc.mods.thrallCap && use('exhume', t)) {
        sim.apply({ t: 'exhume', by: p.id, x: corpseNear.x, z: corpseNear.z, r: 0.8, kind: disc.mods.thrallKind, cap: disc.mods.thrallCap, hp: stats.thrallHp, damage: stats.thrallDamage, attackSpeedMult: disc.mods.thrallAttackSpeedMult });
        // Sickle: Exhume gives back part of its essence (AbilitySystem.cast).
        if (loadout.exhumeRefund > 0) p.essence = Math.min(stats.maxEssence, p.essence + ABILITIES.exhume.essenceCost * loadout.exhumeRefund);
      } else if (bd <= 7 && myThralls.length + corpses.length >= 3 && use('black_litany', t)) {
        sim.apply({ t: 'litany', by: p.id, x: p.x, z: p.z, r: 7, spellPower: sp, leaveCorpses: disc.mods.sacrificeLeavesCorpse });
      } else if (corpseByBoss && use('corpse_explosion', t)) {
        sim.apply({ t: 'detonate', by: p.id, corpseId: corpseByBoss.id, dmg: sp * ABILITIES.corpse_explosion.power });
      } else if (bd <= ABILITIES.miasma.range && use('miasma', t)) {
        sim.apply({ t: 'miasma', by: p.id, x: b.x, z: b.z, r: ABILITIES.miasma.radius * disc.mods.miasmaRadiusMult, dps: sp * ABILITIES.miasma.power, durationMs: 6000, witheredCap: disc.mods.witheredMaxStacks, bloom: disc.mods.miasmaBurstsCorpses });
      } else if (bd <= ABILITIES.marrow_spear.range && use('marrow_spear', t)) {
        sim.apply({ t: 'hit', by: p.id, ids: [], dmg: sp * ABILITIES.marrow_spear.power, fracture: 1, boss: true });
      }
      // Needle: adds that walk up first, otherwise the Prelate. The weapon line changes what the left click is (AbilitySystem.needle / .reap):
      // a staff reaches farther and pierces the add behind its target, a scythe reaps a close arc (up to three bodies, the boss among them),
      // a wand fires faster and softer, a sickle withers adds. A needle that hits the boss itself carries no wither and no pierce (as in play).
      if (ready('bone_needle', t)) {
        const needle = ABILITIES.bone_needle;
        const reach = abilityRange('bone_needle', needle.range, loadout);
        const crit = rand() < 0.08 ? 1.8 : 1;
        const cd = abilityCooldownMs('bone_needle', needle.cooldownMs, loadout, true) / 1000;
        const addInReach = nearAdd && nad <= reach + 0.4 ? nearAdd : null;
        const bossInReach = bd <= abilityRange('bone_needle', needle.range, loadout, true) + BOSS_RADIUS;
        if (loadout.reap) {
          if (addInReach || bossInReach) {
            cds.set('bone_needle', t + cd);
            const aim = addInReach ?? b;
            const T = NECRO_WEAPON_TUNING.scythe;
            const dmg = sp * needle.power * T.damageMult * crit;
            const struck = reapTargets(p, aim, adds);
            const hitBoss = bossInReach && reapTargets(p, aim, [{ x: b.x, z: b.z, radius: BOSS_RADIUS }], T.bossReach).length > 0;
            const ids = struck.slice(0, Math.max(0, T.maxHits - (hitBoss ? 1 : 0))).map((e) => e.id);
            if (ids.length) sim.apply({ t: 'hit', by: p.id, ids, dmg });
            if (hitBoss) sim.apply({ t: 'hit', by: p.id, ids: [], dmg, boss: true });
            p.essence = Math.min(stats.maxEssence, p.essence + T.essencePerHit * (ids.length + (hitBoss ? 1 : 0)));
          }
        } else if (addInReach) {
          cds.set('bone_needle', t + cd);
          const wither = loadout.needleWithered > 0 ? { withered: loadout.needleWithered, witheredCap: effectiveWitheredCap(disc.mods) } : {};
          const dmg = sp * needle.power * loadout.needleDamageMult * crit;
          sim.apply({ t: 'hit', by: p.id, ids: [addInReach.id], dmg, ...wither });
          if (loadout.needlePierce > 0) {
            const behind = pierceTargets(p, addInReach, adds, loadout.needlePierce);
            if (behind.length) sim.apply({ t: 'hit', by: p.id, ids: behind.map((e) => e.id), dmg: dmg * NECRO_WEAPON_TUNING.staff.pierceDamageMult, ...wither });
          }
          p.essence = Math.min(stats.maxEssence, p.essence + 6);
        } else if (bossInReach) {
          cds.set('bone_needle', t + cd);
          sim.apply({ t: 'hit', by: p.id, ids: [], dmg: sp * needle.power * loadout.needleDamageMult * crit, boss: true });
          p.essence = Math.min(stats.maxEssence, p.essence + 6);
        }
      }
    }

    place();
    const events: SimEvent[] = sim.step(DT);
    for (const ev of events) {
      if (ev.t === 'boss') {
        if (ev.ms) {
          for (const [x, z] of ev.targets ?? [[ev.x, ev.z]]) dangers.push({ x, z, r: ev.r ?? 2, at: t + ev.ms / 1000, seenAt: t });
        }
        if (ev.ms === 0 && ev.root && ev.players?.includes(p.id)) rootedUntil = Math.max(rootedUntil, t + ev.root);
        if (ev.kind === 'phase' && ev.phase === 2) phase2At = t;
        if (ev.kind === 'phase' && ev.phase === 3) phase3At = t;
        if (ev.kind === 'defeated' && ev.killer) outcome = 'win';
      } else if (ev.t === 'litanyResult' && ev.by === p.id) {
        // Reliquary barrier per body consumed, and the Mourner's corpse heal (AbilitySystem.onLitany).
        const consumed = ev.corpses + ev.resonant + ev.thralls;
        if (disc.mods.litanyBarrier) {
          body.barrier += stats.maxHp * disc.mods.litanyBarrier * consumed;
          if (consumed > 0) body.barrierPeak = Math.max(body.barrierPeak, body.barrier);
          barrierMade += stats.maxHp * disc.mods.litanyBarrier * consumed;
        }
        if (disc.mods.corpseHeal) p.hp = Math.min(stats.maxHp, p.hp + stats.maxHp * disc.mods.corpseHeal * (ev.corpses + ev.resonant) * 0.5);
      } else if (ev.t === 'hurt' && ev.player === p.id) {
        // The real Player body takes the blow: Bone Ward (capped), Colossus guard, then the Litany barrier before health (Player.takeDamage).
        const mine = [...sim.thralls.values()].filter((th) => th.owner === p.id).length;
        body.hp = p.hp;
        const barrierBefore = body.barrier;
        const dmg = body.takeDamage(ev.dmg, disc.mods.wardPerThrall * mine, t * 1000, { x: ev.x, z: ev.z }, ev.from, colossusActive(disc.mods, mine) ? disc.mods.colossusGuard : 0);
        barrierAbsorbed += barrierBefore - body.barrier;
        p.hp = body.hp;
        dmgTaken += dmg;
        lastHurt = t;
        const src = ev.from === 'boss' ? 'prelate' : 'adds';
        bySource[src] = (bySource[src] ?? 0) + dmg;
        minHp = Math.min(minHp, Math.max(0, p.hp) / stats.maxHp);
      }
    }
    for (let i = dangers.length - 1; i >= 0; i--) if (dangers[i].at <= t) dangers.splice(i, 1);
    if (outcome === 'win') break;
    if (p.hp <= 0) {
      outcome = 'wipe';
      place(false);
      sim.step(DT);
      break;
    }
  }

  const secs = Math.max(DT, t);
  const pct: Record<string, number> = {};
  for (const [k, v] of Object.entries(bySource)) pct[k] = (v / stats.maxHp) * 100;
  const bossHpLeft = outcome === 'win' ? 0 : Math.max(0, b.hp);
  return {
    run,
    outcome,
    seconds: secs,
    phase2At,
    phase3At,
    bossHpLeftPct: (bossHpLeft / bossMaxHp) * 100,
    bossMaxHp,
    dmgPctPerMin: (dmgTaken / stats.maxHp / (secs / 60)) * 100,
    bySource: pct,
    minHpPct: minHp * 100,
    flasksUsed,
    barrierMadePct: (barrierMade / stats.maxHp) * 100,
    barrierAbsorbedPct: (barrierAbsorbed / stats.maxHp) * 100,
    wadingPct: (wadingSteps / Math.max(1, steps)) * 100,
    rootedS: rootedSteps * DT,
    dps: (bossMaxHp - bossHpLeft) / secs,
  };
}
