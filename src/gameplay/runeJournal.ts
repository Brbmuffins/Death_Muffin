import type { StorageLike } from './codexJournal';
import { RUNE_IDS } from '../../server/rules/content/runes';

/** The Relic runes this character has ever held (a browser record, like the Alchemist's Wing shelf): the Codex unseals a rune's page once it has been found. */
const key = (characterId: number) => `dm_runes_found_${characterId}`;

export function loadRunesFound(store: StorageLike | null, characterId: number): Set<string> {
  try {
    const raw = JSON.parse(store?.getItem(key(characterId)) ?? '[]');
    return new Set(Array.isArray(raw) ? raw.filter((x): x is string => typeof x === 'string' && (RUNE_IDS as readonly string[]).includes(x)) : []);
  } catch {
    return new Set();
  }
}

export function recordRunesFound(store: StorageLike | null, characterId: number, held: Iterable<string>): { found: Set<string>; grew: boolean } {
  const found = loadRunesFound(store, characterId);
  const before = found.size;
  for (const id of held) if ((RUNE_IDS as readonly string[]).includes(id)) found.add(id);
  const grew = found.size > before;
  if (grew) {
    try {
      store?.setItem(key(characterId), JSON.stringify([...found]));
    } catch {
      /* storage may be blocked: the record lasts the session */
    }
  }
  return { found, grew };
}
