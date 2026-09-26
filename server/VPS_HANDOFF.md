# VPS handoff — server storage for necromancer progression (incl. Ascension)

**Audience:** a Claude Code session running on the VPS (`playcrossworlds.com`) with shell access.
**Written:** 2026-09-26 from the web-client repo (branch `claude/adoring-knuth-hd1uox`).
**Scope:** progression + Ascension storage ONLY. Web/realtime deploys, relic runes and anti-cheat
hardening are separate (pointers at the end).

---

## 0. Ground rules (read first)

- This is **production**: real accounts, real characters, real gold. Follow `SERVER_OPERATIONS.md`
  ("Safe deploy procedure") from the web repo. Before any change on the box: show the exact diff /
  new files, the exact commands, the backup you took and the rollback — and **wait for the user's
  go-ahead**. After deploying, show `systemctl status` and the last 20 log lines.
- **Additive only.** New table, new files, new `/api/necro-progress/*` routes. Never edit existing
  routes or `/opt/rod-auth/.env`. The only edit to an existing file is ~10 lines in
  `/opt/rod-auth/server.js` that `require` and mount the new module (backed up first).
- **Never hand-edit `necro-rules.cjs`.** It is generated from the client's `src/gameplay/necroRules.ts`
  (`npm run build:server-rules` in the web repo). If a rule must change, change it in the web repo,
  regenerate, and copy the new file over — otherwise client and server disagree.
- Player-facing `error` strings are shown verbatim by the client — keep them readable.

## 1. What you're installing

From the web repo, `server/vps-handoff/necro-progress/`:

| File | Goes to | What it is |
|---|---|---|
| `necro-rules.cjs` | `/opt/rod-auth/necro-progress/` | Generated game rules: prices, unlock thresholds, Ascension, boons, import clamps. Pure functions, no deps. |
| `necro-progress-routes.cjs` | same | `mountNecroProgress(app, { store, requireAuth, ownsCharacter })` — the 7 routes, auth/ownership/rate-limit, one locked transaction per mutation. |
| `mysql-store.cjs` | same | `createMysqlStore(pool, { charactersTable, idColumn, goldColumn })` — row-locked transactions (`SELECT … FOR UPDATE` on the character and its progress row). Also `createMemoryStore` for tests. |
| `schema.sql` | run once | `character_necro_progress` (JSON `state` + generated `ascension`/`boss_kills`/`total_kills` columns). |
| `necro-progress.test.cjs` | same (optional) | `node --test` suite against the memory store — no Express/MySQL needed. |

Design decisions already made with the user:
- **Validated endpoints**: the server owns prices and rules (purchase, summon, Ascend, boons);
  kills/shards arrive as clamped deltas; seals are derived from kills, never trusted.
- **Browser saves are imported once** (clamped hard), then the server wins.
- Gold stays in the existing characters table. `purchase` deducts it inside the same transaction.

## 2. Recon (read-only — report findings before changing anything)

In `/opt/rod-auth/server.js` (and whatever it requires), find and write down:

1. The Express app variable and where routes are registered.
2. The JWT middleware used by the existing `/api/*` routes (e.g. `authenticateToken`, `requireAuth`)
   and what it puts on `req` (e.g. `req.user.id`, `req.userId`, `req.account`).
3. The DB client: `mysql2/promise` pool? `mysql2` callback pool? `mysql`? Find the variable name.
4. The characters table: its name, primary key column and type (`INT` vs `INT UNSIGNED`), the gold
   column, and the column that links a character to its account (e.g. `user_id`, `account_id`).
5. How an existing route checks that a character belongs to the caller (copy that logic).
6. Node version (`node -v`; the modules need ≥ 18) and the systemd unit name (`crossworlds-auth`?).

## 3. Backup

```bash
TS=$(date +%s)
sudo cp /opt/rod-auth/server.js /opt/rod-auth/server.js.bak.$TS
mysqldump -u rodgame -p"$(grep DB_PASS /opt/rod-auth/.env | cut -d= -f2)" rod_online > ~/rod_online.pre-necro.$TS.sql
ls -la /opt/rod-auth/server.js.bak.$TS ~/rod_online.pre-necro.$TS.sql
```

## 4. Schema

