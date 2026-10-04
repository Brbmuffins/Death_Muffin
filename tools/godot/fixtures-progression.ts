/**
 * Death Muffin -> Godot golden fixtures for the progression rules (godot/rules/progression/).
 * Imports the REAL game modules, writes:
 *   godot/data/progression/content.json        runtime content the GDScript rules load (never hand-edited)
 *   godot/tests/rules-progression/fixtures/*.json    inputs -> outputs recorded from the TypeScript
 * Run: npx vite-node tools/godot/fixtures-progression.ts
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// ---- environment stubs (must precede importing the game modules' side effects) ----
const store = new Map<string, string>();
(globalThis as any).localStorage = { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => void store.set(k, String(v)), removeItem: (k: string) => void store.delete(k) };
(globalThis as any).sessionStorage = (globalThis as any).localStorage;
(globalThis as any).window = { setTimeout: () => 0, clearTimeout: () => undefined, location: { search: '' } };
(globalThis as any).setInterval = () => 0;
let fetchMode: 'hang' | 'ok' | 'fail' = 'hang';
(globalThis as any).fetch = (): Promise<unknown> => {
  if (fetchMode === 'hang') return new Promise(() => undefined);
  if (fetchMode === 'fail') return Promise.reject(new Error('down'));
  return Promise.resolve({ ok: true, status: 200, json: async () => ({ success: true, data: {} }) });
};
console.warn = () => undefined;

const { AREAS, AREA_ORDER, BOSS_SUMMON_SHARDS, isAlwaysOpen } = await import('../../src/content/areas');
const { BOSSES, BOSS_IDS } = await import('../../src/content/bosses');
const A = await import('../../src/content/ascension');
const U = await import('../../src/content/upgrades');
const NR = await import('../../src/gameplay/necroRules');
const { KillChain, CHAIN } = await import('../../src/gameplay/killChain');
const MS = await import('../../src/gameplay/milestones');
const { Chronicle } = await import('../../src/gameplay/chronicle');
const { Progression, toNecro, loadLocalProgress } = await import('../../src/gameplay/progression');
const { devAccess } = await import('../../src/gameplay/devAccess');
const { setToken } = await import('../../src/net/api');
const { xpToNext } = await import('../../src/gameplay/characterStats');

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const DATA = resolve(ROOT, 'godot/data/progression');
const FIX = resolve(ROOT, 'godot/tests/rules-progression/fixtures');
mkdirSync(DATA, { recursive: true });
mkdirSync(FIX, { recursive: true });
const write = (dir: string, name: string, data: unknown, pretty = false) => writeFileSync(resolve(dir, name), JSON.stringify(data, null, pretty ? 1 : undefined) + '\n');

// ---- seeded rng (fixtures only; independent of the port) ----
let seed = 0x5eed1234;
const rnd = () => {
  seed = (seed + 0x6d2b79f5) >>> 0;
  let t = seed;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
};
const ri = (lo: number, hi: number) => lo + Math.floor(rnd() * (hi - lo + 1));
const pick = <T>(a: readonly T[]): T => a[Math.floor(rnd() * a.length)];
const chance = (p: number) => rnd() < p;

// ============================================================================
// content.json
// ============================================================================
const areaIds = AREA_ORDER;
const content = {
  areaOrder: AREA_ORDER,
  areas: Object.fromEntries(Object.entries(AREAS).map(([id, a]) => [id, { name: a.name, safe: a.safe, instance: !!(a as any).instance, unlock: a.unlock ?? null }])),
  bossSummonShards: BOSS_SUMMON_SHARDS,
  bossIds: BOSS_IDS,
  bosses: Object.fromEntries(Object.entries(BOSSES).map(([id, b]) => [id, { area: b.area, shards: b.shards, summonLabel: b.summonLabel }])),
  ascension: A.ASCENSION,
  vows: A.VOWS,
  vowOrder: A.VOW_ORDER,
  boons: A.BOONS,
  boonOrder: A.BOON_ORDER,
  upgrades: {
    damage: { maxTier: U.DAMAGE_UPGRADE.maxTier, perTier: U.DAMAGE_UPGRADE.perTier, costBase: 40, costGrowth: 1.5 },
    wave: { maxTier: U.WAVE_UPGRADE.maxTier, costBase: 120, costGrowth: 1.75 },
    legion: { maxTier: U.LEGION_UPGRADE.maxTier, perTier: U.LEGION_UPGRADE.perTier, speedPerTier: U.LEGION_UPGRADE.speedPerTier, costBase: 120, costGrowth: 1.65 },
    thrallRefreshMax: U.THRALL_REFRESH_MAX,
    waveMilestones: U.WAVE_MILESTONES,
    nightfallShroudChance: U.NIGHTFALL_SHROUD_CHANCE,
    restlessSurgeMult: U.RESTLESS_SURGE_MULT,
  },
  limits: NR.NECRO_LIMITS,
  chain: CHAIN,
  milestones: MS.MILESTONES.map((m) => {
    const id = m.id;
    let kind: string, area = '', n = 0;
    if (id.startsWith('kills.')) (kind = 'totalKills'), (n = Number(id.slice(6)));
    else if (id.startsWith('chain.')) (kind = 'bestChain'), (n = Number(id.slice(6)));
    else {
      kind = 'areaKills';
      const rest = id.slice(5);
      const dot = rest.lastIndexOf('.');
      (area = rest.slice(0, dot)), (n = Number(rest.slice(dot + 1)));
    }
    return { id, title: m.title, text: m.text, gold: m.gold, kind, area, n };
  }),
  startAreas: ['chapterhouse', 'graves'],
  alwaysOpen: Object.fromEntries(Object.keys(AREAS).map((id) => [id, isAlwaysOpen(id as any)])),
};
write(DATA, 'content.json', content, true);

// ============================================================================
// random generators
// ============================================================================
const huntAreas = areaIds.filter((id) => !AREAS[id].safe);
const allVowIds = A.VOW_ORDER;
const allBoonIds = A.BOON_ORDER;
const unlockKeys = [...allVowIds.map((v) => `vow:${v}`), ...allBoonIds.map((b) => `boon:${b}`)];
const shardKeys = unlockKeys.filter((k) => A.unlockCost(k)! > 0);

function randVows(max = 1): Record<string, number> {
  const out: Record<string, number> = {};
  for (const id of allVowIds) if (chance(0.35 * max)) out[id] = ri(1, A.VOWS[id].maxRank);
  return out;
}
function randBoons(): Record<string, number> {
  const out: Record<string, number> = {};
  for (const id of allBoonIds) if (chance(0.4)) out[id] = ri(1, A.BOONS[id].maxRank);
  return out;
}
function randState(): any {
  const s: any = NR.blankState();
  s.damageTier = chance(0.8) ? ri(0, 25) : 0;
  s.waveTierOwned = chance(0.7) ? ri(0, 8) : 0;
  s.waveTierActive = ri(0, s.waveTierOwned);
  s.legionTier = chance(0.5) ? ri(0, 12) : 0;
  s.soulShards = chance(0.6) ? ri(0, 700) : ri(0, 6);
  for (const id of huntAreas) if (chance(0.5)) s.areaKills[id] = ri(1, 1500);
  s.unlockedAreas = ['chapterhouse', 'graves'];
  for (const id of areaIds) if (id !== 'chapterhouse' && id !== 'graves' && chance(0.4) && !s.unlockedAreas.includes(id)) s.unlockedAreas.push(id);
  if (chance(0.15)) s.unlockedAreas = areaIds.filter((id) => !(AREAS[id] as any).instance);
  s.bossKills = ri(0, 12);
  s.totalKills = Object.values(s.areaKills).reduce((a: number, b: any) => a + b, 0) + ri(0, 400);
  s.ascension = chance(0.5) ? ri(0, 14) : 0;
  s.ashes = chance(0.7) ? ri(0, 80) : ri(0, 10);
  s.boons = chance(0.8) ? randBoons() : {};
  s.vows = randVows();
  s.unlocks = shardKeys.filter(() => chance(0.4));
  s.run = chance(0.75) ? { prelateKills: ri(0, 6), peakWaveTier: ri(0, 10), kills: ri(0, 6000) } : { prelateKills: 0, peakWaveTier: 0, kills: 0 };
  s.summonsPending = chance(0.5) ? ri(0, 5) : 0;
  s.migrated = chance(0.7);
  return s;
}
const junkNum = () => pick<any>([0, 1, 2, 5, 17, 300, 899, 900, 901, 5000, 99999, -1, -50, 2.7, 0.5, 1e9, '3', '', 'x', null, true, false, [], {}, '12.9', ' 7 ', '0x10']);
const sometimes = (v: any, p = 0.5) => (chance(p) ? v : undefined);

function randSaveInput(): any {
  const inp: any = {};
  if (chance(0.8)) {
    inp.areaKills = {};
    for (const id of areaIds) if (chance(0.35)) inp.areaKills[id] = chance(0.8) ? ri(0, 200) : junkNum();
  }
  if (chance(0.7)) inp.shards = chance(0.8) ? ri(0, 35) : junkNum();
  if (chance(0.6)) inp.prelateKills = chance(0.8) ? ri(0, 4) : junkNum();
  if (chance(0.7)) inp.peakWaveTier = chance(0.8) ? ri(0, 9) : junkNum();
  if (chance(0.5)) inp.waveTierActive = chance(0.8) ? ri(0, 9) : junkNum();
  return inp;
}
function randSwear(): any {
  const r = rnd();
  if (r < 0.05) return pick<any>([null, [], 'x', 5, undefined]);
  const o: any = {};
  for (const id of allVowIds) if (chance(0.3)) o[id] = chance(0.85) ? ri(0, A.VOWS[id].maxRank) : pick<any>([-1, 0.5, 99, '2', null, 'x', A.VOWS[id].maxRank + 1]);
  if (chance(0.06)) o['bogus'] = 1;
  if (chance(0.04)) o['toString'] = 1;
  return o;
}
function randImport(): any {
  if (chance(0.1)) return pick<any>([null, 5, 'x', [], undefined]);
  const r: any = {};
  if (chance(0.7)) r.ascension = chance(0.8) ? ri(0, 7) : junkNum();
  if (chance(0.7)) r.ashes = chance(0.8) ? ri(0, 500) : junkNum();
  if (chance(0.7)) {
    r.boons = {};
    for (const id of allBoonIds) if (chance(0.5)) r.boons[id] = chance(0.8) ? ri(0, 4) : junkNum();
  }
  if (chance(0.7)) r.damageTier = chance(0.8) ? ri(0, 30) : junkNum();
  if (chance(0.7)) r.waveTierOwned = chance(0.8) ? ri(0, 10) : junkNum();
  if (chance(0.5)) r.waveTierActive = chance(0.8) ? ri(0, 10) : junkNum();
  if (chance(0.5)) r.shards = chance(0.8) ? ri(0, 60) : junkNum();
  if (chance(0.3)) r.soulShards = chance(0.8) ? ri(0, 60) : junkNum();
  if (chance(0.7)) {
    r.areaKills = {};
    for (const id of areaIds) if (chance(0.5)) r.areaKills[id] = chance(0.8) ? ri(0, 25000) : junkNum();
  }
  if (chance(0.5)) r.bossKills = chance(0.8) ? ri(0, 300) : junkNum();
  if (chance(0.5)) r.totalKills = chance(0.8) ? ri(0, 90000) : junkNum();
  if (chance(0.5)) r.run = { prelateKills: chance(0.8) ? ri(0, 30) : junkNum(), peakWaveTier: chance(0.8) ? ri(0, 12) : junkNum(), kills: chance(0.8) ? ri(0, 4000) : junkNum() };
  return r;
}
/** A raw stored row of mixed vintage for normalise(). */
function randRaw(): any {
  const s = randState();
  if (chance(0.3)) delete s.vows;
  if (chance(0.2)) delete s.legionTier;
  if (chance(0.15)) delete s.run;
  if (chance(0.15)) s.unlockedAreas = [];
  if (chance(0.15)) delete s.unlockedAreas;
  if (chance(0.2)) s.unlocks = [...(s.unlocks ?? []), pick<any>(['vow:bogus', 'boon:vigil', 'vow:elder_dead', 'junk', 5, null, 'boon:legion_pact']), pick(shardKeys)];
  if (chance(0.15)) delete s.unlocks;
  if (chance(0.1)) s.vows = pick<any>([[], 'x', null, { elder_dead: 99 }, { elder_dead: '2', iron_dead: -3, bogus: 1 }]);
  if (chance(0.2)) s.ascension = pick<any>([300, -5, 2.9, '4', null]);
  if (chance(0.15)) s.legionTier = pick<any>([99, -1, 3.5, '4']);
  if (chance(0.1)) s.extraField = { keep: 'me' };
  if (chance(0.1)) s.run = { kills: 5 };
  if (chance(0.1)) delete s.boons;
  if (chance(0.1)) delete s.areaKills;
  if (chance(0.05)) return pick<any>([null, undefined, 5, 'x', [], {}]);
  return s;
}

