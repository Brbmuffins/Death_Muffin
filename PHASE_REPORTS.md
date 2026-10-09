# Phase Reports

> **OBSOLETE (archived 2026-10-09).** Chronological build log of the frozen web game (July to September 2026). History only; see [docs/ARCHIVE.md](docs/ARCHIVE.md) and [godot/REBUILD.md](godot/REBUILD.md) for current status.

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

## Combat depth pack (2026-09-26) ✅ sim + unit tests + in-browser QA
Folded into master (commit `08c62b0`). In-browser QA 2026-09-26 (cloud session, headless Chromium):
Bell-Tolled bronze telegraph + affix tag/blurb in the target frame, Corpse Explosion burst on an
elite resonant corpse (damage number, corpse consumed), Grave Surge opening, Soul Harvest
charge → free, enlarged Black Litany; no console errors. All host-authoritative via Intent → WorldSim → SimEvent.
- **Corpse Explosion** (RMB, also key 5; hotbar slot 5): `detonate` intent names a corpse
  and claims `spellPower × 1.8` (clamped by server + sim). Host owns the 3m radius;
  resonant ×1.6 radius, elite ×2 damage, toxic leaves a friendly `rot` zone. 15 essence,
  0.6s. Ember/crimson burst + bone shrapnel; refund on `ok:false`.
