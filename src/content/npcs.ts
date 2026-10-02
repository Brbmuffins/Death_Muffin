import { NPC_IDS, NPC_SPOTS, npcInteractableId, type NpcId, type NpcSpot } from './npcSpots';

export { NPC_IDS, npcInteractableId };
export type { NpcId };

/**
 * The people of the Covenant: talkable, never hostile, never required. Names, blurbs and the look of each figure live here;
 * where they stand is content/npcSpots.ts (areas.ts derives their clickable Interactables from that), and graphics/NpcViews.ts reads the
 * look. What they SAY is content/dialogue.ts (data) over gameplay/guidance.ts (selectors).
 */

export interface NpcDef {
  id: NpcId;
  name: string;
  /** One line under the name: what to ask this person about. */
  title: string;
  area: NpcSpot['area'];
  x: number;
  z: number;
  /** Compass facing at rest, radians (rotation.y: atan2(dx, dz)); they turn to the player when near. */
  rest: number;
  /** The Codex "People" entry. */
  blurb: string;
  /** Soft glow colour (the "something new to say" ring and the nameplate accent). */
  accent: number;
}

const at = (id: NpcId) => ({ area: NPC_SPOTS[id].area, x: NPC_SPOTS[id].x, z: NPC_SPOTS[id].z });
const NPC_SPOTS_POS = { prior: at('prior'), sexton: at('sexton'), apothecary: at('apothecary') };

export const NPCS: Record<NpcId, NpcDef> = {
  prior: {
    id: 'prior',
    name: 'The Prior',
    title: 'Keeper of the Chapterhouse',
    ...NPC_SPOTS_POS.prior,
    rest: 0.5,
    blurb: 'Keeper of the Chapterhouse and its seals. Ask where to hunt next, what a seal or a boss asks of you, and when the Altar of Ascension is ready.',
    accent: 0xc6a4ff,
  },
  sexton: {
    id: 'sexton',
    name: 'The Sexton',
    title: 'Tender of the Acre',
    ...NPC_SPOTS_POS.sexton,
    rest: Math.PI / 2,
    blurb: 'Tender of the Sexton’s Acre. Ask about gathering, your Grave Laborers, the Bone Grinder, the Ossuary Vault and the day’s Contracts.',
    accent: 0xe8c15a,
  },
  apothecary: {
    id: 'apothecary',
    name: 'The Apothecary',
    title: 'Brewer of the Covenant',
    ...NPC_SPOTS_POS.apothecary,
    rest: -0.9,
    blurb: 'Brews for the Covenant at the Workbench, until the Alchemist’s Wing is raised. Ask what to brew, where reagents fall, and how elixirs and tonics differ.',
    accent: 0x8fd18a,
  },
};

/**
 * How each figure looks until the real models arrive. `slug` must be a CREATURE_MODELS key (graphics/modelPaths.ts): when
 * `npc_prior` / `npc_sexton` / `npc_apothecary` are added there, change the slug here (keep the old one as `fallback`).
 * Every clip use in NpcViews is optional (`has('talk')`-style), so a stand-in with only idle/walk works.
 */
export interface NpcLook {
  slug: 'necromancer' | 'deacon' | 'grave_robber' | 'plague_doctor' | 'penitent' | 'bell_templar' | 'lich_acolyte';
  fallback?: NpcLook['slug'];
  scale: number;
  tint: number;
  emissive: number;
  glow: number;
}

export const NPC_LOOKS: Record<NpcId, NpcLook> = {
  prior: { slug: 'deacon', scale: 0.95, tint: 0xf3ecff, emissive: 0x4b2f8a, glow: 0.07 },
  sexton: { slug: 'grave_robber', scale: 1.0, tint: 0xf0e6d0, emissive: 0x6b4a1f, glow: 0.1 },
  apothecary: { slug: 'plague_doctor', scale: 0.95, tint: 0xe2f2dc, emissive: 0x2f7a47, glow: 0.08 },
};

/** Distance (world units) inside which an NPC turns to look at the player, and the walk-up range for the E key. */
export const NPC_LOOK_RANGE = 8;
export const NPC_TALK_RANGE = 3.4;

export const npcFromInteractable = (interactableId: string): NpcId | undefined => NPC_IDS.find((n) => npcInteractableId(n) === interactableId);