// ============================================================================
// pure.json: stateless content/rule functions
// ============================================================================
type Case = { fn: string; args: unknown[]; out: unknown };
const pure: Case[] = [];
const rec = (fn: string, args: unknown[], out: unknown) => pure.push({ fn, args, out: out === undefined ? null : out });
const J = (v: unknown) => (v === undefined ? null : JSON.parse(JSON.stringify(v)));

for (let i = 0; i < 400; i++) {
  const vows = chance(0.9) ? randVows(i % 3 === 0 ? 2 : 1) : pick<any>([undefined, null, {}, { elder_dead: 99 }, { iron_dead: '2', bogus: 4 }, { elder_dead: 2.9 }, { dry_cellar: -1 }]);
  const id = pick(allVowIds);
  rec('vowSteps', [vows, id], A.vowSteps(vows, id));
  rec('sanitizeVows', [vows], A.sanitizeVows(vows));
  rec('vowHeat', [vows], A.vowHeat(vows));
  rec('worldVows', [vows], A.worldVows(vows));
  rec('vowEffects', [vows], A.vowEffects(vows));
}
for (let i = -3; i <= 70; i++) {
  rec('ascensionRewardMult', [i], A.ascensionRewardMult(i));
  rec('ascensionLevels', [i], A.ascensionLevels(i));
  rec('legacyVows', [i], A.legacyVows(i));
  rec('roman', [i], A.roman(i));
}
for (const v of [2.5, 7.9, '5', null, 'x', 30.9, 1e9, -2.5]) {
  rec('ascensionRewardMult', [v], A.ascensionRewardMult(v as any));
  rec('ascensionLevels', [v], A.ascensionLevels(v as any));
  rec('legacyVows', [v], A.legacyVows(v as any));
}
for (let i = 0; i < 400; i++) {
  const boons = chance(0.9) ? randBoons() : pick<any>([{ vigil: 99 }, { vigil: -4 }, { vigil: 2.5 }, {}]);
  rec('boonEffects', [boons], A.boonEffects(boons));
  const id = pick(allBoonIds);
  const best = pick([0, 1, 2, 3, 4, 10]);
  const unlocks = chance(0.2) ? undefined : shardKeys.filter(() => chance(0.5));
  rec('boonBlocked', [id, boons, best, unlocks ?? null], A.boonBlocked(id, boons, best, unlocks));
  rec('boonCost', [id, boons], A.boonCost(id, boons));
  const key = pick([...unlockKeys, 'vow:bogus', 'boon:bogus', 'junk', 'vow:', '']);
  rec('isUnlocked', [unlocks ?? null, key], A.isUnlocked(unlocks, key));
  rec('unlockCost', [key], A.unlockCost(key));
  const run = { prelateKills: ri(0, 9), peakWaveTier: ri(0, 12), kills: ri(0, 9000) };
  const heat = pick<any>([0, 1, 2, 5, 12, 30, 50, 2.7, -3, '4', null]);
  rec('ashesForRun', [run, heat], A.ashesForRun(run, heat));
}
for (const id of allBoonIds) for (let r = 0; r <= A.BOONS[id].maxRank + 1; r++) rec('boonCost', [id, { [id]: r }], A.boonCost(id, { [id]: r }));
for (let t = 0; t <= 27; t++) {
  rec('damageUpgradeCost', [t], U.DAMAGE_UPGRADE.cost(t));
  rec('legionUpgradeCost', [t], U.LEGION_UPGRADE.cost(t));
  rec('waveUpgradeCost', [t], U.WAVE_UPGRADE.cost(t));
  rec('damageBonusPct', [t], U.damageBonusPct(t));
  rec('densityTier', [t], U.densityTier(t));
  rec('waveModifiers', [t], U.waveModifiers(t));
  for (const mx of [3, 8, 12, 25]) rec('milestones', [t, mx], U.milestones(t, mx));
  for (const m of U.WAVE_MILESTONES) rec('milestoneActive', [m.id, t], U.milestoneActive(m.id, t));
}
for (const t of [0.5, 1.5, 2.5, 3.5, 7.3, -1]) {
  rec('densityTier', [t], U.densityTier(t));
  rec('waveModifiers', [t], U.waveModifiers(t));
  rec('damageBonusPct', [t], U.damageBonusPct(t));
}
for (let l = 1; l <= 60; l++) rec('xpToNext', [l], xpToNext(l));
for (let n = 0; n <= 100; n++) rec('tierFor', [n], J(KillChain.tierFor(n)));
// necro derived rules over random states
for (let i = 0; i < 120; i++) {
  const s = randState();
  rec('damageCost', [s], NR.damageCost(s));
  rec('waveCost', [s], NR.waveCost(s));
  rec('legionCost', [s], NR.legionCost(s));
  rec('runHeat', [s], NR.runHeat(s));
  rec('ashesOnAscend', [s], NR.ashesOnAscend(s));
  for (const id of areaIds) rec('unlockKills', [s, id], NR.unlockKills(s, id));
}
for (let i = 0; i < 350; i++) {
  const raw = randRaw();
  rec('normalise', [raw], NR.normalise(raw));
}
// milestones list + newlyReached
rec('milestonesList', [], MS.MILESTONES.map((m) => ({ id: m.id, title: m.title, text: m.text, gold: m.gold })));
for (let i = 0; i < 300; i++) {
  const c: any = { totalKills: chance(0.8) ? ri(0, 30000) : 0, areaKills: {}, bestChain: ri(0, 120) };
  for (const id of huntAreas) if (chance(0.5)) c.areaKills[id] = ri(0, 3000);
  const claimed = MS.MILESTONES.filter(() => chance(0.4)).map((m) => m.id);
  rec('newlyReached', [c, claimed], MS.newlyReached(c, new Set(claimed)).map((m) => m.id));
}
write(FIX, 'pure.json', pure);
console.log('pure cases', pure.length);

