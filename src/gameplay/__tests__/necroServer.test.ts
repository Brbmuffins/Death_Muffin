import { readFileSync } from 'node:fs';
import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import * as rules from '../necroRules';
import type { NecroState } from '../necroRules';

// --- A fake auth server running the shared rules (what the VPS will run). ---
const server: { state: NecroState | null; gold: number; up: boolean; calls: string[] } = { state: null, gold: 0, up: true, calls: [] };

vi.mock('../../net/api', () => {
  class ApiError extends Error {
    constructor(message: string, public status: number) {
      super(message);
    }
  }
  const reply = (r: rules.RuleResult<{ gold?: number }>) => {
    if (!r.ok) throw new ApiError(r.error, 400);
    server.state = r.state;
    if (r.gold !== undefined) server.gold = r.gold;
    return { progress: r.state, gold: server.gold };
  };
  const st = () => rules.normalise(server.state ?? rules.blankState());
  const guard = (name: string) => {
    server.calls.push(name);
    if (!server.up) throw new ApiError('Offline backend: no route', 404);
  };
  return {
    ApiError,
    saveProgress: vi.fn(async (p: { gold: number }) => {
      server.calls.push('save-progress');
      server.gold = p.gold;
      return { success: true };
    }),
    necroApi: {
      get: async () => (guard('get'), { progress: st(), gold: server.gold }),
      importLocal: async (_id: number, rec: object) => (guard('import'), reply(rules.importLocal(st(), rec))),
      save: async (_id: number, input: rules.SaveInput) => (guard('save'), reply(rules.applySave(st(), input))),
      purchase: async (_id: number, u: 'damage' | 'wave') => (guard('purchase'), reply(rules.purchase(st(), server.gold, u))),
      summonPrelate: async () => (guard('summon'), reply(rules.summonPrelate(st()))),
      ascend: async () => (guard('ascend'), reply(rules.ascend(st()))),
      boon: async (_id: number, b: string) => (guard('boon'), reply(rules.buyBoon(st(), b as never))),
    },
  };
});

beforeAll(() => {
  (globalThis as unknown as { window: unknown }).window = { setTimeout: () => 0, clearTimeout: () => undefined };
});
beforeEach(() => {
  server.state = null;
  server.gold = 0;
  server.up = true;
  server.calls = [];
});

const settle = () => new Promise((r) => setTimeout(r, 0));

async function progression(gold = 1000) {
  const { Progression } = await import('../progression');
  return new Progression({ id: 7, class_index: 1, class_name: '', level: 12, experience: 0, gold, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 5 });
}

describe('server rules bundle', () => {
  it('server/vps-handoff/necro-progress/necro-rules.cjs is generated from the current rules', async () => {
    const { bundleRules, OUT } = await import('../../../tools/build-server-rules.mjs');
    // Compare content, not line endings: a Windows checkout (core.autocrlf) holds CRLF.
    const lf = (s: string) => s.replace(/\r\n/g, '\n');
    expect(lf(readFileSync(OUT, 'utf8')), 'run `npm run build:server-rules`').toBe(lf(await bundleRules()));
  });
});

describe('Progression server mode', () => {
  it('falls back to browser storage when the routes are missing', async () => {
    server.up = false;
    const p = await progression();
    expect(await p.connect()).toBe('local');
    expect(p.buyDamage()).toBe(true);
    expect(server.calls).not.toContain('purchase');
  });

  it('imports the browser save once, then the server wins', async () => {
    const p = await progression();
    p.local.areaKills = { graves: 320 };
    p.local.totalKills = 320;
    p.local.damageTier = 4;
    p.recordKill('graves'); // gathered before connect: must not double count
    expect(await p.connect()).toBe('server');
    expect(server.calls).toEqual(['get', 'import']);
    expect(p.local.areaKills.graves).toBe(321);
    expect(p.local.unlocked).toContain('ossuary');
    expect(p.local.serverBacked).toBe(true);
    // A second session never imports again.
    const q = await progression();
    q.local.damageTier = 25; // an edited browser cache is ignored
    await q.connect();
    expect(server.calls.filter((c) => c === 'import').length).toBe(1);
    expect(q.local.damageTier).toBe(4);
  });

  it('kills and shards travel as deltas on the regular save', async () => {
    const p = await progression();
    await p.connect();
    for (let i = 0; i < 12; i++) p.recordKill('graves', 0);
    p.addShards(2);
    await p.flush();
    expect(server.state!.areaKills.graves).toBe(12);
    expect(server.state!.soulShards).toBe(2);
    expect(p.local.areaKills.graves).toBe(12);
  });

  it('purchases sync gold first, then the server prices the tier', async () => {
    const p = await progression(500);
    await p.connect();
    expect(p.buyDamage()).toBe(true);
    expect(p.character.gold).toBe(460);
    await settle();
    await settle();
    expect(server.calls).toContain('save-progress');
    expect(server.state!.damageTier).toBe(1);
    expect(server.gold).toBe(460);
    expect(p.local.damageTier).toBe(1);
  });

  it('saves the selected active wave tier without another kill or gold change', async () => {
    const p = await progression(500);
    await p.connect();
    expect(p.buyWave()).toBe(true);
    await settle();
    await settle();
    await p.flush();
    expect(server.state!.waveTierActive).toBe(1);

    p.setActiveWaveTier(0);
    expect(p.state).toBe('dirty');
    await p.flush();
    expect(server.state!.waveTierActive).toBe(0);
  });

  it('summon, Prelate kill and Ascension go through the server rules', async () => {
    const p = await progression();
    p.local.areaKills = { graves: 300, ossuary: 420, nave: 520 };
    p.local.shards = 5;
    await p.connect();
    expect(p.local.unlocked).toContain('sanctum');
    expect(p.spendShards(5)).toBe(true);
    await settle();
    await settle();
    expect(server.state!.summonsPending).toBe(1);
    p.recordPrelateKill(); // urgent: its own save is already out, so flush() below returns at once
    await p.flush();
    await settle();
    await settle();
    expect(server.state!.run.prelateKills).toBe(1);
    expect(p.ascend()).toBeGreaterThan(0);
    await settle();
    expect(server.state!.ascension).toBe(1);
    expect(p.local.ascension).toBe(1);
    expect(p.local.unlocked).toEqual(['chapterhouse', 'graves']);
  });
});
