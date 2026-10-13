# Shared game rules (server-side source of truth)

TypeScript rule modules (`gameplay/*Rules.ts`) and the content they read (`content/`, `types.ts`). They are not run
directly: `npm run build:server-rules` bundles each rule entry into the CommonJS files the live backend requires
(`server/death-muffin/backend/gathering/*-rules.cjs`, `server/vps-handoff/necro-progress/necro-rules.cjs`), and the
`tools/build-*-sql.mjs` / `tools/generate-necro-weapons.mjs` generators write the content migrations from `content/`.

The Godot client has its own GDScript port of these rules (`godot/rules/`); a change here that players should see
needs the matching change there. The loot roll is the strict case: `gameplay/lootRules.ts` must roll exactly what `godot/rules/loot/loot.gd`
rolls from the same `dropStream` seed (server authority Phase 1: the server re-rolls a drop the client showed). Its test writes
`godot/tests/rules-loot/fixtures/loot_parity.json`, which the Godot suite `rules-loot` replays; after a deliberate loot change on both sides,
regenerate it with `UPDATE_LOOT_PARITY=1 npx vitest run server/rules/gameplay/__tests__/lootRules.test.ts`.

- Change a rule or content table here, then `npm run build:server-rules` (and the matching SQL generator) and commit
  both; `node tools/build-server-rules.mjs --check` / the `--check` generators fail when a committed copy is stale.
- Tests: `npm run test:rules` (unit) and `npm run test:server` (backend, includes the freshness checks).
