# Phase Reports

## Section 0 — Setup (2026-07-01)

- Node.js 24.18.0 LTS installed via winget (machine had no Node).
- `threejs-game-skills` pack installed globally: all 9 skills → `~/.claude/skills/`
  (plan's command used `-a claude`; the tool requires `-a claude-code`).
- `npm install` + approved esbuild's install script (allow-scripts policy blocked it).

## Phase 1 — Verify & harden the vertical slice (2026-07-01) ✅

**Endpoints touched:** none modified. Read/called: `/login`, `/register`, `/character`, `/api/health`.

**Findings & fixes (client only):**
- Live server on port 3000 is plain **HTTP** and sends **no CORS headers** → browser
  can't call it cross-origin. Fixed by proxying `/api`, `/login`, `/register`,
  `/character`, `/items` through the Vite dev server (`vite.config.ts`); `API_BASE`
  now defaults to same-origin. Production (Phase 6) must route through Nginx on the
  same domain the client is served from.
- **Bug:** scaffold sent `{classIndex}` to `POST /character`; server requires
  `{class_index}` (verified live: "class_index must be 0–4"). Fixed in `src/net/api.ts`.
- Added `ApiError` (status-aware), network-failure message, JSON-parse guard.
- Added resume flow in `main.ts`: page reload with a sessionStorage JWT goes straight
  to hub (or char select if no character); invalid token falls back to login.

**QA evidence (browser, live server):**
- Bad password → "invalid credentials" shown verbatim, no crash.
- Login as webtest_cw1 → hub with Guardian HUD. Reload → hub again (JWT persists).
- All 4 classes created successfully (Guardian/Shadowblade/Cleric/Arcanist,
  chars 12–15, accounts in `TEST_ACCOUNTS.local.md` — gitignored).
- UI character creation verified with Cleric (webtest_cw5).
- Canvas non-blank (screenshot), console error-free, desktop + narrow viewport.

## Phase 2 — Hub: inventory, professions, equip (2026-07-01) ✅

**Endpoints touched:** none modified. Called: `GET /api/inventory/:id`,
`POST /api/inventory/save` (test seeding), `POST /api/inventory/equip`,
`GET /api/professions/:id`.

**Built:**
- `src/net/types.ts` — shapes verified against live responses.
- `src/gameplay/stats.ts` — displayed stats = base + equipped `stat_bonus` sum.
- `src/ui/InventoryPanel.ts` — 4×6 grid, rarity colors/glow, qty + equipped badges,
  hover tooltip (name/rarity/type/stats/sell), select → detail bar with
  equip/unequip. One-equipped-per-item-type enforced client-side (swaps out the
  conflicting item first). Server's returned slot array is the source of truth.
- `src/ui/ProfessionsPanel.ts` — skill level + XP bar (next level = level×50 xp).
- `HubScene` — loads inventory+professions on mount, gold pill + stat pills with
  green bonus markers, bag/skills buttons, error toast.
- Character select redesigned as cards; **Brandolf** art = Cleric portrait
  (user directive; 3D model deferred to Phase 6 asset pass).

**QA evidence (browser, live server, char 12):**
- Equip Copper Plate → VIT 10 → 16 (+6 shown), equipped flag persisted server-side
  (verified via curl), unequip reverts. Materials expose no equip button.
- Tooltip content verified; professions panel shows Mining Lv 1, 0/50 xp.
- Console error-free; production build passes; desktop primary
  (per user: this is a desktop web game — narrow width only sanity-checked, no overlap).

**Remaining risks:**
- `POST /api/inventory/save` is client-authoritative (accepts any slot array) —
  fine for co-op, a dupe vector if the game ever becomes competitive.
- Gold changes have no source yet (loot/sell arrive in Phases 4–5); `setGold()` hook ready.

## Phase 3 — Realtime co-op layer (2026-07-01) ✅ built & QA'd locally — VPS deploy pending approval

User chose "build locally first". **Nothing has touched the VPS.**

**Built:**
- `server/realtime/server.js` — Socket.io service, port **5000** (3000/4000/7777/3001
  untouched). JWT handshake verifies the same tokens `/login` issues; in production
  the secret is read in place via `ENV_FILE=/opt/rod-auth/.env` (never copied).
  Local dev uses `DEV_TRUST_TOKENS=1` (decode-only), which hard-refuses to run with
  `NODE_ENV=production`. Rooms capped at 4; join/leave/move/chat relay; `[CHAT]`
  and join/leave logging; `/health` endpoint with room occupancy.
- `src/net/realtime.ts` — client wrapper: connect on hub mount, disconnect on
  unmount, join failures surface the server's player-readable error.
- `HubScene` — WASD/arrow movement (camera follows), position sent throttled at
  ~10Hz only when moved, remote players as class-colored capsules with lerp
  interpolation (no snapping), live party slots, chat overlay (Enter to type).
- Class colors + hero portraits centralized in `src/gameplay/classes.ts`;
  **Bo-Gar assigned to Shadowblade** (user directive), portrait on class select.
- Deploy package ready for review: `server/realtime/DEPLOY.md` +
  `rod-realtime.service` (systemd unit) — exact commands, verification, rollback.

**QA evidence (local service + live-issued JWTs):**
- Browser (Guardian) + headless bot (Shadowblade, real `/login` token): both saw
  each other join; bot received 13 move events from 1.2s of browser movement
  (~10Hz throttle confirmed); remote capsule rendered violet and visibly orbited
  between screenshots (interpolation working).
- 4 players filled the room; 5th join rejected with "Party full" (client shows it
  as a toast; server logged the rejection).
- Chat both directions with `[CHAT]` server log lines.
- Clean leaves: slots revert to "Open slot", meshes removed.
- Hub works solo when the realtime service is down (toast, no crash).
- Browser console error-free; production client build passes (505kB chunk-size
  warning — code-splitting noted for Phase 6).

**Next:** user reviews `server/realtime/DEPLOY.md` and gives the go-ahead for the
VPS step, then Phase 4 (arena/combat) can proceed on top of the local service in
the meantime.

## Phase 4 — Arena & combat (2026-07-01) ✅ (local realtime service)

**Endpoints touched:** none modified. Called: `POST /api/inventory/save` (loot),
`GET /api/inventory/:id`. Realtime service extended locally (host designation +
`arena:event` relay) — still not deployed.

**Built:**
- `src/scenes/ArenaScene.ts` — portal transition hub ↔ arena (walk into the
  torus), red-lit arena, HP bar HUD, kill counter, floating damage numbers,
  hit-flash on enemies, death → respawn at entrance.
- `src/gameplay/enemies.ts` — host-simulated slimes: waypoint patrol
  (documented simplification: no NavMesh), aggro range 5, chase, contact damage,
  8s respawn, **leash radius 7 + far-half spawn homes** (added after playtest
  exposed an entrance death-loop), regen while returning home.
- `src/gameplay/loot.ts` — DropTable equivalent (60% shard, 25% bar, 10% ring,
  5% nothing), stacks materials, full-array `POST /api/inventory/save` on pickup,
  drop respawned in-world if the save fails.
- Realtime: room host simulates enemies and broadcasts state at 10Hz via a
  server-side relay; non-hosts send hit events to the host; host promotion on
  leave. Documented simplification: client-authoritative combat + per-player
  loot rolls — fine for PvE co-op, a dupe/cheat vector if PvP or economy ever
  matters.

**QA evidence:**
- Full path verified twice against the live DB: kill → loot drop → pickup →
  `/api/inventory/save` → quantities confirmed via curl (shards 5→6→9, bars 2→3)
  and in the bag UI back in the hub.
- Second client in the arena room received 95 enemy broadcasts in 10s (~10Hz).
- Playtest found and fixed: enemy pack camping the entrance (leash + spawn fix,
  re-verified: full HP at entrance, survivable engagements at 85/100).
- Portal both ways verified; console error-free throughout.

## Phase 5 — Crafting + progression (2026-07-01) ✅

**Endpoints touched:** none modified. Called: `GET /api/recipes?profession=mining`,
`POST /api/craft`, `POST /api/character/save-progress`, `GET /api/professions/:id`.

**Findings & fixes:**
- Recipe ids are **strings** (`recipe_copper_bar`), not numbers as the scaffold's
  `craft()` assumed — fixed. Craft returns `{updatedInventory, updatedProfession}`.

**Built:**
- `src/ui/ForgePanel.ts` — 🔥 button in hub; recipe list with skill requirement
  and per-ingredient have/need coloring; Craft disabled until both are met;
  server error strings shown verbatim; inventory + professions + stats all
  refresh from the craft response.
- XP/level: `Lv` + `XP n/level×100` pills in hub HUD; arena kills bank +10 XP
  locally (kills pill shows the running total); on hub return the client levels
  up as needed and fires `POST /api/character/save-progress` (level-up/hub-return
  only, not per-kill — matches server design intent); "+N XP" / "Level up!" toast.

**QA evidence (browser, live server, char 12):**
- Real seeded recipe crafted end to end through the UI twice: shards 6→3→0,
  bars appearing in the bag, Mining xp 10→30 (30/50 shown in professions panel).
- Gating verified: bar recipe disabled at 0 shards; ring/plate/sword disabled at
  Mining 1 (server rejection "requires mining level 5 (you have 1)" also
  curl-verified).
- Kill → return loop: 2 kills → "+20 XP" toast, XP pill 20/100, and
  `GET /character` on the live server confirms `experience: 20` persisted.
- Console error-free; production build passes.

## Diablo-style control conversion (2026-07-01) ✅

User directive: top-down "clicker" playstyle mimicking the Unity project, abilities on 1–4.

**Built:**
- `src/gameplay/movement.ts` — click-to-move via ground-plane raycast (hold to
  steer); WASD kept as fallback; walk radius clamped.
- `src/gameplay/abilities.ts` — per-class kits on 1/2/3/4 (basic 0.5s cd /
  heavy 2.2× 4s / nova AoE 1.5× 6s / ult AoE 3× 12s). Melee classes strike,
  Cleric/Arcanist fire ranged bolts (range 7/8). Class-colored VFX.
- Arena: click an enemy → auto-chase into range and auto-attack (Diablo
  behavior); bolt-line VFX for ranged, expanding ring for novas; Diablo-style
  ability bar (bottom-center, key badges, cooldown sweep overlays, clickable).
- Both scenes: top-down camera (offset 0,12,7, FOV 50).
- Bundle code-split: three.js in its own chunk (app code now 90kB).
- `git init` run (repo was never initialized despite docs); files staged,
  first commit left to the user's GitHub Desktop flow.

**QA evidence:** click-to-move verified in hub (portal entered by clicking);
single click on a slime auto-chased across the arena and killed it (+10xp);
abilities 3/4 cast with cooldown sweeps at 90%/95% draining; death → entrance
respawn intact; console error-free; production build passes.

**Tuning note:** difficulty is spicy — 2–3 slimes can kill a fresh Guardian.
Balance pass queued for Phase 6 polish.

## Fantasy login redesign (2026-07-01) ✅

User directive: fantasy, interactive login incorporating the Crossworlds logo.

**Built:**
- Logo (`Inspiration ART` → `public/art/crossworlds-logo.png`) floats above the
  panel as a circular medallion (border-radius crop over the source's black
  square), levitation + purple/teal glow-pulse animation.
- `src/graphics/loginBackdrop.ts` — animated crystal-shard field on the Three.js
  canvas in the logo's palette (purple/teal/gold), slow drift + spin, **mouse
  parallax** camera sway. Shared by login and character select.
- Fantasy panel: gold/purple frame glow, gold labels ("Hero Name", "Secret
  Word"), shimmering "Enter the World" button, error **shake** animation.
- **Register mode** ("No legend yet? Forge a new hero") — email field +
  "Forge Your Legend", wired to the existing `POST /register` (returns a token,
  verified live — no second login call needed).

**QA evidence:** bad password → "invalid credentials" + panel shake; forge mode
registered webtest_cw7 through the UI and landed on character select (which now
shares the backdrop, Bo-Gar/Brandolf portraits intact); console error-free;
production build passes.

## 2026-07-02 — Transparent logo + turnkey deploy prep

- Swapped in the user's transparent logo (`updated Logo.png` → RGBA verified,
  colorType 6). Removed the circle-crop; it now shows full with the integrated
  CROSSWORLDS wordmark, crowning the panel and blending into the backdrop.
  Verified in browser; console clean; local realtime still connects.
- **Realtime deploy made turnkey but BLOCKED on SSH.** `ssh ubuntu@playcrossworlds.com`
  → `Permission denied (publickey,password)`; can't do interactive password auth
  non-interactively. Prepared for one-shot deploy once access is granted:
  - Switched routing to **Nginx wss reverse proxy** (required — HTTPS page can't
    open ws://:5000; mixed content). Service now binds `127.0.0.1:5000` only
    (`REALTIME_HOST`), no new public firewall port.
  - Configurable socket path (`REALTIME_PATH` server / `VITE_WS_PATH` client),
    default `/rt/socket.io` in prod, library default locally (dev unchanged).
  - Added `server/realtime/nginx-realtime.conf` (location block to paste into the
    existing 443 vhost) and rewrote `DEPLOY.md` with backup/verify/rollback.
- **Art generation BLOCKED on API keys.** No `TRIPO_API_KEY` (3D) or
  `GEMINI_API_KEY` (2D) in the environment (checked process + Windows user/machine
  env). Cannot generate until keys are provided.

## 2026-07-02 — Front-end deploy made turnkey (/play)

- `server/web-deploy/` — `deploy-web.sh` + `crossworlds-web-play.tar.gz`. User
  uploads both to the VPS and runs `sudo bash deploy-web.sh`. Serves the game at
  `https://playcrossworlds.com/play/`; root site + Unity page untouched.
- Production wiring baked into the build (verified in the artifact):
  - `DEPLOY_BASE=/play/` → assets resolve at `/play/assets/…`
  - `VITE_API_BASE=/authapi` → REST calls go same-origin; nginx `location
    /authapi/` proxies to `127.0.0.1:3000` (fixes CORS + mixed content; auth
    server unmodified)
  - `VITE_WS_BASE=https://playcrossworlds.com` + `VITE_WS_PATH=/rt/socket.io`
  - sourcemaps disabled for the prod bundle (don't publish source)
- vite.config.ts now takes `DEPLOY_BASE` (dev unchanged, stays relative).
- Script verified locally: `bash -n` clean, nginx double-block insertion
  dry-tested (backup + `nginx -t` + auto-restore guard), tarball extract confirmed.
- Still needs the user to run it (SSH from this machine denied). Realtime deploy
  script (`server/realtime/deploy-realtime.sh`) is the companion for co-op.

## Phase 6 — Art pass (2026-07-02) ✅ 2D complete

**Gemini image generation — 34 assets generated (billing enabled, $150 account):**

- `public/art/abilities/` — 16 ability icons (4 per class × 4 classes) at 1K:
  guardian-1–4, shadowblade-1–4, cleric-1–4, arcanist-1–4
- `public/art/items/` — 3 item icons at 1K:
  material_copper_shard, material_copper_bar, ring_copper
- `public/art/status/` — 10 status effect icons at 1K (for COMBAT_PROPOSAL.md states):
  void-rot, burning, cursed, renewal, triage, hemorrhage, scorched,
  void-collapse, withered, sanctified
- `public/art/vfx/` — 5 hit impact sprites at 1K:
  hit-physical, hit-void, hit-holy, hit-frost, hit-fire

**Wired into game:**
- `abilities.ts` — `Ability` interface gains `iconPng: string`; `kit()` derives path
  from class slug; `KIT_BASE` Omit updated. Emoji `icon` kept as fallback.
- `ArenaScene.ts` — ability bar renders `<img src=iconPng>` with `onerror` emoji
  fallback (`data-fallback` attribute + CSS `::after` content).
- `InventoryPanel.ts` — `ITEM_ICONS` map (item_id → PNG path); copper shard/bar/ring
  now show art icons; unknown items fall back to `TYPE_GLYPHS` emoji.
- `ui.css` — `.cw-ability .icon img` fills slot (100% cover); `.cw-slot .item-icon`
  fills cell (100% cover); emoji fallback via `[data-fallback]::after`.
- TypeScript clean (tsc --noEmit passes); HMR reloads confirmed, no console errors.

## Phase 6 — 3D models wired + asset pipeline (2026-07-03) ✅

**Keys arrived (`.ai-keys.local`).** Discovered the five character models were already
generated on 2026-07-02 (raw Tripo outputs, task JSONs preserved); killed a duplicate
Brandolf pipeline mid-generation (~30 credits spent, rig/retarget credits saved).

**Asset pipeline — `tools/build-models.mjs` (repeatable):**
- Raw Tripo outputs (1.7GB) moved `public/models/` → `art-src/tripo/` (gitignored).
- Per character: rig.glb (2.4MB — simplify 1.5M→~75k tris, 1K WebP, quantize) +
  per-clip GLBs (~0.1MB each, geometry stripped). **Total shipped: ~13MB, was 1.7GB.**
- Stable paths (`models/<slug>/rig.glb`, `idle.glb`, …) — `modelPaths.ts` has no UUIDs.

**Bugs found & fixed:**
- `CLASS_TO_MODEL` was 0-based but server classes are 0=Engineer, 1=Guardian, 2=Shadowblade,
  3=Cleric, 4=Arcanist — a Guardian loaded Bo-Gar's model. Fixed (Engineer → capsule fallback).
- Character rendered **prone**: Tripo v1.0 GLB-rig rest space ≠ FBX clip space (documented
  Tripo limitation). Fixed by deriving rig.glb from the idle FBX (same family as clips).
- Model microscopic: hardcoded `scale 0.01` invalidated by quantize; CharacterModel now
  normalizes by measured bounds to TARGET_HEIGHT 1.8 and grounds feet at y=0.
- Root motion: strip HORIZONTAL `Root.position` only, at clip load (verified track present).

**Wired:** HubScene local player + remote players (capsule hidden on load, walk/idle by
movement, dispose on leave/disconnect/unmount). ArenaScene already had local-player wiring.

**QA (live server, headless canvas-pixel checks — preview screenshots flaky):**
- Guardian (webtest_cw1): upright 1.8u, feet y=0, 5 clips incl. attack, 41-track walk,
  warm armor pixels at screen center. Console error-free.
- Cleric/Brandolf (webtest_cw3): upright, 4 clips, muffin-gold + white-coat pixels center.
- tsc clean; only expected failure is realtime :5000 (service not running locally).

**Remaining — Phase 6:**
1. **Brandolf attack clip** — one 10-credit `animate_retarget` (`preset:slash` or
   `preset:biped:*` pick) against his rig task ID (in `art-src/tripo/brandolf/rig/*.json`),
   then `node tools/build-models.mjs brandolf`.
2. **Slime model** into `enemies.ts`/ArenaScene (replace sphere mesh; `models/slime/rig.glb`,
   no clips — bob/squash procedurally).
3. BossScene + CharacterSelect still capsules/portraits (optional 3D preview).
4. Items 2–4 of the previous list (deploy, code-split, VFX billboards) unchanged.

**Previous remaining list (2026-07-02):**
1. **3D models via Tripo** ($150 account): Brandolf (Cleric glTF), Bo-Gar (Shadowblade),
   Guardian, Arcanist, Slime enemy — `character-pipeline` with idle/walk/run animations.
   ~$10/character; wire in via GLTFLoader + AnimationMixer replacing capsule meshes.
2. **Deploy**: static build → `/var/www/rod/` + rod-realtime service → VPS —
   user runs `deploy-web.sh` + `deploy-realtime.sh` (SSH from dev machine denied).
3. **Code-split** the 575kB bundle (Vite chunk warning, noted for Phase 6).
4. **Combat VFX upgrade**: use `hit-*.png` sprites as Three.js billboards
   (SpriteMaterial + AdditiveBlending) replacing plain ring/line geometry.
