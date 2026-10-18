import { describe, it } from 'vitest';
import { AREAS, AREA_ORDER } from '../../content/areas';
import { BOONS, BOON_ORDER, VOWS, VOW_ORDER, ascensionLevels, ascensionRewardMult, ashesForRun, boonBlocked, boonCost, boonEffects, isUnlocked, legacyVows, sanitizeVows, unlockCost, vowEffects, vowHeat, vowSteps, worldVows } from '../../content/ascension';
import { BOSS_IDS } from '../../content/bosses';
import { DAMAGE_UPGRADE, LEGION_UPGRADE, WAVE_UPGRADE, WAVE_MILESTONES, damageBonusPct, densityTier, milestoneActive, milestones, waveModifiers } from '../../content/upgrades';
import { CHAIN, KillChain } from '../killChain';
import {
  applySave, ascend, ashesOnAscend, blankState, buyBoon, damageCost, importLocal, legionCost, normalise, purchase, runHeat, summonAreaBoss, summonPrelate, swearVows,
  unlockEntry, unlockKills, waveCost, type NecroState,
} from '../necroRules';
import { checkParity, recorder } from './parity';

/**
 * The necromancer progression rules (client/rules/progression/necro_rules.gd), the Ascension / vow / boon tables they read
 * (ascension.gd), the upgrade price curves (progression/prog_content.gd, DmUpgrades) and the Kill Chain (kill_chain.gd).
 * Replayed by the Godot suite rules-progression (necro_parity.json, upgrades_parity.json, kill_chain_parity.json).
 * Regenerate: UPDATE_NECRO_PARITY=1 / UPDATE_UPGRADES_PARITY=1 / UPDATE_KILL_CHAIN_PARITY=1 npx vitest run <this file>
 */
