/**
 * Per-family resource rules — the generalisation of the necromancer's Grave
 * Essence. Each class family owns one resource: its ceiling, its starting
 * value, what a revive leaves, and its passive drift per second.
 *
 * The `necromancer` rules reproduce the pre-framework behaviour exactly
 * (60% of max on spawn, 50% on revive, unconditional `stats.essenceRegen`
 * regeneration), so the four necromantic disciplines are unchanged — the
 * resource regression test in `__tests__/resources.test.ts` pins that.
 */
import type { ClassFamily } from '../../server/rules/content/disciplines';
import type { DerivedStats } from './characterStats';

export type ResourceKind = 'essence' | 'rage' | 'oil' | 'resonance' | 'offal' | 'veil';

export interface PassiveContext {
  stats: DerivedStats;
  value: number;
  max: number;
  /** Milliseconds since the player last took damage. Families gate decay on it. */
  sinceHurtMs: number;
  sinceResourceGainMs: number;
}

export interface ResourceRules {
  kind: ResourceKind;
  /** Shown under the HUD's right orb. */
  label: string;
  /** Orb liquid colour. */
  color: string;
  max(stats: DerivedStats): number;
  initial(max: number): number;
  onRevive(max: number): number;
  /** Signed change per second; positive regenerates, negative decays. */
  passive(ctx: PassiveContext): number;
}

/** Grave Essence — the four necromantic disciplines. Behaviour is frozen. */
const NECROMANCER: ResourceRules = {
  kind: 'essence',
  label: 'Grave Essence',
  color: '#7bd3c8',
  max: (stats) => stats.maxEssence,
  initial: (max) => max * 0.6,
  onRevive: (max) => max * 0.5,
  passive: ({ stats }) => stats.essenceRegen,
};

/**
 * Rage — Hollow Knight. Built by taking and dealing punishment rather than
 * regenerated, so it only decays, and only once the fight has clearly stopped
 * (4 s after the last hit taken). Gains are pushed in by the kit:
 * +1 per 1% max HP lost, +4 per Hollow Cut hit, +15 on a perfect block.
 */
const KNIGHT: ResourceRules = {
  kind: 'rage',
  label: 'Rage',
  color: '#8a1f2c',
  max: () => 100,
  initial: () => 0,
  onRevive: () => 0,
  passive: ({ sinceHurtMs }) => (sinceHurtMs > 4000 ? -4 : 0),
};

/**
 * Families whose kits are not built yet fall back to the necromancer rules so
 * an unexpected `discipline_index` can never leave a player with a dead
 * resource orb. Each is replaced by its own rules when its kit lands.
 */
export const RESOURCE_RULES: Record<ClassFamily, ResourceRules> = {
  necromancer: NECROMANCER,
  knight: KNIGHT,
  warden: { kind: 'oil', label: 'Oil', color: '#f2b84b', max: () => 100, initial: () => 60, onRevive: () => 50, passive: () => 3 },
  monk: { kind: 'resonance', label: 'Resonance', color: '#e8d9a0', max: () => 100, initial: () => 0, onRevive: () => 0, passive: ({ sinceResourceGainMs }) => sinceResourceGainMs > 2000 ? -5 : 0 },
  witch: { kind: 'offal', label: 'Offal', color: '#9a1b2a', max: () => 100, initial: () => 0, onRevive: () => 0, passive: () => 0 },
  veil: { kind: 'veil', label: 'Veil', color: '#bff3ff', max: () => 100, initial: () => 100, onRevive: () => 100, passive: () => 8 },
};

export function resourceRulesFor(family: ClassFamily): ResourceRules {
  return RESOURCE_RULES[family] ?? NECROMANCER;
}
