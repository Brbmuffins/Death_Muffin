import { existsSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { ITEMS } from '../items';

describe('item icons', () => {
  it('every catalogue item resolves to an icon file (no 404s in the bag, tooltips or loot beams)', () => {
    const missing = Object.entries(ITEMS)
      .filter(([id, m]) => !existsSync(`public/${m.icon ?? `art/items/${id}.webp`}`))
      .map(([id]) => id);
    expect(missing).toEqual([]);
  });
});
