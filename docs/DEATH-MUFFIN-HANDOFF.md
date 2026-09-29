# Death Muffin agent handoff

Last deployment recorded here: 2026-09-28. Read this before editing or deploying.
Preserve the supplied site's visual design and the accepted fixed click-to-move
behavior. This is a dated release and operations record; for later local work,
read [HANDOFF](../HANDOFF.md) and [the documentation map](README.md).

User-approved complete version: **`death-muffin-v1.0.0`**. See [the checkpoint record](DEATH-MUFFIN-CHECKPOINT.md) for the full private backup and restoration boundaries. Preserve this baseline while designing new abilities.

## AFK gathering visual polish — 2026-09-28

Published the client-only update from `codex/new-blood-release-20260928`. Woodcutting, mining, fishing and gravedigging now equip their generated hand tools during work and restore class gear when work stops. Woodcutting and mining use the hero's `attack` swing where available. The ground circle stays on the selected node during walking, work and respawn waits; the existing progress arc stays under the hero. The four tool GLBs were already on the live site. No API or realtime service changed or restarted.

Typecheck, production build, AFK background/pause/full-bag smoke, four-tool browser size and circle checks, Hollow Knight gear-swap check, and ground-ring tests passed. The previous live index is backed up at `/home/ubuntu/death-muffin/backups/pre-gather-tools-20260928T183608Z/index.html`; old hashed bundles remain served for a client-only rollback.

## New Blood class framework + five kits — 2026-09-28 (deployed)

Grave Warden (`discipline_index` 5), Bell Monk (6), Carrion Witch (7), Hollow Knight (8), and Veilwalker (9) now have client kits, host rites, resources, art registration, Codex, and help. The Grave Warden leaderboard collision with legacy class index 5 is resolved by returning `hasDiscipline` from the backend leaderboard route. The release and public browser verification passed on 2026-09-28.

The class release published the client, Death Muffin backend (`discipline.cjs`, `server.js`), realtime service (`server/realtime/server.js`) and `site/leaderboard.js`. Public QA created a Grave Warden, switched through all five classes, loaded each hero model, exercised the in-game class switch and checked the leaderboard. The temporary account was removed. Its verified pre-release backup is `/home/ubuntu/death-muffin/backups/death-muffin-v1.0.0-20260928T175414Z`. No migration was needed: `discipline_index` was already nullable.

The framework is additive and the four necromantic disciplines are provably unchanged —
`resources.test.ts` pins the old essence numbers (60% on spawn, 50% on revive, unconditional
`essenceRegen`) and `kits.test.ts` pins the necromancer kit against the original constants.

- **Families.** `Discipline.family` + `ClassFamily`; per-family resource rules and kits. The HUD's
  right orb takes its label and colour from the family (violet Grave Essence, oath-crimson Rage).
- **Server.** `discipline.cjs` accepts 1–`maxIndex` (mounted at 9). `DISCIPLINE_NAMES` is a *separate*
  map from the legacy `CLASS_NAMES`, so indices 1–4 keep reporting the `class_name` they always did.
- **Hollow Knight** (`discipline_index` 8): Rage, seven rites, sword + shield on the rig. Shield Bash,
  Corpse Vigil and Grave Brand go through the host as new `sig` kinds; Hollow Cut and Grave Slam are
  client-resolved like Ivory Cleave. New enemy statuses `stunT`/`rootT` (snapshot bits 17/18).
- **Historical release gap:** the first class build had no boss stagger hook.
  The current source has `BossBrain.stagger()` and a Shield Bash boss call;
  verify its deployment separately. The leaderboard index-5 collision was
  resolved in the New Blood follow-up above.

Green after the follow-up: typecheck, 265 client tests (19 Knight, 18 framework regression, 3 new creation/loadout checks), 41 server, 3 VFX, production build.

Follow-up browser check fixed first-time Knight selection: `POST /character` creates its separate
legacy index-5 slot, then `/character/discipline` sets index 8. The offline mock mirrors both steps.
At level 1 the locked Bulwark and Corpse Vigil sockets remain defined, so the HUD and world mount;
casting is still level-gated. Offline browser play confirmed the Rage orb, seven sockets, Knight
model and sword/shield GLBs with no console errors. Help labels now use Grave Brand for the Knight.

