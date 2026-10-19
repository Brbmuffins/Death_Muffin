# Death Muffin server

Backend and operations for Death Muffin. The game is the Godot client (`client/`, with its combat core in `native/`), online only; the Windows launcher is `launcher/windows`. Public site:
https://muffindevelopment.com/death-muffin/ (launcher download, patch notes, leaderboard, benchmarks, play reports).

## Services

| Service | Port | Code | systemd unit | Notes |
|---|---|---|---|---|
| Auth + game API | 5190 (127.0.0.1) | `backend/server.js` | `systemd/death-muffin-auth.service` | Express, MySQL database `death_muffin`, own `JWT_SECRET`. Health: `GET /health`, `GET /api/health` |
| Lobby + packet relay | 5192 (127.0.0.1) | `lobby/` | `lobby/deathmuffin-lobby.service` | WebSocket session list and host-to-client relay for 1-4 player sessions; see `lobby/README.md` |
| Test backend (test builds) | 5194 (127.0.0.1) | the live backend's code | `test-server/death-muffin-auth-test.service` | Database `death_muffin_test`, own user and `JWT_SECRET`, copies of the team's accounts; public at `/death-muffin/test-api/`; see `test-server/README.md` |
| Test lobby and relay (test builds' co-op) | 5195 (127.0.0.1), 5196/udp (public) | the live lobby's and relay's code, own copies | `test-server/coop/*.service` | Authenticate against the test backend; installed 2026-10-16 (Helix's OK); public at `/death-muffin/test-lobby/`; see `test-server/coop/README.md` |
| UDP co-op relay | 5193/udp (public) | `relay/`, `client/net/relay/dm_udp_relay.gd` | `relay/deathmuffin-relay.service` | ENet lane next to the lobby WebSocket, entered with a lobby ticket; see `relay/README.md` |

Ports 5195-5199 are reserved for this project (:5191 is unused); 5195 and 5196 are the test lobby and relay.

Both services run as `ubuntu` from `/home/ubuntu/death-muffin/{backend,lobby}` (copies installed by `deploy-release.sh` and `deploy-lobby.sh`), not from the git checkout.
`.env` lives only in `/home/ubuntu/death-muffin/backend/` (template: `backend/.env.example`: `PORT`, `DB_HOST`, `DB_USER`, `DB_PASS`, `DB_NAME`, `JWT_SECRET`,
`JWT_EXPIRES_IN`; optional `AUTHORITY_MODE`, `AUTHORITY_KILLS`). The unit files contain no secrets; the lobby reads `JWT_SECRET` from the same `.env`.

## nginx

