import * as fs from 'node:fs';
import * as path from 'node:path';
import { describe, expect, it } from 'vitest';
import { AREAS } from '../../content/areas';
import { BOSSES } from '../../content/bosses';
import { DISCIPLINES } from '../../content/disciplines';
import { ENEMIES } from '../../content/enemies';
import { ITEMS } from '../../content/items';
import { LEGENDARY_SET_IDS, legendaryItemId } from '../../content/legendarySets';
import { EVENT_STREAMS, dropStream, eventStreams, rollBoss, rollBossRune, rollEvent, rollFirstKillItem, rollGearInstances, rollKill, rollSurgeItem, type DropKind } from '../lootRules';

/**
 * The parity fixture: seeded rolls of every kind, written here and replayed by the Godot suite rules_loot (loot_parity_part.gd) through
 * DmLoot + DmDropStream. The client and the server must roll the same drop from the same stream (ROADMAP, authority Phase 1).
 * After a deliberate loot change on both sides: UPDATE_LOOT_PARITY=1 npx vitest run server/rules/gameplay/__tests__/lootRules.test.ts
 */
const FIXTURE = path.resolve(__dirname, '../../../../client/tests/rules_loot/fixtures/loot_parity.json');

type Words = [number, number, number, number];
function buildCases() {
  const pick = dropStream([1, 2, 3, 4]);
  const word = () => Math.floor(pick() * 4294967296) >>> 0;
  const seed = (): Words => [word(), word(), word(), word()];
  const one = <T,>(list: readonly T[]): T => list[Math.floor(pick() * list.length)];
  const lootAreas = Object.keys(AREAS).filter((a) => (AREAS as Record<string, { loot: unknown[] }>)[a].loot.length);
  const allAreas = Object.keys(AREAS);
  const defs = Object.keys(ENEMIES);
  const discs = ['', ...Object.keys(DISCIPLINES)];
  const diffs = ['easy', 'medium', 'hard'];
  const legendaries = LEGENDARY_SET_IDS.flatMap((s) => (['head', 'chest', 'hands', 'legs', 'feet'] as const).map((p) => legendaryItemId(s, p)));
  const owned = (): string[] => (pick() < 0.5 ? [] : legendaries.filter(() => pick() < 0.4));
  const cases: unknown[] = [];
  for (let i = 0; i < 600; i++) {
    const k = {
      def: one(defs), area: i % 4 === 0 ? one(['cloister', 'pyre', 'fen']) : one(allAreas), level: 1 + Math.floor(pick() * 400), elite: pick() < 0.45,
      waveTier: Math.floor(pick() * 10), difficulty: one(diffs), itemChanceMult: one([1, 1, 1.15, 1.3]), disciplineId: one(discs),
      runePity: one([1, 1, 1.25, 2, 3]), owned: owned(),
    };
    const s = { rand: seed(), reagent: seed(), rune: seed() };
    const out = rollKill({ ...k, owned: () => new Set(k.owned) }, dropStream(s.rand), dropStream(s.reagent), dropStream(s.rune));
    cases.push({ kind: 'kill', in: k, seeds: s, out });
  }
  const bossIds = Object.keys(BOSSES);
  for (let i = 0; i < 150; i++) {
    const def = (BOSSES as Record<string, { id: string; area: string; shards: number }>)[one(bossIds)];
    const b = { waveTier: Math.floor(pick() * 10), difficulty: one(diffs), area: def.area, costShards: def.shards, boss: def.id, disciplineId: one(discs), owned: owned() };
    const s = { rand: seed() };
    cases.push({ kind: 'boss', in: b, seeds: s, out: rollBoss({ ...b, owned: () => new Set(b.owned) }, dropStream(s.rand)) });
  }
  for (let i = 0; i < 120; i++) {
    const a = { area: one(lootAreas), disciplineId: one(discs) };
    const s = { rand: seed() };
    cases.push({ kind: 'surge', in: a, seeds: s, out: rollSurgeItem(a.area, dropStream(s.rand), a.disciplineId) });
    const s2 = { rand: seed() };
    cases.push({ kind: 'first_kill', in: a, seeds: s2, out: rollFirstKillItem(a.area, dropStream(s2.rand), a.disciplineId) });
  }
  for (let i = 0; i < 100; i++) {
    const b = { boss: one([...bossIds, 'prelate', 'nobody']), first: pick() < 0.5 };
    const s = { rand: seed() };
    cases.push({ kind: 'boss_rune', in: b, seeds: s, out: rollBossRune(b.boss, b.first, dropStream(s.rand)) });
  }
  const sources = ['kill', 'elite', 'boss', 'first_kill', 'surge'] as const;
  const gearIds = Object.keys(ITEMS).filter((id) => ['weapon', 'offhand', 'armor_head', 'armor_chest', 'armor_legs', 'armor_feet', 'armor_hands', 'ring', 'trinket'].includes(String((ITEMS as Record<string, { type?: string }>)[id].type)));
  for (let i = 0; i < 150; i++) {
    const items = Array.from({ length: 1 + Math.floor(pick() * 4) }, () => ({ item_id: pick() < 0.7 ? one(gearIds) : 'reagent_grave_dust', quantity: 1 }));
    const g = { items, level: 1 + Math.floor(pick() * 700), characterLevel: 1 + Math.floor(pick() * 700), source: one(sources) };
    const s = { gear: seed() };
    cases.push({ kind: 'gear', in: g, seeds: s, out: rollGearInstances(g.items, g.level, g.characterLevel, g.source, dropStream(s.gear)) });
  }
  // Whole drop events, as the client rolls them on a kill and the server again on a claim.
  for (let i = 0; i < 300; i++) {
    const kind = one(['kill', 'kill', 'elite', 'elite', 'boss', 'surge'] as const) as DropKind;
    const bdef = (BOSSES as Record<string, { id: string; area: string; shards: number }>)[one(bossIds)];
    const f = kind === 'boss'
      ? { boss: bdef.id, area: bdef.area, costShards: bdef.shards, first: pick() < 0.4, level: 1 + Math.floor(pick() * 200), waveTier: Math.floor(pick() * 10), difficulty: one(diffs), disciplineId: one(discs), characterLevel: 1 + Math.floor(pick() * 700), owned: owned() }
      : kind === 'surge'
        ? { area: one(lootAreas), level: 1 + Math.floor(pick() * 200), disciplineId: one(discs), characterLevel: 1 + Math.floor(pick() * 700) }
        : { def: one(defs), area: i % 3 === 0 ? one(['cloister', 'pyre', 'fen']) : one(allAreas), level: 1 + Math.floor(pick() * 400), waveTier: Math.floor(pick() * 10), difficulty: one(diffs),
          itemChanceMult: one([1, 1.15, 1.3]), runePity: one([1, 2, 3]), disciplineId: one(discs), characterLevel: 1 + Math.floor(pick() * 700), owned: owned() };
    const seeds = Object.fromEntries(EVENT_STREAMS[kind].map((n) => [n, seed()]));
    const streams = Object.fromEntries(Object.entries(seeds).map(([n, w]) => [n, dropStream(w as Words)]));
    cases.push({ kind: 'event', in: { kind, facts: f }, seeds, out: rollEvent(kind, f, streams) });
  }
  // Events from one tape seed each (what the server issues), sub-streams derived on both sides.
  for (let i = 0; i < 100; i++) {
    const kind = one(['kill', 'elite', 'boss', 'surge'] as const) as DropKind;
    const f = kind === 'boss' ? { boss: 'gravedigger', area: 'graves', costShards: 2, first: pick() < 0.5, level: 10, characterLevel: 20 }
      : { def: one(defs), area: one(lootAreas), level: 1 + Math.floor(pick() * 300), characterLevel: 1 + Math.floor(pick() * 300), disciplineId: one(discs) };
    const tape = seed();
    cases.push({ kind: 'tape_event', in: { kind, facts: f }, seeds: { tape }, out: rollEvent(kind, f, eventStreams(kind, tape)) });
  }
  // The Catacomb Depths: a floor clear and a fifth floor's chest.
  for (let i = 0; i < 160; i++) {
    const kind = (i % 2 ? 'floor' : 'chest') as DropKind;
    const depth = kind === 'chest' ? 5 * (1 + Math.floor(pick() * 8)) : 1 + Math.floor(pick() * 40);
    const f = { area: 'depths', depth, level: 12 + Math.floor(pick() * 300), characterLevel: 1 + Math.floor(pick() * 700), disciplineId: one(discs) };
    const tape = seed();
    cases.push({ kind: 'tape_event', in: { kind, facts: f }, seeds: { tape }, out: rollEvent(kind, f, eventStreams(kind, tape)) });
  }
  // The raw stream itself, so a stream bug shows as a stream bug.
  const raw = dropStream([0xdeadbeef, 0x12345678, 0x9abcdef0, 0x0badf00d]);
  return { stream: { seed: [0xdeadbeef, 0x12345678, 0x9abcdef0, 0x0badf00d], first: Array.from({ length: 16 }, () => raw()) }, cases };
}

