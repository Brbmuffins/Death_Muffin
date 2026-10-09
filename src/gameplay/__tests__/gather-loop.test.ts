import { describe, expect, it, vi } from 'vitest';
import { GatherLoop, Skills, type GatherHooks } from '../Gathering';
import type { NodePlacement } from '../../content/layout';
import type { GatherReply } from '../../net/api';
import { GATHER_FLUSH_MS, NODES, actionMs } from '../../../server/rules/gameplay/gatheringRules';

const oakA: NodePlacement = { id: 'acre_1', type: 'coffin_oak', x: 0, z: 0, area: 'acre', rot: 0 };
const oakB: NodePlacement = { id: 'acre_2', type: 'coffin_oak', x: 6, z: 0, area: 'acre', rot: 0 };
const yew: NodePlacement = { id: 'acre_3', type: 'churchyard_yew', x: -6, z: 0, area: 'acre', rot: 0 };

function setup(over: Partial<GatherHooks> = {}) {
  let now = 0;
  const live = new Set(['acre_1', 'acre_2', 'acre_3']);
  const player = {
    x: 1.35,
    z: 0,
    path: [] as { x: number; z: number }[],
    get hasPath() {
      return this.path.length > 0;
    },
    moving: false,
    moveAlong(p: { x: number; z: number }[]) {
      this.path = p;
    },
    face: vi.fn(),
    stop() {
      this.path = [];
    },
  };
  const replies: GatherReply[] = [];
  const reply = (type: string, actions: number): GatherReply => ({
    node: type,
    skill: NODES[type].skill,
    accepted: actions,
    successes: actions,
    xp: actions * NODES[type].xp,
    gold: 0,
    items: [{ itemId: NODES[type].item, qty: actions }],
    rejected: [],
    leveledUp: false,
    skills: [{ profession_id: NODES[type].skill, skill_level: 3, skill_xp: 7 }],
  });
  const hooks: GatherHooks = {
    now: () => now,
    rand: () => 0, // every cycle succeeds
    nav: { blocked: () => false, findPath: (_fx, _fz, tx, tz) => [{ x: tx, z: tz }] },
    player,
    nodes: () => [oakA, oakB, yew].map((n) => ({ ...n, remaining: live.has(n.id) ? 1 : 0 })),
    live: (id) => live.has(id),
    bagFits: () => true,
    sendSuccess: vi.fn(),
    post: vi.fn(async (type: string, actions: number) => {
      const r = reply(type, actions);
      replies.push(r);
      return r;
    }),
    onCycle: vi.fn(),
    onReply: vi.fn(),
    onStop: vi.fn(),
    onError: vi.fn(),
    autoEnabled: () => true,
    ...over,
  };
  const skills = new Skills([{ profession_id: 'woodcutting', skill_level: 1, skill_xp: 0 }]);
  const loop = new GatherLoop(hooks, skills);
  const tick = (ms: number, step = 100) => {
    for (let t = 0; t < ms; t += step) {
      now += step;
      loop.update(step / 1000);
    }
  };
  return { loop, hooks, skills, player, live, tick, replies };
}

const settle = () => new Promise((r) => setTimeout(r, 0));

