import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { renderLootTables } from '../atlasDoc';

describe('docs/LOOT-TABLES.md', () => {
  it('is fresh: it is exactly what `npm run gen:loot` writes from the tables the game rolls', () => {
    const committed = readFileSync(new URL('../../../docs/LOOT-TABLES.md', import.meta.url), 'utf8');
    // Run `npm run gen:loot` and commit the file when this fails.
    expect(committed === renderLootTables()).toBe(true);
  });

  it('covers every part of the owner’s ask', () => {
    const doc = renderLootTables();
    for (const heading of ['## What moves these numbers', '## Legendary armor sets', '## The Catacomb Depths', '## Crafting, brewing and processing', '## Salvage', '## How to upgrade gear', '### The Hollow Graves', '### The Mourning Fen']) expect(doc).toContain(heading);
    for (const boss of ['The Gravedigger King', 'The Bone Abbess', 'The Bell-Sworn Prelate', 'The Mire Mother']) expect(doc).toContain(boss);
  });
});
