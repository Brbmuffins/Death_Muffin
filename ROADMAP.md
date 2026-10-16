# Roadmap

The game is the Godot online client, necromancers plus the Reaper (a scythe class with a soul bag, first pass). It is being rebuilt
underneath (below). Order of work follows the owner's rules: performance first, polish over new content, necromancer focus. Open gaps
are listed once, in [KNOWN-GAPS.md](KNOWN-GAPS.md); decisions in [DECISIONS.md](DECISIONS.md).

## Now: the rebuild (Helix, 2026-10-16)

Death Muffin is rebuilt underneath so the same game runs smoothly on low-end PCs and laptops (phones later) and looks great on high-end
PCs, on a simple foundation that does not need patching again (DECISIONS B34-B42). Same game: same rules, numbers and timing. Every
difference from today is written down; improvements are proposed to Helix, never slipped in. Ascension leaves on launch day and comes back
redesigned right after (B36). First-guess timing: 4 to 6 weeks of working days, re-estimated at Gate B.

**The foundation (B34, B35).**
- The rebuild is its own Godot project, `client/`, next to the live game in `godot/`, which it never changes (B41).
- A C++ combat core (GDExtension, source in `native/`) owns every enemy and thrall in flat arrays: spatial grid,
  movement and separation, targeting, damage, status, affix and necromancer rules. It steps once per 60 Hz tick (same timing as today);
  per-creature work never crosses into GDScript during a tick (one ordered event buffer back), while rites and bosses call it directly (B42). Think and move run in parallel on `WorkerThreadPool`; hits and
  deaths resolve in one fixed-order pass.
- The GDScript game layer in `client/` does the HUD, menus and panels, areas, hero controls, boss scripts and flow.
- Crowds are drawn in bulk on the GPU: one MultiMesh per creature model and LOD, animations baked into vertex-animation textures from the
  existing GLB files. The hero and bosses keep full skeletons.