## Movable counsel and Acre lighting — 2026-09-27

Covenant counsel starts on the left below the portrait. Drag its labeled header (pointer/touch), or focus it and use arrow keys (Shift moves further). Dragging leaves the card open and never reaches game movement handlers. The per-viewer `dm_counsel_position_v1` preference is guarded browser storage, shared across cards and characters; queued tips/reloads retain it, and viewport changes clamp the card on screen. Body click dismissal, timer pausing and the disable-tips control still work. Dragging ends the entrance animation so it cannot jump when released. The resize listener is removed on world disposal.

The sawpit has a static pale gold ground ring and warm light pool, using the existing five dynamic-light slots. No extra point lights or shadows are added. The Acre's initial spawn now calls its normal area-entry lighting setup instead of keeping Chapterhouse colors. Ambient sky/ground fill is modestly brighter, with hemisphere intensity 1.12 and moon 2.65 in the Acre. Nightfall does not darken this safe gathering area. Combat retains its existing .95/2.4 intensities and Nightfall behavior. Help and Settings describe moving counsel and the sawpit cue.

Validation: 196 client tests, server suites, production build and `tools/qa/counsel-lighting-smoke.cjs`. Browser verification covers drag/keyboard controls without hero movement, queued-card and reload persistence, small-viewport clamping, disabling tips, correct initial lighting, sawpit beacon and unchanged total combat light count (12). Public smoke also confirms drag/reload persistence, login, authenticated co-op, class switching and existing routes, with no browser errors; the temporary account was removed. Private screenshots: `acre-counsel-moved.png` and `acre-lighting.png` in the deployment folder. Generated backend rules and running copies are synchronized by the deployment script.

Verified pre-update backup: `/home/ubuntu/death-muffin/backups/death-muffin-v1.0.0-20260927T212922Z`. Its checkpoint label is historical; live-site/runtime/database archives capture production immediately before this change. Restore code independently of newer player data.

## Acre starter polish — 2026-09-27

Fixed fishing markers moving around the world origin: the old animation scaled their entire instanced batch, including world coordinates. Ripples now gently pulse opacity in place, with fewer, smaller rings. No node positions move with this animation.

Repositioned existing beginner nodes while preserving IDs: two Coffin-Oaks north of the entrance, Copper Seam at (-31.5, 20.2), Pauper’s Grave at (-28.5, 21.5), and Still Pool at (-31.5, 28.2). Every gathering skill now has an unlocked node within ten units of spawn, and nearby trees are all level 1. Beginner work has a 60% base success chance (previously 45%); Hangman’s Elm unlocks at 5 (previously 15), Bleeding Willow at 15 (previously 30). Other gates, yields, XP per success and hourly limits are preserved. Shared TypeScript and generated API rules ship together. Help, Skills hints and the README reflect the starter path.

For the reported black rectangle during digging, removed the custom shader plane from work progress and replaced it with actual RingGeometry using a standard transparent material. Hover cards have explicit content sizing, height limits and viewport clamping. The original large black rectangle was not reproduced in VPS Chromium; these changes remove the shader rectangle and bound the only node hover overlay. Low/high graphics mouse checks and screenshots are in the portable Acre smoke test and private deployment artifacts.

Deployment now runs `npm run build:death-muffin` itself, setting all production API/socket/base paths and suppressing source maps. A generic local build was briefly published during this pass; the public smoke caught its login redirect, the correct production build replaced it, and its two source maps were moved into private storage.

Validation: 196 client tests, server suites and production build; new regressions cover anchored fishing markers, ring bounds and level-1 access to every gathering skill. Low/high mouse interaction checks and AFK full-bag regression pass. Public smoke passes login, authenticated co-op, class changes, gathering persistence/authorization, background AFK saves and pause/reload stopping; test accounts were removed and no browser errors remain. Backup before publishing: `/home/ubuntu/death-muffin/backups/death-muffin-v1.0.0-20260927T162747Z` (verified full live-site/runtime/database snapshot; its checkpoint label is historical). Roll back code without overwriting newer player progress.

