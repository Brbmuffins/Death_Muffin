import { beforeAll, describe, expect, it, vi } from 'vitest';
import { ASCENSION, BOONS, BOON_ORDER, VOWS, VOW_ORDER, ashesForRun, ascensionLevels, boonEffects, boonKey, isUnlocked, legacyVows, roman, vowEffects, vowHeat, vowKey, worldVows } from '../../content/ascension';
import { AREAS } from '../../content/areas';
import { Nav } from '../nav';
import { mulberry32 } from '../rng';
import { WorldSim } from '../sim/WorldSim';
import { WorldMirror, makeSnapshot } from '../sim/snapshot';

vi.mock('../../net/api', () => ({ saveProgress: vi.fn(async () => undefined) }));

beforeAll(() => {
  // Progression schedules saves on window timers; node has none.
  (globalThis as unknown as { window: unknown }).window = { setTimeout: () => 0, clearTimeout: () => undefined };
});

async function fresh(id = 1) {
  const { Progression } = await import('../progression');
  return new Progression({ id, class_index: 1, class_name: '', level: 18, experience: 0, gold: 5000, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 5 });
}

describe('Ascension rules', () => {
  it('pays nothing until the Prelate falls this run, then more for a bigger run and a higher rank', () => {
    expect(ashesForRun({ prelateKills: 0, peakWaveTier: 8, kills: 5000 }, 0)).toBe(0);
    const small = ashesForRun({ prelateKills: 1, peakWaveTier: 0, kills: 100 }, 0);
    const big = ashesForRun({ prelateKills: 3, peakWaveTier: 8, kills: 3000 }, 0);
    expect(small).toBeGreaterThan(0);
    expect(big).toBeGreaterThan(small);
    expect(ashesForRun({ prelateKills: 1, peakWaveTier: 0, kills: 100 }, 4)).toBeGreaterThan(small);
  });

  it('boons are sane: costs per rank, effects bounded', () => {
    for (const id of BOON_ORDER) {
      expect(BOONS[id].cost.length).toBe(BOONS[id].maxRank);
      for (let i = 1; i < BOONS[id].cost.length; i++) expect(BOONS[id].cost[i]).toBeGreaterThan(BOONS[id].cost[i - 1]);
    }
    const maxed = boonEffects(Object.fromEntries(BOON_ORDER.map((id) => [id, 99])));
    expect(maxed.damageCostMult).toBeGreaterThan(0.5);
    expect(maxed.unlockKillsMult).toBeGreaterThan(0.5);
    expect(maxed.extraThralls).toBe(1);
    expect(roman(4)).toBe('IV');
    expect(roman(19)).toBe('XIX');
  });

  it('ascending burns the run but keeps level, gold and boons', async () => {
    const p = await fresh(2);
    const c = p.character;
    p.local.damageTier = 9;
    p.local.waveTierOwned = 5;
    p.local.waveTierActive = 4;
    p.local.shards = 7;
    p.local.areaKills = { graves: 400, ossuary: 500 };
    p.local.unlocked = ['chapterhouse', 'graves', 'ossuary', 'nave', 'sanctum'];
    p.local.totalKills = 900;
    expect(p.canAscend()).toBe(false);
    expect(p.ascend()).toBe(0);
    p.recordPrelateKill();
    const earned = p.ashesOnAscend();
    expect(earned).toBeGreaterThan(0);
    expect(p.ascend()).toBe(earned);
    expect(p.local.ascension).toBe(0); // no vows sworn: heat 0, so the best rank stays 0
    expect(p.local.ashes).toBe(earned);
    expect(p.local.damageTier).toBe(0);
    expect(p.local.waveTierOwned).toBe(0);
    expect(p.local.shards).toBe(7); // unspent shards are kept
    expect(p.local.unlocked).toEqual(['chapterhouse', 'graves', 'ossuary', 'nave', 'sanctum']); // seals do not reset
    expect(p.local.areaKills).toEqual({ graves: 400, ossuary: 500 });
    expect(p.local.run.prelateKills).toBe(0);
    // Server-owned and lifetime values survive.
    expect(c.level).toBe(18);
    expect(c.gold).toBe(5000);
    expect(p.local.bossKills).toBe(1);
    expect(p.local.totalKills).toBe(900);
  });

  it('boons cost Ashes, respect rank gates, and shape the next run', async () => {
    const p = await fresh(3);
    p.local.ashes = 100;
    expect(p.boonProblem('legion_pact')).toMatch(/Ascension/);
    expect(p.buyBoon('first_rites')).toBe(true);
    expect(p.local.damageTier).toBe(2); // applies to the run in progress too
    expect(p.buyBoon('shard_keeper')).toBe(true);
    expect(p.buyBoon('bone_tithe')).toBe(true);
    const full = Math.round(40 * Math.pow(1.5, p.local.damageTier));
    expect(p.damageCost()).toBe(Math.round(full * 0.9));
    expect(p.unlockKills(300)).toBe(300);
    p.recordPrelateKill();
    p.ascend();
    expect(p.local.damageTier).toBe(2);
    expect(p.local.shards).toBe(2);
    p.local.ashes = 0;
    expect(p.buyBoon('vigil')).toBe(false);
    expect(p.boonProblem('vigil')).toMatch(/Needs/);
  });

  it('records the run: kills and the peak Wave Speed it was fought at', async () => {
    const p = await fresh(4);
    p.recordKill('graves', 3);
    p.recordKill('graves', 1);
    expect(p.local.run.kills).toBe(2);
    expect(p.local.run.peakWaveTier).toBe(3);
  });
});

