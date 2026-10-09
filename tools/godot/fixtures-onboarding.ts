/**
 * Death Muffin -> Godot golden fixtures for Covenant counsel (godot/ui/onboarding/).
 * Imports the REAL src/ui/Onboarding.ts + counselCadence.ts and writes:
 *   godot/data/onboarding/tips.json                  every tip (title/body/kind/group/priority/here/anchor) + cadence constants
 *   godot/tests/onboarding/fixtures/render.json      renderText() cases (key markup, {p:X}, {auto}, [[desktop||touch]])
 *   godot/tests/onboarding/fixtures/cadence.json     canShow / pickNext / prune / shouldPreempt / shouldYield / showMs cases
 *   godot/tests/onboarding/fixtures/sequences.json   scripted event sequences run through the REAL Onboarding class (fake DOM + fake timers),
 *                                                    with the exact show/hide/glow log and state snapshots to match
 *   godot/tests/onboarding/fixtures/callsites.json   every onboarding.show()/host.tip() call in WorldScene.ts + DepthsController.ts
 * Run: npx vite-node tools/godot/fixtures-onboarding.ts
 */
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// ---- environment stubs (before importing game modules) ----
const store = new Map<string, string>();
const ls = { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => void store.set(k, String(v)), removeItem: (k: string) => void store.delete(k) };
(globalThis as any).localStorage = ls;
(globalThis as any).sessionStorage = ls;

// fake clock + timers: the Onboarding class only ever uses window.setTimeout and the injected clock
let NOW = 0;
let timerSeq = 0;
const timers = new Map<number, { due: number; fn: () => void }>();
function advanceTo(t: number): void {
  for (;;) {
    let best: [number, { due: number; fn: () => void }] | null = null;
    for (const e of timers) if (e[1].due <= t && (!best || e[1].due < best[1].due || (e[1].due === best[1].due && e[0] < best[0]))) best = e;
    if (!best) break;
    timers.delete(best[0]);
    NOW = Math.max(NOW, best[1].due);
    best[1].fn();
  }
  NOW = Math.max(NOW, t);
}
const win: any = {
  innerWidth: 1280, innerHeight: 800,
  addEventListener: () => undefined, removeEventListener: () => undefined,
  setTimeout: (fn: () => void, ms: number) => { const id = ++timerSeq; timers.set(id, { due: NOW + Math.max(0, ms || 0), fn }); return id; },
  clearTimeout: (id: number) => void timers.delete(id),
  location: { search: '' }, matchMedia: () => ({ matches: false }),
};
(globalThis as any).window = win;
try { (performance as any).now = () => NOW; } catch { Object.defineProperty(globalThis, 'performance', { value: { now: () => NOW }, configurable: true }); }

class FakeEl {
  dataset: Record<string, string> = {};
  style: any = { vars: {} as Record<string, string>, setProperty(k: string, v: string) { this.vars[k] = v; } };
  className = '';
  innerHTML = '';
  listeners: Record<string, Array<(e: any) => void>> = {};
  kids: Record<string, FakeEl> = {};
  classList = { add: () => undefined, remove: () => undefined };
  setAttribute() { /* noop */ }
  appendChild(c: FakeEl) { this.onAppend?.(c); return c; }
  onAppend?: (c: FakeEl) => void;
  remove() { /* noop */ }
  matches() { return false; }
  focus() { /* noop */ }
  hasPointerCapture() { return false; }
  getBoundingClientRect() { return { left: 0, top: 0, width: 360, height: 120, bottom: 120 }; }
  querySelector(sel: string) { return (this.kids[sel] ??= new FakeEl()); }
  querySelectorAll() { return []; }
  addEventListener(t: string, f: (e: any) => void) { (this.listeners[t] ??= []).push(f); }
  fire(t: string, e: any = {}) { for (const f of this.listeners[t] ?? []) f(e); }
}
(globalThis as any).document = { createElement: () => new FakeEl(), querySelector: () => null };
console.warn = () => undefined;

