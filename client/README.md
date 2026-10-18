# The rebuilt client

The Death Muffin client, rebuilt (ROADMAP "Now: the rebuild", DECISIONS B34-B42): its own Godot 4.7.2 project, next to the old game in
`godot/`, which it never changes. Since launch day (2026-10-18, B49) this project is the game: `publish-godot-client.sh` publishes it to everyone; the
launcher's Test build channel keeps its last test build.

- Renderer: Forward+ (`project.godot`), Compatibility only as the automatic fallback, the Mobile renderer for phones (B35). Textures also
  import in phone formats (B40).
- Its own user:// folder (`config/name` "Death Muffin (rebuild)"), so it never shares saved logins or settings with the live game.
- It plays on the **live server** since launch day and never reaches the test server ([The API rule](#the-api-rule-decisions-b38-b49)).
- The combat core is a C++ GDExtension built from [native/](../native/README.md) into `bin/` (built files are not committed;
  `bin/dmcore.gdextension` is).
- Crowds are drawn from baked vertex-animation textures, one MultiMesh per creature model and level of detail, driven by the combat core through `CrowdView`:
  [crowd/README.md](crowd/README.md).

## Set up and test

```
bash client/setup.sh                                                       # builds the core for Linux, imports, runs the smoke test
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/core_smoke.gd   # the core loads and answers
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/core_kinds.gd   # the kinds the other areas add, against today's rules: the Ossuary's golem (slam) and deacon (keep-away, curse, raise, Sanctify, silence), the Drowned Nave's censer (incense), acolyte (curse, Unbind), gargoyle (dive), templar (shield) and wraith (scream), the Sanctum's and Cloister's seraph (curse, ward), plague doctor (flask, pool) and flagellant (frenzy), and the Cinder Pyre's and the Mourning Fen's husk (embers), priest (coal), hound, slag brute (slam pool), hag (hex), leech, wisp (pulse, lure) and sexton (chain), their co-op wire, the rosters, seeded replays
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/crowd_bake.gd    # the crowd baker and shader (bakes into a scratch folder)
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/code_load.gd      # every copied script, scene and resource loads; no copy names a per-creature class
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/crowd_view.gd    # the crowd's views against today's view code, its cost (culling against the engine's frustum, the animation bands, the shadow counters), the alpha path (sinking and shrouded bodies in the fade groups), and a Full Party (bakes into a scratch folder)
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/draw_budget.gd    # the 3D draw calls of the Graves' Full Party counted from data (the crowd shows only the groups that hold instances, the world and the whole inside their budgets, and 24 bodies sinking with three shrouded elites cost the crowd two draw calls more; "The draw budget"; bakes into a scratch folder, about a minute)
# RENDERED, not headless (software GL, one run at a time; the header of tests/crowd_look_smoke.gd has the command for Compatibility and for Forward+): the crowd's thralls next to today's skinned ones in the Graves' lighting, with the mean colour of each
# RENDERED (the header of tests/crowd_fade_smoke.gd has the command): the crowd's alpha path, a solid robber beside one under the Shrouded ward and one sinking away, measured by pixels (client/crowd/README.md "The alpha path")
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/game_scene.gd     # the game scene on the core: 60 s of an offline run in the Graves (bakes into a scratch folder; add --fixed-fps 60 before --path to run it faster than real time)
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/rites.gd          # the Gravecaller's rites on the core: all 25 necromancer rites against today's rules, a fight (bakes into a scratch folder; 90 s of game time, --fixed-fps 60 makes it faster)
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/boss.gd           # the Gravedigger King on the core: his brain replayed against today's scenarios, his fight, the thralls, the rites, his defeat and a new summon (bakes into a scratch folder; add --fixed-fps 60 before --path to run it faster than real time)
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/core_boss.gd      # what the bosses call on the core: the Skull Niche (the rise, no blow, no flinch, never moved, no corpse), a body's health, a boss's zones (toxic rot, ember), their wire
/home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client --script res://tests/boss_abbess.gd       # the six other bosses, one suite each (boss_abbess|congregation|prelate|saint|regent|mire.gd on boss_base.gd): the boss's recorded scenarios replayed, the summon at its altar, its fight by hand against today's numbers, thralls, rites, wipe, defeat and rewards, the real clock (bakes into a scratch folder; about 30 s each)
/home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client --script res://tests/boss_meta.gd        # the Covenant Seal's Empowered call and the boss key prompt on the mock backend, the first-kill trophies, a bound summon
/home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client --script res://tests/front.gd   # boot, login, character select and the game scene with the chosen character on the mock; the API rule; the real test server's health (bakes into a scratch folder)
/home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client --script res://tests/hud.gd     # the HUD on the core (today's DmGameUi on DmNextUiHost, driven through tests/hud_shim.gd): target frame, minimap dots, hotbar and cooldowns, thrall pips, floating number caps, pools, pieces, z layers, the draw-call model (bakes into a scratch folder)
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/auto_combat.gd     # Easy auto combat's decisions against the live game's file: its golden cases (read from godot/tests/game/fixtures), seeded Full Party fights for the necromancer's rites and the Reaper's, the movement; INFO: a decision's time on both sides
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/benchmark.gd       # the benchmark on the core: the Full Party fight held as the setup says, every room and every class, Easy auto combat, the report and its budget section, real launches, nothing sent anywhere (its own folder for the models and every file; about 4 minutes)
node tools/rebuild/compare-scenarios.mjs                                                       # the seeded scenario comparison with today's game: ten headless runs, one at a time, and a table against stated tolerances (about 6 minutes; "The seeded scenario")
/home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client --script res://tests/coop.gd    # 2-player co-op: a host and a guest in one process over a real local lobby and relay (needs `cd server/death-muffin/lobby && npm ci`; bakes into a scratch folder; about a minute)
/home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client --script res://tests/coop_bosses.gd  # the six other bosses fight a party of two, summoned by the guest, in the whole world over the same lobby and relay: state, telegraphs, events, zones, adds, blows and effects on the guest's hero (and its hurt on its window), the phases, the defeat by the guest and both accounts paid, a wipe (about 70 s; "Co-op on the core")
/home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client --script res://tests/social.gd  # the Social window: open and close, host from the Party tab, a boot scene that joins from the list and comes home (needs the lobby's modules too; about 40 s)
/home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client --script res://tests/dressing.gd # the world dressing on the area scenes: its pieces in the loaded areas, the stand-ins gone from the scenes, the area by event, the brazier fire's closed form against the web's step, the mist's rate, the earth beyond the walls, the Binbun shaders' colour (about 15 s; "World dressing")
/home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client --script res://tests/presets.gd # the graphics presets on a running game: lights, environment, viewport, crowd shadows, the governor, the lift of each area and its blend (bakes into a scratch folder)
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/rewards.gd                # the rewards node on the core: today's tests/rewards replayed (sessions, batches, lost replies, refusals, the end, per-member loot), on the mock
/home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client --script res://tests/value.gd   # value on the server in the game scene: kills, accepted XP, the purse, a claimed drop, brews and lifesteal, the meta, the belt, saving ("Value on the server")
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/fx_motes.gd               # the effects' particle ring in C++ (DmMotes: the bursts' random starts and the loop) against today's ring, float for float; INFO: its update time on both sides
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/fx_decals.gd              # the ground decals in C++ (DmDecals) against today's (godot/fx/dm_fx_prims.gd compiled at run time): every drawn float, the counts and the handles over two seeded runs and the cap of 160; INFO: its update time on both sides
/home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client --script res://tests/panels.gd # today's panels on the core: every panel opens, the Reliquary (equip, sell, sort) on the server's bag, the loadout, Settings live, chat
/home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client --script res://tests/gathering.gd # gathering and the Acre: all 68 nodes hovered and clicked, a node worked through the server (cycles, batches, finds, XP, spent and back), the stops, AFK and its report, the Grave Laborers, a collection, the garden, a contract, the Sexton ("Gathering and the Acre"; about 25 s)
/home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client --script res://tests/world.gd  # the whole world: every area, seals and gates, into the Warren, waystones, the recall, the core's navmesh against the server's, the Ossuary's deacon and golem, the Nave's five, the Sanctum's, Coliseum's and Cloister's rosters (the seraph's ward, the plague doctor's flask, a frenzied flagellant) and the Pyre's and the Fen's eight in the game scene, the waves following the hero from area to area
/home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client --script res://tests/counsel.gd # the counsel and the first hour on the core: the fight facts read two ways, every fact the creatures give the counsel once, the tips each makes once, the state-driven tips, the welcome and the Next-step box, the Prior, Show tips again ("Tips and onboarding"; about 30 s with --fixed-fps 60, 2 minutes without)
/home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client --script res://tests/sound.gd   # sound on the core's events: a scripted fight's cues against today's rules, by name and count, thralls, the hero's footsteps, the area beds and scores, the gate, the boss score ("Sound"; about 30 s)
/home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client --script res://tests/depths.gd # the Catacomb Depths on the core: the rules, the Warren's stair, floors baked at run time and the core's copy of each, the dead on a floor, the quota, the chest, leaving, death, 14 floors (bakes into a scratch folder; about 40 s)
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/threads.gd           # the work off the main thread ("Threads"): the list of what starts a thread, the audio bus layout edited only under the mixer's lock, the Depths' floor generator and the Atlas' verdicts on a worker against the main thread's, the guard (about 6 s)
bash client/tools/coop_local.sh                                                                # a local lobby and relay for a trial with two game windows (prints the commands; "Co-op on the core")
bash client/tools/bake_crowd.sh                                                                # bakes the crowd models (the Graves roster, the Ossuary's deacon and golem and the Abbess's niche, the Nave's five, the Cloister's three, the Pyre's and the Fen's eight, the thralls) into client/assets/crowd/baked (not committed)
```

Run `bash client/setup.sh` once in every new checkout or worktree (it lists the extension before the first import; see the script).

A suite that asks for paths in a region enabled moments before (a seal broken, a floor baked) sets `DM_SYNC_NAV` first (`OS.set_environment("DM_SYNC_NAV", "1")` in `_initialize`, as `tests/world.gd` does):
the navigation server merges a new region on a worker thread of its own and a game under `--fixed-fps` outruns it on a loaded machine, so a path asked before the merge ends on the nearest ground
that is merged and a body walks away from where it was sent. The variable makes the merges synchronous, in step with game time (never set in the game).

## Code from today's game

The client runs today's scripts, scenes and data (DECISIONS B43) at the same paths as in `godot/`, so `res://` paths, class names and script
uids keep working:
- **Copies:** `client/code.list` names what is copied (globs relative to `godot/`, `!glob` leaves files out; a script's `.uid` goes with it).
  `node tools/rebuild/sync-code.mjs` brings the copies up to date (adds, replaces, deletes copies whose original is gone); `--check` changes
  nothing and fails when anything is out of date. A copy is never edited in `client/`: the hygiene check fails when one is.
- **Ports:** a file that has to change to run on the core (a rite, the director, a boss, a view) is ported: `node tools/rebuild/sync-code.mjs
  --port <path>` marks it and records the version of its original. From then on the sync tool leaves it alone and lists it under PORTS BEHIND
  when the live original changes (a live bug fix), with the `git diff` that shows the change; carry it over, then `--port` the file again.
- `client/code.lock.json` (written by the tool, committed) records every copy and every port. Only files it lists as copies are ever replaced or
  deleted, so the client's own files (`core/`, `crowd/`, `areas/`, `tests/`, ...) are never touched; a copy that would land on one is refused.
- **Proof:** `tests/code_load.gd` loads every copy through `ResourceLoader` (scripts must be able to instantiate, scenes and resources load with
  every dependency present, JSON parses, a class name must not collide with another script) and fails when a copy names a per-creature class or
  path in code (comments do not count). It prints the counts. A new file in a copied folder of `godot/` is copied by the next sync; if the test
  then fails on it, it is a new seam: add it to the right section of `code.list`.
- **`project.godot` is the client's own, not a copy.** From `godot/project.godot` it takes by hand what the copies need: the autoloads of copied
  scripts (`Packs`, `AudioDirector`, `Vfx`; not `Qa`, which is left out with its seam), the display and theme settings the UI layout assumes
  (1600x900 viewport, `canvas_items` stretch, `dm_theme.tres`) and the 60 Hz physics settings (3 steps per frame, physics interpolation). The
  renderer, name, features, main scene (the boot, `main/main.tscn`), layer names and import defaults stay the client's. Input actions are registered at run time by the copied code, and
  the only `ProjectSettings` read, `application/config/version`, has a default.

### What is left out

`client/code.list` says why, section by section; its comments are the list:
- **Per-creature systems** (`enemies/`, `sim/sim_enemy|thrall|corpse|zone.gd`, `next/thralls|corpses|affixes`, `game/dm_entity_views.gd`): the combat core and the crowd view
  replace them (native/README.md "Design").
- **Seams** (55 files at the start): a file outside those systems that names one of their classes or scenes: the rites, the bosses, the HUD's enemy reads, auto combat input, the benchmark
  fight. Each line names what it uses. They are ported to the core in the later steps of the ROADMAP's client layer, and `--port` then moves them from the list into `code.lock.json`.
  Ported already: the game scene, the director, the hero body and look, the input, the enemy fx, the avatar and the event fx; the Gravecaller's rites (the caster, the module base, the legends, the
  registry, 24 of the necromancer's 25 rites, the rite fx, the combat input; "The Gravecaller's rites"); the boss host, body, world, fx and view ("The bosses"); Easy auto combat, the benchmark
  with its screen, setup window and warm-up, and the boot's `--benchmark` and Benchmark button ("The benchmark"); the co-op pieces (`next/next_net.gd`, `next/party/dm_next_party.gd` and the session's hello;
  "Co-op on the core"); value on the server (the rewards node, the meta node, the progress node, the wave milestones and the joiner; "Value on the server"); the HUD's adapter and
  view-model ("The HUD on the core"); the counsel's host side and the audio hooks ("Tips and onboarding", "Sound"); the Reaper's helper and three of her rites ("The Gravecaller's rites"); the Acre's glue ("Gathering and the Acre"); and the Depths (the controller, the floor's ground and the run: "The Depths").
- **Left out with a seam**: a file that cannot load without a seam, grouped under the seam it follows: now only the QA boot (with the QA driver).
  Freed by the game scene's port and copied again: `next/status` (`DmStatusSet`, for the status sets of heroes and bosses only),
  the chronicle, the event fx's telegraph and boss halves, the area flow and gathering. Freed by the rites' ports: the hotbar (`dm_rite_hotbar.gd`), Veil Step and the belt.
  Freed by the boss ports: `next/bosses/dm_boss_meta.gd` (the Covenant Seal altar choice: a copy, made by the game scene's value step). Freed by the panels
  and the Reaper: `DmGameUi` with every panel and the Social window, the Codex, the registry and the Reaper's other rites.
- **Ported for the test server** (not seams): the boot `main/main.gd` and `main/main.tscn` (freed from the left-out list by the front flow's port), `net/dm_config.gd` and
  `net/dm_http_transport.gd` (below).

## The game scene and the dev entry

`next/next_game.tscn` (`DmNextGame`, a port of today's) is the game on the combat core: **the whole world** (every area but the Depths; the hero starts and gets up in the Chapterhouse,
as today), with the character the front flow chose on the test server (below) or, from `dev/dm_dev_entry.tscn`, a dev character on the local mock backend in the Hollow Graves alone (a
quick fight), the way today's `--dev-offline --class=2` does. **The dev entry reaches no server**: the backend is
`DmOffline.make_mock` (accounts in this project's own `user://dm_dev_offline_db.json`) and has no base url. `DmNextGame.start` refuses any api whose base url is not the test server's.

```
bash client/setup.sh                                   # once per checkout: builds the core, imports
bash client/tools/bake_crowd.sh                        # once: bakes the robber, the hound and the thralls (without them nothing is drawn; the other defs borrow these)
/home/ubuntu/tools/godot/godot --path client            # the boot: login and character select on the TEST server, then the game (below)
/home/ubuntu/tools/godot/godot --path client -- --dev-offline --class=1             # the same boot with the local mock backend and no network at all: straight into the whole world as `tester` (--seed=N --no-waves --baked=<dir> too)
/home/ubuntu/tools/godot/godot --path client res://dev/dm_dev_entry.tscn           # the dev entry: the Graves alone, the Gravecaller at level 10, the HUD, waves. He fights with the rites (controls below)
/home/ubuntu/tools/godot/godot --path client res://dev/dm_dev_entry.tscn -- --class=1 --seed=7 --crowd=70      # options after `--`: --class=N --level=N (default 10) --seed=N --no-waves --crowd=N (a first wave of N bodies 6 to 12 m around the hero) --boss (the hero starts at the King's grave and wakes him) --baked=<dir> --shot=<png> [--shot-after=<game s>] (rendered runs only)
```

**Controls of the dev entry** (today's input and hotbar code): **LMB** on the ground walks there, on an enemy walks into range and casts the primary (Bone Needle; hold to repeat, Shift+LMB casts in place);
**1-4** are the kit's default loadout (Marrow Spear, Exhume, Miasma, Black Litany; hold a key to repeat), **RMB** is Corpse Explosion, **R** the signature from level 10 (Command: Rend), **WASD** walks, the wheel
zooms. The Grimoire puts the other rites on the keys; tests cast through `DmNextInput.cast_at(slot, aim, enemy_id, true)` or the caster's `request_cast(rite, aim)`. `--level=N` sets the level the mock
character is made at (R needs 10, Bone Mantle 12, Bone Storm 14; all rites unlock by 14). `--class=11` is the Reaper: **LMB** Scythe Sweep, **1-4** Scythe Throw, Reap, Wraith Walk and Soul Burst,
**RMB** Harvest Spin, **R** Unleash Souls; every rite but the swings pays souls from her bag (10 to start, 30 at most), and every kill credited to her banks one.

**`DmCoreHost`** (`core/dm_core_host.gd`, the scene's `Core` node) is the one owner of the `DmCore` and the `CrowdView`. It loads the data (`DmCoreData.load_all`: this project's `data/`; the
three constants files of the creature systems are not here, so the core keeps its compiled-in defaults, which `core_thralls` checks against the live files), seeds the core and
gives it the area's navigation map and bounds, and registers each hero body as an external (position and alive flag written before every step). Its tick runs at
`process_physics_priority` 100: after the session (which moves the hero bodies) and the director (which spawns), before the crowd's own 1000. A tick is `core.step`, `CrowdView.sync()`, then
`core.take_events()` once, decoded in order into one typed signal per event kind (`enemy_spawned`, `enemy_state`, `enemy_damaged`, `enemy_died`, `enemy_attack`, `telegraph`,
`target_hit`, `target_effect`, `zone*`, `corpse_*`, `thrall_*`, `status_*`, `affix_moment`; `core/dm_core_events.gd` has the numbers). Systems connect to the signals; nothing polls per creature, and
**no node and no script exists per creature**: an enemy is an id (an int) everywhere, and `enemies_in_radius`, `enemy_position`, `damage` and `apply_status` are thin queries on the core.
`CrowdView._process` draws the rendered frames with `Engine.get_physics_interpolation_fraction()`.

The pieces around it (all ports, `code.list` "Ported"): the **world** (`next/next_world.gd`) loads the area scenes (`areas/<id>.tscn`; `opts.areas` takes a shorter list, the tests' Graves) with
the same small API as today's world object (`area_at`, the navigation helpers, `spawn_point`, the seals and gates: `set_unlocked`, `set_door_open`, `gates`, `nav_regions`), keeps a
`DmWorldBuilder` for the area's lights only, and gives the core its copy of the navmesh (`bind_core`; DECISIONS B47); the **Chapterhouse** (`next/chapterhouse/dm_chapterhouse.gd`) breaks a seal
when the kills in the area before it reach its count (the banner, the gate rises, the navmesh joins; a party's guest sees the host's seals, "Co-op on the core"), runs waystone travel and the recall home (T),
opens the stations' panels and animates the people; the **director** (`next/spawn/dm_wave_director.gd`) spawns through `core_host.spawn_enemy` with the affix
roll of today (`core/dm_affix_roll.gd`), counting from the core; the **hero** (`next/hero/dm_hero_body.gd`) takes the enemies' blows from `EV_TARGET_HIT` with the enemy's id as the source, and their chills, roots and drags (the Hag's, the Wisp's, the Sexton's chain) from `EV_TARGET_EFFECT`;
**input** (`next/next_input.gd`) picks the hovered enemy by asking the core for the bodies near the cursor's ray; **enemy effects** (`next/enemy_fx/dm_enemy_fx.gd`) play the telegraphs, strikes (timed from the
wind-up), deaths, voices, dust clouds and burning ground and the affixes' bell, meal and burst from the host's signals, through the same router and the `Vfx` and `AudioDirector` autoloads.

Co-op and the Social window are in ("Co-op on the core"), value on the server ("Value on the server"), today's HUD and panels ("The HUD on the core"), the Reaper ("The Gravecaller's rites") and
gathering with the Acre ("Gathering and the Acre").
The Depths are in ("The Depths"). Off in this step, each until its ROADMAP item: the graphics governor and Grave Surges. The waves follow the heroes from area to area as today's: the director moves to
the combat area a hero stands in, and the ground left behind is cleared at once (its living bodies sent away through the core, no death or corpse), as is one nobody has stood in
for 15 s. Easy auto combat is in and opens from Settings as today. `tests/world.gd` plays the whole world: seals, gates, walking from the Chapterhouse into the Warren, waystones,
the recall, the waves following the hero. `native/README.md` "Differences from today's game" lists what behaves differently from today.

## The Gravecaller's rites

Today's rites (`godot/next/rites`, DECISIONS B42) run in this project as GDScript and call the core synchronously: a rite damages with `core.damage(id, amount, source)` and reads `{dealt, killed}` at once, so Wailing Skull's
extra leap on a kill, Bone Prison skipping the dead, and the Litany's loops work as they do today. `next/rites/` has the necromancer's 25 rites (24 ports, Veil Step a copy) and the Reaper's nine:
her shared helper `DmReaperRites` (the cone and circle pick, the blow with its life steal, the soul bag) and Scythe Weave, Wraith Walk and Unleash Souls are ports; her other five rites only call the helper and are
copies. The registry lists all 34; a rite with no module (the five later classes') is refused `unavailable`. `DmNextGame.attach_caster` gives the hero his `Rites` node (a `DmRiteCaster`, the game scene is its `DmRiteWorld`) and `DmRiteHotbar.wire`
connects the input. The numbers (spell power, cooldowns, costs, runes) are still `DmAbilities`, `DmSimData` and `abilities.json`; the thralls' stats `DmThralls.raise_stats / colossus_stats`.

What a rite uses where it used nodes (all on the caster `c`; the adapters belong to the game scene's `DmCoreHost` and live in `core/`):

| today | on the core |
|---|---|
| `c.world.enemies_in_radius`, `enemy_by_id`, an enemy's `global_position`, `radius`, `hp` | `c.foes_in_radius(pos, r)`, `c.foe(id)`: `DmFoe` snapshots (id, x, z, radius, hp, state, def, area), living, spawn order, edge distance (`core/dm_foe.gd`) |
| `DmStatusSet.hit(e, amount, c.body)`, then `e.hp <= 0` | `c.deal(id, amount)` returns `{dealt, killed}` (`c.hit` the bool); the hero is the source |
| `DmStatusSet.ensure(e).apply / has / stacks / remove`, `c.watch_dots(ss)` | `c.apply_status / has_status / status_stacks / remove_status`; the DoT credit and Withered's hand-on are the core's events, connected once per caster |
| `DmCorpseField`, `DmSimCorpse` | `c.corpses()` (`DmCoreCorpses`, `core/dm_core_corpses.gd`): `pick_corpse`, `corpses_in_radius`, atomic `consume`, `add_corpse`, `notes(id)`; records are `DmCoreCorpse` snapshots |
| `DmThrallHost` (`raise`, `rally`, `command_rend`, `near`, `list`, a `DmThrall` node) | `c.thralls()` (`DmCoreLegion`, `core/dm_core_legion.gd`): the same calls, a thrall is an id and `info(id)` is the core's record; cap, formation, swing and death are the core's |
| lane, cone, circle, `pick_enemy` of `DmRiteModule` | the same functions, answering from the core's radius query with today's rules (edge distance, strict comparisons, spawn order, caps) |
| `e.set_meta` (contagious, the Chain Plague gap, the shroud's cover) | by enemy id in the rite's memory; the shroud's cover is `core.cover_miasma` |

Timers stay the caster's (`c.after(ms, fn)` on the body's clock, a physics tick). Events and fx are today's: `broadcast` -> `play` -> `DmRiteFx` through the copied `Vfx` and `AudioDirector`. The hero's own statuses stay
`DmStatusSet`. The cast flow (owner, cooldown, essence and cast lock through `DmAbilities.cast_check / apply_cast_cost`, refund on a lost corpse race) is unchanged. `client/tests/rites.gd` casts every rite
(table-driven against the copied rules code), the refusals, the synchronous-kill cases, the kit's hotbar and the click-to-attack chase, and plays a fight; then the other three necromancers and the Reaper, each a real
character in a fresh game (her bag, souls paid and refused, every rite's damage with the souls' bonuses, the life steal, the wisps, Soul Harbinger's Raiment, a kill banking a soul, auto combat's pick);
`native/README.md` "Differences from today's game" lists what differs.

## The bosses

The seven bosses (`next/bosses`, `sim/bosses`, `game/dm_boss_view.gd`): the Gravedigger King (the Hollow Graves), the Bone Abbess (Ossuary), the Drowned Congregation (Nave), the Bell-Sworn Prelate (Sanctum, woken with
the Sundered Bell), the Plague Saint (Cloister), the Cinder Regent (Pyre) and the Mire Mother (Fen) run in the game scene as DECISIONS B42 says: **an external entity of the core (kind 1) whose brain stays GDScript.** The
brains of `sim/bosses` are copies, unchanged (a brain does not know what a core is: it asks its `DmBossWorld`) but for the Plague Saint's, which asks for her doctors only (`enemies_of`, below); five files are ports (`code.list` "Ported"). `DmBossHost` (child `Bosses` of the game scene, `g.bosses`) has today's
summon rules, spawner, event routing, fx and music, and serves all seven areas (`served_areas`); `DmBoss` is the body; `DmBossNodeWorld` is the brain's view of the world, answered from the core.

| today | on the core |
|---|---|
| `DmBoss extends DmEnemy` (a `CharacterBody3D` in the `dm_enemy` group, with a collider, a navigation agent, a state machine) | a plain `Node3D` that registers with `DmCoreHost.register_boss` (its `core_id` is an **external of kind 1**) and keeps what it took from `DmEnemy` as fields: `hp`, `max_hp`, `radius` 1.6, `damaged`, `died`, `is_hittable()` |
| thralls scan and hit it as an enemy (group order, boss edge rule) | the host writes `set_external(id, place, is_hittable())` before every `core.step`: `alive` is false while it cannot be hurt (the Mire Mother sunk) or is not awake. Thralls scan it after the enemies by the core's boss edge rule; their blows come back as `EV_THRALL_HIT_EXTERNAL` (`thrall_hit_external`) and `DmBossHost._on_thrall_hit` gives them to `DmBoss.take_damage` with the owner as the credit |
| `world.enemies_in_radius` appends living bosses; `enemy_by_id`; `DmStatusSet.hit(e, ...)` | `DmCoreHost.enemies_in_radius / foes_in_radius / foe / enemy_info / enemy_position / enemy_alive / enemy_radius / damage / apply_status / status_stacks / remove_status` answer for a boss id too: the living boss comes after the enemies, measured to its edge, as a `DmFoe` with `boss` true (so the caster's `c.foe`, `c.foes_in_radius`, `c.deal`, `c.apply_status` and the lane, cone and circle helpers of `DmRiteModule` reach it with no change), the hover pick finds it, and a blow on its id is `take_damage` into the brain |
| its `DmStatusSet` | the same: statuses on a boss are the boss's GDScript set (B42); slow, root and chill show and the brain ignores them; a stun staggers it at most 0.5 s every 8 s |
| the brain's `world.spawn_enemy / remove_enemy` | the adds are the director's spawn through the core, in the boss's area and at its level (`DmWaveDirector.spawn` returns the core id); a kind the core does not run yet is skipped, as a kind without a scene was (the brain goes on without it); they leave with the boss (defeat or wipe) through `DmCore.remove_enemy`: out of the table at once, no death, no corpse, no credit |
| the Abbess's niches: director enemies of kind `niche` (`DmEnemyNiche`), `world.set_enemy_hp` | core bodies of the `niche` kind (`native/src/core/niche.cpp`: they rise, then only stand; nothing staggers, stuns or moves them; they lay no corpse and pay nothing), given their health by `DmCore.set_enemy_hp` (7 % of hers); the crowd draws the baked `skull_niche` and hides it the moment it falls |
| `world.corpses / remove_corpse` (Bone Communion `devoured`, the Drowned Rite `raised`) | the core's corpse field (`DmCoreCorpses`, atomic consume) |
| `world.cover` (the Congregation's pews) | `DmDb.sim_world()["cover"]`, the same boxes |
| the Saint's rot pools and the Regent's coals, firebreak and embers: `DmHostileZone` nodes made by `DmBossHost.spawn_pool` (and a visual-only copy on the other peers) | zones of the core with the boss's id as their source (`DmCore.add_zone(kind, ...)`, kinds `toxic` and `ember`): the core pulses them (`dps x 1 s` on every hero and thrall within radius + 0.45, hit kind toxic or burn), `DmCore.zones(kind)` lists the live ones for the Saint's "am I standing in rot" (a sac's burst corpse counts too), and `DmEnemyFx` draws a pool from its zone event on every peer (a toxic zone whose source is not a body of the table: a boss's) |
| the Prelate's echoes: the summoner's vow `prelate_echo` | `echoes()` is the world's (`DmBossHost.vow_fx`): none, because the rebuild has no vows (B36); native/README.md "Differences" |
| the Congregation's wading water, the hero's root and chill | the host's wade clock (`hb.wade_mult`) and `root_for` / `dm_enemy_effect(&"chill")` on the hero body, as before |
| its blows: `hero.take_damage(dmg, boss)`; `thrall.take_damage(dmg, boss)` | `hero.take_damage(dmg, boss.core_id)` (the id is the source, like any enemy's: the hero's body finds where the blow came from, and Colossus Mantle's reflect finds him by it); `core.damage(thrall id, dmg, boss.core_id)` |
| the Scythe's arc and the needle's range treat a `DmBoss` apart | `DmFoe.boss`: the arc counts it separately with its own reach and one of the arc's hits, the needle's range counts its radius, and the click-to-attack chase does too |

What the host's `DmCoreHost.tick` does with it, in the tick's order: the boss's `_physics_process` (priority 0, with the session and the director) pumps the brain and mirrors its position, then the host writes the external and steps the core; the
core's thralls act on the place it wrote, and their blows on it are given to the brain as the tick's events are dispatched.

**Summoning** is today's: key E within 4 m of the boss's grave, altar, bell or reliquary (or a click on it, or `bosses.request_summon`; the hub shows "Summon X · N shards"), the refusals `far`, `unknown`, `busy`, `dead` and `shards`: the summon takes
the boss's soul shards from the summoner's progression (the Prelate's bell through `spend_shards`, which also owes the run a Prelate summon). **The Covenant Seal** (`DmBossMeta`, child `BossMeta`, made by the game scene's value step, a copy of
today's): at an altar of a boss that can be Empowered, with a Seal in the bag (or an earlier lost fight's summon bound on the backend), the host's `site_hook` opens the HUD's boss-key prompt (`boss_key_offer`; its two buttons answer
`summon_boss` and `summon_boss_empowered` on the HUD adapter); the Empowered call goes to the backend (`/api/boss-key/summon` takes the Seal and 7,500 x shards^2 gold, a bound summon is free), wakes the boss with `try_summon(..., true)`
(+6 levels +15 %, hp x1.4, a red-gold glow), the kill's report carries the summon id and the Seal's prize is claimed from the backend and dropped at the corpse. The Prelate cannot be Empowered.
**A defeat** is the host's `defeated` signal (a real kill; `reset` for a wipe), the brain's events (`brain_event`), `DmBoss.died` and the boss sounds, and `DmSessionRewards.on_boss_defeated` pays every member in range (gold, shards, items, XP,
the first-kill bonus and trophy once, the entry of the backend's report; the Prelate has no trophy: its kill is the run's tally). The boss score follows the local hero while he is in its area. The dev entry's `--boss` starts the hero at the
King's grave, grants the shards and wakes him.

**Tests.** `client/tests/boss.gd` is the King's proof: his six recorded scenarios of `godot/tests/bosses` replayed tick by tick through this project's copy of the brain, the summon rules, the awaken numbers, his attacks and phases stepped
by hand with today's numbers and timing (sweep, Burial, phases, ghouls on the rim, the elite, the pits, the double sweep, the blows on the hero and on a thrall), the wipe (adds leave silently), thralls (the edge rule,
`thrall_hit_external`, credit, `alive` false while he cannot be hurt), the rites (edge distance, order, lane, cone, circle, the needle's range, the Scythe's arc, the Spear's rally, Fan, Lance, statuses, stun), the defeat events, a second summon, a
fight on the real clock and the net state round trip. The other six have a suite each on `client/tests/boss_base.gd` (`boss_abbess|congregation|prelate|saint|regent|mire.gd`): their recorded scenarios (44 with the King's six, 8 for the Prelate
with her three Echoes), and the generic parts the old suite (`godot/tests/next_bosses`) checked of every boss on the core: the hub's prompt and the summon rules, the awaken numbers and the registration with the core, thralls (the edge rule, the credit, the
boss's blows on the thrall), the rites, a stun, the wipe, the defeat with its rewards and the first-kill bonus once, the boss score, a fight on the real clock, the net state; then each boss's own fight by hand against today's numbers (the Abbess's niches, Grasp, Lance,
Chorus, a niche's break, Communion over real corpses; the Congregation's Maul, Grasp, Hymn behind a pew, the water; the Prelate's Slam, Toll, Bell Rain, Procession; the Saint's swing, Rot Rain, pools, blessing, link; the Regent's cleave and
firebreak, coals, Conflagration; the Mire Mother's Maul, Hands, Surface, the flood, the Drowned Rite). `boss_meta.gd` is the Covenant Seal on the mock backend (the altar's choice and the prompt, the Empowered call, the report's summon id, the prize, a
bound summon) with the first-kill trophies. `core_boss.gd` is the core's half (the niche, a body's health, the zones, their wire).
Not in them: the boss bar and banners (the full HUD); the two-player fights (the co-op state and events are `DmBossHost`'s own, 20 Hz and reliable, which the port kept: "Co-op on the core";
the King fights both heroes in `coop.gd`, the other six in `coop_bosses.gd`). Easy auto combat takes the awake boss as a target (`bosses.active_boss()`, its telegraphs from the boss fx).

**The adds** are the director's spawn through the core (`DmWaveDirector.spawn`, in the boss's area, at its level, `runs_on_core`): the Abbess's niches, the Congregation's Choir Wraiths and Penitents, the Prelate's Risen and Penitents, the Saint's Plague Doctors,
Flagellants and rats, the Regent's Cinder Husks, Pyre Priests and Cinderhounds, the Mire Mother's Mire Leeches, Bog Hags and Risen. The Saint's doctors' link heals her by the doctors the world finds in the core's table: `DmBossNodeWorld.enemies_of("plague_doctor")` reads `enemy_rows` (seven numbers a body, no dictionary) and fills a row for a doctor only, each body's area the last answer while it stands strictly inside that area's rect (`DmNextWorld.area_interior`), so a tick with 70 bodies in the room costs about 0.09 ms where every body's row cost 0.3 (`enemies()` is the same list of every body, for a brain that wants it).

## The benchmark

Today's in-game benchmark (`godot/next/perf/README.md` "Benchmark"), ported to the core: the same held fight in today's nine rooms with the four necromancers and the Reaper, so the Full Party fight can be measured in this client against today's game, room by room (ROADMAP Gates B and C).

```
bash client/tools/bake_crowd.sh                                                                                                    # once: the crowd models the fight draws (with none baked the crowd does no view work: about 0.6 ms a frame cheaper, and the report says so)
nice -n 10 /home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client -- --benchmark --bench-room=graves --bench-size=full_party --bench-class=2   # the VPS processor test; the report is in the log
nice -n 10 /home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client -- --benchmark --bench-room=fen --bench-size=full_party --bench-class=11 --bench-length=quick   # any of the nine rooms (graves warren ossuary nave coliseum sanctum cloister pyre fen), any of the five classes (1 2 3 4 11)
/home/ubuntu/tools/godot/godot --path client -- --benchmark --bench-room=graves --bench-size=full_party                              # on a PC: the fight in the window, then the render breakdown
```

- **Launch:** `-- --benchmark` runs it at once on an isolated offline game (no login) and stays on the results screen with a Quit button; a headless run quits by itself once the report is out (`BENCHMARK` lines in the log and
  `user://benchmarks/bench-<datetime>.txt`). From the character select, the **Benchmark** button opens the setup window; Start runs it and Back returns. `--bench-room=`, `--bench-class=`, `--bench-size=light|standard|heavy|full_party` and
  `--bench-length=quick|full` pick the setup (Quick: 6 s warm-up and 20 s measured; Full: 10 s and 30 s, then the render breakdown), `--bench-warm=<s>` / `--bench-measure=<s>` shorten it, `--baked=<dir>` names the baked crowd models.
  **The rooms** are today's nine (`DmBenchmark.ROOMS`: the Hollow Graves, Catacomb Warren, Marrow Ossuary, Drowned Nave, Bone Coliseum, Bell Sanctum, Plague Cloister, Cinder Pyre and Mourning Fen; the Depths is an instance, not a room) and **the classes** the four
  necromancers and the Reaper (`class_indices`, 1 2 3 4 11, the playable disciplines): anything else (`--bench-room=depths`, a greyed-out `--bench-class=5`) is refused with a message that lists what the benchmark has, and exit code 2 (`DmBenchmark.refusal`).
  The Standard setup is today's: the Bell Sanctum, Gravecaller, Standard size, Full; Gate B's Full Party fight is a custom setup in the Graves, as it is today. Only the picked room's area is loaded (`opts.areas`), so the run measures the room, not the world.
- **Where the files go:** the report, the history, the queue of runs to send and the last setup are in `DmBenchmark.dir` (`user://benchmarks`); `--bench-dir=<dir>` keeps a run's in a folder of its own, and a run that has one is a trial that sends nothing.
- **The fight** is today's: the fixed seed 20261011, a god-mode level 60 hero of the picked class on Easy auto combat holding his ground at the walkable point nearest the room's centre that a path joins to its doorway (the Sanctum's centre is a cut-off dais), no elites, every enemy on the health and damage of the Bell Sanctum
  roster's average (272.9 hp, 10.8 damage: `DmBenchmark.STATS_ROOM`, the same in every room), waves brought in to 6 to 14 m, the count topped up and trimmed every 0.25 s, and for Full Party 72 enemies, 32 thralls and the room's boss held awake
  (the one that sleeps in that room, `DmBenchFight.boss_of`, as today's: the Gravedigger King in the Graves, the Bone Abbess in the Ossuary, the Drowned Congregation in the Nave, the Bell-Sworn Prelate in the Sanctum, the Plague Saint in the Cloister, the Cinder Regent in the Pyre
  and the Mire Mother in the Fen; woken through the real summon, again after each defeat; the Warren and the Coliseum have none and run without, and the Setup line says so). On the core: the director spawns through `DmCoreHost.spawn_enemy`, `trim` removes the farthest extras with `remove_enemy` (no death, no corpse, no reward), the thralls are raised
  straight into the core without the cap, and every count is read from the core. `DmBenchFight` holds these rules.
- **The report** is today's (the table, the hitch log, the render breakdown) with the core's name in its header, and a **budget section** that sets the ROADMAP's budgets against this run: the combat core's step, the crowd's sync and the
  event dispatch per 60 Hz tick (`DmCoreHost.measure`, on for the measured window only) against 4 ms; the rest of the main thread per frame (the frame less the core's share, ticks a frame times its tick) against 4 ms; the HUD's main-thread
  share against 0.5 ms (the same fight with the HUD off and on, eight times over, half a second each: a share below the printed spread, twice the standard error of the rounds, is noise) and its draw calls against 150 (from the render breakdown's HUD row, so on a PC with a renderer and a Full-length run).
  Each line says PASS or MISS. The budgets are set for the headless Full Party fight on the VPS; another size, or a rendered run (where the rest includes drawing), prints them as information. The numbers are not asserted by any test.
  The render breakdown's parts are Shadows, Creatures (the crowd's MultiMeshes, in the main pass and in the shadow passes), World, Effects and HUD; they overlap (hiding the world also takes its shadow draws out), and what the rows count is explained in "The draw budget".
- **The crowd's cost** is in the report (client/crowd/README.md "Crowd cost"): a `Crowd:` line under the setup names what was in force (the mesh levels' distances, the instances a group starts with, the animation bands, culling, whether thralls cast, the
  enemies that cast), and `Crowd per frame` under the budgets gives the measured window's averages from `DmCrowd.stats()`, sampled with the fight's other counters (bodies, drawn with their MultiMeshes and triangles, outside the view, the instances that cast
  shadows with the thralls among them and the triangles the shadow pass takes again, poses worked out against the living, the bands). Those counters are deterministic: they read the same on any PC, so a run on Helix's PC and a run on the VPS compare
  by them. `-- --bench-crowd=key=value,...` changes a run to compare A with B on one PC: `cull=off`, `anim=off` (the animation bands), `mid_m`, `mid_hz`, `far_m`, `far_hz` (the bands), `thrall_shadows=off` (over the preset), `lod=32/60` (the mesh levels' distances in
  metres), `reserve=128` (instances a group starts with); a key that is not one is named and ignored. Culling and the bands save GPU work the headless run cannot see: the CPU side of the whole crowd is under 0.3% of a frame (README "Crowd cost").
- **Physics and process, what a frame costs:** Godot's `TIME_PROCESS` and `TIME_PHYSICS_PROCESS` (what today's report prints as "Process ms" and "Physics ms") are the slowest single frame and the slowest single tick of each second,
  refreshed once a second, so they read above the average frame whenever one tick in sixty is slow (Helix's PC, 2026-10-17: a 4.12 ms frame with "process" 5.59 ms and "physics" 6.47 ms, the core's tick 0.30 ms; the slow tick was Easy auto combat
  choosing its rite). The report keeps them as the two **Godot peak** rows (today's game prints only those, so they still compare with it) and puts what a frame costs beside them: `DmFrameSplit` (`next/perf/dm_frame_split.gd`) times the
  physics part (from the first tick's `physics_frame` to `process_frame`: every tick's `_physics_process`, the physics and navigation servers, the physics clock's timers and tweens) and the process part (to the start of the last `_process`) of
  every measured frame: **Process ms (avg)**, **Physics ms (avg)** a frame and the **Slowest tick ms**, and a **Frame** line that splits the frame into physics, process and the rest (drawing, waiting for the GPU, presenting). The F3 overlay's
  logic line is the same split over the last second. `tests/benchmark.gd` pins the split with a tick that holds itself for 3 ms.
- **The headless frame pad:** with no window to draw, Godot waits at least 6.9 ms (`low_processor_usage_mode_sleep_usec`) after every frame, so a plain headless run shows 6.9 ms for any frame that cost less (a median within 3% of it) and hides the
  cost under it: the report warns, and does not judge the rest of the frame. `--fixed-fps 60` before `--path` has no pad and runs one tick with every frame, which is the processor test (the repo's `tests/perf/fight_breakdown.gd` runs the same way).
  It runs faster than real time, so a window counts seconds of fight by the engine's frame time (`--bench-warm`, `--bench-measure`; 30 s is 1,800 frames), and Easy auto combat keeps its cadence on the physics clock (`DmNextAutoCombat.clock_ms`),
  where a wall clock would stretch it.
- **Easy auto combat** (`next/feel/dm_next_auto.gd`) is today's decision code (`DmAutoCombat`, `DmAutoDodge`) behind an adapter that reads the core: the enemies by `enemy_ids / enemy_positions / enemy_states` (spawn order, as the nodes were walked),
  the corpses by `corpse_ids / corpse_positions`, and what those arrays lack from small tables the host's signals keep (an enemy's radius, elite flag, health, wind-up and area from the spawn, damaged and attack events; a corpse's kind from
  `corpse_added`; the dust clouds and toxic pools from `zone`). It emits the same intents as the keyboard (`DmNextInput.cast_at`, `request_move_dir`). Its gate (`allowed()`) is closed until the settings (not built) or `gate_probe` opens it.
  Its choice (`DmAutoCombat`, ported: native sorts, each field read once, the counting rites on packed arrays) takes about 0.6 ms with 62 enemies and 31 corpses in reach on the VPS (today's file takes 3.0 ms, 7 ms when it ends in
  Corpse Explosion, all inside one physics tick; a step of the walk 0.3 ms against 0.8), always choosing the same rite and the same step: `tests/auto_combat.gd` replays the live game's golden cases and seeded fights against the live file. A hero that holds his ground reads the core's tables only when an action is due.
- **The warm-up** (`DmNextWarmup`, with `DmWarmup`) runs for players as in today's game (`DmNextGame._wants_warmup`: not headless, not on `--qa` or `--shot-plan=` runs; `--warmup` forces it, `opts.warmup` overrides it, the benchmark forces it): models and effects load on worker threads (not headless: its dummy renderer fails on them), the boss's models, the effects, the gear (the Reaper's scythe too), the telegraph shapes, a shot of each kind and a beam (`DmFxPrims.warm_shots`) and the hero see-through (Wraith Walk's
  phantom) are drawn once, every crowd model is drawn at its three levels of detail from rehearsal rows fed to the crowd (`DmCrowd.sync_rows`, with the core's tick held meanwhile so its sync does not forget them; the rows are cleared after), and the camera tours the areas
  the game has loaded, lit, with every point light off, and with the flash light. Until 2026-10-17 it ran only in the benchmark: play compiled every effect the first time it was drawn (warbogar's
  report, the Reaper's effects stalling on their first cast); the benchmark's numbers had it on all along.
- **Sends:** the run's backend is the in-memory mock. A finished run is queued in `pending.json` (`DmBenchmark.dir`) and sent to the **test server** only (`net/dm_config.gd`): from the character select with the logged-in api, from `--benchmark` with a
  release build's saved login; debug builds, `--dev-offline`, a run with its own `--bench-dir=` and tests never send (the run waits in the queue, and goes out when a player next enters the world on the test server). The one door a run leaves by is
  `DmBenchHistory.flush`, and from a script run (every test is one) it refuses a real transport. `tests/benchmark.gd` pins it: it points `DmBenchmark.dir` at a folder of its own (with its baked models, removed at the end), so another run's history,
  queue or setup can neither change a check nor be sent by it, and its uploads go to a mock that answers as the test API.
- **In the fight as today:** rewards, loot drops and the kill ledger against the run's in-memory mock (the King's soul shards are granted to the throwaway character and charged, as today's `hold_boss`),
  and today's effects (`Vfx`), with one difference: the work that grows with what is on screen is the core's C++, particles and decals ("The effects"), which won back 0.7 ms of a Full Party
  frame on the VPS for the particle ring (5.7 to 5.0 ms; 2026-10-16) and about 0.6 ms for the decals.
- **The world dressing's cost** (2026-10-17, the Graves' Full Party, headless `--fixed-fps 60`, six alternating pairs in ABBA order, `--bench-dressing=off` against the default, on a shared machine whose load swung between 3.7 and 5.9): the average frame 3.86 ms
  without it (runs 3.27 to 4.35; p95 7.68, p99 10.83) and 3.96 ms with it (3.61 to 4.27; p95 8.01, p99 10.95), +0.10 ms, a fifth of the spread of either arm; the rest of the main thread 3.27 against 3.35 ms of its 4 (the combat core 0.59 and 0.60).
  The node alone costs 18 microseconds a frame ("World dressing"); what the dummy renderer cannot say is the GPU's share, which is the water's fragment loop and a dozen transparent draws: Helix's PC.
- **Not in the fight yet** (it is cheaper than today's by these): the guests' hero bodies, as today. `native/README.md` "Differences from today's game" has the rest.

## The draw budget

The 3D draw calls of the Graves' Full Party fight (72 enemies, 32 thralls, the camera over the middle of the room, Ultra's moon with two cascades), counted from data so a test can hold them
(`tests/draw_budget.gd`: a draw call is what the budget counts and a headless run draws nothing) and checked against a rendered run (`tools/draw_measure.gd`). `DmDrawModel` (`next/perf/dm_draw_model.gd`) is the
count, `DmDrawScene` (`next/perf/dm_draw_scene.gd`) the scene both build: the room's area scene, the game's camera, the Ultra preset's moon, the combat core with four necromancers' thralls and 72 enemies; no hero, HUD or effects.

**What Forward+ draws,** measured with the engine's own counters (`Viewport.get_render_info`, the main pass and the shadow passes; Forward+ on lavapipe, 2026-10-17) and found again in Helix's two benchmark runs:
- An instance is an *object* in the main pass when its bounds meet the camera's frustum, and in a shadow pass once for each moon cascade whose volume its bounds meet, when it casts. A *draw call* is one surface of an object.
  The Ultra preset has two cascades (0 to 8 m from the camera, 8 to 80 m: the first holds nothing but air at this camera, and still draws every MultiMesh that casts, whose bounds are the whole area).
- **Identical meshes are instanced by the renderer:** the instances of one mesh, surface and material that a pass meets are ONE draw call. The Graves' 130 props as prefab instances cost 33 draw calls (15 in the main pass, 18 in the shadow
  passes); a mesh that stands once costs its surfaces, and so does a mesh that merges many props.
- **A MultiMesh with no instance costs its draw calls all the same:** one in the main pass and one in each cascade it meets when it casts (+1 draw call in the main pass and +2 in the shadow passes when it casts, whether it holds 0 or 4 instances). A MultiMesh is never merged with another.
- Occlusion culling (the Graves' occluders), the sky and the lights' own work are not counted: the model runs a few draws under the engine (the Graves' world from the camera's middle: 75 against 84 rendered; with the merged cell meshes of ROADMAP "Static batching" it was 105 against 107), so a budget is set a little over the model's number.

**The benchmark's rows,** from those rules (the rows overlap: hiding the world takes its shadow draws too, and the Shadows row is every shadow draw, the crowd's too):

| Helix's PC, the Full Party in the Graves | 20261017.012954 (da9cc52) | 20261017.025239 (8913127) | explained by |
|---|---|---|---|
| Creatures | 280 | 396 | every group drawn: 144 groups + 2 cascades x 68 casting groups, then 202 + 2 x 97 (12 models, 29 levels, joined: +58 in the main pass, +58 in the shadow passes) |
| Shadows | 227 | 301 | +58 the same groups, +16 the world's shadow draws |
| World | 123 | 153 | +14 main pass, +16 shadow passes: static batching lost the instancing of the props (taken out again) |
| HUD | 126 | 121 | |
| total | 581 | 725 | |

Of the 202 groups (41 models x levels of detail x with and without shadows) the Graves' party used 15: the other 187 were drawn empty, 396 draw calls for 41 that mattered.

**The crowd draws what is in view, not what is registered.** `DmCrowd.set_group_nodes` (dmcore 0.14; `CrowdView` calls it for every model) hands the crowd the `MultiMeshInstance3D` of each group: the nodes start hidden, a group is shown
the frame its first instance is written and hidden once it has held none for half a second (a body crossing a level of detail back and forth does not rebuild the instance every few frames). The party's draws no longer grow with the roster:
the crowd of the Full Party costs 41 draw calls (17 main, 24 shadow) in the rendered run, 396 with every group shown, and the Graves' whole fight about 340 where it was 725 (with the batching out as well; the benchmark on Helix's PC will say). A model's first appearance
shows a group the frame it is needed; the models share the crowd's shader, so that costs a material's uniform set and no compile (the warm-up draws every model once all the same).

**Static batching is not in the areas** (ROADMAP "Static batching"): merging a cell's repeated props into one mesh was no saving in draw calls, because the instances it replaced were already one draw call per mesh and a cell mesh is unique.
The Graves' world from the camera's middle and four places round it, rendered (`tools/draw_measure.gd --compare=<another version of the room's scene>`): 107, 112, 112, 93 and 116 draw calls merged, 84, 94, 91, 80 and 99 as prefab
instances (13 to 23 more merged; +30 on Helix's PC); the props alone 56 against 33; the merge saved objects (171 in the main and shadow passes to 129). The lightmap does not change the count (110 with it, 109 with it hidden). What cuts the
world's draws further is fewer distinct meshes and materials, which is the asset rebuild's.

**A body that is not solid draws through its model's fade group** (client/crowd/README.md "The alpha path"): a sinking body or a shrouded elite is written to a third MultiMesh of its model and level, drawn with the alpha shader in the
main pass only (no shadow pass), so a fight with nothing fading costs what it did and a crowd of bodies sinking together costs one draw call a model and level. The Full Party with 24 of its robbers and hounds sinking and three shrouded elites
standing among them: 27 instances in 2 fade groups, 24 draw calls for the crowd where the standing party's are 22 (`BUDGET_FADE`, 8, is what the budget allows the fade groups on top of the others).

**The test** (`tests/draw_budget.gd`, 50 s, bakes twelve crowd models into a scratch folder) builds the scene, lets the party fight for two seconds and counts: the crowd's groups (a group that holds instances is shown, at most two empty ones are shown, most
groups are idle), the crowd's, the world's and the whole's draw calls against `BUDGET_CROWD` (30), `BUDGET_WORLD` (85) and `BUDGET_TOTAL` (110; the model counts 22, 75 and 97), and that the model sees a crowd with every group shown (120 draws with only
twelve models; 396 with the roster). A change that adds draw calls fails here and not on Helix's PC; raising a budget is a decision. Rows by group are printed.

**The measurement** (`tools/draw_measure.gd`, rendered, about 200 s on the VPS; the command and its options are in the file's header) writes JSON lines: the world from five camera places and each group of its geometry hidden alone, the same for
another version of the scene (`--compare`), a MultiMesh with and without instances, and the crowd as the crowd shows it, with every group shown and hidden, each beside the model's number for the same frame.

## World dressing

Today's `DmWorldDressing` (`client/world_fx/`, data in `godot/data/world_fx/fx.json`, ported: client/code.list) is attached by `DmNextWorld.build` to the areas the world holds, so the rebuilt world draws what the live
one does around the static scenes. `DmNextWorld.dressing` is the node (null in a world built with no lights), `enter_area` tells it the hero's area (the weather and the water follow by event), `DmNextPerf.apply` thins the
weather on Low (`atmosphere.quality_low`, today's), and the graphics preset owns the bloom (`DmGraphicsPreset.apply_environment`, "Glow" below); the dressing no longer touches the environment. The area scenes carry none of what it draws:
the converter leaves out the flame spheres (a sphere floated above each candle and, with the glow, read as a white blob), the water planes and the puddle quads, so nothing is hidden at run time.

| Piece | What it is | How it is drawn and what a frame pays |
|---|---|---|
| Candle flames, 347 in 8 areas | additive billboards at the wicks, flicker and bob, the Sanctum's candle groups | one MultiMesh in each loaded area that has candles (a draw call when in view), the flicker in the vertex shader: nothing per frame |
| Brazier fire (21 braziers) | violet wisps and amber embers 30 x 28 m round the hero | one ring MultiMesh. A particle is written once, when it is emitted (a roll every 0.05 s, the web's 10 wisps and 1.5 embers a second a brazier); its place, size and fade are closed forms of its age in the vertex shader (`DmWfxParticles.pose` is the same function in GDScript and the test holds it against the web's frame-by-frame step). Today's GDScript stepped every live particle every frame |
| Ground mist, 220 puffs | big soft puffs at knee height drifting over the world | one MultiMesh; the web's wrap rule stepped 4 times a second (today's: 15), 55 microseconds a step |
| Weather, 13 profiles | ash, leaves, bone dust, drips, embers round the hero | one mesh drawn from a clock by its vertex shader; an area's mesh is built the first time it is asked for and kept (4.8 ms in GDScript for the Nave's), the starting area's during loading |
| Windows, 4 | stained glass and a slanted shaft of light | a pane and a shaft under the nearest area's scene (the Nave's three, the Sanctum's one), static |
| Silhouettes, 70 | far spires, dead trees, fallen walls | one merged mesh |
| Water | the Nave's channels, the Fen's bog, the Acre's ponds, the puddles | one mesh, fresnel, the moon's glint, up to 16 ripple rings in the fragment shader; Low keeps today's flat sheet only through `quality` |

The brazier fire, the mist, the weather and the water are the only things that move on the CPU, and `DmWorldDressing._process` is a clock, an emission roll every third frame, a mist step every fifteenth and a few shader uniforms:
**18 microseconds a frame** (measured with the dummy renderer, the node alone in a Graves world, 3,000 frames; the weather 0.8, the water 0.4, the roll 16 each time and a mist step 55). Today's mist (14 a frame) and brazier fire (44 with 26 live particles) took 58 between them.
Building an area's weather in GDScript costs 4.8 ms (the Nave's), which an area entry used to pay each time: now every loaded area's is built while the world loads. The six objects (water, weather, brazier fire, silhouettes, mist and the area's flames) are six draw calls
in the Graves' budget scene (`tests/draw_budget.gd`: `BUDGET_DRESSING` 8, none cast shadows) and replace the eight draws the stand-ins cost: the Graves' world, the dressing and the crowd are 96 draw calls with the earth beyond the walls (1), against 97 before.
`DmDrawModel` counts the dressing's pieces apart ("dressing:<piece>"). `--bench-dressing=off` (or `mist,water,...`) switches pieces off for a benchmark run and the report says which were off (`World dressing:`); the A/B is in "The benchmark".
`tests/dressing.gd` is the suite.

Not wired, as in today's game: `add_ripple` and `candle_group` are called through `DmEnemyFxHost.dressing`, which the game scene does not set, so the water has no ripples and the Prelate's candles do not gutter (ROADMAP "After launch day" → "For review").

## The effects

The effects are today's `Vfx` (`fx/`, `DmFxRuntime`): ground decals, the two particle rings, the Binbun scenes, flashes, beams, projectiles. What grows with the number of them on screen is done in C++, each piece proved against today's GDScript; the rest is today's code.

- **Particles** (`DmMotes`, native/README.md "Files"): a ring's motes, the random start of every mote of a burst and the per-frame loop. `DmFxRing.emit` hands the options over; the numbers come from the global generator in the order today's loop drew them, so a seeded run gives today's motes. `tests/fx_motes.gd` compiles today's `godot/fx/dm_fx_ring.gd` and compares both rings' buffers float for float (bursts in every colour form).
- **Ground decals** (`DmDecals`): a decal is a record in C++, not two GDScript objects. `DmFxPrims.decal` works out what it is made of (its layer, tint, whether it settles into an outline, as today's) and hands it over; C++ ages it, shapes it (growth, spin, pulse, fades, the outline that comes up after 0.6 s and the ring a settling disc brings with it, a flipbook's frame), places it (a decal that follows a body gives its id as `follow_body`, which C++ asks the crowd for; one with a `follow` callable calls it as before) and writes each layer's instance buffer and gives it to the RenderingServer. `DmFxLayer` keeps the MultiMesh and its node (`show_count`, `grow`). The cap of 160 combat transients counts decals and the other kinds together and the oldest leaves first. `tests/fx_decals.gd` compiles today's `godot/fx/dm_fx_prims.gd` at run time and compares every drawn float, the counts and the handles with it over two seeded runs and the cap; `tests/rites.gd` checks a decal that follows a thrall by id.
- **Binbun scenes** (`fx/dm_fx_binbun.gd`): an effect's root is moved only when it moved (every move walks the effect's subtree), a looping effect is tested against the camera every third frame (the test keeps 4 m of margin past the frustum) and 8 idle instances per effect are kept (it was 4), so a salvo of bonfires more often finds instances waiting than builds them from the scene.
- **The enemies' effects** (`DmEnemyFx`): the ambient tick (every 0.2 s) reads the bodies' places from one read of the core's bulk arrays (`enemy_ids`, `enemy_positions`) instead of a record each, and the Pyre's colours are read once. `DmCoreHost.foes_in_radius` (every rite's query) takes one call of the core (`DmCore.foes_in_radius`, ten numbers a body) where it took a record and a snapshot each (19 us a body).

Costs on the VPS (headless, cold: one call in the middle of a Full Party frame): the decals' step with 140 alive 0.04 ms (today's GDScript 0.55), the Pyre's whole effects layer 0.40 ms (1.27), the Graves' 0.16 (0.61), the Pyre's ambient tick 0.86 ms every 12th frame (2.7 ms before), a Plague Saint's look at her doctors 0.09 ms a tick (0.3), a rite's query over 40 foes 0.25 ms (0.45 to 0.9).

## Graphics presets

Today's Low, Medium, High and Ultra on Forward+ (DECISIONS B45): `game/dm_graphics_preset.gd` is the table and `next/perf/dm_next_perf.gd` (`DmNextPerf`, the game scene's `perf`)
applies it, ports of today's. The game scene reads the player's settings file at the start (the file today's game writes, so the test build plays at the player's preset) and the
Settings panel applies a change live, `opts.settings` in tests and the benchmark. A preset sets the moon's shadow, reach, splits
and atlas and the soft filter, bloom (`DmWfxBloom`), screen-space ambient occlusion (High and Ultra), MSAA, anisotropy and mesh LOD on the viewport, the effects quality
and the Binbun layer, the crowd's shadow policy (`DmCrowd.set_shadow_policy`: the nearest enemies that cast, today's counts, and whether thralls cast; a change reaches the
thralls already drawn) and the floor of Auto resolution, whose lower scales are upscaled with FSR 1. Brightness, fps cap, V-Sync, window mode and interface size are
today's. Not today's: the prop-light count and the prop shadow range (baked into the area's lightmap), and the brightness lift: an exposure multiplier of each area (`DmWorldBuilder.AREA_LIFT`, 0.8 to 2.1,
measured so that the rebuilt frame is as bright as today's, "The look against today's game"), eased in over 0.8 s when the hero enters another area (`LIFT_BLEND`; nothing runs per frame outside the blend),
times the preset's own factor (`DmGraphicsPreset` `lift`: 1, and 0.96 on Low, whose moon casts no shadow); the creatures' and the effects' shaders divide the lift out again (the global `dm_lift_inv`, declared in `project.godot`), because they are not in the lightmap it is calibrated on. `tests/presets.gd` (`--fixed-fps 60`, about 30 s) applies
each preset to a running game and checks the lights, the environment (the ACES tonemapper, the exposure from the world's number, the area's easing, the area's lift, the preset's factor and the brightness, the
plain-colour ambient, the depth fog, the moon and the rim light at today's energies), viewport, crowd shadows and the governor, the twelve lifts (a number here is a calibration: measure again with the probe before changing it), the blend and what the lift leaves alone (`dm_lift_inv` follows it through a blend, the creature material's, the crowd's and the effects' shaders divide it out and convert their colours as Compatibility does, the hero's ring and shadow strength).

## The look against today's game

Today's game runs the Compatibility renderer; the rebuilt client runs Forward+. The same scene, lights and numbers look different, and the first test builds looked darker and
purpler, with big beige pools under every flame and white blobs of glow, than today's blue-lit stone. `client/tools/look_probe.gd` measured it (2026-10-17, Ultra, the VPS's
software renderers, the same camera in the Chapterhouse, the Hollow Graves and the Ossuary, plus calibration scenes: a grey plane under one light kind at a time). What it found:

| What | Today (Compatibility) | Forward+ | The rebuild now |
|---|---|---|---|
| ambient, moon, rim, prop lights, fog, specular on a plane | the same pixel as Forward+ to within 1 | the same pixel as today's to within 1 | nothing to change |
| a vertex colour (a light pool's 0.25 / 0.17 / 0.09, a particle's colour, a gear mote) | read as sRGB: the pool's centre (82, 49, 24) | read as linear: (203, 175, 130), 9 times the light | `vertex_color_is_srgb` on the pools (`build_area._light_pools`, `DmWorldBuilder._light_pools`), the gear motes (`DmGearFx`) and the Binbun particles' materials (`DmFxBinbun`): (79, 48, 24) |
| a colour an effect's shader writes to `ALBEDO` (`COLOR.rgb` of the Fx layer, the world mist and particles) | converted from sRGB after the shader multiplied it | taken as linear | the shaders convert it (`dm_srgb` in `DmFxTex`, `DmWfxParticles`, `DmWfxMist`): (191, 155, 114) for today's (191, 156, 114) |
| a tinted dark texture (every floor, every wall, the gate posts) | tint x texel multiplied in sRGB, the product converted once | each converted, then multiplied: 1.04 to 1.6 times darker | the area converter lifts the tint by the measured ratio (`DmCompatAlbedo`, `client/next/look/`): the Graves' ground tint 0.72 / 0.67 / 0.72 becomes 0.80 / 0.77 / 0.81 |
| the glow of a very bright thing (an HDR quad of albedo 2 and a small emission of energy 6 on a dark plane, the glow part of the probe, 1280x720, red channel every 6 px past the edge) | 247, 189, 103, 41, 15, then the background at 30 px (the quad's edge pixel 62 of 255) | five mips: 255, 255, 251, 232, 213, 191 ... still 88 at 66 px | `DmWfxBloom`: the two finest mips at 0.8 of the web's strength: 255, 210, 104, 15, nothing at 24 px; threshold 0.85, scale 2 and cap 12 unchanged |
| a Binbun scene's own shader reading its particle's `COLOR` (`.rgb` as a colour or a mask offset) | the vertex colour converted from sRGB | taken as it is | `DmFxBinbun` reads it through a patched copy of each such shader (`dm_COLOR`: rgb converted, alpha as it is) |
| what a creature's shader writes to `EMISSION` and the tint it multiplies into `ALBEDO` (the hero's accent emissive 0.04 x the accent, the friend rim, the gear tints, a tinted body, the hit flash: all `lin()` of a hex) | `emission = srgb_to_linear(emission)` and the albedo product converted once, in `scene.glsl` (a small glow is a twelfth of itself; the glTF's colour and the texel are read raw) | taken as linear: the accent emissive doubled the hero's robe, the lilac look | `DmCreatureMat` and the crowd's shader multiply in Compatibility's numbers and convert like it (`dm_s2l`, `dm_l2s`): the hero's robe (the Graves, Y of a 24 px box) 59.2 with the old shader, 43.2 without the emissive, 33.6 with the lift divided out as well |
| the exposure lift of an area on a thing that is not in the lightmap (a creature, an effect) | none: today's exposure | the lift multiplies everything the tonemapper sees, 0.8 to 2.1 times | the shaders divide it out (`dm_lift_inv`, a global: 1 / (the lift x the preset's), set with the exposure): the lift is the baked world's calibration, not theirs |
| the beyond the walls | one 420 m field of grave soil under the fog (196 tiles); the background colour past it, (7, 6, 10) | nothing drawn: black, (1, 1, 3) through the tonemapper | the field as one quad (`DmWorldBuilder.build_outside`, the soil's tint lifted by `DmCompatAlbedo`); the background colour past it is never in view (the field reaches 80 m past every area) and stays black |

**The lift of each area** (2026-10-17, on Helix's bake of all twelve areas, e8ce4fd9; Ultra, 1280x720, the mean luminance of the world region, the probe's WSTAT line: x .12 to .78 and y .1 to .72 of the frame, the hero's box left out, because today's frames carry the game's HUD
where the rebuilt client's carry none). One lift for the whole game does not fit: at the old 1.2 the rebuilt Chapterhouse was 18 % darker than today's, the Alchemist Wing 29 % darker and the Acre 3 % brighter, because every area's bake carries its own share of the light.
So the lift is a number per area (`DmWorldBuilder.AREA_LIFT`, asserted by `tests/presets.gd`), solved from each area's own response and checked by a last run at the table's numbers: the probe shot every area at lifts of 1.1, 1.5 and 2.0
(`--plan="<area>:lift=1.1,lift=1.5,lift=2.0"`), a curve through the three points in log-log gave the lift that reaches today's mean, and one run at the table (`base`, two frames each) measured the result. The response is not one power of the lift: the mean rises as lift^0.75 to lift^0.9 in the dark areas
and lift^0.6 in the bright ones (the Wing and the Coliseum, where the tonemapper presses the highlights), so the rule of thumb of one exponent (lift^0.85) would have put the Wing 8 % below today's.

| area | today | rebuilt at lift 1.1 / 1.5 / 2.0 | response (exponent) | lift | rebuilt at the lift |
|---|---|---|---|---|---|
| Chapterhouse | 45.3 | 34.3 / 44.9 / 56.7 | 0.84 | 1.52 | 45.4 (+0.2 %) |
| Acre | 52.0 | 51.7 / 66.4 / 82.4 | 0.78 | 1.11 | 52.1 (+0.2 %) |
| Alchemist Wing | 124.1 | 83.5 / 102.4 / 121.5 | 0.63 | 2.08 | 124.2 (+0.1 %) |
| Graves | 37.4 | 31.0 / 41.2 / 52.7 | 0.89 | 1.35 | 37.6 (+0.5 %) |
| Warren | 34.1 | 28.1 / 37.4 / 47.8 | 0.89 | 1.35 | 34.1 (+0.0 %) |
| Ossuary | 40.5 | 31.7 / 42.0 / 53.6 | 0.88 | 1.38 | 39.0 to 42.2 (-3.7 to +4.2 %, see below) |
| Nave | 36.2 | 30.6 / 40.2 / 50.9 | 0.85 | 1.33 | 36.3 (+0.3 %) |
| Coliseum | 127.8 | 94.1 / 114.9 / 135.0 | 0.60 | 1.80 | 127.6 (-0.2 %) |
| Sanctum | 48.7 | 40.9 / 52.6 / 65.6 | 0.79 | 1.36 | 48.7 (+0.0 %) |
| Cloister | 52.8 | 43.9 / 57.1 / 71.8 | 0.82 | 1.37 | 53.1 (+0.6 %) |
| Pyre | 57.8 | 49.4 / 62.9 / 77.3 | 0.75 | 1.34 | 57.8 (+0.0 %) |
| Fen | 44.5 | 57.0 / 71.4 / 86.6 | 0.70 | 0.80 | 44.7 (+0.4 %) |

Eleven areas are within 0.6 % of today's, inside the noise of the measurement: today's own frames repeat to 1.5 % between runs (the Acre 52.0 and 52.8, the Chapterhouse 45.1 and 45.3, the Graves 37.3 to 37.5), two frames of one visit differ by 0.3 % at most, and a second visit to the Chapterhouse, the Graves, the
Wing and the Acre (in a different order of visits) repeated the numbers to 0.1 % (the Acre to 1.9 %). The Ossuary is the exception: its ground mist drifts across the frame and is part of the mean, so a visit early in a run read 43.8 at a lift of 1.44 and 37.3 at 1.2, a later one 40.5 at 1.44 (the lift that matches the early visit is 1.33, the late one 1.44); the table's 1.38
centres them (the curve's numbers, not a run at 1.38: 39.0 and 42.2). The numbers are for Ultra on the software renderers; Medium, High and Low share them (`DmGraphicsPreset`'s own factor, 1, Low 0.96, is not measured), and the Depths, which the probe cannot stand in, keep the old 1.2 (`LIFT_DEFAULT`).

The lift is Forward+'s own, on top of today's exposure (the world's number, the area's easing, the Settings brightness). It is a property of the area, not of the preset: `DmWorldBuilder.set_area` (what the world's `enter_area` calls when the hero crosses into another area) sets the target and eases to it over
0.8 s (`LIFT_BLEND`, smoothstep, together with the area's own exposure easing, so a door is not a pop of brightness; today's change of ambient at a door is instant); `_process` runs only during the blend and switches itself off, so a frame outside a blend costs nothing, and the first area is set at once.

**The unbaked things** (the hero, the creatures, the effects) are lit by the real-time lights alone, not by the lightmap, and the first table of the lifts left them 1.3 to 2.5 times today's in seven areas and the hero lilac. Two causes, found with the probe's `HSTAT` line (the mean of a 24 x 24 px box on the hero's
robe, the same box on both sides) and its hero variants (`hnoemis`, `noamb`, `nomoon`, `norim`, `noshadow`, `noprops`, `nossao`, `hnolantern`, `hgear`): **the colours** (the table above: Compatibility converts what a shader writes to `EMISSION` and the albedo product once, so the hero's accent emissive,
0.04 of the accent, is a twelfth of itself on today's side and was most of the robe's brightness here: the Graves' robe 59.2 with the old shader, 43.2 with the emissive off, and the lilac gone) and **the lift** (an exposure multiplier calibrated on the baked world is an exposure multiplier on a creature too: the robe falls to 33.6 with the lift divided out of its albedo, specular
and emission; an effect gets the same, `DmFxTex`). The global `dm_lift_inv` is 1 / (the area's lift x the preset's), set by `DmWorldBuilder._apply_exposure`, so it eases with the blend; a shader reads it for nothing per frame. Bloom, ambient occlusion, the moon's shadow and the prop lights were tried and are not the cause (the robe's box without bloom 58.5 against 59.2, without
ambient occlusion 33.8 against 33.6, without the moon's shadow 34.5 against 34.2, with the prop lights off 33.2 against 34.2; the moon is half of the robe's light, the ambient a sixth, the lantern a sixth).

The robe now, the mean luminance of the box (today's: `today_*`; before: the table's lifts with the old shader; now: the table's lifts, the run of 2026-10-17 after; the rebuilt numbers repeat to 5 % between runs, **today's own do not**: the Graves' box is 23.9, 33.0 and 34.9 in three runs of today's game, the pose of a moving hero):

| area | today | before | now | now / today |
|---|---|---|---|---|
| Chapterhouse | 81.6 | 76.1 | 73.3 | 0.90 |
| Acre | 55.3 | 83.0 | 53.8 | 0.97 |
| Alchemist Wing | 77.8 | 111.4 | 56.1 | 0.72 |
| Graves | 23.9 (33.0, 34.9) | 58.6 | 33.6 | 1.41 (1.10 of the three runs' mean) |
| Warren | 30.5 | 60.7 | 35.6 | 1.17 |
| Nave | 20.4 | 50.9 | 27.0 | 1.32 |
| Coliseum | 82.7 | 88.7 | 46.2 | 0.56 |
| Sanctum | 26.4 | 55.2 | 29.6 | 1.12 |
| Cloister | 56.7 | 68.5 | 38.9 | 0.69 |
| Pyre | 44.0 | 57.7 | 32.7 | 0.74 |
| Fen | 39.8 | 38.6 | 34.6 | 0.87 |

(The Ossuary's hero stands behind a wall in the frame.) The mean of the absolute log error over the eleven falls from 0.42 to 0.25 (the mean log error from +0.40 to -0.09): the dark areas, where the hero was 2.0 to 2.5 times today's, are now 1.1 to 1.4 (the Graves, the Nave, the Warren, the Sanctum), the Acre and the Fen
are within 15 %, and the bright ones (the Wing, the Coliseum, the Cloister, the Pyre) are now 0.56 to 0.74: the hero is darker there than before and than today's. Not explained, and not guessed at with a table: the box is one pose, today's own frames differ by a third between runs, and the part today's bloom plays is not here (today's box without bloom is 27.3 against 34.9 in the Graves and
58.0 against 85.7 in the Chapterhouse, the rebuilt box without bloom is within 2 %: the glow is calibrated on bright things, `DmWfxBloom`, and not on the halo of a ring and a staff light on a robe). The crowd is the same material (`crowd_vat.gdshader`) and takes the same two changes; it was not drawn in the probe's frames (a rendered fight on the VPS outran the run's timeout), `tests/crowd_look_smoke.gd` is its check.

**The hero's ring and the contact shadow.** Today's ring is thin (a half-height width of 4 to 6 px at 1280 x 720) with a peak of 169 to 224 in the dark areas; the rebuilt one was 8 to 9 px wide and 244 to 255 (white, flat on top) in every area. Not the bloom (the profile without it is the same row for row: 255 against 255, 9 px), not the lift (245 and 8 to 9 px at a
lift of 1.0). `scene.glsl` shows where it comes from: Compatibility writes the exposed scene as `linear_to_srgb(radiance x exposure)` into its buffer before the post effects, so a translucent decal blends in that encoded space (its faint flanks lose most), Forward+ blends in linear light. The decal's own numbers
are today's (`tests/fx_decals.gd` proves them float for float), so the hero's decals are drawn at the strength that gives today's peak: the ring decals at `DmHeroLook.RING_K` = 0.4 of their opacity and the contact shadow at `SHADOW_A` = 0.75 (today's 0.5). Measured against the Graves, the Sanctum, the Warren and the Nave in the probe's `ring=K/S` variants (K 0.2 to 0.5, S 0.5 to 0.9): the peak is
195, 190, 203 and 187 against today's 195 to 221, 200, 224 and 169, the pool inside the ring (the mean of the 8 to 20 px inside) 44 against 45 to 50 in the Graves; the width stays 7 px against 5 (6 at a fifth of the opacity), which only the blend would change. Every other blended effect keeps its linear blend: wider and whiter than today's by the same measure ("Still not today's").

The Fen is the other way round: its baked ground is brighter than today's even at a lift of 1.1 (the mean 57.0 against 44.5, the darkest tenth 26 against 15), so the lift that matches the mean is 0.80, which leaves the ground's shadows lighter than today's (its hero is 0.87). All of this wants Helix's eye on his PC; the open causes are lines in ROADMAP "For review".

**Still not today's** (each one a line in ROADMAP "Look pass"): the Depths' walls keep Forward+'s darker tint (its floor is lifted, `DmWorldBuilder._floor_mat`) and the Depths' lift is the old 1.2; Low and Medium: today's draw blended effects in sRGB space when bloom is off (an alpha sprite half-way over black: 131, with bloom on 205), Forward+ always blends
in linear light, and at Ultra too today's ring is thinner and dimmer than a linear blend of its decal ("The unbaked things"): only the hero's ring and shadow are scaled to it, every other blended effect (the rites' decals, the telegraphs, the particles) is wider and brighter here than today's;
the gear props' emission (`StandardMaterial3D` with an energy: Compatibility converts the colour times the energy, Forward+ the colour) and the Binbun scenes' own shaders that write `EMISSION` are the same class as the creatures' and not converted, and the staff's light sprite takes the lift. The Chapterhouse's floor carries the candles' light in the new bake (warm pools by every candle, as today's), which the old bake did not.

The probe starts the real game scene at a fixed spot of each area and shoots variants of its light (`--plan`; `lift=1.5` shoots the rebuilt client at that exposure lift in place of the area's, which is how the table above was found; `nodress` takes the world dressing off, `before` is the first test builds' look: no dressing, a sphere at every light, the five-mip glow; the hero's box has its own `HSTAT` line and the hero variants are `hnoemis`, `hnogear`, `hnolantern`, `hgear`, `noamb`, `noprops`, `nossao`, `ring=K/S` and `crowd`, see the script's header), the glow part (`--part=glow --glow="name:lv=a/b,int=..;..."`) prints the glow's profile of two bright things under each setting of a list, and the calibration part prints one pixel line per test object; run it
on both projects (the header of the script has the commands; today's game takes 3 to 4 minutes to start on the VPS, the rebuild half a minute). It is not a pass/fail suite: the checked
values are `tests/areas.gd` (the pools' flag, the tint table against its textures) and `tests/presets.gd` (the twelve lifts, the blend, the environment and what the lift leaves alone). `client/tools/compat_albedo.gd` prints the tint
table of `DmCompatAlbedo`.

## The seeded scenario

Gate B's "same rules" proof (ROADMAP "Now: the rebuild", native/README.md "Proof of same game", which holds the tolerances and the results): `client/tools/parity_scenario.gd` plays one scenario in this client and writes its metrics as JSON, `godot/tests/parity/scenario.gd`
plays the same one in today's game, and `tools/rebuild/compare-scenarios.mjs` runs both, one Godot process at a time at `nice -n 10`, and prints kills, damage dealt, time to kill and thrall uptime side by side against the tolerances. Seeds 1 to 5 take about 6 minutes;
`--seeds=1-20` takes about 23 and settles a close call. The scenario is the Hollow Graves with one Gravecaller at level 10 on the kit's default loadout, Easy difficulty and Easy auto combat on (the benchmark's adapter, on the physics clock), the director's normal waves and
no rewards, for 180 s of game time. Everything is read from the host's signals and the caster's events; the game scene gets no code for it. By hand: `nice -n 10 /home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client --script res://tools/parity_scenario.gd -- --seed=1 --seconds=180 --out=/tmp/client-1.json`
(`--trace=10` prints the hero's state every 10 s; `--level=` and `--difficulty=` change the scenario, on both sides alike). `--discipline=<index>` (1 Ossuary, 2 Gravecaller, 3 Mourner, 4 Rotweaver, 11 the Reaper) and `--area=<id>` (any hunting ground but the Depths: the nine
whose kinds the core runs; only that area is loaded, its seal broken, the hero set down at its waystone) play the other disciplines and the later areas, on both sides alike: `node tools/rebuild/compare-scenarios.mjs --seeds=1-20 --discipline=11` or `--area=sanctum --level=13`
(native/README.md "Proof of same game" holds the scenarios and their results).

## The HUD on the core

Today's HUD and panels run in the game scene (`opts.hud = true`; DECISIONS B46) as today's game composes them: `DmGameUi` (`game_ui/dm_game_ui.gd`, a copy) with every panel, on the
host-contract adapter `DmNextUiHost` (`next/hud/dm_next_ui_host.gd`, ported to the core), whose view-model is `DmNextHudVm` (`next/hud/dm_next_hud_vm.gd`, ported: it reads the core's
arrays). `DmGameUi` applies the view-model every 50 ms (`HUD_INTERVAL_MS`) to today's `DmHud` (orbs, hotbar with cooldowns and the cast state, target frame, minimap, thrall pips, XP and
level, area line, banners, toasts, floating numbers, death veil). The adapter hears the core host instead of each enemy (`_watch_core`). Nothing runs per creature per frame:

| piece | where it reads |
|---|---|
| view-model refresh | `DmGameUi`'s 50 ms of wall time (`ui_host.hud_state()`): ~0.4 ms hot with a Full Party crowd and the panels' own keys merged (`tests/hud.gd`), about 0.9 ms in the fight with the caches cold; "The HUD's budget" (CPU) says what that costs a frame |
| orbs, XP, level, area | the hero body (`hp`, `resource`), the character, `DmContent` |
| hotbar, cooldowns, cast state | the hero's `DmRiteCaster` (`cooldown_left`, essence, souls); the player's loadout (`DmLoadout`, the Grimoire's) |
| "no corpse" / "no legion" dimming | one `core.corpses_in_radius` (13 m around the hero) and `core.thrall_count` per refresh |
| target frame | `core.enemy_info(id)`, `core.statuses(id)` (4 bytes a status: id, stacks, tenths of a second) for the one enemy under the cursor or last aimed at (held 4 s, `ui_host.target_id()`); chips from its affix list |
| minimap dots | `enemy_ids / enemy_positions / enemy_states`, `thrall_positions / thrall_states`, `corpse_positions`: flat arrays, filtered in one pass into the packed lists the minimap takes; an elite is flagged from `enemy_spawned` |
| thrall count, pips, red pips | `core.thrall_places`, `thrall_owners / thrall_hp / thrall_states` (under 35 % health) |
| floating numbers | the caster's `hit_number` (the rites' own events, with the impact point), the core host's `enemy_damaged` of a thrall and `status_dot`, the hero's `hurt`; `DmFloatBudget` caps them (14 hit, 5 dot, 6 thrall, 22 in all, a crit 4 past); a guest's window below |
| boss plate, minimap dot | `g.bosses.active_boss()` (name, phase, hp; the King's dot on the map) |
| notices | today's `DmAreaFlow` (an area's first entry, a themed wave), a refused cast (an "info" number over the hero), the boss fx's banners and the summon refusals: all `DmNextGame.game_event`, which reaches `DmGameUi` |

**A guest's window.** In a party the HUD hears the same events from what reaches the guest. The numbers of both heroes' rites (crits too) are `hit_number` on every peer, from the rites' events the host broadcasts; an enemy's hit flash is the crowd's, from the
puppet core's `damaged` events (derived from the snapshots' health); a DoT's lumps are `status_dot` (they ride the reliable batches). The guest's own hero's hurt is the fall in the vitals the host sends at 20 Hz: `DmHeroBody.apply_vitals` emits `hurt` for the health a
body that was alive lost while its maximum stayed the same, once per message (blows within 50 ms are one number with the sum; a blow that killed is the health it took, where the host's counts the overkill; a heal, a respawn and a new maximum are none), and the HUD binds it as
it binds the host's own: a number over the hero, the red flash, the hurt sound, the low-health sound under 30 %, the counsel's hurt flag and tip. An enemy's drag of the guest's hero is told by `DmNextNet.hero_effect` ("Dragged!" and the camera shake; a chill and a root are
statuses, which replicate). No work per frame: all of it is events. Not shown on a guest: a thrall's blow number over an enemy except the killing blow (the puppet's `damaged` has no source). Today's guest shows none of the hero's hurt and no DoT number
(`hurt` and `enemy_effect` are host-only signals there, and the status set ticks on the host only): native/README.md "Differences from today's game". `tests/coop.gd` ("the guest's window") counts each of these on both HUDs and `tests/coop_bosses.gd` the guest's hurt in every boss fight.

The upgrades box (Empower, Quicken and the wave dial), the belt (Q, Z, X), the Kill Chain, the Omen, the save chip and the pickup lines come with value ("Value on the server"); the menu row, the
panels and the Social window with `DmGameUi`. Not in the game scene yet, each with its system: the Altar (DECISIONS B36). The hub's prompts (the Chapterhouse node's hover and nearby lines) and the Depths readout, minimap floor and area line are in. The Acre ledger's panels (Skills, Garden, Laborers, Contracts) and the node and laborer cards are in ("Gathering and the Acre"). `tests/hud_feeds.gd` (`HudFeeds.full()`) fills every view-model key for the
tests that draw every piece.

**Pieces (DECISIONS B40).** Every readout group is a Control of its own with its own anchors and offsets, listed in `DmHud.pieces` (`party omen ward chain belt target boss map toasts banner prompt hint chat xp altar
upgrades`). `set_piece(id, offset, scale)` moves one by `offset` logical pixels and scales it (0.5 to 2) around the corner its anchor holds (a piece anchored to the top right grows left and down, the hotbar up and
sideways); `set_layout({id: {offset, scale}})` applies a saved layout (a piece it does not name goes home); `show_piece(id, false)` hides one for good; `set_hud_scale(0.75 to 1.3)` scales them all at once, as
Settings did. The game scene takes `opts.hud_scale` and `opts.hud_layout`. There is no editor: this is the structure it will need.

### The HUD's budget

DECISIONS B39: the HUD at most 0.5 ms and 150 draw calls on Helix's PC. Today's HUD was about 550 draw calls (the benchmark's Compatibility numbers: ROADMAP "Before numbers"). In Godot 4.7's canvas renderer
(`RendererCanvasRenderRD`) consecutive commands that share a texture and a kind are ONE draw call, and a rendered run measured what is not (Forward+ on lavapipe, 2026-10-16; `tools/hud_measure.gd --micro`):

| drawn with | draw calls |
|---|---|
| rectangles (`draw_rect` filled), any number, in any items; lines (`draw_line`, thick or anti-aliased too) | 1 together |
| icons of one texture or of regions of one atlas, with any colour; 9-patches (`StyleBoxTexture`) of one texture, other regions and colours | 1 together (a different texture, or a rectangle between icons of another texture, starts a new one) |
| glyphs of one font and size, with or without a shadow; a Label with an outline: its outline and its fill | 1 together; 2 for every outlined label (the outline has an atlas of its own) |
| `StyleBoxFlat` panel (fill, border, radius, shadow: any) | 1 each |
| `draw_circle`, `draw_colored_polygon`, `draw_polyline` (3 when anti-aliased), `draw_arc` (3), `draw_rect(filled = false)`, a RichTextLabel, an item with `clip_contents` | 1 each |
| `clip_children` (the minimap's disc) | +2 and its inside as above |
| items with different `z_index` | sorted by z first, then tree order: the same kinds of drawing on one z layer batch even when their controls are far apart in the tree |

What the HUD does with that (`ui/hud/dm_hud_kit.gd` has the layers, `next/hud/dm_hud_atlas.gd` the atlases; all of it keeps the look):
- **Layers.** Panels (9-patches) z 0, rectangles and icons 1, vector art 2, rectangles over the art 3, text from 4 up (one layer for each font and size), toasts, banner and prompt +100, the floating numbers 200.
  A HUD label is put on its layer when it is made; `DmHudKit.layer_tree` does the rest of a subtree.
- **One atlas.** A runtime atlas holds every icon (ability art is kept at 128 px, shown at 62), a white block (any rectangle), the bars' gradients and, on a page of its own, every panel's 9-patch (`DmHudKit.plate`
  makes a `StyleBoxTexture` of the picture of a `StyleBoxFlat`; `style` still gives the StyleBoxFlat the copied panels ask for). A greyed slot icon is a baked variant, not a shader.
- **One mesh per widget.** The orbs (2 draws), cooldown sweeps (5 triangles at most), thrall pips and gems (one mesh for the row), the level badge, the minimap's frame, disc and edge fade, its marks and arrow, and the
  death veil are triangle bags (`DmHudMesh`); the minimap's dots are one MultiMesh.
- **Floating numbers are a pool** (`DmHudFloats`): 48 entries of two canvas items made once; a frame only moves them; the numbers of a kind are two draw calls.

*Measuring.* `tools/hud_measure.gd` starts the game scene with the full HUD in a Full Party-like crowd (72 enemies, 32 thralls, numbers kept at their caps), reads
`RenderingServer.get_rendering_info(RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)` and the canvas share of it with the HUD hidden and shown, as the game scene shows it and with every piece on, prints the HUD's CPU cost, and
(`--micro`, `--fidelity`, the breakdown) the cost of each drawing primitive, the pixel difference of each replacement against the original, and each piece alone. It writes one JSON line per measurement as it goes:
```
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 xvfb-run -a -s "-screen 0 1600x900x24" \
  timeout 55 /home/ubuntu/tools/godot/godot --path client --rendering-driver vulkan --resolution 1280x720 --fixed-fps 60 --script res://tools/hud_measure.gd -- --out=<file.jsonl> [--shot=<png>] [--micro] [--fidelity] [--3d]
```
**Status (2026-10-17): measured on Helix's PC** (RTX 4070 SUPER, 2560x1440, the benchmark's render breakdown, the Bell Sanctum's Full Party with the panels in): the HUD row draws 120, 120 and 117 calls on Low, High
and Ultra for 0.03 to 0.05 ms of GPU, and the HUD's share of the main thread is 0.07 ms (eight on/off rounds). The model's 63 to 81 counts the HUD alone; the rendered row also holds the panels' pieces. Before that
(2026-10-16) the budget was only modelled: on this VPS a Forward+ process needs ~21 s to reach its first script line and then ~23 s inside the first main-loop iteration (software
Vulkan pipelines; it did not shrink with drawing switched off), so a 55 s run has about ten seconds left. The three runs allowed for this item produced the table above (the first, a bare scene) and nothing from the game scene
(the later two reached the end of the scene's build at 50 s). The harness still runs with a longer limit (`timeout 180 ... --budget=170`) for a look at single widgets.

*The model.* `tests/hud_cost.gd` is a model of the batching rules in the table; `tests/hud.gd` first checks that it reproduces the 18 numbers the rendered run counted for the same trees, then asks it about the HUD in a Full Party fight
(72 enemies, 12 thralls, casts on cooldown, a target with four statuses, toasts, numbers at their caps): 63 draw calls as the game scene shows it (26 text, 10 vector art, 8 floating numbers, 6 toasts and banner, 3 panels, 1 rectangles
and icons, 1 borders) and 81 with every piece on and fed (41 text, 13 art). The test fails above 150, so a control left on the wrong layer or a new polygon per thing shows up in CI. Asked about logged copies of today's widgets in the same
fight the model said about 500 for the game scene's HUD (the hotbar 188, the minimap column 160, the floating numbers 104, the target frame 18) and 630 with every piece on; the benchmark counted 544 to 564 for it in Compatibility. What looks different from today's HUD, piece by piece: native/README.md "Differences from today's game", "The HUD".

*CPU.* The HUD's work on the main thread is of two kinds. **Per frame:** what animates (the orbs' ripple, 15 times a second, the floating numbers, the counsel's card, the cooldown edges and sweeps) and the panel host's clocks
(counsel, guidance, cues). **Per refresh:** the view-model build and its apply, every 50 ms of **wall** time (`DmGameUi.HUD_INTERVAL_MS`, 20 Hz), so a refresh falls on every 12th frame of the VPS's 4 ms headless frame, every 5th
of a 10 ms frame (Helix's 99 fps) and every 3rd at 60 fps. It costs about 1.5 ms in the Full Party fight (the caches cold: 0.4 ms hot in `tests/hud.gd`), which is 0.12 ms a frame on the VPS, 0.3 on a 10 ms frame and 0.5 at 60 fps:
**the VPS's share leaves most of the refresh out**, and Helix's PC pays it in full (the ROADMAP's Helix's PC item measures it there).

What the share was and is, on this VPS in the Full Party fight (2026-10-17, main at d625161f; `--benchmark --bench-room=graves --bench-size=full_party --bench-class=2`, headless, `--fixed-fps 60`, a new character with its tips).
The benchmark's own HUD readout is eight rounds of half a second (give or take 0.3 to 0.85 on a busy machine), too coarse to tell 0.45 from 0.55: five runs of each build alternated read **0.88 to 1.97 before (median 1.07) and
0.15 to 0.67 now (median 0.51)**. The same on/off rounds, seventy of them, in CPU time with the slowest 3 % of frames left out (give or take 0.1 to 0.15 each), builds alternated: **0.96 to 1.01 before, 0.42 to 0.57 now** (four
runs; 0.37 to 0.63 over every run of the last three versions on a machine with a load of 5 to 15). The rest of the main thread in the same fight went from 3.4 to 4.6 ms to 3.0 to 3.2 (5.7 in one busy minute). `tests/hud.gd` hot (three runs each): the
refresh's build 0.44 to 0.51 ms before, 0.36 to 0.48 now; its apply 0.15 to 0.18, now 0.11 to 0.14; a headless frame with the HUD 0.41 to 0.55 ms over one without, now 0.21 to 0.41.

Where it went, and the rules that keep it there (every `_process`, `_draw` and the refresh's parts timed in a scratch copy of the project, never committed; a call costs two to four times in the game what it costs in a loop,
because the refresh finds its code and data cold):
- **An animation that only changes an alpha is a layer drawn once and faded by `modulate`:** the NEW glow's halo (three on a new character), a hotbar slot's empowered pulse and its cast flash redrew 24 and 16 rectangles every
  frame (0.15 ms of the fight: 80 us for the glows, 65 for the slots' edges); a frame now sets one property for each, and a layer is drawn when it is shown. Same rings, same strength at every instant. The low-health wash
  processes only while it moves.
- **A rite on cooldown changes its seconds and its sweep and nothing else** (`DmHudSlot.apply` compares the slot with the last one natively and takes a short path when only `left_ms` differs).
- **Static art appended to a mesh is moved to its place once per place** (`DmHudMesh.append`): the orbs' gloss and dish were re-indexed by a loop over 1,150 indices at every redraw.
- **Sections:** `DmHud.apply` hashes each section's keys and applies a section that changed. The Kill Chain meter moves with every refresh while a chain runs, and the belt, omen, party and ward shared its section: they are
  sections of their own now, so a moving meter applies none of them (and redraws no belt chip).
- **The panel host asks nothing it can keep:** `panel_open()` (asked by the counsel and by the combat input a dozen times a second) answers from a flag the windows' own visibility changes set; `area_safe()` per area; the
  Ascension guidance asks the Prelate count before it builds a progression and keeps the Swift Seals share and the parsed trophies until their sources change; the belt's chips count the bag in one pass and only when the bag
  was replaced, a pick changed or the vows did (it was thirty passes, 0.2 ms of every refresh); the view-model looks the hero's caster, soul state and rite level up once a refresh; `DmHudKit.commas` keeps the text of the
  numbers it formats.
- **The counsel (a new character's tips: a card up, ten waiting) costs about 80 us of the frame in this fight, a veteran's with the tips seen about half of that:** the first-thrall card asked `hud_state()` whether a thrall lived, a whole view-model
  (a millisecond) every time the line was looked at; it asks the host's `thralls_now()` now. The line is looked at five times a second: a card on screen is only compared with the urgent and danger tips waiting (the only
  ones that can take its place), the clock waits for the earliest timer instead of scanning them every frame, and the poll reads the bosses' summon sites and the doors' rects once. The card's draining line (24 rectangles
  every frame) is drawn once on a canvas item of its own and squeezed by that item's transform (`DmTipCard.show_timer`).
- `tests/hud.gd` pins these (no redraw per frame for a pulse or the line, the strength at every instant, the short path against a full apply, the kept indices, the sections, the counsel's timers), `tests/panels.gd` the flag
  and the guidance, `tests/value.gd` the belt chips against the bag.

What is left by the same timing (us a frame at the VPS's refresh rate): the refresh 100 (its slots 27, minimap dots 17, target frame and party 10, belt 6) and the minimap's draw 22, the orbs 56 (the ripple's mesh at 15 Hz,
60 to 75 us a build), the counsel 80 of which the card 20, floats 17, the panel host's clocks 25, the pulses 15; and about a third of the A/B share is not in any script callback (text shaping and redraws the refresh
starts, and the caches its working set empties for the rest of the frame). Next in line: the minimap's dots and the hotbar's fill in the core (`enemy_ids / enemy_positions / enemy_states` already are its arrays: about
0.25 ms of every refresh, 0.05 ms a frame on a 10 ms frame), and the orbs' ripple.

## Tips and onboarding

The counsel is today's: `DmCounsel` (the tip queue in `ui/onboarding`: kinds, groups, places, cadence, the card and its glow), owned by `DmGameUi`, ported only in how it waits ("The HUD's budget", CPU: the clock waits for its earliest timer, a card on screen is compared with the urgent tips alone, the card's line is drawn once), fed through `DmNextUiHost.game_event` and polled every
400 ms; `data/onboarding/tips.json` has the 120 tips and `DmCounselEvents` the table from a fact to its tips. What reads creatures is the counsel's host side, `DmNextCounsel` (ported), and the few facts the old
per-enemy hooks raised. Neither has a node or a call per creature: both are the core host's events and one timer.

| fact | where it comes from | tips |
|---|---|---|
| a body spawned within 40 m (`enemy_spawned {def, elite, near, area_safe}`) | the host's `enemy_spawned`, once for each, in `DmNextUiHost._on_enemy_spawned` | the kind's first sight, move, elite, deacon |
| a corpse laid (`corpse_near {area_safe, dist}`) | `corpse_added` | exhume (within 12 m, outside a safe place) |
| a Deacon blessed a body (`sanctify_near {dist}`) | the `sanctify` cue | sanctify (within 18 m) |
| the hero hurt (`hurt_check {hp, max_hp}` each blow, the `hurt` tip below half health) | the hero's `hurt` signal | hurt |
| a cast refused for essence (`essence_short`) | the caster's rejection | essence |
| a fight: three living dead within 9 m of the hero, or the boss awake | `DmNextCounsel`, on the poll | holds calm tips back (`busy.combat`); the Grimoire's rune swap (`in_combat`) |
| corpses within 7 m, a pack of three on a corpse, the thralls he owns | `DmNextCounsel`, on the poll | thrall, litany, burst |
| kills, shards, gold, the bag, a boss site or a closed door near, the unlock set | the progression and the bag, on the poll (today's code) | codex, wave, prelate, belt, tool, boss sites, gate |

`DmNextCounsel.tick_ctx` (DmGameUi's 400 ms timer) asks the core: one radius query for the fight (the core measures to the edge, which finds everything the centre test finds, so a candidate is confirmed by
its centre as today's was: a rising or burrowed body counts, a dead one does not), `corpses_in_radius` for the corpses and, for each, one more query for its pack, `thrall_count` for the legion: 0.18 ms a poll with
72 bodies and 30 corpses around the hero (`tests/counsel.gd`, INFO). The busy flags (`counsel_busy`, 10 Hz) are two time stamps and the hero's `alive`.

**The first hour.** `world_entered {family, level, grimoire_unlocked}` is raised once at the end of `DmNextGame.start` (the welcome tip; from level 10 the signature, with the Grimoire unlocked the Grimoire tip).
The welcome tip is a tip of the Acre (`HERE` in the tips data), so a new hero meets the belt's tip first (the bag's flask) and the welcome when he walks into the Acre. The Next-step box (`DmGuidanceHud`), the
Prior's greeting and advice (`DmCovenantDialogue` over the same `guidance_state`), the HUD's progressive reveal, the NEW cues, Settings' "Show tips again" and "Don't show tips" (kept with the account) are
`DmGameUi`'s and run as in today's game; a party joiner whose kills the backend will not credit is told at the end of `start`. Not today's: the poll says `altar: false` (`DmCounselEvents.tick_calls`, ported),
because the build has no Altar of Ascension (B36), which holds back the vows, altar_unlocks and boons tips; `can_ascend` (the Prelate's fall, the bosses item) must stay unraised too. Off until their items: the
Depths' tips (`depths_*`), the Grave Surge tip, gathering's and the Acre's (`gather_started`, `skill_up`, `bag_full`, `laborers_seen`) and the other bosses'; `omen_told`, `set_bonus_gained`,
`necro_weapon_changed`, `loadout_check` and `depths_solo / floor / affix` are not raised by today's game either (godot/ui/onboarding/README.md).

`tests/counsel.gd` plays it on the whole world as a new Gravecaller: the poll against a brute-force reading of the core's tables (24 seeded placements, and the edges by hand: bodies whose edges are within 9 m and
whose centres are not), every fact above through the real scene with the events compared with today's, each tip queued and shown once, the state-driven tips one fact at a time, the welcome held for the Acre, the
Next-step box, the Prior, the reveal, an area's first entry, no Altar tips, Show tips again and Don't show tips.

## Sound

Sound is today's: the `AudioDirector` autoload (`audio/`: its map, mixer, beds, music and footsteps; godot/audio/README.md) and the cues the game plays through it. On the core the cues come from its events, never from
a node per creature, through the same router and the same ids (no sound was added):

| cue | where in the rebuild |
|---|---|
| an elite rising within 40 m (`eliteAggro`), every telegraph (`tellStrike`; `tollSmall` for the cone and the toll; `raise`; `curse`), a swing landing (the attack voice within 18 m; `boneHit` for a slam), the ghoul's eruption (`burst`), a death (`enemyDeath` or `eliteDeath`; the death voice within 26 m) | `DmEnemyFx`, from the host's `enemy_spawned`, `telegraph`, `enemy_attack`, `enemy_state` and `enemy_died`, through `DmEventFx` |
| the affixes: the bell's toll (`toll`), a meal (`raise`), the vengeful's burst (`burst`) | `DmEnemyFx._on_affix_moment` |
| a thrall standing up (`thrallRise`), one killed (`thrallDeath`; not one that crumbled, was sacrificed or decayed) | `DmEnemyFx`, from `thrall_raised` and `thrall_died`; a guest's puppet core raises the same events |
| the hero hurt (`hurt`, `lowHealth` under 30 %), `buy`, the pickups | `DmNextUiHost`, `DmNextLoot` |
| the rites | `DmRiteFx` (copy), through the caster |
| the listener, the area's bed and score, the hero's footsteps (the walk loop's phase, the area's surface, water where he wades), the gate | `DmAudioHooks` (ported, a child of the game scene) |
| the boss score and the boss sounds | `DmBossHost`, `DmBossFx` |
| the panels, the counsel's card | `DmGameUi.sound`, connected to the director by the game scene |

Ported: the hooks' gate sound is the world's `door_opened` signal (a door rose: at the door's centre; silent for doors that rise while the world loads, before the hooks' first frame), where today's polls every door
each frame. `DmEnemyFx` forgets a swing when its body leaves alive (a boss's adds go with him), as today's slot went with the node. Everything is gated by `opts.audio` (on in a player's window, off headless).
Every kind on the core has its sounds (the router plays the tells; the Templar's shield glance, `tollSmall`, and the Acolyte's Unbind, `raise`, are cue sounds of `DmEnemyFx._on_cue`). Off until its item: the Depths'.

`tests/sound.gd` puts a recording stand-in where the director is (every call logged, passed on to the real one where a check needs it) and plays a scripted fight in the Graves, the hero standing still and not able to
fall, against the cues today's code plays for the events the core raised, by name and count (the expectation is written from today's `dm_enemy_fx.gd`, `dm_event_fx*.gd`, `dm_thrall.gd`, `dm_affix_set.gd` and the ui
host; a swing within two ticks of landing or of what ended it may count either way); then the thralls at their places and only the killed ones' death, and the hero's world on the real director: footsteps, the beds
and scores of four areas, the gate, the boss score with the King.

## Threads

A worker computes data and hands it back; whatever touches the scene tree, a node, a signal or a Godot object that is not thread-safe happens on the main thread, after the worker has finished. The places that take a worker's result call
`DmThreadGuard.assert_main` first (a violation is an error in the log and a count the suites check is 0: `tests/depths.gd`). `tests/threads.gd` lists what starts work off the main thread and fails on anything new until it has been read and added here; the C++ core starts no thread, lock or atomic.

| what | thread | touches | result |
|---|---|---|---|
| the Depths' floor generator (`DmDepths._generate`) | a `WorkerThreadPool` task | content (read only once `DmDbWarm` has run) and its own arrays | polled on the physics frame with `is_task_completed`, joined, the Dictionary returned to the controller |
| the Depths' navmesh bake (`DmDepthsGround.prepare`) | the navigation server's pool task (`bake_from_source_geometry_data_async`) | the source geometry and the `NavigationMesh` handed to it, which the main thread leaves alone until `is_baking_navigation_mesh` is false; the server emits `changed` in its own main-thread `sync` | the mesh goes on the region (`show`) on the main thread; a bake that does not finish in 20 s is made again on the main thread on a fresh mesh |
| the Gear Atlas' verdicts (`DmUiPanelsA._atlas_*`) | a `WorkerThreadPool` task | a deep copy of the stat context, a fresh map of what is owned, and the static tables the first main-thread pass filled (`tests/threads.gd` checks a worker writes none of them) | joined in `_atlas_data` or `tick` before the result is read |
| a legendary body's prefetch (`DmGearModels.prefetch`), the sample bank (`DmSampleBank`, twelve in flight), the warm-up's models (`DmNextWarmup`, not headless) | `ResourceLoader.load_threaded_request` | resources only, no node | `load_threaded_get`, or `load` from the cache, on the main thread |
| the mixer | the audio driver's thread (the Dummy driver in a headless run) | the bus layout and every playing stream, under the audio lock | n/a |

**Data the workers read.** `DmDbWarm.all()` (`DmNextGame.start`, in loading) reads every dataset and projection of `DmDb` once, so its cache never changes again: a Godot Dictionary is not safe to read on one thread while another inserts, and a first use of a dataset
is an insert. About 100 files, 4.6 MB; +60 ms in loading (3.37 s without, 3.43 s with, three runs each alternating on the shared VPS, spread +-0.25 s). The Depths' floor generator calls `DmDbWarm.all()` (a hundred lookups when warm) and `DmSimData.ensure()` before it starts.

**The mixer.** `AudioServer.add_bus` and `set_bus_send` edit the bus list, the name map and a bus's send without taking the audio lock (Godot 4.7.2 `servers/audio/audio_server.cpp`), while the mixer thread reads all three in every mix step (`bus_map[bus->send]`). An edit that lands
in the middle of a step can crash the mixer thread (the one crash log with frames, 2026-10-07: the Dummy driver's loop, then the step's lookup of a bus's send in the name map). The director makes about 55 buses at start, while the mixer already runs (`AudioDirector` is an autoload), and changes a voice's send as sounds play. Its two helpers `_add_bus` and `_set_bus_send` (today's game has them too since 2026-10-17: the file is a copy again) hold
`AudioServer.lock()` around an edit (the lock is recursive: `set_bus_name` and `add_bus_effect` take it themselves); nothing else in the client edits the layout (`tests/threads.gd`).

**Reading a crash.** A crash on any thread but the main one prints, just before Godot's `handle_crash: Program crashed with signal N` and its C++ frames, `ERROR: /root: The caller thread can't call the function propagate_notification()`. That is not code touching the tree: the crash
handler tells the main loop, the scene tree hands the notification to `/root`, and the call is refused off the main thread. Then the process aborts (exit 134, SIGABRT) whatever the signal was. (`OS.crash()` in a `WorkerThreadPool` task prints exactly this.) The signal and the frames are the
crash: `start_thread` at the bottom is a pool, loader or driver thread, and a GDScript backtrace under the message names the script that thread was running, if any. `compare-scenarios.mjs` keeps such a run's whole output and says so. The official binary has no symbols; the frames can
be told apart by what they call (a function that takes the audio mutex, calls `clock_gettime` before and after, then `delay_usec` is the Dummy driver's loop).

## Value on the server

The backend owns value (DECISIONS D1, B20, B32), and the game scene on the core earns it through today's code. On the host (`DmNextGame._start_value`, under the loading cover):
- **Rewards** (`next/rewards/dm_session_rewards.gd`, a port): a kill is the game's `kill_credited` (the core's EV_ENEMY_DIED, credited once, to the hero who struck it or the owner of the thrall
  whose blow it was), not each enemy's `died`; everything after it is today's code: who earned it (alive, within 38 m), the Kill Chain for the killer, the loot roll from the member's drop tape,
  the gold pool, and the numbered kill reports of the backend's party session, whose replies decide the XP and kill counts applied. Lifesteal hears `DmCoreHost.struck` (a hero's direct blow
  through `damage`; a DoT tick or a thrall's swing never is one). A boss's defeat pays through `on_boss_defeated` (the boss host calls it).
- **Meta, milestones, Chronicle, progression** are today's (`next/meta/dm_next_meta.gd` and `next/areas/dm_wave_milestones.gd` ported, the Chronicle and `DmNextProgress` as they are but for the
  bag): difficulty, the week's Omen, Soul Harvest, the Kill Chain, the level-ups, the upgrade tiers, the belt, and the saves through
  `DmProgressSync`. The host's world (its difficulty) reaches the lobby (`DmNextParty.sync_world`).
- **No Ascension** (DECISIONS B36): a character's saved vows, boons and Ashes stay on the server, untouched, and do nothing here: the world runs without vows (no heat,
  the rewards' rank 0, the base corpse lifetime), a build reads its progression without them (`DmNextGame.without_ascension`), no Covenant Boon acts (the Bonded Dead
  do not rise) and the party's world carries no heat.
- **The loot node** (`next/rewards/dm_next_loot.gd`, the client's own: today's take, pickup, claim and rune-ownership paths of `DmNextUiHost`, standing on their own so value works before the
  panels): a click on a drop walks the hero there and takes it on arrival (loot never flies; walking over it takes nothing); a drop rolled from the tape is claimed, and the server puts its
  own roll in the bag; a rune the character owns (learned, bag, Vault) never drops. The bag is the server's rows (`DmInventory`); worn gear feeds the build, and the belt drinks from it.
- **The HUD** reads the member's progression (level, XP, gold, shards, tiers), shows the upgrades box and the wave dial by today's rules (`DmHudReveal.veteran_reveals`), the belt, the Kill
  Chain, the Omen and the save chip, and the toasts, banners, floats and pickup lines of `DmNextGame.game_event`.
- **Saving:** `flush_all` (leave, the window's close) ends the party session with its last batch and flushes the Chronicle, the progression and the bag.

**A party guest earns on its own account** (DECISIONS B22, today's handshake in `DmNextParty`): the host makes it a rewards member (its character id, remote, rolling its own
drops), its `DmNextJoiner` (`next/party/dm_next_joiner.gd`, ported for the bag) joins the host's backend party session with the guest's own token and holds its progression,
saves and drop tape; the host reads the guest's build from the server (`remote_builds`: gear, sets, boons, vows, runes) once it joined and whenever its worn gear changes; the
host's accepted reports, gold, shards and drop events go to the guest, which rolls its items from its own tape and claims them into its own bag; its belt drinks from its own
bag and the host applies the drink.

**Ground drops between members** (ground.cjs): the Reliquary's Drop (`DmNextUiHost.drop_gear`) puts a piece on the party session's ground; the party draws it for the members the server
lets take it (`DmNextParty.share_ground`), the first pickup wins (`DmNextLoot`'s claim, `api.ground_pickup`) and the other copies go (`share_taken`). A rune's or a legendary's find is a
chat line the party reads (`DmNextParty.announce`).

The Covenant Seal's altar choice and the boss key prompt (`DmBossMeta`) are in ("The bosses").
`tests/rewards.gd` replays today's `godot/tests/rewards` on the port (a test double emits `kill_credited`); `tests/value.gd` plays the game scene on the mock: kills through the core, the accepted
XP and counts against the server's counters, the purse, a drop claimed into the bag, brews and lifesteal, the meta, Q's flask, and the save on leave.

## Gathering and the Acre

Gathering (the nodes of the world, the professions, AFK) and the Acre (the Grave Laborers, the garden, the Sexton's contracts) are today's code on the game scene (DECISIONS B43, B46): the rules, the loop, the
value path and the panels are copies, so a live fix reaches them with the sync. The rebuild changes where the pieces stand, not what they do.

| piece | here |
|---|---|
| the nodes | the 68 of `world.json` are props of the area scenes (group `GatherNodes`, one holder named by the node's id, placed and turned as the data says). `DmNextWorld` hands the lights-only builder their holders (`node_views`) and each area's root (`area_nodes`), the two members the copied `DmNodeViews` reads. It swaps a node between its live look (the scene's prop) and its spent look (the pipeline's spent model, built the first time a node is spent, or the stand-in), draws the hover and selected rings and the progress arc under the hero, and makes a rich node a little bigger with a glow disc |
| the Gather node | `DmNextGather` (a copy; child `Gather` of `DmNextGame` on every peer at the same path, made right after the session starts so a guest has it before its relay hold is released). The host runs the loop for its own hero, owns each node's yield (`1.5 x` for a rich node) and respawn clock (half for a rich node) and credits through the backend; every peer holds the spent set, replicated as the host's RPCs (`_rpc_state`, and `_rpc_full` for a joiner) |
| hover, click | `DmNextInput` asks the node 10 times a second (`hover_at`) unless a station or a person is under the cursor; a click that is not on a drop, an enemy, a station or a person walks to the node (`click_at`). Cost: the nodes of the current area within 26 x 22 m of the hero, about 0.1 ms a pick; nothing is built by hovering |
| a cycle | `ticks x 600 ms` (the node's `ticks`; 2.4 s for a first-tier node). The client rolls each cycle for feel (the gesture, the floating XP, the sound); a success takes one off the node's yield; at none the node is spent (its model swaps, the card says "Spent. It will return soon.") and Auto (the Settings toggle, on by default) walks to the next live node of its kind or waits beside it for the respawn; Auto off ends with "The X is spent." |
| the server | the cycles go to `POST /api/gather` in batches (8 s, 40 cycles, or when the work stops), after the bag is saved. The server decides what was found, the XP and the level from its own dice and its time budget (a burst of 3 beyond what the time allows, 1,800 cycles an hour); the client adopts its answer: the bag, the professions (`skills.adopt`), the gold, the Chronicle's `gathered.<skill>` count, a "Found: ..." toast for each extra, the level-up banner and the counsel's `skill_up`, the rare-find banner for a pet charm. A refusal is shown in the server's words and the cycles are dropped; offline or a 5xx keeps them and tries again 10 s later. The client's own rolls never mint a thing: cycles it rolled as failures are paid too |
| stops | walking by hand, a click on the ground, a panel, a rite, death, a full bag ("Your bag is full." before it starts); a level the skill has not reached is refused in the rules' words ("Requires ...") and GM mode opens every tier to the client's gate |
| AFK | from the Skills tab (P), in the Acre only ("Visit the Sexton's Acre for safe AFK gathering."): `begin_afk_gather`, then the loop with no burst; stopping shows the report (`gather_report`) and keeps the best session in the counsel store under the original key |
| the Acre's glue | `DmNextAcre` (ported, one line: it reads the world's lights-only builder where today's reads the game's; child `Acre` of the host, with the real HUD) is the host object `DmLaborerViews` and `DmGameLabor` talk to: the garden check 4 s after the game is ready and every 60 s ("N plots are ready / still growing in your garden (U)"), the labor check 6 s after and every 5 min ("Your laborers have gathered about N finds (H)" after 30 minutes of work, "A laborer has filled up"), the panels' results (`on_labor_collected`, `on_garden_result`, `on_contract_delivered`: the gold the server paid, the Chronicle, the report hung under the laborer, "Harvested N x ...", "Grave Gardening N", "Order filled"), and the feeds the Sexton and the Next box read (`labor_summary`, `contract_summary`, the skills' levels, the bosses beaten) |
| the panels | the Acre ledger (Skills P, Garden U, Laborers H, Contracts), the AFK report and the node and laborer cards are today's `DmGameUi` panels, warmed with the others (`DmNextGame.WARM_PANELS`); `DmNextUiHost` forwards their calls to the Gather node and the Acre |

**The Grave Laborers are views, not bodies of the core.** Up to four pooled `DmCreature` models (the legion's art, `skeleton_thrall` and its kin) stand at their posts in the Acre and chop, dig or fish; each is a full skeleton with
a tool in its hand, none is a thrall of anyone's legion, and none exists outside the Acre: they are made on the first visit and hidden, not updated and not fetched anywhere else. A crowd goes in the core's arrays; four
characters are the same kind of thing as the hub's three people, so they stay nodes, and the count is capped by the labor rules (`DmLabor.MAX_SLOTS`, 4). A laborer competes with the nodes for the hover by screen distance
(an 18 px bonus), and a click on one opens the Laborers (H).

*Cost.* An idle frame of the Gather node and the Acre's glue is about 4 us (`tests/gathering.gd` prints it): the Gather node accumulates a clock, ticks at 10 Hz (the views' pulse, the loop's update), and while a loop runs it ticks every frame for
the progress arc; the respawn check runs at 4 Hz only while a node is spent; the Acre's glue is three timers and, in the Acre only, up to four laborers within 48 m. No node or script exists per creature, and nothing is scanned across all nodes.

*Tests.* `tests/gathering.gd` plays it on the local mock with a game clock the mock follows (the whole world, the HUD and panels, no real server): the nodes in the scenes and their views, all 68 hovered and clicked (a level refused in the
rules' words), a node worked from the click to the server's answer and to spent and back (the walk, the cycle's length, the batch, the bag, the XP, the Chronicle, the respawn), the stops, Auto off, the server's dice
(a level-up, the extras, a charm, the burst, a spent hour), AFK and its report, the laborers (none built outside the Acre, three at their posts, the hover card, a click, three hours of work, a collection with its gold), the garden (plant,
harvest, a level), a contract, the Sexton's greeting and the guidance feeds. `tests/coop.gd` checks that a node the host spends is spent on the guest.

*Differences, and gaps kept from today's game.* A node's live look is the area scene's prop, which the lighting bake lit; its spent model is built at run time, so it is lit by the area's real-time light and ambient, and the bake's light of the live model
stays on the ground around it. Never looked at on a GPU. The laborers' models are first built on the first Acre visit (`DmNextWarmup` does not draw them yet, so the first look at their materials on a GPU is unmeasured). Gathering is the host's, as today: a guest holds the nodes and their views but has no loop (its character has no backend api on the host), so it cannot gather, and it does not see the host's laborers or the tool in
a gatherer's hand. Cycles worked in the last 8 s before the window closes or the player leaves are not sent, as today (`flush_all` does not flush the loop).

## Co-op on the core

2-player co-op (ROADMAP "2-player co-op"; DECISIONS B22, B26-B28, B38, B40, B42) is today's session, relay and lobby with the combat core's messages on top. One player HOSTS: the real game runs on the host's core, as in a solo run, and the
party's other player is a GUEST: its game scene (`DmNextGame` joined, `is_guest`) holds a **puppet core** (`DmCoreHost.puppet`, `set_puppet(true)`) that shows what the host tells it. Up to 4 players fit the session; the proof is a host and one guest.

| | HOST | GUEST |
|---|---|---|
| core | simulates: enemies, thralls, corpses, statuses, affixes, zones; the hero and the boss are its externals | a puppet: bodies come from the wire, ease toward snapshots, events are derived from state edges and health drops |
| waves, the bosses' brains, rites | the director, `DmBossHost`, the casters (every player's cast is resolved here) | none: the director is off, a boss is a puppet fed by `DmBossHost`'s state, a caster only asks and plays the host's events |
| crowd, effects, HUD | from its own events | from the puppet's events, the same consumers (`DmCrowd`, `DmEnemyFx`, `DmNextUiHost`); its hero's hurt from the host's vitals ("The HUD on the core") |
| kills | `kill_credited` (once per death, with the killer's peer: the hook of the kill report and the rewards) | nothing: its `enemy_died` events draw the death and credit no one |
| a hero | an external of the core (`core_id`); a guest's too | `core_id` is the HOST's id for it (told in a table): the owner id in a thrall's event, the source of a blow |
| seals, doors, open areas | the host's own account breaks them (the Chapterhouse node: the kills in the area before), the gates and navmesh follow | the host's, told on joining and whenever one breaks; the guest's own account's seals open and close nothing in this world |

**Messages** (`next/next_net.gd`, node `Net`; the session and the rites keep their own RPCs; everything rides the session's `DmRelayPeer`: the UDP lane when the relay offers one, else the lobby's WebSocket):
- **Snapshot**, host to guest, unreliable ordered, 20 Hz: `core.snapshot_parts(tick, 1300)`. **The split:** the Full Party's snapshot is 1.2 KB on average and reaches 1.7 KB, past the 1,392-byte packet the old code stayed under (ENet fragments
  a bigger unreliable packet, and one lost fragment loses all of it), so it is cut **by body ranges**: the live enemies in spawn order, then the thralls, in as many messages as keep each at or under 1,300 bytes (the RPC frame and the relay's
  6-byte header come on top: a packet stays under the 1,364 B or so that ENet sends in one datagram, and under the 1,392 B limit of the old code). Every part is a complete snapshot message of its own bodies, with its own tick (the parts of a frame are consecutive numbers, the frame id), and **the guest applies each part as it arrives**:
  bodies are independent records, a puppet ignores a tick that is not newer, and a lost or overtaken part costs its bodies 50 ms (the next snapshot has them). Nothing is reassembled and no frame is waited for. One part is the common case.
- **Reliable batch**, reliable, every tick with content: `core.take_reliable()`, the numbered batch of spawns, deaths, zones, statuses, corpses and thralls. A guest that sees a gap (`need_baseline`) asks for a baseline.
- **Baseline**, reliable, once to a new guest (`core.baseline()`, the whole present) and again on request (at most once a second); the guest clears its crowd first. The host collects events only while a guest is in (`set_replication`).
- **Seals**, reliable, host to guest (`DmNextParty.send_seals`): the open areas of the host's world (`DmNextWorld.unlocked`), a few strings. A party plays in the host's world, so the guest's doors, navmesh and open areas
  (the minimap's) are the host's: the message goes to a guest as it joins (`joining`: the doors just stand open for it, silently, without the gate sound or a banner) and to every guest whenever the host's seals change (`apply_seals`:
  a kill that breaks one, GM mode). A seal that breaks while the guest is in rises on the guest through the world's `set_unlocked` (the gate, the collider, the navmesh region and both links, and one `door_opened`, the event
  `DmAudioHooks` plays the gate sound on) and shows the host's "A seal breaks" banner (`DmChapterhouse.announce_seal`). The guest's own account is its own world's: its seals, GM mode included, never open or close a door in the
  host's (`apply_seals` and `check_seals` do nothing on a guest), and what its account earned by the host's kills is its own business (`DmNextJoiner`).
- **Travel**, reliable, guest to host and back (`DmNextParty.ask_travel`): a guest's waystone jump or recall (T). The host simulates every body, so it moves the
  guest's (`DmChapterhouse.guest_destination` + `move_body`: beside a stone or in the Chapterhouse, the area open in the host's world; the recall goes home from anywhere) and answers
  with the jump the guest plays (`arrived`: the sound, the bursts, the camera, `travelled`) or the reason it refused (the guest's toast). A guest's waystone map still lists its own
  account's open areas; a jump to one sealed in the host's world is refused with that reason. `client/tests/coop.gd` "guest_travel".
- **Hero table**, reliable, on a join and a leave: peer id to the hero's external id in the host's core. **Vitals**, unreliable ordered, 20 Hz: every hero's health, resource and alive flag. The hero positions are the session's own snapshot.
- **Guest to host:** move intents (`DmSession`), `request_cast` (`DmRiteCaster`: the host validates the owner, the rite's rules and the aim, resolves it on its core with the guest's hero as the source, and broadcasts the rite's events, which the guest
  plays), a baseline request, and the **profile** (class and level, clamped to 100) once the session is live: the host binds that character to the guest's body, so what its caster may cast follows the level. The guest's thralls are the
  host's bodies, owned by the guest's hero external; they leave with the guest.
- **Versions (B40):** the session's hello carries the build and `DmCore.wire_version()` (`DmSession.PROTOCOL` 3); a different release build, or another wire version even between dev builds (which skip the build check), is refused with the words a
  player reads (`DmSession.version_text` / `wire_text`: which side is behind and "restart from the launcher"), and the guest's game does not start. The core's own messages also carry the wire version and a hash of the data tables: a guest whose
  first message is refused for that (not for a gap) leaves the session with the core's words (`Net.refused`). Phones will join as guests only: the same messages (B40), measured when the first phone build exists.

**Bosses in a party.** The brain, the state and the events are `DmBossHost`'s and stay GDScript (DECISIONS B42): the host runs the brain and sends the boss's state to the guest at 20 Hz (position, facing, health, phase, state, its telegraphs with their
seconds left, and the id the host's core gave it) and every brain event reliably. The guest's `DmBoss` is a puppet drawn by `DmBossView`, and its `DmBossFx` plays each event once, as the host's does: the telegraph shapes, impacts, banners and sounds are
the same on both sides, kind for kind. The adds, the Abbess's niches (with the health the host gave them) and the pools (the Saint's rot, the Regent's coals, firebreak and embers) are bodies and zones of the core and ride its wire. The boss's blows are the
host's: it applies them to its copy of the guest's hero (the damage, the Flood Hymn's chill, the Drowning Grasp's and the Drowned Hands' root, the nave's wading water), and the guest sees them as its vitals, the status set's replication and the position the
host moves it to. A guest summons with its own soul shards (its client takes them when the host says yes; the host checks the site, the dead and a boss already awake, and the refusal reaches the guest as a toast), its casts at the boss resolve on the host with
its hero as the source, and a kill by the guest is the guest's: `defeated` names its peer and the host pays every member in range (each one's gold, shards, drop event, XP and the boss in its report; the guest's first-kill bonus and trophy are its own backend's
business, later, as in today's game). The guest's core host knows the boss by the id the host's core gave it (`DmCoreHost.adopt_boss`, taken from the state): the hover pick, `enemies_in_radius` and `enemy_info` find it there as they do on the host, and nothing is
written to the puppet core, which has no externals. A wipe is the host's: both heroes fall, the brain resets, its adds leave through `remove_enemy` (no death, no corpse, no credit) and the body is freed on both sides 8 s later.

**Joining** (`next/party/dm_next_party.gd`, node `Party`, a port of today's): hosting turns the running solo session into a hosted one (`host_session(name, closed)`: lobby `create`, `DmRelayPeer.host`, `DmSession.swap_transport`; Open parties are listed, Closed ones
need the code or an invite); `join_by_code` / `join_session` / `join_friend` seat a solo game in a party (`join_ready(lobby, info)`: the shell frees the solo game and starts a guest game on that socket, `opts.lobby`); `invite_friend`,
`ask_to_join`, `answer_request`, `accept_invite` are the friends flows over the lobby's presence of online mutual friends; `view()` is the contract of today's party pane. Errors are the player-readable `ERROR_TEXT` / `CLOSE_TEXT`.
Party chat goes through the host (`DmNextParty.chat`: the host names the speaker, at most 4 lines a second a player, 200 characters a line). The guest's own account and the
ground drops between members are "Value on the server".
A player's world keeps a lobby link (`go_online()`, after loading) so friends see it online and invites and asks arrive. The friends list itself is `DmNextFriends` (a copy: the test backend's friends routes); a friendship it changes is announced
through the party (`friends_changed`).

**The Social window** is the player's way in: today's (`game_ui/dm_ui_social.gd` in `DmGameUi`, its window and panes `ui/panels/dm_social_window.gd`), opened as today (O = Friends,
F = Party, the HUD's Social button) and wired through the adapter's party and friends calls (`DmNextUiHost.party_view`, `friends_view`, ...) to `party` and `friends`. The Party tab
hosts an Open or Closed party and lists the Open ones to join; the Friends tab sends and answers friend requests and joins, asks or invites an online friend; the public list is
watched only while the window is open. **`main/main.gd`** does today's hand-over: `join_ready` frees the solo game and starts a guest game on the same lobby socket (behind "Entering the host's world..."); `client_ended` and a refused or failed join put the player
back in their own world with the reason as a toast.

Launch arguments, for a trial without the window (any build, test lobby only): `--host-party[=name]` makes a Closed party as soon as the world is up (the code is in the log and in a toast), `--join-party=<code>` takes a seat before the game is built,
`--lobby=<ws url>` points at a lobby on this machine (the token in `DM_LOBBY_TOKEN`).

**The test lobby and relay are the only ones this build uses** (the API rule above): `DmConfig.LOBBY_URL`, `RELAY_PORT`, `allows_lobby_url`, `allows_relay`. The services (their own ports, the test backend's signing key) are
`server/death-muffin/test-server/coop/` (installed 2026-10-16; its README has the steps). The lobby offers the relay's address and a ticket when a session is made or joined; without the relay a session
plays over the lobby's WebSocket, which works and stalls a movement packet behind a lost one.

**Try it on this machine** (no install, no network beyond loopback):
```
cd server/death-muffin/lobby && npm ci                    # once: the lobby's modules
bash client/tools/coop_local.sh                           # a local lobby and relay with a throwaway key; it prints the two commands below with tokens filled in
DM_LOBBY_TOKEN=<token> godot --path client -- --dev-offline --class=2 --lobby=ws://127.0.0.1:45195 --host-party        # the host: prints "the party's code is NNNNNN"
DM_LOBBY_TOKEN=<token> godot --path client -- --dev-offline --class=2 --lobby=ws://127.0.0.1:45195 --join-party=NNNNNN # the guest, in another window
```
(`--dev-offline` is the local mock backend: both windows play `tester` on it, so both heroes carry that name; the lobby accounts are the tokens'.)

**The proof** is `tests/coop.gd` (`--fixed-fps 60`, about a minute): two game scenes in ONE process, each in its own `SceneMultiplayer` branch (the way a second machine would be; the alternative, two processes, needs file-driven remote control for little
more), over a REAL lobby (the node service on a free port, a test signing key) and the real `DmUdpRelay` in the process (offered by the lobby, so the packets travel the UDP lane). It runs the party flow (a wrong code, a Closed party, a join by code, an invite
and an ask to join), the connection (both on UDP, the puppet, the ids), a still moment and a fight compared **at the snapshot's own tick** (every live body the same, every position within the 1 cm quantization, lost parts excepted), a guest cast resolved by
the host with its damage on both, a guest Exhume simulated by the host, the King fighting both heroes to his fall (the other six: `tests/coop_bosses.gd`, below), a guest-side death and respawn, the guest's window (an enemy's flash on both crowds; a number for every hit of either
hero's rites, the guest's crits included, and for a DoT's lumps; the guest's own hero's hurt as a number with the damage taken, the red flash and the hurt sound, the low-health sound under 30 %, one number for two blows in the same 50 ms, none for a heal or a lower maximum, the killing blow once and
none for getting up; a drag by an enemy; the host's window deaf to the guest's hurt and the guest's to the host's), the kill accounting (the host credits every kill once, the guest none), the party's seals (the Warren is in every game: a seal the host breaks opens the gate, the navmesh and the banner on the guest with one `door_opened`, the guest's own GM mode opens nothing, a player joining afterwards finds the door open without a sound), refused versions, the Full Party's
packets and bandwidth, a leaving guest, and zero script errors. The suites' relay (`TapRelay`) counts its rate limits in GAME time: the ticks run several times faster than a player's, and a wall-clock budget of 600 packets a second would drop the packets of that burst
(reliable ones too: the relay drops after ENet has acknowledged them), which left the guest without its batches; a limit that still drops in game time fails the run. `until` waits at least twice its game-time limit in real time as well, for the sockets and ENet keep real time. `tests/coop_bosses.gd` (`--fixed-fps 60`, about 70 s, the same lobby and relay, its helpers from `coop.gd`) fights the other six bosses with one party in the whole world, each summoned twice. The first time the GUEST asks, at the altar, and pays with its own shards:
the boss wakes on the host and the guest holds its body with the same health (the party's extra health counted for two heroes), model and plate; the guest's core host names it among the bodies near it and its hover pick finds it; a fight on the real clock with
the guest's hero in front and the host's to the side, the attacks provoked one after the other through the brain's own cooldowns: every attack lands twice, the casts of both heroes hurt it (the guest's resolved on the host), its blows reach the guest's hero (its own
client shows the health fall, with a hurt number, the red flash and the hurt sound on its window for it and none on the host's), the guest's copy shows its telegraphs, and the guest's boss fx, drawing back-end, sounds and HUD banners are the host's, kind for kind and count for count; the chill on the guest's hero as the guest's own status set shows it, the root
that holds the host's body of it against its own move intent, the nave's water, the Saint's and the Regent's pools as the same zone events and the same drawn visuals, the Mire Mother sunk and untargetable on the guest; the phases at 60 and 30 % with their waves (the
Abbess's niches broken by the heroes, one by the guest's own cast at the niche it sees, then rebuilt) as the same bodies on both cores, every body the guest holds the host's at the snapshot's tick; the last phase's own attack (Bone Communion over real corpses, the
Drowned Rite raising Risen from them, Conflagration, the rain); the defeat by a cast of the guest, `defeated` naming it, both members paid (each one's gold, shards and drop event, XP, report entry; the guest's on its own account), the adds gone silently. The second
time the HOST asks: a wipe (both heroes fall, the boss resets on both sides with nothing paid, its adds leave with no death, corpse or credit, both get up, the bodies are freed on both sides). `tests/social.gd` (`--fixed-fps 60`, about 40 s, on the same local lobby and relay, its helpers from `coop.gd`) drives the Social window: the button, O, F and Esc,
hosting an Open party from the Party tab, a guest that is the real boot scene (`DmMain`) joining it from the list and leaving from its tab (main.gd's hand-over both ways), a refused join and a host who closes the party (the guest back home with the
reason), a friend request sent and answered from the windows, friends' presence over the lobby, and zero script errors. It prints INFO lines: the Full Party's bandwidth for one guest was about 28 KB/s (23 KB/s snapshots, 0.7 KB/s reliable) in 82 packets/s on the host's connection, 2.7 % and 14 % of the relay's limits (1 MiB/s, 600 packets/s); the largest game
packet was 1,231 B.

## The server: login and character select

`main/main.tscn` (`DmMain`, a port of today's) is the project's main scene. It is today's boot and front flow (login, register, the online gate, character select, the discipline switch,
the saved login `user://dm_jwt.txt` in this project's own user folder), pointed at the **live server** since launch day (2026-10-18; before it, the test server,
`server/death-muffin/test-server/README.md`), then the ported game scene with the chosen character:

```
/home/ubuntu/tools/godot/godot --path client            # login with a live account (never a real one in a test; tests run on the local mock); pick a discipline
```

- A character that already exists skips the select screen (today's `resume()`); one whose discipline is not playable goes to the discipline switch. The online gate reads the live
  manifest (`https://muffindevelopment.com/death-muffin/client/manifest.json`, its `online` block).
- **The character's build comes from the server**, read-only, before the game starts (`DmMain.load_build`): the bag's rows (worn gear, set bonuses, the weapon line) and the progression (damage and
  legion tier, boons, vows). `DmNextGame.build_for` builds the hero from them as today's does from the progress node and the bag, so the hero's health, spell power and loadout follow the worn gear.
  A bag or progression the server fails to give sends the player back to the login screen with the server's words; nothing is written, created or imported.
- Server errors are shown as today shows them ("Cannot reach server — check your connection", the server's own `error`, "Request failed: 502"); a stored login with the server unreachable lands on
  the login screen saying "Online opens soon", as today.
- **Value is the server's** ("Value on the server"): the kill reports, the drops claimed into the bag, the progression's and the bag's saves all go to the live API with the logged-in character.
- **As today's since launch day:** the automatic crash report (`DmMain._send_crash_report`, DmCrashWatch) and the update notice (`DmNextGame._start_update_check`,
  DmUpdateCheck). Log out, Switch character and a discipline change (Settings, the class
  panel) save and hand over as today's (`tests/front.gd` "hand-overs"). The four necromancer disciplines and the Reaper play (their hero models are in `client/assets.list`; `tests/rites.gd` "the disciplines", "the Reaper").

### The API rule (DECISIONS B38, B49)

The client plays on the **live server** and **never reaches the test server** (since launch day, 2026-10-18; before it the rule was the other way round). Where it may talk is set in
**one place**, `net/dm_config.gd` (a port of the live game's config), and enforced twice:
- `DmConfig.API_BASE` is the live API (`https://muffindevelopment.com/death-muffin/api`), `SITE_BASE` the site's root (the manifest `client/manifest.json` and the patch notes under it),
  `LOBBY_URL` the live lobby and `RELAY_PORT` the live relay's (5193). A test run and an exported build all read these constants: there is no publish-time swap to miss.
- `DmHttpTransport.send` (the one door to the network, a port) refuses any URL `DmConfig.allows_url` does not accept: under the site's root, never under a test-server path
  (`DmConfig.TEST_PATHS`: the test API, the test channel, the test lobby), nothing with a `/..` that a server would resolve elsewhere. It logs an error and answers like an unreachable server.
  `DmNextGame.start` refuses any api whose base url is not the live API or empty (the local mock). `DmNextParty` connects only to a lobby `DmConfig.allows_lobby_url` accepts (the live
  lobby, or one on this machine for a trial) and keeps a relay the lobby offers only when `DmConfig.allows_relay` does (port 5193, or this machine; never the test relay's 5196).
- A finished benchmark run is sent (`DmApi.post_benchmark`) through the same transport to the live API's benchmark history.
- `client/tests/front.gd` fails if any of it moves: the constants are the live server's (read from `godot/net/dm_config.gd` too), the allow-list refuses the test server's addresses and
  lookalikes, every request the flows made stayed on the live server, and a scan of every shipped file finds no address outside `net/dm_config.gd` and no test-server path anywhere.

Test builds (the launcher's Test build switch) keep the last one published to the test channel before launch day; a new test build needs its own endpoints first (a PREPARE step
that points a scratch copy at the test server), never a change to `net/dm_config.gd`.

## Assets

The client keeps its own copies of the assets it uses, at the same relative paths as under `godot/assets/` (DECISIONS B41). `client/assets.list`
names them, one path or glob per line (relative to `godot/assets/`, `#` comments, `*` inside a folder, `**` across folders, a folder name
copies it whole). A line starting with `@` names art that lives next to the code in `godot/` instead (`@ui/fonts`, `@ui/hud/art`, `@front/art`,
`@world_fx/assets`): its path is relative to `godot/` and it lands at the same path in `client/`. Each rebuild item adds its block to the list;
nothing else is copied.

```
node tools/rebuild/sync-assets.mjs [--dry-run] [--list <file>]     # copy what the list names into client/assets
```

- Idempotent: only missing or changed files are copied. It prints what it added and changed, **flags list lines that match nothing** (exit 1) and
  lists files in `client/assets` that no line names any more (it never deletes; delete them by hand).
- Asset files only. Godot's `*.import` and `*.uid` files of `godot/` are never copied: the client imports with its own settings and commits its
  own `.import` files (and the `*.unwrap_cache` files Godot writes next to models it gives lightmap UV2: commit them, they keep UV2 identical on every machine). A new 3D texture (under `slice/models/`, `slice/art/textures/`, `fx/art/` and the other 3D folders in the tool) gets a seed
  `.import` first (VRAM compressed, mipmaps, normal maps flagged), so even a headless first import is right; `npm run hygiene` checks them like
  the live game's. Models import with lightmap UV2 (`importer_defaults` in `project.godot`); a model that never gets a lightmap (creatures, the
  hero) may set `meshes/light_baking=1` in its `.import`.
- Scenes and resources in `godot/` name assets by path, never by uid, so a client asset's new uid raises no "invalid UID" warning (0 in the
  imports and in `code_load`). If a copied scene ever carries `uid=` references, seed the `.import` of new assets with the live asset's uid here.
- **Licensed flipbook sheets** (`fx/sheets/`) are not in git (`godot/fx/README.md`). A list line under `fx/sheets/` (for example `fx/sheets/hit_flash.png`)
  is read from `$FX_SHEETS` (default `~/death-muffin/private/fx-sheets/`, the source of `tools/godot/fx-sheets-sync.sh`) and copied to
  `client/assets/fx/sheets/`, which the root `.gitignore` keeps out of git; the tool refuses to copy them anywhere git does not ignore.

## The Depths

The Catacomb Depths (area `depths`, an instance below the Warren, solo: DECISIONS D5) are the one area with no scene: a run's floors are generated, drawn and baked when they are entered. The rules and numbers are
today's (the floor generator `sim/depths_floor.gd`, the quota, pacing, rosters and affixes `sim/sim_depths_rules.gd`, the rewards `rules/loot/depths_rewards.gd` are copies); `next/depths` is the game's side:

| file | job |
|---|---|
| `dm_depths_run.gd` (`DmDepthsRun`, a port) | the run as pure rules: seed, depth, quota, kills, stair, peak, summary, `plan_wave` |
| `dm_depths_ground.gd` (`DmDepthsGround`, a port) | one floor as ground: the navmesh baked on a worker thread, the picture, the core's copy |
| `dm_depths.gd` (`DmDepths`, a port; child `Depths` of `DmNextGame`, host only) | the controller: enter / descend / leave, waves, quota and rewards, chest, death, the Chronicle, the HUD's readout and map, the interactables |

**Flow.** The Warren's stair (a `DmStairMesh` the controller puts in the Warren's scene) is an interactable of the hub: `stair_clicked()` offers "start at 1 or resume at the deepest" once a deeper floor is on the Chronicle (`depths_stair_offer`, the card calls
`DmNextUiHost.enter_depths`), else starts a run on depth 1; the floor's stairs and chest join the hub's interactables while the run is on (the hub's hover, walk-and-use and prompts work as everywhere). Quota `9 + depth` (at most 30); the stair opens at the
quota, once, and the floor pays (gold, XP, 65% an item); a chest on every fifth floor; death ends the run and takes nothing (the floor stays up behind the death screen; the Depths close when the hero rises in the Chapterhouse); the exit asks twice;
a recall or waystone out ends the run; a second player joining ends it (the stair refuses a party of two). The floor's gold and XP are reported (`psync.report_floor`) and its items and the chest's come from the server's drop tape (kinds `floor` and `chest`,
DECISIONS B20): the server rolls the same event on the claim and grants its own roll. A run's kills are the ordinary kills of the core (area `depths`, level `max(12, hero) + depth`, the loot ground following the depth: `rewards.loot_area_of`) and count for the
quota; they do not count toward any area's seal.

**On the core.** The dead are bodies of the combat core made by the ported director (`DmWaveDirector.spawn` with `over = {area: "depths", depth, aggro: 36, leash: 90, affix_list}`; the core gives each body its own notice and chase distances,
`DmCore.set_enemy_aggro`, where everyone else's are 15 and 30), spawned from the floor's breaches (not the hero's room, up to 3 breaches, first wave 8 after 1.4 s, at most 24 alive). `DmDepths._living` counts the Depths' living bodies from the core's
spawned, died and removed events (a Risen a Vengeful elite or a deacon raises on a floor is of the floor, as the core makes it); a kill is the core's `enemy_died` with area `depths`. When a floor goes, every body of the Depths leaves the core without a death or a credit
(`remove_enemy`, found by the core's table), its corpses are consumed through the core's field (`corpses_in_radius(..., "depths")`), its loot is cleared, and the hero's thralls are recalled through his caster (`thralls().recall()`, which writes the hero's new
place into the core first) with the camera snapped. The roster is the bands' (`depth_roster`: 1 / 5 / 10 / 15), every kind of which the core runs (`tests/depths.gd` fails if a band gains one it does not).

**A floor, in order** (`DmDepths._load_floor`; measured on the VPS, headless, one run of `tests/depths.gd`): the floor is generated on a worker thread (`WorkerThreadPool`; `DmDepthsRun.generate` is pure and reads only data `DmDbWarm` loaded in loading ("Threads"), about 16 ms there, off the main thread);
`DmDepthsGround.prepare` builds the navmesh's source geometry (the rooms and doors as ground, the walls and solid props as projected obstructions, the builder's settings and grow) and bakes it with `NavigationServer3D.bake_from_source_geometry_data_async`, the old floor
(or the Warren) standing meanwhile; then, in one frame, the old floor's dead, corpses and loot go, `show` draws the new floor (the lights builder's `build_depths_floor`: floors, walls, props, light pools, the stairs and the chest, the existing look, into the world's
`depths_root`; every prop light on, since Forward+ lights them all), puts the baked mesh on the floor's one `NavigationRegion3D` and hands the core its copy; the hero is put at the way in with the banner (about 4 to 8 ms of the main thread); the navigation server
merges the region a few frames later (`merged`: a path from the way in to the stair exists), and the floor counts as loaded (`floor_loaded`, the end of `enter` / `descend`, about 80 to 160 ms after the click). The core keeps bodies on the navmesh with its own copy of it
(DECISIONS B47): the floor is one region of it, added with the first floor and **replaced** by every later one (`DmCore.nav_replace_region`, so a long run holds one floor's 220 to 260 triangles and nothing piles up), emptied when the run ends. A floor has no physics
colliders: the hero has no body and the core keeps the dead on the navmesh, whose obstructions are the walls and props.

**The world's side.** `DmNextWorld` keeps the Depths' rect from the start (`area_rect`; the core's bounds and the crowd's cover it when the Warren is in the world) and the shape of today's builder: `open_instance("depths", true)` makes `area_at` answer "depths" there while a run stands (so the game's area, the
lighting, the music and the ambience follow the hero, and the director sees no hero in a combat area while he is below), `attach_floor / detach_floor` give the core the floor's region. The HUD reads `vm["depth"]` (depth, kills / quota, stair, chest), the minimap's floor (rooms,
doors, stairs, chest; built once per floor and kept current in place), the area line "Level N dead · elites bear K affixes" and, for the stair, the hub's hover prompt (`vm["prompt"]`).

The floor's tall props follow today's moon-shadow range rule: while a run lasts `DmDepths` calls the lights builder's `update_shadow_cells` for the hero (it checks every 0.25 s, a few cells a frame, and drops the cells of freed floors from its list); nothing else in the rebuild calls it.

**Not yet.** The first floor of a session is not in the warm-up (the floor is made at run time, after the warm-up); a floor is not lightmapped (made at run time: the area's ambient, the moon and the real prop lights light it; the look pass decides
what it becomes); the see-through cutout is not applied to it (as in every area). What differs from today's game is in `native/README.md` "Differences from today's game".

`tests/depths.gd` is the proof: the rules without a game (floors per seed, quota, pacing, rosters, the filter, the first wave, the stair opening once, the loot ground by depth); then the game scene as a player gets it, on the local mock: the Warren's seal broken, waystone travel, a click on the stair
(the hero walks to it and the run starts), floor 1 (drawn, the hero at its way in, the interactables, banner, HUD readout, map and prompts, the core's copy of the navmesh equal to the server's at 600 points, a point inside a wall moved out, paths to the stair and breaches), the dead (bodies of the core
at the depth's level, aggro 36, hunting across the rooms, hitting back, an elite's affixes), the quota and the floor's pay and report, descending (the dead and corpses gone from the core, the core's navmesh replaced, thralls recalled, a click on the open stair walking across the floor and taking it),
the chest on depth 5 (a find claimed into the bag on the server), leaving (twice to confirm, everything torn down, the record on the backend, the stair's resume offer and `enter_depths`), a second player joining, a recall, death (nothing taken), and 14 more floors (nodes flat, one floor's
triangles in the core, every bake from the worker); zero script or engine errors.

## Areas

An area is a scene built once, offline, from `godot/data/slice/world.json`: the layout `godot/world/world_builder.gd` builds at start-up today.
Twelve areas are converted: the Hollow Graves (`graves`), the three hubs (`chapterhouse`, `acre`, `alchemist_wing`) and `warren`, `ossuary`, `nave`,
`coliseum`, `sanctum`, `cloister`, `pyre`, `fen`.

```
bash tools/rebuild/build-areas.sh [area id ...]                     # sync assets, import, convert; default graves
godot --headless --path client --script res://tests/areas.gd         # every converted scene equals what world_builder.gd makes from world.json (about 10 s)
```

`client/tools/build_area.gd` is the one converter for every area (`--lenient` skips models not synced yet, for a smoke run; the Depths' floors are
generated at runtime and are not converted: "The Depths"). Output is deterministic, so regenerating changes nothing unless the data or the converter did:

- `client/areas/<id>.tscn`: groups `Floor` (the ground quad, the paths whose centre lies in the area, the Alchemist Wing's rugs and stains, the Fen's
  hummocks), `Walls`, `Props`, `GatherNodes`, `Decals`, `Doors`, `Lights` (the prop lights and the pool mesh),
  `Occluders`, one static `Colliders` body on the `world` physics layer (walls, prop and node obstacles, deep ponds; 3 m tall as today), and `Navigation`
  with a **baked** `NavigationRegion3D` for the area, one per door touching it and the two `NavigationLink3D` per door. Settings and obstruction
  rules are `world_builder._nav_mesh` / `_all_obstacles`. A door starts as `world_builder` leaves it after building: a sealed door's gate is closed
  (region and links off) and each `Doors/<id>/gate/bars` rises when it opens, which the runtime does as `set_door_open` does (region and links on,
  `gate/body/collider` off); the doors world.json lists as `open` start open (bars up and hidden, collider off, region and links on), and
  `chapter_graves`, the one hall `world_builder` builds without a gate, has none.
- `client/areas/props/<model>.tscn`: one prefab per prop or gathering-node model: the glTF instanced with the height normalisation of `DmModels.analyze`.
  Props up to 1.5 m (the height `world_builder` stops casting shadows at) also get a 70 m visibility range.
- `client/areas/common/ring.png`, `glow.png`: the two decal textures the live game paints at start-up.
- `Lightmap`: the area's `LightmapGI`. Walls, gate stone and floors carry UV2, prop meshes get UV2 on import, everything solid is `gi_mode` static
  and the prop lights are `BAKE_STATIC` (positions, colours and ranges as today), so the bake takes their direct and bounced light; the area's
  ambient is baked in too, since a lightmapped surface ignores the environment's: `DmWorldBuilder.set_area`'s colour (same constants) as linear light (the Environment's ambient colour is sRGB and
  the renderer converts it; the bake takes `environment_custom_color` as it is) at the hemisphere's energy times the area's factor (`DmWorldBuilder.AREA_HEMI_K`: the Acre's 2.0 / 0.95 and the Wing's
  1.12 / 0.95, which today's `DmGameRewards.tick_milestones` applies and the rebuild does not run; `set_area` applies them, and the moon's `AREA_MOON_K` 3.4 / 2.4 and 2.65 / 2.4, to the live lights). Every floor quad
  (the ground, the paths, the door floors) is built by hand and carries a lightmap size hint of 0.125 m a texel (`FLOOR_TEXEL`); a quad without a hint gets 64 x 64 texels whatever its size, which was 0.43 m a
  texel in the Chapterhouse, 0.84 x 0.65 m in the Graves and 0.6 m along a 40 m path (`client/addons/dm_bake/README.md` has the sizes). When
  `client/areas/<id>.lmbake` exists (a bake from `client/addons/dm_bake/README.md`) the converter points the node at it; an area without one has a `LightmapGI` with no data and is lit as "Without a bake" below says
  (all twelve areas have their bake since 2026-10-17: Helix's helper, one commit). The props stay instances of their prefab scenes: Forward+ and Mobile draw identical meshes instanced,
  so merging them would add draw calls (ROADMAP "Static batching"). Occluders: tall walls (3 m, 4 m long) and large solid
  box props (the mausoleums), shrunk so they never hide what is visible past them.

**Without a bake** (an area whose `.lmbake` is missing) an area keeps its `LightmapGI` with no data: nothing is lightmapped, so the Environment's plain-colour ambient (the colour and energy today's game uses, the Acre's and the Wing's
brighter ones included), the moon, the rim light and every prop light as a real-time omni light (no shadows; `BAKE_STATIC` lights only skip a mesh that has a lightmap) light the room, which is today's lighting model
without baked contact shadows, bounce and the candle light's occlusion by props. The exposure lift of each area (`DmWorldBuilder.AREA_LIFT`) is measured on the baked areas; an unbaked one is brighter or darker than today's by whatever the bake changed, and the cost of a room's
lights in real time (the Wing has 21, the Graves 18, the Chapterhouse 14) is not measured on a graphics card.

`client/tests/areas.gd` checks every converted area, one scene at a time (instantiate, check, free), and prints `PASS areas (N checks)` or a `FAIL areas: <id>: ...`
line per failed check. Each expected number is computed from `world.json` the way `world_builder.gd` computes it (its constants, `DmModels.prop_parts`, its
hummock ring mesh), never read from a scene:

- the ground and every path and door floor (theme texture, tint, roughness, glow; UVs anchored to the world; lightmap UV2), walls (position, size, the
  texture and tint `world_builder` shares per texture; the tints are lifted by `DmCompatAlbedo` to the albedo today's renderer makes of them, and the test measures its table against the
  textures again: "The look against today's game"), props (the same meshes where `DmModels.prop_parts` puts them, shadow and visibility range), gathering
  nodes (models, an ore's three crystals, the herb, pool and tree stand-ins), decals, the Wing's rugs and stains, the Fen's hummocks
  and rims, prop lights (with no flame sphere) and the floor-pool mesh (the Nave's dimmer, smaller pools; its vertex colours read as sRGB, as today's renderer reads them), colliders, occluders, the two decal textures pixel for pixel; and that the scenes hold none of what the world dressing draws (no flame sphere, water plane or puddle quad), whose water rects and puddles are world.json's;
- doors: each door touching the area (and no other) with its corridor floor, and each gate's posts, lintel, bars, rails, seal and body, closed or open;
- navigation: the area's region and each door's region equal a fresh bake with `world_builder`'s settings, stop short of the walls by the agent's radius, and
  the regions and links are enabled exactly when the door is `open`; paths cross the area, join its door mouths and bend round box props; a sealed gate blocks the
  way to its corridor's far end and, once its region and links are enabled, the corridor is walkable to it;
- the lighting bake: the `LightmapGI` bakes the area's ambient as linear light at the hemisphere's energy times the area's factor (and that equals the light the builder's real-time ambient gives the area), every floor quad
  (the ground, the paths, the door floors) has a lightmap size hint of 0.125 m a texel under the 4096 limit, today's `DmGameRewards` still holds the Acre's and the Wing's factors, `set_area` scales the moon and the
  ambient by them as a ratio (so the Nightfall dimming composes); the `LightmapGI` points at `<id>.lmbake` when one exists, and a bake is stale (the test fails) when a mesh it recorded is no longer at its path in the scene;
  the test prints which areas have no bake yet;
- the whole: one scene per converted area, and every path, wall, prop, node, decal, hummock, wing-floor quad and door of `world.json` is in
  exactly the scenes it belongs to.

A headless Godot (the dummy renderer) keeps no `MultiMesh` instance transforms set one by one, so the converter writes the gate bars' and hummocks' `buffer`
directly and the test reads them from the scene file. Every mesh that is static for the bake carries a lightmap UV2 (the test checks each), or the bake stops on it.

Not the same as today's runtime, on purpose: props are single instances of a prefab (not one MultiMesh per 12 m cell; MultiMesh cannot take
lightmaps); each floor is one quad (not 12 m tiles, which only limited per-object lights on Compatibility); there is no per-area light switching
(the lights stay on; the bake takes over) and no see-through cutout shader yet (`apply_occlusion`). Not in an area scene (a later world scene
owns them; `DmNextWorld`'s lights builder makes them): the dark earth beyond the walls (one quad), the environment, fog, moon and rim lights, and the world dressing ("World dressing"); the people (`npcs`) are the Chapterhouse node's (`DmHubNpcs`). A door
between two areas is in both scenes with the same id and place (nodes carry `door_id`); `DmNextWorld` keeps the first copy it loads.

