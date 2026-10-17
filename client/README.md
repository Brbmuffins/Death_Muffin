# The rebuilt client

The rebuilt Death Muffin client (ROADMAP "Now: the rebuild", DECISIONS B34-B42): its own Godot 4.7.2 project, next to the live game in
`godot/`, which it never changes. The live game keeps shipping from `godot/` until launch day; this project ships only to the launcher's
Test build channel until then.

- Renderer: Forward+ (`project.godot`), Compatibility only as the automatic fallback, the Mobile renderer for phones (B35). Textures also
  import in phone formats (B40).
- Its own user:// folder (`config/name` "Death Muffin (rebuild)"), so it never shares saved logins or settings with the live game.
- It talks to the **test server** only (DECISIONS B38), never the live one before launch day: [The test server](#the-test-server-login-and-character-select).
- The combat core is a C++ GDExtension built from [native/](../native/README.md) into `bin/` (built files are not committed;
  `bin/dmcore.gdextension` is).
- Crowds are drawn from baked vertex-animation textures, one MultiMesh per creature model and level of detail, driven by the combat core through `CrowdView`:
  [crowd/README.md](crowd/README.md).

## Set up and test

```
bash client/setup.sh                                                       # builds the core for Linux, imports, runs the smoke test
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/core_smoke.gd   # the core loads and answers
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/core_kinds.gd   # the kinds the other areas add, against today's rules: the Ossuary's golem (slam) and deacon (keep-away, curse, raise, Sanctify, silence), the Drowned Nave's censer (incense), acolyte (curse, Unbind), gargoyle (dive), templar (shield) and wraith (scream) and the Sanctum's and Cloister's seraph (curse, ward), plague doctor (flask, pool) and flagellant (frenzy), their co-op wire, the rosters, seeded replays
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/crowd_bake.gd    # the crowd baker and shader (bakes into a scratch folder)
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/code_load.gd      # every copied script, scene and resource loads; no copy names a per-creature class
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/crowd_view.gd    # the crowd's views against today's view code, and a Full Party (bakes into a scratch folder)
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/game_scene.gd     # the game scene on the core: 60 s of an offline run in the Graves (bakes into a scratch folder; add --fixed-fps 60 before --path to run it faster than real time)
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/rites.gd          # the Gravecaller's rites on the core: all 25 necromancer rites against today's rules, a fight (bakes into a scratch folder; 90 s of game time, --fixed-fps 60 makes it faster)
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/boss.gd           # the Gravedigger King on the core: his brain replayed against today's scenarios, his fight, the thralls, the rites, his defeat and a new summon (bakes into a scratch folder; add --fixed-fps 60 before --path to run it faster than real time)
/home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client --script res://tests/front.gd   # boot, login, character select and the game scene with the chosen character on the mock; the API rule; the real test server's health (bakes into a scratch folder)
/home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client --script res://tests/hud.gd     # the HUD on the core (today's DmGameUi on DmNextUiHost, driven through tests/hud_shim.gd): target frame, minimap dots, hotbar and cooldowns, thrall pips, floating number caps, pools, pieces, z layers, the draw-call model (bakes into a scratch folder)
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/benchmark.gd       # the benchmark on the core: the Full Party fight held as the setup says, Easy auto combat, the report and its budget section, real launches, nothing sent but to the test API (bakes into a scratch folder; about 2 minutes)
node tools/rebuild/compare-scenarios.mjs                                                       # the seeded scenario comparison with today's game: ten headless runs, one at a time, and a table against stated tolerances (about 6 minutes; "The seeded scenario")
/home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client --script res://tests/coop.gd    # 2-player co-op: a host and a guest in one process over a real local lobby and relay (needs `cd server/death-muffin/lobby && npm ci`; bakes into a scratch folder; about a minute)
/home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client --script res://tests/social.gd  # the Social window: open and close, host from the Party tab, a boot scene that joins from the list and comes home (needs the lobby's modules too; about 40 s)
/home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client --script res://tests/presets.gd # the graphics presets on a running game: lights, environment, viewport, crowd shadows, the governor (bakes into a scratch folder)
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/rewards.gd                # the rewards node on the core: today's tests/rewards replayed (sessions, batches, lost replies, refusals, the end, per-member loot), on the mock
/home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client --script res://tests/value.gd   # value on the server in the game scene: kills, accepted XP, the purse, a claimed drop, brews and lifesteal, the meta, the belt, saving ("Value on the server")
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/fx_motes.gd               # the effects' particle ring in C++ (DmMotes) against today's ring, float for float; INFO: its update time on both sides
/home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client --script res://tests/panels.gd # today's panels on the core: every panel opens, the Reliquary (equip, sell, sort) on the server's bag, the loadout, Settings live, chat
/home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client --script res://tests/gathering.gd # gathering and the Acre: all 68 nodes hovered and clicked, a node worked through the server (cycles, batches, finds, XP, spent and back), the stops, AFK and its report, the Grave Laborers, a collection, the garden, a contract, the Sexton ("Gathering and the Acre"; about 25 s)
/home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client --script res://tests/world.gd  # the whole world: every area, seals and gates, into the Warren, waystones, the recall, the core's navmesh against the server's, the Ossuary's deacon and golem, the Nave's five and the Sanctum's, Coliseum's and Cloister's rosters (the seraph's ward, the plague doctor's flask, a frenzied flagellant) in the game scene
bash client/tools/coop_local.sh                                                                # a local lobby and relay for a trial with two game windows (prints the commands; "Co-op on the core")
bash client/tools/bake_crowd.sh                                                                # bakes the crowd models (the Graves roster, the Ossuary's deacon and golem, the Nave's five, the Cloister's three, the thralls) into client/assets/crowd/baked (not committed)
```

Run `bash client/setup.sh` once in every new checkout or worktree (it lists the extension before the first import; see the script).

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
  registry, 24 of the necromancer's 25 rites, the rite fx, the combat input; "The Gravecaller's rites"); the boss host, body, world, fx and view ("The Gravedigger King"); Easy auto combat, the benchmark
  with its screen, setup window and warm-up, and the boot's `--benchmark` and Benchmark button ("The benchmark"); the co-op pieces (`next/next_net.gd`, `next/party/dm_next_party.gd` and the session's hello;
  "Co-op on the core"); value on the server (the rewards node, the meta node, the progress node, the wave milestones and the joiner; "Value on the server"); the HUD's adapter and
  view-model ("The HUD on the core"); the Reaper's helper and three of her rites ("The Gravecaller's rites"); and the Acre's glue ("Gathering and the Acre").
