# Server bug hunt — 2026-10-03 (branch `claude/server-bug-hunt`)

Scope: `server/death-muffin/backend/*.js|*.cjs` (+ `gathering/`) and `server/realtime/server.js`. Method: read every route, then for each real bug a
failing `node:test` first, then the smallest fix, one commit per bug. No migrations, no behaviour change to anything that is clearly intended.
Gates at the end: `npm ci` (root, `server/realtime`), `npm run test:server` (250 pass), `npm test` (1236 pass), `npx tsc --noEmit` — all green.
`npm run build:server-rules` leaves the tree clean (no server/client rule drift).

New test helper: `server/death-muffin/backend/server-harness.cjs` loads `server.js` with express / mysql2 / jwt / bcrypt stubbed, so routes that live in
`server.js` itself (previously untested) can be called without a database. Its tests are `server-routes.test.cjs` (added to `npm run test:server`).

## Fixed

| # | Bug | Severity | Where | Fix commit |
|---|-----|----------|-------|------------|
| 1 | A `null` payload on `world:join` / `player:move` crashed the whole realtime service: `inWorld(null)` was true (`Number(null) === 0`), the handler then read `null.x`, and an exception in a socket.io listener is uncaught. Any logged-in player could drop every world. | **High** (remote DoS) | `server/realtime/server.js` `inWorld`, `io.on('connection')` | `284a3dc` (also wraps every listener so one bad message is logged and dropped) |
| 2 | A host snapshot with a non-array enemy/thrall row threw inside the per-guest interest filter (same crash path, needs two accounts). | Medium | `snapshotFor` | `991e9ec` |
| 3 | `/api/craft` proved ownership of `parseInt(characterId)` but then queried with the **raw** body value. `"1e1"` parses to the caller's character 1 while MySQL reads the string as 10, so a player could burn another player's materials and credit them the result and profession XP. | **High** (cross-account) | `server.js` POST `/api/craft` | `e261289` |
| 4 | `/api/gold/adjust` let any player credit any amount (bypassing the plausibility guard on `save-progress`, even in enforce mode), and its read-modify-write lost updates and could push gold past the 32-bit column. Crediting is now staff-only; the update runs under the character row lock and is bounded. | **High** | `server.js` | `a0f0c8d` |
| 5 | `save-progress`: `Number(null)`, `Number('')`, `Number([])`, `Number(false)` are 0, so a client NaN (serialised as `null`) wrote 0 to gold, XP, level or a stat. | Medium (data loss) | `server.js` `bounded()` | `8fd8938` |
| 6 | `loot/roll` and `loot/drop` looked for a free slot in 0–199, so with a full 48-slot bag a drop landed in the reserved equipment/belt/kit/rune range (100–134) where bag saves never see it. | Medium | `server.js` `rollDbLoot`, `loot/roll` | `36c73f9` |
| 7 | `inventory/save`: `slots: [null]` (or no JSON body) threw before the handler's `try` (bare 500). `parseInt` let `5.5` and `'5abc'` pass the duplicate check although MySQL rounds the first to slot 6 and rejects the second. Now a readable 400. | Low–Medium | `inventory-save.cjs` `slotProblem`, `server.js` | `8fc0024` |
| 8 | Body over the 512 KB limit produced Express's HTML 413 (the client shows server error strings verbatim and cannot parse HTML); anything thrown outside a route's `try` produced an HTML 500 with a full stack in the journal. Both now answer JSON with a one-line log. | Low | `server.js` error handlers | `94f079e` |
| 9 | `GET /character` normalised leftover XP into levels with no cap: a saved row with `experience` up to 2^31 became level ~6,300 (the column/every other path caps at 255), so the character could no longer load. | Low (self-inflicted brick) | `normalizeCharacterProgress` | `11d235a` |
| 10 | `POST /character` signed the character token with `expiresIn: process.env.JWT_EXPIRES_IN`; jsonwebtoken rejects `undefined`, so an `.env` without it made every character create/select a 500. Defaults to `24h` like `/login`. | Low (config fragility) | `server.js` | `2a940a2` |
| 11 | `PATCH /character/position` only rejected `NaN`; `Infinity` / `1e30` reached the DB and failed there (500). Now a 400 (finite, \|v\| < 100000, same bound as the offline import). | Low | `server.js` | `cfead39` |
| 12 | With `AUTHORITY_MODE=enforce`, `combat/kill`, `loot/roll` and `loot/drop` still paid XP, gold or items for an enemy instance id the client makes up (`combat/hit` records any id), at HTTP speed — a hole next to the guarded `save-progress`. Enforce mode now restricts them to staff; **report mode is unchanged**. The browser never calls them. | Medium (enforce-mode bypass) | `server.js` `legacyRewardAllowed` | `ef304ba` |
| 13 | The `[refused]` journal line only saw 4xx. Most module routes (vault, salvage, belt, kit, rune, garden, labor, cosmetics, contracts, roll-gear) refuse a player with `200 { success:false, error }`, so those refusals were invisible. | Logging gap | `server.js` logging middleware | `2c705d9` |