function rng(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

describe('necromancer progression parity', () => {
  it('necro_parity.json is current', () => {
    const r = recorder();
    const rnd = rng(20261015);
    const int = (n: number) => Math.floor(rnd() * n);
    const pick = <T,>(l: readonly T[]): T => l[int(l.length)];
    const hunt = AREA_ORDER.filter((a) => !AREAS[a].safe);
    const keys = [...VOW_ORDER.map((v) => `vow:${v}`), ...BOON_ORDER.map((b) => `boon:${b}`), 'vow:nope', 'boon:nope', 'x', ''];
    const randVows = () => {
      const v: Record<string, number> = {};
      for (const id of VOW_ORDER) if (rnd() < 0.5) v[id] = int(VOWS[id].maxRank + 2) - (rnd() < 0.1 ? 3 : 0);
      return v;
    };
    const randBoons = () => {
      const b: Record<string, number> = {};
      for (const id of BOON_ORDER) if (rnd() < 0.5) b[id] = int(BOONS[id].maxRank + 1);
      return b;
    };
    const randState = (): NecroState => {
      const s = blankState();
      s.damageTier = int(27);
      s.waveTierOwned = int(10);
      s.waveTierActive = int(s.waveTierOwned + 1);
      s.legionTier = int(14);
      s.soulShards = int(900);
      for (const a of hunt) if (rnd() < 0.6) s.areaKills[a] = int(4000);
      s.unlockedAreas = ['chapterhouse', 'graves', ...AREA_ORDER.filter((a) => rnd() < 0.5 && a !== 'graves' && a !== 'chapterhouse')];
      s.bossKills = int(30);
      s.totalKills = int(40000);
      s.ascension = int(12);
      s.ashes = int(600);
      s.boons = randBoons();
      s.vows = sanitizeVows(randVows());
      s.unlocks = keys.filter((k) => unlockCost(k) && rnd() < 0.6);
      s.run = { prelateKills: int(5), peakWaveTier: int(10), kills: int(5000) };
      s.summonsPending = int(6);
      s.migrated = rnd() < 0.5;
      return s;
    };

    // Derived values on random states
    const states: NecroState[] = [blankState(), ...Array.from({ length: 24 }, randState)];
    for (const s of states) {
      r.add('damageCost', [s], () => damageCost(s));
      r.add('waveCost', [s], () => waveCost(s));
      r.add('legionCost', [s], () => legionCost(s));
      r.add('runHeat', [s], () => runHeat(s));
      r.add('ashesOnAscend', [s], () => ashesOnAscend(s));
      for (const a of AREA_ORDER) if (AREAS[a].unlock) r.add('unlockKills', [s, a], () => unlockKills(s, a));
    }
    r.add('unlockKills', [states[0], 'graves'], () => unlockKills(states[0], 'graves'));

    // Transitions: each case carries the whole input state, so the replay needs no history.
    const randOpts = () => (rnd() < 0.3 ? { staff: rnd() < 0.5, backed: Object.fromEntries(hunt.filter(() => rnd() < 0.4).map((a) => [a, int(300)])) } : undefined);
    const withOpts = (o: unknown) => (o === undefined ? undefined : o);
    for (let i = 0; i < 170; i++) {
      const s = i % 3 === 0 ? states[1 + (i % 24)] : randState();
      const opts = withOpts(randOpts());
      switch (i % 10) {
        case 0: case 1: {
          const input = { waveTierActive: rnd() < 0.7 ? int(12) - 1 : undefined, areaKills: Object.fromEntries([...hunt, 'chapterhouse'].filter(() => rnd() < 0.5).map((a) => [a, int(1200) - (rnd() < 0.05 ? 50 : 0)])), shards: int(60) - 5, prelateKills: int(14) - 2, peakWaveTier: int(14) };
          r.add('applySave', [s, input, opts ?? null], () => applySave(s, input, opts));
          break;
        }
        case 2: {
          const up = pick(['damage', 'wave', 'legion', 'bogus'] as const);
          const gold = pick([0, 39, 40, 120, 5000, 100000, 3_000_000]);
          r.add('purchase', [s, gold, up], () => purchase(s, gold, up));
          break;
        }
        case 3: r.add('summonPrelate', [s, opts ?? null], () => summonPrelate(s, opts)); break;
        case 4: {
          const boss = pick([...BOSS_IDS, 'nope', 7, null]);
          r.add('summonAreaBoss', [s, boss, opts ?? null], () => summonAreaBoss(s, boss, opts));
          break;
        }
        case 5: {
          const t = { ...s, run: { prelateKills: 1 + int(4), peakWaveTier: int(10), kills: int(5000) } };
          r.add('ascend', [t], () => ascend(t));
          break;
        }
        case 6: {
          const input = rnd() < 0.1 ? pick([null, [], 'x', { nope: 1 }]) : randVows();
          r.add('swearVows', [s, input], () => swearVows(s, input));
          break;
        }
        case 7: { const k = pick(keys); r.add('unlockEntry', [s, k], () => unlockEntry(s, k)); break; }
        case 8: { const b = pick([...BOON_ORDER, 'nope']); r.add('buyBoon', [s, b], () => buyBoon(s, b as never)); break; }
        default: {
          const raw = rnd() < 0.15 ? pick([null, 5, 'x', {}]) : {
            ascension: int(9), ashes: int(700), boons: randBoons(), damageTier: int(30), waveTierOwned: int(12), waveTierActive: int(12), shards: int(80),
            areaKills: Object.fromEntries(hunt.filter(() => rnd() < 0.6).map((a) => [a, int(30000)])), bossKills: int(300), totalKills: int(200000),
            run: { prelateKills: int(10), peakWaveTier: int(12), kills: int(9000) },
          };
          r.add('importLocal', [s, raw], () => importLocal(s, raw));
          const stored = i % 2 ? { ...s, vows: undefined, ascension: int(300), unlocks: [...s.unlocks, 'zzz'] } : raw;
          r.add('normalise', [stored], () => normalise(stored));
        }
      }
    }
    checkParity('rules-progression', 'necro', 'NECRO', r.cases);
  });

  it('upgrades_parity.json is current', () => {
    const r = recorder();
    const rnd = rng(77);
    const vowsFor = (): Record<string, number> => Object.fromEntries(VOW_ORDER.map((id) => [id, Math.floor(rnd() * (VOWS[id].maxRank + 2))]));
    for (const tier of [0, 1, 2, 5, 9, 12, 24, 25, 26, 27, 40]) {
      r.add('damageUpgradeCost', [tier], () => DAMAGE_UPGRADE.cost(tier));
      r.add('waveUpgradeCost', [tier], () => WAVE_UPGRADE.cost(tier));
      r.add('legionUpgradeCost', [tier], () => LEGION_UPGRADE.cost(tier));
    }
    for (const tier of [-1, 0, 0.5, 1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 27]) {
      r.add('damageBonusPct', [tier], () => damageBonusPct(tier));
      r.add('densityTier', [tier], () => densityTier(tier));
      r.add('waveModifiers', [tier], () => waveModifiers(tier));
      for (const m of WAVE_MILESTONES) r.add('milestoneActive', [m.id, tier], () => milestoneActive(m.id, tier));
      for (const max of [8, 12, 25]) r.add('milestones', [tier, max], () => milestones(tier, max));
    }
    for (let i = 0; i < 40; i++) {
      const v = vowsFor();
      if (i === 0) for (const k of Object.keys(v)) v[k] = 0;
      r.add('vowHeat', [v], () => vowHeat(v));
      r.add('sanitizeVows', [v], () => sanitizeVows(v));
      r.add('worldVows', [v], () => worldVows(v));
      r.add('vowEffects', [v], () => vowEffects(v));
      for (const id of VOW_ORDER) if (i < 3) r.add('vowSteps', [v, id], () => vowSteps(v, id));
    }
    for (const x of [-3, 0, 1, 2.9, 5, 12, 99, 1000]) {
      r.add('ascensionRewardMult', [x], () => ascensionRewardMult(x));
      r.add('ascensionLevels', [x], () => ascensionLevels(x));
      r.add('legacyVows', [x], () => legacyVows(x));
    }
    const unlockSets = [[], VOW_ORDER.map((v) => `vow:${v}`), BOON_ORDER.map((b) => `boon:${b}`)];
    for (let i = 0; i < 9; i++) {
      const ranks: Record<string, number> = Object.fromEntries(BOON_ORDER.map((b) => [b, Math.floor(rnd() * (BOONS[b].maxRank + 1))]));
      r.add('boonEffects', [ranks], () => boonEffects(ranks));
      for (const b of BOON_ORDER) {
        const best = Math.floor(rnd() * 8);
        const unl = unlockSets[i % 3];
        r.add('boonBlocked', [b, ranks, best, unl], () => boonBlocked(b, ranks, best, unl));
        r.add('boonCost', [b, ranks], () => boonCost(b, ranks));
      }
    }
    for (const k of [...unlockSets[1], ...unlockSets[2], 'vow:nope', 'x']) {
      r.add('unlockCost', [k], () => unlockCost(k));
      r.add('isUnlocked', [unlockSets[(k.length) % 3], k], () => isUnlocked(unlockSets[k.length % 3], k));
      r.add('isUnlocked', [unlockSets[1], k], () => isUnlocked(unlockSets[1], k));
    }
    for (const run of [{ prelateKills: 0, peakWaveTier: 5, kills: 900 }, { prelateKills: 1, peakWaveTier: 0, kills: 0 }, { prelateKills: 3, peakWaveTier: 12, kills: 8176 }, { prelateKills: 9, peakWaveTier: 8, kills: 99999 }]) {
      for (const heat of [-1, 0, 1, 4.7, 10, 40]) r.add('ashesForRun', [run, heat], () => ashesForRun(run, heat));
    }
    checkParity('rules-progression', 'upgrades', 'UPGRADES', r.cases);
  });

  it('kill_chain_parity.json is current', () => {
    const r = recorder();
    for (const n of [0, 1, 4, 5, 6, 11, 12, 24, 25, 44, 45, 79, 80, 500]) r.add('tierFor', [n], () => KillChain.tierFor(n));
    const rnd = rng(4242);
    for (let run = 0; run < 8; run++) {
      const ops: [string, number][] = [];
      let now = 1000;
      for (let i = 0; i < 60; i++) {
        now += Math.floor(rnd() * (rnd() < 0.08 ? 9000 : 1500));
        ops.push([rnd() < 0.75 ? 'hit' : rnd() < 0.7 ? 'tick' : rnd() < 0.5 ? 'frac' : 'reset', now]);
      }
      r.add('chainRun', [ops], () => {
        const kc = new KillChain();
        return ops.map(([op, t]) => {
          let out: unknown = null;
          if (op === 'hit') out = kc.hit(t);
          else if (op === 'tick') out = kc.tick(t);
          else if (op === 'frac') out = kc.frac(t);
          else kc.reset();
          return { out, count: kc.count, best: kc.best, mult: kc.mult, active: kc.active, tier: kc.tier, frac: kc.frac(t) };
        });
      });
    }
    void CHAIN;
    checkParity('rules-progression', 'kill_chain', 'KILL_CHAIN', r.cases);
  });
});
