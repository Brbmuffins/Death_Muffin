/**
 * Boss report: `npm run balance:boss`. One row per boss x band x discipline x weapon x dodge,
 * averaged over seeds. Targets live in BALANCE.md.
 *
 * Env: BALANCE_SEEDS=3, BALANCE_BANDS=intended,geared, BALANCE_DISCIPLINES=1,3,
 *      BALANCE_BOSS=prelate|all|id,id (or `-- --boss abbess`), BALANCE_KIT=none|progress|typical|ascended|auto,
 *      BALANCE_WEAPONS=kit,staff,scythe,wand,sickle (main-hand worn instead of the discipline's own; `kit` = its own; needs a kit other than none),
 *      BALANCE_DODGE=yes,no, BALANCE_LEGENDARY=1 (the discipline's full legendary set bonus folded on top of the kit).
 */
import { AREAS } from '../../content/areas';
import { runBossFight, type BossResult, type BossRun } from './boss';
import type { Difficulty } from '../../content/difficulty';
import { ascensionLevels } from '../../content/ascension';
import { KIT_NAMES, type KitName } from './kits';
import { BOSSES, BOSS_IDS, isBossId, type BossId } from '../../content/bosses';
import { FULL_SETS } from './legendaryFull';
import { NECRO_MAIN_KINDS, type NecroMainKind } from '../../content/necroWeapons';

/** `npm run balance:boss -- --boss abbess` (or BALANCE_BOSS=abbess, =all, =abbess,mire); default the Prelate. */
const list = (v: string | undefined) => (v ? v.split(',').map((s) => s.trim()) : null);
const argIdx = process.argv.indexOf('--boss');
const bossSpec = argIdx >= 0 ? process.argv[argIdx + 1] : process.env.BALANCE_BOSS;
const BOSS_LIST: BossId[] = bossSpec === 'all' ? [...BOSS_IDS] : (list(bossSpec) ?? ['prelate']).filter(isBossId);
if (!BOSS_LIST.length) throw new Error(`BALANCE_BOSS must be all or boss ids (${BOSS_IDS.join(', ')})`);

/** Gear kit worn (BALANCE_KIT=none|progress|typical|ascended; `auto` = progress at intended, typical at geared). */
const KIT = process.env.BALANCE_KIT ?? 'none';
if (KIT !== 'auto' && !KIT_NAMES.includes(KIT as KitName)) throw new Error('BALANCE_KIT must be auto or a kit name');
const kitFor = (band: string): KitName => (KIT === 'auto' ? (band === 'intended' ? 'progress' : 'typical') : (KIT as KitName));
const WEAPONS = list(process.env.BALANCE_WEAPONS) ?? ['kit'];
for (const w of WEAPONS) if (w !== 'kit' && !(NECRO_MAIN_KINDS as readonly string[]).includes(w)) throw new Error(`BALANCE_WEAPONS entries must be kit or ${NECRO_MAIN_KINDS.join('|')}`);
const DODGES = (list(process.env.BALANCE_DODGE) ?? ['yes', 'no']).map((d) => d === 'yes');
const DIFFICULTY = (process.env.BALANCE_DIFFICULTY ?? 'medium') as Difficulty;
/** World Ascension rank; bands then anchor on the aged area level. */
const ASC = Math.max(0, Number(process.env.BALANCE_ASCENSION ?? 0));
const LEGENDARY = !!process.env.BALANCE_LEGENDARY;
const SEEDS = Math.max(1, Number(process.env.BALANCE_SEEDS ?? 3));
const disciplines = (list(process.env.BALANCE_DISCIPLINES) ?? ['1', '2', '3', '4']).map(Number);
const names: Record<number, string> = { 1: 'Ossuary', 2: 'Gravecaller', 3: 'Mourner', 4: 'Rotweaver' };

/** Same bands as the farming report, anchored on the boss area's level. */
const bandsFor = (L: number): Record<string, Omit<BossRun, 'classIndex' | 'dodge'>> => ({
  intended: { level: L, damageTier: Math.round(L * 0.6), gearStats: Math.round(L * 0.8) },
  geared: { level: L + 3, damageTier: Math.round(L * 0.9), gearStats: L },
});
const bandNames = list(process.env.BALANCE_BANDS) ?? ['intended', 'geared'];

