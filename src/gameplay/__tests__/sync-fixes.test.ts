import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import * as rules from '../necroRules';
import { Progression } from '../progression';
import { necroApi, saveProgress } from '../../net/api';
import type { Character } from '../../net/types';

// A fake server that applies each request when it ARRIVES (in issue order) but lets the test choose the order replies come back in.
const srv: { state: rules.NecroState; gates: Array<() => void>; order: string[] } = { state: rules.blankState(), gates: [], order: [] };

vi.mock('../../net/api', () => {
  class ApiError extends Error {
    constructor(message: string, public status: number) {
      super(message);
    }
  }
  return {
    ApiError,
    saveProgress: vi.fn(),
    saveInventory: vi.fn(),
    necroApi: { get: vi.fn(), importLocal: vi.fn(), save: vi.fn(), purchase: vi.fn(), boon: vi.fn(), summonPrelate: vi.fn(), summonBoss: vi.fn(), ascend: vi.fn() },
  };
});

const character = (): Character => ({ id: 9, class_index: 2, class_name: 'Shadowblade', level: 12, experience: 0, gold: 100, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 5 });
const settle = () => new Promise((r) => setTimeout(r, 0));

/** Apply on arrival, answer when the test releases the gate. */
function gated(name: string, apply: () => rules.RuleResult) {
  srv.order.push(name);
  const r = apply();
  if (!r.ok) throw new Error(r.error);
  srv.state = r.state;
  const snapshot = rules.normalise(r.state);
  return new Promise<{ progress: rules.NecroState }>((resolve) => srv.gates.push(() => resolve({ progress: snapshot })));
}

/** Release every held reply, newest first, until none are left. */
async function releaseNewestFirst() {
  for (let guard = 0; guard < 50; guard++) {
    await settle();
    const g = srv.gates.pop();
    if (!g) return;
    g();
  }
}

async function serverProgression() {
  srv.state = rules.blankState();
  srv.state.migrated = true;
  srv.state.ashes = 100;
  srv.gates = [];
  srv.order = [];
  vi.mocked(necroApi.get).mockImplementation(async () => ({ progress: rules.normalise(srv.state) }) as never);
  vi.mocked(necroApi.save).mockImplementation(((_id: number, input: rules.SaveInput) => gated('save', () => rules.applySave(srv.state, input))) as never);
  vi.mocked(necroApi.boon).mockImplementation(((_id: number, b: string) => gated('boon', () => rules.buyBoon(srv.state, b as never))) as never);
  const p = new Progression(character());
  expect(await p.connect()).toBe('server');
  return p;
}

describe('sync fixes: progression', () => {
  beforeEach(() => {
    vi.stubGlobal('window', { setTimeout, clearTimeout });
    vi.stubGlobal('localStorage', { getItem: () => null, setItem: () => undefined });
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    vi.mocked(saveProgress).mockReset().mockResolvedValue({ success: true } as never);
  });
  afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks(); });

  it('a late reply from an older request never rolls back kills a newer save already landed', async () => {
    const p = await serverProgression();
    try {
      expect(p.buyBoon('vigil')).toBe(true); // reply computed before any kill reached the server
      for (let i = 0; i < 10; i++) p.recordKill('graves');
      const flushing = p.flush();
      await releaseNewestFirst(); // the save's reply comes back first, the boon's reply last
      await flushing;
      await releaseNewestFirst();
      await settle();
      expect(srv.state.areaKills.graves).toBe(10);
      expect(p.local.areaKills.graves).toBe(10);
      expect(p.local.boons.vigil).toBe(1);
      p.dispose();
    } finally { p.dispose(); }
  });

  it('a reply that lands while a kill save is in flight keeps those kills', async () => {
    const p = await serverProgression();
    for (let i = 0; i < 7; i++) p.recordKill('graves');
    const flushing = p.flush(); // saveProgress, then the necro save goes out holding the 7 kills
    await settle();
    expect(necroApi.save).toHaveBeenCalledTimes(1);
    p.buyBoon('vigil');
    await releaseNewestFirst();
    await flushing;
    await releaseNewestFirst();
    await settle();
    expect(p.local.areaKills.graves).toBe(7);
    expect(p.local.boons.vigil).toBe(1);
    p.dispose();
  });

  it('the final keepalive flush on page close still sends gains made while a save was in flight', async () => {
    const p = await serverProgression();
    let release!: () => void;
    vi.mocked(saveProgress).mockImplementationOnce(() => new Promise((resolve) => { release = () => resolve({ success: true } as never); }));
    p.addGold(5);
    const first = p.flush(); // in flight, carrying 5 gold
    await settle();
    p.addGold(40);
    p.recordKill('graves');
    const closing = p.flush(true); // pagehide
    await settle();
    const calls = vi.mocked(saveProgress).mock.calls;
    expect(calls).toHaveLength(2);
    expect(calls[1][0]).toMatchObject({ gold: 145 });
    expect(calls[1][1]).toBe(true);
    expect(necroApi.save).toHaveBeenCalledWith(9, expect.objectContaining({ areaKills: { graves: 1 } }), true);
    release();
    await releaseNewestFirst();
    await Promise.all([first, closing]);
    p.dispose();
  });
});

describe('sync fixes: gathering', () => {
  it('a keepalive flush on page close sends cycles queued while a batch was in flight', async () => {
    const { GatherLoop, Skills } = await import('../Gathering');
    const { NODES, actionMs } = await import('../gatheringRules');
    let now = 0;
    const node = { id: 'acre_1', type: 'coffin_oak', x: 0, z: 0, area: 'acre', rot: 0 } as never;
    const player = { x: 1.35, z: 0, path: [] as unknown[], get hasPath() { return false; }, moving: false, moveAlong() {}, face() {}, stop() {} };
    const releases: Array<() => void> = [];
    const post = vi.fn((type: string, actions: number) => new Promise((resolve) => {
      releases.push(() => resolve({ node: type, skill: NODES[type].skill, accepted: actions, successes: actions, xp: 0, gold: 0, items: [], rejected: [], leveledUp: false, skills: [] }));
    }));
    const loop = new GatherLoop({
      now: () => now, rand: () => 0, nav: { blocked: () => false, findPath: () => [] }, player,
      nodes: () => [{ ...(node as object), remaining: 1 }] as never, live: () => true, bagFits: () => true, sendSuccess: vi.fn(),
      post: post as never, onCycle: vi.fn(), onReply: vi.fn(), onStop: vi.fn(), onError: vi.fn(), autoEnabled: () => true,
    }, new Skills([{ profession_id: 'woodcutting', skill_level: 1, skill_xp: 0 }]));
    const tick = (ms: number) => { for (let t = 0; t < ms; t += 100) { now += 100; loop.update(0.1); } };
    loop.start(node);
    tick(actionMs(NODES.coffin_oak) * 2 + 50);
    const first = loop.flush(); // two cycles out
    await settle();
    tick(actionMs(NODES.coffin_oak) * 3); // three more queue up behind it
    const closing = loop.flush(true); // pagehide
    await settle();
    expect(post).toHaveBeenCalledTimes(2);
    expect(post.mock.calls[1][1]).toBe(3);
    expect(post.mock.calls[1][2]).toBe(true);
    releases.forEach((r) => r());
    await Promise.all([first, closing]);
  });
});