- **Left out with a seam**: a file that cannot load without a seam, grouped under the seam it follows: now only the QA boot (with the QA driver).
  Freed by the game scene's port and copied again: `next/status` (`DmStatusSet`, for the status sets of heroes and bosses only),
  the chronicle, the event fx's telegraph and boss halves, the area flow and gathering. Freed by the rites' ports: the hotbar (`dm_rite_hotbar.gd`), Veil Step and the belt.
  Freed by the boss ports: `next/bosses/dm_boss_meta.gd` (the Covenant Seal altar choice; nothing creates it until the bosses item, with the boss key prompt). Freed by the panels
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
`target_hit`, `zone*`, `corpse_*`, `thrall_*`, `status_*`, `affix_moment`; `core/dm_core_events.gd` has the numbers). Systems connect to the signals; nothing polls per creature, and
**no node and no script exists per creature**: an enemy is an id (an int) everywhere, and `enemies_in_radius`, `enemy_position`, `damage` and `apply_status` are thin queries on the core.
`CrowdView._process` draws the rendered frames with `Engine.get_physics_interpolation_fraction()`.

The pieces around it (all ports, `code.list` "Ported"): the **world** (`next/next_world.gd`) loads the area scenes (`areas/<id>.tscn`; `opts.areas` takes a shorter list, the tests' Graves) with
the same small API as today's world object (`area_at`, the navigation helpers, `spawn_point`, the seals and gates: `set_unlocked`, `set_door_open`, `gates`, `nav_regions`), keeps a
`DmWorldBuilder` for the area's lights only, and gives the core its copy of the navmesh (`bind_core`; DECISIONS B47); the **Chapterhouse** (`next/chapterhouse/dm_chapterhouse.gd`) breaks a seal
when the kills in the area before it reach its count (the banner, the gate rises, the navmesh joins; a guest's doors follow the host's seals), runs waystone travel and the recall home (T),
opens the stations' panels and animates the people; the **director** (`next/spawn/dm_wave_director.gd`) spawns through `core_host.spawn_enemy` with the affix
roll of today (`core/dm_affix_roll.gd`), counting from the core; the **hero** (`next/hero/dm_hero_body.gd`) takes the enemies' blows from `EV_TARGET_HIT` with the enemy's id as the source;
**input** (`next/next_input.gd`) picks the hovered enemy by asking the core for the bodies near the cursor's ray; **enemy effects** (`next/enemy_fx/dm_enemy_fx.gd`) play the telegraphs, strikes (timed from the
wind-up), deaths, voices, dust clouds and the affixes' bell, meal and burst from the host's signals, through the same router and the `Vfx` and `AudioDirector` autoloads.

Co-op and the Social window are in ("Co-op on the core"), value on the server ("Value on the server"), today's HUD and panels ("The HUD on the core"), the Reaper ("The Gravecaller's rites") and
gathering with the Acre ("Gathering and the Acre").
Off in this step, each until its ROADMAP item: the Depths, the graphics governor, Grave Surges, and the enemies of the areas past the Warren (the director skips a kind the
core does not run yet). Easy auto combat is in and opens from Settings as today. `tests/world.gd` plays the whole world: seals, gates, walking from the Chapterhouse into the Warren, waystones,
the recall. `native/README.md` "Differences from today's game" lists what behaves differently from today.

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

## The Gravedigger King

The Hollow Graves' boss (`next/bosses`, `sim/bosses`, `game/dm_boss_view.gd`) runs in the game scene as DECISIONS B42 says: **an external entity of the core (kind 1) whose brain stays GDScript.** The brains of `sim/bosses` are
copies, unchanged (the brain does not know what a core is: it asks its `DmBossWorld`); five files are ports (`code.list` "Ported"). `DmBossHost` (child `Bosses` of the game scene, `g.bosses`) has today's summon rules, spawner,
event routing, fx and music; `DmBoss` is the body; `DmBossNodeWorld` is the brain's view of the world, answered from the core. Only the King wakes in this build (`served_areas` is the Graves): the other six bosses' brains are
copied but need their areas, adds and pools.