describe('the gathering loop', () => {
  it('refuses a node above the skill level with the server-style wording', () => {
    const { loop } = setup();
    expect(loop.start(yew)).toBe('Requires Woodcutting level 45');
    expect(loop.active).toBe(false);
  });

  it('works cycles, reports successes to the host and shows optimistic XP', () => {
    const { loop, hooks, skills, tick } = setup();
    expect(loop.start(oakA)).toBeNull();
    expect(loop.working).toBe(true);
    tick(actionMs(NODES.coffin_oak) * 3 + 50);
    expect(hooks.onCycle).toHaveBeenCalledTimes(3);
    expect(hooks.sendSuccess).toHaveBeenCalledWith('acre_1');
    expect(skills.shown('woodcutting').xp).toBe(18);
  });

  it('walks to the ring first when standing away from the node', () => {
    const { loop, player, tick } = setup();
    player.x = 10;
    loop.start(oakA);
    expect(loop.working).toBe(false);
    expect(player.path.length).toBe(1);
    player.x = player.path[0].x;
    player.z = player.path[0].z;
    player.path = [];
    tick(100);
    expect(loop.working).toBe(true);
  });

  it('stops working when the hero ends up away from the node (safety net)', () => {
    const { loop, hooks, player, tick } = setup();
    loop.startAfk(oakA);
    tick(300);
    expect(loop.working).toBe(true);
    player.x = 12; // moved by something that never called stop()
    tick(100);
    expect(loop.active).toBe(false);
    expect(loop.afk).toBe(false);
    expect(loop.status).toBe('Paused');
    expect(hooks.onStop).toHaveBeenCalledWith('moved', undefined);
    const cycles = (hooks.onCycle as ReturnType<typeof vi.fn>).mock.calls.length;
    tick(5000);
    expect((hooks.onCycle as ReturnType<typeof vi.fn>).mock.calls.length).toBe(cycles);
  });

  it('stops working when a path starts mid-work, but AFK node-hopping still walks', () => {
    const a = setup();
    a.loop.startAfk(oakA);
    a.tick(300);
    a.player.moveAlong([{ x: 9, z: 9 }]);
    a.tick(100);
    expect(a.loop.active).toBe(false);
    const b = setup();
    b.loop.startAfk(oakA);
    b.tick(100);
    b.live.delete('acre_1');
    b.tick(100);
    expect(b.loop.node?.id).toBe('acre_2');
    expect(b.loop.afk).toBe(true);
  });

  it('batches cycles to the server and adopts its answer (server wins)', async () => {
    const { loop, hooks, skills, tick } = setup();
    loop.start(oakA);
    tick(GATHER_FLUSH_MS + 100);
    await settle();
    expect(hooks.post).toHaveBeenCalledTimes(1);
    const [type, actions] = (hooks.post as ReturnType<typeof vi.fn>).mock.calls[0];
    expect(type).toBe('coffin_oak');
    expect(actions).toBe(Math.floor((GATHER_FLUSH_MS + 100) / actionMs(NODES.coffin_oak)));
    expect(hooks.onReply).toHaveBeenCalled();
    expect(skills.get('woodcutting')).toEqual({ level: 3, xp: 7 });
    expect(skills.shown('woodcutting').level).toBe(3);
  });

  it('shows a refusal verbatim and drops those cycles; keeps them on a network error', async () => {
    const refused = setup({ post: vi.fn(async () => Promise.reject(Object.assign(new Error('You are gathering faster than your hands allow. Slow down.'), { status: 400 }))) });
    refused.loop.start(oakA);
    refused.tick(GATHER_FLUSH_MS + 100);
    await settle();
    expect(refused.hooks.onError).toHaveBeenCalledWith('You are gathering faster than your hands allow. Slow down.');
    expect(refused.skills.shown('woodcutting').xp).toBe(0);

    let calls = 0;
    const offline = setup({
      post: vi.fn(async (type: string, actions: number) => {
        calls++;
        if (calls === 1) throw Object.assign(new Error('Cannot reach server'), { status: 0 });
        return { node: type, skill: 'woodcutting', accepted: actions, successes: actions, xp: 0, gold: 0, items: [], rejected: [], leveledUp: false, skills: [] } as GatherReply;
      }),
    });
    offline.loop.start(oakA);
    offline.tick(GATHER_FLUSH_MS + 100);
    await settle();
    expect(offline.hooks.onError).not.toHaveBeenCalled();
    offline.tick(10_500);
    await settle();
    expect(calls).toBe(2);
    const second = (offline.hooks.post as ReturnType<typeof vi.fn>).mock.calls[1][1];
    expect(second).toBeGreaterThan(Math.floor(GATHER_FLUSH_MS / actionMs(NODES.coffin_oak)));
  });

  it('stops when the bag is full', () => {
    let fits = true;
    const { loop, hooks, tick } = setup({ bagFits: () => fits });
    loop.start(oakA);
    tick(500);
    fits = false;
    tick(200);
    expect(loop.active).toBe(false);
    expect(hooks.onStop).toHaveBeenCalledWith('bagFull', undefined);
  });

  it('Auto walks to the nearest live node of the same kind when this one is spent', () => {
    const { loop, live, player, tick } = setup();
    loop.start(oakA);
    tick(300);
    live.delete('acre_1');
    tick(100);
    expect(loop.node?.id).toBe('acre_2');
    expect(player.path.length).toBe(1);
  });

  it('with nothing else live, waits at the spent node and resumes when it returns', () => {
    const { loop, live, tick } = setup();
    loop.start(oakA);
    live.delete('acre_1');
    live.delete('acre_2');
    tick(200);
    expect(loop.active).toBe(true);
    expect(loop.working).toBe(false);
    live.add('acre_1');
    tick(200);
    expect(loop.working).toBe(true);
  });

  it('without Auto, a spent node ends the loop', () => {
    const { loop, live, hooks, tick } = setup({ autoEnabled: () => false });
    loop.start(oakA);
    live.delete('acre_1');
    tick(200);
    expect(loop.active).toBe(false);
    expect(hooks.onStop).toHaveBeenCalledWith('blocked', 'The Coffin-Oak is spent.');
  });

  it('AFK cycles nodes even with Auto off and waits through respawns', () => {
    const { loop, live, tick, player } = setup({ autoEnabled: () => false });
    expect(loop.startAfk(oakA)).toBeNull();
    live.delete('acre_1');tick(200);
    expect(loop.afk).toBe(true);expect(loop.node?.id).toBe('acre_2');
    const spot=player.path[0];player.x=spot.x;player.z=spot.z;player.stop();tick(100);
    live.delete('acre_2');tick(100);
    expect(loop.status).toMatch(/Waiting for respawn/);
    live.add('acre_2');tick(100);
    expect(loop.working).toBe(true);
  });

  it('AFK ends at a full bag and manual movement cancels it', () => {
    let fits=true;
    const { loop, tick } = setup({ bagFits:()=>fits });
    loop.startAfk(oakA);fits=false;tick(100);
    expect(loop.afk).toBe(false);expect(loop.status).toMatch(/Bag full/);
    fits=true;loop.startAfk(oakA);loop.stop('moved');
    expect(loop.afk).toBe(false);expect(loop.active).toBe(false);
  });

  it('flush waits for an existing save, so switching AFK tasks cannot race it', async () => {
    let resolve!: (r: GatherReply)=>void;
    const { loop, tick }=setup({ post:()=>new Promise(r=>{resolve=r;}) });
    loop.startAfk(oakA);tick(actionMs(NODES.coffin_oak));
    const first=loop.flush();const next=loop.flush();
    expect(next).toBe(first);
    resolve({node:'coffin_oak',skill:'woodcutting',accepted:1,successes:0,xp:0,gold:0,items:[],rejected:[],leveledUp:false,skills:[]});
    await next;
  });
});
