/**
 * Death Muffin -> Godot data export for the gathering/crafting/inventory rules (godot/rules/gathering, godot/rules/inventory).
 * Imports the REAL game modules, writes godot/data/gathering/gathering.json. Run: npx vite-node tools/godot/export-gathering.ts
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { NODES, SKILLS } from '../../server/rules/gameplay/gatheringRules';
import { NODE_REACH } from '../../src/content/layout';
import { PLOTS, SEEDS, COMPOST_ITEM, COMPOST_SPEED } from '../../server/rules/content/gardening';
import { ALL_RECIPE_ROWS } from '../../src/content/recipes';
import { PROCESSING_RECIPES, MEALS } from '../../server/rules/content/processing';
import { ALCHEMY_RECIPES } from '../../server/rules/content/alchemy';
import { REAGENT_RECIPES } from '../../server/rules/content/reagents';
import { MOB_REAGENTS } from '../../server/rules/content/reagents';
import { RELIC_ORDERS } from '../../server/rules/gameplay/contractRules';
import { ITEMS } from '../../server/rules/content/items';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const OUT = resolve(ROOT, 'godot/data/gathering');
mkdirSync(OUT, { recursive: true });

const items: Record<string, unknown> = {};
for (const [id, m] of Object.entries(ITEMS)) items[id] = { name: m.name, type: m.type, rarity: m.rarity, sell: m.sell, ...(m.offlineStats ? { offlineStats: m.offlineStats } : {}), ...(m.stack !== undefined ? { stack: m.stack } : {}) };

const data = {
  skills: SKILLS,
  nodes: Object.values(NODES),
  node_reach: NODE_REACH,
  plots: PLOTS,
  seeds: SEEDS,
  compost: { item: COMPOST_ITEM, speed: COMPOST_SPEED },
  recipes: ALL_RECIPE_ROWS,
  processing_recipes: PROCESSING_RECIPES,
  alchemy_recipes: ALCHEMY_RECIPES,
  reagent_recipes: REAGENT_RECIPES,
  meals: MEALS,
  mob_reagents: MOB_REAGENTS,
  relic_orders: RELIC_ORDERS,
  items,
};
writeFileSync(resolve(OUT, 'gathering.json'), JSON.stringify(data) + '\n');
console.log('nodes', data.nodes.length, 'recipes', data.recipes.length, 'items', Object.keys(items).length);