| today | on the core |
|---|---|
| `DmBoss extends DmEnemy` (a `CharacterBody3D` in the `dm_enemy` group, with a collider, a navigation agent, a state machine) | a plain `Node3D` that registers with `DmCoreHost.register_boss` (its `core_id` is an **external of kind 1**) and keeps what it took from `DmEnemy` as fields: `hp`, `max_hp`, `radius` 1.6, `damaged`, `died`, `is_hittable()` |
| thralls scan and hit it as an enemy (group order, boss edge rule) | the host writes `set_external(id, place, is_hittable())` before every `core.step`: `alive` is false while it cannot be hurt or is not awake. Thralls scan it after the enemies by the core's boss edge rule; their blows come back as `EV_THRALL_HIT_EXTERNAL` (`thrall_hit_external`) and `DmBossHost._on_thrall_hit` gives them to `DmBoss.take_damage` with the owner as the credit |
| `world.enemies_in_radius` appends living bosses; `enemy_by_id`; `DmStatusSet.hit(e, ...)` | `DmCoreHost.enemies_in_radius / foes_in_radius / foe / enemy_info / enemy_position / enemy_alive / enemy_radius / damage / apply_status / status_stacks / remove_status` answer for a boss id too: the living boss comes after the enemies, measured to its edge, as a `DmFoe` with `boss` true (so the caster's `c.foe`, `c.foes_in_radius`, `c.deal`, `c.apply_status` and the lane, cone and circle helpers of `DmRiteModule` reach it with no change), the hover pick finds it, and a blow on its id is `take_damage` into the brain |
| its `DmStatusSet` | the same: statuses on a boss are the boss's GDScript set (B42); slow, root and chill show and the brain ignores them; a stun staggers it at most 0.5 s every 8 s |
| the brain's `world.spawn_enemy / remove_enemy` | the adds are the director's spawn through the core, in the boss's area and at its level (`DmWaveDirector.spawn` returns the core id); they leave with the boss (defeat or wipe) through `DmCore.remove_enemy`: out of the table at once, no death, no corpse, no credit |
| its blows: `hero.take_damage(dmg, boss)`; `thrall.take_damage(dmg, boss)` | `hero.take_damage(dmg, boss.core_id)` (the id is the source, like any enemy's: the hero's body finds where the blow came from, and Colossus Mantle's reflect finds him by it); `core.damage(thrall id, dmg, boss.core_id)` |
| the Scythe's arc and the needle's range treat a `DmBoss` apart | `DmFoe.boss`: the arc counts it separately with its own reach and one of the arc's hits, the needle's range counts its radius, and the click-to-attack chase does too |

What the host's `DmCoreHost.tick` does with it, in the tick's order: the boss's `_physics_process` (priority 0, with the session and the director) pumps the brain and mirrors its position, then the host writes the external and steps the core; the
core's thralls act on the place it wrote, and their blows on it are given to the brain as the tick's events are dispatched.

**Summoning** is today's: key E within 4 m of the King's grave (or `bosses.request_summon`), the refusals `far`, `unknown`, `busy`, `dead` and `shards`: the summon takes the King's soul shards from the
summoner's progression (the plain soul-shard summon; the Covenant Seal's Empowered call waits for its prompt with the panels).
**His defeat** is the host's `defeated` signal (a real kill; `reset` for a wipe), the brain's events (`brain_event`), `DmBoss.died` and the boss sounds, and `DmSessionRewards.on_boss_defeated` pays every member in range. The dev entry's `--boss` starts the hero at the grave, grants the shards and wakes him.

`client/tests/boss.gd` is the proof: the six recorded Gravedigger scenarios of `godot/tests/bosses` replayed tick by tick through this project's copy of the brain, the summon rules, the awaken numbers, his attacks and phases stepped by hand with today's numbers and
timing (sweep, Burial, phases, ghouls on the rim, the elite, the pits, the double sweep, the blows on the hero and on a thrall), the wipe (adds leave silently), thralls (the edge rule, `thrall_hit_external`, credit, `alive` false while he cannot be hurt),
the rites (edge distance, order, lane, cone, circle, the needle's range, the Scythe's arc, the Spear's rally, Fan, Lance, statuses, stun), the defeat events, a second summon, a fight on the real clock and the net state round trip.
Not in it: the other six bosses; their pools, niches and hooks (the core makes no zone for a boss, has no call that sets a body's health, and the Veilwalker's echoes are not ported); the boss bar and banners (the full HUD); Guests see him through `DmBossHost`'s own state (20 Hz) and events, which the port kept ("Co-op on the core").
Easy auto combat takes him as a target (`bosses.active_boss()`, his telegraphs from the boss fx).

## The benchmark

Today's in-game benchmark (`godot/next/perf/README.md` "Benchmark"), ported to the core: the same held fight, so the Full Party fight can be measured in this client against today's game (ROADMAP Gate B).

```
bash client/tools/bake_crowd.sh                                                                                                    # once: the crowd models the fight draws (with none baked the crowd does no view work: about 0.6 ms a frame cheaper, and the report says so)
nice -n 10 /home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client -- --benchmark --bench-room=graves --bench-size=full_party --bench-class=2   # the VPS processor test; the report is in the log
/home/ubuntu/tools/godot/godot --path client -- --benchmark --bench-size=full_party                                                 # on a PC: the fight in the window, then the render breakdown
```

- **Launch:** `-- --benchmark` runs it at once on an isolated offline game (no login) and stays on the results screen with a Quit button; a headless run quits by itself once the report is out (`BENCHMARK` lines in the log and
  `user://benchmarks/bench-<datetime>.txt`). From the character select, the **Benchmark** button opens the setup window; Start runs it and Back returns. `--bench-room=`, `--bench-class=`, `--bench-size=light|standard|heavy|full_party` and
  `--bench-length=quick|full` pick the setup (Quick: 6 s warm-up and 20 s measured; Full: 10 s and 30 s, then the render breakdown), `--bench-warm=<s>` / `--bench-measure=<s>` shorten it, `--baked=<dir>` names the baked crowd models.
  The client has the **Hollow Graves** and the **Gravecaller** only: any other room or class is refused with a message and exit code 2 (`DmBenchmark.refusal`). The Standard setup is the Graves, Gravecaller, Standard size, Full
  (today's is the Bell Sanctum); Gate B's Full Party fight is a custom setup, as it is today.
- **The fight** is today's: the fixed seed 20261011, a god-mode level 60 Gravecaller on Easy auto combat holding his ground at the walkable point nearest the room's centre, no elites, every enemy on the health and damage of the Bell Sanctum
  roster's average (272.9 hp, 10.8 damage: `DmBenchmark.STATS_ROOM`, the same in every room), waves brought in to 6 to 14 m, the count topped up and trimmed every 0.25 s, and for Full Party 72 enemies, 32 thralls and the Gravedigger King held awake
  (woken through the real summon, again after each defeat). On the core: the director spawns through `DmCoreHost.spawn_enemy`, `trim` removes the farthest extras with `remove_enemy` (no death, no corpse, no reward), the thralls are raised
  straight into the core without the cap, and every count is read from the core. `DmBenchFight` holds these rules.
- **The report** is today's (the table, the hitch log, the render breakdown) with the core's name in its header, and a **budget section** that sets the ROADMAP's budgets against this run: the combat core's step, the crowd's sync and the
  event dispatch per 60 Hz tick (`DmCoreHost.measure`, on for the measured window only) against 4 ms; the rest of the main thread per frame (the frame less the core's share, ticks a frame times its tick) against 4 ms; the HUD's main-thread
  share against 0.5 ms (the same fight with the HUD off and on, eight times over, half a second each: a share below the printed spread, twice the standard error of the rounds, is noise) and its draw calls against 150 (from the render breakdown's HUD row, so on a PC with a renderer and a Full-length run).
  Each line says PASS or MISS. The budgets are set for the headless Full Party fight on the VPS; another size, or a rendered run (where the rest includes drawing), prints them as information. The numbers are not asserted by any test.
  The render breakdown's parts are Shadows, Creatures (the crowd's MultiMeshes and the boss), World, Effects and HUD.
- **The headless frame pad:** with no window to draw, Godot waits at least 6.9 ms (`low_processor_usage_mode_sleep_usec`) after every frame, so a plain headless run shows 6.9 ms for any frame that cost less (a median within 3% of it) and hides the
  cost under it: the report warns, and does not judge the rest of the frame. `--fixed-fps 60` before `--path` has no pad and runs one tick with every frame, which is the processor test (the repo's `tests/perf/fight_breakdown.gd` runs the same way).
  It runs faster than real time, so a window counts seconds of fight by the engine's frame time (`--bench-warm`, `--bench-measure`; 30 s is 1,800 frames), and Easy auto combat keeps its cadence on the physics clock (`DmNextAutoCombat.clock_ms`),
  where a wall clock would stretch it.
- **Easy auto combat** (`next/feel/dm_next_auto.gd`) is today's decision code (`DmAutoCombat`, `DmAutoDodge`) behind an adapter that reads the core: the enemies by `enemy_ids / enemy_positions / enemy_states` (spawn order, as the nodes were walked),
  the corpses by `corpse_ids / corpse_positions`, and what those arrays lack from small tables the host's signals keep (an enemy's radius, elite flag, health, wind-up and area from the spawn, damaged and attack events; a corpse's kind from
  `corpse_added`; the dust clouds and toxic pools from `zone`). It emits the same intents as the keyboard (`DmNextInput.cast_at`, `request_move_dir`). Its gate (`allowed()`) is closed until the settings (not built) or `gate_probe` opens it.
- **The warm-up** (`DmNextWarmup`, with `DmWarmup`) runs when `opts.warmup` or `--warmup` ask for it, and the benchmark does: models and effects load on worker threads (not headless: its dummy renderer fails on them), the boss's models, the effects, the gear and the telegraph shapes are drawn
  once, every crowd model is drawn at its three levels of detail from rehearsal rows fed to the crowd (`DmCrowd.sync_rows`, with the core's tick held meanwhile so its sync does not forget them; the rows are cleared after), and the camera tours the areas
  the game has loaded, lit, with every point light off, and with the flash light. It has not been looked at on a GPU: play does not run it yet.
- **Sends:** the run's backend is the in-memory mock. A finished run is queued in `user://benchmarks/pending.json` and sent to the **test server** only (`net/dm_config.gd`): from the character select with the logged-in api, from `--benchmark` with a
  release build's saved login; debug builds, `--dev-offline` and tests never send (the run waits in the queue, and goes out when a player next enters the world on the test server). `tests/benchmark.gd` pins it.
- **In the fight as today:** rewards, loot drops and the kill ledger against the run's in-memory mock (the King's soul shards are granted to the throwaway character and charged, as today's `hold_boss`),
  and today's effects (`Vfx`), with one difference: the particle ring's per-frame loop is the core's C++ (`DmMotes`, native/README.md "Files"), which won back 0.7 ms of a Full Party
  frame on the VPS (5.7 to 5.0 ms; 2026-10-16).
- **Not in the fight yet** (it is cheaper than today's by these): the other rooms and the guests' hero bodies (as today); the benchmark plays the Gravecaller only. `native/README.md` "Differences from today's game" has the rest.

## Graphics presets

Today's Low, Medium, High and Ultra on Forward+ (DECISIONS B45): `game/dm_graphics_preset.gd` is the table and `next/perf/dm_next_perf.gd` (`DmNextPerf`, the game scene's `perf`)
applies it, ports of today's. The game scene reads the player's settings file at the start (the file today's game writes, so the test build plays at the player's preset) and the
Settings panel applies a change live, `opts.settings` in tests and the benchmark. A preset sets the moon's shadow, reach, splits
and atlas and the soft filter, bloom (`DmWfxBloom`), screen-space ambient occlusion (High and Ultra), MSAA, anisotropy and mesh LOD on the viewport, the effects quality
and the Binbun layer, the crowd's shadow policy (`DmCrowd.set_shadow_policy`: the nearest enemies that cast, today's counts, and whether thralls cast; a change reaches the
thralls already drawn) and the floor of Auto resolution, whose lower scales are upscaled with FSR 1. Brightness, fps cap, V-Sync, window mode and interface size are
today's. Not today's: the prop-light count and the prop shadow range (baked into the area's lightmap). The brightness lifts are today's numbers until the look pass.
`tests/presets.gd` (`--fixed-fps 60`, about 20 s) applies each preset to a running game and checks the lights, environment, viewport, crowd shadows and the governor.

## The seeded scenario

Gate B's "same rules" proof (ROADMAP "Now: the rebuild", native/README.md "Proof of same game", which holds the tolerances and the results): `client/tools/parity_scenario.gd` plays one scenario in this client and writes its metrics as JSON, `godot/tests/parity/scenario.gd`
plays the same one in today's game, and `tools/rebuild/compare-scenarios.mjs` runs both, one Godot process at a time at `nice -n 10`, and prints kills, damage dealt, time to kill and thrall uptime side by side against the tolerances. Seeds 1 to 5 take about 6 minutes;
`--seeds=1-20` takes about 23 and settles a close call. The scenario is the Hollow Graves with one Gravecaller at level 10 on the kit's default loadout, Easy difficulty and Easy auto combat on (the benchmark's adapter, on the physics clock), the director's normal waves and
no rewards, for 180 s of game time. Everything is read from the host's signals and the caster's events; the game scene gets no code for it. By hand: `nice -n 10 /home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client --script res://tools/parity_scenario.gd -- --seed=1 --seconds=180 --out=/tmp/client-1.json`
(`--trace=10` prints the hero's state every 10 s; `--level=` and `--difficulty=` change the scenario, on both sides alike).

## The HUD on the core

Today's HUD and panels run in the game scene (`opts.hud = true`; DECISIONS B46) as today's game composes them: `DmGameUi` (`game_ui/dm_game_ui.gd`, a copy) with every panel, on the
host-contract adapter `DmNextUiHost` (`next/hud/dm_next_ui_host.gd`, ported to the core), whose view-model is `DmNextHudVm` (`next/hud/dm_next_hud_vm.gd`, ported: it reads the core's
arrays). `DmGameUi` applies the view-model every 50 ms (`HUD_INTERVAL_MS`) to today's `DmHud` (orbs, hotbar with cooldowns and the cast state, target frame, minimap, thrall pips, XP and
level, area line, banners, toasts, floating numbers, death veil). The adapter hears the core host instead of each enemy (`_watch_core`). Nothing runs per creature per frame:

| piece | where it reads |
|---|---|
| view-model refresh | `DmGameUi`'s 50 ms (`ui_host.hud_state()`): ~0.4 ms with a Full Party crowd with the panels' own keys merged, about 0.2 ms per frame at 60 fps (`tests/hud.gd`) |
| orbs, XP, level, area | the hero body (`hp`, `resource`), the character, `DmContent` |
| hotbar, cooldowns, cast state | the hero's `DmRiteCaster` (`cooldown_left`, essence, souls); the player's loadout (`DmLoadout`, the Grimoire's) |
| "no corpse" / "no legion" dimming | one `core.corpses_in_radius` (13 m around the hero) and `core.thrall_count` per refresh |
| target frame | `core.enemy_info(id)`, `core.statuses(id)` (4 bytes a status: id, stacks, tenths of a second) for the one enemy under the cursor or last aimed at (held 4 s, `ui_host.target_id()`); chips from its affix list |
| minimap dots | `enemy_ids / enemy_positions / enemy_states`, `thrall_positions / thrall_states`, `corpse_positions`: flat arrays, filtered in one pass into the packed lists the minimap takes; an elite is flagged from `enemy_spawned` |
| thrall count, pips, red pips | `core.thrall_places`, `thrall_owners / thrall_hp / thrall_states` (under 35 % health) |
| floating numbers | the caster's `hit_number` (the rites' own events, with the impact point), the core host's `enemy_damaged` of a thrall and `status_dot`, the hero's `hurt`; `DmFloatBudget` caps them (14 hit, 5 dot, 6 thrall, 22 in all, a crit 4 past) |
| boss plate, minimap dot | `g.bosses.active_boss()` (name, phase, hp; the King's dot on the map) |
| notices | today's `DmAreaFlow` (an area's first entry, a themed wave), a refused cast (an "info" number over the hero), the boss fx's banners and the summon refusals: all `DmNextGame.game_event`, which reaches `DmGameUi` |

The upgrades box (Empower, Quicken and the wave dial), the belt (Q, Z, X), the Kill Chain, the Omen, the save chip and the pickup lines come with value ("Value on the server"); the menu row, the
panels and the Social window with `DmGameUi`. Not in the game scene yet, each with its system: the counsel (`DmNextCounsel` reads creatures: the tips item; the adapter's counsel is null), the
Chapterhouse's prompts, the Depths readout, the Altar (DECISIONS B36). The Acre ledger's panels (Skills, Garden, Laborers, Contracts) and the node and laborer cards are in ("Gathering and the Acre"). `tests/hud_feeds.gd` (`HudFeeds.full()`) fills every view-model key for the
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
**Status (2026-10-16): the budget is modelled, not yet measured in the game scene.** On this VPS a Forward+ process needs ~21 s to reach its first script line and then ~23 s inside the first main-loop iteration (software
Vulkan pipelines; it did not shrink with drawing switched off), so a 55 s run has about ten seconds left. The three runs allowed for this item produced the table above (the first, a bare scene) and nothing from the game scene
(the later two reached the end of the scene's build at 50 s). Run the harness once with a longer limit (`timeout 180 ... --budget=170`) or on Helix's PC to close it.

*The model.* `tests/hud_cost.gd` is a model of the batching rules in the table; `tests/hud.gd` first checks that it reproduces the 18 numbers the rendered run counted for the same trees, then asks it about the HUD in a Full Party fight
(72 enemies, 12 thralls, casts on cooldown, a target with four statuses, toasts, numbers at their caps): 63 draw calls as the game scene shows it (26 text, 10 vector art, 8 floating numbers, 6 toasts and banner, 3 panels, 1 rectangles
and icons, 1 borders) and 81 with every piece on and fed (41 text, 13 art). The test fails above 150, so a control left on the wrong layer or a new polygon per thing shows up in CI. Asked about logged copies of today's widgets in the same
fight the model said about 500 for the game scene's HUD (the hotbar 188, the minimap column 160, the floating numbers 104, the target frame 18) and 630 with every piece on; the benchmark counted 544 to 564 for it in Compatibility. What looks different from today's HUD, piece by piece: native/README.md "Differences from today's game", "The HUD".

*CPU.* `tests/hud.gd` prints the refresh (view-model build and apply) and a frame with the HUD against one without. With 72 enemies and 32 thralls on this VPS and today's
panel host (2026-10-16): build 0.42 ms (the core's view-model and `DmGameUi`'s own keys) + apply 0.14 ms every 50 ms; a headless frame with the HUD and panels costs about 0.4 ms more than
without (no drawing: every `_process`, tween and `_draw` callback runs); the benchmark's HUD rounds measure the same share in the Full Party fight.

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

Not yet, each with its item: the Covenant Seal's altar choice and the boss key prompt (`DmBossMeta`).
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
| core | simulates: enemies, thralls, corpses, statuses, affixes; the hero and the King are its externals | a puppet: bodies come from the wire, ease toward snapshots, events are derived from state edges and health drops |
| waves, the King's brain, rites | the director, `DmBossHost`, the casters (every player's cast is resolved here) | none: the director is off, the King is a puppet fed by `DmBossHost`'s state, a caster only asks and plays the host's events |
| crowd, effects, HUD | from its own events | from the puppet's events, the same consumers (`DmCrowd`, `DmEnemyFx`, `DmNextUiHost`) |
| kills | `kill_credited` (once per death, with the killer's peer: the hook of the kill report and the rewards) | nothing: its `enemy_died` events draw the death and credit no one |
| a hero | an external of the core (`core_id`); a guest's too | `core_id` is the HOST's id for it (told in a table): the owner id in a thrall's event, the source of a blow |

**Messages** (`next/next_net.gd`, node `Net`; the session and the rites keep their own RPCs; everything rides the session's `DmRelayPeer`: the UDP lane when the relay offers one, else the lobby's WebSocket):
- **Snapshot**, host to guest, unreliable ordered, 20 Hz: `core.snapshot_parts(tick, 1300)`. **The split:** the Full Party's snapshot is 1.2 KB on average and reaches 1.7 KB, past the 1,392-byte packet the old code stayed under (ENet fragments
  a bigger unreliable packet, and one lost fragment loses all of it), so it is cut **by body ranges**: the live enemies in spawn order, then the thralls, in as many messages as keep each at or under 1,300 bytes (the RPC frame and the relay's
  6-byte header come on top: a packet stays under the 1,364 B or so that ENet sends in one datagram, and under the 1,392 B limit of the old code). Every part is a complete snapshot message of its own bodies, with its own tick (the parts of a frame are consecutive numbers, the frame id), and **the guest applies each part as it arrives**:
  bodies are independent records, a puppet ignores a tick that is not newer, and a lost or overtaken part costs its bodies 50 ms (the next snapshot has them). Nothing is reassembled and no frame is waited for. One part is the common case.
- **Reliable batch**, reliable, every tick with content: `core.take_reliable()`, the numbered batch of spawns, deaths, zones, statuses, corpses and thralls. A guest that sees a gap (`need_baseline`) asks for a baseline.
- **Baseline**, reliable, once to a new guest (`core.baseline()`, the whole present) and again on request (at most once a second); the guest clears its crowd first. The host collects events only while a guest is in (`set_replication`).
- **Hero table**, reliable, on a join and a leave: peer id to the hero's external id in the host's core. **Vitals**, unreliable ordered, 20 Hz: every hero's health, resource and alive flag. The hero positions are the session's own snapshot.
- **Guest to host:** move intents (`DmSession`), `request_cast` (`DmRiteCaster`: the host validates the owner, the rite's rules and the aim, resolves it on its core with the guest's hero as the source, and broadcasts the rite's events, which the guest
  plays), a baseline request, and the **profile** (class and level, clamped to 100) once the session is live: the host binds that character to the guest's body, so what its caster may cast follows the level. The guest's thralls are the
  host's bodies, owned by the guest's hero external; they leave with the guest.
- **Versions (B40):** the session's hello carries the build and `DmCore.wire_version()` (`DmSession.PROTOCOL` 3); a different release build, or another wire version even between dev builds (which skip the build check), is refused with the words a
  player reads (`DmSession.version_text` / `wire_text`: which side is behind and "restart from the launcher"), and the guest's game does not start. The core's own messages also carry the wire version and a hash of the data tables: a guest whose
  first message is refused for that (not for a gap) leaves the session with the core's words (`Net.refused`). Phones will join as guests only: the same messages (B40), measured when the first phone build exists.

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
the host with its damage on both, a guest Exhume simulated by the host, the King fighting both heroes to his fall, a guest-side death and respawn, the kill accounting (the host credits every kill once, the guest none), refused versions, the Full Party's
packets and bandwidth, a leaving guest, and zero script errors. `tests/social.gd` (`--fixed-fps 60`, about 40 s, on the same local lobby and relay, its helpers from `coop.gd`) drives the Social window: the button, O, F and Esc,
hosting an Open party from the Party tab, a guest that is the real boot scene (`DmMain`) joining it from the list and leaving from its tab (main.gd's hand-over both ways), a refused join and a host who closes the party (the guest back home with the
reason), a friend request sent and answered from the windows, friends' presence over the lobby, and zero script errors. It prints INFO lines: the Full Party's bandwidth for one guest was about 28 KB/s (23 KB/s snapshots, 0.7 KB/s reliable) in 82 packets/s on the host's connection, 2.7 % and 14 % of the relay's limits (1 MiB/s, 600 packets/s); the largest game
packet was 1,231 B.

## The test server: login and character select

`main/main.tscn` (`DmMain`, a port of today's) is the project's main scene. It is today's boot and front flow (login, register, the online gate, character select, the discipline switch,
the saved login `user://dm_jwt.txt` in this project's own user folder), pointed at the **test server** (`server/death-muffin/test-server/README.md`: copies of the team's accounts, its own
database and signing key, so nothing played here can touch a live character), then the ported game scene with the chosen character:

```
/home/ubuntu/tools/godot/godot --path client            # login (the team's accounts were copied to the test server) or register a throwaway account there; pick a discipline
```

- A character that already exists skips the select screen (today's `resume()`); one whose discipline is not playable goes to the discipline switch. The online gate reads the test channel's
  manifest (`https://muffindevelopment.com/death-muffin/client-test/manifest.json`, its `online` block).
- **The character's build comes from the server**, read-only, before the game starts (`DmMain.load_build`): the bag's rows (worn gear, set bonuses, the weapon line) and the progression (damage and
  legion tier, boons, vows). `DmNextGame.build_for` builds the hero from them as today's does from the progress node and the bag, so the hero's health, spell power and loadout follow the worn gear.
  A bag or progression the server fails to give sends the player back to the login screen with the server's words; nothing is written, created or imported.
- Server errors are shown as today shows them ("Cannot reach server — check your connection", the server's own `error`, "Request failed: 502"); a stored login with the server unreachable lands on
  the login screen saying "Online opens soon", as today.
- **Value is the test server's** ("Value on the server"): the kill reports, the drops claimed into the bag, the progression's and the bag's saves all go to the test API with the logged-in character.
- **Off until their items:** the automatic crash report and the update notice. Log out, Switch character and a discipline change (Settings, the class
  panel) save and hand over as today's (`tests/front.gd` "hand-overs"). The four necromancer disciplines and the Reaper play (their hero models are in `client/assets.list`; `tests/rites.gd` "the disciplines", "the Reaper").

### The API rule (DECISIONS B38)

The rebuilt client **never talks to the live server before launch day.** Where it may talk is set in **one place**, `net/dm_config.gd` (a port of the live game's config), and enforced twice:
- `DmConfig.API_BASE` is the test API (`https://muffindevelopment.com/death-muffin/test-api`), `SITE_BASE` the test channel's folder (`.../client-test/`, the manifest), `LOBBY_URL` the test lobby (`wss://muffindevelopment.com/death-muffin/test-lobby/`) and `RELAY_PORT` the test relay's UDP port (5196). A dev run, a
  test run and an exported build all read these constants: there is no publish-time swap to miss.
- `DmHttpTransport.send` (the one door to the network, a port) refuses any URL `DmConfig.allows_url` does not accept: under the test API or the test channel's folder, nothing with a `/..` that a
  server would resolve elsewhere. It logs an error and answers like an unreachable server. `DmNextGame.start` refuses any api whose base url is not the test API or empty (the local mock).
  `DmNextParty` connects only to a lobby `DmConfig.allows_lobby_url` accepts (the test lobby, or one on this machine for a trial) and keeps a relay the lobby offers only when `DmConfig.allows_relay` does (port 5196, or this
  machine; never the live relay's 5193): a lobby that handed out the live relay is ignored and the session stays on the lobby's WebSocket.
- A finished benchmark run is sent (`DmApi.post_benchmark`) through the same transport to the test API's benchmark history, never anywhere else; "The benchmark" says when it is sent.
- `client/tests/front.gd` fails if any of it moves: the constants are the test server's and not the live API, lobby or manifest (read from `godot/net/dm_config.gd`), the allow-list refuses the live
  addresses and lookalikes, every request the flows made stayed on the test server, and a scan of every shipped file finds no address outside `net/dm_config.gd` and no live path anywhere.

**Launch day flips it** (the day `client/` becomes the game, B38/B40): in one commit, set `API_BASE` to `https://muffindevelopment.com/death-muffin/api`, `SITE_BASE` to `https://muffindevelopment.com/death-muffin/`,
`CLIENT_MANIFEST_URL` to `SITE_BASE + "client/manifest.json"`, `LOBBY_URL` to the live lobby (the values in `godot/net/dm_config.gd` that day) and `RELAY_PORT` to the live relay's (5193). The allow-list is written in those constants, so it
follows. Then change `tests/front.gd` to pin the live addresses instead (its `TEST_API` and `LIVE_API` constants and the "never the live API" checks). Until that commit the test fails on any live
address; after it the same test pins the live ones.

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

## Areas

An area is a scene built once, offline, from `godot/data/slice/world.json`: the layout `godot/world/world_builder.gd` builds at start-up today.
Twelve areas are converted: the Hollow Graves (`graves`), the three hubs (`chapterhouse`, `acre`, `alchemist_wing`) and `warren`, `ossuary`, `nave`,
`coliseum`, `sanctum`, `cloister`, `pyre`, `fen`.

```
bash tools/rebuild/build-areas.sh [area id ...]                     # sync assets, import, convert; default graves
godot --headless --path client --script res://tests/areas.gd         # every converted scene equals what world_builder.gd makes from world.json (about 10 s)
```

`client/tools/build_area.gd` is the one converter for every area (`--lenient` skips models not synced yet, for a smoke run; the Depths' floors are
generated at runtime and are not converted). Output is deterministic, so regenerating changes nothing unless the data or the converter did:

- `client/areas/<id>.tscn`: groups `Floor` (the ground quad, the paths whose centre lies in the area, the Alchemist Wing's rugs and stains, the Fen's
  hummocks), `Walls`, `Props`, `GatherNodes`, `Decals` (decals and puddles), `Water` (the Nave's channels, the Fen's bog, the Acre's ponds), `Doors`, `Lights`,
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
  ambient (`DmWorldBuilder.set_area`'s colour, same constants) is baked in too, since a lightmapped surface ignores the environment's. When
  `client/areas/<id>.lmbake` exists (a bake from `client/addons/dm_bake/README.md`; today the Graves') the converter points the node at it; an area
  without one has a `LightmapGI` with no data. Occluders: tall walls (3 m, 4 m long) and large solid
  box props (the mausoleums), shrunk so they never hide what is visible past them.

`client/tests/areas.gd` checks every converted area, one scene at a time (instantiate, check, free), and prints `PASS areas (N checks)` or a `FAIL areas: <id>: ...`
line per failed check. Each expected number is computed from `world.json` the way `world_builder.gd` computes it (its constants, `DmModels.prop_parts`, its
hummock ring mesh), never read from a scene:

- the ground and every path and door floor (theme texture, tint, roughness, glow; UVs anchored to the world; lightmap UV2), walls (position, size, the
  texture and tint `world_builder` shares per texture), props (the same meshes where `DmModels.prop_parts` puts them, shadow and visibility range), gathering
  nodes (models, an ore's three crystals, the herb, pool and tree stand-ins), decals, puddles, water, bog and ponds, the Wing's rugs and stains, the Fen's hummocks
  and rims, prop lights with their flames and the floor-pool mesh (the Nave's dimmer, smaller pools), colliders, occluders, the two decal textures pixel for pixel;
- doors: each door touching the area (and no other) with its corridor floor, and each gate's posts, lintel, bars, rails, seal and body, closed or open;
- navigation: the area's region and each door's region equal a fresh bake with `world_builder`'s settings, stop short of the walls by the agent's radius, and
  the regions and links are enabled exactly when the door is `open`; paths cross the area, join its door mouths and bend round box props; a sealed gate blocks the
  way to its corridor's far end and, once its region and links are enabled, the corridor is walkable to it;
- the lighting bake: the `LightmapGI` bakes the area's ambient and points at `<id>.lmbake` when one exists, and a bake is stale (the test fails) when a mesh it
  recorded is no longer at its path in the scene;
- the whole: one scene per converted area, and every path, wall, prop, node, decal, puddle, water rect, hummock, wing-floor quad and door of `world.json` is in
  exactly the scenes it belongs to.

A headless Godot (the dummy renderer) keeps no `MultiMesh` instance transforms set one by one, so the converter writes the gate bars' and hummocks' `buffer`
directly and the test reads them from the scene file. Every mesh that is static for the bake carries a lightmap UV2 (the test checks each), or the bake stops on it.

Not the same as today's runtime, on purpose: props are single instances of a prefab (not one MultiMesh per 12 m cell; MultiMesh cannot take
lightmaps); each floor is one quad (not 12 m tiles, which only limited per-object lights on Compatibility); there is no per-area light switching
(the lights stay on; the bake takes over) and no see-through cutout shader yet (`apply_occlusion`). Not in an area scene (a later world scene
owns them): the dark ground beyond the walls, the environment, fog, moon and rim lights; the people (`npcs`) are the Chapterhouse node's (`DmHubNpcs`). A door
between two areas is in both scenes with the same id and place (nodes carry `door_id`); `DmNextWorld` keeps the first copy it loads.