## AFK and ten-player release — 2026-09-27 15:30 UTC

Deployed from the canonical `game` repository using [the versioned deployment script](../server/death-muffin/deploy-afk.sh). It updates gathering rules/routes, restarts the API and realtime services, and publishes assets before the index while retaining previous hashed bundles. The older VPS `deploy-update.sh` now also reads this repository, not the stale extracted `update-stage`. No migration or dependency changes were needed. Both running services are healthy, and their updated source copies match the repository.

**AFK professions:** enter the Acre, press **P**, choose an unlocked tier and Start AFK. The existing gathering loop walks between matching nodes and waits for respawn even when ordinary Auto gathering is disabled. A full bag pauses work; clear space and restart. Skills may stay open; movement, casts, recall, other panels and Pause AFK cancel the session. Hidden tabs run capped simulation updates without rendering and save server-rolled inventory/XP. Closing/reloading ends the session; it does not resume or grant offline rewards. Browsers that suspend a tab may delay work, and each background wake is capped at 90 seconds. The authenticated AFK-start endpoint resets elapsed-time credit; AFK requests have no normal burst allowance and preserve hourly caps, ownership and level checks. The budget consumes accepted action time so multiple catch-up batches cannot reuse it.

**Co-op:** client, server and embedded realtime installer now allow ten players per world. Public matchmaking fills a world, then opens another; an explicit full world rejects an eleventh player. Party HUD scrolling keeps it clear of bottom controls. Enemy/effect limits and update rates are unchanged. The browser test joined nine socket clients to a rendered host and verified ten visible party members, chat, shared gathering depletion, guest combat and host migration. With 40 enemies, two low-quality software-renderer runs measured solo CPU update 2.72–3.29 ms and ten-player averages 3.50–4.00 ms. Draw calls increased 119→164 and rendered triangles 416,151→514,520; no extra lights were introduced. These CPU measurements do not promise identical GPU FPS on all devices.

Validation: 193 client tests, server suites, production build, combat input regression and AFK full-bag/pause/resume checks passed. Public smoke verified existing-account login, signup, authenticated co-op, class changes, saved gathering inventory/XP, authorization gates, hidden-tab AFK rewards, Pause AFK and reload ending the session, redirects and other sites, with no browser errors. Temporary accounts and ledgers were removed. Reproducible checks and their setup are in [tools/qa](../tools/qa/README.md); private results/screenshots remain under `/home/ubuntu/death-muffin/deploy/`.

Verified backup before this release: `/home/ubuntu/death-muffin/backups/death-muffin-v1.0.0-20260927T150545Z`. Roll back code independently of newer player progress. The user explicitly requested committing all work; source, tests, deployment tooling and documentation are committed together. Use `git log -1` for the release commit.

## Live update — 2026-09-27 14:53 UTC

The `Updates.zip` handoff is deployed from Git `e29dc08`, plus the staged spawn and node-rendering changes in this workspace. Professions/gathering, the Sexton's Acre, node art, the Grimoire and implemented spell effects are live. Migration `002-gathering.sql` is applied to `death_muffin`; the profession ID column was already VARCHAR(32). The API and realtime copies are updated, including shared node depletion and new rite intents. Player progress was preserved.

Players now enter at the fixed Acre entrance spawn (-26, 20), beside beginner gathering nodes. The welcome tip points to gathering and the east → Chapterhouse → north → combat route. Recall and death recovery still return to the Chapterhouse. Class changes remount at the Acre. **P** opens Skills; **L** opens the Grimoire.

Node rendering batches by area, hides completely inactive batches and refreshes bounds after depletion/respawn. Same 40-enemy low-quality browser comparison: baseline 122 draw calls / 415,769 triangles / median 1.857 ms CPU update; release 121 / 416,155 / 1.935 ms. These are headless software-renderer measurements, not a promise of hardware FPS. Combat browser checks confirm eight auto attacks in four seconds, stable aim/animation anchoring, fixed click movement and held casts. 190 client tests, server suites, portable VFX checks and production build pass.

