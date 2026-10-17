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
4 ms and the rest of the main thread 4 ms; the HUD 0.5 ms and 150 draw calls on Helix's PC; crowd models at most 5,000 triangles (the Bone Colossus 6,000) and
1024-pixel textures with LODs, hero and bosses at most 20,000 and 2048. Godot stays 4.7.2 for the whole rebuild.

**Before numbers** (Standard fight, 30 enemies and 20 thralls, Compatibility): Helix's PC (Ryzen 9 5950X, RTX 4070 SUPER, 1440p Ultra)
99 fps, GPU 2.9 of 10 ms; warbogar's PC (Core i7-8700K, Arc B580, 1080p High) 41 fps, GPU 4.5 of 25 ms. Both processor-bound; the HUD is
about 550 of 800 draw calls; slow frames pay extra 60 Hz catch-up steps. Calm play already reaches Helix's 170 Hz.
Full Party fight on Helix's PC (Sanctum, 1440p Ultra, today's game on Compatibility, 2026-10-16): 61.5 fps, p95 21.0 ms, about 944 draw calls.
Full Party fight, VPS processor test (today's game at c47c35a1, headless, `--benchmark --bench-size=full_party --bench-class=2`, 2026-10-16):
the Hollow Graves (Gate B's room) 14.3 ms a frame on average, p95 24.4, p99 33.5; the Bell Sanctum 13.6 ms, p95 22.2 (an earlier run gave
17.2 ms: the shared VPS varies by about a fifth, so Gate B runs today's game and the test build back to back).
**Gate B, Full Party in the Hollow Graves, VPS processor test** (2026-10-16: today's game and the rebuilt client at aa0bca07 plus the benchmark port, headless, run back to back three times each,
alternating, `--benchmark --bench-room=graves --bench-size=full_party --bench-class=2`, Full length; the client's own report, client/README.md "The benchmark"). With `--fixed-fps 60` before `--path` (a tick with every
frame, no idle pad: this is the processor test) today's game takes 16.2 ms a frame on average (runs 15.7 to 16.9; p95 24.3, p99 31.1) and the rebuilt client 5.4 ms (5.1 to 5.9; p95 9.1, p99 17.4):
**3.0 times today's speed on average, 2.7 times at p95, 1.8 at p99** (the gate asks for 2 times). In the same runs the client's budgets: combat core 2.0 ms a tick of 4 (step 1.8, crowd sync 0.05, event dispatch 0.2) PASS;
rest of the main thread 3.4 ms a frame of 4 (3.2 to 3.9) PASS, with little room; the HUD's share cannot be told from noise headless (0.3 ms give or take 0.6, against 0.5; Helix's PC measures it with the draw calls).
A plain headless run (no `--fixed-fps`) pads every frame to 6.9 ms (Godot waits that long when no window can draw), so the client reads 7.0 ms there against today's 16.5 (15.2 to 17.7): 2.4 times, a floor not a cost; the
report warns and does not judge the rest of the frame then. The client's fight is cheaper than today's by what it does not have yet: the panels, the graphics presets
(today's HUD with its panels cost 2.7 ms of its 15.6 in the same fight: `tests/perf/fight_breakdown.gd --full-party --area=graves`, fixed 60; the client has the HUD, not the panels).
**With value in** (2026-10-16, 8e621396: rewards, loot drops, the kill ledger and the progression in the client's fight too, as in today's), back to back three times each with
`--fixed-fps 60`: today's game 14.7 ms (14.4 to 15.4; p95 22.3, p99 29.4), the rebuilt client 6.2 ms (6.0 to 6.4; p95 10.3, p99 17.6): **2.4 times on average, 2.2 at p95,
1.7 at p99**. An A/B of the client before and after (four runs each) puts value at about 0.5 ms a frame: the value code itself is about 0.015 ms (0.44 ms a kill, 0.004 ms a
blow), the rest is today's rules now playing in the fight (level-ups refreshing the hero, more kills and corpses), which today's game pays too. The rest of the main thread
is now 3.8 to 4.1 ms of its 4: on the line (Gate B item below). With the effects' particle ring in C++ (the same day, A/B four runs each): the client 5.0 ms a frame, the rest
of the main thread 3.1 ms: about **2.9 times** today's 14.7. With the core's own navmesh (ad7d68eb, DECISIONS B47; three runs each, alternating): today's game
14.9 ms, the client 3.2 ms (p95 6.7, p99 14.2; the core 0.47 ms, the rest of the main thread 2.8 ms): **4.6 times on average, 3.3 at p95, 2.0 at p99**.

**Full Party in every room, the rebuilt client** (VPS processor test, 2026-10-17, rebuild/bench-rooms on dcd89c4d, the seven bosses in: headless, `--fixed-fps 60`, Full length, `--benchmark --bench-room=<room> --bench-size=full_party --bench-class=2`, each room twice,
in room order and then reversed, on a shared machine whose load swung between 6 and 12). Average frame in ms, the two runs: Graves 4.1 and 3.7, Warren 3.8 and 3.5, Ossuary 3.7 and 3.8, Nave 3.6 and 5.8, Coliseum 4.1 and 3.6, Bell Sanctum 3.4 and 3.3,
Cloister 5.7 and 5.2, Pyre 5.1 and 6.3, Fen 4.2 and 3.8 (p95 7.0 to 12.4). Every room's boss was awake for the whole measured window (the Warren and the Coliseum have none; the Bone Abbess was defeated once and woken again in both of her runs).
The combat core is 0.36 to 0.71 ms a tick of its 4, its event dispatch the largest part (0.24 to 0.51 ms). The rest of the main thread, against its 4 ms: 2.9 to 3.6 ms in the Graves, Warren, Ossuary, Coliseum, Sanctum and Fen; **over in the Cloister (5.2 and 4.7)
and the Pyre (4.5 and 5.6)**, and in one of the Nave's two runs (3.2 and 5.2: the machine's noise or the room, not told yet). The report's timing shows no more than that: the Pyre has the highest event dispatch (0.43 and 0.51 ms) and physics time with about 29 corpses
on the ground, the Cloister's core is ordinary (0.47 and 0.52 ms) and what its rest holds is not itemized there (a per-system timing of a Full Party frame in these two rooms, `tools/godot/profile.py`, is the next step). Loading the room's area alone instead of the whole world
changed nothing measurable in the Graves (three runs each, alternating, Quick length: 3.7, 3.6 and 4.8 ms against 3.9, 3.5 and 4.8). Today's game's numbers per room are the other half of Gate C.

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
- [x] Launcher Test build switch: the test build installs next to the normal game and updates itself (launcher 0.9.2, live 2026-10-16
  after Helix checked a test copy on his PC; Ctrl+click Settings, launcher/windows/README.md "Test build channel").
- [x] Test server: `death-muffin-auth-test` on 127.0.0.1:5194, its own database and user, public at /death-muffin/test-api/, copies
  of the team's accounts (`server/death-muffin/test-server/`). The lobby and relay for test co-op come with the test build (Gate B).
- [x] Full Party benchmark fight in today's game, with before numbers on Helix's PC and in the VPS processor test. Live since 06cccafc;
  the numbers are in "Before numbers" (Helix's PC: the Sanctum; the Graves comes with Gate B's back-to-back run).
- [x] First test build: today's game on Forward+, fixing only what stops it running → **Gate A passed** (2026-10-16, Helix's PC): it runs
  without a crash or a broken screen and is faster (Full Party, Sanctum, 1440p Ultra: 61.5 fps, p95 21.0 ms on Compatibility; 100.2 fps,
  p95 14.2 ms, worst 22 ms, no hitch on Forward+). The lighting looked wrong on Forward+ (flat cream pools under every light, white glow
  blobs, a darker and purpler ground): the causes were found and the first part fixed on 2026-10-17 (the look pass's first item, below;
  client/README.md "The look against today's game"; Helix 2026-10-16: "if there is a looks pass later we can wait").