- **Elite affixes** (every elite rolls one; snapshot `EnemyRow[13]` = affix index + 1):
  Bell-Tolled (6s anchored bronze ring r=3 → `hurt from:'toll'` + 0.5s stun), Hungering
  (every 4s, if wounded, devours a corpse ≤5m → +15% HP, `corpseGone reason:'devoured'`),
  Shrouded (×0.5 damage taken unless inside a player's miasma/rot; dimmed until revealed),
  Vengeful (3 Risen on death). Affix tag + blurb in the target frame.
- **Grave Surges**: after 100s (then 90–150s) of combat in an open unsafe area, a breach
  cracks open (`surge`), three waves at +1.5/7.5/13.5s; kill ≥80% before 20s →
  `surgeCleared` (personal guaranteed `rollItem` + bonus gold), else `surgeFailed`.
- **Soul Harvest** (client-only): kills credited to you/your thralls fill a 50-soul skull
  meter above the slots; charged → next Marrow Spear / Miasma / Black Litany is free and
  50% larger. Realtime litany radius clamp raised 10 → 11 for the empowered litany.
- DEV hooks: `__cwDebug.spawn(def, true, affix)`, `.surge()`, `.souls(n)`, `.corpse(kind, elite)`.
- Tests: +12 sim (detonate, each affix, surge lifecycle), +2 systems, +2 realtime.

## Environment set pieces (2026-09-26) ✅ unit tests + in-browser QA
Re-dispatch of `docs/agent-briefs/environment.md` (the `cloud/environment` branch never reached
GitHub), built on master in commit `5e5e382`.
- **Drowned Nave water** (`graphics/Water.ts`): three flooded rects (central aisle under the arches
  + both side aisles) with dry pillar walkways and dry entrance/altar landings; plus 12 graveyard
  **puddles**. One merged mesh, one draw call. Per-vertex shore distance → rim fade + depth tint;
  two scrolling canvas normal maps, fresnel rim, patchy moon glints, a faint moonlit sheen on the
  open-sky puddles, 16 ripple rings. Drawn under spell decals (renderOrder 1 < 2) so telegraphs stay
  readable. 'low' quality = flat glossy sheet. No Reflector, no textures on disk.
- **Atmosphere** (`graphics/Atmosphere.ts`): per-area GPU-animated weather around the focus — ash +
  tumbling leaves (Graves), bone-dust motes (Ossuary), rain streaks + drips + motes (Nave), rising
  violet embers (Sanctum), dust (Chapterhouse). ≤300 live particles, one draw call, premultiplied
  blend (normal + additive in one pass), cross-fades on area change, half count on 'low'.
- **Distant silhouettes**: 7 hand-placed ruined spires + ~63 dead trees / broken walls beyond the
  walls, code-built, merged into one occlusion-patched mesh.
- `content/layout.ts`: `water`, `puddles`, `silhouettes` from a separate RNG stream (existing
  placements unchanged). `WorldView.addRipple()/isWet()`; `WorldScene.wadeRipples()` rings the water
  under moving players/enemies/thralls (round-robin, 16-slot budget) and on deaths.
- Tests: `src/graphics/__tests__/layout-water.test.ts` (6).
- Perf: +3 draw calls total (water, atmosphere, silhouettes). No per-frame CPU work beyond
  uniforms; atmosphere attributes rewrite only on area change.

## Balance pass (2026-09-26) ✅ harness
Commit `556e848`. Full write-up, targets and current numbers: `BALANCE.md`.
Intended-band damage taken went from 0–15 %HP/min to 4–54; push is dangerous (0.3–6 deaths /
3 min) instead of harmless-or-spiral; the bot opens each area in 3–5 min (was 2.7–3.7).
Harness now respawns via the Chapterhouse and reports time-to-first-death.

## Horde performance profile (2026-09-26) ✅ measured + two fixes
`__cwDebug.perf()` (DEV) renders the scene once directly and reports draw calls / triangles,
a scene census (skinned meshes, shadow casters), and CPU cost of `update()` and `sim.step()`.
Wait ~2 s after spawning before calling it — creature GLBs attach asynchronously.
Measured in headless Chromium (software GPU, so GPU *time* is meaningless there; counts are exact):

| Scene | Triangles before → after | Draw calls | Shadow casters |
|---|---|---|---|
| Chapterhouse, idle | 622k → 415k | 86 → 97 | 23 → 32 (smaller, cullable batches) |
| Nave, 34 enemies | 575k → 365k | 129 → 137 | — |
| Nave horde, 94 enemies at the cap | 1.25M → 717k | 294 → 312 | 117 → 46 |
| Horde + 30 corpses | 1.48M → 829k | 356 → 238 | 147 → 46 |

- **CPU is not the bottleneck:** `sim.step` ≈ 0.1 ms and the whole game update ≈ 1.5 ms/frame with
  94 animated enemies (animation LOD already skips far mixers).
- **Fix 1 — per-area prop batches** (`WorldView.buildProps`): props were one instanced mesh per kind
  spanning the whole world, so neither the camera nor the moon's shadow pass could cull anything.
- **Fix 2 — shadow LOD** (`EntityViews.shadowLod`, `Creature.setCastShadow`): only the 12 common
  enemies nearest the focus plus every elite cast moon shadows; corpses never do (they lie flat).
- **VAT decision: not needed at the current cap** (72 enemies + ≤5 thralls per player ≈ 90 skinned
  bodies). Revisit if the cap goes past ~120 or a real mid-range/integrated-GPU test shows skinning
  as the cost. Next cheap levers if needed: shared materials for unflashed enemies (fewer programs /
  uniforms uploads), and lowering `SHADOW_CASTERS` on the 'low' preset.
- Still owed: a frame-time measurement on real mid hardware (needs the user's machine).

## Cloud session, part 2 (2026-09-26) ✅ each with tests; browser-QA'd where visual
Commits on `claude/adoring-knuth-hd1uox` after the environment/balance pass:
- **Prelate balance**: boss harness (`npm run balance:boss`), BASE_HP 4200 → 26000, party scaling
  +80%, seeded Bell Rain. Careful arrival-level players win in ~2.7 min; standing in telegraphs dies.
- **Easy / Medium / Hard**: HP ×0.75/1/1.2, damage ×0.6/1/1.3, rewards ×0.75/1/1.3 (+2% elites on
  Hard); host-authoritative, rides snapshots; Settings select; harness `BALANCE_DIFFICULTY`.
- **Wave Speed milestones**: Elite Vanguard (tier 3, elite every other wave), Restless Crypts
  (tier 6, surges ×0.6 interval), Nightfall (tier 8, half the commons Shrouded, +25% gold, dimmer moon).
- **Surges from crypts**: `layout.crypts` in front of mausoleums/sarcophagi; breaches as fallback.
- **Relic runes**: server proposal (`server/proposals/relic-runes.md`); progress proposal thresholds fixed.
- **Status matrix**: Hemorrhage (spear bleed, clamped in sim + realtime), Chill (wraith hits),
  Sanctified (Deacon blessing), plus Bone Hex and Silenced from the items below.
- **Horde perf**: see the section above.
- **Thrall variety**: Penitent → archer, Deacon → bone mage (Bone Hex), Sac → plague bearer (rot burst).
- **Signature rites** (lvl 10, key R): Ossuary Wall, Command: Rend, Dirge, Plague Bloom via one
  validated `signature` intent.
- **Onboarding**: welcome card + 12 contextual tips; "Show tips again".
- **Backlog**: replay/endgame proposals (Ascension prestige etc.) in FUTURE_CONTENT.
Checks at the end: 80 vitest, 8 realtime, typecheck, production build all green.

## Ascension — prestige loop (2026-09-26) ✅ tests + browser QA
- `content/ascension.ts` (pure rules), `Progression` (rank, Ashes, boons, per-run record; save migration),
  `WorldSim.ascension` (+3 enemy/boss levels per rank, in snapshots), `ui/AscensionPanel.ts` (Altar:
  two-step Ascend listing resets/keeps, boon grid), portrait rank, onboarding tip, harness
  `BALANCE_ASCENSION`, DEV hooks `prelateSlain()` / `altar()`.
- Resets only the browser-local layer; level/XP/gold/items are never touched.
- QA: ascended to rank I for 10 Ashes, bought Vigil + First Rites (HP 226 → 244, Damage tier 2), seals
  closed, rank shown under the portrait. 86 vitest / 8 realtime / build green.
- README rewritten for the whole session (statuses table, signature rites, thrall kinds, water/weather,
  Ascension section, new-player section, dev commands) with six new screenshots in `docs/screenshots/`.


## VPS storage handoff — necro progress (2026-09-26) ✅ tests + mock-backend browser QA
- One rules module, `src/gameplay/necroRules.ts`, covers prices, seals opened by kills, Prelate summons, Ascension,
  boons and the one-time browser import clamps. `npm run build:server-rules` bundles it to
  `server/vps-handoff/necro-progress/necro-rules.cjs` for the Node auth server. A parity test keeps
  the bundle in step with the source.
- Package: `necro-progress-routes.cjs` (GET + 6 POST routes under `/api/necro-progress`, with ownership
  guard, rate limit and `{success,data|error}` replies), `mysql-store.cjs` (row-locked transaction per
  mutation, so gold is deducted server-side and atomically), `schema.sql` (one additive table), and
  `necro-progress.test.cjs` (8 node:test cases).
- Client: `Progression` has a server mode. It applies optimistically, sends deltas on the save flush, and
  reconciles on every reply. It falls back to localStorage on a 404 or when the server is unreachable, and
  uploads the browser save once. Server errors show as toasts. The DEV mock backend serves the same routes.
- Brief for the Claude Code session on the VPS: `server/VPS_HANDOFF.md` (recon, backups, install,
  verify, rollback, report-back).
- Verified: 92 vitest / 16 server tests / build green. In the browser (mock server mode): ascended and
  bought boons, and the server record ended at `asc:1, boons {vigil, first_rites}, dmg 2, migrated`.
- Known limits (documented in the brief): gold is still earned client-side through `save-progress`, the import
  trusts clamped browser data, and the DEV `prelateSlain()` hook can't credit a kill once a character is
  server-backed (the server requires a paid summon).

## Grimoire + four new rites (2026-09-27) ✅ tests + in-browser QA
- **Grimoire (L):** keys 1–4 stay four fixed slots; the player picks which rites fill them from
  `GRIMOIRE` (the classic four + four level-gated rites). Picking a key for a rite already on another key
  swaps them; cooldowns belong to the rite, so swapping resets nothing. Stored per character in browser
  storage (`gameplay/loadout.ts`, `dm_loadout_v1_<id>`; a preference, not progress, so no server work).
  `ui/GrimoirePanel.ts`, HUD open-book button, `HUD.setHotbar()` rebuilds the bar, `unlockLevel()`
  replaces the signature-only lock.
- **New rites**, each modelled on a shipped one so they feel the same:
  - **Wailing Skull** (lvl 3, jade) — flies and hits like Bone Needle; chains 3 bites, −20% per leap, a
    killing bite earns another (max 5). Client-resolved `hit` intents.
  - **Grave Step** (lvl 5, blood crimson) — picks a corpse like Corpse Explosion; blink (same area only)
    + 2.6 m marrow burst with Hemorrhage. The corpse stays. Client-owned movement + `hit`.
  - **Grave Frost** (lvl 7, cold blue) — resolves its 70° cone on impact like Marrow Spear; `hit.chill`
    (new flag; host owns the 3 s duration); already-Chilled enemies shatter for +50%.
  - **Bone Mantle** (lvl 12, ivory/old gold) — like Black Litany the host consumes corpses
    (`signature` intent `sig: 'mantle'`, event `mantle`); caster gains a barrier (10% + 7%/corpse, cap
    45%) held for 6 s (`Player.barrierHoldUntil`) and orbiting shards tick adjacent enemies.
- **Art via the pipeline** (`art-manifest/gemini-jobs/spells-v4.json`, `status-v2.json`): 4 rite icons,
  6 tintable VFX sprites in `public/art/fx/` (new `post.lumaAlpha` + `post.mask: circle|cone` in
  `tools/ai/gemini.mjs`), and real Chilled/Silenced status icons replacing the inline SVG stand-ins.
  Loaded by `graphics/fxImages.ts`; Effects gained sprite projectiles and `orbit()`.
- Four procedural SFX (`wail`, `bloodStep`, `frost`, `mantle`). Auto combat uses whatever is on the bar
  (Mantle when pressed + hurt or on corpse fuel, Frost into cones of 3+, Skull on bosses/elites/knots,
  never Grave Step). Help: Grimoire tip + one tip per new rite the first time it's slotted; tips that
  named fixed keys now read the loadout (`{key:exhume}`); Codex entries, Settings keys, README.
- Realtime: `SIGNATURES` += `mantle`, `hit.chill` sanitised; deploy script re-embedded. **Co-op guests
  need the new realtime service for Bone Mantle** (older servers drop the intent; everything else works).
- QA (offline mock, level 12 Mourner): skull chain 86→69→55→44→35 over 5 bites; Frost 68→18 + Chill 2.7 s,
  second breath shattered for 75; Step moved 7.6 m, corpse kept, burst + bleed on the enemy in reach;
  Mantle took 5 of 6 nearby corpses, barrier 114/254 (cap) held 6 s then decayed; auto combat cast
  Mantle → Frost → Skull → needles → Corpse Explosion. No console errors. 134 vitest + 17 server tests green.

## Enemy variety pack + processions (2026-09-27) ✅ tests + in-browser QA
- **Four new dead**, each a shipped behaviour plus one twist (`content/enemies.ts`, `WorldSim`):
  - **Censer Bearer** (melee): an aura pulse each second Incenses the dead within 5 m (+30% move,
    +25% attack rate; new status `incenseT`, snapshot flag bit 65536, bronze motes + a ground ring).
  - **Choir Wraith** (caster, `attack: 'scream'`): a telegraphed song ring (2.2 m) at the target's
    feet that screams on release; hovers, translucent, leaves no corpse, dissolves on death.
  - **Ossuary Skull-Rat** (flank, `pack: [4, 6]`): spawns as a pack, never elite, no corpse.
  - **Bone Golem** (hazard, `slamRadius: 2.8`, `deathCorpses: 3`): wide slam telegraph with cracks;
    falls apart into its own corpse + two skeleton corpses.
- **Processions** (`WAVE_THEMES`, `PROCESSION`): from a wave's 2nd count onward, ~30% of waves come
  as a themed band with an optional lead; the `wave` event carries `theme` and the scene shows one
  banner per band. Wave size now counts bodies, so packs fill several places; surges track pack ids.
- Rosters: rats + rare golem (Ossuary), wraiths + censers (Nave), all four (Sanctum); the Hollow Graves
  roster is unchanged (only its processions bring newcomers). `npm run build:server-rules` re-run
  (the bundle embeds `areas.ts`).
- **Art via the pipeline**: Gemini concepts (`enemies-v2.json`, preview `docs/enemy-concepts-v2.webp`),
  Tripo specs `art-manifest/tripo-specs/{censer_bearer,choir_wraith,skull_rat,bone_golem}.json`
  (spend approved by the owner: 50 + 85 + 125 + golem), built with `build-characters.mjs`. The wraith is
  a static mesh (`models/props/choir_wraith.glb`, bobbed in code). Every new slug has a shipped-model
  fallback (`ENEMY_FALLBACK`). Incensed status icon via Gemini (`status-v2.json`).
- Help: first-sight tips (censer, wraith, swarm, golem) + a procession tip, Codex bestiary entries and
  area dangers, README tables (dead, processions, statuses).
- Tests: `enemy-variety.test.ts` (codex/roster integrity, packs never elite, procession theme + lead,
  censer aura + snapshot mirror, scream hits only inside its ring, golem → 3 corpses; wraith/rat → 0).

## Professions G0 + G1 + G2 + G4: gathering and the Sexton's Acre (2026-09-27) ✅ tests + in-browser QA
Built from `docs/PROFESSIONS-ROADMAP.md` in one cloud session (branch `claude/adoring-knuth-hd1uox`). G3 art is with the owner.
- **G0 (rules + server):** `src/gameplay/gatheringRules.ts` holds 26 nodes (7 trees, 8 seams + 2 geodes, 6 fishing spots,
  4 graves), success odds, loot, both XP curves (live rule active), a time budget (elapsed ÷ cycle + 3 burst, 30 s
  window, 1,800/h cap) and bag placement. It is bundled to `server/death-muffin/backend/gathering/gathering-rules.cjs`
  (`npm run build:server-rules`, with a parity test). `POST /api/gather` runs ownership → node → level → budget → server roll →
  one transaction (items, gold, skill, ledger). `002-gathering.sql` adds 21 materials, 250-stacks and `gather_ledger`.
  `award-xp` now answers 410. The offline mock serves the same route with the same rules. 10 node:test route tests.
- **G2 (the Sexton's Acre):** a safe zone at x −62…−20, z 6…38, always open through door `chapter_acre`. It has a gravel
  lane, the quarry wall, the grove, a black-water pond (blocks feet; fishing spots on the shore) and burial rows, with
  higher tiers further west and one Bone Elder. Stations: Sawpit, Bone Kiln (`prop_node_bone_kiln`, ember light) and
  Cooking Fire. Leaves, crows and a wind bed for atmosphere. Rich nodes in every hunting ground (2 each). "Always open"
  is now data (`isAlwaysOpen`: areas with no seal), so progress saves needed no new field.
- **G1 (nodes + loop):** `WorldSim.nodes` gives host-authoritative depletion and respawn, the `gather` intent (reach-checked),
  `nodeGone`/`nodeBack` events and a snapshot `depleted` list; mirror and host migration carry it. `Gathering.ts`
  (`GatherLoop` + `Skills`) handles walk → work → gesture per cycle → local roll for feel → 8 s batches → server wins.
  Auto (`gatherPlan.ts`) moves to the nearest live node of the same kind and area, or waits. It stops on
  movement, cast, panel, full bag, hit or death. `Nav.findPath` is a 0.5 m grid A* per room leg, used only for
  node walks, so click-to-move is unchanged. `NodeViews` draws instanced live/spent stand-ins, ore-tint vein
  overlays, pool ripples, rich glow, a hover ring and the progress arc, and swaps to `prop_node_*` GLBs when they exist.
  Four procedural SFX (chop, pick, splash, shovel) plus a skill-up chime.
- **G4 (UI + help):** the Skills panel (P) shows levels, XP to go, the next unlock and total level. The node hover card has
  the level requirement, XP per success and yield. The Workbench gained station mode. There are 6 counsel tips (Acre, first
  node, rich node, station, full bag, skill up), and the welcome tip now mentions the Acre. The Codex has a Professions tab
  generated from the rules and layout. Settings has Auto gathering, and the key list gained node click and Skills. The README
  has a Professions section with 4 new screenshots.
- **Fixes on the way:** the Workbench now re-reads the bag after crafting (the live `/api/craft` returns no bag; see HANDOFF).
  The offline `/api/recipes` works without a token. Spell hover cards for the four Grimoire rites had no detail lines
  (the test on master was red).
- Verified: 188 vitest, 28 server tests (realtime 10, necro-progress 8, gathering 10) and build all green. Every node is
  reachable on foot from spawn (walker test). In the browser (offline mock) I chopped, mined, dug and fished; the server
  bag held `log_oak×3, ore_copper×2, bones_old×3, seed_mourning_moss×1, fish_river×3` and gold 4; the kiln listed
  recipes; the hover card and Skills panel rendered. No console errors.

## Roadmap art batch + combine (2026-09-27, workstation) ✅ tests + in-browser QA
- **Combined for one push:** `master` fast-forwarded to the professions commit `fa43c9c`. The workstation's work
  (Grimoire, enemy pack, art, merge fixes) was restored from GitHub Desktop's two branch-switch stashes (backups:
  `backup/art-batch-stash`, `backup/art-late-stash`). There were two conflicts: the briefs index (both statuses kept)
  and `spellTooltip.ts` (the workstation version is a superset of the professions agent's fix). The image manifest
  was union-merged (268 records).
- **Node art live:** the build keeps `prop_` for gathering nodes, so the GLBs land where `NodeViews`/`layout` already
  load them (`models/props/prop_node_*.glb`). `NodeViews` gained `live` models for Blackthorn, Ghostwood, crypt collapse
  and barrow tomb. Verified in the Sexton's Acre: every node GLB returns 200 and the real trees render.
- **Generated for future roadmaps** (all listed in `docs/ART-BACKLOG.md` with what each waits on): hand tools, thrall
  bow/staff, Mourner wraith thrall, 13 more profession props (stations, garden stages, sapling, grave tiers), Lich
  Acolyte, three area bosses (1024 px), five Release-0.3 class heroes (8 clips); 2D for herbs/seeds/saplings/planks/
  meals/bone meal, 24 tool-tier icons, finds, contracts, 9 skill icons, 9 future-spell icons, 11 relic runes,
  8 portraits, omen icons and three area moodboards (`future-2d.json`, 97 jobs).
- **Existing heroes gained an `attack` (slash) clip.** A GLB diff proves mesh, skeleton, textures and every existing clip
  are byte-identical; no hero code requests `attack`, so combat is unchanged.
- Tools: `tools/art-backlog.mjs` (unreferenced-art scan that follows imports and the by-name item-icon rule);
  `tools/tint-variants.mjs` now targets `prop_node_*`.
- Checks: typecheck, 189 client tests, 28 server tests, both rules bundles current, production build.

## Readability pass + boss/mob art + briefs (2026-09-27 evening, workstation) ✅ in-browser QA
- **UI readability** (owner: "fonts, text boxes, readability, slight adjustments"):
  - `tokens.css`: muted text 66% → 80%, faint 42% → 60%, and a new `--cw-shadow-legible` token.
  - New `src/ui/readability.css`, linked after `ui.css` in `index.html` so it never collides with the cloud agent's
    `ui.css` edits. The display serif is now titles-only: tabs, field labels, Grimoire sockets and Codex `dt` use the
    body sans.
  - Panel reading text is 15px/1.5. Every piece of text over the 3D world carries the legible shadow.
  - One `kbd` key-cap style everywhere; some had fallen back to monospace.
  - Disabled buy buttons are readable (0.62), the chat backing is heavier, and a 1px overflow that put a stray scrollbar
    on the spell card is clipped.
  - Checked in the browser at 1440×900: the Codex tabs now fit one row, and the party epithet stays on one line (the
    12px bump was reverted there). The production build bundles the sheet.
- **Art** (records in `art-manifest/`; Tripo ledger in `docs/ART-BACKLOG.md` §6):
  - Barrow Ghoul: 7 clips, 145 credits.
  - Boss props: King's Grave, Abbess's Reliquary, skull niche, Drowned Font, church pew (250 credits).
  - Sprites: `grave-outline`, `tide-crest`, `drowned-hand`, plus the five rite sprites from earlier.
  - 45 more Binbun conversions (67 in total).
- **Briefs for the cloud agent:**
  - `spell-variety-first-session`: dev access, Grimoire, 7 rites, BinbunFX runtime, interactables, First Rites.
    Dev access, the Grimoire and the 7 rites have since landed on `claude/adoring-knuth-hd1uox`.
  - `mobs-barrow-ghoul-lich-acolyte`.
  - `area-bosses`.
  - `build-depth-aspects-runes`.
- The merge of `master` (`acfdd36`) with the cloud branch (`502f726`) was previewed with no conflicts and tested in a
  scratch worktree: typecheck, 220 client, 33 server and 3 VFX tests all green.

## Spell variety brief §2–§5 (2026-09-27, cloud, `claude/adoring-knuth-hd1uox`) ✅ tests + in-browser QA
- **§2 Dev access** (`55a6dd2`): `gameplay/devAccess.ts`. The `brbmuffins` account or any `gm_enabled` character gets
  every rite, area and gathering tier as a runtime overlay that is never saved. It adds a **DEV** chip and a Settings
  toggle to preview as a normal player. Death Muffin `/api/gather` skips only the level check for staff (`isStaff`:
  `accounts.role` admin/gm or `gm_enabled`); the mock mirrors it.
- **§3 Grimoire** (`7c3afae`): loadout v2 `{primary, keys}` (migrates v1), a Grimoire button with a NEW pip, a
  clickable level-up toast, right-click on any slot, role chips, and the left-click primary socket (Bone Needle /
  Bone Fan / Rot Lance). Escape closes an open panel before it opens Settings.
- **§4 Seven rites** (`502f726`):
  - primaries Bone Fan (2) and Rot Lance (6, Withered);
  - keys Grave Offering (2), Ivory Cleave (4), Veil Step (4), Rally the Dead (6, snapshot rally bit), Carrion Seed
    (8, host-side seeded corpses, `seeded` / `seedGone` / `seedBurst` events).

  The unlock ladder is 2/3/4/4/5/6/7/8/12. Each rite has a Codex entry, counsel tip, spell card, auto-combat rule
  (Veil Step never) and realtime sanitiser.
- **§5 BinbunFX runtime + DEV gallery**: `graphics/binbun/`, owned by `Effects` as `effects.binbun`.
  - Fail-open fetch/cache, one CPU-simulated InstancedMesh per particle node, Mesh per mesh node, track player.
  - Lights go through `lightFlash`; cap 24 one-shots / 32 loopers, pooled, loopers culled.
  - Exact GLSL for the shared `transparent` / `particle` / `glow_fresnel`, a `generic` program for the per-pack
    shaders, and procedural textures for the unbaked noise/gradient `.tres`.
  - DEV `vfx(id)`, `vfxGallery(page)`, `vfxCount()`.
  - Headless QA: all 60 spawnable effects render with no shader errors. `dirge_area`, `exhume_lift` and
    `prelate_impact` read too bright under bloom; tuning is next.
  - **Not yet wired into gameplay** (brief §5 wiring list).
- Checks: typecheck, 225 client tests (new `binbun.test.ts`), 33 server tests, `test:vfx`, production build.

## Core art round + agent review (2026-09-27 late evening, workstation) ✅
- **Tripo (1,210 credits, balance 20):**
  - Chapterhouse centrepieces: the Altar of Ascension, Rite Niches and Covenant lectern. The altar and niches had no
    model at all before this.
  - 10 room props (Graves, Ossuary, Nave, Sanctum).
  - The Bell-Sworn Templar (Sanctum enemy) and the Bone Colossus thrall (the payoff for the epic rune).
  - Six class weapons.
- **Gemini:** 35 ability icons for the five Release-0.3 classes, and 5 class sprites (crow, hook-chain, sound-ring,
  lantern-cone, veil-rift). The Bone Colossus concept was regenerated once for bulk.
- **Known flaw:** the Monk bell staff's bell is a separate floating island. The workaround is in the `new-classes.md` §5
  brief.
- **Briefs:** `world-dressing.md` and `new-classes.md` are new. The Templar went into the mobs brief (§5), the Colossus
  into build depth (§7), and the centrepieces into spell-variety (§6).
- **Review of the agent's `964906f`** (scratch worktree, fonts allowed):
  - Tests: typecheck, 225 client, 33 server and 3 VFX, all green.
  - Checked in the browser: dev access, the Grimoire button and the LMB socket, and the gallery (every shader compiles,
    all textures load).
  - **Blocker:** effects blow out under bloom at default gain. The notes are in the spell-variety brief §5.
  - The counsel card's stray scrollbars are fixed on master (`readability.css`: the plate's corner brackets are pulled
    inside scrolling plates).

## Four remaining New Blood classes (2026-09-28, undeployed)

Built Grave Warden, Bell Monk, Carrion Witch and Veilwalker on the class framework: 28 abilities, four family resources, hero and gear registration, host corpse/control/zone rites, Veil echoes, Codex, tooltips, first-entry counsel, and family-aware auto combat. Added focused host/resource tests and the four families to the headless balance report. Echo now requires an eligible echo corpse; Watchman's Ward slows by 25%; class sprite effects are wired and Warden Cone, Witch Harvest and Veil Tear passed offline browser checks. The updated three-seed Graves bot pass still shows repeated deaths for the new families. It does not dodge or drink flasks, so this is a release risk signal requiring human combat review, not a player balance verdict. Backend leaderboard now distinguishes Warden index 5 from the legacy Necromancer class index. Changes are on `claude/new-classes-framework` and not deployed.

The owner chose Easy as a powerful hands-off mode. Easy auto now engages and dodges within the combat area, uses equipped rites and signatures, drinks flasks, and recovers health under pressure; Knight and Veilwalker gain automatic ward. Veilwalker now saves Veil Form for actual pressure. Easy enemy damage was reduced to 0.3× Medium. Three-minute real-browser Graves samples starting at level 1 had zero deaths for all five New Blood classes; the final Veilwalker policy survived two separate samples without flasks. See `BALANCE.md` for counts and limits. This is separate from the older headless Medium bot and still needs later-area playtests. Not deployed.

## Class framework + Hollow Knight (2026-09-28, undeployed)

Branch `claude/new-classes-framework`. Release 0.3's first class, on a framework built to carry the
other four.

- **Framework, additive, no class-visible change:** `ClassFamily` + `Discipline.family`; per-family
  resource rules (`gameplay/resources.ts`) and kits (`content/kits.ts`); the HUD orb takes its label
  and colour from the family; `Player.resource { kind, value, max }` with `essence` kept as an alias
  so no necromancer call site moved. Server `discipline_index` range opened to 1–9 and realtime
  validation extended to the new `sig` kinds.
- **Hollow Knight** (`discipline_index` 8): Rage 0–100 built by damage taken, by Hollow Cut hits and
  by perfect blocks; the seven rites from the brief; `gear_knight_sword` + `gear_knight_shield`
  attached to the rig; Codex entries, a first-entry counsel tip, spell cards and README.
- **Host authority kept:** Shield Bash, Corpse Vigil and Grave Brand ride `signature` as new sig
  kinds so the corpse spend, the body struck and every duration are the host's. Hollow Cut and Grave
  Slam are client-resolved like Ivory Cleave. New enemy statuses `stunT`/`rootT`, snapshot bits 17/18.
- **First-time play check:** the legacy `/character` endpoint cannot create index 8, so new
  families create in the separate legacy index-5 slot, then set `discipline_index` on that same
  character. The offline mock mirrors this path. A level-1 Knight now keeps Bulwark and Corpse
  Vigil visible as locked hotbar slots; the old sanitizer left them undefined and prevented the
  world from mounting. Class-specific corpse action labels replaced stale Corpse Explosion help.
- **Tests:** typecheck, client tests including the new creation and low-level loadout regressions,
  server tests, VFX tests, and build — all green.
- **Follow-up:** Shield Bash now damages and staggers the boss for 0.2s; its pending telegraphs
  pause with it. The leaderboard index-5 collision was resolved in the four-class follow-up above.
- **Browser-checked in offline DEV:** first-time account creation, Knight card selection, world
  entry, Rage HUD (0/100), seven hotbar sockets, and successful loading of the Knight, sword and
  shield GLBs. No browser errors. Combat mechanics are covered by 20 Knight tests, not a manual
  in-world fight. Production remains undeployed.

## New Blood browser and boss follow-up (2026-09-28, undeployed)

All five classes were selected in offline Chromium at 1280×800. Each entered the world with its
resource orb, seven hotbar slots and hero GLB, then landed its primary attack on a live sim enemy
without browser errors. The ninth card was unreachable at that viewport height; the selection
screen now scrolls safely, and Veilwalker was selected through the visible card. Shield Bash's
host-owned charge now staggers the boss for 0.2s and delays pending telegraphs; a focused host
test covers damage and the pause. The local branch remains undeployed.

## Flying pack, Grimoire expansion, Bone Mantle fix, Easy-auto smoothing (2026-09-28, VPS session, undeployed)

**Art (Tripo 565 credits, balance 10,020 → 9,455; Gemini for concepts and icons).**
- Four flyers: `belfry_gargoyle` and `weeping_seraph` (biped rig, 4.5k/4.4k tris; gargoyle clips idle/attack/dive/hurt/death,
  seraph idle/cast/hurt/death), `shroud_moth` and `tithe_bat` (static, 3.6k/1.8k). The cherub concept was
  refused by Gemini's image-safety filter (child figure), so it was replaced by the adult Weeping Seraph.
- **Tripo's avian auto-rig boned only one wing** of a symmetric model, and Tripo has no flight presets. Wings therefore
  flap in the vertex shader (`graphics/wingFlap.ts`): no bones, no mixer, one shared program, and it runs before skinning,
  so rigged flyers flap on top of their clips.
- Bone Mantle fragments `mantle_rib/vertebra/skullchip` (~300 tris, 256 px) and `grave_hand` (278 tris). All are drawn
  as InstancedMesh, three draw calls for every mantle and storm, one for every hand field.
- Rite icons: `necro-{soul-siphon,bone-prison,grave-hands,bone-storm}.png` (`gemini-jobs/spells-v6.json`).
- Binbun: four more scenes converted (`bone_prison_burst`, `soul_siphon_beam`, `bone_storm_dust`,
  `grave_hands_pulse`); the converter's output for the existing 67 effects is byte-identical.

**Flying pack** (`content/enemies.ts`, `WorldSim`): each flyer reuses a behaviour and adds one twist.
- Gargoyle: a telegraphed dive-bomb. It moves in a straight line during the second half of the windup, lands, slams,
  then stays grounded 1.4 s. A stun mid-dive drops it onto walkable ground. Snapshot flag bit 19 carries `diving`.
- Moth: `attack: 'dust'`, a burst ring plus a 3.5 s hostile `dust` zone.
- Bat: `hitRun`, which flits away 0.8 s after each bite.
- Seraph: `ward`, which Sanctifies up to four allies in 5.5 m at once and never raises corpses.
- Added to the area rosters plus three processions (Moth-Dusk, The Belfry Stirs, Vespers). Each has Codex, counsel
  and README entries.
- `necro-rules.cjs` was regenerated (areas changed).

**Balance** (`npm run balance`, 4 seeds, base vs new): every band is within a few percent on deaths, damage taken
and kills. The first pass over-tuned the Seraph (6 targets, 6.5 s) and halved sanctum-push kill speed. It is now
4 targets on an 8.5 s cooldown, and the Ossuary flyer weights were trimmed.

**Grimoire expansion**:
- Soul Siphon (6): a following tether that drains into health and essence.
- Bone Prison (9): a root ring. It adds the `hit.root` flag; the host owns the 1.8 s duration.
- Grave Hands (11): a slow field, with the `hit.slow` flag. Corpses in it add hands and damage without being consumed.
- Bone Storm (14): a drifting funnel of the instanced bones. Corpses it starts on extend it.
- All four are client-resolved like Bone Mantle's shard ticks (`AbilitySystem.timed`), with Easy-auto rules, tooltips,
  Codex, counsel tips and README entries.
- `server.js` sanitises the two new flags. The relay already passes unknown fields, so co-op works before a
  realtime deploy; `deploy-realtime.sh` is refreshed.

**Bone Mantle "bananas" fix.**
- Cause: a cream-tinted, curved sprite with additive blending, spun in a ring.
- Fix: real lit, matte bone meshes tumbling on the orbit, and aged-bone greys in `SPELL_FX.mantle`.

**Easy auto choppiness** (`selectAutoCombatMovement` + `AutoMoveMemory`).
- A frame trace showed the hero's intended heading was steady while its motion flipped 178° each frame. It was walking
  a straight line into props and being resolved back out.
- Movement now keeps a sticky target, a closing hysteresis band, committed dodges and smoothed turns. It walks
  `nav.findPath` whenever `nav.clearLine` says the target is out of sight.
- Browser sample (4 seeds × 40 s, old vs new): heading jitter 56 → 25 °/s, walk/stop flips 2.1 → 1.8 /s, kills +20%.

**Perf** (`tools/qa/flyers-rites-smoke.cjs`, 36 enemies): CPU update 0.688 ms ground roster vs 0.678 ms flyers,
triangles equal, +24 draw calls.

**Verification:** typecheck, 289 vitest (new `flying-pack`, `grimoire-expansion` and auto-combat routing cases),
41 realtime tests, and a headless-Chromium smoke with screenshots.

## Backlog mobs, combat animation variety, Professions G6 (2026-09-28, VPS session, deployed)

**Backlog mobs** (`docs/agent-briefs/mobs-barrow-ghoul-lich-acolyte.md`, all three built to the brief):
- **Barrow Ghoul.** New `'burrow'` state, appended to `E_STATES`.
  - Burrowed it is immune and untargetable: 20 client and sim guards skip it, and the host drops hits.
  - It erupts in a 1.8 m ring, at 1× damage in the Graves and 1.25× deeper in. At most 3 eruption telegraphs per target.
  - The first time it drops below half health it digs back in (0.8 s) and tunnels up to 8 m.
  - Burrowed views hide the model and slide a pooled dirt mound.
- **Lich Acolyte.** A curse caster. **Unbinding** raises a hostile Risen from a thrall *killed* within 7 m, one second
  later. Limits: once per 4 s, at most 4 alive, and a dead acolyte cancels a pending one. Its crimson reach ring shows
  only while your thralls stand inside it.
- **Bell-Sworn Templar.** `damageEnemy(…, from)`: directed blows from its front 120° do 30% damage. Zones and damage
  over time pass no source and ignore the shield, and Fracture removes the block. Shield sparks sound a `tollSmall`.
- **Balance** (4 seeds; the base / flyers / mobs table is in the session notes).
  - Graves are back at baseline after three passes: the Barrow Opens procession moved to the Ossuary, Graves
    eruptions do 1×, and roster weights were trimmed.
  - Open for owner feel: Nave geared deaths +15% (Acolytes punish thrall play, as designed) and Ossuary geared kill
    rate −18% (burrowed ghouls can't be hit).

**Animation variety** (Tripo, 1,040 credits in total; balance 8,415).
- **Bug found:** Tripo's `hurt` preset is a **14 s lying-injured clip** on every model. The hero played it on 35% of
  hits and couldn't walk out of it. It is now renamed `hurt_down` and never shipped.
- A 13-preset catalogue on `grave_robber` (hip-height measurements) settled which clips are real. `chop` is a
  byte-identical alias of `slash`, and `defeat_02` never falls. The results are recorded in the spec's `catalogued` field.
- Every biped model got `hit_to_body_01` → `hurt`, `hit_to_head` → `hurt2` and `defeat_03` → `death2`. Melee mobs
  got `box_01` / `front_kick_01` → `attack2`.
- `Creature` picks at random among a clip and its numbered variants. `inPlaceHeroClip` keeps root motion for every
  `death*`.
- Enemies now flinch on a fresh hit: throttled per enemy, near the camera only, and never over a windup.
- The rebuild kept identical triangle counts and every old clip on all 27 models.

**Professions G6 — processing** (`src/content/processing.ts` is the single source).
- Carpentry: planks for all 6 woods. Cooking: meals for all 5 fish, healing over time (Eat from the bag, stacks
  with a flask). Bonework: 4 bone grinds → bone meal, plus a Bone-Ash Flask.
- **Tools**: hatchet, pickaxe, rod and spade × 6 metals. The server reads the bag itself
  (`gathering-routes.cjs` → `toolTierFor`) for +5% success per tier, and the Skills panel shows it.
- The migration `004-processing.sql` is generated by `tools/build-processing-sql.mjs`; a test checks it is current.
  It is additive and idempotent, and was dry-run on the live DB inside a rolled-back transaction before it was applied.
- The Bone Kiln has Smelting / Tools / Bonework tabs.
- Fixed a client bug: a missing profession row meant level 0 client-side, but the server uses 1, so new characters
  couldn't use their first Bonework recipe.

## Area bosses (2026-09-29, VPS session; docs/agent-briefs/area-bosses.md)

- **Engine.** `BossBrain` is now a base class covering awaken, damage, Fracture, Withered, stagger, the 60% / 30%
  phases, telegraph resolution, wipe reset and the arena leash.
  - `PrelateBrain` keeps the old logic in the old order. **`npm run balance:boss` output is byte-identical** to the
    single-boss build.
  - `WorldSim.bosses` holds all four and `boss` returns the awake one. The ~20 old call sites are unchanged.
  - `summonBoss.boss` defaults to the Prelate for old clients, and the realtime server validates it (42 tests).
  - `BossState.id` travels in snapshots.
- **Content** (`src/content/bosses.ts`):
  - **Gravedigger King:** Burial roots whoever stays on the outline; each client roots itself. Spade Sweep. P2 digs up
    ghouls; P3 opens pits.
  - **Bone Abbess:** four inert `niche` enemies heal her and fire lances, and breaking one tears at her. Chorus spokes;
    P3 Rebuild and Bone Communion (eats arena corpses).
  - **Drowned Congregation:** Flood Hymn with pew cover, a segment-vs-box test against the layout's pew boxes.
    Drowning Grasp roots. Rising-water slow off the dais in P2/P3, and Soaked adds Hymn damage in P3.
- **World.** `layout.ts` `bossArenas()` runs last: it clears small props from each arena, places the summon object on
  the north edge, keeps niche and pit spots clear, and adds pew rows.
  - Gathering nodes are byte-identical and all 10 crypts are kept.
- **Tuned solo kill times** (skilled player, intended band) against the brief's targets:
  - King: 88–114 s (target 90–120), baseHp 15 500.
  - Abbess: about 120–150 s (target 120–150), baseHp 13 000, regen 0.25%/s.
  - Congregation: 139–162 s (target 150–180), baseHp 19 000.
  - Non-dodging players lose the Congregation, as they do the Prelate.
- **Rewards:** `rollBoss(…, area, shards)` scales per boss; the Prelate is unchanged. The first kill is a browser
  trophy worth +2 shards and a guaranteed rare-or-better relic.
- **HUD fix:** the boss bar kept the previous boss's numbers when a new boss started at 100%.
- **Tests:** `area-bosses.test.ts` (6) covers one awake boss, the snapshot id, Burial roots, niche regen and Fracture,
  Communion, and pew cover. The browser QA summoned all three through their real objects.

## Plague Cloister (2026-09-29, VPS session)

- **Why:** a level-49 dev account had nothing worth killing. Area levels top out at 13 while levels cost `level × 100`.
- **Zone** (`areas.ts` `cloister`, rect x 24..64, z −134..−98, door from the Sanctum's east wall, 600 Sanctum kills):
  - `scaling: { minLevel: 20 }`: `WorldSim.areaLevel` = the highest living player level inside (never below 20), plus
    Ascension. It drives enemy HP, damage and XP, the toxic rupture, and the boss.
  - Players now carry `level` (join, `setPlayer`, realtime clamp). The realtime `classIndex` clamp was widened from
    0–4 to 0–9, fixing New Blood partners showing as Rotweavers.
  - Art: Gemini floor texture (seamless), a green atmosphere and ambience, 4 Tripo props (plague well, rot garden,
    plague cart, the Saint's litter), arcade pillars and a sigil.
- **Mobs:** **Plague Doctor** (a caster flask: burst plus a hostile rot pool, `PLAGUE_FLASK`) and **Flagellant**
  (melee that frenzies below 50%: ×1.45 move, ×1.6 attack rate, blood-mote tell). Tripo models with hurt/death variety.
- **Plague Saint** (`SaintBrain`, 5 shards, baseHp 24 000, level-scaled):
  - Rot Rain: circles on each player plus the garth, and each becomes a hostile pool (`addHostilePool`).
  - She heals 0.6%/s while standing in any hostile pool (the "blessed" tell).
  - Censer Swing cone. P2 brings a doctor and a flagellant; P3 brings heavier rain, longer pools and rats.
- **Harness fixes:** `balance/boss.ts` and `harness.ts` pass the player level and unlock the Cloister. Dodging
  bots now step out of hostile pools (before, pool damage counted as "adds" and every run wiped).
- **Numbers:**
  - Saint, intended band (level 20), dodging: 137–164 s, 2/2 wins, minHp 34–58%. Non-dodgers wipe (as with the
    Congregation and Prelate).
  - Cloister farming at intended: necro kills 62–102/m vs Sanctum 79–86, XP/m 3 070–5 123 vs 2 759–3 086, 0–2 deaths.
  - Perf (36 enemies): Cloister roster 185 calls / 240k tris / 0.93 ms vs Graves roster 198 / 280k / 0.99 ms.
- **Tests:** `cloister.test.ts` (5): scaling floor and partner rules, flask pool, frenzy, summon spot, rain pools and
  the heal-only-in-rot rule. `tools/qa/cloister-smoke.cjs` covers the zone, mobs and Saint screenshots, model loads
  and perf. A skyline spire that stood inside the new zone was moved behind it.
- **Credits:** Tripo 8 415 → 7 760.

## Cinder Pyre (2026-09-30)

A second level-scaled world, the fire realm past the Plague Cloister's east arch.

- **Zone** (`areas.ts` `pyre`, rect x 70..110, z −134..−98, door `cloister_pyre` on the Cloister's east wall, 700 Cloister
  kills, level floor 30). Ember/ash theme: floor texture, rising-ember atmosphere, orange fire-lit props
  (`pyre_stack`, `slag_font`, `cinder_obelisk`), area ambient. Boss: the Cinder Regent (below).
- **Mobs** (each leaves fire; enemy ember orange is `SPELL_FX.enemy.ember*`, never Miasma green):
  Cinder Husk (dies into an ember pool, `EMBER_DEATH`), Pyre Priest (coal → burning ground, `EMBER_BOLT`, new `ember`
  attack/telegraph), Cinderhound (pack of 2–3 flankers), Slag Brute (slam leaves its ring burning, `SLAG_POOL`).
  New `ember` zone kind, `ember` burst kind and `ember` hurt source.
- **Feel pass:** ember shedding per mob type, sparks when struck and when they strike, coal flare + jolt on impact,
  Slag Brute shockwave/heat flash/shake, fire death puffs, burning-ground bonfire loops, scorched-hero sparks,
  three new procedural sounds (`emberThrow`, `emberBurst`, `slagSlam`).
- **Balance:** `npm run balance` (cloister vs pyre, four disciplines, three bands) shows the Pyre in line with the
  Cloister on hurt%/min, kills/min and deaths.
- **Tests:** `pyre.test.ts` (7). Art records: `gemini-jobs/pyre-v1.json`, `tripo-specs/{cinder_husk,pyre_priest,
  slag_brute,cinderhound,prop_pyre_stack,prop_slag_font,prop_cinder_obelisk}.json`.

### Cinder Regent (2026-09-30)

- **Boss** (`bosses.ts` `regent`, `REGENT`; `BossBrain.ts` `RegentBrain`): arena (90, −117) r 11, Ember Altar on its north edge,
  6 shards, level-scaled with the Pyre. Coals (burning circles), Cinder Cleave (a cone that lays a line of burning ground),
  and the signature **Conflagration**: a 2.7 s windup marks grey ash circles (4 / 3 / 2 by phase, +1 per three extra players)
  and the rest of the arena burns for `dmg 46`, leaving a few embers. P2 adds Husks and Priests, P3 hounds and husks.
  New `coals` / `cleave` / `conflagration` boss events; `WorldSim.emberPool` is public for the brain.
- **Art:** `boss_cinder_regent` (Tripo, 1024 px, 14k tris, 8 clips) and `ember_altar` prop; the slag font moved to the east
  alcove so the arena stays open.
- **Balance:** `npm run balance:boss -- --boss regent` — dodgers win 2/2 in ~90–130 s at intended/geared, non-dodgers lose;
  comparable to the Plague Saint.
- **Tests:** `pyre.test.ts` covers the summon spot, Conflagration (off-ash hurt, on-ash spared), ash-circle telegraph and coals.
  `tools/qa/regent-smoke.cjs` screenshots the awake boss, the windup and the eruption.

## Kill Chain and Milestones (2026-09-30, GRIND-LOOP #8 and #9)

- `gameplay/killChain.ts`: 4 s window, tiers 5/12/25/45/80 → +5/10/15/20/25% XP and gold (applied to the reward the client already
  rolls, on top of the Ascension multiplier). Only your own kills (thralls and DoTs credit their owner) in unsafe areas count;
  death resets it. HUD readout `hud-chain` (left edge, warms by tier, timer bar), floating tier call-outs, rising `chainTier`
  chime, a `chainBreak` thud for chains of 10+, a counsel tip on the first tier.
- `gameplay/milestones.ts`: kill totals (100–25,000), per-area kills (100–2,500), best chain (10–100); a one-off gold purse each,
  claimed per character in localStorage (`dm_milestones_<id>`, best chain in `dm_chain_best_<id>`).
- Tests: `killChain.test.ts` (6). QA: `tools/qa/chain-smoke.cjs` (14 own kills → ×14 Rampage, HUD visible, then hides; the
  chain-10 milestone paid). Debug hooks `__cwDebug.self()` and `.chain()`.

## Weekly Omens (2026-09-30, GRIND-LOOP #5)

- `content/omens.ts`: Blood Moon / Drowned Week / The Tolling, chosen by UTC week (Monday 00:00 start), no server state.
  Effects: `WorldSim.omen` adds to the elite chance, scales wave size and forces an elite affix (Tolling → Bell-Tolled); the
  client multiplies kill XP and gold (`rewardMult`, combat areas only) and elite shards (`shardMult`), tints the moon half-way
  and thickens the fog (`sky`). HUD chip `hud-omen` (hover = rules and time left), counsel tip on first entry.
- Tests: `omens.test.ts` (3): rotation and week boundaries, modest bounds, and a 60-wave harvest showing elites ×1.5+,
  waves ×1.15+, all Tolling elites Bell-Tolled. The `daily_rite` icon is reserved for Daily Rites.
- Co-op: the host's sim applies the spawn effects; every client computes the same week from its clock.

## New levels: Catacomb Warren, Bone Coliseum (2026-09-30)

Two more areas, both reusing existing props and mobs (only floor textures are new art; Gemini, ~free).

- **Catacomb Warren** (`areas.ts` `warren`, rect x −72..−32, z −52..−8, door `graves_warren`, level 4, 150 Graves kills): a 3×3
  grid of chambers divided by tall (3.4) half-walls with staggered gaps, a lantern at each gap end, and a central vault
  (sarcophagus, four candelabra, reliquary; also a surge crypt). Rats, robbers, ghouls, bats, sacs, hounds.
- **Bone Coliseum** (`coliseum`, rect x 70..112, z −46..−10, door `ossuary_coliseum`, level 11, 350 Ossuary kills): oval pillar ring,
  four L-shaped low skull walls with statues as cover, bone-dust sand floor, blood decals. Wave 14 / 4.2 s / cap 36, elite
  chance 0.16, a fodder-heavy roster so it plays as a horde pit; `npm run balance` shows ~120–185 necro kills/min with
  real damage taken (unlike the melee bots, which are slow everywhere).
- **Line of sight:** tall layout walls (height ≥ 2.5) are registered with `Nav.addSightBlocker`; `WorldSim.wallBetween` now
  also checks them, so Penitent cones and gargoyle dives stop at any tall wall, including the Ossuary's existing partitions.
- **Tests:** `levels.test.ts` (8): no area overlaps, door graph reaches every area, unlock chains, breaches inside the area,
  and a 0.5 m flood-fill from each waystone proving every spawn breach (and the Warren vault) is walkable. The flood-fill
  caught two real bugs (a breach under a pillar and one under a sarcophagus).
- **QA:** `tools/qa/levels-smoke.cjs` (warren, coliseum, pyre screenshots + a mob mix), `pyre-smoke.cjs`, `regent-smoke.cjs`.
  Run them on an idle machine: a leftover headless Chromium makes screenshots time out.

## Armor sets: tuning and findability pass (2026-09-30)

- **Tuning** (`balance:boss` regent, 4 disciplines): the first set ≈ the "intended" gear band (+22 INT/+11 VIT ≈ one rare helm plus kit),
  but the ascended set's flat +2/+1 made a full set ≈ +45 INT and turned the Regent into a stand-still win (non-dodgers 0/2 → 2/2, 125 s → 70 s).
  Trimmed to +1 primary / +0 secondary per ascended piece (full set ≈ +40 INT, +17 VIT); dodging still matters for 3 of 4 disciplines.
  Open for owner feel: 5 of 9 sets are INT/VIT and INT is the best damage stat for every class, so those sets are the default pick.
- **Findability:** the Graves/Ossuary HUD line only showed the first pending seal, so the Warren (150) and Coliseum (350) were never
  announced; it now lists every pending seal. The "A seal breaks" banner says which door to use ("the west door of The Hollow Graves").
  First set-piece drop shows a counsel tip (`armor`); tooltips show "N/5 worn" and say there is no set bonus.
- Migrations 011 and 012 must be applied (`sudo mysql death_muffin < file`) before the client that drops these items is published.

## Necromancer polish pass 1 (2026-09-30)

- **Heals are readable:** new `heal` floating-number kind (green, glowing) for corpse-eat heals, Mourner Litany heals, flasks and the heal event; previously they reused the gold-coin style. Litany now also floats `+N barrier` (`ward`, blue) for Ossuary and `+N` for Mourner (there was no feedback at all).
- **Bone Ward chip** (left column under the Kill Chain): `Bone Ward −N%` for Ossuary, hover explains the 6%/thrall rule and the 60% cap; dim at 0 thralls.
- **Mourner tuning:** wraith HP ×0.7→0.9, corpse heal 6%→8%. Sanctum geared (4 seeds): hurt 169→91 %/min, deaths 2.8→1.3, kills/min 80→95. The earlier 45 kills/min Ossuary reading was a one-seed fluke (4-seed mean ≈126, now ≈110; bot noise is large).
- **Legions have class colour:** Gravecaller's thralls glow violet, Rotweaver's are olive with rot; Ossuary keeps bone ivory + shields, Mourner's are spectral wraiths. Own legion only (other players' thralls keep the default look).
- Still open: effect clutter around the hero, bespoke wraith/plague thrall meshes, Gravecaller trailing Ossuary at levels 8–12, Rotweaver weakest at the Ossuary (≈99 kills/min).

## Necromancer polish pass 2: legions and clutter (2026-09-30)

- **Custom thrall models** (Gemini concept → Tripo biped rig, 10 clips each, ≈175 credits apiece; balance 6,855 → ~6,330):
  `thrall_sentinel` (Ossuary: bone-plate armour, still carries the code-built sword and shield), `thrall_legionnaire` (Gravecaller: violet legion tabard, iron helm),
  `thrall_plague` (Rotweaver: mossy rot with fungus and spore pods, unarmed). Mourner wraiths now use the existing `wraith_thrall.glb` prop.
  `EntityViews` `LEGION` maps discipline → model; it uses the owner's class, so other players' legions look right too. Thralls raised from corpses
  (archer, mage, hound, bearer) and the New Blood classes keep their old look. Specs `art-manifest/tripo-specs/thrall_*.json`, jobs `gemini-jobs/thralls-v1.json`.
- **Clutter:** call-outs that land on the same spot (chain tiers, heals, gold, notices) now stack upward instead of overprinting (`FloatingText`);
  Black Litany loses its outermost ring and its sigil is lighter; the level-up "join your Grimoire" toast lists three rites then "and N more".
- Hero rings (glow, bone ring, cursor reticle) are kept on purpose: they keep the hero findable on dark stone.

## Necromancer tuning pass (2026-09-30)

8-seed `balance` (geared band, gold/min as the kill-rate proxy) found Ossuary well ahead at levels 8-16; Gravecaller and Rotweaver lagged and died more.
- **Gravecaller:** thrall HP ×0.85 → ×1.0, thrall damage ×1 → ×1.15 (passive text updated). Ossuary/Nave/Sanctum gold/min 1377/2347/4304 → 1535/2803/5027, Sanctum deaths 1.8 → 0.5. ×1.35 bought almost nothing more.
- **Rotweaver:** Miasma radius ×1.3 → ×1.4, +10% max health. 1201/2649/3640 → 1605/2796/4746, deaths 0.3/1.1/1.9 → 0.1/0.3/0.6.
- Ossuary is untouched (1527/3179/4504): the three are now within ~10% of each other. Regent and Plague Saint re-run: dodgers still win 3/3, non-dodgers still mostly lose (one geared Gravecaller Regent stand-still win, 1/3).
- Bot noise is ±30 kills/min at 4 seeds; use 8 before believing a delta.

## Validation and QA pass (2026-09-30, after the armor / necromancer deploys)

- **Live bug found and fixed:** `GET /api/chronicle/:id` returned 500 for every character since the Chronicle deploy (`LIMIT ?` bound as a double → MySQL 8 `ER_WRONG_ARGUMENTS`; the mock-pool unit test could not see it). Interpolated the constant, added a source-level regression test, deployed to prod (auth restarted; rollback `deploy/backup-pre-chronicle-fix-20260930-191827`). `live-release-smoke.cjs` now exits 0.
- **New `tools/qa/live-armor-api.cjs`:** throwaway account on the public domain; grants both Gravecaller collections, equips a full set into reserved slots 100-104, checks the stats endpoint (set 1 = +24 INT / +12 VIT, ascended = +40 INT / +17 VIT, matching the client catalogue), swaps collections, and confirms a bag-only `/inventory/save` keeps the gear. Cleans up after itself.
- **Also green:** typecheck, 403 vitest, 75 server tests, offline smokes armor / chain / regent / levels / pyre / flyers-rites / cloister / afk (afk timed out once while the box was loaded, passed alone).
- **Observation, not changed:** `/inventory/add-item` lets any authenticated player add any known item id (qty ≤ 9999) to their own character; loot is client-authoritative by design.

## Brew engine (2026-09-30, Alchemy plan Part 1 A)

One table drives every drinkable buff; the three hardcoded `buffUntil` timers are gone.
- **Where:** `src/content/brews.ts` (`BREWS`, pure helpers `applyBrew`, `brewValue`, `brewWard`, `lifestealHeal`, text helpers). `BUFF_FLASKS` in items.ts is now derived from it (ids and values unchanged). `Player.brews` = `{ elixir, tonic }` active state plus `Player.brewValue(kind, now)` (O(2), no per-effect timers).
- **One read site per kind:** damage `AbilitySystem.sp` (fixes the hardcoded 1.15: Moonlit is now +25%); ward + resist_fire (`ember`/`burn`) + resist_rot (`toxic`/`dust`) in `WorldScene.onHurt` (shares the 60% ward cap in `takeDamage`); lifesteal in `WorldScene.sendIntent` (every direct player hit passes it); haste divides the cooldown when it starts (`AbilitySystem.cast`); speed in `moveMult`; essence in `Player.update` regen; wisdom on kill XP; fortune is the new `itemChanceMult` arg of `rollKill`.
- **Lifesteal cap:** heals `value x damage` per hit intent, counting at most 3 targets, and never more than 1.5% of max HP per hit. No shipped brew uses lifesteal yet (engine only).
- **Drinking:** a new elixir replaces the active one (float "Moonlit replaces Forge-tempered"); the same brew extends, capped at 2x its duration remaining; tonic is independent. Q and healing flasks unchanged.
- **Belt:** **Z** = elixir, **X** = tonic (both were unbound; **F** left free for concoctions). Right-click a brew in the Reliquary or use "Put on belt"; an empty belt auto-fills with the first brew of that slot you carry. Choice persists per character in localStorage (`dm_belt_<characterId>`).
- **HUD:** brew tray under the Bone Ward chip: key cap, glyph, label, countdown bar, belt count; dim "ready" chip when belted but idle; tooltip with exact numbers. Inventory detail and tooltip show the slot, effects and duration.
- **Help:** counsel tip `brew` (first brew drunk), Codex "Elixirs & Tonics" card in the Professions tab (rows generated from `BREWS`), Settings key list, README.
- **Tests:** `src/gameplay/__tests__/brews.test.ts` (11): values preserved, sum/expiry, elixir replaces, tonic independent, extend cap, Moonlight +25%, resist by source, fortune multiplies chance, lifesteal cap. Full suite 414 pass, `tsc` clean.
- **QA:** `tools/qa/brew-smoke.cjs` (offline character, belt keys, damage multiplier 1.15 then 1.25 on replace, tonic survives). Screenshots in `docs/screenshots/brew/`.
- **Not done:** auto-combat does not drink belted elixirs (skipped); no shipped brew uses haste/lifesteal/resists/essence/wisdom/fortune yet (recipes come with Phase C/D).
## Necro weapon line (phase N1, 2026-09-30)

35 items (staff, scythe, wand, ritual sickle, skull focus, grimoire, mourning bell x bone/iron/gold/hell/moon). Design and file map: `docs/NECRO-WEAPONS.md`.
- **Mechanics** (Ossuary, Gravecaller, Mourner, Rotweaver only; all numbers in `NECRO_WEAPON_TUNING`, only Bone Needle changes): staff +25% needle range, pierces 1 extra (80% damage), +10% Spell power; scythe LMB = 100 degree / 3 m reaping arc, up to 3 targets, 115% of a needle each, 520 ms swing, +4 essence per target, +1 soul for kills the arc delivers; wand +30% cadence, -15% damage; sickle needle adds 1 Withered (host-clamped), Exhume refunds 20% essence; skull focus +1 thrall cap at gold+; grimoire -10% rite cooldowns (not the primary); mourning bell: a Mourner's wraith hit heals allies in 14 m for 2% of their own max health.
- **Co-op:** the scythe arc and staff pierce are client-resolved like Ivory Cleave (the caster picks targets, sends one `hit` intent, no relayed-cast duplication). The bell claim rides the `exhume` intent (`allyHeal`, host clamps to 3%) and the host emits `heal` events with a `frac`, each client scaling to its own max health. The ability context now reads `discipline` through a getter (Covenant boons and a Skull Focus swap replaced `WorldScene.discipline`, leaving the cast code holding a stale cap).
- **Server:** no `server.js` change: `/api/inventory/equip` already displaces the off-hand for `two_handed` and vice versa (tested by source assertion; the offline mock now enforces the same rule, tested). Migration **`013-necro-weapons.sql`** (35 items + 35 Workbench recipes, `INSERT IGNORE`) must be applied after a backup, before publishing the client. Items have no level column (armor neither), so levels 1/15/30/45/60 are a tooltip recommendation.
- **Drops/crafting:** bone in Graves and Warren, iron in Ossuary and Coliseum, gold in Nave and Sanctum, hell in Cloister and Pyre, moon in the Pyre at half weight; each tier adds 7 weight-1 entries (under 12% of any table). Carpentry (staff, wand, grimoire) and Smithing (scythe, sickle, skull focus, bell) recipes from planks/ingots. `npm run build:server-rules` was re-run (necro-rules, contract-rules changed).
- **Models:** 7 Tripo static props (Gemini pale-monochrome concept, P1, 50 credits each = **350 credits spent**, 100 under the 450 budget; balance before 6,330-era reading, after about 5,780 with parallel agents also spending, so the remaining figure is shared). One mesh per kind, tinted per tier in `gearProps.tintModel`; procedural lathe/extrude builders stay as fallback. Scythe and sickle are yawed 180 so blades sweep forward. Specs/records in `art-manifest/`, raw files in `art-src/necro-weapons/`.
- **Help:** Covenant tip `necroWeapon` (first time a necro equips a non-staff weapon), Codex Weapons tab, README section, Reliquary tooltips show the effect line and recommended level.
- **QA:** `tools/qa/necro-weapons-smoke.cjs` (Gravecaller + Mourner, asserts GLB swap, tips, ranges, cooldowns, single arc intent, tint difference, off-hand/2H displacement, Skull Focus cap) with screenshots in `docs/screenshots/necro-weapons/`. Unit tests: `necroWeapons.test.ts`, `weaponLine.test.ts`.
- **Open:** animation selection per weapon is N2 (the scythe uses the existing `attack` clip, everything else `cast`); HUD shows no Withered/soul call-out for the scythe beyond the meter; grip/tip alignment of small props (sickle, wand) at default zoom is only verified by eye.
## Necro animation pass (N2, 2026-09-30)

**What shipped.** Five new combat clips on each of the four necromancer heroes (`hero_gravecaller/ossuary/mourner/rotweaver`),
retargeted onto their existing rig tasks (no re-rig), plus a `(weapon kind, rite) -> clip` table. Non-necro heroes, enemies and the
base `necromancer` fallback model are untouched (the table falls back to today's `cast` / `attack` / `dig` when a model lacks a clip).

| Clip | Preset | Window (src s) | Release | Used for |
|---|---|---|---|---|
| `slam` | `slash` (already owned, 0 cr) | 1.3-3.3 | 0.40 | big rites (staff / no weapon / scythe): Corpse Explosion, Bone Storm, Rend, Wall, Bloom, Prison |
| `sweep` | `box_03` | 0.3-1.7 | 0.286 | scythe primary (Bone Needle) |
| `flick` | `pitch_baseball` | 1.25-2.3 | 0.619 | wand / sickle primary and bolt rites |
| `channel` | `sing_01` | 5.9-7.5 | 0.687 | Black Litany, Dirge, Bone Mantle, Grave Offering |
| `summon` | `basketball_shot` | 1.4-3.0 | 0.50 | Exhume, Grave Hands, Rally, Carrion Seed |

**Rejected presets (measured on `hero_gravecaller` with `tools/measure-clips.mjs` + `tools/clip-sheet.mjs`, 120 cr of candidates):**
`golf` (16 s, hands peak 0.38 m/s: a slow practice swing), `shovel` (gardening loop), `lift_heavy` (hip ends at 2.8x standing height, 2.4 m
travel), `fire` (hands peak 0.09 m/s), `football_pass` (no release), `cheer` (good arms-up pose but `basketball_shot` does crouch-then-raise
for the same role), `volleyball` (great spike, 7.4 m/s, but duplicates `slam` and adds an airborne tuck), `warm_up` (stretching).
`box_03` is the weakest accept: a hooking lunge at 2.1 m/s, not a true scythe reap; revisit with a dedicated sweep if the scythe mesh lands.

**Trimming.** Tripo presets carry seconds of idle lead-in/out (`slash` is 6.6 s for a 1 s action), so `tools/build-characters.mjs`
(`COMBAT_TRIMS`) cuts each to its action window, and stores the Hip position relative to the source clip's standing first frame. At runtime
`inPlaceAnimation.ts` (`combatClip`) drops Root motion and ground-plane Hip travel (the `stripRootTravel` rule) but keeps the vertical
crouch/leap. The release fraction is written to each `clips.json` (`release`) and a unit test keeps `CLIP_RELEASE` in sync.

**Selection.** `src/content/castClips.ts`: `ABILITY_ROLE` (rite -> primary/bolt/big/channel/summon) x `WEAPON_CLIPS` (weapon kind or `none`
-> role -> clip); `none` plays like a staff (the default skull staff is in hand). `NecromancerAvatar.cast(..., abilityId)` (the 21 necro
call sites in `AbilitySystem`) asks the table using the equipped main hand (`weaponKind`), so local and remote avatars behave the same (remote gear
arrives through `setEquipment(gearFromIds(...))`). Remote necros now also gesture on the rite events that carry their caster
(`WorldScene.REMOTE_GESTURE`: exhumed, litany, detonated, mantle, offering, rend, rally, seeded); before this they never gestured.
Timing: rites spawn instantly and `lockMs` / `gestureSeconds` are untouched. `planGesture` starts the clip part-way in (`Creature.playOnce(..., startAt)`)
and scales its speed so the release frame lands 0.08 s after the rite fires; heavy clips play at least `minSeconds` (slam 0.55, channel 0.9, summon 0.7).

**Hurt / death.** The lying `hurt` preset was already not shipped (renamed `hurt_down`, PHASE "Animation variety"): the shipped `hurt` is
`hit_to_body_01` (1.3 s) and `hurt2` is `hit_to_head`. Now pinned by `necro-clips.test.ts` (measures the shipped GLBs: flinches under 3 s and
hip >= 0.85 of standing; `death` / `death2` end lying, hip < 0.45). Both death clips were checked on stick-figure sheets and in game strips.

**Cost.** 240 of the 260-credit budget: 120 candidates (12 jobs on gravecaller) + 120 (4 accepted presets x 3 other rigs); `slam` was free.
Every job id is in `art-manifest/necro-anim-jobs.json`. Shared account balance went 6330 -> ~5075 over the session, but other agents also spend
from it; this pass accounts for 240 of that.

**GLB size (before -> after):** gravecaller 2,037,364 -> 2,153,712; ossuary 1,934,240 -> 2,050,628; mourner 1,903,388 -> 2,019,360;
rotweaver 2,174,640 -> 2,290,704 (about +116 KB / +5.7% each).

**Tools:** `tools/ai/retarget-clips.mjs` (budget-capped retargets onto an existing rig), `tools/measure-clips.mjs` (hip height, travel, release),
`tools/clip-sheet.mjs` (stick-figure contact sheet), `tools/qa/necro-anim-smoke.cjs` (in-game strips to `docs/screenshots/necro-anim/`).

**Open:** the scythe / wand / sickle meshes belong to the N1 agent (until they land those ids render as the sword stand-in); the release
timing is verified by numbers and strips, not yet by ear; N3 (weapon trails, hit-stop) not started.

## Reagents and new brews (2026-09-30, Alchemy plan Part 1 D-lite)

Alchemy now has a way in that does not start with farming: mobs drop reagents, bosses leave ichor, two zone herbs are foraged, and eleven new brews use every previously unused Brew kind.
- **Where:** `src/content/reagents.ts` (items, drop specs, brew rows, recipes; one source for client, mock, loot, contracts and migration). `BREWS` = original four + `REAGENT_BREWS`. Migration 009 and 007 are untouched.
- **Migration:** `server/death-muffin/backend/migrations/014-alchemy-reagents.sql`, generated by `node tools/build-alchemy-reagents-sql.mjs` (`--check` runs in vitest), INSERT IGNORE only. **Apply order: 013 (necro weapons, other branch) then 014**, before deploying the client (contracts and gathering reference the new ids).
- **Icons:** `node tools/build-reagent-icons.mjs` draws 25 SVGs (armor-set style) into `public/art/items/` (no generation credits; `--check` in vitest).
- **Drops** (independent per-kill roll in `rollReagents`, own rng stream so seeded balance runs are unchanged; elites x4, fortune tonic multiplies): Grave Dust 1.0% (1-2) Graves, 1.2% Warren; Wraith Ectoplasm 10% wraith, 8% seraph (any area); Plague Bile 1.0% Cloister; Cinder Ash 1.2% Pyre. Measured ~4-8 dust / 10 min at 40 kills/min. Boss ichor: `rollBoss(..., bossId)` always adds exactly one (`ichor_gravedigger/abbess/congregation/prelate/plague_saint/regent`).
- **Zone herbs:** nodes `rot_cap_patch` (Cloister) and `ash_bloom_patch` (Pyre), new node kind `herb`, skill gardening, level 1, 10% seed per pick, 3 patches per zone via `richNodes` (off boss arenas/doors). Seeds `seed_rot_cap` (Gardening 35) and `seed_ash_bloom` (50) plantable in the Acre. Patches are not laborer posts and not contract candidates (their herbs enter via the seed list).
- **Recipes (alchemy):**

| Lvl | Brew | Slot | Effect | Needs |
|---|---|---|---|---|
| 1 | Grave-Dust Tonic (x2) | tonic | +20% essence, 60s | 4 Grave Dust |
| 10 | Wraithquick | elixir | +15% haste, 45s | 2 ectoplasm, 2 dust |
| 22 | Grave-Luck | tonic | +15% drops, 60s | 6 dust, 2 nightshade |
| 28 | Sexton's Insight | tonic | +15% XP, 60s | 3 ectoplasm, 3 moss |
| 38 | Leechblood | elixir | 4% lifesteal, 45s | 2 bile, 3 dust |
| 42 | Rot-Proof | elixir | 40% rot resist, 75s | 1 bile, 3 rot-cap |
| 52 | Cinderskin | elixir | 40% fire resist, 75s | 1 ash, 3 ash-bloom |
| 62 | Ghostwalk | tonic | +30% essence, +10% speed, 75s | 4 ectoplasm, 2 wolfsbane |
| 70 | Bloodmoon | elixir | +20% damage, 6% lifesteal, 60s | Gravedigger + Abbess ichor, 2 bile |
| 78 | Hymnal | elixir | 15% ward, 20% rot resist, 3% lifesteal, 75s | Congregation + Plague Saint ichor, 4 ectoplasm |
| 85 | Regent's Vigil | elixir | +12% damage, 15% ward, +10% haste, 60s | Regent + Prelate ichor, 3 ash |

- **Contracts:** new brews and the four mob reagents join `candidatesFor` (small orders, gated by alchemy level). Note: boards for the current day change when deployed.
- **Help:** counsel tip `reagent` (first reagent pickup), Codex "Reagents" card (sources, recipes, numbers generated), Professions counsel text, README.
- **Tests:** `reagents.test.ts` (dead-end, ids, drop rates, ichor in every boss spoil, starter needs only mob drops, recipes/brews valid, patches placed, migration + icons check). Existing acre/alchemy/processing/gathering tests updated for zone-only gardening nodes and the 014 migration. `tools/qa/reagents-smoke.cjs`, screenshots in `docs/screenshots/reagents/`.
- **Not done:** auto-combat does not drink brews; no bespoke herb-patch GLB (code-built stand-in).

## HUD UX pass: bug button, self-explanatory belt, key-art splash (2026-10-03, branch dm/hud-ux)

Owner feedback: the report form was buried in Settings; the elixir belt was hard to recognise and "put on belt" hard to find; the web loading screen should wear the launcher's art.
- **Report a bug:** a small button just above the chat input (bottom left, `.hud-bugbtn`) calls `HudCallbacks.reportBug` -> `closePanels()` + `SettingsPanel.openBugReport()`. No per-frame work.
- **Belt:** `.hud-brews` now has a "Belt" header; empty Z/X slots are dashed with "+ add" and a hint tooltip; clicking a Z/X slot opens `BeltPicker` (brews of that kind in the bag, the one on the belt flagged, a "brew it in the Alchemist's Wing" line when none); a brew dragged from the Reliquary (`draggable`, `BELT_DRAG_TYPE`) drops onto the slot; the "Put on belt (key Z)" detail button is `primary` and the bag tooltip names the belt key. Escape closes the picker first. The Heal slot stays automatic (best flask first). Counsel: `belt` tip rewritten and now fires the first time the bag holds a healing flask or brew (`tickOnboarding`); `brew` tip, Codex line and README updated; `tips-desktop.fixture.json` refreshed for those two tips.
- **Splash:** `public/art/loading/keyart-960.webp` and `keyart-1600.webp` (from `death-muffin-key-art.png`, WebP q58) replace the covenant art; `index.html` inline CSS and `LoadVeil` share the markup: title bottom-left (Georgia bold, violet glow), gold status line, thin violet bar that slides while the page splash waits, scrim from the bottom and left so the necromancer (right of centre) stays clear; `object-position: 68% 50%` keeps him in frame on narrow windows.
- **Tests:** `beltPicker.test.ts`, `beltRules.test.ts` (new hint), onboarding fixture; browser: `tools/qa/hud-ux-smoke.cjs`.

## Progressive HUD, merged panels, NEW cues (2026-10-03, branch dm/hud-progressive)

- **Gated (stays revealed, per character):** Upgrades plate (first gold gained in a hunting ground), its Active wave dial (a Wave tier owned), Soul Shards counter (first shard), Omen chip (hidden in safe areas, a one-time NEW cue on the first hunt), hotbar "Swap spells" + Menu Spells (first learned alternative rite, the old SWAP rule), Menu Atlas (first gear piece), Menu Acre (first skill XP), thrall counter (necromancers or a standing thrall). Keys always work. Existing characters are seeded silently from level / gold / tiers / shards / areas.
- **Merged:** Acre ledger = Skills + Garden + Laborers + Contracts; Character = Stats + Capes & Pets; Grimoire = Grimoire + Legion. Panels are hosted unchanged in `TabbedWindow` slots (CSS flattens their plate); only the visible tab's panel is open.
- **NEW cue:** `HudReveal` (store), `CueQueue` (one toast at a time), `setNew` on the HUD / windows. Pip + glow stay until hover (HUD readouts) or open (menu buttons, tabs); a used cue never returns.
- **Tests:** `progressiveHud.test.ts`; browser: `tools/qa/hud-progressive-smoke.cjs`. Screenshots: `docs/screenshots/hud-progressive/`.

## Loadout presets (2026-10-03, branch `dm/loadouts`, not deployed, migration 037)

Necromancers save rites + runes + weapon/off-hand under a name and apply them in one click (Grimoire, under the rite bar).
- **Data:** table `character_loadouts (character_id, slot 0-5, name VARCHAR(24), data JSON)`; `data` = `{ rites: { primary, keys[5] }, runes: { <rite>: <rune> }, weapon, offhand }`, weapon/off-hand = `{ itemId, instanceId|null }` (a rolled piece is matched by its roll, never by item id alone); `null` hand = left as it is on apply.
- **Rules:** `src/gameplay/loadoutRules.ts` (validation, `captureGear`, pure `applyLoadout` over inventory rows); bundled for the backend as `gathering/loadout-rules.cjs`. The server applies from the stored preset (the client sends only the slot), inside one transaction over every locked row, and writes the row difference. Each step is all-or-nothing: missing piece -> `missing`, no free bag slot for what leaves a hand/socket -> `no_room` (nothing moves), the rest still applies. The rites half is applied by the client (rites live in browser storage); unlearned rites fall back like any saved bar.
- **Offline mock:** `/api/loadouts/*` in `mockBackend.ts` use the same rules module.
- **Help:** counsel tip `loadouts` (calm, in the `gear` group; at >= 6 rites learned or >= 2 runes), Codex entry under Relic Runes, README "Loadouts". Hotkeys: `keybinds.ts`, unbound by default, bound in Settings → Controls (click, press a key, Esc clears; refuses game keys and duplicates), shown on the cards; `keybinds.test.ts`.
- **Tests:** `loadout-rules.test.ts`, `mockLoadouts.test.ts`, `loadoutPresets.test.ts`, server `loadouts.test.cjs` (save/validate/ownership, apply, missing pieces, full bag). QA: `tools/qa/loadouts-smoke.cjs`.
