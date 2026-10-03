import type { Rarity } from '../net/types';

/** Commons and uncommons are farm noise: a short toast that merges repeats. Rare and better stay up as long as any other news. */
export const isMinorLoot = (rarity: Rarity) => rarity === 'common' || rarity === 'uncommon';

/** How long a pickup toast stays (ms); the minimum for a rare drop matches HUD.toast's own floor. */
export const lootToastMs = (rarity: Rarity) => (isMinorLoot(rarity) ? 3500 : 8000);

/** "Bone Dust", then "Bone Dust ×3" as the same item is picked up again within the toast's life. */
export const lootToastLine = (name: string, total: number) => (total > 1 ? `${name} ×${total}` : name);