`nginx-locations.conf` mirrors the `/death-muffin/` locations of `/etc/nginx/sites-available/muffindevelopment` (it is not installed by this repo):
`/death-muffin/api/` -> :5190 (`/death-muffin/api/team/` too, with a 9 MB body limit for the team app's pictures), `/death-muffin/lobby/` -> :5192 (WebSocket upgrade), everything else under `/death-muffin/` is static files from `/var/www/death-muffin/`.
`nginx-crossworlds-redirects.conf` redirects the old Crossworlds game URLs to Muffin Development.

## Static files (`/var/www/death-muffin/`)

- `site/`: the launcher download page, About, Classes, leaderboard, benchmarks, play reports and patch notes. Copied to `/var/www/death-muffin/` by hand; no script publishes it.
- `client/`: the Godot Windows client and `manifest.json`, written by `publish-godot-client.sh`.
- `play/release-notes.json`, `play/patch-notes.json`: written by `announce-release.sh`; read by the launcher, the site and the client.

## Scripts

| Script | What it does |
|---|---|
| `deploy-release.sh [--if-changed] [rev] [migration.sql ...]` | Deploys the **backend only** from a committed revision (default `HEAD`; refuses a rev that does not contain `origin/main` unless `ALLOW_BEHIND_MAIN=1`, which is how you roll back). Exports the rev with `git archive`, runs `npm run test:rules` and `npm run test:server`, dumps the database, writes a `ROLLBACK.sh`, applies every pending migration (`migrate.sh`, below; naming files is optional), copies the backend code to `/home/ubuntu/death-muffin/backend/`, restarts `death-muffin-auth`, checks health (a failure after the install runs `ROLLBACK.sh` on its own and exits 1), then runs `announce-release.sh` in QUIET mode (`NO_ANNOUNCE=1` skips it). `--if-changed` (no migrations named) exits doing nothing when every server file the rev installs is byte-identical to the installed copy and no migration is pending; the Discord agent's Godot ships run it that way before the client publish. Takes `~/death-muffin/deploy/.deploy.lock`. Does not publish the client and does not restart the lobby. |
| `deploy-lobby.sh [--if-changed] [--wait MIN] [--force] [rev]` | Deploys the **lobby only** from a committed revision (default `HEAD`; refuses a rev that does not contain `origin/main` unless `ALLOW_BEHIND_MAIN=1`). Exports `server/death-muffin/lobby` with `git archive`, runs its tests and `node --check`, waits up to `--wait` minutes (default 30) for `/health` to show 0 sessions because a restart ends every party (exit 3 and nothing installed if it never empties; `--force` restarts anyway), backs up the installed copy with a `ROLLBACK.sh`, installs the lobby code, package files and README (`npm ci` only when the lockfile changed), restarts `deathmuffin-lobby` and checks `/health` (a failure after the install began runs `ROLLBACK.sh --force` on its own and exits 1). `--if-changed` exits doing nothing when the installed code and package files already match (a README-only change never restarts it); the Discord agent's Godot ships run it that way after the backend. Takes `~/death-muffin/deploy/.deploy.lock`. |
| `publish-godot-client.sh <git-rev>` | Exports the `Windows Desktop` preset of the Godot project (Godot 4.7.2 at `/home/ubuntu/tools/godot/godot`) from a committed revision into `/var/www/death-muffin/client/<version>/`, then writes `manifest.json` last and atomically (SHA-256 of every file plus the `online` block, which is carried over from the live manifest). Keeps the newest two builds. Both exports bake the shaders they use into their pack (`tools/godot/export-baked.sh`: Godot bakes only with a renderer, so the export runs on the software Vulkan driver on a virtual screen, holding the renderer lock, and falls back to a headless export without baked shaders, never to a failed release). `res://assets` ships as `DeathMuffin.assets.pck` (`tools/godot/assets-pack.sh`), reused from `~/death-muffin/deploy/assets-cache/` while its fingerprint (`tools/godot/assets-fp.sh`: the assets, the crowd baker's inputs, export settings, Godot version, pack tools) is unchanged, so most releases change only `DeathMuffin.pck` (~33 MB with its baked shaders) and the launcher keeps the rest. Keeps the combat core's debug symbols of each build in `~/death-muffin/symbols/<version>/` (the newest 40) for `tools/crash/symbolize.mjs` (native/README.md "Crash notes"). |
| `publish-launcher.sh <version>` | Makes a launcher release live for self-update (DECISIONS B33): takes `DeathMuffinLauncher.exe` from the GitHub release `launcher-v<version>` (built by `.github/workflows/launcher-windows.yml` from `main`), copies it to `/var/www/death-muffin/launcher/<version>/` and writes the launcher `manifest.json` (served at /death-muffin/launcher/) last and atomically (`version, url, size, sha256`). Refuses a version that is not newer than the live one (a rollback is the old code under a new version). Keeps the newest two. |
| `set-online.sh on\|staff\|off ["message"]` | Edits only the `online` block of the live `manifest.json`: `on` = everyone, `staff` = staff accounts only, `off` = nobody (the message is shown as the lock). The launcher, the game and the lobby (if `DM_LOBBY_MANIFEST` is set) re-read it within about a minute; no release needed. |

Test build channel and test backend for test builds (DECISIONS B38, B53): [test-channel/README.md](test-channel/README.md), [test-server/README.md](test-server/README.md).

### Release flow

1. Merge to `main`. For a release worth naming, add a new top entry (`title`, `items`) to `PATCH_NOTES.json`. Branches that add lines to the same entry merge cleanly: `.gitattributes` routes `PATCH_NOTES.json` through `tools/git/merge-patch-notes.mjs` (register it once per clone with `tools/git/install-merge-drivers.sh`; the VPS clone has it).
2. Backend: `deploy-release.sh <rev> [NNN-name.sql]`. Lobby: `deploy-lobby.sh <rev>` when it changed. Client last: `publish-godot-client.sh <rev>`, which refuses a release while the live lobby differs from the rev's (`LOBBY_SKEW_OK=1` overrides; rollbacks to older revs are exempt). Online play is opened or closed separately with `set-online.sh`.
3. Both scripts end with `announce-release.sh <rev>` (also callable by hand; never fails the caller; `NO_ANNOUNCE=1` skips it in the publish script). It:
   - writes the launcher/site notes: the top `PATCH_NOTES.json` entry if that file changed since the last announced release, otherwise the commit subjects;
   - posts "Death Muffin update is live" in #deathmuffin;
   - marks player bug reports fixed by `Bug report #<id>:` commits as released, with their own notice.
   - **QUIET (backend deploys):** if `PATCH_NOTES.json` did not change, the live notes keep their title and items and no release notice is posted (bug reports are still released).
   - **Rollbacks and repeats** (a rev that is not newer than the last announced one) announce nothing.

The manifest format is in `launcher/windows/README.md`.

## Database and migrations

`backend/migrations/NNN-*.sql` are applied by `migrate.sh` (deploy-release.sh runs it): every file not yet recorded in the `schema_migrations` table
(name, sha256, rev; `055-schema-migrations.sql`) runs once, in name order, and is recorded; a failing file stops the run unrecorded. 001-054 were recorded as a
baseline when the runner came in (2026-10-15). `migrate.sh --pending <dir>` lists what would run. Never edit an applied file (the runner warns on a changed
checksum and does not re-run it); add a new one. Every file must still be additive and idempotent. Numbers are not contiguous (gaps are intentional). Several files are generated from `server/rules/content/` by `tools/build-*-sql.mjs`; those generators have a `--check` mode.
`001-discipline-index.sql` and `003-optional-email.sql` are for fresh installs of the original schema and must not be re-run blindly against the live database.
Real credentials, the initial schema and test accounts are not in Git.

## Shared rules

`server/rules/` (TypeScript) is the server-side source of truth for content and rule tables; `npm run build:server-rules` bundles it into
`backend/gathering/*-rules.cjs` and `server/vps-handoff/necro-progress/necro-rules.cjs`. Never edit those `.cjs` files by hand. See `rules/README.md`. The game's port of the rules is `client/rules/`.
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
  progressSeq}`. A body without `gains` (totals, clients before B23) is refused with 426 and writes nothing (DECISIONS B32). Gold other routes pay is written by them: gathering,
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
A release build also files one by itself after a crash (`DmCrashWatch`, DECISIONS B29: message "Automatic crash report ...", `context.crash`).
Each new report gets its own thread in #in-game-reports (message, context, game log attached), opened by the Discord dev agent's runner; the devs bring the agent in with an @-mention (`discord-agent/README.md`). `announce-release.sh` marks reports whose `Bug report #<id>:` fix went live as released.

## Benchmark history

The client uploads every finished in-game benchmark run to `POST /api/benchmarks` (`backend/benchmarks.cjs`, table `benchmark_runs`, migration 048; reply `{ success, data: { id } }`; a repeated `clientRunId` answers the first id; 60 runs per account per day, 30 calls a minute). Everything in it is untrusted and is clamped on the way in; vsync-capped or cancelled runs are stored with `flagged` set and left out of the default list.
Anyone can read: `GET /api/benchmarks` (filters `room`, `discipline`, `size` (`light`, `standard`, `heavy`, `full_party`), `length`, `version`, `gpu`, `account`, `standard=1`, `includeFlagged=1`, `limit`, `before`) and `GET /api/benchmarks/:id` (metrics, breakdown, text report); only admin / gm accounts (GM mode or not) may `DELETE /api/benchmarks/:id`. nginx strips `/death-muffin/api`, so every route is mounted both as `/api/benchmarks` (the game's base) and `/benchmarks` (the site, like `/leaderboard`).
The public page is `site/benchmarks.html` (`benchmarks.js`): filters (default: every run, flagged ones shown with a badge), a per-version trend chart (one line per PC, per PC and setup when several setups are shown; flagged runs left out), the runs table and a two-run compare.

## Play reports

When a play session ends, the game sends one summary to `POST /api/play-reports` (`backend/play-reports.cjs`, table `play_reports`, migration 056; the player's token; reply `{ success, data: { id } }`). Errors are `{ success: false, code, error }`: 400 `bad_request`, 401 `unauthorized`, 429 `rate_limited` (50 reports a day per account, 30 calls a minute), 503 `unavailable` while the table is missing. A report needs a valid `reportId` (16-64 characters, made once per session; a repeated one answers the first id), a `version` and `seconds`; everything else is untrusted and cleaned (unknown keys dropped, strings trimmed and capped, numbers clamped, a bad value becomes its safe default), so a crash found at the next start still counts. The account id (only to count players and cap spam) and the party session ids a report names are never returned.
Anyone can read `GET /api/play-reports/releases` (every release newest first by its first report: `version, reports, players, hours, first, last`) and `GET /api/play-reports/summary?version=<v>` (kept a minute): reports, players, hours, median and average session minutes; by graphics preset and by graphics card (the 15 with most sessions) the sessions, average frame ms (weighted by frames), p99 ms and worst frame ms (the median over sessions of each one's own) and hitches per hour (frames over 50 ms); end reasons and end areas (counts); per area hours, deaths, deaths per hour and average frame ms; and `server`, the server's own numbers. Both are mounted as `/api/play-reports/...` (the game's base) and `/play-reports/...` (the site: nginx strips `/death-muffin/api`).
**The server's numbers** (`server`) cover the party sessions the reports name, each counted once however many of its members reported, and only when an account that named it was a member of it. They are per player-hour, each member counted from joining to leaving (or to the session's end): `kills` and `bosses` are the members' accepted counters in `party_session_members`; `xp` and `gold` are what the members' progress saves paid in that time (`value_ledger`, reason `save`, gains only), because the kill ledger keeps XP and gold only as lifetime totals. `dropsPerHour` is always null: `character_drop_events` carries no party session (a claim's `sessionId` only decides whether a member may carry a drop and is not stored), an event's time is its first pickup (up to 3 minutes after the kill) and drops nobody picks up leave no row, so a time window would count a member's solo Depths drops and miss late pickups.
The public page is `site/play-reports.html` (`play-reports.js`): a release picker (newest first) and the summary as tables.

## Team jobs

The team app (a small Windows app on War's, Muffins' and Helix's PCs; ROADMAP Phase 1, DECISIONS B54 and B55) runs jobs that need a real graphics card; the first kind is `shots`, screenshots of a Discord agent proposal on Low and Ultra. The server queues a job, one PC claims it, uploads its pictures and finishes it; the Discord agent's runner (same machine) creates jobs and reads the results. `backend/team-jobs.cjs`, tables `team_members`, `team_tokens`, `team_pcs` and `team_jobs`, migration 057. Until the migration is applied every team route answers a readable 503 `unavailable`. Errors are `{ success: false, code, error }` with a player-readable `error`: 400 `bad_request`, 401 `bad_login` or `signed_out`, 403 `not_team`, `wrong_pc` or `not_your_job`, 404 `not_found`, 409 `taken`, `not_running` or `too_many`, 413 `too_large`, 415 `bad_type`, 429 `rate_limited` (120 calls a minute per account) or `too_many_jobs`, 503 `unavailable`, 500 `server_error`.
**Who may use it.** Only accounts in `team_members`, with the team app's own sign-in, never the game's: `POST /api/team/login` `{ username, password, pcId, pcName }` checks the password as `/login` does (the same bcrypt compare and rate limiter, the same words for a refusal), then the account must be on the team (403 `not_team`, asked only after a right password), but it does not claim the account's game session (`session.cjs`), so signing in to the app never ends the player's game and the game's one-session rule never refuses the app. It answers `{ token, expiresAt, accountId, username }`: 32 random bytes as base64url, kept only as its SHA-256 in `team_tokens`, good for 90 days, one live sign-in per PC (signing in again on a PC ends its old one) and at most 5 per account (the oldest ends). Every other app route needs `Authorization: Team <token>`: not revoked, not expired, its account still in `team_members` and active, else 401 `signed_out` ("Signed out: sign in to the team app again."); a game token is refused the same way. The token names its PC, and that is the PC every call acts as: a body, header (`X-Team-Pc`) or query (`?pcId=`) that names another is 403 `wrong_pc`, and one that names none is the token's. `POST /api/team/logout` ends the token it came with. Taking an account out of `team_members` locks its tokens out at once. Rows are added by hand, never by a route or a migration:

```sql
INSERT INTO team_members (account_id) VALUES (1001), (1002), (1003);   -- placeholder ids: SELECT id, username FROM accounts WHERE username IN (...)
DELETE FROM team_members WHERE account_id = 1001;                      -- takes the access away at once, tokens included
```

The runner's routes (`/internal/team/...`, mounted only there) answer 404 to everything except a connection from this machine that carries none of nginx's forwarding headers (`/death-muffin/api/internal/...` would reach them from 127.0.0.1 through nginx, so the headers count) and an `X-Team-Secret` equal to the contents of `TEAM_SECRET_FILE` (default `/home/ubuntu/death-muffin/discord-agent/secret`, the runner's own secret; compared in constant time; a missing or short file refuses everything).
**The app** (each route is also mounted without `/api`, like benchmarks: nginx strips `/death-muffin/api`):

- `POST /api/team/login`, `POST /api/team/logout`: above. `GET /api/team/me` -> `{ accountId, username }`.
- `POST /api/team/heartbeat` `{ pcId, name, version, gpu, mode, state }` every 30 s: stores the PC (`mode` `ask` | `auto` | `yes`, `state` `gameRunning, fullscreen, onBattery, busy, paused`), renews the heartbeat of the job it runs, sweeps, and answers `{ serverTime, offer }`, the oldest queued job that has not expired and this PC has not declined (`id, kind, title, weightS, expiresAt`) or null; every other team PC is offered it until one claims it.
- `POST /api/team/jobs/:id/claim` `{ pcId }` -> `{ id, kind, title, payload }`; the claim is one atomic update, so of two PCs one gets it and the other 409 `taken` (also for an expired or cancelled job). The PC that holds it may claim it again. Declining does not forbid a claim.
- `POST /api/team/jobs/:id/decline` `{ pcId, reason }` (`not_now`, `paused`, `busy`): noted in the job's `result.declines` (one entry per PC, its latest answer last, at most 20); the job stays queued for the other PCs and the heartbeat never offers it to this PC again.
- `PUT /api/team/jobs/:id/files/:name`: the raw PNG as the body, `Content-Type: image/png`, at most 8 MB (refused at once when `Content-Length` says more; never more than 8 MB is read), at most 40 pictures a job (replacing one is fine). The name is `^[a-z0-9_-]{1,60}\.png$`; the body needs the PNG signature, an IHDR first with each side 16 to 4096 pixels, and the closing IEND chunk. Stored as `$TEAM_RESULTS_DIR/<job id>/<name>` (default `/home/ubuntu/death-muffin/team-results`; folders 0750, files 0640, written to a part file and renamed). Answers `{ name, bytes, width, height }`. An upload renews the job's heartbeat.
- `POST /api/team/jobs/:id/done` `{ files, log, timings: { downloadS, runS } }`: every named picture must have been uploaded; the result keeps the pictures' sizes, the log (64 KB) and the timings. `POST /api/team/jobs/:id/fail` `{ error, log }` (400 characters). A resent done or fail answers the same success.
- `PUT`, `done` and `fail` are only for the PC that holds a running job (403 `not_your_job` for another account or another PC of the account, 409 `not_running` for a job that is not running, with the reason in the text).

**The runner:** `POST /internal/team/jobs` `{ kind, title, weightS, payload, ttlS }` -> `{ id }` (12 lowercase hex; `ttlS` 60 seconds to 7 days, default 1 hour; at most 50 queued or running jobs); `GET /internal/team/jobs/:id` (the row: status, tries, times as ISO strings, payload, result, error, and `files` with their absolute paths); `POST /internal/team/jobs/:id/cancel` (queued or running; a finished job is 409); `GET /internal/team/pcs` (PCs seen in the last 2 minutes with username, mode and state).
**Life of a job:** `queued` -> `running` -> `done` | `failed`; `queued` -> `expired` once `expires_at` passes; `queued` or `running` -> `cancelled`. A running job whose PC sends no heartbeat for 3 minutes goes back to `queued` once (`tries` 1, claim cleared) and fails with "The team PC went quiet" the second time. The sweep runs on every heartbeat and every runner call, so there is no timer; a cancel reaches a PC the next time it uploads or finishes (409 "This job was cancelled."). Nothing prunes `team-results`.
**Installing it.** Apply migration 057 (`deploy-release.sh` does), then by hand: `mkdir -p -m 0750 /home/ubuntu/death-muffin/team-results`; copy `systemd/death-muffin-auth.service` to `/etc/systemd/system/` (its `ReadWritePaths` lets the service write that folder under `ProtectSystem=strict`) and `sudo systemctl daemon-reload`; add the `/death-muffin/api/team/` location of `nginx-locations.conf` to the live site (nginx's default 1 MB body limit would refuse the pictures) and `sudo nginx -t && sudo systemctl reload nginx`; restart `death-muffin-auth`. The test backend (`:5194`) mounts the same routes against its own database and answers 503 until that database has the tables.

## Tests

From the repository root: `npm run test:rules` (shared rules), `npm run test:server` (backend, necro-progress and freshness checks of the generated bundles). Lobby: `cd server/death-muffin/lobby && npm install && npm test`.
Backend dependencies: `npm ci` inside `backend/`. The Godot suites are run by `tools/rebuild/run-client-tests.sh`.

## Ops jobs

The health watch (every minute, alerts in #build-alerts), the nightly DB backup and the nightly drift report: [`ops/README.md`](ops/README.md) (`ops/install.sh` installs them).
