import { rollLoot, type RolledDrop } from '../net/api';
import { canRoll } from './affixes';
import type { DropSource } from '../../server/rules/gameplay/affixRules';
import type { LootDrop } from './loot';

/** How many drops one request may carry (the server's MAX_DROPS). */
const BATCH = 12;

type RollFn = typeof rollLoot;

/**
 * Asks the server to roll item level and affixes for the gear in a kill's drops, and attaches the answer to the drop so the bag
 * save can name it. Plain materials never leave the client. If the server cannot roll (offline, too many unclaimed relics, a
 * hiccup) the drop simply stays plain gear with its base stats: nothing is lost and nothing is invented client-side.
 */
export class LootRoller {
  /** Requests in flight (for the debug overlay and tests). */
  pending = 0;

  constructor(private characterId: number, private roll: RollFn = rollLoot) {}

  /** Mutates `drops` in place: each rolled piece gains `instance`. Never rejects. */
  async attach(drops: LootDrop[], level: number, source: DropSource): Promise<void> {
    const gear = drops.filter((d) => canRoll(d.item_id) && !d.instance);
    for (let i = 0; i < gear.length; i += BATCH) {
      const batch = gear.slice(i, i + BATCH);
      this.pending++;
      try {
        const answer: RolledDrop[] = await this.roll(this.characterId, batch.map((d) => ({ item_id: d.item_id, level, source })));
        batch.forEach((d, n) => {
          const a = answer[n];
          if (a && a.item_id === d.item_id && a.instance_id) d.instance = { id: a.instance_id, ilvl: a.ilvl, affixes: a.affixes };
        });
      } catch (err) {
        console.warn('[loot] could not roll item levels', err);
      } finally {
        this.pending--;
      }
    }
  }
}