Public browser verification passed owner login, signup, authenticated co-op, class switching, progress, spell cards, minimap, Skills, gathering inventory/XP persistence, level and ownership gates, leaderboard and redirects, with no browser errors. The temporary account and gather ledger were removed. Evidence is in `/home/ubuntu/death-muffin/deploy/update-performance.json`, `update-performance.log`, `update-client-tests.log`, `update-build.log` and `live-professions.png`. Deployment script: `deploy/deploy-update.sh`.

The converted 22-effect Binbun asset pack is published, but its Three.js runtime/hooks are still unimplemented in the supplied source. Do not describe these effects as active. The shipped game retains its managed spell effects and new skull/frost/bone sprites.

Verified pre-update backup: `/home/ubuntu/death-muffin/backups/death-muffin-v1.0.0-20260927T144330Z`. Its live-site/runtime/database archives captured production immediately before this release. Roll back code only if needed; never import its database over newer player progress merely to roll back visuals.

## Existing Claude foundation

This builds on the supplied Claude project, not a replacement game. Read `CLAUDE.md` for the architecture and `HANDOFF.md`/`PHASE_REPORTS.md` for already shipped systems. This Death Muffin handoff adds the current VPS deployment state; historical ports, Windows paths and pending-server statements in those earlier documents are not the live Death Muffin configuration.

- `NECROMANCER_REDESIGN_AUDIT.md`: connected world → waves → corpses as minions/spell fuel → loot → damage/wave upgrades → new areas. Keep that loop.
- `docs/agent-briefs/combat-depth.md`: the combat depth pack is already shipped. Preserve host-authoritative **Intent → WorldSim → SimEvent → VFX/audio/rewards**; polish presentation/input without inventing a second damage path.
- `src/content/abilities.ts` (`SPELL_FX`) and `FUTURE_CONTENT.md`: bone ivory/amber; marrow ember/crimson; spirit jade/teal; rot chartreuse/olive; ritual violet; enemy bells bronze. Readability needs distinct shapes/timing as well as colour.
- `CLAUDE.md`: new mechanics need their Onboarding counsel tip, Codex entry, Settings keys and README guidance. Keep known live item IDs and the legacy class/client discipline index mappings in sync.
- `BALANCE.md`, `src/gameplay/balance/harness.ts`, `npm run balance` and `npm run balance:boss`: existing deterministic farming/combat bot harnesses; reuse them before designing future persistent live bots.
- `docs/agent-briefs/environment.md`: desktop 60 fps, high/low quality fallbacks, capped effects and no allocations in hot loops. Existing managed Effects/runtime should own updates and disposal.
- `.claude/launch.json` is a Windows preview configuration (ports 5188/5000). Use the VPS dev command below here.

Historical prohibitions on changing the original shared REST server still protect that server. Current user authorization covers this separate Death Muffin installation and local Git commits; it does not authorize editing unrelated applications or publishing secrets.

## Current outcome and active work

- Live site: https://muffindevelopment.com/death-muffin/; game: `/death-muffin/play/`; leaderboard: `/death-muffin/leaderboard.html`.
- Old `playcrossworlds.com/death-muffin/` URLs return 308 redirects to the new domain, preserving path and query. Other Crossworlds and Muffin Development routes remain independent.
- Completed: separate accounts/progress/co-op, login effects and sound, leaderboard, readable help, fixed click destinations, stable hero animation roots, correct model facing. Standing heroes aim at the mouse; walking heroes face their path. Holding or moving the mouse must not retarget movement.
- **Published 2026-09-27 and tested:** free class changes from Settings, and the combat polish pass. Class changes save inventory/progression first, preserve the character ID and original class slot, and return to the Chapterhouse.
- Combat direction: easy, readable Three.js combat for relaxed grinding, while remaining engaging to watch. On Easy, auto combat is enabled by default and toggled with `G` or the HUD button. The 2026-09-28 New Blood branch extends it to engage enemies within the current combat area, dodge close windups, use equipped rites and signatures, drink flasks, and recover health under attack; Hollow Knight auto guards. Manual paths, keys, targets, panels and gathering take priority. Easy enemy damage is 0.3×. Medium/Hard remain manual and keep their previous damage values. Hold 1–4 to repeat at the cursor; short input buffering absorbs near-ready casts. Cast recovery is 60–160ms and gestures .22–.48s. Spear and Miasma hits arrive with the visuals; delayed impacts cancel on caster death. Smoke, shake and particle counts are reduced; cosmetic meshes cap at 160 and projectile meshes are pooled.
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

