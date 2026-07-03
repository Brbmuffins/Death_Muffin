# Crossworlds Web — Build Plan for Claude Code

This is the operating brief for Claude Code to build out this project autonomously.
Read this file first, in full, before writing code. `ACTION_PLAN.md` in this same folder has the architecture rationale — read that too. `SERVER_OPERATIONS.md` covers the separate VPS: what gets deployed there, when, and the exact confirm-before-you-touch-it process — read it before Phase 3 or Phase 6, and follow it any time a step involves `ssh`/`scp` to `playcrossworlds.com`.

## 0. One-time setup (run these before starting Phase 1)

Install the actual threejs-game-skills skill pack so you have `threejs-game-director` and its specialists available:

```
npx skills add majidmanzarpour/threejs-game-skills --skill '*' -a claude -g -y
```

Then use `threejs-game-director` to route to `threejs-gameplay-systems`, `threejs-aaa-graphics-builder`, `threejs-game-ui-designer`, `threejs-debug-profiler`, and `threejs-qa-release` as each phase below calls for them.

Install project deps:

```
npm install
npm run dev
```

## 1. Critical rules — never violate these

- **The live auth server is real and in production.** Server: `playcrossworlds.com` (15.204.243.36), port 3000, `/opt/rod-auth/server.js`. Do not modify it unless a phase below explicitly says to add a new endpoint — and if so, only *add*, never change existing ones.
- **Old endpoints are read-only, forever**: `/login`, `/register`, `/character`, `/character/gear/equip`, `/character/position`, `/items`. Unity may still be running against these. Never change their request/response shape.
- **New `/api/*` endpoints** (`/api/inventory/*`, `/api/professions/*`, `/api/craft`, `/api/character/save-progress`) already exist server-side and are safe to call as-is — see `src/net/api.ts`, already wired.
- **Response shape for all `/api/*` calls**: `{ success: true, data: {...} }` or `{ success: false, error: "player-readable string" }` — show `error` directly in UI, don't reword it.
- **JWT**: `Authorization: Bearer <token>`, stored in `sessionStorage` via `setToken`/`getToken` in `src/net/api.ts`. Every `/api/*` call needs it.
- **Ports are frozen**: 3000 (auth), 4000 (dashboard), 7777/UDP (legacy Unity, irrelevant to this client), 3001 (Kuma). If you add a WebSocket service (Phase 3), pick a new port and document it — do not reuse these.
- **5 classes, fixed indices**: 0 Engineer (unused/no role), 1 Guardian, 2 Shadowblade, 3 Cleric, 4 Arcanist — see `src/gameplay/classes.ts`, already matches server `CLASS_NAMES`.
- **Don't touch the dashboard** (port 4000) — it's independent GM tooling, unaffected by this client.

## 2. Current state (already built — verify, don't redo)

Phase 0/1 scaffold exists in this folder:

```
src/net/api.ts          — REST client, all endpoints wired (login, character, inventory, professions, craft, save-progress)
src/net/config.ts        — API_BASE, WS_BASE (stub), MAX_PARTY_SIZE = 4
src/scenes/SceneManager.ts, LoginScene.ts, CharacterSelectScene.ts, HubScene.ts
src/gameplay/classes.ts
src/graphics/renderer.ts — shared WebGL renderer + resize handling
src/ui/ui.css
```

Flow works: Login (real `POST /login`) → Character Select (real `POST /character`) → Hub (Three.js placeholder scene, capsule mesh, 4-slot party HUD stub).

**First task: run `npm install && npm run build` and `npm run dev`, confirm the existing flow actually works end to end against the live server before adding anything.** This was scaffolded without network access to verify — treat it as unverified until you've run it.

## 3. Phases — build in order, don't skip ahead

Each phase ends with a QA gate (via `threejs-qa-release`): production build succeeds, browser console has no errors, Playwright screenshot + canvas non-blank check, desktop + mobile viewport pass.

