import { AREA_ORDER, type AreaId } from '../../server/rules/content/areas';
import { DEAD_ORDER, type DeadId } from '../content/codex';

/**
 * Which Codex entries this character has uncovered (enemies on first sight,
 * areas on first entry, the Prelate on awakening). Browser-local and per
 * character — a convenience, not progress, so every storage access is guarded
 * and the journal simply starts empty when storage is unavailable.
 */
export type CodexKind = 'dead' | 'area';
export interface CodexIds {
  dead: DeadId;
  area: AreaId;
}

/** The subset of the Web Storage API the journal needs (injectable for tests). */
export interface StorageLike {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

export const codexStorageKey = (characterId: number) => `dm_codex_v1_${characterId}`;

const KNOWN: { [K in CodexKind]: readonly string[] } = { dead: DEAD_ORDER, area: AREA_ORDER };

export function browserStorage(): StorageLike | null {
  try {
    const store = globalThis.localStorage;
    if (!store) return null;
    if (import.meta.env.VITE_OFFLINE_BUILD !== '1') return store;
    return {
      getItem: (key) => store.getItem(`dm_offline_${key}`),
      setItem: (key, value) => store.setItem(`dm_offline_${key}`, value),
    };
  } catch {
    return null;
  }
}

export class CodexJournal {
  private found: { [K in CodexKind]: Set<string> } = { dead: new Set(), area: new Set() };
  private listeners = new Set<() => void>();
  private key: string;

  constructor(
    characterId: number,
    private storage: StorageLike | null = browserStorage(),
  ) {
    this.key = codexStorageKey(characterId);
    this.load();
  }

  has<K extends CodexKind>(kind: K, id: CodexIds[K]): boolean {
    return this.found[kind].has(id);
  }

  /** Records a discovery; true only the first time (callers toast on true). */
  discover<K extends CodexKind>(kind: K, id: CodexIds[K]): boolean {
    if (!KNOWN[kind].includes(id) || this.found[kind].has(id)) return false;
    this.found[kind].add(id);
    this.save();
    this.listeners.forEach((fn) => fn());
    return true;
  }

  count(kind: CodexKind): number {
    return this.found[kind].size;
  }

  onChange(fn: () => void): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  private load() {
    try {
      const raw = this.storage?.getItem(this.key);
      if (!raw) return;
      const data = JSON.parse(raw) as Partial<Record<CodexKind, unknown>>;
      for (const kind of ['dead', 'area'] as const) {
        const list = data?.[kind];
        if (!Array.isArray(list)) continue;
        for (const id of list) if (typeof id === 'string' && KNOWN[kind].includes(id)) this.found[kind].add(id);
      }
    } catch {
      /* storage unavailable or corrupt — start sealed */
    }
  }

  private save() {
    try {
      this.storage?.setItem(this.key, JSON.stringify({ dead: [...this.found.dead], area: [...this.found.area] }));
    } catch {
      /* storage unavailable — discoveries last for this session only */
    }
  }
}
