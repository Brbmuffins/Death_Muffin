# Death Muffin hosted web game

Site: https://muffindevelopment.com/death-muffin/
Leaderboard: https://muffindevelopment.com/death-muffin/leaderboard.html

The supplied site design is preserved in `site/`, with live login and registration, animated smoke and ash, sound after the first browser interaction, and a lightweight leaderboard. Successful login waits for the gate effect before entering the game. Sound is muted by its existing toggle; browsers require a click or keypress before audio can start. OS reduced-motion preferences are respected.

The game uses Diablo-style controls: left-click ground to move, click enemies to attack, aim with the mouse and press 1–4 for equipped rites, right-click or press 5 for the class's corpse action, R or 6 for the level-10 signature rite, and Shift-click to attack while standing. The cursor reticle follows the mouse. HUD buttons remain interactive; empty HUD space passes input to the game canvas. Each left-click chooses a fixed ground destination. Mouse movement turns and aims a standing hero; walking faces its path, and holding the mouse does not add a second steering input. Generated hero models are aligned from their authored +X front to gameplay’s +Z heading. Help cards stay visible for at least 25 seconds, extend with text length, pause on hover, and can be clicked to dismiss. Status messages stay for at least eight seconds.

On Easy, auto combat starts enabled: the hero engages enemies in the current area, uses equipped rites and may cast a signature when its conditions fit. Click or use movement keys to take control, and toggle **G** or the Auto HUD button. Hold **1–4** to repeat at the cursor. Cast recovery is short; gestures blend into walking, projectile impacts match damage, and visual clutter/shake is bounded.

Use **Settings → Change class** at any time. The same character keeps level, XP, gold, items and permanent progress and returns to the Chapterhouse. The live database already has the nullable `discipline_index` override; new installations with the original character schema must apply `backend/migrations/001-discipline-index.sql` once before starting this backend. Do not rerun it blindly against the current VPS.

For the last recorded deployment, validation, Git and rollback details, read
[the agent handoff](../../docs/DEATH-MUFFIN-HANDOFF.md). For work newer than
that release, check [HANDOFF](../../HANDOFF.md) and `git status --short`.

## Services and isolation

- `backend/`: account/character/inventory/profession API, adapted from the existing VPS API. Listens only on 127.0.0.1:5190; uses a separate `death_muffin` MySQL database and JWT secret. Copy `server/vps-handoff/necro-progress/` into its `necro-progress/` folder when installing.
- `server/realtime/`: the included co-op service runs separately on 127.0.0.1:5191 with `ENV_FILE` pointing to Death Muffin's private backend `.env`.
- `systemd/`: unit files for the current VPS installation.
- `nginx-locations.conf`: additive HTTPS locations under the existing muffindevelopment.com certificate. HTTP requests under `/death-muffin/` redirect to HTTPS.
- `nginx-crossworlds-redirects.conf`: old game URLs redirect to Muffin Development with path and query preserved.
- Published static files: `/var/www/death-muffin/`; built game under `play/`.
- Browser session, progress, codex, settings, and help keys use the `dm_` prefix to avoid Crossworlds collisions.

Only the original game schema and catalogs were copied into the separate database. Existing player accounts and characters were not imported. The new backend excludes the old game's admin, Discord notification, ticket, and lore-edit routes. Real credentials, initial database SQL, temporary test accounts, and private provisioning scripts are deliberately excluded from Git.

The leaderboard exposes username, discipline, level, Ascension, Prelate kills, and total kills for the top 25 characters. Ordering is Ascension, Prelate kills, total kills, then level. It caches database results for 30 seconds and refreshes the web page every minute. Email password recovery is not configured; the login UI says so instead of pretending an email was sent.

Future bot opponents, companions, and leaderboard grinding are recorded in `docs/death-muffin-roadmap.md` at the repository root.

## Build and update the existing VPS

```bash
npm ci
npm run build:server-rules
npm test
npm run build:death-muffin
```

Copy `site/` to `/var/www/death-muffin/` and `dist/` to its `play/` folder. Install backend dependencies with `npm ci` inside the backend directory; configure `.env` privately using `.env.example`. Preserve the running database and `.env` during subsequent updates. On the current VPS, `/home/ubuntu/death-muffin/deploy/deploy.sh` publishes the extracted source and restarts only Death Muffin's services. The original nginx config is backed up in that folder; `rollback.sh` restores hosting while retaining player saves.

## Validation

The initial 2026-09-27 pass had 122 client tests plus TypeScript, server and
build checks. Later releases added classes, rites and tests; use the current
checkout's commands in `CLAUDE.md` for today's result. Initial browser checks
covered preserved saves, combat/facing/animation, manual movement priority,
menu/toggle suspension and held casts. Temporary test accounts were removed.


Domain migration checks verified the supplied owner's login and existing character, temporary account creation, rendered game world, authenticated co-op over the new domain, progress API, leaderboard, HTTP-to-HTTPS and old-domain redirects, and availability of both other sites. The temporary test account was removed. The existing Muffin Development front end and Workbench API were not changed.

The facing follow-up aligns the authored hero front with movement/casting headings. Standing heroes face the mouse; walking keeps path-facing and the fixed click destination. All 99 tests pass, including actual rig orientation checks for all five hero models. Chrome checked visible facing in four mouse directions, unchanged position while aiming, path-facing with the cursor in the opposite direction, arrival at the clicked point, spell-facing, and retained casting stability.

The casting follow-up anchors hero root transforms and hip position to the rig, leaving limb animation and the authored death collapse intact. Repeated casts retain animation weight, and movement loop updates no longer overwrite casting speed. All 99 client tests pass, including checks against all five shipped hero rigs. Chrome verified keyboard casting, zero animation-driven hip drift or root turning, and preserved hand gestures.

94 client tests passed, including waypoint continuity regressions. Chrome browser checks used actual mouse clicks and keypresses to verify click-to-move, aiming changes, spell casting, right-click suppression, interactive HUD buttons, and help duration. Public-site checks verified animated canvas pixels, a running WebAudio context after interaction, and the sound toggle. The initial deployment also verified owner login, world rendering, co-op connection, save/reload, and leaderboard behavior using a temporary account that was removed afterward.
