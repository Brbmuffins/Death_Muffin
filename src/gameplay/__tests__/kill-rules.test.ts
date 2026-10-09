import { describe, expect, it } from 'vitest';
import { AREAS, type AreaId } from '../../../server/rules/content/areas';
import { ENEMIES, type EnemyId } from '../../../server/rules/content/enemies';
import { DIFFICULTY_ORDER } from '../../../server/rules/content/difficulty';
import { depthEnemyLevel, hasChest } from '../../../server/rules/content/depths';
import { KillReporter } from '../../net/killReporter';
import { runBalance } from '../balance/harness';
import { rollKill } from '../loot';
import { ELITE_SHARDS_MAX, KILLS, bucketCaps, evaluateKillReport, killGoldMax, killXpBase, parseKillReport, type KillContext, type KillGroup, type KillReport } from '../../../server/rules/gameplay/killRules';
import { mulberry32 } from '../rng';
import { bundleRulesFor } from '../../../tools/build-server-rules.mjs';
import { readFileSync } from 'node:fs';

/**
 * Server authority step 2 (docs/SERVER-AUTHORITY.md): the kill ledger's rules agree with the game's own reward roll, honest bot play
 * passes them whole, and the browser's reporter batches and retries correctly.
 */

describe('what a kill is worth matches loot.ts rollKill', () => {
  const defs = Object.keys(ENEMIES).filter((d) => !ENEMIES[d as EnemyId].inert) as EnemyId[];
  it('XP is exact and gold/shards are bounded by the best roll, for every enemy, level, tier, difficulty and elite flag', () => {
    const rand = mulberry32(7);
    for (const def of defs) {
      for (const level of [1, 12, 40, 150]) {
        for (const tier of [0, 4, 8]) {
          for (const diff of DIFFICULTY_ORDER) {
            for (const elite of [false, true]) {
              const r = rollKill(def, 'graves', level, elite, tier, rand, diff);
              expect(r.xp, `${def} L${level} t${tier} ${diff} elite=${elite}`).toBe(Math.round(killXpBase(def, level, elite, tier, diff)));
              expect(r.gold).toBeLessThanOrEqual(Math.round(killGoldMax(def, level, elite, tier, diff)));
              expect(r.shards).toBeLessThanOrEqual(elite ? ELITE_SHARDS_MAX : 0);
            }
          }
        }
      }
    }
  });
  it('the best gold roll is reached (the credit is a ceiling, not an over-estimate by a wide margin)', () => {
    const top = Math.max(...Array.from({ length: 4000 }, (_, i) => rollKill('hound', 'graves', 10, false, 0, mulberry32(i + 1), 'medium').gold));
    expect(top).toBeLessThanOrEqual(Math.round(killGoldMax('hound', 10, false, 0, 'medium')));
    expect(top).toBeGreaterThanOrEqual(Math.round(killGoldMax('hound', 10, false, 0, 'medium')) - 2);
  });
});

describe('parseKillReport', () => {
  it('drops junk and clamps numbers', () => {
    expect(parseKillReport(null)).toBeNull();
    expect(parseKillReport({ seq: 0 })).toBeNull();
    const r = parseKillReport({ seq: 3, groups: [{ area: 'graves', def: 'robber', level: 1, n: 5.9 }, { area: 'graves', def: 'robber', n: -1 }, 'x'] })!;
    expect(r.groups).toHaveLength(1);
    expect(r.groups[0].n).toBe(5);
    expect(r.groups[0].diff).toBe('medium');
  });
});

