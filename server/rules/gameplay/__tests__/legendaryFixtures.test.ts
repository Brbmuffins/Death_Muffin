import * as fs from 'node:fs';
import * as path from 'node:path';
import { describe, expect, it } from 'vitest';
import { legendarySetFor, pickLegendaryItem, pickLegendarySet, rollLegendary } from '../../content/legendarySets';
import { rollBoss } from '../lootRules';

/**
 * The Godot suite rules_loot replays these fixtures through DmLegendarySets and DmLoot. Their answers depend on the legendary set list, so a new
 * set (War's armor sets) moves some of them. They are the server rules' answers, made here: after a set change on both sides,
 * UPDATE_LOOT_PARITY=1 npx vitest run server/rules/gameplay/__tests__/ rewrites them with loot_parity.json (inputs and seeds stay as they are).
 */
const DIR = path.resolve(__dirname, '../../../../client/tests/rules_loot/fixtures');
const UPDATE = !!process.env.UPDATE_LOOT_PARITY;

/** mulberry32, bit for bit the same as the suite's rng (client/tests/rules_loot/rng_shim.gd). */
function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

type Case = Record<string, unknown>;
const ownedSet = (owned: unknown): Set<string> | undefined => (Array.isArray(owned) ? new Set(owned as string[]) : undefined);

/** Recomputes each case's answers with `answer`; writes the file back under UPDATE_LOOT_PARITY, else checks it is current. */
function replay(file: string, answer: (c: Case) => Case) {
  const p = path.join(DIR, file);
  const text = fs.readFileSync(p, 'utf8');
  const now = (JSON.parse(text) as Case[]).map((c) => ({ ...c, ...answer(c) }));
  if (UPDATE) fs.writeFileSync(p, JSON.stringify(now) + (text.endsWith('\n') ? '\n' : ''));
  expect(JSON.parse(fs.readFileSync(p, 'utf8'))).toEqual(JSON.parse(JSON.stringify(now)));
}

describe('legendary fixtures the Godot suite replays are the server rules\' answers', () => {
  it('legendary_set_for.json', () => {
    replay('legendary_set_for.json', (c) => ({ set: legendarySetFor(String(c.d)) ?? null }));
  });

  it('legendary_pick.json', () => {
    replay('legendary_pick.json', (c) => {
      const disc = String(c.disc);
      const owned = ownedSet(c.owned);
      const r = mulberry32(Number(c.seed));
      const roll = rollLegendary(disc, Number(c.chance), r, owned ? () => owned : undefined);
      return {
        set: pickLegendarySet(disc, mulberry32(Number(c.seed))),
        item: pickLegendaryItem(disc, mulberry32(Number(c.seed)), owned),
        roll,
        after: r(),
      };
    });
  });

  it('roll_boss.json', () => {
    replay('roll_boss.json', (c) => {
      const owned = ownedSet(c.owned);
      const r = mulberry32(Number(c.seed));
      const res = rollBoss({
        waveTier: Number(c.tier), difficulty: String(c.diff), area: String(c.area), costShards: Number(c.cost),
        boss: c.boss == null ? '' : String(c.boss), disciplineId: c.disc == null ? '' : String(c.disc), owned: owned ? () => owned : undefined,
      }, r);
      return { res, after: r() };
    });
  });
});
