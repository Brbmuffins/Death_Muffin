import { ABILITIES, BONE_MANTLE, DETONATE, FRACTURE, GRAVE_FROST, GRAVE_STEP, MIASMA_SLOW, NEEDLE_ESSENCE, SIGNATURE, SIGNATURE_LEVEL, SOUL_HARVEST, WAILING_SKULL, type AbilityId } from '../content/abilities';
import { CODEX_RITES } from '../content/codex';
import { DISCIPLINES, type Discipline } from '../content/disciplines';
import { HEMORRHAGE } from '../content/statuses';

export interface SpellTooltipState {
  empowered?: boolean;
  locked?: boolean;
  affordable?: boolean;
  /** Remaining cooldown in milliseconds; distinct from the base cooldown. */
  left?: number;
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
  const locked = !!state.locked && a.slot === 6;
  const metrics = [
    { label: 'Essence', value: empowered ? `Free (normally ${a.essenceCost})` : a.essenceCost ? number(a.essenceCost) : 'Free' },
    { label: 'Cooldown', value: `${number(a.cooldownMs / 1000)}s` },
    { label: 'Range', value: a.range ? `${number(a.range * (id === 'marrow_spear' ? areaMult : 1))}m` : 'Around you' },
  ];
  let radius = a.radius;
  if (id === 'miasma') radius *= (m?.miasmaRadiusMult ?? 1) * areaMult;
  if (id === 'black_litany') radius *= areaMult;
  if (['miasma', 'black_litany', 'corpse_explosion', 'dirge', 'plague_bloom', 'command_rend'].includes(id)) {
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
    case 'wailing_skull':
      details.push(`Leaps up to ${WAILING_SKULL.hops - 1} times within ${number(WAILING_SKULL.leapRange)}m, each leap ${percent(1 - WAILING_SKULL.falloff)} weaker. A killing leap earns another, up to ${WAILING_SKULL.maxHops} in all.`);
      break;
    case 'grave_step':
      details.push(`Teleports to a corpse and bursts for ${number(GRAVE_STEP.burstRadius)}m. Enemies hit suffer Hemorrhage for ${HEMORRHAGE.durationS}s. The corpse is not consumed.`);
      break;
    case 'grave_frost':
      details.push(`A ${GRAVE_FROST.halfAngleDeg * 2}° cone. Chill lasts ${number(GRAVE_FROST.chillS)}s; enemies already Chilled shatter for ${number(GRAVE_FROST.shatterMult)}× damage.`);
      break;
    case 'bone_mantle':
      details.push(`Consumes up to ${BONE_MANTLE.maxCorpses} nearby corpses. Barrier: ${percent(BONE_MANTLE.barrierBase)} of max health + ${percent(BONE_MANTLE.barrierPerCorpse)} per corpse (cap ${percent(BONE_MANTLE.barrierCap)}) for ${BONE_MANTLE.durationS}s.`);
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
    case 'plague_bloom':
      details.push(`The first flower lasts ${SIGNATURE.bloom.durationS}s. Every ${SIGNATURE.bloom.spreadEveryS}s it can consume a corpse to seed another flower, up to ${SIGNATURE.bloom.maxGenerations} generations.`,
        `Builds Withered up to ${SIGNATURE.bloom.witheredCap} stacks. Bodies used to spread cannot be raised.`);
      break;
  }
  if (SOUL_HARVEST.spells.includes(id)) {
    details.push(empowered ? `Soul Harvest is ready: this cast is free and ${percent(SOUL_HARVEST.areaMult - 1)} larger. It spends the charged meter.` : 'A full Soul Harvest meter makes your next cast of this spell free and larger.');
  }
  const control = a.slot === 0 ? 'Click an enemy, or Shift + click to cast in place.' : a.slot === 5 ? 'Right-click, press 5 or click this icon. Aim before casting.' : a.slot === 6 ? 'Press R or 6, or click this icon. Signature spells are manual.' : `Press or hold ${a.slot}; aim with the mouse. You can also click this icon.`;
  const status = locked ? `Locked — unlocks at level ${SIGNATURE_LEVEL}.` : (state.left ?? 0) > 0 ? `Ready in ${Math.ceil(state.left! / 1000)}s.` : state.affordable === false && !empowered ? 'Not enough Grave Essence.' : empowered ? 'Soul Harvest ready.' : 'Ready to cast.';
  return { name: a.name, description: a.description, control, targeting: TARGETING[a.targeting], metrics, details, tip: CODEX_RITES[id].tip, status, empowered, locked };
}
