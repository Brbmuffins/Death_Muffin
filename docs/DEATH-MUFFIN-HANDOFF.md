# Death Muffin agent handoff

Updated 2026-09-27. Read this before editing or deploying. Preserve the supplied site's visual design and the accepted fixed click-to-move behavior.

User-approved complete version: **`death-muffin-v1.0.0`**. See [the checkpoint record](DEATH-MUFFIN-CHECKPOINT.md) for the full private backup and restoration boundaries. Preserve this baseline while designing new abilities.

## Existing Claude foundation

This builds on the supplied Claude project, not a replacement game. Read `CLAUDE.md` for the architecture and `HANDOFF.md`/`PHASE_REPORTS.md` for already shipped systems. This Death Muffin handoff adds the current VPS deployment state; historical ports, Windows paths and pending-server statements in those earlier documents are not the live Death Muffin configuration.

- `NECROMANCER_REDESIGN_AUDIT.md`: connected world → waves → corpses as minions/spell fuel → loot → damage/wave upgrades → new areas. Keep that loop.
- `docs/agent-briefs/combat-depth.md`: the combat depth pack is already shipped. Preserve host-authoritative **Intent → WorldSim → SimEvent → VFX/audio/rewards**; polish presentation/input without inventing a second damage path.
- `src/content/abilities.ts` (`SPELL_FX`) and `FUTURE_CONTENT.md`: bone ivory/amber; marrow ember/crimson; spirit jade/teal; rot chartreuse/olive; ritual violet; enemy bells bronze. Readability needs distinct shapes/timing as well as colour.
- `CLAUDE.md`: new mechanics need their Onboarding counsel tip, Codex entry, Settings keys and README guidance. Keep known live item IDs and four discipline/server index mappings.
- `BALANCE.md`, `src/gameplay/balance/harness.ts`, `npm run balance` and `npm run balance:boss`: existing deterministic farming/combat bot harnesses; reuse them before designing future persistent live bots.
- `docs/agent-briefs/environment.md`: desktop 60 fps, high/low quality fallbacks, capped effects and no allocations in hot loops. Existing managed Effects/runtime should own updates and disposal.
- `.claude/launch.json` is a Windows preview configuration (ports 5188/5000). Use the VPS dev command below here.

Historical prohibitions on changing the original shared REST server still protect that server. Current user authorization covers this separate Death Muffin installation and local Git commits; it does not authorize editing unrelated applications or publishing secrets.

## Current outcome and active work

- Live site: https://muffindevelopment.com/death-muffin/; game: `/death-muffin/play/`; leaderboard: `/death-muffin/leaderboard.html`.
- Old `playcrossworlds.com/death-muffin/` URLs return 308 redirects to the new domain, preserving path and query. Other Crossworlds and Muffin Development routes remain independent.
- Completed: separate accounts/progress/co-op, login effects and sound, leaderboard, readable help, fixed click destinations, stable hero animation roots, correct model facing. Standing heroes aim at the mouse; walking heroes face their path. Holding or moving the mouse must not retarget movement.
- **Published 2026-09-27 and tested:** free class changes from Settings, and the combat polish pass. Class changes save inventory/progression first, preserve the character ID and original class slot, and return to the Chapterhouse.
- Combat direction: easy, readable Three.js combat for relaxed grinding, while remaining engaging to watch. Auto combat is enabled by default and toggled with `G` or the HUD button. It never sets a movement path, stops for manual movement and open panels, conserves essence, raises below the discipline cap, and leaves signatures manual. Hold 1–4 to repeat at the cursor; short input buffering absorbs near-ready casts. Cast recovery is 60–160ms and gestures .22–.48s. Spear and Miasma hits arrive with the visuals; delayed impacts cancel on caster death. Smoke, shake and particle counts are reduced; cosmetic meshes cap at 160 and projectile meshes are pooled.
- Future bot opponents/companions and persistent leaderboard farming are recorded in [death-muffin-roadmap.md](death-muffin-roadmap.md). They are not implemented by this pass.

## Source and running copies

| Purpose | Location |
| --- | --- |
| Git repository / game source | `/home/ubuntu/vps-handoffs/DeathMuffin/game` |
| Canonical versioned deployment source | `server/death-muffin/` inside the repository |
| Extracted front-end site used by current deploy script | `/home/ubuntu/vps-handoffs/DeathMuffin/site` |
| Running API / realtime copies | `/home/ubuntu/death-muffin/backend`, `/home/ubuntu/death-muffin/realtime` |
| Published site / built game | `/var/www/death-muffin/`, `/var/www/death-muffin/play/` |
| VPS scripts, backups and browser QA | `/home/ubuntu/death-muffin/deploy/` |

