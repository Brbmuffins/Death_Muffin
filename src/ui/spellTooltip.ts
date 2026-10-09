import { canUseAutoCombat } from '../app/settings';
import {
  ABILITIES,
  BONE_FAN,
  BONE_MANTLE,
  CARRION_SEED,
  GRAVE_OFFERING,
  IVORY_CLEAVE,
  RALLY,
  ROT_LANCE,
  DETONATE,
  FRACTURE,
  GRAVE_FROST,
  SOUL_SIPHON,
  BONE_PRISON,
  GRAVE_HANDS,
  BONE_STORM,
  GRAVE_STEP,
  MIASMA_SLOW,
  NEEDLE_ESSENCE,
  SIGNATURE,
  KNIGHT_RAGE,
  HOLLOW_CUT,
  SHIELD_BASH,
  GRAVE_SLAM,
  BULWARK,
  CORPSE_VIGIL,
  GRAVE_BRAND,
  OATH_UNBROKEN,
  SOUL_HARVEST,
  WAILING_SKULL,
  unlockLevel,
  type AbilityId,
} from '../content/abilities';
import { CODEX_RITES } from '../content/codex';
import { DISCIPLINES, type Discipline } from '../../server/rules/content/disciplines';
import { kitFor, type Kit } from '../content/kits';
import { CHILL, HEMORRHAGE } from '../content/statuses';
import { resourceRulesFor } from '../gameplay/resources';

export interface SpellTooltipState {
  empowered?: boolean;
  locked?: boolean;
  affordable?: boolean;
  /** Remaining cooldown in milliseconds; distinct from the base cooldown. */
  left?: number;
  /** The key this Grimoire rite sits on (1–4 or RMB), when it is on the bar. */
  key?: string;
  /** The active family's kit; defaults to the necromancer's when a caller has none. */
  kit?: Kit;
}

export interface SpellTooltipData {
  name: string;
  description: string;
  control: string;
  targeting: string;
  metrics: { label: string; value: string }[];
  details: string[];
  tip: string;
  status: string;
  empowered: boolean;
  locked: boolean;
}

const number = (n: number) => Number(n.toFixed(2)).toString();
const percent = (n: number) => `${number(n * 100)}%`;
const TARGETING = {
  enemy: 'Aim at an enemy.',
  direction: 'Aim with the mouse; the spell travels along that direction.',
  corpse: 'Aim at a corpse on the ground. Requires an available body.',
  ground: 'Aim at a point on the ground.',
  self: 'Cast around your character; no target needed.',
};

