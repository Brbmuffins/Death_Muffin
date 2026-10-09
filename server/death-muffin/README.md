# Death Muffin server

Backend and operations for Death Muffin. The game is the Godot client (`godot/`), online only; the Windows launcher is `launcher/windows`. Public site:
https://muffindevelopment.com/death-muffin/ (launcher download, patch notes, leaderboard).

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

- `site/`: the launcher download page, About, Classes, leaderboard and patch notes. Copied to `/var/www/death-muffin/` by hand; no script publishes it.
- `client/`: the Godot Windows client and `manifest.json`, written by `publish-godot-client.sh`.
- `play/release-notes.json`, `play/patch-notes.json`: written by `announce-release.sh`; read by the launcher, the site and the client.

## Scripts

| Script | What it does |
|---|---|
| `deploy-release.sh [rev] [migration.sql ...]` | Deploys the **backend only** from a committed revision (default `HEAD`; refuses a rev that does not contain `origin/main` unless `ALLOW_BEHIND_MAIN=1`, which is how you roll back). Exports the rev with `git archive`, runs `npm run test:rules` and `npm run test:server`, dumps the database, writes a `ROLLBACK.sh`, applies the named migrations, copies the backend code to `/home/ubuntu/death-muffin/backend/`, restarts `death-muffin-auth`, checks health, then runs `announce-release.sh` in QUIET mode. Takes `~/death-muffin/deploy/.deploy.lock`. Does not publish the client and does not restart the lobby. |
| `publish-godot-client.sh <git-rev>` | Exports the `Windows Desktop` preset of the Godot project (Godot 4.7.2 at `/home/ubuntu/tools/godot/godot`) from a committed revision into `/var/www/death-muffin/client/<version>/`, then writes `manifest.json` last and atomically (SHA-256 of every file plus the `online` block, which is carried over from the live manifest). Keeps the newest two builds. |
| `set-online.sh on\|staff\|off ["message"]` | Edits only the `online` block of the live `manifest.json`: `on` = everyone, `staff` = staff accounts only, `off` = nobody (the message is shown as the lock). The launcher, the game and the lobby (if `DM_LOBBY_MANIFEST` is set) re-read it within about a minute; no release needed. |

### Release flow

1. Merge to `main`. For a release worth naming, add a new top entry (`title`, `items`) to `PATCH_NOTES.json`.
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
  is not believable and returns a readable message. Findings are written to `progress_audit` (`[AUTHORITY]` in the log). Staff accounts are exempt; guards fail open if the tables are missing.
- **Step 2, kill ledger** (`backend/kills.cjs`, migration 036): `AUTHORITY_KILLS=off` (default) ignores kill reports, `audit` keeps the ledger and logs differences, `enforce` lets saves claim only what
  the ledger credits (and implies the step-1 clamp). Ceilings come from `server/rules/gameplay/authorityRules.ts`.
- **Party sessions** (`backend/party-sessions.cjs`, migration 041, `backend/SESSION-REPORTS.md`): a session host reports what its members killed; each member's part goes through the same kill ledger.

```sql
SELECT a.created_at, ac.username, a.character_id, a.kind, a.mode, a.action, a.detail
  FROM progress_audit a JOIN accounts ac ON ac.id = a.account_id ORDER BY a.id DESC LIMIT 50;
```

## Player bug reports

Settings -> Report a bug in the client posts to `POST /api/bug-reports` (10 per account per day; `GET /api/bug-reports/mine` lists the player's own; table `bug_reports`, migration 029).
The daily agent in `bug-agent/` triages them (`bug-agent/README.md`); `announce-release.sh` marks fixed ones released. The Discord dev agent is in `discord-agent/README.md`.

## Tests

From the repository root: `npm run test:rules` (shared rules), `npm run test:server` (backend, necro-progress and freshness checks of the generated bundles). Lobby: `cd server/death-muffin/lobby && npm install && npm test`.
Backend dependencies: `npm ci` inside `backend/`. The Godot suites are run by `tools/godot/run-all-tests.sh`.
