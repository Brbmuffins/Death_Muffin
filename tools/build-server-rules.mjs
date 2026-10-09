/**
 * Bundles the shared rule modules (+ the content they import) into plain
 * CommonJS files the Node backends can `require`:
 *   server/rules/gameplay/necroRules.ts    → server/vps-handoff/necro-progress/necro-rules.cjs
 *   server/rules/gameplay/gatheringRules.ts→ server/death-muffin/backend/gathering/gathering-rules.cjs
 * Run after changing prices, boons, Ascension, unlock thresholds or gathering nodes/XP:
 *   npm run build:server-rules
 * `--check` exits 1 if a committed copy is stale (the unit tests check this too).
 */
import { build } from 'esbuild';
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

const TARGETS = {
  necro: {
    entry: 'server/rules/gameplay/necroRules.ts',
    out: join(root, 'server/vps-handoff/necro-progress/necro-rules.cjs'),
    about: 'Necromancer progression rules shared by the web client and the auth server.',
  },
  gathering: {
    entry: 'server/rules/gameplay/gatheringRules.ts',
    out: join(root, 'server/death-muffin/backend/gathering/gathering-rules.cjs'),
    about: 'Gathering rules (nodes, XP curve, rolls, time budget) shared by the web client and the Death Muffin backend.',
  },
  garden: {
    entry: 'server/rules/gameplay/gardeningRules.ts',
    out: join(root, 'server/death-muffin/backend/gathering/garden-rules.cjs'),
    about: 'Grave Gardening rules (plots, growth, harvest rolls) shared by the web client and the Death Muffin backend.',
  },
  cosmetics: {
    entry: 'server/rules/gameplay/cosmeticRules.ts',
    out: join(root, 'server/death-muffin/backend/gathering/cosmetic-rules.cjs'),
    about: 'Capes and pets (unlock rules) shared by the web client and the Death Muffin backend.',
  },
  labor: {
    entry: 'server/rules/gameplay/laborRules.ts',
    out: join(root, 'server/death-muffin/backend/gathering/labor-rules.cjs'),
    about: 'Grave Laborers (thrall labour) rules shared by the web client and the Death Muffin backend.',
  },
  contracts: {
    entry: 'server/rules/gameplay/contractRules.ts',
    out: join(root, 'server/death-muffin/backend/gathering/contract-rules.cjs'),
    about: "Sexton's Contracts (the daily delivery board) shared by the web client and the Death Muffin backend.",
  },
  salvage: {
    entry: 'server/rules/gameplay/salvageRules.ts',
    out: join(root, 'server/death-muffin/backend/gathering/salvage-rules.cjs'),
    about: 'Salvaging (the Bone Grinder) yield rules shared by the web client, the offline mock and the Death Muffin backend.',
  },
  affix: {
    entry: 'server/rules/gameplay/affixRules.ts',
    out: join(root, 'server/death-muffin/backend/gathering/affix-rules.cjs'),
    about: 'Item level and affix rules (pool, rolls, validation, names, value) shared by the web client, the offline mock and the Death Muffin backend.',
  },
  authority: {
    entry: 'server/rules/gameplay/authorityRules.ts',
    out: join(root, 'server/death-muffin/backend/gathering/authority-rules.cjs'),
    about: 'Server authority plausibility numbers (XP/gold ceilings, ground-drop rates) shared by the Death Muffin backend and the tests.',
  },
  kills: {
    entry: 'server/rules/gameplay/killRules.ts',
    out: join(root, 'server/death-muffin/backend/gathering/kill-rules.cjs'),
    about: 'Server authority step 2: kill report validation and what a kill is worth, shared by the web client, the tests and the Death Muffin backend.',
  },
  vault: {
    entry: 'server/rules/gameplay/vaultRules.ts',
    out: join(root, 'server/death-muffin/backend/gathering/vault-rules.cjs'),
    about: 'Ossuary Vault (shared stash) move rules shared by the web client, the offline mock and the Death Muffin backend.',
  },
  legion: {
    entry: 'server/rules/gameplay/legionRules.ts',
    out: join(root, 'server/death-muffin/backend/gathering/legion-rules.cjs'),
    about: 'Legion kit (thrall gear) slots, eligibility and bonus rules shared by the web client, the offline mock and the Death Muffin backend.',
  },
  goldSinks: {
    entry: 'server/rules/gameplay/goldSinkRules.ts',
    out: join(root, 'server/death-muffin/backend/gathering/gold-sink-rules.cjs'),
    about: 'Gold sinks (affix reforge prices and rolls, Empowered boss summons and their prize) shared by the web client, the offline mock and the Death Muffin backend.',
  },
  runes: {
    entry: 'server/rules/gameplay/runeRules.ts',
    out: join(root, 'server/death-muffin/backend/gathering/rune-rules.cjs'),
    about: 'Relic rune sockets (slots, which rune fits which rite) shared by the web client, the offline mock and the Death Muffin backend.',
  },
  loadouts: {
    entry: 'server/rules/gameplay/loadoutRules.ts',
    out: join(root, 'server/death-muffin/backend/gathering/loadout-rules.cjs'),
    about: 'Loadout presets (validation, capture and apply over inventory rows) shared by the web client, the offline mock and the Death Muffin backend.',
  },
};

export const OUT = TARGETS.necro.out;
export const GATHER_OUT = TARGETS.gathering.out;

async function bundle(target) {
  const res = await build({
    entryPoints: [join(root, target.entry)],
    bundle: true,
    platform: 'node',
    format: 'cjs',
    target: 'node18',
    write: false,
    legalComments: 'none',
    banner: {
      js: `// GENERATED by tools/build-server-rules.mjs from ${target.entry} — do not edit by hand.\n// ${target.about}`,
    },
  });
  return res.outputFiles[0].text;
}

export const bundleRules = () => bundle(TARGETS.necro);
export const bundleGatheringRules = () => bundle(TARGETS.gathering);
/** Output path and freshly bundled text for any target (used by the freshness tests). */
export const bundleRulesFor = async (key) => ({ out: TARGETS[key].out, text: await bundle(TARGETS[key]) });

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  let stale = false;
  for (const target of Object.values(TARGETS)) {
    const text = await bundle(target);
    const name = target.out.slice(root.length + 1);
    if (process.argv.includes('--check')) {
      let current = '';
      try {
        current = readFileSync(target.out, 'utf8');
      } catch {
        /* missing counts as stale */
      }
      if (current !== text) {
        console.error(`${name} is stale — run \`npm run build:server-rules\``);
        stale = true;
      } else console.log(`${name} is up to date`);
    } else {
      writeFileSync(target.out, text);
      console.log(`wrote ${name} (${text.length} bytes)`);
    }
  }
  if (stale) process.exit(1);
}
