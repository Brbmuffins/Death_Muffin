import { describe, it } from 'vitest';
import { DIFFICULTY_ORDER } from '../../content/difficulty';
import { ENEMIES, type EnemyId } from '../../content/enemies';
import { killGoldMax, killXpBase } from '../killRules';
import { newBloodDamageMult, newBloodXpMult } from '../newBloodTuning';
import { LEVEL_CAP, splitXp, totalXp } from '../authorityRules';
import { checkParity, recorder } from './parity';

/**
 * What a kill pays and how the level curve runs: client/rules/combat/dm_enemy_stats.gd (kill_xp_base, kill_gold_max, new_blood_*) and
 * client/rules/progression/progression.gd (xp_to_next). Replayed by the Godot suites rules-combat (kill_parity.json) and
 * rules-progression (xp_parity.json). Regenerate: UPDATE_KILL_PARITY=1 / UPDATE_XP_PARITY=1 npx vitest run <this file>
 */
describe('kill reward parity', () => {
  it('kill_parity.json is current', () => {
    const r = recorder();
    const ids = Object.keys(ENEMIES) as EnemyId[];
    const levels = [1, 2, 5, 17, 40, 99, 250, 999];
    const tiers = [0, 1, 3, 7, 10, 25];
    let n = 0;
    for (const def of ids) {
      for (const diff of DIFFICULTY_ORDER) {
        for (const elite of [false, true]) {
          const level = levels[n % levels.length];
          const tier = tiers[(n * 7) % tiers.length];
          n++;
          r.add('killXpBase', [def, level, elite, tier, diff], () => killXpBase(def, level, elite, tier, diff));
          r.add('killGoldMax', [def, level, elite, tier, diff], () => killGoldMax(def, level, elite, tier, diff));
        }
      }
    }
    for (const level of levels) for (const tier of tiers) {
      r.add('killXpBase', [ids[0], level, false, tier, 'medium'], () => killXpBase(ids[0], level, false, tier, 'medium'));
    }
    for (const fam of ['necromancer', 'templar', 'ranger', 'anything']) {
      r.add('newBloodDamageMult', [fam], () => newBloodDamageMult(fam));
      for (const lv of [0, 1, 2, 7, 8, 14, 14.6, 15, 16, 200]) r.add('newBloodXpMult', [fam, lv], () => newBloodXpMult(fam, lv));
    }
    checkParity('rules-combat', 'kill', 'KILL', r.cases);
  });

  it('xp_parity.json is current', () => {
    const r = recorder();
    // The port: xp_to_next(level) = level x 100 and DmProgression.carry_xp (adopt_server_totals / add_xp), which from level 1 is splitXp.
    for (const level of [1, 2, 3, 10, 50, 99, 100, 255, 500, 998]) r.add('xpToNext', [level], () => totalXp(level + 1, 0) - totalXp(level, 0));
    const atCap = totalXp(LEVEL_CAP, 0);
    for (const total of [0, 1, 99, 100, 101, 299, 300, 301, 4950, 49500, 123456, 4_000_000, 49_000_000, totalXp(998, 0), totalXp(998, 99_000),
      atCap - 1, atCap, atCap + 1, atCap + LEVEL_CAP * 100 - 1, atCap + LEVEL_CAP * 100, atCap + 10_000_000, 2147483647]) {
      r.add('splitXp', [total], () => splitXp(total));
    }
    checkParity('rules-progression', 'xp', 'XP', r.cases);
  });
});
