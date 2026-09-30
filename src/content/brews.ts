/**
 * The Brew engine. Every drinkable buff is one row here: a brew goes in one of two slots (an elixir is a combat
 * effect, a tonic is utility), carries one or more effects, and lasts `seconds`. A new elixir REPLACES the active
 * elixir; a tonic never touches the elixir slot. Each effect kind is read in exactly one place in the game code
 * (see the table in docs/ALCHEMY-AND-WORLDS-PLAN.md, Part 1 A). Pure helpers live here so they can be unit-tested.
 */

import { REAGENT_BREWS } from './reagents';

export type BrewSlot = 'elixir' | 'tonic';

export type BrewKind =
  | 'damage' | 'ward' | 'lifesteal' | 'haste' | 'resist_fire' | 'resist_rot' // elixir slot
  | 'speed' | 'essence' | 'wisdom' | 'fortune'; // tonic slot

export interface BrewEffect { kind: BrewKind; value: number }

export interface BrewDef {
  slot: BrewSlot;
  effects: BrewEffect[];
  seconds: number;
  label: string;
  /** Tray / float-text colour. */
  color: number;
  /** One-character mark for the HUD chip. */
  glyph: string;
}

/** Existing flasks keep their ids and values; new brews are added as rows here. */
const BASE_BREWS: Record<string, BrewDef> = {
  flask_damage: { slot: 'elixir', effects: [{ kind: 'damage', value: 0.15 }], seconds: 45, label: 'Forge-tempered', color: 0xffa060, glyph: '✦' },
  elixir_moonlight: { slot: 'elixir', effects: [{ kind: 'damage', value: 0.25 }], seconds: 60, label: 'Moonlit', color: 0xbcd0ff, glyph: '☾' },
  flask_void_resist: { slot: 'elixir', effects: [{ kind: 'ward', value: 0.25 }], seconds: 90, label: 'Warded', color: 0xb9c8ff, glyph: '◈' },
  flask_speed: { slot: 'tonic', effects: [{ kind: 'speed', value: 0.2 }], seconds: 30, label: 'Swift', color: 0x9ff5e0, glyph: '≫' },
};

/** The four original flasks and elixirs plus the reagent brews (content/reagents.ts). */
export const BREWS: Record<string, BrewDef> = { ...BASE_BREWS, ...REAGENT_BREWS };

export const BREW_SLOTS: BrewSlot[] = ['elixir', 'tonic'];
/** Belt quick-keys. F is reserved for throwable concoctions (Phase B). */
export const BREW_KEYS: Record<BrewSlot, string> = { elixir: 'z', tonic: 'x' };
/** Drinking the same brew again extends it, up to this many times its own duration remaining. */
export const BREW_EXTEND_CAP = 2;

/** Lifesteal guard rails: at most this many targets count per hit, and one hit heals at most this share of max HP. */
export const LIFESTEAL_TARGET_CAP = 3;
export const LIFESTEAL_HIT_CAP = 0.015;

export interface ActiveBrew { id: string; until: number }
export type ActiveBrews = Record<BrewSlot, ActiveBrew | null>;

export const emptyBrews = (): ActiveBrews => ({ elixir: null, tonic: null });

/** Sum of one effect kind across the active (unexpired) brews. O(2). */
export function brewValue(brews: ActiveBrews, kind: BrewKind, now: number): number {
  let sum = 0;
  for (const slot of BREW_SLOTS) {
    const a = brews[slot];
    if (!a || now >= a.until) continue;
    const def = BREWS[a.id];
    if (!def) continue;
    for (const e of def.effects) if (e.kind === kind) sum += e.value;
  }
  return sum;
}

/** Fire and rot blows the resist effects cover (the `from` of a hurt event). */
export const FIRE_SOURCES = ['ember', 'burn'];
export const ROT_SOURCES = ['toxic', 'dust'];

/** The brew-derived damage reduction for one incoming blow (adds to the ward sum; Player caps the total at 60%). */
export function brewWard(brews: ActiveBrews, from: string, now: number): number {
  let w = brewValue(brews, 'ward', now);
  if (FIRE_SOURCES.includes(from)) w += brewValue(brews, 'resist_fire', now);
  if (ROT_SOURCES.includes(from)) w += brewValue(brews, 'resist_rot', now);
  return w;
}

export interface DrinkResult { replaced: string | null; extended: boolean; until: number }

/** Drink a brew: a different brew in the slot is replaced, the same brew is extended (capped). Mutates `brews`. */
export function applyBrew(brews: ActiveBrews, id: string, now: number): DrinkResult {
  const def = BREWS[id];
  const cur = brews[def.slot];
  const live = cur && now < cur.until ? cur : null;
  const ms = def.seconds * 1000;
  if (live && live.id === id) {
    const until = Math.min(live.until + ms, now + ms * BREW_EXTEND_CAP);
    brews[def.slot] = { id, until };
    return { replaced: null, extended: true, until };
  }
  brews[def.slot] = { id, until: now + ms };
  return { replaced: live ? live.id : null, extended: false, until: now + ms };
}

/** Heal from lifesteal for one hit intent: % of damage over at most LIFESTEAL_TARGET_CAP targets, capped per hit. */
export function lifestealHeal(dmg: number, targets: number, frac: number, maxHp: number): number {
  if (frac <= 0 || dmg <= 0 || targets <= 0) return 0;
  return Math.min(dmg * Math.min(targets, LIFESTEAL_TARGET_CAP) * frac, maxHp * LIFESTEAL_HIT_CAP);
}

const pct = (v: number) => `${Math.round(v * 100)}%`;
const EFFECT_TEXT: Record<BrewKind, (v: number) => string> = {
  damage: (v) => `+${pct(v)} spell damage`,
  ward: (v) => `${pct(v)} less damage taken`,
  lifesteal: (v) => `heal ${pct(v)} of damage dealt`,
  haste: (v) => `+${pct(v)} cooldown recovery`,
  resist_fire: (v) => `${pct(v)} less fire damage`,
  resist_rot: (v) => `${pct(v)} less rot and plague damage`,
  speed: (v) => `+${pct(v)} move speed`,
  essence: (v) => `+${pct(v)} essence regeneration`,
  wisdom: (v) => `+${pct(v)} experience from kills`,
  fortune: (v) => `+${pct(v)} item drop chance`,
};

export const effectText = (e: BrewEffect) => EFFECT_TEXT[e.kind](e.value);
export const brewEffectsText = (def: BrewDef) => def.effects.map(effectText).join(' · ');
export const slotName = (slot: BrewSlot) => (slot === 'elixir' ? 'Elixir' : 'Tonic');

/** One line for item tooltips: slot, effects, duration. */
export function brewSummary(id: string): string | null {
  const def = BREWS[id];
  return def ? `${slotName(def.slot)} · ${brewEffectsText(def)} · ${def.seconds}s` : null;
}
