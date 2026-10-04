/**
 * Golden fixtures for godot/rules/dialogue (run: npx vite-node tools/godot/fixtures-dialogue.ts): guidance selectors, news, memory and every
 * line the Prior / Sexton / Apothecary can say, from the REAL gameplay/guidance.ts + content/dialogue.ts.
 * Output: godot/tests/dialogue/fixtures/*.json, each {fn, cases:[{in, out}]}.
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { mulberry32 } from '../../src/gameplay/rng';
import { AREAS, AREA_ORDER } from '../../src/content/areas';
import { BOSS_IDS } from '../../src/content/bosses';
import { NPC_IDS } from '../../src/content/npcs';
import { Guidance, baseState, newsFor, nextSuggestion, suggestionFor, suggestions, summarizeContracts, summarizeLabor, pendingSeals, bossesWaiting, readTrophies, type GuidanceState } from '../../src/gameplay/guidance';
import { TOPICS, adviceLines, farewell, greetingLines, topicLines } from '../../src/content/dialogue';

const OUT = 'godot/tests/dialogue/fixtures';
mkdirSync(OUT, { recursive: true });
const counts: Record<string, number> = {};
const w = (fn: string, cases: { in: unknown; out: unknown }[]) => { writeFileSync(`${OUT}/${fn}.json`, JSON.stringify({ fn, cases }) + '\n'); counts[fn] = cases.length; };
const rand = mulberry32(777001);
const R = (n: number) => Math.floor(rand() * n);
const pick = <T>(a: readonly T[]): T => a[R(a.length)];
const chance = (p: number) => rand() < p;
const range = (lo: number, hi: number) => lo + R(hi - lo + 1);
const J = <T>(x: T): T => JSON.parse(JSON.stringify(x));

function randomState(): GuidanceState {
  // open halls follow the road, mostly
  const depth = R(AREA_ORDER.length + 1);
  const unlocked = AREA_ORDER.filter((a, i) => AREAS[a].unlock && (i < depth ? chance(0.9) : chance(0.1)));
  const areaKills: Record<string, number> = {};
  for (const a of AREA_ORDER) if (chance(0.6)) areaKills[a] = range(0, 800);
  const skills: Record<string, number> = {};
  for (const k of ['woodcutting', 'mining', 'fishing', 'gravedigging', 'alchemy']) if (chance(0.5)) skills[k] = range(1, 14);
  return baseState({
    level: range(1, 60), area: pick(AREA_ORDER), ascension: chance(0.6) ? 0 : range(1, 6), canAscend: chance(0.2), ashesOnAscend: range(0, 120000),
    shards: range(0, 12), unlocked, areaKills, unlockMult: pick([1, 1, 0.8, 0.5, 0.75]),
    bossesBeaten: BOSS_IDS.filter(() => chance(0.4)), prelateThisRun: chance(0.3), totalKills: chance(0.2) ? range(0, 12) : range(0, 9000),
    skills, bagUsed: range(0, 48), bagSize: chance(0.05) ? 0 : 48, dust: range(0, 9),
    labor: chance(0.6) ? { unlocked: range(0, 4), assigned: range(0, 4), ready: range(0, 3) } : null,
    contracts: chance(0.6) ? { open: range(0, 3), total: 3 } : null,
  });
}

// suggestions / next / seals / waiting
const sg: { in: unknown; out: unknown }[] = [];
for (let i = 0; i < 400; i++) {
  const s = randomState();
  const dismissed = chance(0.3) ? (suggestions(s)[0]?.id ?? null) : null;
  sg.push({ in: { s: J(s), dismissed }, out: J({
    suggestions: suggestions(s), next: nextSuggestion(s, dismissed), seals: pendingSeals(s), waiting: bossesWaiting(s),
    forNpc: Object.fromEntries(NPC_IDS.map((n) => [n, suggestionFor(n, s) ?? null])),
    news: Object.fromEntries(NPC_IDS.map((n) => [n, newsFor(n, s)])),
  }) });
}
w('guidance', sg);

// every line, with a Guidance memory carried through a short conversation history
const stor = () => { const m = new Map<string, string>(); return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v) }; };
const talk: { in: unknown; out: unknown }[] = [];
for (let i = 0; i < 250; i++) {
  const g = new Guidance(1, stor());
  const steps: unknown[] = [];
  for (let step = 0; step < 4; step++) {
    const s = randomState();
    const npc = pick(NPC_IDS);
    const unheard = g.unheard(npc, s);
    const met = g.met(npc);
    const newOverhead = Object.fromEntries(NPC_IDS.map((n) => [n, g.hasSomethingNew(n, s)]));
    const greet = greetingLines(npc, s, unheard, met);
    g.told(npc, s);
    const topics = Object.fromEntries(TOPICS[npc].map((t) => [t.id, topicLines(npc, t.id, s)]));
    const heardBefore = TOPICS[npc].map((t) => g.heardTopic(npc, t.id));
    const hear = pick(TOPICS[npc]);
    g.hearTopic(npc, hear.id);
    steps.push({ s: J(s), npc, hear: hear.id, out: J({ unheard, met, newOverhead, greet, advice: adviceLines(npc, s), topics, farewell: farewell(npc, s), heardBefore, heardAfter: TOPICS[npc].map((t) => g.heardTopic(npc, t.id)), mem: g.mem, first: g.firstSight(npc), first2: g.firstSight(npc), metAfter: g.met(npc) }) });
  }
  talk.push({ in: { steps: steps.map((x: any) => ({ s: x.s, npc: x.npc, hear: x.hear })) }, out: steps.map((x: any) => x.out) });
}
w('talk', talk);

// all three NPCs' advice and topics for a fixed spread of states (every suggestion kind), plus summaries and trophies
const adv: { in: unknown; out: unknown }[] = [];
for (let i = 0; i < 300; i++) { const s = randomState(); adv.push({ in: J(s), out: J(Object.fromEntries(NPC_IDS.map((n) => [n, { advice: adviceLines(n, s), farewell: farewell(n, s) }]))) }); }
w('advice', adv);
const sum = [
  { in: { labor: { slots: [{ unlocked: true, nodeType: 'tree', capped: true, elapsedMs: 5 }, { unlocked: true, nodeType: 'tree', capped: false, elapsedMs: 1800000 }, { unlocked: true, nodeType: null, capped: false, elapsedMs: 0 }, { unlocked: false, nodeType: 'x', capped: true, elapsedMs: 9e9 }] }, contracts: { contracts: [{ done: true }, { done: false }, { done: false }] } },
    out: J({ labor: summarizeLabor({ slots: [{ unlocked: true, nodeType: 'tree', capped: true, elapsedMs: 5 }, { unlocked: true, nodeType: 'tree', capped: false, elapsedMs: 1800000 }, { unlocked: true, nodeType: null, capped: false, elapsedMs: 0 }, { unlocked: false, nodeType: 'x', capped: true, elapsedMs: 9e9 }] } as never), contracts: summarizeContracts({ contracts: [{ done: true }, { done: false }, { done: false }] } as never) }) },
];
w('summaries', sum);
const tr = ['["gravedigger","abbess"]', '["gravedigger","nope",3]', 'bad json', '{"a":1}', ''].map((raw) => ({ in: raw, out: readTrophies({ getItem: () => raw, setItem: () => {} }, 7) }));
w('trophies', tr);
console.log(counts);