const O = await import('../../src/ui/Onboarding');
const C = await import('../../src/ui/counselCadence');
const S = await import('../../src/app/settings');
const { BOSS_SUMMON_SHARDS } = await import('../../server/rules/content/areas');
const { SIGNATURE_LEVEL } = await import('../../src/content/abilities');
const { BAG_SIZE } = await import('../../src/gameplay/loot');
const { TIPS, TIP_ANCHOR, Onboarding, renderText } = O;

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const DATA = resolve(ROOT, 'godot/data/onboarding');
const FIX = resolve(ROOT, 'godot/tests/onboarding/fixtures');
mkdirSync(DATA, { recursive: true });
mkdirSync(FIX, { recursive: true });
const wr = (p: string, o: unknown) => writeFileSync(p, JSON.stringify(o) + '\n');
const ids = Object.keys(TIPS) as (keyof typeof TIPS)[];

// ---- source-text mirrors of module-private constants (verified, so drift fails the export) ----
const onbSrc = readFileSync(resolve(ROOT, 'src/ui/Onboarding.ts'), 'utf8');
const num = (re: RegExp) => { const m = re.exec(onbSrc); if (!m) throw new Error(`Onboarding.ts changed: ${re}`); return Number(m[1].replace(/_/g, '')); };
const PUMP_MS = num(/const PUMP_MS = ([\d_]+);/);
const DEFAULT_X = num(/const DEFAULT_X = (\d+);/);
const DEFAULT_Y = num(/const DEFAULT_Y = (\d+);/);
const START_GAP = num(/this\.lastClosedAt = this\.clock\(\) - ([\d_]+);/);
if (!/const ALSO_SEEN: Partial<Record<TipId, TipId\[\]>> = \{ welcome: \['acre'\] \};/.test(onbSrc)) throw new Error('ALSO_SEEN changed');
if (!onbSrc.includes('const tipsKey = (characterId: number) => `dm_tips_v1_${characterId}`;') || !onbSrc.includes("const POSITION_KEY = 'dm_counsel_position_v1';")) throw new Error('storage keys changed');
const ALSO_SEEN = { welcome: ['acre'] };

// ---- tips.json ----
const tips: Record<string, unknown> = {};
for (const id of ids) {
  tips[id] = {
    title: TIPS[id].title, body: TIPS[id].body,
    kind: C.kindOf(id), group: C.groupOf(id), priority: C.priorityOf(id), here: C.HERE[id] ?? null, anchor: (TIP_ANCHOR as Record<string, string>)[id] ?? null,
  };
}
const wsSrc = readFileSync(resolve(ROOT, 'src/scenes/WorldScene.ts'), 'utf8');
const objLit = (name: string) => {
  const m = new RegExp(`const ${name}: [^=]+= \\{([\\s\\S]*?)\\n\\};`).exec(wsSrc);
  if (!m) throw new Error(`WorldScene.ts changed: ${name}`);
  const out: Record<string, string> = {};
  for (const l of m[1].matchAll(/(\w+): '(\w+)'/g)) out[l[1]] = l[2];
  return out;
};
const riteTips = objLit('RITE_TIPS');
const firstSight = objLit('FIRST_SIGHT_TIPS');
for (const t of [...Object.values(riteTips), ...Object.values(firstSight)]) if (!(t in TIPS)) throw new Error(`unknown tip ${t}`);
wr(resolve(DATA, 'tips.json'), {
  order: ids, tips, anchors: TIP_ANCHOR, rite_tips: riteTips, first_sight_tips: firstSight, also_seen: ALSO_SEEN,
  constants: {
    GAP_MS: C.GAP_MS, GROUP_GAP_MS: C.GROUP_GAP_MS, ENEMY_GAP_MS: C.ENEMY_GAP_MS, MAX_AGE_MS: C.MAX_AGE_MS, LESSON_AGE_MS: C.LESSON_AGE_MS,
    MAX_CALM_QUEUED: C.MAX_CALM_QUEUED, STARVED_MS: C.STARVED_MS, YIELD_AFTER_MS: C.YIELD_AFTER_MS, PREEMPT_AFTER_MS: C.PREEMPT_AFTER_MS,
    PUMP_MS, DEFAULT_X, DEFAULT_Y, START_GAP_MS: START_GAP, HERE: C.HERE,
    GROUP_GAPS: { enemy: C.ENEMY_GAP_MS, lesson: C.ENEMY_GAP_MS },
    BOSS_SUMMON_SHARDS, SIGNATURE_LEVEL, BAG_SIZE,
    LESSONS: ['move', 'exhume', 'litany', 'burst', 'souls'],
  },
});

