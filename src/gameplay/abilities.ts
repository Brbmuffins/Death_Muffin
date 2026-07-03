/**
 * Per-class ability kits on keys 1–4, Diablo-style. All classes share the
 * same four archetypes (basic / heavy / nova / ultimate) with class-flavored
 * names, colors, and reach; melee classes strike, casters fire ranged bolts.
 * Damage = attackPower × damageMult, routed through the same host-authoritative
 * hit path as before.
 */

export type AbilityKind = 'strike' | 'heavy' | 'nova' | 'ult';

export interface Ability {
  slot: 1 | 2 | 3 | 4;
  name: string;
  icon: string;     // emoji fallback
  iconPng: string;  // PNG path under public/
  kind: AbilityKind;
  cooldownMs: number;
  /** Reach for strike/heavy; radius for nova/ult (centered on the player). */
  range: number;
  damageMult: number;
  ranged: boolean; // draws a bolt line instead of a melee flash
  color: string;
}

const KIT_BASE: Record<AbilityKind, Omit<Ability, 'name' | 'icon' | 'iconPng' | 'range' | 'ranged' | 'color'>> = {
  strike: { slot: 1, kind: 'strike', cooldownMs: 500, damageMult: 1.0 },
  heavy: { slot: 2, kind: 'heavy', cooldownMs: 4000, damageMult: 2.2 },
  nova: { slot: 3, kind: 'nova', cooldownMs: 6000, damageMult: 1.5 },
  ult: { slot: 4, kind: 'ult', cooldownMs: 12000, damageMult: 3.0 },
};

function kit(
  ranged: boolean,
  reach: number,
  color: string,
  slug: string,
  names: [string, string, string, string],
  icons: [string, string, string, string],
): Ability[] {
  const kinds: AbilityKind[] = ['strike', 'heavy', 'nova', 'ult'];
  return kinds.map((kind, i) => ({
    ...KIT_BASE[kind],
    name: names[i],
    icon: icons[i],
    iconPng: `art/abilities/${slug}-${i + 1}.png`,
    // Novas/ults are centered on the player; strikes use class reach.
    range: kind === 'nova' ? 3.5 : kind === 'ult' ? 5 : reach,
    ranged: ranged && (kind === 'strike' || kind === 'heavy'),
    color,
  }));
}

const KITS: Record<number, Ability[]> = {
  // Guardian — melee tank
  1: kit(false, 2.2, '#f59e0b', 'guardian',
    ['Shield Strike', 'Crushing Blow', 'Warstomp', 'Avatar of Bronze'],
    ['🛡', '🔨', '💥', '⚜']),
  // Shadowblade — melee burst
  2: kit(false, 2.2, '#a78bfa', 'shadowblade',
    ['Quick Slash', 'Eviscerate', 'Fan of Blades', 'Death Bloom'],
    ['🗡', '⚔', '🌀', '☠']),
  // Cleric — ranged support
  3: kit(true, 7, '#fde68a', 'cleric',
    ['Smite', 'Holy Bolt', 'Radiant Nova', 'Judgement'],
    ['✝', '✨', '🌟', '⚖']),
  // Arcanist — ranged DPS
  4: kit(true, 8, '#60a5fa', 'arcanist',
    ['Arcane Bolt', 'Arcane Blast', 'Frost Nova', 'Meteor'],
    ['🔮', '💫', '❄', '☄']),
};

export function abilitiesFor(classIndex: number): Ability[] {
  return KITS[classIndex] ?? KITS[1];
}