Editing source does not update the running copies. When editing the supplied site, keep the versioned `server/death-muffin/site/` and extracted deployment source in sync. Never commit generated `dist/`, credentials, private provisioning files, test accounts, or database dumps.

- API: `death-muffin-auth.service`, loopback `127.0.0.1:5190`, separate MySQL database `death_muffin`.
- Co-op: `death-muffin-realtime.service`, loopback `127.0.0.1:5191`, socket path `/death-muffin/rt/socket.io`.
- Realtime reads the private API `.env`; its allowed origins are Muffin Development. Do not replace either secret or import other games' users.
- Nginx locations live in `/etc/nginx/sites-available/muffindevelopment`; old game redirects live in `/etc/nginx/sites-enabled/crossworlds`. Repository fragments are under `server/death-muffin/`.
- Do not edit the Workbench API, Muffin Development application, original Crossworlds game, or their databases for Death Muffin changes.

## After the approved checkpoint

The approved complete version `death-muffin-v1.0.0` points to `a9e54b3` (documentation atop gameplay `fca634d`). Private full backup: `/home/ubuntu/death-muffin/backups/death-muffin-v1.0.0-20260927T024930Z`, about 202MiB. All archives were listed and checked, Git bundle verified and SHA256SUMS validated; includes the consistent 34-table database snapshot. Source/tag are pushed; private backups are on this VPS, not GitHub. See its `RESTORE.md` and never import a snapshot over newer player data merely to roll back code.

Follow-up UI changes add rich spell hover/focus cards and minimap click movement. Spell counsel derives from `abilities.ts`, `codex.ts` and actual discipline modifiers; native titles are replaced by readable, scrollable cards with current cooldown, cost, range, targeting, effects and tips. Cards persist while hovered/focused; Escape dismisses them before Settings opens.

Minimap clicks map from the displayed canvas/player center to world coordinates, accounting for DPR and CSS scaling. Unlocked floors/open corridors only; invalid/locked/circle-corner clicks do not replace a path. The scene uses the accepted Nav/Player path system, clears attack/interaction/queued cast/auto aim, and never adds drag steering. An amber marker tracks the actual final destination until arrival.

Follow-up verification: 131 client tests, typecheck and production build pass. Public browser smoke also verified the new spell cards/minimap UI with owner login, signup, co-op, class switching and leaderboard; the temporary test account was removed. Browser checks passed persistent/keyboard/readable spell details, hover without casting, desktop/mobile bounds, minimap arrival and fixed destinations, locked/outside rejection, DPR2 and CSS scaling.

New spell additions are **planned, not implemented** in [SPELL-VARIETY-PLAN.md](SPELL-VARIETY-PLAN.md): role-compatible loadouts and four MVP spells before class expansion. Preserve existing art, current short gestures/effects and authoritative sim boundaries. Do not assume the proposals are shipped abilities.

## Class-change migration checkpoint

The additive nullable `characters.discipline_index` column is already applied to the live `death_muffin` database. **Do not blindly rerun** `server/death-muffin/backend/migrations/001-discipline-index.sql`.

`POST /character/discipline` in `server/death-muffin/backend/discipline.cjs` accepts a character ID and discipline index 1–4, checks ownership, and updates only that override. Character responses and the leaderboard use the effective discipline while preserving original `class_index`, ID, level, items and progress. The live backend copy includes the class override endpoint. Preview checks verified all four correct models, persistence after reload, preserved inventory/gold/shards and mobile panel fit. Live API checks verified ownership, invalid inputs, all four changes preserving saved stats/gear/XP/progress and immediate leaderboard updates; the temporary test account was removed. Review `src/ui/ClassPanel.ts`, `src/scenes/WorldScene.ts`, `src/net/api.ts`, and the class-save tests together.

## Build, validation and publication

From the repository root:

```bash
npm ci
npm run build:server-rules
npm test
npm run test:server
DEPLOY_BASE=/death-muffin/play/ VITE_API_BASE=/death-muffin/api VITE_WS_BASE=https://muffindevelopment.com VITE_WS_PATH=/death-muffin/rt/socket.io npm run build
```

Approved baseline suite: **122 passing tests**; after minimap and rich spell cards, **131 passing tests**, including automatic selection, spell arrival timing/caster death/effect limits, real shipped hero anchoring/short gestures/movement blending, and class-save failures/in-flight upgrade purchases. Typecheck, both server test suites and the production build pass. Regenerate server rules when changing shared rules; do not regenerate models merely to adjust gameplay.