Open `schema.sql`. Make `character_necro_progress.character_id` match the characters PK **exactly**
(type and signedness) and point the FK at the real table/column — or delete the `CONSTRAINT` line
(the routes check the character exists in every transaction anyway). Then:

```bash
mysql -u rodgame -p"$(grep DB_PASS /opt/rod-auth/.env | cut -d= -f2)" rod_online < schema.sql
mysql … rod_online -e "SHOW CREATE TABLE character_necro_progress\G"
```
Needs MySQL ≥ 5.7.8 (JSON + generated columns). On MariaDB, JSON is an alias of LONGTEXT; the generated
columns may need `JSON_VALUE(state,'$.ascension')` — adjust and note it.

## 5. Install and mount

```bash
sudo mkdir -p /opt/rod-auth/necro-progress
# copy the four .cjs files + schema.sql into it (scp/sftp from the web repo checkout)
cd /opt/rod-auth/necro-progress && node --test necro-progress.test.cjs   # expect: pass 8, fail 0
```

Add to `/opt/rod-auth/server.js`, **after** the app, the DB pool and the JWT middleware exist and
**before** any catch-all/404 handler (names below are placeholders — use what recon found):

```js
// --- Necromancer progression (additive; see necro-progress/) ---
const { mountNecroProgress } = require('./necro-progress/necro-progress-routes.cjs');
const { createMysqlStore } = require('./necro-progress/mysql-store.cjs');
mountNecroProgress(app, {
  store: createMysqlStore(promisePool, { charactersTable: 'characters', idColumn: 'id', goldColumn: 'gold' }),
  requireAuth: authenticateToken,
  ownsCharacter: async (req, characterId) => {
    const [rows] = await promisePool.query('SELECT 1 FROM characters WHERE id = ? AND user_id = ?', [characterId, req.user.id]);
    return rows.length > 0;
  },
});
```

DB client notes:
- `mysql2` callback pool → pass `pool.promise()`.
- `mysql` (callback) package → either create a small `mysql2/promise` pool with the same credentials
  from `.env` just for these routes (`npm i mysql2` in `/opt/rod-auth`), or write an adapter whose
  `getConnection()` resolves to an object with promise `beginTransaction/query/commit/rollback/release`
  where `query()` resolves to `[rows]`. Prefer the first.
- The JSON body parser (`express.json()`) must already run before these routes (it does for existing `/api/*` POSTs — confirm).

Then: `node -e "require('/opt/rod-auth/server.js')"` is NOT a safe syntax check (it would start the
server) — use `node --check /opt/rod-auth/server.js`, then restart:

```bash
sudo systemctl restart crossworlds-auth
sudo systemctl status crossworlds-auth --no-pager
sudo journalctl -u crossworlds-auth -n 30 --no-pager
curl -s http://localhost:3000/api/health
```

## 6. Verify with a test account

Use an account from the user's `TEST_ACCOUNTS.local.md` (ask the user; never create characters on real
player accounts). Get a token via `POST /login`, find its character id via `GET /character`, then:

```bash
T=<jwt>; C=<characterId>; H=(-H "Authorization: Bearer $T" -H 'Content-Type: application/json')
curl -s "${H[@]}" localhost:3000/api/necro-progress/$C                                  # blank record, migrated:false
curl -s "${H[@]}" -X POST localhost:3000/api/necro-progress/import -d "{\"characterId\":$C,\"record\":{\"areaKills\":{\"graves\":310},\"shards\":2}}"
curl -s "${H[@]}" -X POST localhost:3000/api/necro-progress/save   -d "{\"characterId\":$C,\"areaKills\":{\"graves\":5},\"shards\":1}"
curl -s "${H[@]}" -X POST localhost:3000/api/necro-progress/purchase -d "{\"characterId\":$C,\"upgrade\":\"damage\"}"   # deducts gold if the character has ≥ 40
curl -s "${H[@]}" -X POST localhost:3000/api/necro-progress/import -d "{\"characterId\":$C,\"record\":{}}"             # 400: already imported
curl -s "${H[@]}" localhost:3000/api/necro-progress/999999                              # 403/404, never another player's data
```
Expected: `{ "success": true, "data": { "progress": {…}, "gold": … } }`; the Ossuary unlocked after
310+ Graves kills; the purchase moved gold in the characters table (`SELECT gold …`) and the tier in
`character_necro_progress`. Check `SELECT character_id, ascension, boss_kills, total_kills, updated_at
FROM character_necro_progress;`.