// ============================================================================
// necro_seq.json: action sequences over the server rules
// ============================================================================
type Step = { op: string; args: unknown[]; opts?: unknown; out: any };
const seqs: { start: unknown; steps: Step[] }[] = [];
const strip = (r: any) => J(r);

function oneStep(state: any): { op: string; args: unknown[]; opts?: unknown; run: () => any } {
  const staff = chance(0.15) ? { staff: true } : chance(0.5) ? {} : undefined;
  const r = rnd();
  if (r < 0.27) {
    const inp = randSaveInput();
    return { op: 'applySave', args: [inp], opts: staff, run: () => NR.applySave(state, inp, staff) };
  }
  if (r < 0.4) {
    const up = pick<any>(['damage', 'wave', 'legion', 'damage', 'wave', 'bogus', null]);
    const cost = up === 'damage' ? NR.damageCost(state) : up === 'wave' ? NR.waveCost(state) : up === 'legion' ? NR.legionCost(state) : 100;
    const gold = chance(0.7) ? (cost ?? 100) + ri(-3, 400) : ri(0, 3000);
    return { op: 'purchase', args: [gold, up], run: () => NR.purchase(state, gold, up) };
  }
  if (r < 0.46) return { op: 'summonPrelate', args: [], opts: staff, run: () => NR.summonPrelate(state, staff) };
  if (r < 0.54) {
    const boss = pick<any>([...BOSS_IDS, ...BOSS_IDS, 'bogus', 5, null, 'toString']);
    return { op: 'summonAreaBoss', args: [boss], opts: staff, run: () => NR.summonAreaBoss(state, boss, staff) };
  }
  if (r < 0.62) return { op: 'ascend', args: [], run: () => NR.ascend(state) };
  if (r < 0.72) {
    const v = randSwear();
    return { op: 'swearVows', args: [v], run: () => NR.swearVows(state, v) };
  }
  if (r < 0.82) {
    const key = pick<any>([...shardKeys, ...shardKeys, ...unlockKeys, 'vow:bogus', 'junk', 5, null]);
    return { op: 'unlockEntry', args: [key], run: () => NR.unlockEntry(state, key) };
  }
  if (r < 0.94) {
    const id = pick<any>([...allBoonIds, ...allBoonIds, 'bogus', 3, null, 'toString']);
    return { op: 'buyBoon', args: [id], run: () => NR.buyBoon(state, id) };
  }
  const raw = randImport();
  return { op: 'importLocal', args: [raw], run: () => NR.importLocal(state, raw) };
}
for (let i = 0; i < 500; i++) {
  let state: any = chance(0.1) ? NR.blankState() : chance(0.5) ? randState() : NR.normalise(randRaw());
  if (i % 4 === 0) {
    // ready-to-ascend / flush-with-shards bias
    state.run.prelateKills = Math.max(1, state.run.prelateKills);
    state.soulShards += 200;
    state.ashes += 40;
    state.unlockedAreas = areaIds.filter((id) => !(AREAS[id] as any).instance);
    state.summonsPending = ri(0, 3);
  }
  const start = J(state);
  const steps: Step[] = [];
  const n = ri(4, 12);
  for (let k = 0; k < n; k++) {
    const st = oneStep(state);
    const res: any = st.run();
    steps.push({ op: st.op, args: J(st.args) as unknown[], ...(st.opts !== undefined ? { opts: J(st.opts) } : {}), out: strip(res) });
    if (res.ok) state = res.state;
  }
  seqs.push({ start, steps });
}
write(FIX, 'necro_seq.json', seqs);
console.log('necro sequences', seqs.length, 'steps', seqs.reduce((a, s) => a + s.steps.length, 0));