### Phase 1 — Verify & harden the vertical slice
- [ ] `npm run build` succeeds, `npm run dev` loads, login against live server works
- [ ] Handle login failure states (bad password, server down) with visible error, no crash
- [ ] Handle character creation for all 4 real classes (1–4)
- [ ] Confirm JWT persists across a page reload (session, not permanent — that's correct)
- QA gate: screenshot of login screen + character select + hub, desktop and mobile viewport

### Phase 2 — Hub: inventory, professions, equip
- [ ] `GET /api/inventory/:characterId` on hub mount, render 4×6 bag grid (matches Unity's grid)
- [ ] Tooltip on hover (name, rarity color, stat_bonus)
- [ ] Equip/unequip calling `POST /api/inventory/equip`, recalculate displayed stats from equipped items' `stat_bonus` JSON client-side
- [ ] `GET /api/professions/:characterId` — show skill levels in a simple panel
- [ ] Gold counter on HUD already stubbed — wire to real character gold, update on changes
- Use `threejs-game-ui-designer` for grid/tooltip/panel layout and mobile touch targets
- QA gate: full inventory interaction path screenshotted, no layout overlap at mobile width

### Phase 3 — Realtime co-op layer (4-player)
This is new server work, additive only — do not touch the existing Express app's routes.
- [ ] Stand up a WebSocket service (Socket.io recommended) — new process or new port on the same box, e.g. `/opt/rod-realtime/server.js` on a fresh port (document the port choice, do not use 3000/4000/7777/3001)
- [ ] JWT-authenticated socket handshake (reuse the existing JWT secret/verification logic — read it from `/opt/rod-auth/.env`, don't duplicate secrets)
- [ ] Room = hub or arena instance, capped at `MAX_PARTY_SIZE = 4` (already defined in `src/net/config.ts`)
- [ ] Broadcast: player join/leave, position updates (throttled, e.g. 10–20Hz not per-frame), basic chat
- [ ] Client: `src/net/realtime.ts` — connect on hub mount, disconnect on unmount, render other players as capsule meshes with class-colored materials, interpolate position between updates (don't snap)
- [ ] Reject a 5th join with a clear client-side message ("Party full")
- QA gate: two browser sessions in the same room see each other move; verify with two Playwright contexts if feasible, otherwise manual two-tab verification documented in the QA report

### Phase 4 — Arena/combat (parity with the Unity Week 4 scope already planned server-side)
- [ ] Portal transition: hub → arena scene load
- [ ] Enemy spawns (start with a static/simple patrol, not full NavMesh-equivalent pathfinding — document the simplification)
- [ ] Aggro range, basic attack, hit confirm, death — client-authoritative is fine for now, note as a risk if this becomes PvP-relevant later
- [ ] Loot drop on death → `POST /api/inventory/save` with the updated slot array (reuse Phase 2's inventory sync logic)
- [ ] Realtime broadcast of enemy state so all 4 party members see the same fight (extends Phase 3's socket layer)
- Use `threejs-gameplay-systems` for combat/entity architecture, `threejs-aaa-graphics-builder` for hit VFX
- QA gate: full kill → loot → inventory update path screenshotted and verified

### Phase 5 — Crafting + progression polish
- [ ] Forge UI panel: `GET /api/recipes?profession=mining`, `GET /api/professions/:characterId`
- [ ] Craft button → `POST /api/craft`, refresh inventory on success, show `error` string on failure
- [ ] Level-up flow: XP bar, `POST /api/character/save-progress` on level-up and on hub return (not per-kill — matches existing server design intent)
- QA gate: craft path end to end with a real seeded recipe (e.g. copper_shard → copper_bar)

### Phase 6 — AAA polish + release QA
- [ ] Replace placeholder capsule/circle geometry with real environment art and character models (glTF) — source or generate (Tripo/Gemini need API keys, not set up; ask before spending on generation)
- [ ] Lighting pass, postprocessing (bloom/tone mapping), material pass via `threejs-aaa-graphics-builder`
- [ ] Full responsive/mobile UI pass via `threejs-game-ui-designer`
- [ ] Full `threejs-qa-release` evidence pass: production build, browser check, Playwright screenshots, canvas pixel check, desktop+mobile viewports, perf snapshot, visual scorecard
- [ ] Deploy: static build to `/var/www/rod/` behind the existing Nginx/Certbot setup — coordinate with the current site, don't overwrite anything unrelated

## 4. Reporting

After each phase, report: what was built, which endpoints/ports were touched (should be none outside what's listed above until Phase 3+), QA evidence gathered, and remaining risks — same bar the `threejs-qa-release` skill expects. Stop and ask before Phase 3's new WebSocket service goes anywhere near the production box's existing services.