**Test build checklist** (built ahead while Gate A waits; nothing from it reaches anyone before Gate A passes):
- [x] Assets: `tools/rebuild/sync-assets.mjs` copies the test build's assets from `godot/assets` into `client/assets` by the list
  `client/assets.list`. The Hollow Graves are in it; each later item adds its block (the Gravecaller, the Graves roster, thralls, the
  Gravedigger King, effects, sounds, HUD art).
- [x] The Hollow Graves as a scene: `tools/rebuild/build-areas.sh graves` converts `godot/data/slice/world.json` into
  `client/areas/graves.tscn` (same layout, static colliders, offline-baked navmesh, occluders, visibility ranges); the other eleven areas that are
  not generated at runtime are converted the same way. `client/tests/areas.gd` proves every area's layout against world.json.
- [x] The first lighting bake of the Graves through Helix's helper (2026-10-16, RTX 4070 SUPER, 5.8 s): `client/areas/graves.lmbake` and its lightmap
  (prop lights and the area's ambient baked, the moon real-time). The helper, the editor plugin and the kit publisher: `client/addons/dm_bake/README.md`;
  `client/tests/areas.gd` fails when a converter change leaves the bake stale (a baked mesh gone).
- [x] Static batching, measured and not kept (2026-10-17): Forward+ and Mobile already draw identical prop meshes as one instanced draw, so merging each 12 m cell's
  props into unique meshes raised the Graves' world draw calls (33 to 56 in a rendered count; Helix's World row 123 to 153) for 25 MB more and a slower load. The props
  stay prefab instances; what cuts draws further is fewer distinct meshes and materials (the asset rebuild).
- [x] Crowd animation: `client/crowd/` bakes each creature model's clips into vertex-animation textures (`bash client/tools/bake_crowd.sh`;
  the robber and the hound so far) and the crowd material plays them per MultiMesh instance (`client/tests/crowd_bake.gd`).