/** Player-readable data only. Costs and areas reflect class tuning and Harvest. */
export function spellTooltip(id: AbilityId, discipline?: Discipline, state: SpellTooltipState = {}): SpellTooltipData {
  const a = ABILITIES[id];
  const m = discipline?.mods;
  const empowered = !!state.empowered && SOUL_HARVEST.spells.includes(id);
  const areaMult = empowered ? SOUL_HARVEST.areaMult : 1;
  // Signature and Grimoire rites wait for their level; the starting kit never locks.
  const locked = !!state.locked && unlockLevel(id) > 1;
  const resourceName = discipline && discipline.family !== 'necromancer' ? resourceRulesFor(discipline.family).label : 'Essence';
  const metrics = [
    { label: resourceName, value: empowered ? `Free (normally ${a.essenceCost})` : a.essenceCost ? number(a.essenceCost) : 'Free' },
    { label: 'Cooldown', value: `${number(a.cooldownMs / 1000)}s` },
    { label: 'Range', value: a.range ? `${number(a.range * (id === 'marrow_spear' ? areaMult : 1))}m` : 'Around you' },
  ];
  let radius = a.radius;
  if (id === 'miasma') radius *= (m?.miasmaRadiusMult ?? 1) * areaMult;
  if (id === 'black_litany') radius *= areaMult;
  if (['miasma', 'black_litany', 'corpse_explosion', 'dirge', 'plague_bloom', 'command_rend', 'grave_step', 'bone_mantle', 'carrion_seed', 'rally_dead', 'bone_prison', 'grave_hands', 'bone_storm'].includes(id)) {
    metrics.push({ label: 'Radius', value: `${number(radius)}m` });
  }
  const details: string[] = [];
  switch (id) {
    case 'bone_needle':
      details.push(`Each hit restores ${NEEDLE_ESSENCE} Grave Essence. Use it between your other spells.`);
      break;
    case 'marrow_spear':
      details.push(`Pierces enemies in a line. Fracture makes targets take ${percent(FRACTURE.perStack)} more damage per stack, up to ${FRACTURE.maxStacks} stacks for ${number(FRACTURE.durationMs / 1000)}s.`,
        `Non-boss enemies also suffer Hemorrhage: bleeding for ${HEMORRHAGE.durationS}s.`);
      break;
    case 'exhume':
      details.push(`Consumes one corpse to raise a thrall${m ? `; your ${discipline!.name} cap is ${m.thrallCap}` : ''}. At the cap, your oldest thrall crumbles.`,
        'The body determines special thrall types; resonant and elite corpses raise empowered thralls.');
      if (m) {
        details.push(`Ordinary bodies rise as ${m.thrallKind === 'shieldbearer' ? 'shieldbearers' : m.thrallKind === 'wraith' ? 'ranged wraiths' : 'warriors'}.`);
        if (m.thrallHpMult !== 1) details.push(`${discipline!.name}: thralls have ${percent(Math.abs(m.thrallHpMult - 1))} ${m.thrallHpMult > 1 ? 'more' : 'less'} health.`);
        if (m.thrallAttackSpeedMult !== 1) details.push(`${discipline!.name}: thralls attack ${percent(m.thrallAttackSpeedMult - 1)} faster.`);
        if (m.wardPerThrall) details.push(`${discipline!.name}: take ${percent(m.wardPerThrall)} less damage per active thrall.`);
        if (m.corpseHeal) details.push(`${discipline!.name}: consuming this corpse restores ${percent(m.corpseHeal)} of your maximum health.`);
      }
      break;
    case 'miasma':
      details.push(`Slows enemies by ${percent(1 - MIASMA_SLOW)} and builds Withered damage over time, up to ${m?.witheredMaxStacks ?? DISCIPLINES.gravecaller.mods.witheredMaxStacks} stacks.`);
      if (m?.miasmaBurstsCorpses) details.push(`${discipline!.name}: corpses inside your Miasma burst and spread Withered. These bodies are consumed.`);
      break;
    case 'black_litany':
      details.push('Consumes nearby corpses and sacrifices your nearby thralls. More bodies and thralls make the burst stronger.');
      if (m?.sacrificeLeavesCorpse) details.push(`${discipline!.name}: sacrificed thralls leave fresh corpses to raise again.`);
      if (m?.litanyBarrier) details.push(`${discipline!.name}: gain a barrier worth ${percent(m.litanyBarrier)} of your maximum health per corpse or thrall consumed.`);
      if (m?.corpseHeal) details.push(`${discipline!.name}: restore ${percent(m.corpseHeal * 0.5)} of your maximum health per corpse consumed.`);
      break;
    case 'corpse_explosion':
      details.push(`Consumes one corpse. Resonant corpses blast ${number(DETONATE.resonantRadiusMult)}× wider; elite corpses deal ${number(DETONATE.eliteDamageMult)}× damage.`,
        `Toxic corpses leave a friendly rot pool for ${number(DETONATE.rotDurationMs / 1000)}s. A burst body cannot also become a thrall.`);
      break;
    case 'bone_fan':
      details.push(`${BONE_FAN.slivers} slivers, each on a different enemy within ${BONE_FAN.coneHalfDeg * 2}° of your target; the Prelate counts as one.`,
        `+${BONE_FAN.essencePerHit} Grave Essence per sliver that lands (up to ${BONE_FAN.essenceCap} per cast). Equip on the Grimoire's LMB socket.`);
      break;
    case 'rot_lance':
      details.push(`Pierces the first ${ROT_LANCE.pierce} enemies in a narrow line and adds ${ROT_LANCE.withered} Withered stack to each (up to ${m?.witheredMaxStacks ?? DETONATE.rotWitheredCap}).`,
        `+${ROT_LANCE.essence} Grave Essence on the first hit. Equip on the Grimoire's LMB socket.`);
      break;
    case 'grave_offering':
      details.push(`Consumes one corpse: +${GRAVE_OFFERING.essence} essence (+${GRAVE_OFFERING.resonantBonus} resonant, ×${GRAVE_OFFERING.eliteMult} elite) and ${percent(GRAVE_OFFERING.healFrac + (m?.corpseHeal ?? 0))} of your maximum health.`);
      break;
    case 'ivory_cleave':
      details.push(`A ${IVORY_CLEAVE.halfAngleDeg * 2}° arc to ${number(IVORY_CLEAVE.reach)}m. Everything cut gains ${IVORY_CLEAVE.fracture} Fracture stack.`);
      break;
    case 'veil_step':
      details.push('Stops at walls and sealed doors and never leaves the hall you stand in. No damage and no invulnerability. Auto combat never casts it.');
      break;
    case 'rally_dead':
      details.push(`Requires at least one thrall. For ${RALLY.durationS}s${m && discipline!.id === 'gravecaller' ? ` (+${RALLY.gravecallerBonusS}s, Gravecaller)` : ''} thralls deal ${percent(RALLY.damageMult - 1)} more damage and attack ${percent(RALLY.attackSpeedMult - 1)} faster; each heals ${percent(RALLY.healFrac)} and turns on the enemy nearest the cursor.`);
      break;
    case 'carrion_seed':
      details.push(`Arms after ${number(CARRION_SEED.armS)}s; the first enemy within ${number(CARRION_SEED.triggerR)}m bursts it for ${number(CARRION_SEED.burstR)}m and ${CARRION_SEED.withered} Withered stacks. One seed at a time; it withers after ${CARRION_SEED.lifeS}s.`,
        'If another rite uses the seeded corpse, the seed is lost with it.');
      break;
    case 'wailing_skull':
      details.push(`Leaps to ${WAILING_SKULL.hops - 1} more enemies within ${WAILING_SKULL.leapRange}m, each bite ${percent(1 - WAILING_SKULL.falloff)} weaker. A bite that kills earns another leap, up to ${WAILING_SKULL.maxHops} in all.`);
      break;
    case 'grave_step':
      details.push(`Blinks you onto a corpse up to ${number(a.range)}m away in the area you stand in; it never crosses a sealed door. The corpse is not consumed.`,
        `Re-forming bursts within ${GRAVE_STEP.burstRadius}m and makes enemies bleed (Hemorrhage) for ${HEMORRHAGE.durationS}s.`);
      break;
    case 'grave_frost':
      details.push(`A ${GRAVE_FROST.halfAngleDeg * 2}° cone. Chills enemies for ${GRAVE_FROST.chillS}s: ${percent(1 - CHILL.moveMult)} slower movement and ${percent(1 - CHILL.attackRateMult)} slower attacks.`,
        `Enemies already Chilled shatter for ${percent(GRAVE_FROST.shatterMult - 1)} more damage.`);
      break;
    case 'bone_mantle':
      details.push(`Consumes up to ${BONE_MANTLE.maxCorpses} nearby corpses. Barrier: ${percent(BONE_MANTLE.barrierBase)} of your maximum health plus ${percent(BONE_MANTLE.barrierPerCorpse)} per corpse (at most ${percent(BONE_MANTLE.barrierCap)}), held for ${BONE_MANTLE.durationS}s before it fades.`,
        `Shards hit enemies within ${BONE_MANTLE.orbitRadius}m every ${BONE_MANTLE.tickS}s.`);
      break;
    case 'soul_siphon':
      details.push(`Drains every ${SOUL_SIPHON.tickS}s for ${SOUL_SIPHON.durationS}s. Heals ${percent(SOUL_SIPHON.healFrac)} of each tick and returns ${SOUL_SIPHON.essencePerTick} essence. Snaps beyond ${number(a.range * SOUL_SIPHON.breakMult)}m.`);
      break;
    case 'bone_prison':
      details.push(`Roots everything in the ring for ${BONE_PRISON.rootS}s (the Prelate only takes the damage) and adds ${BONE_PRISON.fracture} Fracture.`);
      break;
    case 'grave_hands':
      details.push(`Slows and rakes every ${GRAVE_HANDS.tickS}s for ${GRAVE_HANDS.durationS}s. Each corpse in the field adds ${percent(GRAVE_HANDS.perCorpse)} damage (up to ${GRAVE_HANDS.maxCorpses}); corpses are not consumed.`);
      break;
    case 'bone_storm':
      details.push(`Lasts ${BONE_STORM.durationS}s, +${BONE_STORM.perCorpseS}s per corpse it starts on (up to +${BONE_STORM.maxExtraS}s; not consumed). Drifts toward the nearest enemy and hits every ${BONE_STORM.tickS}s.`);
      break;
    case 'ossuary_wall':
      details.push(`Creates a ${SIGNATURE.wall.length}m wall for ${SIGNATURE.wall.durationS}s. Blocks enemy movement and Penitent cones.`);
      break;
    case 'command_rend':
      details.push(`Requires at least one thrall. Each commanded thrall pays ${percent(SIGNATURE.rend.hpCost)} of its health instead of your essence.`);
      break;
    case 'dirge':
      details.push(`Lasts ${SIGNATURE.dirge.durationS}s. Mends you and your thralls while Silenced enemies cannot start spells.`);
      break;
    // ── Hollow Knight ──
    case 'hollow_cut':
      details.push(`A ${HOLLOW_CUT.halfAngleDeg * 2}° arc ${HOLLOW_CUT.reach}m in front of you. Costs nothing and pays ${HOLLOW_CUT.rage} Rage for every enemy it cuts, so it is worth lining up two or three.`);
      break;
    case 'shield_bash':
      details.push(`Charges ${SHIELD_BASH.dashM}m and stuns the first enemy struck for ${SHIELD_BASH.stunS}s — only ${SHIELD_BASH.bossStunS}s against a boss. Stops at walls and sealed doors.`);
      break;
    case 'grave_slam':
      details.push(`Leaps up to ${GRAVE_SLAM.leapM}m to the cursor and strikes everything within ${GRAVE_SLAM.slamR}m of the landing. It will not leap anywhere you could not walk.`);
      break;
    case 'bulwark':
      details.push(`Held for ${BULWARK.holdS}s: ${percent(BULWARK.damageCut)} less damage from the front ${BULWARK.frontHalfDeg * 2}° only — blows from behind land in full.`,
        `A blow inside the first ${BULWARK.perfectWindowS}s is a perfect block: ${percent(BULWARK.reflect)} of it is reflected and you gain ${KNIGHT_RAGE.perPerfectBlock} Rage.`);
      break;
    case 'corpse_vigil':
      details.push(`Consumes the body and regenerates ${percent(CORPSE_VIGIL.regenFracPerS)} of your maximum health every second for ${CORPSE_VIGIL.durationS}s.`,
        'The corpse cannot then be raised or exploded — in co-op, say which one you are taking.');
      break;
    case 'grave_brand':
      details.push(`Brands a body for ${GRAVE_BRAND.lifeS}s. The first enemy within ${GRAVE_BRAND.triggerR}m of it is rooted for ${GRAVE_BRAND.rootS}s and the corpse is spent.`,
        'A rooted enemy can still swing, so do not brand under your own feet.');
      break;
    case 'oath_unbroken':
      details.push(`For ${OATH_UNBROKEN.durationS}s you cannot be reduced below 1 health, you deal ${percent(OATH_UNBROKEN.damageMult - 1)} more damage, and your Rage fills.`,
        'It does not heal you — when the oath ends you are as hurt as it found you.');
      break;
    case 'plague_bloom':
      details.push(`The first flower lasts ${SIGNATURE.bloom.durationS}s. Every ${SIGNATURE.bloom.spreadEveryS}s it can consume a corpse to seed another flower, up to ${SIGNATURE.bloom.maxGenerations} generations.`,
        `Builds Withered up to ${SIGNATURE.bloom.witheredCap} stacks. Bodies used to spread cannot be raised.`);
      break;
  }
  if (!details.length) details.push(a.description);
  if (SOUL_HARVEST.spells.includes(id)) {
    details.push(empowered ? `Soul Harvest is ready: this cast is free and ${percent(SOUL_HARVEST.areaMult - 1)} larger. It spends the charged meter.` : 'A full Soul Harvest meter makes your next cast of this spell free and larger.');
  }
  // HUD passes the equipped slot; elsewhere, describe the default kit position.
  const kit = state.kit ?? kitFor('necromancer');
  const defaults = [...kit.defaultLoadout, kit.rmb];
  const gKey = state.key ?? (defaults.includes(id) ? String(defaults.indexOf(id) + 1) : undefined);
  const control = a.slot === 0
    ? 'Click an enemy, or Shift + click to cast in place.'
    : a.slot === 6
        ? `Press R or 6, or click this icon.${canUseAutoCombat() ? ' On Easy, Auto may cast it in a suitable fight.' : ''}`
        : gKey === 'RMB' || gKey === '5'
          ? 'Right-click, press 5 or click this icon. Aim before casting. Change this slot in the Grimoire (L).'
        : gKey
          ? `Press or hold ${gKey}; aim with the mouse. You can also click this icon. Change its key in the Grimoire (L).`
          : 'Place it on one of the five slots in the Grimoire (L), then press that key or right-click for slot 5.';
  const status = locked ? `Locked — unlocks at level ${unlockLevel(id)}.` : (state.left ?? 0) > 0 ? `Ready in ${Math.ceil(state.left! / 1000)}s.` : state.affordable === false && !empowered ? `Not enough ${resourceName === 'Essence' ? 'Grave Essence' : resourceName}.` : empowered ? 'Soul Harvest ready.' : 'Ready to cast.';
  return { name: a.name, description: a.description, control, targeting: TARGETING[a.targeting], metrics, details, tip: CODEX_RITES[id].tip, status, empowered, locked };
}
