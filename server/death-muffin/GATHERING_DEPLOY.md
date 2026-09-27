# Deploying gathering (POST /api/gather) to the Death Muffin backend

Written 2026-09-27 for whoever deploys on the VPS. **Nothing here has been run yet.** Scope: only the
Death Muffin installation (`death-muffin-auth.service`, MySQL database `death_muffin`). Never the
original shared Crossworlds server, the Workbench API or Muffin Development.

## What ships

| File (repo) | Goes to | What it does |
|---|---|---|
| `server/death-muffin/backend/gathering/gathering-rules.cjs` | `/home/ubuntu/death-muffin/backend/gathering/` | Generated from `src/gameplay/gatheringRules.ts` (`npm run build:server-rules`): nodes, success odds, loot, XP curve, time budget, bag placement |
| `server/death-muffin/backend/gathering/gathering-routes.cjs` | same | `POST /api/gather` (ownership → node → level → time budget → roll → one transaction) |
| `server/death-muffin/backend/gathering/gather-store.cjs` | same | MySQL store (row-locks character, skill row, ledger and bag) + an in-memory store for tests |
| `server/death-muffin/backend/server.js` | `/home/ubuntu/death-muffin/backend/server.js` | Mounts the route, adds `gravedigging`/`gardening` to the profession list, uses the shared XP curve, caps crafting at 99, **retires `POST /api/professions/award-xp` (410)** |
| `server/death-muffin/backend/migrations/002-gathering.sql` | run once | `gather_ledger` table, 21 new material rows, stack size 250 for gathered materials |
| `server/vps-handoff/necro-progress/necro-rules.cjs` | `/home/ubuntu/death-muffin/backend/necro-progress/` | Regenerated because the area list gained the Sexton's Acre. Optional: the old copy keeps working (the Acre is always open on the client). |

No new npm dependencies. The web client from the same commit must be published too. Older clients never
call `/api/gather`, so the backend can go first.

## 1. Back up

```bash
TS=$(date -u +%Y%m%dT%H%M%SZ)
sudo mysqldump --single-transaction death_muffin > /home/ubuntu/death-muffin/backups/death_muffin-before-gathering-$TS.sql
cp -a /home/ubuntu/death-muffin/backend /home/ubuntu/death-muffin/backups/backend-before-gathering-$TS
```

## 2. Check the professions column (once)

```sql
SHOW COLUMNS FROM professions LIKE 'profession_id';
```

If `Type` is an `enum(...)`, widen it before anything writes `gravedigging`:
`ALTER TABLE professions MODIFY profession_id VARCHAR(32) NOT NULL;` (keep the column's existing
collation). A `varchar` needs nothing.

## 3. Apply the migration (idempotent)

```bash
sudo mysql death_muffin < server/death-muffin/backend/migrations/002-gathering.sql
sudo mysql death_muffin -e "SELECT COUNT(*) FROM items WHERE id IN ('log_elm','bones_old','gem_void_sapphire'); SHOW TABLES LIKE 'gather_ledger';"
```

Expect `3` and one table.

## 4. Copy the backend and restart

```bash
cd /home/ubuntu/vps-handoffs/DeathMuffin/game
npm ci && npm run build:server-rules && npm test && npm run test:server   # all green first
mkdir -p /home/ubuntu/death-muffin/backend/gathering
cp server/death-muffin/backend/gathering/{gathering-rules.cjs,gathering-routes.cjs,gather-store.cjs} /home/ubuntu/death-muffin/backend/gathering/
cp server/death-muffin/backend/server.js /home/ubuntu/death-muffin/backend/server.js
cp server/vps-handoff/necro-progress/necro-rules.cjs /home/ubuntu/death-muffin/backend/necro-progress/necro-rules.cjs
node --check /home/ubuntu/death-muffin/backend/server.js
sudo systemctl restart death-muffin-auth.service
systemctl status death-muffin-auth.service --no-pager
```

`.env` is untouched. Realtime needs a restart only if you also ship the realtime `gather` intent
(`server/realtime/server.js`, re-embedded by `node tools/embed-realtime.mjs`). Older realtime servers drop
the unknown intent, so co-op node depletion just stays local to each player until it's deployed.

## 5. Verify (temporary test account; never paste owner credentials)

```bash
API=https://muffindevelopment.com/death-muffin/api
TOKEN=...        # POST $API/login with the temporary account
CID=...          # GET $API/character → id
curl -s -X POST $API/api/gather -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"characterId\":$CID,\"nodeType\":\"coffin_oak\",\"actions\":5}"
#  → {"success":true,"data":{"accepted":5,"successes":…,"items":[{"itemId":"log_oak",…}],"skills":[…]}}
curl -s -X POST $API/api/gather -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"characterId\":$CID,\"nodeType\":\"bone_elder\",\"actions\":1}"
#  → 400 {"success":false,"error":"Requires Woodcutting level 90"}
curl -s -X POST $API/api/professions/award-xp -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{}'
#  → 410 "Skill XP is earned by gathering and crafting now."
```

Then in the browser: walk west from the Chapterhouse into the Sexton's Acre, chop a Coffin-Oak, and
check that the logs land in the Reliquary after about 8 seconds and survive a reload. Remove the test account afterwards.

## Dev access (staff) — needs this deploy

The client opens every rite, area and gathering tier for the owner's account (`brbmuffins`, or any character whose
`/character` reply has `gm_enabled`) as a runtime overlay; nothing is saved. On the server, `POST /api/gather` and
`/api/gather/afk-start` skip only the node **level** check for staff (`isStaff` in `server.js`: `accounts.role` is
`admin`/`gm` or `gm_enabled = 1`); ownership, the rate limit and the time budget still apply, and XP lands on the
real level. For the owner's account to gather above its level on the live server, set it once:

```sql
UPDATE accounts SET role = 'admin' WHERE username = 'brbmuffins';   -- or: SET gm_enabled = 1
```

Without that, the client still shows every tier but the server answers "Requires … level N" verbatim.

## Rollback

1. Restore `server.js` from the backup folder and restart `death-muffin-auth.service` (the route
   disappears; clients show the server's 404 as a toast and keep playing combat).
2. Leave the migration in place: the new item rows and `gather_ledger` are additive and harmless. To remove them anyway,
   first confirm nothing references them (`SELECT COUNT(*) FROM inventory WHERE item_id IN (...)`), then
   `DROP TABLE gather_ledger;`.
3. Never import the pre-deploy dump over newer player data just to roll back code.

## Owner decisions assumed (roadmap §12)

- **XP curve:** the live rule `level × 50` stays (`XP_CURVE = 'live'` in `gatheringRules.ts`). Switching
  to the recommended curve is one constant plus a rebuild, and it applies to crafting too.
- **Tools:** optional. `successChance` takes a tool tier, and nothing grants tools yet.
- **Character XP from gathering:** none.
- **Level cap:** 99.
- **Co-op nodes:** shared depletion, per-player rewards.
- **Tripo budget:** not spent here. Nodes use code-built stand-ins until the `prop_node_*` GLBs exist.
