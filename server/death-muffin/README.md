# Death Muffin server

Backend and operations for Death Muffin. The game is the Godot client (`godot/`), online only; the Windows launcher is `launcher/windows`. Public site:
https://muffindevelopment.com/death-muffin/ (launcher download, patch notes, leaderboard, benchmarks).

## Services

| Service | Port | Code | systemd unit | Notes |
|---|---|---|---|---|
| Auth + game API | 5190 (127.0.0.1) | `backend/server.js` | `systemd/death-muffin-auth.service` | Express, MySQL database `death_muffin`, own `JWT_SECRET`. Health: `GET /health`, `GET /api/health` |
| Lobby + packet relay | 5192 (127.0.0.1) | `lobby/` | `lobby/deathmuffin-lobby.service` | WebSocket session list and host-to-client relay for 1-4 player sessions; see `lobby/README.md` |

Ports 5193-5199 are reserved for this project (:5191 is unused).

Both services run as `ubuntu` from `/home/ubuntu/death-muffin/{backend,lobby}` (copies installed by `deploy-release.sh` and by hand for the lobby), not from the git checkout.
`.env` lives only in `/home/ubuntu/death-muffin/backend/` (template: `backend/.env.example`: `PORT`, `DB_HOST`, `DB_USER`, `DB_PASS`, `DB_NAME`, `JWT_SECRET`,
`JWT_EXPIRES_IN`; optional `AUTHORITY_MODE`, `AUTHORITY_KILLS`). The unit files contain no secrets; the lobby reads `JWT_SECRET` from the same `.env`.

## nginx

`nginx-locations.conf` mirrors the `/death-muffin/` locations of `/etc/nginx/sites-available/muffindevelopment` (it is not installed by this repo):
`/death-muffin/api/` -> :5190, `/death-muffin/lobby/` -> :5192 (WebSocket upgrade), everything else under `/death-muffin/` is static files from `/var/www/death-muffin/`.
`nginx-crossworlds-redirects.conf` redirects the old Crossworlds game URLs to Muffin Development.

## Static files (`/var/www/death-muffin/`)

- `site/`: the launcher download page, About, Classes, leaderboard, benchmarks and patch notes. Copied to `/var/www/death-muffin/` by hand; no script publishes it.
- `client/`: the Godot Windows client and `manifest.json`, written by `publish-godot-client.sh`.
- `play/release-notes.json`, `play/patch-notes.json`: written by `announce-release.sh`; read by the launcher, the site and the client.

## Scripts

| Script | What it does |
|---|---|
| `deploy-release.sh [--if-changed] [rev] [migration.sql ...]` | Deploys the **backend only** from a committed revision (default `HEAD`; refuses a rev that does not contain `origin/main` unless `ALLOW_BEHIND_MAIN=1`, which is how you roll back). Exports the rev with `git archive`, runs `npm run test:rules` and `npm run test:server`, dumps the database, writes a `ROLLBACK.sh`, applies the named migrations, copies the backend code to `/home/ubuntu/death-muffin/backend/`, restarts `death-muffin-auth`, checks health, then runs `announce-release.sh` in QUIET mode (`NO_ANNOUNCE=1` skips it). `--if-changed` (no migrations named) exits doing nothing when every server file the rev installs is byte-identical to the installed copy; the Discord agent's Godot ships run it that way before the client publish. Takes `~/death-muffin/deploy/.deploy.lock`. Does not publish the client and does not restart the lobby. |
| `publish-godot-client.sh <git-rev>` | Exports the `Windows Desktop` preset of the Godot project (Godot 4.7.2 at `/home/ubuntu/tools/godot/godot`) from a committed revision into `/var/www/death-muffin/client/<version>/`, then writes `manifest.json` last and atomically (SHA-256 of every file plus the `online` block, which is carried over from the live manifest). Keeps the newest two builds. |
| `set-online.sh on\|staff\|off ["message"]` | Edits only the `online` block of the live `manifest.json`: `on` = everyone, `staff` = staff accounts only, `off` = nobody (the message is shown as the lock). The launcher, the game and the lobby (if `DM_LOBBY_MANIFEST` is set) re-read it within about a minute; no release needed. |

