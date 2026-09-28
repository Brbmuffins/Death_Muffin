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