describe('Ascension in the world', () => {
  it('ages every enemy and the Prelate, and rides snapshots to guests', () => {
    const base = new WorldSim(new Nav(), mulberry32(1));
    const old = new WorldSim(new Nav(), mulberry32(1));
    old.ascension = 2;
    const a = base.spawnEnemy('robber', 'graves', 0, -20, false, false);
    const b = old.spawnEnemy('robber', 'graves', 0, -20, false, false);
    expect(b.level - a.level).toBe(ascensionLevels(2));
    expect(b.maxHp).toBeGreaterThan(a.maxHp);
    expect(b.damage).toBeGreaterThan(a.damage);
    old.setPlayer({ id: 'p1', x: 0, z: -110, alive: true, area: 'sanctum' });
    old.apply({ t: 'summonBoss', by: 'p1' });
    expect(old.bossState.level).toBe(AREAS.sanctum.level + 2 * ASCENSION.levelsPerRank);
    const m = new WorldMirror();
    m.applySnapshot(makeSnapshot(old, true));
    expect(m.ascension).toBe(2);
  });
});

describe('Vows', () => {
  const run = { prelateKills: 1, peakWaveTier: 4, kills: 900 };

  it('heat is the sum of the sworn steps times each vow\'s heat, bounded by each vow\'s own cap', () => {
    expect(vowHeat({})).toBe(0);
    expect(vowHeat({ elder_dead: 3, deacon_host: 1 })).toBe(3 + 2);
    expect(vowHeat({ elder_dead: 999, dry_cellar: 5, nonsense: 4 } as never)).toBe(VOWS.elder_dead.maxRank + VOWS.dry_cellar.heat);
    expect(vowHeat(Object.fromEntries(VOW_ORDER.map((id) => [id, VOWS[id].maxRank])))).toBeLessThanOrEqual(ASCENSION.maxRank);
    expect(VOW_ORDER.length).toBeGreaterThanOrEqual(8);
    expect(VOW_ORDER.length).toBeLessThanOrEqual(12);
  });

  it('pays more Ashes for more heat, and nothing until the Prelate falls', () => {
    expect(ashesForRun({ ...run, prelateKills: 0 }, 20)).toBe(0);
    const base = ashesForRun(run, 0);
    expect(base).toBeGreaterThan(0);
    let last = base;
    for (const h of [1, 4, 10, 25]) {
      const a = ashesForRun(run, h);
      expect(a).toBeGreaterThan(last);
      last = a;
    }
    expect(ashesForRun(run, 5)).toBe(Math.round(base * (1 + ASCENSION.ashesPerHeat * 5)));
  });

  it('effects: older dead, tougher dead, bigger waves, Deacons, elites, echoes, and the self curses', () => {
    const fx = vowEffects({ elder_dead: 2, iron_dead: 2, swollen_waves: 2, deacon_host: 1, elite_surge: 2, prelate_echo: 3, thin_graves: 2, frail_vessel: 3, famished: 2, brittle_thralls: 2, dry_cellar: 1 });
    expect(fx.levels).toBe(2 * ASCENSION.levelsPerRank);
    expect(fx.enemyHpMult).toBeCloseTo(1.5);
    expect(fx.waveSizeMult).toBeCloseTo(1.5);
    expect(fx.deaconMult).toBe(2);
    expect(fx.eliteBonus).toBeCloseTo(0.16);
    expect(fx.echoes).toBe(3);
    expect(fx.corpseLifeMult).toBeCloseTo(0.5);
    expect(fx.maxHpMult).toBeCloseTo(0.64);
    expect(fx.essenceRegenMult).toBeCloseTo(0.6);
    expect(fx.thrallHpMult).toBeCloseTo(0.6);
    expect(fx.noFlasks).toBe(true);
    expect(vowEffects({}).noFlasks).toBe(false);
    // Only world-scope vows run in the sim.
    expect(Object.keys(worldVows({ elder_dead: 1, frail_vessel: 2, dry_cellar: 1, deacon_host: 1 })).sort()).toEqual(['deacon_host', 'elder_dead']);
  });

  it('shard unlocks: free vows and boons need none, the rest are priced against the live shard economy', () => {
    for (const id of VOW_ORDER) {
      const c = VOWS[id].unlockShards;
      expect(c).toBeGreaterThanOrEqual(0);
      expect(c).toBeLessThanOrEqual(1000); // ~7 shards per 100 kills: a dedicated day, never an impossible wall
    }
    for (const id of BOON_ORDER) expect(BOONS[id].unlockShards).toBeLessThanOrEqual(1000);
    expect(isUnlocked([], vowKey('elder_dead'))).toBe(true);
    expect(isUnlocked([], vowKey('prelate_echo'))).toBe(false);
    expect(isUnlocked([vowKey('prelate_echo')], vowKey('prelate_echo'))).toBe(true);
    expect(isUnlocked([], boonKey('bonded_dead'))).toBe(false);
    expect(isUnlocked([], 'vow:bogus')).toBe(false);
    // Six boons that change how you play.
    expect(BOON_ORDER.filter((id) => BOONS[id].shape).length).toBeGreaterThanOrEqual(6);
  });

  it('server rule: swearing validates ids, steps and unlocks; changing mid-run restarts the tally', async () => {
    const rules = await import('../necroRules');
    const s0 = { ...rules.blankState(), run, soulShards: 700 };
    expect(rules.swearVows(s0, { bogus: 1 }).ok).toBe(false);
    expect(rules.swearVows(s0, { elder_dead: 99 }).ok).toBe(false);
    expect(rules.swearVows(s0, { elder_dead: 1.5 }).ok).toBe(false);
    expect(rules.swearVows(s0, { elder_dead: -1 }).ok).toBe(false);
    expect(rules.swearVows(s0, [] as never).ok).toBe(false);
    const locked = rules.swearVows(s0, { prelate_echo: 1 });
    expect(locked.ok).toBe(false);
    if (!locked.ok) expect(locked.error).toMatch(/not unlocked/);
    const r = rules.swearVows(s0, { elder_dead: 3, iron_dead: 1 });
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.heat).toBe(4);
    expect(r.restarted).toBe(true);
    expect(r.state.run).toEqual({ prelateKills: 0, peakWaveTier: 0, kills: 0 });
    expect(r.state.vows).toEqual({ elder_dead: 3, iron_dead: 1 });
    // Same set again: nothing restarts. An empty tally never restarts.
    const same = rules.swearVows({ ...r.state, run }, { iron_dead: 1, elder_dead: 3 });
    expect(same.ok && same.restarted).toBe(false);
    expect(same.ok && same.state.run).toEqual(run);
    const fresh = rules.swearVows({ ...rules.blankState() }, { elder_dead: 2 });
    expect(fresh.ok && fresh.restarted).toBe(false);
  });

  it('server rule: unlocking spends the shards once, is priced by the server, and gates swearing and buying', async () => {
    const rules = await import('../necroRules');
    const s = { ...rules.blankState(), soulShards: 650, ashes: 40 };
    expect(rules.unlockEntry(s, 'vow:elder_dead').ok).toBe(false); // free: nothing to unlock
    expect(rules.unlockEntry(s, 'vow:nope').ok).toBe(false);
    expect(rules.unlockEntry(s, 7).ok).toBe(false);
    expect(rules.unlockEntry({ ...s, soulShards: 599 }, vowKey('prelate_echo')).ok).toBe(false);
    const u = rules.unlockEntry(s, vowKey('prelate_echo'));
    expect(u.ok).toBe(true);
    if (!u.ok) return;
    expect(u.cost).toBe(VOWS.prelate_echo.unlockShards);
    expect(u.state.soulShards).toBe(650 - VOWS.prelate_echo.unlockShards);
    expect(rules.unlockEntry(u.state, vowKey('prelate_echo')).ok).toBe(false); // once only
    expect(rules.swearVows(u.state, { prelate_echo: 3 }).ok).toBe(true);
    // A locked boon cannot be bought with Ashes; unlocking opens it.
    expect(rules.buyBoon(s, 'bonded_dead').ok).toBe(false);
    const b = rules.unlockEntry({ ...s, soulShards: 300 }, boonKey('bonded_dead'));
    expect(b.ok && rules.buyBoon(b.state, 'bonded_dead').ok).toBe(true);
  });

  it('server rule: ascend pays for the sworn heat, raises the best rank, keeps seals, shards and vows', async () => {
    const rules = await import('../necroRules');
    const open = ['chapterhouse', 'graves', 'ossuary', 'nave', 'sanctum'] as never;
    const s = { ...rules.blankState(), run, soulShards: 777, damageTier: 5, waveTierOwned: 3, legionTier: 2, areaKills: { graves: 400 }, unlockedAreas: open, vows: { elder_dead: 4, iron_dead: 2 }, ascension: 3 };
    const a = rules.ascend(s);
    expect(a.ok).toBe(true);
    if (!a.ok) return;
    expect(a.earned).toBe(ashesForRun(run, 6));
    expect(a.heat).toBe(6);
    expect(a.state.ascension).toBe(6); // a hotter run than the old best
    expect(a.state.unlockedAreas).toEqual(open); // seals do not reset
    expect(a.state.areaKills).toEqual({ graves: 400 });
    expect(a.state.soulShards).toBe(777);
    expect(a.state.vows).toEqual({ elder_dead: 4, iron_dead: 2 });
    expect(a.state.damageTier).toBe(0);
    expect(a.state.legionTier).toBe(0);
    expect(a.state.run).toEqual({ prelateKills: 0, peakWaveTier: 0, kills: 0 });
    // A cooler run never lowers the best rank.
    const cool = rules.ascend({ ...s, vows: { elder_dead: 1 } });
    expect(cool.ok && cool.state.ascension).toBe(3);
    expect(rules.ascend({ ...s, run: { ...run, prelateKills: 0 } }).ok).toBe(false);
    const keeper = rules.ascend({ ...rules.blankState(), soulShards: 0, run, boons: { shard_keeper: 2 } });
    expect(keeper.ok && keeper.state.soulShards).toBe(4);
  });

  it('migration: an existing character keeps rank, Ashes and boons, and plays the same world (rank N = N steps of Elder Dead)', async () => {
    const rules = await import('../necroRules');
    // Shaped like the live row of 2026-10-03: rank 1, boons bought, Ashes in hand, no vows or unlocks keys yet.
    const old = { damageTier: 3, waveTierOwned: 2, waveTierActive: 2, legionTier: 1, soulShards: 9799, areaKills: { graves: 5 }, unlockedAreas: ['chapterhouse', 'graves', 'ossuary'], bossKills: 4, totalKills: 65925, ascension: 1, ashes: 12, boons: { vigil: 3, bone_tithe: 2, first_rites: 1 }, run: { prelateKills: 1, peakWaveTier: 2, kills: 300 }, summonsPending: 0, migrated: true };
    const m = rules.normalise(old);
    expect(m.ascension).toBe(1);
    expect(m.ashes).toBe(12);
    expect(m.boons).toEqual(old.boons);
    expect(m.vows).toEqual({ elder_dead: 1 });
    expect(vowHeat(m.vows)).toBe(1);
    expect(vowEffects(m.vows).levels).toBe(ascensionLevels(1)); // the same +3 levels
    expect(m.unlocks).toEqual([]);
    expect(m.soulShards).toBe(9799);
    expect(m.unlockedAreas).toEqual(old.unlockedAreas); // seals untouched
    expect(m.run).toEqual(old.run);
    // Normalising again changes nothing (idempotent), and a rank-0 row has no vows.
    expect(rules.normalise(m)).toEqual(m);
    expect(rules.normalise({ ...old, ascension: 0 }).vows).toEqual({});
    expect(legacyVows(20)).toEqual({ elder_dead: 20 });
    // The player may lower the vow whenever they like; the best rank stays.
    const lowered = rules.swearVows(m, {});
    expect(lowered.ok && lowered.state.ascension).toBe(1);
    expect(lowered.ok && lowered.state.vows).toEqual({});
  });

  it('migration: a stored row with garbage vows or unlocks is cleaned, not trusted', async () => {
    const rules = await import('../necroRules');
    const m = rules.normalise({ vows: { elder_dead: 500, bogus: 3, dry_cellar: 'x' }, unlocks: ['vow:prelate_echo', 'vow:elder_dead', 'zzz', 4], ascension: 2 });
    expect(m.vows).toEqual({ elder_dead: VOWS.elder_dead.maxRank });
    expect(m.unlocks).toEqual(['vow:prelate_echo']);
  });

  it('tampering: the client cannot choose price, heat or Ashes', async () => {
    const rules = await import('../necroRules');
    const s = { ...rules.blankState(), soulShards: 10, run };
    // Extra fields in a swear / unlock are ignored; a price in the body does nothing (unlockEntry takes only the key).
    expect(rules.unlockEntry(s, vowKey('prelate_echo')).ok).toBe(false);
    expect(rules.swearVows(s, { elder_dead: 2, heat: -99, ashes: 9999 } as never).ok).toBe(false);
    // Fighting cold and swearing hot at the end does not pay: changing vows restarts the tally, and Ascend needs a Prelate kill.
    const hot = rules.swearVows(s, { elder_dead: 20 });
    expect(hot.ok).toBe(true);
    if (hot.ok) expect(rules.ascend(hot.state).ok).toBe(false);
    // The browser-save import brings rank across as Elder Dead, clamped, and never imports unlocks or shard-unlocked boons.
    const imp = rules.importLocal(rules.blankState(), { ascension: 99, boons: { bonded_dead: 1, vigil: 2 }, unlocks: ['vow:prelate_echo'], vows: { prelate_echo: 3 } });
    expect(imp.ok).toBe(true);
    if (imp.ok) {
      expect(imp.state.vows).toEqual({ elder_dead: 5 });
      expect(imp.state.boons).toEqual({ vigil: 2 });
      expect(imp.state.unlocks).toEqual([]);
    }
  });

  it('the shard-economy hoards of the live game can open everything', () => {
    const total = VOW_ORDER.reduce((n, id) => n + VOWS[id].unlockShards, 0) + BOON_ORDER.reduce((n, id) => n + BOONS[id].unlockShards, 0);
    expect(total).toBeLessThan(5000);
    expect(total).toBeGreaterThan(1500); // and it is still a goal for someone with ~400 shards
  });
});