### Release flow

1. Merge to `main`. For a release worth naming, add a new top entry (`title`, `items`) to `PATCH_NOTES.json`. Branches that add lines to the same entry merge cleanly: `.gitattributes` routes `PATCH_NOTES.json` through `tools/git/merge-patch-notes.mjs` (register it once per clone with `tools/git/install-merge-drivers.sh`; the VPS clone has it).
2. Client: `publish-godot-client.sh <rev>`. Backend: `deploy-release.sh <rev> [NNN-name.sql]`. Online play is opened or closed separately with `set-online.sh`.
3. Both scripts end with `announce-release.sh <rev>` (also callable by hand; never fails the caller; `NO_ANNOUNCE=1` skips it in the publish script). It:
   - writes the launcher/site notes: the top `PATCH_NOTES.json` entry if that file changed since the last announced release, otherwise the commit subjects;
   - posts "Death Muffin update is live" in #deathmuffin;
   - marks player bug reports fixed by `Bug report #<id>:` commits as released, with their own notice.
   - **QUIET (backend deploys):** if `PATCH_NOTES.json` did not change, the live notes keep their title and items and no release notice is posted (bug reports are still released).
   - **Rollbacks and repeats** (a rev that is not newer than the last announced one) announce nothing.

The manifest format is in `launcher/windows/README.md`.

## Database and migrations

`backend/migrations/NNN-*.sql` are applied by hand or by naming them on `deploy-release.sh`; there is no migration runner and no migrations table, so every file must be additive and
idempotent. Numbers are not contiguous (gaps are intentional). Several files are generated from `server/rules/content/` by `tools/build-*-sql.mjs`; those generators have a `--check` mode.
`001-discipline-index.sql` and `003-optional-email.sql` are for fresh installs of the original schema and must not be re-run blindly against the live database.
Real credentials, the initial schema and test accounts are not in Git.

## Shared rules

`server/rules/` (TypeScript) is the server-side source of truth for content and rule tables; `npm run build:server-rules` bundles it into
`backend/gathering/*-rules.cjs` and `server/vps-handoff/necro-progress/necro-rules.cjs`. Never edit those `.cjs` files by hand. See `rules/README.md`. The Godot port of the rules is `godot/rules/`.
`server/vps-handoff/necro-progress/` holds the necromancer progression routes, store and schema, installed into `backend/necro-progress/` by `deploy-release.sh`.

## Server authority

The client reports level, XP, gold, kills and its bag; the backend decides whether the report is believable. Both switches are read on every request, but the service reads `.env` only at
start, so changing one needs a restart of `death-muffin-auth`.

- **Step 1, plausibility guards** (`backend/authority.cjs`, migration 021): `AUTHORITY_MODE=report` (default) logs what it would refuse and never changes a save; `enforce` clamps what
  is not believable and returns a readable message. Findings are written to `progress_audit` (`[AUTHORITY]` in the log). Accounts in GM mode are exempt (below); a guard that cannot run refuses the write with a 503 (the client retries), never saves unchecked.
- **Step 2, kill ledger** (`backend/kills.cjs`, migration 036): `AUTHORITY_KILLS=off` (default) ignores kill reports, `audit` keeps the ledger and logs differences, `enforce` lets saves claim only what
  the ledger credits (and implies the step-1 clamp). Ceilings come from `server/rules/gameplay/authorityRules.ts`.