- Areas become scenes with the same layouts, built by a tool from `godot/data/slice/world.json`, with baked navmesh, occluders, visibility
  ranges and baked lighting (`LightmapGI`, baked on Helix's PC through a one-click helper).
- Forward+ at every PC preset; Compatibility is only the automatic fallback; the Mobile renderer is for phones.
- On launch day `client/` becomes the game and `godot/` is retired.

**Performance rules (B39).** No goal to stop at: as much performance as we can get with the Forward+ graphics on top, and nothing ships
slower than what it replaces. Floors protect weaker PCs: a 2020-era laptop at Low never drops below 60 fps in normal play or 45 in the
biggest fight; a GTX 970-class PC at Medium never drops below 60 in the biggest fight. The biggest fight is the benchmark's Full Party fight:
4 necromancers with all their thralls (about 32), 72 enemies and a boss, all run by the host. Budgets (starting points, set for real in the
test build, each with an automatic check): in the headless Full Party fight on the VPS (stand-in for a weaker processor) the combat core
4 ms and the rest of the main thread 4 ms; the HUD 0.5 ms and 150 draw calls on Helix's PC; crowd models at most 5,000 triangles and
1024-pixel textures with LODs, hero and bosses at most 20,000 and 2048. Godot stays 4.7.2 for the whole rebuild.

**Before numbers** (Standard fight, 30 enemies and 20 thralls, Compatibility): Helix's PC (Ryzen 9 5950X, RTX 4070 SUPER, 1440p Ultra)
99 fps, GPU 2.9 of 10 ms; warbogar's PC (Core i7-8700K, Arc B580, 1080p High) 41 fps, GPU 4.5 of 25 ms. Both processor-bound; the HUD is
about 550 of 800 draw calls; slow frames pay extra 60 Hz catch-up steps. Calm play already reaches Helix's 170 Hz.

**Phases and gates.** Gates are checked on Helix's PC and the VPS processor test; brbmuffins' and warbogar's PCs join before launch day, and
at least one other graphics brand runs Forward+ before then. The team plays the rebuild through the launcher's Test build switch on a test
server (B38).
1. **Prep** → Gate A: today's game on Forward+ runs on Helix's PC without crashing.
2. **Test build** (the Hollow Graves, the Gravecaller, enemies, thralls and a boss on the core, GPU crowds, the new HUD, Low to Ultra, 2-player
   co-op) → Gate B, the engine checkpoint: the Full Party fight at least twice today's speed on Helix's PC and in the VPS processor test with
   Forward+ on, rule tests match today's, co-op works, budgets met. A miss: fix it, or rethink the engine before any content moves.
3. **Bring everything over** (the other disciplines, the Reaper, 13 areas, 7 bosses, the Depths, loot and gear, panels, social, tips, sound)
   → Gate C: every rule test matches, playtests OK, nothing slower than the test build.
4. **Look pass** (Ultra extras, every area's lighting, Low made to look good) → Gate D: floors met on every preset measured, every area's
   look signed off by Helix.
5. **Launch day:** one update for everyone; the last old build stays downloadable and accepted for 2 weeks (B40); then the old code and the
   paths only it used go.

**Prep checklist** (the current work):
- [x] The plan in the repository (this section, DECISIONS B34-B42).
- [x] C++ build: `native/build.sh` builds the core for Linux (tests) and Windows (mingw-w64, static runtime) against godot-cpp pinned at
  1e79263; `client/setup.sh` imports the new project and runs `client/tests/core_smoke.gd` (the core loads and answers).
- [x] Test build channel: `server/death-muffin/test-channel/publish-test-channel.sh <rev>` publishes to /death-muffin/client-test/ with its
  own work folder and asset cache; builds of the live project get Forward+, their own user folder and the test backend in a scratch copy.
- [ ] Launcher Test build switch: the test build installs next to the normal game and updates itself; a test copy is checked on Helix's PC
  before the launcher release goes to everyone.
- [x] Test server: `death-muffin-auth-test` on 127.0.0.1:5194, its own database and user, public at /death-muffin/test-api/, copies
  of the team's accounts (`server/death-muffin/test-server/`). The lobby and relay for test co-op come with the test build (Gate B).
- [ ] Full Party benchmark fight in today's game, with before numbers on Helix's PC and in the VPS processor test.
- [ ] First test build: today's game on Forward+, fixing only what stops it running → Gate A.

**Test build checklist** (built ahead while Gate A waits; nothing from it reaches anyone before Gate A passes):
- [x] Assets: `tools/rebuild/sync-assets.mjs` copies the test build's assets from `godot/assets` into `client/assets` by the list
  `client/assets.list`. The Hollow Graves are in it; each later item adds its block (the Gravecaller, the Graves roster, thralls, the
  Gravedigger King, effects, sounds, HUD art).
- [x] The Hollow Graves as a scene: `tools/rebuild/build-areas.sh graves` converts `godot/data/slice/world.json` into
  `client/areas/graves.tscn` (same layout, static colliders, offline-baked navmesh, occluders, visibility ranges); the other 12 areas
  use the same converter. `client/tests/area_graves.gd` proves the layout against world.json.
- [ ] The first lighting bake of the Graves through Helix's helper.
- [ ] Static batching: after the bake, merge each 12 m cell's static props into one mesh (about 250 draw calls for the Graves' 132
  prop instances today; phones and weak laptops need far fewer).
- [x] Crowd animation: `client/crowd/` bakes each creature model's clips into vertex-animation textures (`bash client/tools/bake_crowd.sh`;
  the robber and the hound so far) and the crowd material plays them per MultiMesh instance (`client/tests/crowd_bake.gd`).
- [ ] Crowd drawing: the core writes each creature model's MultiMesh buffer once per rendered frame, interpolated between ticks.
- [x] Core skeleton (native/README.md "Design"): enemy table in spawn order, heroes and bosses as external entities, tick, timers in
  doubles, seeded randomness, grid, event buffer, damage with synchronous kills, radius queries, bulk reads; `client/tests/core_api.gd`.
  Thrall, corpse and status tables come with their items.