describe('Vows in the world', () => {
  it('Elder Dead, Iron Dead and Swollen Waves change what spawns', () => {
    const base = new WorldSim(new Nav(), mulberry32(1));
    const hot = new WorldSim(new Nav(), mulberry32(1));
    hot.vows = { elder_dead: 2, iron_dead: 2 };
    const a = base.spawnEnemy('robber', 'graves', 0, -20, false, false);
    const b = hot.spawnEnemy('robber', 'graves', 0, -20, false, false);
    expect(b.level - a.level).toBe(6);
    // Level alone would raise health; Iron Dead adds its 50% on top of the aged dead's.
    const aged = new WorldSim(new Nav(), mulberry32(1));
    aged.vows = { elder_dead: 2 };
    const c = aged.spawnEnemy('robber', 'graves', 0, -20, false, false);
    expect(b.maxHp / c.maxHp).toBeCloseTo(1.5);
    expect(hot.ascension).toBe(4); // the world's rank is its heat
  });

  it('Thin Graves and Lingering Dead change how long a corpse lies', () => {
    const lifeOf = (vows: object, mult = 1) => {
      const sim = new WorldSim(new Nav(), mulberry32(1));
      sim.vows = vows;
      sim.corpseLifeMult = mult;
      const c = sim.addCorpse(0, 0, 'normal', 'robber', false, 0, 1, 'graves')!;
      return c.expiresAt - c.bornAt;
    };
    const normal = lifeOf({});
    expect(lifeOf({ thin_graves: 2 })).toBeCloseTo(normal * 0.5);
    expect(lifeOf({}, 1.5)).toBeCloseTo(normal * 1.5);
    expect(lifeOf({ thin_graves: 1 }, 1.5)).toBeCloseTo(normal * 0.75 * 1.5);
  });

  it('Deacon Host makes Deacons more of a wave and Bloodied Elites make more elites', () => {
    const count = (vows: object, def: string, seed = 5) => {
      const sim = new WorldSim(new Nav(), mulberry32(seed));
      sim.vows = vows;
      let n = 0;
      for (let i = 0; i < 400; i++) {
        const e = (sim as unknown as { spawnAtBreach: (...a: unknown[]) => { def: string; elite: boolean }[] }).spawnAtBreach('sanctum', 0, -100, false, [{ id: 'deacon', weight: 10 }, { id: 'penitent', weight: 30 }]);
        for (const x of e) if (def === 'elite' ? x.elite : x.def === def) n++;
      }
      return n;
    };
    expect(count({ deacon_host: 1 }, 'deacon')).toBeGreaterThan(count({}, 'deacon') * 1.5);
    expect(count({ elite_surge: 3 }, 'elite')).toBeGreaterThan(count({}, 'elite') + 20);
  });

  it('Swollen Waves bring more dead per wave', () => {
    const wave = (vows: object) => {
      const sim = new WorldSim(new Nav(), mulberry32(3));
      sim.vows = vows;
      sim.setPlayer({ id: 'p', x: 0, z: 0, alive: true, area: 'graves' });
      (sim as unknown as { spawnWave: (a: string, f?: boolean) => void }).spawnWave('graves', false);
      return sim.enemies.size;
    };
    expect(wave({ swollen_waves: 3 })).toBeGreaterThan(wave({}));
  });

  it('Bonded Dead raises one thrall from nothing, only when none stands', () => {
    const sim = new WorldSim(new Nav(), mulberry32(2));
    sim.setPlayer({ id: 'p1', x: 0, z: -20, alive: true, area: 'graves' });
    const bond = { t: 'exhume' as const, by: 'p1', x: 1, z: -20, r: 0.8, kind: 'warrior' as const, cap: 4, hp: 100, damage: 10, attackSpeedMult: 1, bond: true };
    sim.apply(bond);
    expect([...sim.thralls.values()].filter((t) => t.owner === 'p1').length).toBe(1);
    sim.apply(bond);
    expect([...sim.thralls.values()].filter((t) => t.owner === 'p1').length).toBe(1); // already has one
    expect(sim.corpses.size).toBe(0); // no corpse was needed or left
  });

  it('Prelate Echoes: a second bell, an elite procession, chasing rain', () => {
    const fight = (echoes: number) => {
      const sim = new WorldSim(new Nav(), mulberry32(7));
      sim.vows = { prelate_echo: echoes };
      sim.setPlayer({ id: 'p1', x: 0, z: -110, alive: true, area: 'sanctum', level: 20 });
      sim.apply({ t: 'summonBoss', by: 'p1' });
      const tolls: number[] = [];
      let rains = 0;
      let elites = 0;
      for (let i = 0; i < 60 * 30; i++) {
        sim.setPlayer({ id: 'p1', x: -6 + (i % 90) / 8, z: -108, alive: true, area: 'sanctum', level: 20 });
        for (const ev of sim.step(1 / 30)) {
          if (ev.t === 'boss' && ev.kind === 'toll') tolls.push(ev.ms ?? 0);
          if (ev.t === 'boss' && ev.kind === 'rain' && (ev.ms ?? 0) > 0) rains++;
        }
        sim.bossState.hp = sim.bossState.maxHp * (i > 600 ? 0.5 : 1);
      }
      for (const e of sim.enemies.values()) if (e.elite) elites++;
      return { tolls: tolls.length, rains, elites };
    };
    const none = fight(0);
    expect(fight(1).tolls).toBeGreaterThan(none.tolls);
    expect(fight(3).rains).toBeGreaterThan(fight(1).rains);
    expect(fight(2).elites).toBeGreaterThan(none.elites);
  });

  it('rides snapshots to guests, and an older host\'s plain rank is read as Elder Dead', () => {
    const old = new WorldSim(new Nav(), mulberry32(1));
    old.vows = { elder_dead: 2, deacon_host: 1 };
    const m = new WorldMirror();
    m.applySnapshot(makeSnapshot(old, true));
    expect(m.ascension).toBe(4);
    expect(m.vowFx.levels).toBe(6);
    expect(m.vowFx.deaconMult).toBe(2);
    const legacy = new WorldMirror();
    legacy.applySnapshot({ ...makeSnapshot(old, true), vows: undefined, ascension: 3 });
    expect(legacy.vows).toEqual({ elder_dead: 3 });
    const sim2 = new WorldSim(new Nav(), mulberry32(1));
    m.seed(sim2);
    expect(sim2.vows).toEqual({ elder_dead: 2, deacon_host: 1 });
  });
});