// ---- render.json ----
const keyFor = (a: string) => ({ exhume: '2', black_litany: '3', grave_offering: '4', ivory_cleave: '1', veil_step: '5', carrion_seed: '4' } as Record<string, string>)[a] ?? null;
const render: unknown[] = [];
for (const allowed of [false, true]) {
  S.setActiveCharacter(1, allowed);
  for (const id of ids) {
    render.push({ id, auto: allowed, keys: false, title: renderText(TIPS[id].title), body: renderText(TIPS[id].body) });
    render.push({ id, auto: allowed, keys: true, title: renderText(TIPS[id].title, keyFor), body: renderText(TIPS[id].body, keyFor) });
  }
  for (const text of ['Hold 1.{auto} On Easy, Auto (G) plays for you.{/auto} Done.', 'Open [[the Menu||tap the button]] now {p:I}{p:L} and {key:nope} {key:exhume}']) {
    render.push({ text, auto: allowed, keys: true, out: renderText(text, keyFor) });
    render.push({ text, auto: allowed, keys: false, out: renderText(text) });
  }
}
S.setActiveCharacter(1, false);
wr(resolve(FIX, 'render.json'), render);
wr(resolve(FIX, 'keys.json'), { exhume: '2', black_litany: '3', grave_offering: '4', ivory_cleave: '1', veil_step: '5', carrion_seed: '4' });