// ============================================================================
// kill_chain.json
// ============================================================================
const chains: any[] = [];
for (let i = 0; i < 120; i++) {
  const kc = new KillChain();
  let now = ri(0, 5000);
  const steps: any[] = [];
  for (let k = 0; k < ri(10, 120); k++) {
    const r = rnd();
    now += r < 0.1 ? ri(3500, 6000) : ri(0, 900);
    let op: string;
    let out: any = null;
    if (r < 0.7) (op = 'hit'), (out = J(kc.hit(now)));
    else if (r < 0.88) (op = 'tick'), (out = kc.tick(now));
    else if (r < 0.93) (op = 'reset'), kc.reset();
    else (op = 'frac'), (out = kc.frac(now));
    steps.push({ op, now, out, count: kc.count, best: kc.best, mult: kc.mult, active: kc.active, tier: J(kc.tier), frac: kc.frac(now) });
  }
  chains.push({ steps });
}
write(FIX, 'kill_chain.json', chains);

// ============================================================================
// progression_seq.json: the local Progression object (mode local + server-cache paths)
// ============================================================================
setToken('x.y.z');
const chr = () => ({ id: 1, class_index: 0, class_name: 'Necromancer', level: ri(1, 40), experience: ri(0, 900), gold: chance(0.7) ? ri(0, 200000) : ri(0, 500), stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 5 });
function snap(p: any) {
  const v = p.chronicle?.view();
  return { local: J(p.local), character: { level: p.character.level, experience: p.character.experience, gold: p.character.gold }, pending: J(p.pending), pendingWaveActive: p.pendingWaveActive, chronicle: v ? { life: J(v.life), run: J(v.run) } : null };
}
const progs: any[] = [];
function localFromNecro(): any {
  // a LocalProgress of mixed vintage (as stored in the browser)
  const s = randState();
  const l: any = { v: 1, damageTier: s.damageTier, waveTierOwned: s.waveTierOwned, waveTierActive: s.waveTierActive, shards: s.soulShards, areaKills: s.areaKills, unlocked: s.unlockedAreas, bossKills: s.bossKills, totalKills: s.totalKills, ascension: s.ascension, ashes: s.ashes, boons: s.boons, run: s.run };
  if (chance(0.8)) l.legionTier = s.legionTier;
  if (chance(0.7)) l.vows = s.vows;
  if (chance(0.7)) l.unlocks = s.unlocks;
  if (chance(0.3)) l.summonsPending = s.summonsPending;
  if (chance(0.2)) l.serverBacked = true;
  if (chance(0.15)) delete l.run;
  return l;
}
for (let i = 0; i < 220; i++) {
  store.clear();
  const c = chr();
  let saved: any = null;
  const r0 = rnd();
  if (r0 < 0.85) {
    saved = localFromNecro();
    store.set(`dm_progress_v1_${c.id}`, JSON.stringify(saved));
  }
  const loaded = J(loadLocalProgress(c.id));
  const prog: any = new Progression(c as any);
  const mode = chance(0.35) ? 'server' : 'local';
  prog.mode = mode;
  const withChron = chance(0.8);
  if (withChron) prog.chronicle = new Chronicle(c.id);
  const dev = chance(0.15);
  devAccess.active = dev;
  const steps: any[] = [];
  if (chance(0.5)) {
    prog.local.shards += 150;
    prog.local.run.prelateKills = Math.max(1, prog.local.run.prelateKills);
  }
  const init = { character: { level: c.level, experience: c.experience, gold: c.gold }, savedLocal: saved, loaded, mode, dev, withChron, initial: snap(prog), toNecro: J(toNecro(prog.local)) };
  for (let k = 0; k < ri(8, 30); k++) {
    const r = rnd();
    let op: string, args: any[], ret: any;
    if (r < 0.1) (op = 'addXp'), (args = [chance(0.8) ? ri(0, 3000) : ri(0, 90000)]), (ret = prog.addXp(args[0]));
    else if (r < 0.17) (op = 'addGold'), (args = [pick<any>([ri(0, 5000), ri(0, 80000), 0, -5, 12.5, 99.5])]), (ret = prog.addGold(args[0]));
    else if (r < 0.22) (op = 'buyDamage'), (args = []), (ret = prog.buyDamage());
    else if (r < 0.27) (op = 'buyWave'), (args = []), (ret = prog.buyWave());
    else if (r < 0.31) (op = 'buyLegion'), (args = []), (ret = prog.buyLegion());
    else if (r < 0.34) (op = 'ascend'), (args = []), (ret = prog.ascend());
    else if (r < 0.41) {
      op = 'swearVows';
      const v: any = {};
      for (const id of allVowIds) if (chance(0.3)) v[id] = ri(0, A.VOWS[id].maxRank + (chance(0.1) ? 1 : 0));
      args = [v];
      ret = [prog.vowsProblem(v), prog.vowsRestartRun(v), prog.swearVows(v)];
    } else if (r < 0.47) {
      op = 'unlockAtAltar';
      const key = pick<any>([...shardKeys, 'vow:bogus', 'vow:elder_dead']);
      args = [key];
      ret = [prog.unlockProblem(key), prog.unlockAtAltar(key)];
    } else if (r < 0.53) {
      op = 'buyBoon';
      const id = pick(allBoonIds);
      args = [id];
      ret = [prog.boonProblem(id), prog.buyBoon(id)];
    } else if (r < 0.7) {
      op = 'recordKill';
      const area = pick(areaIds);
      args = chance(0.5) ? [area] : [area, ri(0, 8)];
      ret = prog.recordKill(...(args as [any, any]));
    } else if (r < 0.74) (op = 'recordPrelateKill'), (args = []), (ret = prog.recordPrelateKill());
    else if (r < 0.78) {
      op = 'unlock';
      args = [pick(areaIds)];
      ret = [prog.unlock(args[0]), prog.isUnlocked(args[0]), prog.reallyUnlocked(args[0])];
    } else if (r < 0.83) (op = 'addShards'), (args = [ri(0, 12)]), (ret = prog.addShards(args[0]));
    else if (r < 0.87) (op = 'spendShards'), (args = [pick([5, 5, 50, 300])]), (ret = prog.spendShards(args[0]));
    else if (r < 0.9) {
      op = 'spendBossShards';
      args = [pick(BOSS_IDS)];
      ret = prog.spendBossShards(args[0]);
    } else if (r < 0.92) (op = 'refundBossShards'), (args = [pick(BOSS_IDS)]), (ret = prog.refundBossShards(args[0]));
    else if (r < 0.95) (op = 'setActiveWaveTier'), (args = [pick<any>([ri(-2, 12), 3.5])]), (ret = prog.setActiveWaveTier(args[0]));
    else if (r < 0.98 && mode === 'server') {
      op = 'adopt';
      const srv = NR.normalise(randState());
      args = [J(srv)];
      ret = prog.adopt(srv);
    } else {
      op = 'queries';
      args = [pick(areaIds), ri(1, 900)];
      ret = [prog.damageCost(), prog.waveCost(), prog.legionCost(), prog.ashesOnAscend(), prog.canAscend(), prog.heat, J(prog.boons), J(prog.vowFx), prog.kills(args[0]), prog.unlockKills(args[1])];
    }
    steps.push({ op, args: J(args), ret: J(ret ?? null), ...snap(prog) });
  }
  progs.push({ ...init, steps });
  devAccess.active = false;
}
write(FIX, 'progression_seq.json', progs);
console.log('progression sequences', progs.length, 'steps', progs.reduce((a, s) => a + s.steps.length, 0));