const cols: [string, number][] = [
  ['boss', 13], ['band', 9], ['disc', 12], ['weapon', 8], ['dodge', 6], ['wins', 6], ['deaths', 7], ['time s', 7], ['P2 s', 6], ['P3 s', 6], ['boss%', 6],
  ['dps', 6], ['hurt%/m', 8], ['boss dmg%', 10], ['adds%', 6], ['minHp', 6], ['flasks', 7], ['barrier%', 9], ['wade%', 7], ['rooted s', 8],
];
const pad = (s: string | number, n: number) => String(s).padEnd(n);
const avg = (rs: BossResult[], f: (r: BossResult) => number) => rs.reduce((s, r) => s + f(r), 0) / rs.length;
const avgPhase = (rs: BossResult[], f: (r: BossResult) => number) => {
  const hit = rs.map(f).filter((x) => x >= 0);
  return hit.length ? (hit.reduce((a, b) => a + b, 0) / hit.length).toFixed(0) : '-';
};
const rows: string[] = [cols.map(([h, n]) => pad(h, n)).join('')];
const maxHps: string[] = [];
for (const boss of BOSS_LIST) {
  const bands = bandsFor(AREAS[BOSSES[boss].area].level + ascensionLevels(ASC));
  for (const band of bandNames) {
    for (const classIndex of disciplines) {
      for (const weapon of WEAPONS) {
        for (const dodge of DODGES) {
          const kit = kitFor(band);
          const kitOverride = weapon === 'kit' ? undefined : { main: weapon as NecroMainKind };
          const rs = Array.from({ length: SEEDS }, (_, i) => runBossFight({ ...bands[band], kit, kitOverride, ...(LEGENDARY ? { effect: FULL_SETS[classIndex].effect } : {}), classIndex, dodge, difficulty: DIFFICULTY, seed: 42 + i, ascension: ASC, boss }));
          if (!maxHps.some((m) => m.startsWith(boss))) maxHps.push(`${boss} ${Math.round(rs[0].bossMaxHp)}`);
          const wins = rs.filter((r) => r.outcome === 'win');
          const cells = [
            boss, band, names[classIndex], weapon, dodge ? 'yes' : 'no', `${wins.length}/${SEEDS}`, `${rs.filter((r) => r.outcome === 'wipe').length}/${SEEDS}`,
            wins.length ? avg(wins, (r) => r.seconds).toFixed(0) : '-',
            avgPhase(rs, (r) => r.phase2At), avgPhase(rs, (r) => r.phase3At),
            avg(rs, (r) => r.bossHpLeftPct).toFixed(0), avg(rs, (r) => r.dps).toFixed(0),
            avg(rs, (r) => r.dmgPctPerMin).toFixed(0), avg(rs, (r) => r.bySource.prelate ?? 0).toFixed(0),
            avg(rs, (r) => r.bySource.adds ?? 0).toFixed(0), Math.min(...rs.map((r) => r.minHpPct)).toFixed(0),
            avg(rs, (r) => r.flasksUsed).toFixed(1), avg(rs, (r) => r.barrierAbsorbedPct).toFixed(0), avg(rs, (r) => r.wadingPct).toFixed(0), avg(rs, (r) => r.rootedS).toFixed(1),
          ];
          rows.push(cells.map((c, i) => pad(c, cols[i][1])).join(''));
        }
      }
    }
  }
}
console.log(`\nBoss report: ${SEEDS} seed(s) per row, solo, difficulty ${DIFFICULTY}, ascension ${ASC}, kit ${KIT}${LEGENDARY ? ' + full legendary set' : ''}; boss max HP: ${maxHps.join(', ')}`);
console.log('time s = average kill time of winning runs · deaths = runs ending in a wipe (a solo death resets the boss) · boss% = HP left (avg) · boss dmg%/adds% = damage taken as % of max HP over the fight · barrier% = Litany barrier soaked, % of max HP (Reliquary sets) · wade% = share of the fight slowed by open water · rooted s = seconds rooted by hands / grasps / burial\n');
console.log(rows.join('\n'));