- **GM mode** (`backend/gm-mode.cjs`, migration 046, DECISIONS B19): an account with role admin / gm or `gm_enabled` is a normal player until it sends
  `POST /api/gm/mode {on: true}` (in game: Settings -> GM mode); only then is it staff for the guards above. Each switch (`gm_mode`) and each successful write
  in GM mode (`gm_write`) is a `progress_audit` row, and switching on sets `characters.gm_marked` (the leaderboard's GM tag). `GET /api/me` answers `gmActive`.
  GM-mode only: `POST /api/inventory/add-item`, `POST /api/offline/load`, `POST /api/offline/sync-stats`, and a first `POST /api/necro-progress/import`
  carrying a record (a player's starts blank).
- **Progress saves are gains** (`POST /api/character/save-progress {characterId, gains: {xp, gold}, seq, killReports?}`, migration 052, DECISIONS B23):
  the backend adds the gains to its own record (the level is worked out of the XP; stats are its own), runs the guards above on the result
  and answers the character row; a `seq` at or below `character_authority.progress_seq` is a retry and answers `{duplicate: true,
  progressSeq}`. A body without `gains` is an older client's totals (the old path). Gold other routes pay is written by them: gathering,
  labor, contracts (each answers `goldTotal`) and `POST /api/inventory/sell {characterId, items: [{slot_index, quantity}]}` (`sell.cjs`:
  bag slots only, never worn gear, an affixed piece at its affixed price; answers `{sold, gold, goldTotal, bag}`).
- **The bag is the server's** (DECISIONS B25): `POST /api/inventory/sort {characterId, locked?}` -> `{bag, moves}` and
  `POST /api/inventory/use {characterId, uses: [{item_id, slot_index?, quantity}]}` -> `{bag, used}` (`bag-ops.cjs`, rules in
  `vaultRules.ts` sortBag / useItems; only consumables are used up). Every other bag change has its own route. `POST /api/inventory/save`
  (the whole bag) is GM mode only; a player gets a 403 telling them to update.
- **Value ledger** (`backend/value-ledger.cjs`, migration 054, DECISIONS B24): every server write of a character's gold, XP (lifetime total)
  or soul shards adds a `value_ledger` row `{delta, balance, reason, ref}` inside the write's transaction; a failure is logged, never fails the write.
- **Boss kills** in the kill ledger draw first on paid summons (`character_drop_tape.boss_credit` minus `character_kill_ledger.summon_used`,
  migration 053), then on the per-minute allowance. A party session's report is deduplicated by its batch number and neither checks nor
  moves the member's own report `seq`.
- **Server-decided drops** (`backend/drops.cjs`, migrations 047, 049, 050, DECISIONS B20): `POST /api/drops/tape {characterId, next?}` deals each
  drop kind's next seeds (kill 128, elite 48, boss 6, surge 6, floor 8, chest 4; one secret-derived seed per event); `POST /api/drops/claim
  {characterId, kind, n, index, facts, expect?, sessionId?}` rolls that event again from its seed (`gathering/loot-rules.cjs` rollEvent, equal
  to the client's roll by the loot parity fixture) and puts exactly that drop in the bag, once. Bounds: ground open or carried, Wave Speed
  owned, fortune, rising rune chance in roll order, one first kill per boss, a Depths floor within the ledger's proven depth (+1), chests on
  fifth floors, each kind's tape spent no faster than the kill ledger's accepted kills / floors, a surge rate; boss drops are backed by paid
  summons instead (migration 051 `boss_credit`: +1 per summon the character or its party host paid, no rate limit). `DROPS_MODE` (read in
  `drops-mode.cjs`): `enforce` (default) refuses a claim past a bound;
  `audit` logs it (`drop_*` rows in `progress_audit`) and lets them through, rolled with the client's value up to the hard limits.
  A claim refused over budget answers `resync {kind, spent}`: the client rewinds that tape to the server's position (seeds re-used in order).
  `POST /api/loot/roll-gear` (client-named gear) is GM-mode only.
- **A member's build** (`GET /api/sessions/:id/members/:cid/build`, party-sessions.cjs `memberBuild`, DECISIONS B22): the session's host
  reads an active member's level, class, stats, worn slots and progression to build that member's hero. A member's party kills are judged in
  the host's world (the host character's level and Ascension rank).
- **Party sessions** (`backend/party-sessions.cjs`, migration 041, `backend/SESSION-REPORTS.md`): a session host reports what its members killed; each member's part goes through the same kill ledger.
- **Learned runes** (`backend/runes.cjs`, migration 044): `GET /api/runes/:id` lists a character's learned runes; `POST /api/inventory/rune/learn` spends a bag rune and learns it; `POST /api/inventory/rune` puts a learned rune in its rite's socket (or empties it). DECISIONS B17.
- **Friends** (`backend/friends.cjs`, migration 045): `GET /api/friends` (friends with their active character's discipline and level, requests both ways), `POST /api/friends/request {username}`
  (asking someone who asked you accepts), `/accept {accountId}`, `/remove {accountId}` (unfriend, decline or cancel). Mutual, one row per pair, 100 per account, 20 waiting requests; 60 calls a minute.
- **Dropped gear** (`backend/ground.cjs`, migration 043): `POST /api/ground/drop` and `/api/ground/pickup`. Gear dropped from a bag lies on its party session's ground until the session ends; the dropper and members who were in the session when it was found (`loot_instances.found_session_id`, stamped by roll-gear) may take it; the first pickup wins, one transaction each. A bag save may not name a piece on the ground.

```sql
SELECT a.created_at, ac.username, a.character_id, a.kind, a.mode, a.action, a.detail
  FROM progress_audit a JOIN accounts ac ON ac.id = a.account_id ORDER BY a.id DESC LIMIT 50;
```

## Player bug reports

Settings -> Report a bug in the client posts to `POST /api/bug-reports` (10 per account per day; `GET /api/bug-reports/mine` lists the player's own; table `bug_reports`, migration 029).
Each new report gets its own thread in #in-game-reports (message, context, game log attached), opened by the Discord dev agent's runner; the devs bring the agent in with an @-mention (`discord-agent/README.md`). `announce-release.sh` marks reports whose `Bug report #<id>:` fix went live as released.

## Benchmark history

The client uploads every finished in-game benchmark run to `POST /api/benchmarks` (`backend/benchmarks.cjs`, table `benchmark_runs`, migration 048; reply `{ success, data: { id } }`; a repeated `clientRunId` answers the first id; 60 runs per account per day, 30 calls a minute). Everything in it is untrusted and is clamped on the way in; vsync-capped or cancelled runs are stored with `flagged` set and left out of the default list.
Anyone can read: `GET /api/benchmarks` (filters `room`, `discipline`, `size`, `length`, `version`, `gpu`, `account`, `standard=1`, `includeFlagged=1`, `limit`, `before`) and `GET /api/benchmarks/:id` (metrics, breakdown, text report); only admin / gm accounts (GM mode or not) may `DELETE /api/benchmarks/:id`. nginx strips `/death-muffin/api`, so every route is mounted both as `/api/benchmarks` (the game's base) and `/benchmarks` (the site, like `/leaderboard`).
The public page is `site/benchmarks.html` (`benchmarks.js`): filters (default: every run, flagged ones shown with a badge), a per-version trend chart (one line per PC, per PC and setup when several setups are shown; flagged runs left out), the runs table and a two-run compare.

## Tests

From the repository root: `npm run test:rules` (shared rules), `npm run test:server` (backend, necro-progress and freshness checks of the generated bundles). Lobby: `cd server/death-muffin/lobby && npm install && npm test`.
Backend dependencies: `npm ci` inside `backend/`. The Godot suites are run by `tools/godot/run-all-tests.sh`.

## Ops jobs

Nightly DB backup and the weekly drift report: [`ops/README.md`](ops/README.md) (`ops/install.sh` installs both).
