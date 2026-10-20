# Shared game rules (server-side source of truth)

TypeScript rule modules (`gameplay/*Rules.ts`) and the content they read (`content/`, `types.ts`). They are not run
directly: `npm run build:server-rules` bundles each rule entry into the CommonJS files the live backend requires
(`server/death-muffin/backend/gathering/*-rules.cjs`, `server/vps-handoff/necro-progress/necro-rules.cjs`), and the
`tools/build-*-sql.mjs` / `tools/generate-necro-weapons.mjs` generators write the content migrations from `content/`.

The Godot client has its own GDScript port of these rules (`client/rules/`); a change here that players should see
needs the matching change there. Every rule module with a real GDScript counterpart is machine-checked against it by a parity fixture:
the vitest test builds a deterministic table of representative and edge inputs from the TypeScript, the committed
`client/tests/<suite>/fixtures/<name>_parity.json` must equal it (the test fails when it does not), and the Godot suite replays each case through
the port and compares (numbers within 1e-9). The loot roll is the strict case: `gameplay/lootRules.ts` must roll exactly what `client/rules/loot/loot.gd`
rolls from the same `dropStream` seed (server authority Phase 1: the server re-rolls a drop the client showed). Seeded rolls elsewhere use the same
stream on both sides (`DmDropStream`). After a deliberate change made on both sides, regenerate with
`UPDATE_<NAME>_PARITY=1 npx vitest run <test file>`; a failing Godot replay means the two sides really differ: decide which is right, never regenerate to make it pass.

| Fixture (`client/tests/<suite>/fixtures/`) | Test (`gameplay/__tests__/`) | `<NAME>` | GDScript port |
|---|---|---|---|
| `rules_loot/loot_parity.json` | `lootRules.test.ts` | `LOOT` | `rules/loot/loot.gd`, `drop_stream.gd` |
| `rules_loot/affix_parity.json` | `affixRules.parity.test.ts` | `AFFIX` | `rules/loot/affix_rules.gd` |
| `rules_combat/kill_parity.json` | `killRules.parity.test.ts` | `KILL` | `dm_enemy_stats.gd` (kill XP / gold, New Blood) |
| `rules_combat/legion_parity.json`, `runes_parity.json` | `legionRules.parity.test.ts` | `LEGION`, `RUNES` | `dm_legion.gd`, `dm_runes.gd` |
| `rules_combat/loadout_parity.json` | `loadoutRules.parity.test.ts` | `LOADOUT` | `net/offline/dm_offline_loadout.gd` |
| `rules_progression/xp_parity.json` | `killRules.parity.test.ts` | `XP` | `progression.gd` (level curve, `carry_xp` up to the 999 cap) |
| `rules_progression/necro_parity.json`, `upgrades_parity.json`, `kill_chain_parity.json` | `necroRules.parity.test.ts` | `NECRO`, `UPGRADES`, `KILL_CHAIN` | `necro_rules.gd`, `ascension.gd`, `DmUpgrades`, `kill_chain.gd` |
| `rules_gathering/{gather,salvage,gold_sink,labor,garden,contracts}_parity.json` | `gatheringRules.parity.test.ts` | `GATHER`, `SALVAGE`, `GOLD_SINK`, `LABOR`, `GARDEN`, `CONTRACTS` | `rules/gathering/*.gd` |
| `rules_gathering/vault_parity.json` | `vaultRules.parity.test.ts` | `VAULT` | `rules/inventory/vault_rules.gd` |
| `rules_gathering/cosmetics_parity.json` | `loadoutRules.parity.test.ts` | `COSMETICS` | `net/offline/dm_offline_cosmetics.gd` |

The shared pieces are `gameplay/__tests__/parity.ts` (case recorder and fixture check) and `dm_parity_part.gd` (the replay base, in the suites' shared test folder;
each suite's `parity_part.gd` maps a case's `fn` to its port). Rules with no GDScript counterpart (`multCaps`, `ceilingsFor`, the kill ledger)
are server-only. A case is never left out of a fixture: when the sides differ, fix the port (the TypeScript is the source of truth).

- Change a rule or content table here, then run `server/death-muffin/discord-agent/regen-godot.sh` (`npm run build:server-rules`, the armor-set generator and
  the loot rules' recorded answers) and commit what it changed; `node tools/build-server-rules.mjs --check` / the `--check` generators fail when a committed
  copy is stale, and CI runs them.
- Tests: `npm run test:rules` (unit) and `npm run test:server` (backend, includes the freshness checks).