At this 2026-09-27 checkpoint, additions in [SPELL-VARIETY-PLAN.md](SPELL-VARIETY-PLAN.md)
were proposals. Several rites and the Grimoire were built and published later;
check source and the newer release entries above before using that plan as a task list.

## Class-change migration checkpoint

The additive nullable `characters.discipline_index` column is already applied to the live `death_muffin` database. **Do not blindly rerun** `server/death-muffin/backend/migrations/001-discipline-index.sql`.

`POST /character/discipline` in `server/death-muffin/backend/discipline.cjs` accepts a character ID and discipline index 1–`maxIndex` (9 in the 2026-09-28 release), checks ownership, and updates only that override. Character responses and the leaderboard use the effective discipline while preserving original `class_index`, ID, level, items and progress. The live backend copy includes the class override endpoint. The initial 1–4 preview and API checks verified correct models, persistence after reload, preserved inventory/gold/shards, ownership and invalid inputs; the later New Blood release checked all five added classes. Temporary test accounts were removed. Review `src/ui/ClassPanel.ts`, `src/scenes/WorldScene.ts`, `src/net/api.ts`, and the class-save tests together.

## Build, validation and publication

From the repository root:

```bash
npm ci
npm run build:server-rules
npm test
npm run test:server
npm run build:death-muffin
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
- On Easy, check auto-combat toggle on/off, equipped rites and conditional signatures, manual movement/aim priority, no casting through open panels, and safe behavior with no target, no resource, death and scene changes.
- Change through all nine classes and reload: same character ID, level, gold, items, upgrades and saved progress; effective class updates in game and leaderboard. Failure must leave play usable and existing progress intact.
- Check help readability, HUD clicks, sound toggle, leaderboard, old-domain redirect, and availability of the unrelated sites. Hard refresh with Ctrl+Shift+R after publication.

For isolated browser work, `npm run dev -- --host 127.0.0.1 --port 5198 --strictPort` and `?offline` use the DEV-only mock backend. `window.__cwDebug` is DEV-only; keep it out of production. Existing private browser scripts in the deploy directory have scenario-specific assumptions: inspect them before running against real accounts.

## Rollback and Git

- Previous static build is saved at `/home/ubuntu/death-muffin/deploy/play.before-combat-flow-20260927`. Keep the previous static build before publishing. Roll back game code by restoring that build; retain player saves and the additive class override column.
- `/home/ubuntu/death-muffin/deploy/rollback-domain.sh` restores pre-migration nginx configs, realtime unit and game index, then restarts realtime/reloads nginx. It is a **domain migration rollback**, not a combat rollback. It retains the database.
- Origin: `https://github.com/Brbmuffins/Death_Muffin.git`; branch: `claude/adoring-knuth-hd1uox`. Domain migration commit: `6f99bc2`; accepted facing: `ceddcd5`; stable animations: `890473a`.
- Review `git log -1` for the final feature commit and `git status` before new work. GitHub authentication is configured with the dedicated repo deploy key `/home/ubuntu/.ssh/death_muffin_github` (mode600), GitHub-published host keys in `known_hosts`, and repo-local `core.sshCommand`. Origin uses SSH (`git@github.com:Brbmuffins/Death_Muffin.git`). Never copy the private key into Git or logs. This persists for future sessions on this VPS; access can be revoked from the repository Deploy keys settings.
- Use the existing private `controls-smoke.cjs --combat-review` and `--class-review` scenarios and `class-api-smoke.cjs` for relevant checks. DEV `__cwDebug.advance(seconds, false)` advances actual simulation without repeated software-GPU renders; it is not a desktop FPS benchmark. Ear-test and judge subjective combat feel in the home-PC browser.
