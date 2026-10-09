import type { AreaId } from './areas';

/**
 * Where the people of the Covenant stand: the only part of content/npcs.ts that areas.ts (and so the server rules bundle) needs.
 * Names, blurbs and looks live in npcs.ts; this file stays tiny and dependency-free.
 */
export type NpcId = 'prior' | 'sexton' | 'apothecary';
export const NPC_IDS: NpcId[] = ['prior', 'sexton', 'apothecary'];

export interface NpcSpot {
  area: AreaId;
  x: number;
  z: number;
  /** The label on the clickable Interactable. */
  label: string;
}

export const NPC_SPOTS: Record<NpcId, NpcSpot> = {
  prior: { area: 'chapterhouse', x: -3.4, z: 15.8, label: 'The Prior' },
  sexton: { area: 'acre', x: -26, z: 23, label: 'The Sexton' },
  // In front of her counter in the Alchemist's Wing (the counter itself stands at areas.ts WING_APOTHECARY_SPOT, x 45.1).
  apothecary: { area: 'alchemist_wing', x: 42.6, z: 20, label: 'The Apothecary' },
};

export const npcInteractableId = (id: NpcId) => `npc_${id}`;