- [x] Crowd drawing: `DmCrowd` reads the core's tables after each step and writes each creature model's MultiMesh buffers once per rendered frame, interpolated between
  ticks (clips, blends, flash, knock, rise, death into corpses, shadow budget, level of detail); `CrowdView` builds the nodes from the baked models
  (`client/tests/crowd_view.gd`, `client/crowd/README.md` "Driving the crowd"). Left out on purpose, each its own item:
  - [ ] Crowd looks: a crowd thrall is drawn as today's (2026-10-17, `client/tests/crowd_look_smoke.gd`: the same thralls skinned and crowd-drawn in the Graves' lighting, Forward+ and Compatibility on
    the software drivers; the lighting alone, no glow and no rim, comes within 5 levels of a colour channel of today's). The test build's "flat lavender" was the crowd material's metallic factor, 0
    where today's glTF material has 1: armour and bone read matt and silver, +38 levels over a thrall's pixels, and without the rim and the normal map nothing broke it up. Now the glTF's factors, the normal map
    (a frame from the derivatives, the crowd mesh has no tangents), the friend rim (0.9 for this player's thralls, 0.6 for another's, a champion's gold 1.4) and the Leech's slither. The rim rides the glow's palette
    slot: no instance data, no draw call (a material per rim would split each model's MultiMeshes by the rims in them: 8 groups drawing in the Full Party against 10), see `client/crowd/README.md` "Differences
    from the creature material". Not drawn: the legion kit's armour tint and weapon tier colour, which today's game never shows either (no host gives DmEntityViews a `legion_kit_for`: "For review"). Left:
    the Bone Colossus's rim reads fuller than today's in the Forward+ test (a pose that differs, or the baked normals
    at its hard edges: to look at on a real GPU). Done (2026-10-17): sinking bodies fade out as they sink, and the Shrouded ward's body is see-through, through the crowd's alpha path (the "Crowd effects, the rest" item below).
    Done before: every body's glow (elite, risen and drowned, wraith, wisp, a legion's thralls with the empowered and champion boosts) through a glow palette, no extra
    draw call (`client/crowd/README.md`), the wings, the spectral wraiths (see-through, no shadow), the dirt mound over a ghoul underground (`DmEnemyFx`), and the thralls' hand props (swords, shields, bows, staffs:
    "<model>+<kind>" variants, `client/crowd/README.md` "Hand props").
  - [ ] Crowd download size: a thrall variant (`<model>+<kind>`) shares its plain body's textures and draws its hand props as rigid meshes on a baked hand-transform track (one small
    RGBAF texture per variant; under 2 MB a variant, it was about 25 MB), and positions are three integer codes over the model's bounds in one 32-bit texel (4 bytes, they were 8). The
    baked crowd is 234 MB, it was 565 (the test build #4's 493 MB assets pack held 200 MB of variants); draw calls are today's (no extra MultiMesh), and the variants no longer upload their own
    copy of the textures. Positions are within 1.5 mm for most models and 2.9 mm for the widest boxes (a colossus's; the half floats had 2.4 mm there); the props are where today's
    formula puts them (0.001 mm): `client/crowd/README.md` "What is baked", "Hand props", `client/tests/crowd_bake.gd`. Left: the first rendered check on a real GPU
    (`client/tests/crowd_smoke.gd`, Forward+, Mobile and Compatibility): the shader's integer decoding and its prop branch are proven in a line-by-line mirror and a GLSL compile, not yet on a renderer.
  - [x] Crowd effects, the rest (2026-10-17): `DmEnemyFx` plays the telegraphs, swings, deaths, voices, rising dust, dust clouds and the affixes' bell, meal and burst from the core's events, and the status
    and idle motes on its 5 Hz ambient tick (the Flagellant's frenzy, the Pyre's and the Fen's: `client/tests/world.gd`); the last of native/README.md "Differences", the fade of a sinking body and of the Shrouded
    ward's, is the crowd's alpha path: a fade group a model and level (MultiMesh, alpha shader, no shadow), a body in it only while it is not solid (opacity `1 - sink_t / 0.9` as it sinks, the ward eased to 0.38 at 6 a second and
    solid where the body falls), the opacity in the clip index's fraction (no instance float more), closed bodies cull their back faces in it as today's fade variant does, a ghost needs no group; the Full Party with 24 bodies
    sinking and three shrouded elites draws two crowd draw calls more (22 to 24, `client/tests/draw_budget.gd`), rendered once on llvmpipe (`client/tests/crowd_fade_smoke.gd`: `client/crowd/README.md` "The alpha path");
    Forward+ and Mobile not yet seen (a look for Helix's PC). Done: the thralls' ground rings, the shattered corpse (`DmCrowd.shatter`) and each corpse's puff when it goes, the landing dust (`DmCrowd.take_landings`), the corpse rings and the toxic disc, the affixes' standing marks and motes, the status tells and the fliers' motes (their cost in the VPS Full Party fight, headless, two rounds each: 5.06 -> 5.22 ms a frame on average, the median unchanged; today pays the same effects every frame).
  - [ ] Crowd cost. In the crowd (`client/crowd/README.md` "Crowd cost"): animation bands (a body beyond 32 m of the camera works its pose out 24 times a second, beyond 60 m 10 times; always placed every frame), bodies outside the camera's
    view not written (a casting body kept while its shadow falls in), the thrall shadows counted (instances, MultiMeshes and triangles in the shadow pass) and switchable for a run, and the level-of-detail distances (32 and 60 m) and the
    128-instance reserve as settings the benchmark records; `-- --bench-crowd=...` changes them for a run. Measured on the VPS (headless): the crowd's whole CPU is 30 to 50 us a frame at Full Party, so the saving is on the GPU.
    Left for Helix's PC (the Full Party, a few alternating runs each way): what culling and the bands save in the render CPU and GPU columns; whether the thralls' shadows (4 of 5 casting instances) are worth their triangles, kept or
    capped; the level-of-detail distances and the reserve, from the draw calls, triangles and upload. Then tick this. (The crowd's draw calls are the groups in use: `client/crowd/README.md` "Crowd cost".)
  - [ ] The whole roster baked (`bash client/tools/bake_crowd.sh`; the Graves' whole roster, robber, hound, penitent, sac, moth, bat, ghoul, rat and risen, and the thralls are baked and synced so far) and its models synced (`client/assets.list`); a first look on Forward+ and Mobile.
  - [x] Unrigged creatures (props today's shader animates, `DmCreatureMat` wings): the baker's static-mesh path bakes the wing beat into a 24-frame
    loop (moth and bat within about a millimetre of today's formula, `client/tests/crowd_bake.gd`); a model without wings gets a still pose.
  - [x] Co-op guest: a puppet core is drawn by `DmCrowd.sync(core)` like a host core (its hits come from the hp drops it derives); no translation into `sync_rows` is needed.
- [x] Core skeleton (native/README.md "Design"): enemy table in spawn order, heroes and bosses as external entities, tick, timers in
  doubles, seeded randomness, grid, event buffer, damage with synchronous kills, radius queries, bulk reads; `client/tests/core_api.gd`.
  Thrall, corpse and status tables come with their items.
- [x] Core enemies: the Graves roster (robber, hound, penitent, sac, moth, bat, ghoul) with elites and affixes: the brain, elite stats and hostile
  zones (`client/tests/core_enemies.gd`), Bell-Tolled, Hungering, Shrouded and Vengeful (`client/tests/core_affixes.gd`). Rolling stays with the
  director, the affixes' look with the client.
- [x] Core thralls, corpses and statuses: statuses (`client/tests/core_status.gd`), thralls with their brain, legion and enemy targeting
  (`client/tests/core_thralls.gd`) and corpses with the toxic pool (`client/tests/core_corpses.gd`). Not in it: the Veilwalker's echo corpses,
  views (their own item), and the rites that call it.
- [ ] Client layer (B43), in this order:
  - [x] Code sync: today's scripts, scenes and data copied into `client/` by `tools/rebuild/sync-code.mjs`, the hygiene rules for copies and
    ports, and the project opening without errors with the per-creature systems left out (`client/tests/code_load.gd`).
  - [x] The game scene on the core: the area scene, the core and the crowd view, the hero, camera, input, and the director spawning through
    the core. A solo run in the Hollow Graves: `DmCoreHost` owns the core and the crowd and turns the event buffer into signals, `dev/dm_dev_entry.tscn` runs it offline,
    `client/tests/game_scene.gd` proves it (client/README.md "The game scene and the dev entry"). Off until their items: the rites (the hero cannot attack), bosses, party,
    gathering, the Chapterhouse, rewards, the HUD's panels, Grave Surges. Not in the core yet: what an enemy does to a hero besides damage (chill, root, pull) and a call that removes a living body (a hero
    who stays away 15 s used to see the area's enemies freed).
  - [x] The Gravecaller's rites ported to the core: the caster, its module base, the legends, the registry and 24 of the necromancer's 25 rites (Veil Step is a copy) are today's GDScript calling the core synchronously, so a kill
    resolves inside the cast; the enemy queries, the corpse field and the legion are adapters over the core (`core/dm_foe.gd`, `dm_core_corpses.gd`, `dm_core_legion.gd`). The hero fights in the dev entry (LMB, keys 1-4, RMB, R) and the crowd draws his
    thralls. `client/tests/rites.gd` casts every rite against today's formulas, the synchronous kills, the input and a fight (client/README.md "The Gravecaller's rites"). Not in it, each its own item: the Reaper's nine rites (with the Reaper),
    Easy auto combat, the kill-credit consumers (`DmSessionRewards`; the game scene emits `rite_hit`), and the
    loadout, rune and weapon sockets (the panels and the bag); the floating damage numbers came with the HUD. The rites' pictures have run headless only: their first look is on Helix's PC.
  - [x] Login to the test server and character select (today's front flow, pointed at the test API): the boot (`main/main.tscn`, the project's main scene) runs today's login, online gate and
    character select against the test server, then the game scene with the chosen character, its bag and its progression read from the server. The API base is the test API in one place
    (`net/dm_config.gd`), enforced by the transport and the game scene and pinned by `client/tests/front.gd` (client/README.md "The test server"). Proved on the mock backend and against the
    real test server's health and manifest; no real account was used (the team's first real login there is the check left for Helix). Off until their items: rewards and the kill ledger,
    saves, party, friends, chat, gathering, the Chapterhouse, the panels (no Log out, no Switch character), the benchmark, the crash report; the other disciplines' hero models.
  - [x] The Gravedigger King's brain as an external entity: the Hollow Graves' boss is `DmBossHost`, `DmBoss`, `DmBossNodeWorld`, `DmBossFx` and `DmBossView` ported to the core; the brains of `sim/bosses` are today's copies. His body registers as an
    external of kind 1 (position and `alive` written before every step), thralls pick him by the core's boss edge rule and their blows come back as `thrall_hit_external` into his brain, the host's queries and damage calls answer for his id so every rite
    reaches him (edge distance, his radius, after the enemies; the Scythe's arc and the needle's range count him), his statuses are his own GDScript set, his ghouls and elite robber are core bodies that leave with him through the new `DmCore.remove_enemy`,
    and his blows reach the hero and the thralls (`core.damage` on their ids). `client/tests/boss.gd` replays his six recorded scenarios against the copy of the brain and fights him: summon, phases, telegraphs, thralls, rites, wipe, defeat, a second summon
    (client/README.md "The bosses"). The other six bosses and the Covenant Seal's call are the "Bring everything over" item below.
- [x] Core obstacles: Ossuary Wall solid for the core's enemies (`DmCore.add_obstacle`, a box the core keeps enemies out of and their steering
  slides along; `client/tests/core_enemies.gd` obstacles, `client/tests/rites.gd`). A later rite or boss barrier uses the same call.
- [ ] The rebuild on the test channel: `publish-test-channel.sh <rev>` exports `client/` (`publish-godot-client.sh` with `PROJECT=client`,
  `prepare-rebuild.sh`: the combat core, the sheets, the crowd's bakes), proven in dry runs (2026-10-16). The crowd's bakes live under
  `client/assets/crowd/baked` and ship in the assets pack, counted by their inputs (baker, looks, models), so a code-only build is a 15 MB code
  pack and the 268 MB assets pack is reused. The first publish waits for the benchmark in the client.
- [ ] The new HUD and the Low to Ultra presets:
  - [ ] The HUD, same layout and look, under 150 draw calls: built, **not yet measured**. Today's HUD runs in the game scene from the core (today's `DmGameUi` on the ported `DmNextUiHost` since the panels, DECISIONS B46) (orbs, hotbar with cooldowns and the cast state, target frame
    with statuses, minimap, thrall pips, "no corpse" dimming, floating numbers with today's caps, XP and level, area line, banners, the King's plate and map dot, the death veil), every readout group a movable, scalable piece
    (client/README.md "The HUD on the core"). The budget is modelled at 63 draw calls as the game scene shows it and 81 with every piece on (`client/tests/hud.gd`; the model reproduces the 18 numbers a rendered run
    counted), but ticks only when `client/tools/hud_measure.gd` has measured it in the game scene: the three 55 s runs of this item went on lavapipe's start-up (~44 s before the first frame; "The HUD's budget"). Left: that
    run once, with a longer limit or on Helix's PC (draw calls, and the HUD's 0.5 ms there); the look on Helix's PC against today's; the panels' pieces (menu row, chat, Empower, party frames, belt) as their items
    land, each keeping the budget.
  - [x] The Low to Ultra presets on Forward+ (DECISIONS B45; client/README.md "Graphics presets", `client/tests/presets.gd`): today's four, with ambient occlusion on High and Ultra, the crowd's shadow policy and FSR 1 for Auto
    resolution; the game and the benchmark play at the player's preset. Each preset's cost on a real GPU comes from the benchmark (its report names the preset).
- [ ] 2-player co-op (the combat core's half: native/README.md "Co-op", `client/tests/core_coop.gd`; the game's half: client/README.md "Co-op on the core", `client/tests/coop.gd`):
  - [x] Core snapshots: `DmCore.snapshot` (20 Hz, the Full Party in about 1.2 KB), `take_reliable` and `baseline` on the host, a puppet core (`set_puppet`, `apply_snapshot`,
    `apply_reliable`) on the guest, versioned messages (B40), loss, reordering and late joins proven.
  - [x] Transport and wiring, proven on a real local lobby and relay: the snapshot unreliable at 20 Hz, cut by body ranges (`DmCore.snapshot_parts`, at most 1,300 B a packet, each part applied as it arrives), batches and baselines reliable and in order, a
    baseline asked for after a gap, the heroes' ids and vitals; the host calls `set_replication(true)` with the first guest and registers every player's hero as an external; the guest's game scene runs a puppet core (`DmCoreHost.puppet`), the crowd,
    effects and HUD from its events, no rewards or kill report (`kill_credited` is the host's, once); the hello carries the build and `DmCore.wire_version()` and refuses a mismatch in the player's words; a guest's casts and move intents go to the host, which
    resolves them on its core (Exhume raises a thrall the host simulates, owned by the guest's hero external). The Full Party for one guest: about 28 KB/s and 82 packets/s on the host's connection (2.7 % and 14 % of the relay's limits), the largest packet 1,231 B.
  - [x] The Gravedigger King, hero vitals and the rites' events reach the guest (GDScript beside the core, as today's code sends them); the King fights both heroes in the proof.
  - [x] The party flow on the test lobby and relay (`DmNextParty`: host, join by code or id, invite, ask to join, answer, leave; `DmConfig` pins the test lobby and the test relay's port).
  - [x] The test lobby and relay installed and running (2026-10-16, Helix's OK; `server/death-muffin/test-server/coop/README.md`): `death-muffin-lobby-test` on 5195 behind `/death-muffin/test-lobby/`, `death-muffin-relay-test` on udp 5196,
    in the drift report's service list.
  - [x] The player's way in: the Social window (today's window and its Party and Friends tabs, O, F and the HUD's Social button) (today's `DmUiSocial` in the panel host since the panels), friends' presence over the lobby,
    and main.gd's hand-over (join, leave, a refused join, a closed party: home with the reason); `client/tests/social.gd`.
  - [x] The party's seals: the party plays in the host's world, so a guest's seals, doors and open areas are the host's (told to a guest as it joins, silently, and to every guest when they change: the gate rises
    with its sound and the banner); its own account's seals never open or close a door there (client/README.md "Co-op on the core", `client/tests/coop.gd`).
  - [ ] Still to do beside the core: the six other bosses' two-player fights (they ride `DmBossHost`'s state and events like the King); a new baseline for each new area. (A guest's build
    from the server's record and its own account came with value on the server; party chat and ground drops between members with the panels.)
  - [ ] Phones join as guests only (B40): the same messages; measure the snapshot on the Mobile renderer's budget when the first phone build exists.
- [ ] The Full Party fight in the new client with the budget checks, and a seeded scenario comparison with today's game → Gate B.
  It runs in the Hollow Graves on both sides (72 Graves enemies, 32 thralls, the Gravedigger King): the test build has the Graves roster, and today's
  game runs the same fight with `--benchmark --bench-room=graves --bench-size=full_party` (or Benchmark -> Hollow Graves -> Full Party).
  - [x] The fight and its budget checks in the new client: `--benchmark` and the character select's Benchmark button, Easy auto combat on the core, the report with its budget section (client/README.md "The benchmark",
    `client/tests/benchmark.gd`); the VPS numbers are in "Before numbers" (3.0 times today's speed without value, 2.4 with it).
  - [ ] The HUD's share with the panels back inside 0.5 ms on the VPS: about 0.5 now, from 0.9 to 1.0 on main at d625161f (2026-10-17; the panels, then the counsel's tips on the core, had taken it from 0.3 to 0.6). Seventy on/off
    rounds in CPU time: 0.96 to 1.01 before, 0.42 to 0.57 now; the benchmark's own readout (eight rounds, give or take 0.3 to 0.85) 0.88 to 1.97 before and 0.15 to 0.67 now (median 0.51), too coarse to say which side of 0.5 a
    share of 0.5 is on. What it cost and what removed it (client/README.md "The HUD's budget", CPU): pulses and flashes redrawn every frame (the NEW glows, the hotbar's empowered edges and cast flashes: 0.15 ms) are layers drawn once and
    faded; a slot on cooldown changes its seconds and sweep only; the orbs' appended art is re-indexed once per place; the Kill Chain meter no longer applies the belt and the party with it; the panel host answers
    `panel_open()`, `area_safe()` and the Ascension guidance without scans or a progression; the belt counts the bag in one pass; the counsel's first-thrall check built a whole view-model each time it looked (0.06 ms a
    frame in this fight), its pump compares only the urgent tips with the card, its poll reads static facts once, its card's line is drawn once. Left: the refresh itself (the view-model and its apply, about 1.5 ms every 50 ms of
    wall time, so 0.12 ms a frame on the VPS and 0.3 to 0.5 on a PC at 60 to 100 fps: Helix's PC is where it counts) with the minimap's dots and the hotbar's fill in the core as the next step (about 0.25 ms of it), the orbs'
    ripple (0.06 ms), and about a third of the share that is in no script callback. Open until Helix's PC reads it, or the benchmark's HUD rounds are made to tell 0.45 from 0.55 (more rounds, or the slowest frames left out).
  - [x] The rest of the main thread back inside its 4 ms with value in (3.8 to 4.1 ms on the VPS, 2026-10-16): a timing of every per-frame callback in a Full Party frame found the
    effects' particle ring (today's `DmFxRing`, GDScript) at 1.15 ms a frame, the most after the core; its loop is the core's C++ now (`DmMotes`, float for float the same:
    `client/tests/fx_motes.gd`). A/B four runs each: 5.7 to 5.0 ms a frame, the rest of the main thread 3.7 to 3.1 ms. Next in line by the same timing: Easy auto combat's
    decisions (0.5 ms, the benchmark's driver) and the enemy effects (0.15).
  - [x] Helix's PC (RTX 4070 SUPER, Ryzen 9 5950X, 2560x1440, Ultra, V-Sync off, 2026-10-17): the Full Party fight in the Hollow Graves, today's game (20261016.035802, Compatibility) 77.3 fps (12.93 ms a frame,
    p95 18.1, p99 21.0, 1,091 draw calls) against the test build 20261017.012954 (Forward+) 242.5 fps (4.12 ms, p95 5.1, p99 6.7, worst 13.3, 581 draw calls): 3.1 times today's speed (3.5 at p95), so Gate B's
    2 times holds on a real PC as on the VPS. The HUD row: 126 draw calls (150) and 0.08 ms of the frame; no hitch through the warm-up and the fight. The test builds before da9cc529 drew no enemies or
    thralls (the crowd looked for its models by file name, which an export changes); their runs do not count.
  - [x] The draw calls (2026-10-17): the next test build (20261017.025239, 8913127) drew 725 where the one before drew 581 (Creatures 280 to 396, World 123 to 153, Shadows 227 to 301, HUD 126 to 121), when static batching was to cut
    them. Counted from data and checked in a rendered Forward+ run (client/README.md "The draw budget", `client/tests/draw_budget.gd`, `client/tools/draw_measure.gd`): the renderer draws a MultiMesh with no instance all the same, one draw
    call and one more for each moon cascade it casts into, and the crowd keeps a group for every model, level of detail and shadow setting of the roster, 202 of which the Graves' party left empty but 15; the 12 models of the other areas
    (29 levels) added 58 groups to the main pass and 29 casting groups to both cascades: Creatures +116 exactly, 58 of the Shadows row's +74. The crowd now shows a group only while it holds instances (`DmCrowd.set_group_nodes`, dmcore
    0.14): the crowd's 396 draw calls are 41 in the rendered run. The other +30 (16 of them in the Shadows row) was static batching, which cost draw calls in Forward+ and is taken out again (the Static batching item above). The Graves' Full
    Party should come to about 340 (725 less 355 less 30), under the 581; the next benchmark on Helix's PC confirms it, and `client/tests/draw_budget.gd` holds the crowd, the world and the whole inside budgets from now on.
  - [x] The physics frame (2026-10-17): the 6.5 ms was not what a frame costs. Godot's `TIME_PHYSICS_PROCESS` (and `TIME_PROCESS`, the 5.6) is the slowest single tick (frame) of each second, refreshed once a second, so it read above the 4.1 ms average
    frame; the average physics part is a few tenths of a millisecond a frame at 0.25 ticks a frame. The slow tick of each second was Easy auto combat's choice (`DmAutoCombat.select_action`, the web game's TypeScript line for line: a lambda calling a field reader for
    every pair of bodies, a merge sort with a lambda; 3 ms on the VPS, 7 when it ends in Corpse Explosion, once every eleven ticks), then a rite's cast with its effects (2 to 4 ms) and a big kill's event handlers. Not in it: the core's step, the physics and navigation
    servers (0.1 ms a tick, 0.3 at p99), the interpolation, the hero (a `Node3D`, no physics body). The report now prints the monitors as the two "Godot peak" rows, beside the averages, the slowest tick and a Frame line (`DmFrameSplit`; the F3 overlay's logic line too:
    client/README.md "The benchmark"). Cut: `DmAutoCombat` ported, the same choice and step (the live game's golden cases and seeded fights: `client/tests/auto_combat.gd`) at a quarter of the cost, and a hero that holds his ground reads the core's tables only when an
    action is due. VPS Full Party on dcd89c4d, `--fixed-fps 60`, four alternating runs each: frame 4.69 ms (4.37 to 5.38) to 4.03 (3.36 to 4.68), the slowest tick of each second 14.5 (13.3 to 16.5) to 7.0 (6.0 to 7.7), tick p99 13.5 to 6.4; the full report, three
    runs each: Godot's physics peak 15.7 to 9.1 (one run hit by a 128 ms stall of the shared VPS left out). Helix's PC shows it with the next test build.
  - [x] The seeded scenario comparison with today's game (`tools/rebuild/compare-scenarios.mjs`, native/README.md "Proof of same game", 2026-10-16): the Hollow Graves, a level-10 Gravecaller on Easy auto combat, 180 s of game time, twenty seeds on each side.
    Kills -2.3 % (tolerance 15), hero damage -3.0 % (15), thrall damage -6.5 % (20), median time to kill 0.0 % (20), thrall uptime -0.4 points (10), damage taken by the hero and his thralls -1.3 % (25): every metric inside its tolerance, and underneath it the kinds, the rites, the thralls lost
    and who hurt them agree. Seeds 1 to 5 (6 minutes) are too few for damage taken (-32.5 % against a noise band of 47 %); the verdict takes `--seeds=1-20` (23 minutes). No behaviour difference found. Not in it: bosses, rewards and loot.
  - [x] The comparison widened (2026-10-17, `--discipline=<index>` and `--area=<id>`, native/README.md "Proof of same game"): the Ossuary, the Mourner, the Rotweaver and the Reaper in the Hollow Graves (level 10) and the Gravecaller in the Bell Sanctum (13), the Cinder Pyre (30) and the
    Mourning Fen (45), 20 seeds each (40 for the Reaper and the Pyre): every metric inside its tolerance in all seven, the largest difference 9.7 %; the Pyre reads about 5 % below today's in kills and damage, inside the tolerances (see "For review").
  - [ ] What the client's fight lacks, each with its own item: the other rooms ("The benchmark's other rooms"). The panels, the other disciplines, rewards, loot drops and the kill ledger are in.

**Bring everything over checklist** (built ahead while Gate B waits, B34's rule: nothing reaches players before its gate; Claude's order, 2026-10-16: what a player meets first,
necromancers first; the order is easy to change). Each item is today's GDScript on the core the way the test build did it (copies where they run as they are, ports where
they touched a creature), with today's tests replayed, and ends as a tested commit:
- [x] The other three necromancer disciplines (2026-10-16): Ossuary, Mourner and Rotweaver play as real characters of their discipline: their hero models
  (`client/assets.list`), the signature on R, Exhume's kinds, cap and health, and the discipline's rules through the ported paths (the Ossuary's health, thralls and Bone Ward; the
  Mourner's essence and the heal from a corpse; the Rotweaver's health, wider Miasma that bursts corpses and Withered up to 8), each against the Gravecaller's number and today's
  formula (`client/tests/rites.gd` "the disciplines"); the Mourner's wraiths are spectral in the crowd. The plague bearer's pools stay as today's (they do nothing: an after-launch fix).
- [x] Value on the server (2026-10-16): rewards, loot drops, the kill ledger and saves from the core's kill events, against the test server (today's `DmSessionRewards` and the
  authority flows, B32); a guest's own account in co-op (B22).
  - [x] The host's side (2026-10-16, client/README.md "Value on the server"): today's rewards node on the game's `kill_credited` (the party session's numbered reports, XP and counts
    from what the server accepted, the drop tape, the gold pool, lifesteal on `DmCoreHost.struck`), the meta node, the milestones, the Chronicle and the progression with its saves,
    and the loot node (click to walk to a drop, tape drops claimed into the server's bag, worn gear feeding the build, the belt); the HUD's upgrades box, wave dial, belt, Kill Chain,
    Omen and save chip; the King's summon takes its soul shards. `client/tests/rewards.gd` replays today's rewards tests on the port, `client/tests/value.gd` plays it in the scene.
  - [x] A guest's own account (B22, 2026-10-16): the host makes it a rewards member that rolls its own drops, it joins the host's backend party session with its own token
    (DmNextJoiner: its progression, saves, drop tape and bag), the host reads its build from the server (`remote_builds`, its runes too), its XP and drops are sent on, its belt
    drinks from its own bag; `client/tests/coop.gd` "the guest's own account". Ground drops between members (they start from the Reliquary's Drop) came with the panels.
- [x] The panels on the core (DECISIONS B46, 2026-10-16): the panel host (`DmGameUi`, `DmNextUiHost`), the Reliquary (bag, gear, runes), the Grimoire and loadout, Settings (the presets get their window),
  chat and the menu row; the Social window moves into the host.
  - [x] `DmNextUiHost` ported (2026-10-16): the host contract on the core, the HUD's view-model and numbers from the core's events, the target by id, the bag and the drops the
    loot node's, the counsel null until tips, no Altar (B36); the Codex ported (spawns from the core).
  - [x] `DmGameUi` and `DmUiSocial` copied in; the game scene composes them as today (`_start_hud`, today's `DmAreaFlow` for the banners); the rebuild's own HUD host and Social host
    retired (`tools/hygiene/retired.json`), their tests moved onto today's UI (`client/tests/hud_shim.gd`).
  - [x] The Reliquary on the server's bag (equip, sell and sort in `client/tests/panels.gd`; learning and socketing a rune are today's panel code on the adapter, not yet in a rebuild
    test), the worn look and the runes reaching the caster on a change (`DmNextGame._start_hud`); ground drops between members (`DmNextParty.share_ground`, the loot node's claim;
    `client/tests/coop.gd`).
  - [x] The Grimoire's loadout on the hotbar; Settings applying presets and the rest live (the adapter's `apply_settings`); party chat and the finds the party reads (`DmNextParty.chat`,
    `announce`); the menu row whole.
  - [x] The HUD's budget with the panels: the draw-call model 75 as the game scene shows it and 86 with every piece on (150), the HUD and panels about 0.4 ms of a headless frame (0.5;
    `client/tests/hud.gd`), the benchmark's HUD rounds switch the panel host; `client/tests/panels.gd` (every panel, the Reliquary, the loadout, Settings, chat). The draw calls on a
    real GPU stay Helix's PC's (Gate B).
- [x] The Reaper (discipline 11) and its nine rites: her model and the worn gear models in `client/assets.list`, the soul bag on the HUD, her kit on the hotbar; `DmReaperRites` and Scythe Weave,
  Wraith Walk and Unleash Souls ported to the core (her other five rites are copies); a kill credited to her banks a soul. `client/tests/rites.gd` "the Reaper" replays today's Reaper checks on core
  enemies (client/README.md "The Gravecaller's rites"). Her look and feel in play are Helix's PC's.
- [ ] The other areas: the eleven static ones as scenes, moving between them, their enemies (DECISIONS B47).
  - [x] The eleven areas converted (`client/tools/build_area.gd`; their textures and props in `client/assets.list`); `client/tests/areas.gd` proves each against today's builder.
  - [x] Moving between areas: every area but the Depths loads, the hero starts and gets up in the Chapterhouse; the Chapterhouse node (ported) breaks seals on kills and
    opens their gates, runs waystone travel, the recall, the stations and the people; a guest's doors follow the host's seals. The core keeps its own copy of the
    navmesh (`NavGrid`): its step with 72 chasing enemies went from 1.76 to 0.10 ms with the Graves alone and from 11.75 to 0.11 ms with every area loaded (VPS, one
    run, 2026-10-16). `client/tests/world.gd`.
  - [x] The lighting bake of the eleven (Helix's helper, RTX 4070 SUPER, 0.8 min, 2026-10-17); the helper waits for the editor's first scene, its 3D toolbar
    and each lightmap, retries a bake and gives a failed scene a second pass (three runs found those snags).
  - [x] Their enemies in the core, kind by kind against today's (`client/tests/core_kinds.gd`): the Ossuary's golem and deacon (2026-10-16), the Drowned Nave's censer,
    acolyte, gargoyle, templar and wraith, the Sanctum's and Cloister's seraph, flagellant and plague doctor, and the Cinder Pyre's husk, priest, hound and slag brute and the
    Mourning Fen's hag, leech, wisp and sexton (2026-10-17), with their crowd models: every area's roster runs on the core (the bosses' adds come with the bosses).
  - [x] The benchmark's other rooms and classes (2026-10-17; client/README.md "The benchmark", `client/tests/benchmark.gd`): today's nine rooms (each loads its own area alone), the four necromancers and the Reaper, each set up as today's
    (the hero at the walkable point nearest the centre that a path joins to the doorway, the roster of the room on the core, the Bell Sanctum's health and damage for every enemy), so Gate C can compare every room; the Standard setup is today's Bell Sanctum again.
    A Full Party fight holds the room's boss awake the whole fight as today's does (the seven bosses; the Warren and the Coliseum have none), woken through the real summon. The suite keeps its files in a folder of its own and never sends a run through a real transport.
- [x] The six other bosses (a core zone for a boss, a call that sets a body's health, the Veilwalker's echoes), and the Covenant Seal's Empowered call (`DmBossMeta`, the boss key prompt).
  Progress (2026-10-17, client/README.md "The bosses"): all seven bosses wake in their areas (`served_areas`), their brains the copies of today's, each replayed against its recorded scenarios (44) and fought by hand against today's numbers
  (`client/tests/boss_abbess|congregation|prelate|saint|regent|mire.gd` on `boss_base.gd`, 130 to 160 checks each, with the summon at the altar, thralls, rites, wipe, defeat and rewards). The core got the `niche` kind (the Abbess's Skull Niche),
  `set_enemy_hp`, and zones for a boss (`add_zone`, `zones`: the Saint's rot, the Regent's coals), with their wire (`client/tests/core_boss.gd`); the corpses (`devoured`, `raised`), the pews and the Mire Mother's sunk state ride the core's existing
  calls. `DmBossMeta` and the HUD's boss-key prompt are in (`client/tests/boss_meta.gd`, on the mock backend). The Prelate's echoes are the world's vows, none in the rebuild (B36; native/README.md "Differences").
  Every add a boss calls is a core body now (the Cloister's, the Pyre's and the Fen's kinds are on the core): each boss suite checks its waves arrive on the rim in the boss's area, and the Saint's doctors feed her through the link as real bodies.
  Their two-player fights are the co-op item's ("Still to do beside the core").
- [x] The Depths and gathering (the Chapterhouse came with the areas, DECISIONS B47).
  - [x] The Depths (2026-10-17, client/README.md "The Depths"): the instanced descent on the core: floors generated on a worker thread, baked off the main thread and handed to the core (one floor's triangles, replaced per floor), the dead
    core bodies with their own aggro, the stair, quota, chest and rewards on the server as today, the HUD's readout, map and prompt, solo, death takes nothing; every band's kinds are on the core, so the rosters are today's.
    `client/tests/depths.gd`.
  - [x] Gathering and the Acre (2026-10-17; client/README.md "Gathering and the Acre", `client/tests/gathering.gd`): the nodes of every area hovered, clicked and worked through the server (the walk, the cycle, the batches, the finds and XP the server decides, spent and
    back, Auto, AFK and its report), the professions' levels and banners, the Acre ledger's panels, the Grave Laborers as pooled views (at most four, only in the Acre), the garden, the contracts and the Sexton's and the Next box's feeds; a guest holds the nodes and cannot gather, as today.
- [x] Tips, onboarding and sound on the core's events.
  - [x] The counsel on the core (2026-10-17, client/README.md "Tips and onboarding", `client/tests/counsel.gd`): `DmNextCounsel` ported, its fight, corpse, pack and legion facts asked of the core on the 400 ms poll (0.18 ms with 72 bodies
    and 30 corpses), the spawn, corpse, Sanctify and hurt facts the core host's events, each tip fired once on the facts of today's table; the first hour's `world_entered` (the welcome tip, the signature and Grimoire tips) was
    never raised in the game scene and is now. The build has no Altar (B36): the vows, altar_unlocks and boons tips are held back (native/README.md "Differences").
  - [x] Sound on the core's events (`client/README.md` "Sound", `client/tests/sound.gd`): the thralls' rise and death, the gate sound (an event, not a poll of every door), a scripted fight's cues against today's rules by name and count.
    The Depths play today's sounds (the stairs' gate, the chest, a refusal, the floor's level-up) from `DmDepths`.
- [ ] Gate C: every rule test matches today's, playtests OK, nothing slower than the test build.

**Look pass checklist** (phase 4, Gate D; the first item came early because the test build looked wrong):
- [x] Today's colours on Forward+ (2026-10-17, client/README.md "The look against today's game", `client/tools/look_probe.gd`; Helix's RTX 4070 SUPER shots of the Chapterhouse and the Graves were
  the report): Compatibility reads every vertex colour as sRGB and multiplies a material's colours in sRGB, Forward+ does both in linear light, which made the light pools 9 times too bright
  (the beige pools, the glare round the waystone), the effects' and gear motes' colours too white, and the tinted ground and walls darker and less red and green. Fixed: `vertex_color_is_srgb`
  on the pools, the gear motes and the Binbun particles, the Fx layer's and the world particles' and mist shaders convert their colour, the area converter lifts the floor, wall and gate-post
  tints (`DmCompatAlbedo`, checked by `client/tests/areas.gd`), and a brightness lift of 1.2 (`DmGraphicsPreset.LIFT`, checked by `client/tests/presets.gd`) puts the mean luminance of the Chapterhouse, the
  Graves and the Ossuary within 3 % of today's (measured on frames at lift 1.0 and raised in software; not re-rendered). The tinted-floor change needs no bake; the pools' fix is in the area scenes.
- [x] World dressing on the area scenes (2026-10-17, client/README.md "World dressing", `client/tests/dressing.gd`): today's `DmWorldDressing` (ground mist, each area's weather, the stained-glass windows and their light shafts, candle flames
  and brazier fire as sprites, the far silhouettes, the water's glint) is attached to the loaded areas by `DmNextWorld.build`; the converter no longer writes the flame spheres, the water planes or the puddle quads it replaces.
  Ported to cost less than today's: the brazier fire is a ring of emission records drawn from their age by its vertex shader (written once, never stepped), the mist steps 4 times a second instead of 15, the weather's mesh is built once
  an area, the area arrives by event. A frame costs the node 18 microseconds (today's mist and fire alone cost 58), six objects are six draw calls in the Graves' budget scene (`BUDGET_DRESSING` 8) in place of the eight the stand-ins cost
  (the Graves' world 95 draw calls with it, 97 before), and the benchmark's Full Party in the Graves reads +0.10 ms an average frame on a spread of a whole millisecond (six alternating pairs, 3.86 against 3.96 ms; `--bench-dressing=off`; client/README.md "The benchmark"). Looked at against today's frames with the probe: the
  candle flames sit on the wicks instead of a ball floating above each candle, the brazier fire, mist and weather are there. The brightness lift was measured again with it on: 1.30, 1.08 and 1.18 would match today's Chapterhouse, Graves and
  Ossuary, mean 1.19, so 1.2 stays until the bake. Water ripples and the Prelate's candle groups are not wired, as in today's game ("For review").
- [ ] Baked lighting, one bake for these (Helix's helper): the bake reads the area's ambient (an sRGB colour) as linear light, so baked shadows are filled about three times brighter than today's
  real-time ambient (`environment_custom_color`: `srgb_to_linear()` in `build_area._lightmap`); the big floors' lightmap is 0.43 m a texel, which flattens a candle's pool to a quarter of the
  real-time light at 0.3 m (`gi_lightmap_texel_scale` on the ground quads); the Acre's and the Alchemist Wing's live ambient and moon are brighter than the other areas' (`DmGameRewards`) and are not in
  their bakes. Measure the lift again after.
- [x] Glow and the void (2026-10-17, client/README.md "The look against today's game"): the glow is today's width (`DmWfxBloom`: the two finest mips at 0.8 of the web's strength; five mips glowed to 66 px past an edge, today's is gone by 30, and a candle's
  sphere or a Binbun effect became the soft white blob Helix saw: the same Chapterhouse frame has none now); the dark earth beyond the walls is one quad (`DmWorldBuilder.build_outside`, today's 196 tiles) and the background colour
  past it comes out of the tonemapper as (7, 6, 10) (`DmCompatAlbedo.void_color`, set whenever the exposure changes); the Binbun scenes' own shaders read their particle's colour converted from sRGB through a patched copy (`DmFxBinbun`).
- [ ] Low and Medium: today's draw blended effects in sRGB space when bloom is off (half-transparent white over black: 131; with bloom, 205), Forward+ blends in linear light on every preset;
  the lift of Low (1.15) and Medium (1.2) is the High and Ultra number, not measured; the Depths' walls keep Forward+'s darker tint (its floor is lifted in `DmWorldBuilder._floor_mat`).
- [ ] Every area's look signed off by Helix on his PC (Acre, Alchemist Wing, Warren, Nave, Coliseum, Sanctum, Cloister, Pyre and Fen were not measured: one frame each is in the probe's plan).

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
- **For review** (Helix, 2026-10-16: issues, concerns and ideas outside the rebuild are listed here and reviewed later for other roadmap sections):
  - Colours in the chat window (2026-10-13).
  - Today's game: Easy auto combat parks the hero in pockets of tombstones (it steers straight at the nearest enemy, with no path round the graves; found by the
    seeded comparison, native/README.md "Proof of same game").
  - The rebuild: the Cinder Pyre scenario reads about 5 % below today's in kills and damage (-5.9 %, -4.5 %, -4.9 % at forty seeds, inside the tolerances); not the core's navmesh copy, the navmesh, or the first wave's
    kinds, levels, elites and health; cause not found (native/README.md "Proof of same game").
  - The rebuild: one headless client run in about 300 aborted before it ended (SIGABRT, "The caller thread can't call the function `propagate_notification()` on this node", `/root`; the Ossuary scenario's seed 13, clean on
    the rerun); `compare-scenarios.mjs` keeps such a run's output and makes it once more.
  - Today's game: quitting while models still load in the background can abort on a PC with few cores (the GitHub runner's 4: the CI's perfctl abort, 2026-10-16).
  - Today's game and the rebuild: a party guest cannot use a waystone or the recall (T): `DmChapterhouse.teleport_to` moves the host's own body only, so the stone's jump and the recall do nothing for a guest
    (its waystone list also reads its own account's open areas, not the host's world). It needs a guest request the host answers by moving the guest's body (2026-10-17).
  - Today's game: a thrall never wears its Legion kit: DmEntityViews asks its host for `legion_kit_for` (the kit's armour tint on a thrall's chest and hands, the kit weapon's tier colour on its sword, bow or staff) and no host
    has it, so `kit` is always null; the rebuild draws thralls the same until this is decided (2026-10-17).
  - Today's game: a thrall never wears its discipline's legion look either (the Ossuary's sentinel, the Gravecaller's legionnaire, the Rotweaver's plague thrall, their tints and glows):
    `DmEntityViews._legion_of` asks its host for `discipline_id_for`, which no host has, so every thrall is the default bone skeleton with the teal glow. The rebuild draws the same
    (`DmCoreHost` gives the crowd no legion; `CrowdView.set_owner_legion` and crowd_looks.json `legions` are kept for when the team wants them) (2026-10-17).
  - The rebuild: `client/tests/game_scene.gd`'s node checks pass about every other run under load (2026-10-17): the Covenant counsel's tip card (a 16-node `DmTipCard`, shown at the first Barrow Ghoul and dismissed on a wall-clock
    timer) is in the scene tree for part of the run, so the nodes outside the effects vary by 19 against the 15 allowed, or `n` differs from `n0` by 14 in the 70-bodies check.
  - The rebuild: a co-op guest's baseline clears the crowd (`DmCrowd.clear` forgets `owner_legion` and `owner_ally`) and `DmNextNet.apply_heroes` adopts a hero only when its id changed, so after a baseline the guest's
    thralls may fall back to the plain look and the strong rim until the heroes are adopted again; read from the code, not reproduced (2026-10-17).
  - Today's game and the rebuild: the world dressing's water ripples and the Prelate's candle groups never happen: `DmEventFx.add_ripple` and `set_candle_group` call `game.dressing`, which no game scene has (`DmEnemyFxHost.dressing` is never
    set), so the Nave's and the Fen's water has no ripples under the hero, the Mire Mother's rings or the Wisp's pulse, and the Sanctum's candles do not gutter as the Prelate's phases pass; the rebuild matches (2026-10-17).
  - Today's game: a party guest leaving with kills not yet reported makes the host send to a peer that is gone (an engine error in the log, nothing lost; the rebuild
    skips the send).
  - Today's game: the Plague Doctor's flask leaves a 5 s toxic pool that hurts but draws nothing on the ground (DmEnemyFx draws only dust and ember zones);
    the rebuild keeps it so until this is decided (2026-10-17).
  - Today's game: the Shrouded body's opacity has two writers that disagree: `DmEntityViews._tick_affix` writes it every frame toward 0.38 unless `e.slowT > 0`, a field nothing ever sets, and `DmStatusSet._visual_state`
    sets 0.38 and 1.0 at once as the `shrouded` status comes and goes (a Miasma lifts it); which one a player sees depends on the order they run. The rebuild draws the status's state, eased at `_tick_affix`'s rate (2026-10-17).
  - Today's game: a sinking thrall's hand props (sword, shield, bow, staff) are bone-attached nodes the body's opacity does not reach, so they float solid while the body fades; the rebuild's props fade with it (2026-10-17).
  - Today's game: the Reaper's soul wisp bursts on arrival through a lambda that reads the meta node (`DmNextMeta._soul_fx`), so a wisp still flying when the game is left logs a script error
    (the benchmark's Reaper run found it; the rebuild's port reads a local, 2026-10-17).
  - Today's game's benchmark: the fight's settings carry no V-Sync, so the game scene turns it back on during the measurement; a run faster than the monitor reads its
    refresh rate (the server flags it). The rebuild keeps it off (2026-10-17).
  - Today's game: cycles gathered in the last 8 s before the player leaves or closes the window are never sent (`flush_all` does not flush the gather loop). The rebuild keeps it (2026-10-17).
  - The rebuild's crowd meshes repeat the vertex arrays in every level of detail's `mesh_lod<N>.res` (23 MB of the 234); one array with Godot's own mesh LODs would share it (2026-10-17).
  - The benchmark (both games): a level-up during the fight refreshes the god-mode hero's stats from the throwaway character's real level, so the held fight changes
    as that character levels; the benchmark could hold its XP.
  - Today's game and the rebuild: `Vfx` (`DmFxRuntime`) leaves some pooled MultiMeshes visible with no instance (4 of its 20 in a Full Party fight, 2026-10-17); each costs a draw call, as an empty crowd group did (client/README.md "The draw budget").
  - The draw model counts the rendered Graves (world and crowd) a few draws under the engine, but Helix's World row is about 40 over the same stage (153 and 123 there against 107 and 84 rendered at the room's middle): the real fight draws something the stage
    does not (the hero's place, the effects, the boss); a rendered run of the real Full Party needs ~3 minutes of boot on the VPS (2026-10-17).
  - The rebuild's area scenes: props always cast the moon's shadow; today's runtime stops it beyond 32 m of the hero (`SHADOW_RANGE`). Decals and puddles are unique quads the renderer
    cannot draw instanced (one draw call each: the Graves 23), and so are the flame spheres (18).
  - The rebuild's crowd: a casting body outside the camera's view is kept for its shadow and drawn in the main pass too (one MultiMesh does both); a shadows-only MultiMesh per model and level would
    send it to the shadow map alone. Worth doing if Helix's PC shows the kept casters cost something (2026-10-17).
  - The benchmark's held Full Party keeps the whole pack inside the camera's view and within 32 m of it, so the crowd's culling and animation bands barely engage in it (1 of 148 bodies culled);
    their saving shows in play (F3) or in a looser fight (2026-10-17).
  - Today's game: Easy auto combat's choice costs 3 ms (7 ms when it ends in Corpse Explosion) inside one physics tick with 60 enemies and 30 corpses in reach: `godot/game/dm_auto_combat.gd` is the file the rebuild ported to a quarter of that (client/code.list); the live game keeps it until launch day (2026-10-17).
  - The rebuild's slowest ticks after Easy auto combat's choice (2026-10-17, VPS): a rite's cast, 2 to 4 ms in the tick it is cast, 1.2 to 1.9 ms of it its effects (`DmRiteCaster._play_event`, the `Vfx` nodes), and the event handlers of a big kill (`DmCoreHost._dispatch`: rewards, loot, the counsel), 2 to 9 ms.
  - `DmAutoCombat._primary_target` (Bone Fan's pick) tests every pair of targets with V8's hypot: up to 4,000 calls, about 6 ms on the VPS in the tick it runs; the Gravecaller's default loadout does not use it (2026-10-17).
- **Found during the rebuild, today's game ignores them** (Helix 2026-10-16: fixed after launch day, in the rebuild only; until then both keep today's behaviour; the core already emits each one):
  toxic corpse pools always hit as at level 1 (nothing sets the area level), a fallen plague bearer's pool never appears, and the
  Mourning Bell wraith's ally heal never happens (both are signals nobody listens to). Statuses never change the blows a boss takes:
  `DmBoss.take_damage` does not apply the status set's damage-taken multiplier, and the brain's own Fracture is never fed (a Marrow Spear's Fracture or a Sanctify on the King does nothing); kept, and so is the port.
- **Phones:** on the Mobile renderer, following the phone rules kept since the rebuild (B40).
- **The asset and effects rebuild** (Helix, 2026-10-16: after the core is rebuilt, with its own roadmap and pipelines). Until then the rebuild changes effects
  and assets only where speed needs it. Notes for it: the crowd's download size (234 MB baked: positions 140, normals 70, level-of-detail meshes 23; "Test build checklist").

## Later

- **The other five disciplines** (Grave Warden, Bell Monk, Carrion Witch, Hollow Knight, Veilwalker) on the Godot kit and rite
  system; their data is in `godot/data/content/`. Shrouded suspension, monk beat meter and Bulwark come with them.
- **New content after polish:** new zones (the Hollow Court), more bosses with summoning keys, new enemy archetypes, replay and
  endgame depth (weekly Omen variants, deeper Depths rewards).
- **In-game leaderboard panel** (KNOWN-GAPS: UI).
- Not planned: VPS-hosted sessions (headless Godot) and host migration.