// ============================================================================
// chronicle_seq.json: counters, time, view fold, flush transitions
// ============================================================================
const chrons: any[] = [];
const chKeys = ['kills', 'kills.graves', 'kills.ossuary', 'gold.earned', 'gold.spent', 'peak.wave', 'peak.level', 'boss.saint', 'playSeconds', 'afkSeconds'];
for (let i = 0; i < 150; i++) {
  const c: any = new Chronicle(1);
  const data: any = { life: {}, run: {}, runNo: ri(1, 5), runStartedAt: null, runs: [] };
  for (const k of chKeys) if (chance(0.4)) (data.life[k] = ri(0, 500)), chance(0.7) && (data.run[k] = ri(0, 200));
  c.data = JSON.parse(JSON.stringify(data));
  c.loaded = true;
  const steps: any[] = [];
  for (let k = 0; k < ri(8, 40); k++) {
    const r = rnd();
    let op: string, args: any[];
    if (r < 0.35) (op = 'add'), (args = [pick(chKeys), pick<any>([1, 1, 3, 10, 0, -2, 2.5, 7])]), c.add(args[0], args[1]);
    else if (r < 0.5) (op = 'max'), (args = [pick(chKeys), pick<any>([ri(0, 60), 0, -3, 4.5])]), c.max(args[0], args[1]);
    else if (r < 0.7) (op = 'time'), (args = [pick<any>([0.016, 0.5, 1.25, 2.9, 0, 7]), chance(0.4)]), c.time(args[0], args[1]);
    else if (r < 0.85) {
      op = 'flush_ok';
      args = [];
      fetchMode = 'ok';
      await c.flush();
    } else {
      op = 'flush_fail';
      args = [];
      fetchMode = 'fail';
      await c.flush();
    }
    fetchMode = 'hang';
    const v = c.view();
    steps.push({ op, args: J(args), sums: J(c.sums), maxes: J(c.maxes), data: { life: J(c.data.life), run: J(c.data.run) }, view: { life: J(v.life), run: J(v.run) }, fraction: J(c.fraction) });
  }
  chrons.push({ data: J(data), steps });
}
write(FIX, 'chronicle_seq.json', chrons);

console.log('done');
process.exit(0);