- [ ] Core enemies: the Graves roster (robber, hound, penitent, sac, moth, bat, ghoul) with elites and affixes. The roster's brain,
  elite stats and hostile zones are in the core (`client/tests/core_enemies.gd`); affixes are next, now that statuses and corpses are in the core.
- [x] Core thralls, corpses and statuses: statuses (`client/tests/core_status.gd`), thralls with their brain, legion and enemy targeting
  (`client/tests/core_thralls.gd`) and corpses with the toxic pool (`client/tests/core_corpses.gd`). Not in it: the Veilwalker's echo corpses,
  views and co-op snapshots (their own items), and the rites that call it.
- [ ] Client layer: login to the test server, character select, hero, camera, input, the Gravecaller's rites on the core, the
  Gravedigger King's brain as an external entity.
- [ ] The new HUD (same layout and look, under 150 draw calls) and the Low to Ultra presets.
- [ ] 2-player co-op: a test lobby and relay, core snapshots.
- [ ] The Full Party fight in the new client with the budget checks, and a seeded scenario comparison with today's game → Gate B.

**Working rules for the rebuild.**
- This checklist is the only to-do list; the next unchecked item is the only work. Ideas go to "After launch day".
- Each item ends as a tested commit. Architecture rules are tests: no node or script per creature, no per-creature calls across the core
  boundary during a tick, no per-frame allocations in the core, the HUD draw-call cap.
- Subagents work in their own worktrees, never push or deploy, and report in a few lines; the main session runs their tests and reads their
  diffs before merging.
- Stop rules: three failed tries at one problem, an item at twice its estimate, or a plan that does not fit what the code shows → stop that
  line, write it down, ask Helix with options.
- Easy-to-undo choices are made and recorded in DECISIONS; anything hard to undo or that players would notice waits for Helix.

## The live game during the rebuild (B37)

Bug fixes, warbogar's armor sets (each new set is also checked in the rebuild) and server safety work only; feature requests go to "After
launch day". Server authority (DECISIONS B19-B26, B32) is live and enforced. Still to do on the server: watch `progress_audit` for rule false
positives, make area kills, shards and seals in the necromancer save come only from accepted reports, clear the old audit rows, a Discord
notice when a character trips a flag, and a rollback runbook on `character_save_versions`. Pck encryption moves into the rebuild's build
pipeline. The model stays hybrid (owner, 2026-10-15): a player's PC hosts the combat, the server owns everything of value; no server-side
combat simulation for now.

## After launch day

- **Ascension, redesigned** (B36): the first new feature. Players' saved boons, Ashes and best rank are kept for it.
- **Necromancer polish:** combat feel and loot for the four disciplines from playtests, readability of rites and statuses, gear and affix
  legibility, the first hour (Next-step box, counsel tips, guide NPCs); the rejoin window (D13) and the party gaps (KNOWN-GAPS: Party and
  online).
- **Ideas parked during the rebuild:** colours in the chat window (2026-10-13).
- **Found during the rebuild, today's game ignores them** (kept as they are until Helix decides; the core already emits each one):
  toxic corpse pools always hit as at level 1 (nothing sets the area level), a fallen plague bearer's pool never appears, and the
  Mourning Bell wraith's ally heal never happens (both are signals nobody listens to).
- **Phones:** on the Mobile renderer, following the phone rules kept since the rebuild (B40).

## Later

- **The other five disciplines** (Grave Warden, Bell Monk, Carrion Witch, Hollow Knight, Veilwalker) on the Godot kit and rite
  system; their data is in `godot/data/content/`. Shrouded suspension, monk beat meter and Bulwark come with them.
- **New content after polish:** new zones (the Hollow Court), more bosses with summoning keys, new enemy archetypes, replay and
  endgame depth (weekly Omen variants, deeper Depths rewards).
- **In-game leaderboard panel** (KNOWN-GAPS: UI).
- Not planned: VPS-hosted sessions (headless Godot) and host migration.