describe('loot rules (server copy of DmLoot)', () => {
  it('the drop stream is sfc32: uniform-looking floats in [0, 1), the same for the same seed', () => {
    const a = dropStream([1, 2, 3, 4]);
    const b = dropStream([1, 2, 3, 4]);
    const xs = Array.from({ length: 1000 }, () => a());
    expect(xs.every((x) => x >= 0 && x < 1)).toBe(true);
    expect(Array.from({ length: 1000 }, () => b())).toEqual(xs);
    const mean = xs.reduce((s, x) => s + x, 0) / xs.length;
    expect(Math.abs(mean - 0.5)).toBeLessThan(0.05);
  });

  it('the parity fixture the Godot suite replays is current', () => {
    const now = buildCases();
    if (process.env.UPDATE_LOOT_PARITY) fs.writeFileSync(FIXTURE, `${JSON.stringify(now)}\n`);
    const committed = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'));
    expect(committed).toEqual(JSON.parse(JSON.stringify(now)));
  });

  it('the fixture exercises every drop path', () => {
    const { cases } = buildCases() as { cases: { kind: string; out: { items?: { item_id: string }[]; item_id?: string } | null }[] };
    const ids = cases.flatMap((c) => (c.out && 'items' in c.out ? c.out.items!.map((d) => d.item_id) : c.out && c.out.item_id ? [c.out.item_id] : []));
    expect(ids.some((id) => id.startsWith('leg_'))).toBe(true);
    expect(ids.some((id) => id.startsWith('rune_'))).toBe(true);
    expect(ids.some((id) => id.startsWith('reagent_'))).toBe(true);
    expect(cases.some((c) => c.kind === 'boss_rune' && c.out === null)).toBe(true);
  });
});