describe('Authority ceilings follow the vows', () => {
  it('a plain rank reads as Elder Dead steps; cooler vows never raise the ceiling; heat and older dead do', async () => {
    const { ceilingsFor } = await import('../authorityRules');
    const open = ['chapterhouse', 'graves', 'ossuary', 'nave', 'sanctum'];
    expect(ceilingsFor(open, 3, 30)).toEqual(ceilingsFor(open, { elder_dead: 3 }, 30));
    const none = ceilingsFor(open, {}, 30);
    expect(ceilingsFor(open, { frail_vessel: 3, dry_cellar: 1 }, 30).xpPerMin).toBeGreaterThanOrEqual(none.xpPerMin); // heat lifts the reward multiplier a little
    expect(ceilingsFor(open, { elder_dead: 6 }, 30).xpPerMin).toBeGreaterThan(none.xpPerMin);
    expect(ceilingsFor(open, { elder_dead: 20 }, 30).xpPerMin).toBeGreaterThan(ceilingsFor(open, { elder_dead: 6 }, 30).xpPerMin);
  });
});

describe('Boons that change how you play', () => {
  it('flatten into the effects the scene folds into the discipline', () => {
    const fx = boonEffects({ lingering_dead: 2, grave_feast: 2, bone_ward: 2, bonded_dead: 1, hollow_sacrifice: 1, carrion_bloom: 1 });
    expect(fx.corpseLifeMult).toBeCloseTo(2);
    expect(fx.corpseHeal).toBeCloseTo(0.06);
    expect(fx.wardPerThrall).toBeCloseTo(0.04);
    expect(fx.bondedDead && fx.sacrificeLeavesCorpse && fx.miasmaBurstsCorpses).toBe(true);
    const none = boonEffects({});
    expect(none.corpseLifeMult).toBe(1);
    expect(none.bondedDead).toBe(false);
  });

  it('the local Progression swears, unlocks and ascends like the server', async () => {
    const p = await fresh(42);
    p.local.shards = 650;
    expect(p.swearVows({ prelate_echo: 1 })).toBe(false); // locked
    expect(p.unlockAtAltar(vowKey('prelate_echo'))).toBe(true);
    expect(p.local.shards).toBe(650 - VOWS.prelate_echo.unlockShards);
    expect(p.unlockAtAltar(vowKey('prelate_echo'))).toBe(false);
    p.local.run = { prelateKills: 1, peakWaveTier: 0, kills: 50 };
    expect(p.vowsRestartRun({ prelate_echo: 2, elder_dead: 1 })).toBe(true);
    expect(p.swearVows({ prelate_echo: 2, elder_dead: 1 })).toBe(true);
    expect(p.heat).toBe(5);
    expect(p.local.run.kills).toBe(0);
    p.recordPrelateKill();
    const earned = p.ashesOnAscend();
    expect(earned).toBe(ashesForRun(p.local.run, 5));
    p.local.unlocked = ['chapterhouse', 'graves', 'ossuary'];
    expect(p.ascend()).toBe(earned);
    expect(p.local.ascension).toBe(5);
    expect(p.local.unlocked).toEqual(['chapterhouse', 'graves', 'ossuary']);
    expect(p.vows).toEqual({ prelate_echo: 2, elder_dead: 1 });
    // An old browser save (rank 2, no vows) loads as two steps of Elder Dead.
    expect(legacyVows(2)).toEqual({ elder_dead: 2 });
  });
});
