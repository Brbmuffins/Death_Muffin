import { describe, expect, it } from 'vitest';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { ITEMS } from '../items';
import { ALL_RECIPE_ROWS } from '../recipes';
import { TRADE_GOODS_RECIPES } from '../tradeGoods';

const SQL = readFileSync('server/death-muffin/backend/migrations/028-trade-goods-recipes.sql', 'utf8');

/** Parse the migration's recipe and ingredient rows back into RecipeRow shape. */
function parse() {
  const recipes = new Map<string, { name: string; prof: string; level: number; result: string; qty: number; ings: [string, number][] }>();
  for (const m of SQL.matchAll(/INTO recipes \([^)]*\) VALUES \('([^']+)', '([^']+)', '([^']+)', (\d+), '([^']+)', 'craft', \d+, (\d+)\);/g)) {
    recipes.set(m[1], { name: m[2], prof: m[3], level: +m[4], result: m[5], qty: +m[6], ings: [] });
  }
  for (const m of SQL.matchAll(/INTO recipe_ingredients \([^)]*\) VALUES \('([^']+)', '([^']+)', (\d+)\);/g)) recipes.get(m[1])!.ings.push([m[2], +m[3]]);
  return recipes;
}

describe('trade-goods recipes (migration 028)', () => {
  it('the migration is generated from the content file and up to date', () => {
    expect(() => execFileSync('node', ['tools/build-trade-goods-sql.mjs', '--check'], { stdio: 'pipe' })).not.toThrow();
  });

  it('client recipe data equals the migration rows', () => {
    const sql = parse();
    expect(sql.size).toBe(TRADE_GOODS_RECIPES.length);
    for (const [id, name, prof, level, result, qty, ings] of TRADE_GOODS_RECIPES) {
      const row = sql.get(id);
      expect(row, id).toBeTruthy();
      expect(row).toEqual({ name, prof, level, result, qty, ings });
      expect(ALL_RECIPE_ROWS.find((r) => r[0] === id), `${id} in ALL_RECIPE_ROWS`).toEqual([id, name, prof, level, result, qty, ings]);
    }
  });

  it('is additive only: no schema change, no deletes, only INSERT IGNORE', () => {
    const stmts = SQL.split('\n').filter((l) => l && !l.startsWith('--'));
    for (const s of stmts) expect(s).toMatch(/^INSERT IGNORE INTO (recipes|recipe_ingredients) /);
    expect(SQL).not.toMatch(/\b(DROP|DELETE|ALTER|CREATE|UPDATE|TRUNCATE)\b/i);
  });

  it('uses existing item rows only and recipe ids stay unique', () => {
    for (const [id, , , , result, , ings] of TRADE_GOODS_RECIPES) {
      expect(ITEMS[result], `${id} result ${result}`).toBeTruthy();
      for (const [item] of ings) expect(ITEMS[item], `${id} ingredient ${item}`).toBeTruthy();
    }
    const ids = ALL_RECIPE_ROWS.map((r) => r[0]);
    expect(new Set(ids).size).toBe(ids.length);
  });

  it('no recipe pays out more vendor value than it eats (no gold loop)', () => {
    for (const [id, , , , result, qty, ings] of TRADE_GOODS_RECIPES) {
      const inV = ings.reduce((n, [item, k]) => n + ITEMS[item].sell * k, 0);
      const outV = ITEMS[result].sell * qty;
      expect(outV, `${id}: ${inV} in, ${outV} out`).toBeLessThanOrEqual(inV);
    }
  });
});