// ---- deterministic rng for scenario generation ----
function mulberry(seed: number) { let a = seed >>> 0; return () => { a = (a + 0x6d2b79f5) >>> 0; let t = a; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }

// ---- cadence.json ----
const AREAS = ['', 'acre', 'chapterhouse', 'graves', 'warren', 'cloister', 'alchemist_wing', 'pyre', 'fen', 'coliseum', 'ossuary', 'nave', 'depths'];
const KINDS = ['urgent', 'danger', 'asked', 'calm'] as const;
function randBusy(r: () => number): any {
  const b = (p: number) => r() < p;
  return { combat: b(0.3), hurt: b(0.15), talking: b(0.1), banner: b(0.15), dead: b(0.05), panel: b(0.2), area: AREAS[Math.floor(r() * AREAS.length)], safe: b(0.3) };
}
const inf = (v: number) => (v === -Infinity ? null : v);
const cr = mulberry(1234);
const pick = <T,>(r: () => number, a: readonly T[]): T => a[Math.floor(r() * a.length)];
const cadence: any[] = [];
for (let n = 0; n < 350; n++) {
  const now = 100_000 + Math.floor(cr() * 600_000);
  const groups = ['lesson', 'enemy', 'gear', 'bag', 'brew', 'acre', 'road'];
  const gsa: Record<string, number> = {};
  for (const g of groups) if (cr() < 0.5) gsa[g] = now - Math.floor(cr() * 200_000);
  const state: any = { now, lastClosedAt: cr() < 0.1 ? -Infinity : now - Math.floor(cr() * 40_000), groupShownAt: gsa, busy: randBusy(cr) };
  const queue: any[] = [];
  const qn = 1 + Math.floor(cr() * 7);
  for (let i = 0; i < qn; i++) {
    const id = pick(cr, ids) as string;
    const e: any = C.makeEntry(id, now - Math.floor(cr() * 400_000), i + 1, cr() < 0.15);
    if (cr() < 0.2) e.kind = pick(cr, KINDS);
    queue.push(e);
  }
  const card = { id: pick(cr, ids) as string, kind: pick(cr, KINDS), shownAt: now - Math.floor(cr() * 30_000) };
  const waiting = cr() < 0.85 ? queue[0] : null;
  const st = { ...state, lastClosedAt: inf(state.lastClosedAt) };
  const picked = C.pickNext(queue, state);
  cadence.push({
    state: st, queue, card, waiting_seq: waiting ? waiting.seq : null,
    can_show: queue.map((t) => C.canShow(t, state)),
    pick: picked ? picked.seq : null,
    prune: C.prune(queue.map((t) => ({ ...t })), now).map((t) => t.seq),
    preempt: C.shouldPreempt(card as any, waiting, state),
    yield: C.shouldYield(card as any, state),
    max_age: queue.map((t) => C.maxAge(t)),
  });
}
const showms: unknown[] = [];
for (const k of KINDS) for (const w of [1, 10, 24, 25, 40, 55, 60, 80, 120]) showms.push({ kind: k, words: w, ms: C.showMs(k, w) });
wr(resolve(FIX, 'cadence.json'), { cases: cadence, show_ms: showms, classify: ids.map((id) => ({ id, kind: C.kindOf(id), group: C.groupOf(id), priority: C.priorityOf(id) })), make_entry: [
  C.makeEntry('welcome', 500, 3), C.makeEntry('hurt', 500, 4, true), C.makeEntry('move', 1500, 5), C.makeEntry('totally_unknown', 7, 6),
] });

// ---- sequences.json: the real Onboarding class under scripted events ----
interface Op { t: number; op: string; [k: string]: unknown }
const T0 = 50_000;
function run(name: string, ops: Op[], opt: { initial_seen?: string[]; end: number; snap_every?: number; keys?: boolean }) {
  timers.clear(); NOW = T0; timerSeq = 0;
  store.clear();
  S.updateSettings({ tips: true });
  const mem = new Map<string, string>();
  const stor = { getItem: (k: string) => mem.get(k) ?? null, setItem: (k: string, v: string) => void mem.set(k, v), removeItem: (k: string) => void mem.delete(k) };
  const KEY = 'dm_tips_v1_7';
  if (opt.initial_seen) mem.set(KEY, JSON.stringify(opt.initial_seen));
  const root = new FakeEl();
  const log: unknown[] = [];
  const ob: any = new Onboarding(root as any, 7, stor as any, () => NOW);
  if (opt.keys) ob.keyFor = keyFor;
  let busy: any = { ...C.NOT_BUSY };
  ob.busy = () => ({ ...busy });
  const staleIds = new Set<string>();
  ob.stale = (id: string) => staleIds.has(id);
  const rel = () => NOW - T0;
  let lastEl: FakeEl | null = null;
  root.onAppend = (el) => { lastEl = el; log.push([rel(), 'show', ob.shown.id, el.dataset.kind, el.style.vars['--tip-ms']]); };
  const light = ob.light.bind(ob); ob.light = (id: string | null) => { log.push([rel(), 'glow', id]); light(id); };
  const sendBack = ob.sendBack.bind(ob); ob.sendBack = () => { log.push([rel(), 'back', ob.shown?.id ?? null]); sendBack(); };
  const dismiss = ob.dismiss.bind(ob); ob.dismiss = () => { if (ob.el) log.push([rel(), 'hide', ob.shown?.id ?? null]); dismiss(); };
  const clear = ob.clear.bind(ob); ob.clear = () => { log.push([rel(), 'clear']); clear(); };
  const snap = () => ({
    t: rel(), seen: [...ob.seen], queue: ob.queue.map((q: any) => [q.id, q.kind, q.priority, q.queuedAt - T0, q.seq]),
    shown: ob.shown ? [ob.shown.id, ob.shown.kind, ob.shown.shownAt - T0] : null, last_closed: ob.lastClosedAt - T0,
    groups: Object.entries(ob.groupShownAt).map(([g, v]: any) => [g, v - T0]).sort(), pending: [...ob.pending].sort(),
    saved: mem.get(KEY) ?? null,
  });
  const snaps: unknown[] = [];
  const sorted = ops.map((o, i) => ({ o, i })).sort((a, b) => a.o.t - b.o.t || a.i - b.i);
  let k = 0;
  for (const { o } of sorted) {
    advanceTo(T0 + o.t);
    switch (o.op) {
      case 'show': ob.show(o.id, (o.delay as number) ?? 0, o.opts as any ?? {}); break;
      case 'busy': busy = { ...busy, ...(o.set as object) }; break;
      case 'click': ob.dismiss(); break;
      case 'hover': lastEl && ob.el && lastEl.fire(o.on ? 'pointerenter' : 'pointerleave'); break;
      case 'skip': S.updateSettings({ tips: false }); break;
      case 'tips': S.updateSettings({ tips: !!o.value }); break;
      case 'reset': ob.reset(); break;
      case 'stale': staleIds.clear(); for (const s of o.ids as string[]) staleIds.add(s); break;
      default: throw new Error(o.op);
    }
    k++;
    if (!opt.snap_every || k % opt.snap_every === 0) snaps.push(snap());
  }
  advanceTo(T0 + opt.end);
  snaps.push(snap());
  ob.dispose();
  return { name, ops, initial_seen: opt.initial_seen ?? null, end: opt.end, snap_every: opt.snap_every ?? 1, keys: !!opt.keys, log, snaps };
}
const show = (t: number, id: string, delay = 0, opts?: unknown): Op => ({ t, op: 'show', id, delay, ...(opts !== undefined ? { opts } : {}) });
const busyOp = (t: number, set: object): Op => ({ t, op: 'busy', set });
const seqs: unknown[] = [];
// 1 plain: first card after ~3 s, then the queue unrolls one card at a time
seqs.push(run('welcome_flow', [show(0, 'welcome', 900), show(100, 'move'), show(200, 'wave'), show(300, 'gate'), show(400, 'relic')], { end: 200_000 }));
// 2 the ALSO_SEEN rule and re-ask
seqs.push(run('welcome_marks_acre', [show(0, 'welcome'), show(5000, 'acre'), show(40_000, 'welcome')], { end: 90_000 }));
// 3 fight keeps calm tips away, hurt jumps the queue and preempts after 5 s
seqs.push(run('fight_and_hurt', [
  busyOp(0, { combat: true }), show(10, 'wave'), show(20, 'acre'), show(30, 'exhume'), show(40, 'deacon'), busyOp(20_000, { hurt: true }), show(21_000, 'hurt'),
  busyOp(30_000, { hurt: false, combat: false }),
], { end: 120_000 }));
// 4 place-bound tips wait for the place, leave when the hero does
seqs.push(run('here_tips', [
  busyOp(0, { area: 'chapterhouse' }), show(10, 'acre'), show(20, 'warren'), show(30, 'boons'), busyOp(30_000, { area: 'warren' }), busyOp(60_000, { area: 'acre' }), busyOp(90_000, { area: 'chapterhouse' }),
], { end: 300_000 }));
// 5 yield to a conversation and a panel, and death
seqs.push(run('yield_talk_panel_death', [
  show(0, 'wave'), busyOp(30_000, { talking: true }), busyOp(40_000, { talking: false }), show(41_000, 'gate'), busyOp(70_000, { panel: true }), busyOp(80_000, { panel: false }),
  busyOp(100_000, { dead: true }), busyOp(105_000, { dead: false }),
], { end: 300_000 }));
// 6 click dismiss, hover pause, settings off/on, reset and persistence
seqs.push(run('hover_click_settings', [
  show(0, 'welcome'), { t: 5000, op: 'hover', on: true }, { t: 40_000, op: 'hover', on: false }, show(41_000, 'move'), { t: 50_000, op: 'click' }, show(52_000, 'wave'),
  { t: 60_000, op: 'skip' }, show(61_000, 'gate'), { t: 70_000, op: 'tips', value: true }, show(71_000, 'gate'), { t: 120_000, op: 'reset' }, show(121_000, 'welcome'),
], { end: 300_000 }));
// 7 persistence: seen set loaded from storage (unknown ids dropped), never repeats
seqs.push(run('initial_seen', [show(0, 'welcome'), show(10, 'move'), show(20, 'wave')], { end: 100_000, initial_seen: ['welcome', 'bogus', 'move'] }));
// 8 groups keep their distance; asked tips ignore them
seqs.push(run('groups', [
  show(0, 'relic'), show(10, 'armor'), show(20, 'affix'), show(30, 'gearEquip'), show(40, 'meal'), show(50, 'brew'), show(60, 'belt'), show(70, 'gather'), show(80, 'acre'), show(90, 'rich_node'),
], { end: 600_000 }));
// 9 enemy first-sight cards: 40 s apart; stale thrall is dropped
seqs.push(run('enemies_and_stale', [
  busyOp(0, { combat: true }), show(0, 'censer'), show(10, 'wraith'), show(20, 'golem'), show(30, 'thrall'), show(40, 'move'), show(50, 'exhume'), { t: 100, op: 'stale', ids: ['thrall'] },
  busyOp(60_000, { combat: false }),
], { end: 400_000 }));
// 10 calm backlog capped at 4; starved calm tip shows in a fight lull; bump priority
seqs.push(run('backlog_cap_starved', [
  busyOp(0, { combat: true }), show(0, 'people'), show(1, 'omen'), show(2, 'chain'), show(3, 'codex'), show(4, 'tool'), show(5, 'signature'), show(6, 'prelate', 0, true), show(7, 'ascend'),
], { end: 600_000, snap_every: 1 }));
// 11 safe-area danger tips; banner blocks calm
seqs.push(run('safe_and_banner', [
  busyOp(0, { safe: true }), show(10, 'deacon'), show(20, 'elite'), busyOp(30_000, { banner: true }), show(31_000, 'wave'), busyOp(45_000, { banner: false, safe: false }),
], { end: 200_000 }));
// 12 key markup in resolved text does not change the log
seqs.push(run('keys', [show(0, 'thrall'), show(10, 'rite_offering'), show(20, 'exhume')], { end: 200_000, keys: true }));
// 13 delayed shows, pending dedupe and overlapping
seqs.push(run('delays', [show(0, 'omen', 150_000), show(10, 'omen', 10), show(20, 'surge', 1200), show(30, 'surge'), show(40, 'laborers_working', 1500), busyOp(40, { area: 'acre' })], { end: 400_000 }));
// randomized stress
const AREA_POOL = AREAS;
const OPTS = [undefined, undefined, undefined, true, { kind: 'calm' }, { kind: 'asked' }, { kind: 'danger' }, { kind: 'urgent' }, { bump: true }];
const DELAYS = [0, 0, 0, 0, 600, 1200, 1500, 2500, 4500, 45_000];
for (let s = 0; s < 40; s++) {
  const r = mulberry(9000 + s);
  const ops: Op[] = [];
  let t = 0;
  const n = 90;
  for (let i = 0; i < n; i++) {
    t += Math.floor(r() * (r() < 0.2 ? 20_000 : 3000));
    const x = r();
    if (x < 0.5) ops.push(show(t, pick(r, ids) as string, pick(r, DELAYS), pick(r, OPTS)));
    else if (x < 0.75) ops.push(busyOp(t, (() => { const b = randBusy(r); const keys = Object.keys(b); const k = keys[Math.floor(r() * keys.length)]; return { [k]: b[k] }; })()));
    else if (x < 0.82) ops.push({ t, op: 'click' });
    else if (x < 0.87) ops.push({ t, op: 'hover', on: r() < 0.5 });
    else if (x < 0.9) ops.push({ t, op: 'stale', ids: r() < 0.5 ? ['thrall'] : [] });
    else if (x < 0.92) ops.push({ t, op: 'reset' });
    else if (x < 0.94) ops.push({ t, op: 'tips', value: r() < 0.5 });
    else ops.push(show(t, 'thrall'));
  }
  seqs.push(run(`random_${s}`, ops, { end: t + 400_000, snap_every: 6, initial_seen: s % 7 === 0 ? ['welcome', 'move'] : undefined }));
}
wr(resolve(FIX, 'sequences.json'), seqs);

// ---- callsites.json: every show()/tip() call in the web scenes ----
const callsites: unknown[] = [];
function scan(file: string, re: RegExp, kind: 'show' | 'tip') {
  const src = readFileSync(resolve(ROOT, file), 'utf8');
  src.split('\n').forEach((line, i) => {
    for (const m of line.matchAll(re)) {
      const tipArg = m[1];
      const rest = (m[2] ?? '').trim();
      let delay = 0; let kind2: string | null = null; let bump = false;
      const parts = rest ? rest.replace(/^,\s*/, '') : '';
      const dm = /^([\d_]+)\s*(?:,\s*(.*))?$/.exec(parts);
      let optsText = parts;
      if (dm) { delay = Number(dm[1].replace(/_/g, '')); optsText = dm[2] ?? ''; }
      if (/^true$/.test(optsText.trim())) bump = true;
      const km = /kind:\s*'(\w+)'/.exec(optsText);
      if (km) kind2 = km[1];
      if (/bump:\s*true/.test(optsText)) bump = true;
      callsites.push({ file: file.split('/').pop(), line: i + 1, via: kind, tip: tipArg.replace(/^['`]|['`]$/g, ''), dynamic: !/^'/.test(tipArg), delay, kind: kind2, bump });
    }
  });
}
for (const f of ['src/scenes/WorldScene.ts', 'src/scenes/DepthsController.ts']) {
  scan(f, /onboarding\.show\(('[\w]+'|`[^`]+`|[\w.]+)(?:\s+as \w+)?((?:,[^)]*)?)\)/g, 'show');
  scan(f, /host\.tip\(('[\w]+')((?:,[^)]*)?)\)/g, 'tip');
}
wr(resolve(FIX, 'callsites.json'), callsites);
console.log(`onboarding fixtures: ${ids.length} tips, ${cadence.length} cadence cases, ${seqs.length} sequences, ${callsites.length} call sites`);