For a game-only update after checks pass:

```bash
sudo cp -a /home/ubuntu/vps-handoffs/DeathMuffin/game/dist/. /var/www/death-muffin/play/
curl --silent --show-error --fail https://muffindevelopment.com/death-muffin/play/ -o /tmp/death-muffin-live.html
cmp /tmp/death-muffin-live.html /home/ubuntu/vps-handoffs/DeathMuffin/game/dist/index.html
```

API edits require copying the reviewed backend files to `/home/ubuntu/death-muffin/backend/`, preserving `.env`, and restarting `death-muffin-auth.service`. Install dependencies there only if changed. The full `deploy/deploy.sh` also copies the extracted site, publishes the game, installs units/nginx configs, and restarts **both** services; use it only when those changes are needed because realtime restart disconnects co-op players.

Inspect service health with `systemctl status death-muffin-auth.service death-muffin-realtime.service --no-pager`. Public health and leaderboard endpoints are `/death-muffin/api/health` and `/death-muffin/api/leaderboard`.

Final public-site smoke passed: owner login and existing character, temporary signup/world rendering, authenticated co-op, progress, Auto toggle, UI class switching, leaderboard, redirects and unrelated sites. Test account removed; no browser errors.

Browser combat evidence: eight automatic needles during the isolated four-second fight; facing dot product1, no movement, hip drift below1e-15 after the initial turn. Toggle/menu suspend new casts, movement wins, and held Spear repeats. Numerical QA uses the actual sim/animation/effects at60 updates/s and a final screenshot, not a claim of measured home-PC rendering FPS.

## Manual smoke checklist

- Login on the new site, enter a character, confirm animated world and reconnecting co-op. Use temporary test accounts; do not repeat owner credentials in logs or documentation.
- Click ground and move the cursor elsewhere: destination remains fixed; arrival stops movement. Standing aim, path-facing, Shift-click and right-click corpse casting still work; Chrome's context menu stays suppressed over the game.
- Cast repeatedly while standing and walking: no hip/root drift, facing reversal or snapping; spell origin and impact match the target. Check frame stability during crowded fights and effect cleanup after leaving a scene.
- If auto-combat is present, check toggle on/off, manual movement/aim priority, no casting through open panels, and safe behavior with no target, no essence, death and scene changes.
- Change all four classes and reload: same character ID, level, gold, items, upgrades and saved progress; effective class updates in game and leaderboard. Failure must leave play usable and existing progress intact.
- Check help readability, HUD clicks, sound toggle, leaderboard, old-domain redirect, and availability of the unrelated sites. Hard refresh with Ctrl+Shift+R after publication.

For isolated browser work, `npm run dev -- --host 127.0.0.1 --port 5198 --strictPort` and `?offline` use the DEV-only mock backend. `window.__cwDebug` is DEV-only; keep it out of production. Existing private browser scripts in the deploy directory have scenario-specific assumptions: inspect them before running against real accounts.

## Rollback and Git

- Previous static build is saved at `/home/ubuntu/death-muffin/deploy/play.before-combat-flow-20260927`. Keep the previous static build before publishing. Roll back game code by restoring that build; retain player saves and the additive class override column.
- `/home/ubuntu/death-muffin/deploy/rollback-domain.sh` restores pre-migration nginx configs, realtime unit and game index, then restarts realtime/reloads nginx. It is a **domain migration rollback**, not a combat rollback. It retains the database.
- Origin: `https://github.com/Brbmuffins/Cross-Worlds-Web.git`; branch: `claude/adoring-knuth-hd1uox`. Domain migration commit: `6f99bc2`; accepted facing: `ceddcd5`; stable animations: `890473a`.
- Review `git log -1` for the final feature commit and `git status` before new work. GitHub authentication is configured with the dedicated repo deploy key `/home/ubuntu/.ssh/death_muffin_github` (mode600), GitHub-published host keys in `known_hosts`, and repo-local `core.sshCommand`. Origin uses SSH (`git@github.com:Brbmuffins/Cross-Worlds-Web.git`). Never copy the private key into Git or logs. This persists for future sessions on this VPS; access can be revoked from the repository Deploy keys settings.
- Use the existing private `controls-smoke.cjs --combat-review` and `--class-review` scenarios and `class-api-smoke.cjs` for relevant checks. DEV `__cwDebug.advance(seconds, false)` advances actual simulation without repeated software-GPU renders; it is not a desktop FPS benchmark. Ear-test and judge subjective combat feel in the home-PC browser.