Not bugs (checked): no `LIMIT ?` is bound through `execute()` anywhere (all LIMITs are literals or go through `query()`); the generated
`*-rules.cjs` match `src/` (`npm run build:server-rules` is a no-op; `SIGNATURES`, `INTENT_TYPES`, `BOSS_IDS` in the realtime service match `sim/types.ts` and
`content/bosses.ts`); every module route (`vault`, `salvage`, `runes`, `tool-belt`, `thrall-kit`, `contracts`, `garden`, `labor`, `cosmetics`, `chronicle`,
`loot`, `gathering`) uses the parsed, ownership-checked id; vault/salvage/craft/garden/labor/contracts run in one transaction with the rows `FOR UPDATE`
and refuse the whole action when the result will not fit; chat is rendered with `textContent`.

## Suspected, not confirmed (need a database or an owner decision)

1. **Banned/deactivated accounts keep working for up to 24 h.** `/login` checks `accounts.active`; `requireJWT`, `verifyJWT` and the realtime handshake do not.
   Fix would be an `active` check in `verifyJWT` (it already reads `accounts`) and a cached check in `requireJWT`/realtime. Left alone: costs a query per request.
2. **Possible relic duplication across routes.** `replaceBag` (bag save) reads the bag rows without a lock, and `resolveInstances` checks `inventory` / `account_vault`
   with plain reads, while vault deposit/withdraw lock only the bag and vault rows. A tampered client firing a vault deposit and a bag save naming the same
   `instance_id` at once could, in theory, leave the instance in both. The honest client serialises with `Inventory.exclusive()`. A cheap hardening is
   `SELECT id FROM characters WHERE id = ? FOR UPDATE` as the first statement of every bag mutator (bag save, vault, salvage, craft, belt/kit/rune). Not provable without MySQL.
3. **Chronicle counters are cosmetic but unbounded**: `chronicle/add` keeps summing (50 M per key per call), and an offline import stores `chronicle.life` unchecked
   (only size-limited), so the public leaderboard's `playSeconds` / `bestDepth` can be forged. `kills.alchemist_wing` is not in `SUM_KEYS` and is dropped silently.
4. **`combat/kill` uses a different XP curve** (`100·(L+1)^1.5`) from `characterXpToNext` (`100·L`). Dormant for players now that enforce mode closes it;
   if the route is ever reopened it must use `characterXpToNext`.
5. **Realtime has no per-account/IP connection cap**; a player can open many sockets and many private worlds (each is freed when its players leave).
6. `/api/inventory/add-item` and the bag save still let a player introduce any item in **report** mode — known and documented ("client-authoritative by design").
7. `/api/inventory/equip` treats any truthy `equipped` (e.g. the string `"false"`) as true; the real client sends booleans.
8. Per-character rate-limiter maps in `gathering-routes.cjs` and `necro-progress-routes.cjs` keep one array per character id for the process lifetime (a few bytes each).
9. `level`/`experience` column widths are not in the repo (no base schema); the 255 cap assumes the columns hold it, as the other save paths already do.

No migration is required by any fix above.