## 7. The client side (already written — nothing to code on the server)

The web client on this branch (`src/gameplay/progression.ts`) detects the routes: `GET
/api/necro-progress/:id` → 404 means "keep browser storage", success means server mode. On first
contact it POSTs the browser save to `/import` once, then adopts the server state; afterwards every
change is applied optimistically and reconciled with the server's reply. Gold stays client-
authoritative: before a purchase the client sends `save-progress` with its pre-purchase gold so the
server can charge it. **Players only get this once the web client from this branch is deployed**
(`server/web-deploy/README.md`) — tell the user; deploying it is a separate step they run.

The DEV offline mock (`src/net/mockBackend.ts`) serves the same routes from the same rules, so the
client flow can be tested without the VPS: `http://localhost:5188/?offline`.

## 8. API reference

All routes: JWT required, `characterId` must belong to the caller, 60 requests/min/character.
Success `200 { success: true, data: { progress, gold?, earned?, cost? } }`;
failure `400/403/404/429/500 { success: false, error }` (player-readable).

| Route | Body | Rule |
|---|---|---|
| `GET /api/necro-progress/:characterId` | — | Load (creates a blank row on first sight). Returns gold too. |
| `POST /api/necro-progress/save` | `{ characterId, areaKills?, shards?, prelateKills?, peakWaveTier?, waveTierActive? }` | Deltas since the last save. ≤ 900 kills and ≤ 30 shards per call; kills only in unlocked, unsafe areas; a Prelate kill needs a paid summon; seals derived from kills. Never fails on bad input (clamps). |
| `POST /api/necro-progress/purchase` | `{ characterId, upgrade: 'damage' \| 'wave' }` | Server price (Bone Tithe / Quickened Coin boons apply), gold deducted in the same transaction. `Not enough gold (need N)`, `Already at max tier`. |
| `POST /api/necro-progress/summon-prelate` | `{ characterId }` | −5 shards, +1 pending summon. Needs the Sanctum open. |
| `POST /api/necro-progress/ascend` | `{ characterId }` | Needs a Prelate kill this run. Resets tiers/shards/kills/seals, +rank, +Ashes, applies starting boons. Returns `earned`. |
| `POST /api/necro-progress/boon` | `{ characterId, boonId }` | Costs Ashes; rank gates; max ranks. |
| `POST /api/necro-progress/import` | `{ characterId, record }` | One time only (then 400). Everything clamped: tiers ≤ max, shards ≤ 40, kills ≤ 20000/area, Prelate kills ≤ 200, Ascension ≤ 5, Ashes ≤ 400, boons validated against rank gates; seals re-derived. |

State document (`character_necro_progress.state`): `damageTier, waveTierOwned, waveTierActive,
soulShards, areaKills{area:n}, unlockedAreas[], bossKills, totalKills, ascension, ashes, boons{id:rank},
run{prelateKills, peakWaveTier, kills}, summonsPending, migrated`.

## 9. Rollback

```bash
sudo cp /opt/rod-auth/server.js.bak.<TS> /opt/rod-auth/server.js
sudo systemctl restart crossworlds-auth && curl -s http://localhost:3000/api/health
# optional — the table is harmless if left:  mysql … rod_online -e "DROP TABLE character_necro_progress;"
```
Clients fall back to browser storage automatically when the routes 404. Players who already migrated
keep playing from their browser cache (it mirrors the last server state).

## 10. Report back

When done, tell the user (they relay it to the web repo's HANDOFF.md): the recon findings (§2),
any schema/adapter changes you made, test + curl output, and the service status. If anything in the
rules looks wrong, report it — don't patch `necro-rules.cjs` on the box.

## Out of scope here (separate handoffs)

- **Web client + realtime deploy**: `server/web-deploy/README.md`, `server/realtime/DEPLOY.md`. This
  branch adds realtime protocol fields (`signature` intents, `hit.bleed` clamp, `difficulty` and
  `ascension` in snapshots) — deploy client and realtime together.
- **Relic runes**: `server/proposals/relic-runes.md`.
- **Anti-cheat**: `save-progress` accepts absolute gold/XP from the client and `inventory/save` grants
  items the client names. A modified client can still mint gold and loot; closing that needs
  server-side reward validation (a future handoff).
