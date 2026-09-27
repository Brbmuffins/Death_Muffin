# Brief G0: gathering rules + server authority → branch `cloud/professions-g0`

Read `CLAUDE.md`, `HANDOFF.md`, `docs/DEATH-MUFFIN-HANDOFF.md`, **`docs/PROFESSIONS-ROADMAP.md`**
(§2, §4, §8, §9 are the spec), then `src/gameplay/necroRules.ts`, `tools/build-server-rules.mjs`,
`server/death-muffin/backend/server.js` (professions, recipes, craft, inventory routes),
`server/death-muffin/backend/migrations/001-discipline-index.sql`, `src/net/api.ts` and the DEV
offline mock in `src/net/`, and `src/content/items.ts`.

Build the contract every other gathering task uses. **Only** the Death Muffin backend
(`server/death-muffin/backend/`), never the original shared Crossworlds server.

1. **`src/gameplay/gatheringRules.ts`** (pure, DOM-free, no three.js): the node catalogue from roadmap
   §4 (`NodeType` id, skill, level, XP, `minActionMs`, success formula `(level − nodeLevel)` + tool tier,
   yields-before-depletion range, respawn, loot table with item ids and weights, rich-variant multipliers),
   the XP curve from §9 behind one exported `xpToNext(level)` (export both the live rule and the recommended
   curve; a single constant picks which one is active, **defaulting to the live `level × 50`** until the
   owner decides), and `rollGather(nodeType, level, rng)`. Bundle it for the server the way
   `necroRules.ts` is bundled (extend `tools/build-server-rules.mjs` or add a sibling), with a parity test.
2. **Migration `server/death-muffin/backend/migrations/002-gathering.sql`**, additive only: the new
   `items` rows (§4 ✱ ids, stackable, `max_stack_size` 250 for materials, sensible `sell_value`), new
   profession ids `gravedigging` and `gardening`, and `gather_ledger` for the time budget. Idempotent
   (`INSERT IGNORE`, `CREATE TABLE IF NOT EXISTS`). Also add each new id to `src/content/items.ts`,
   and extend the unit test that guards item ids.
3. **`POST /api/gather`** `{ characterId, nodeType, actions }`: ownership, level ≥ node level, time budget
   `actions ≤ floor((now − last) / minActionMs) + burst(3)`, then roll with the shared rules and grant
   the items and XP in one transaction. Reply `{ success, data: { skills, items: [{itemId, qty}], leveledUp } }`.
   Player-readable `error` strings (the UI shows them verbatim). Add `gravedigging`/`gardening` to
   `VALID_PROFESSION_IDS` and to the recipes `levels` defaults. **Disable `POST /api/professions/award-xp`
   for client use** (return an error), or restrict it; document which in the report.
4. **Client API + DEV mock**: `gather()` in `src/net/api.ts`, and the same route in the offline mock
   using the bundled rules, so `?offline` behaves like the server.
5. Tests: `node:test` for the route (ownership, level gate, budget refusal, ledger rollover, loot ids
   exist) using the in-memory store pattern from `server/vps-handoff/necro-progress/`, and vitest for
   the rules (rates stay within the §9 targets and every loot id is in `items.ts`).

Do NOT edit `src/scenes/**`, `src/graphics/**`, `src/ui/**` or `src/content/areas.ts`/`layout.ts`.
Write `server/death-muffin/GATHERING_DEPLOY.md` (backup, apply migration, copy backend, restart
`death-muffin-auth.service`, verify, rollback) but **do not deploy**. Keep `npm run typecheck && npm test
&& npm run test:server && npm run build` green. Commit on `cloud/professions-g0`; no PR, no merge.
Report: the contract (types + route shapes), files, test results, and any owner decisions you had to assume.