describe('honest play passes the ledger whole', () => {
  // The balance bot plays the real sim at the hardest settings an honest player can dial (Hard, Wave Speed 8). Its kills are fed to the
  // ledger in 45-second reports, the way a flush every 45 s would send them; nothing may be dropped and the credits must cover what the
  // bot was paid. If this fails after a content change, the ledger would be docking real players.
  const unlockedFor = (area: AreaId): string[] => {
    const out = ['chapterhouse', 'graves'];
    for (let a: AreaId | undefined = area; a && AREAS[a].unlock; a = AREAS[a].unlock!.area) out.push(a);
    return [...new Set([...out, 'warren'])];
  };
  const cases: { area: AreaId; classIndex: number; level: number; depth?: number; ascension?: number }[] = [
    { area: 'graves', classIndex: 2, level: 8 },
    { area: 'ossuary', classIndex: 2, level: 14 },
    { area: 'nave', classIndex: 3, level: 24 },
    { area: 'sanctum', classIndex: 2, level: 34 },
    { area: 'cloister', classIndex: 2, level: 45 },
    { area: 'fen', classIndex: 2, level: 60, ascension: 1 },
    { area: 'depths', classIndex: 2, level: 40, depth: 10 },
    { area: 'ossuary', classIndex: 6, level: 16 },
  ];
  for (const c of cases) {
    it(`${c.area}${c.depth ? ` depth ${c.depth}` : ''} (class ${c.classIndex}${c.ascension ? `, rank ${c.ascension}` : ''})`, () => {
      const kills: { t: number; def: string; area: string; level: number; elite: boolean }[] = [];
      const minutes = 3;
      const res = runBalance({ area: c.area, classIndex: c.classIndex, level: c.level, damageTier: Math.round(c.level * 0.6), gearStats: Math.round(c.level * 0.8), waveTier: 8, minutes, seed: 42, difficulty: 'hard', depth: c.depth, ascension: c.ascension, kit: 'ascended', onKill: (k) => kills.push(k) });
      expect(kills.length).toBeGreaterThan(50);
      const unlocked = unlockedFor(c.area);
      const caps = bucketCaps(unlocked);
      let bucket = caps.killPerMin * KILLS.FIRST_MINUTES;
      let accepted = 0;
      let xp = 0;
      let gold = 0;
      let shards = 0;
      const dropped: unknown[] = [];
      let last = 0;
      let floorsReported = 0;
      for (let from = 0, seq = 1; from < minutes * 60; from += 45, seq++) {
        const batch = kills.filter((k) => k.t >= from && k.t < from + 45);
        const groups = new Map<string, KillGroup>();
        for (const k of batch) {
          const key = `${k.def}|${k.level}|${k.elite}`;
          const g = groups.get(key) ?? { area: k.area, def: k.def, level: k.level, elite: k.elite, tier: 8, diff: 'hard', rank: c.ascension ?? 0, xpMult: 1, goldMult: 1, shardMult: 1, n: 0 };
          g.n++;
          groups.set(key, g);
        }
        bucket = Math.min(caps.killCap, bucket + caps.killPerMin * ((from - last) / 60));
        last = from;
        const ctx: KillContext = { unlocked, ascension: c.ascension ?? 0, heroLevel: c.level, deepest: c.depth ?? 0, killBucket: bucket, bossBucket: 5, floorBucket: 20, maxCleared: c.depth ?? 0, staff: false };
        // The bot clears floors and opens chests as it goes (a held depth re-rolls the same floor): report them in the batches, evenly.
        const floorsHere = c.depth ? Math.round(((res.floorsPerMin * minutes) / Math.ceil((minutes * 60) / 45)) * 1) : 0;
        const floors = Array.from({ length: floorsHere }, () => ({ depth: c.depth!, level: depthEnemyLevel(c.depth!, c.level), clear: true, chest: hasChest(c.depth!), mult: 1 }));
        floorsReported += floorsHere;
        const report: KillReport = { seq, groups: [...groups.values()], bosses: [], floors };
        const ev = evaluateKillReport(report, ctx);
        accepted += ev.killsAccepted;
        bucket -= ev.killsAccepted;
        xp += ev.credits.xp;
        gold += ev.credits.gold;
        shards += ev.credits.shards;
        dropped.push(...ev.findings);
      }
      expect(dropped, JSON.stringify(dropped)).toEqual([]);
      if (c.depth) expect(floorsReported).toBeGreaterThan(0);
      expect(accepted).toBe(kills.length);
      // The bot's own totals (the sim paid them with the same rollKill the client uses). The credit must cover them.
      expect(xp).toBeGreaterThanOrEqual(Math.floor(res.xpPerMin * minutes * 0.97));
      expect(gold).toBeGreaterThanOrEqual(Math.floor(res.goldPerMin * minutes * 0.97));
      expect(shards).toBeGreaterThanOrEqual(Math.floor((res.shardsPerHour / 60) * minutes));
    }, 60_000);
  }
});

describe('the reporter', () => {
  const k = (over: Partial<Omit<KillGroup, 'n'>> = {}) => ({ area: 'graves', def: 'robber', level: 1, elite: false, tier: 0, diff: 'medium', rank: 0, xpMult: 1, goldMult: 1, shardMult: 1, ...over });

  it('groups identical kills, rounds multipliers and seals numbered batches that stay until acknowledged', () => {
    let clock = 1000;
    const rep = new KillReporter(() => clock);
    for (let i = 0; i < 30; i++) rep.kill(k({ xpMult: 1.2 + i * 0.0001 }));
    rep.kill(k({ elite: true }));
    const [first] = rep.batches();
    expect(first.seq).toBe(1000);
    expect(first.groups.map((g) => g.n).sort()).toEqual([1, 30]);
    // Nothing new: the same sealed batch comes back with the same sequence number (a retry after a lost reply is a repeat).
    expect(rep.batches()).toEqual([first]);
    clock = 1000; // clock did not advance: sequence numbers still strictly increase
    rep.kill(k());
    const two = rep.batches();
    expect(two.map((b) => b.seq)).toEqual([1000, 1001]);
    rep.ack(1000);
    expect(rep.batches().map((b) => b.seq)).toEqual([1001]);
    rep.ack(1001);
    expect(rep.hasPending).toBe(false);
    expect(rep.batches()).toEqual([]);
  });

  it('keeps a bounded pile when the server never answers', () => {
    let clock = 1;
    const rep = new KillReporter(() => clock++);
    for (let i = 0; i < 10; i++) { rep.kill(k({ level: i + 1 })); rep.batches(); }
    expect(rep.batches()).toHaveLength(4);
  });

  it('reports bosses and floors, and discard() forgets everything for an older server', () => {
    const rep = new KillReporter(() => 5);
    rep.boss({ boss: 'prelate', tier: 3, diff: 'hard', first: false });
    rep.boss({ boss: 'prelate', tier: 3, diff: 'hard', first: false });
    rep.floor({ depth: 4, level: 50, clear: true, chest: false, mult: 1.0501 });
    const [b] = rep.batches();
    expect(b.bosses[0].n).toBe(2);
    expect(b.floors[0].mult).toBe(1.05);
    rep.discard();
    expect(rep.hasPending).toBe(false);
  });

  it('every report it produces is something the server parses back unchanged', () => {
    const rep = new KillReporter(() => 9);
    rep.kill(k());
    rep.kill(k({ elite: true, def: 'hound', level: 4 }));
    const [b] = rep.batches();
    expect(parseKillReport(JSON.parse(JSON.stringify(b)))).toEqual(b);
  });
});

describe('the generated server rules', () => {
  it('gathering/kill-rules.cjs is fresh (run `npm run build:server-rules`)', async () => {
    const { out, text } = await bundleRulesFor('kills');
    expect(readFileSync(out, 'utf8') === text, 'kill-rules.cjs is stale').toBe(true);
  });
});
