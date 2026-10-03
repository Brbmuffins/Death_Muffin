// Writes docs/LOOT-TABLES.md from src/gameplay/atlas.ts (npm run gen:loot, run with vite-node). A unit test fails when the committed file is stale.
import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { renderLootTables } from '../src/gameplay/atlasDoc';

const out = fileURLToPath(new URL('../docs/LOOT-TABLES.md', import.meta.url));
writeFileSync(out, renderLootTables());
console.log(`wrote ${out}`);
