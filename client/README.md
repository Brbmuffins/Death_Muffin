# The game client

The Death Muffin client: its own Godot 4.7.2 project, the game since launch day (2026-10-18; DECISIONS B34-B50 record how it was built and launched). `publish-godot-client.sh` publishes it to everyone; the
launcher's Test build channel keeps its last test build. The first Godot game, the old game, is kept as the tag `archive/old-game` (B57): nothing is copied from it, and this project owns all its files
("How the project is organised").

- Renderer: Forward+ (`project.godot`), Compatibility only as the automatic fallback, the Mobile renderer for phones (B35). Textures also
  import in phone formats (B40).
- Its `user://` folder is named after `config/name`, "Death Muffin (rebuild)" (KNOWN-GAPS "Leftovers from the web era").
- It plays on the **live server** and never reaches the test server ([The API rule](#the-api-rule-decisions-b38-b49)).
- The combat core is a C++ GDExtension built from [native/](../native/README.md) into `bin/` (built files are not committed;
  `bin/dmcore.gdextension` is).
- Crowds are drawn from baked vertex-animation textures, one MultiMesh per creature model and level of detail, driven by the combat core through `CrowdView`:
  [crowd/README.md](crowd/README.md).

## System guides

One short README per system folder: how the system works and its known gaps (this file holds what spans systems; the combat core, with its affixes, corpses and thralls, is [native/README.md](../native/README.md)).
- The game scene and its parts: `next/` (the scene's nodes and seams), `next/spawn/`, `next/areas/`, `next/chapterhouse/`, `next/depths/`, `next/bosses/` with the brains in `sim/bosses/`, `next/rites/`, `next/feel/`, `next/hero/`, `next/status/`, `next/enemy_fx/`.
- Value and the player's account: `next/rewards/` (with the loot node), `next/progress/`, `next/meta/`, `next/gathering/`, `next/party/` (friends, the lobby, a guest's own account).
- What the player sees and hears: `next/hud/`, `ui/hud/`, `ui/onboarding/`, `game/` (creatures, gear look, settings), `fx/`, `world_fx/`, `audio/`, `next/perf/` (graphics controls, the warm-up, the benchmark, the play reports, the F3 overlay).
- Data and shared rules: `data/`, `sim/`.

**Where features live.** Start here for a request, then read the system's README. One row per feature; paths are from `client/`, the backend side is under `server/death-muffin/backend/`.

| Feature | In the client | Backend |
|---|---|---|
| Bags, inventory, take / deposit, drag between slots | `game_ui/dm_ui_inventory.gd`, `game_ui/dm_ui_panels_b.gd`, `ui/widgets/dm_item_slot.gd`, `game/dm_inventory.gd`; rules `rules/inventory/vault_rules.gd` | `vault.cjs`, `bag-store.cjs` |
| Vault window | `ui/panels_b/dm_vault_panel.gd` | `vault.cjs` |
| Gear, Reliquary, equipping | `ui/panels/dm_reliquary_panel.gd`, `game/dm_loadout.gd`, `game/dm_gear_models.gd`; rules and data `rules/gear/`, `data/combat/armor.json`, `data/combat/necro_weapons.json` | `inventory-save.cjs`, `loadouts.cjs` |
| Abilities, rites, Reaper kit | `next/rites/`, `game_ui/dm_rites.gd`, `game_ui/dm_spell_tooltip.gd`; rules and data `rules/combat/dm_abilities.gd`, `data/combat/abilities.json`, `data/combat/disciplines.json` | `discipline.cjs` |
| Grimoire, loadouts, keybinds | `ui/panels_a/dm_grimoire_window.gd`, `game_ui/dm_loadout_presets.gd`, `game_ui/dm_ui_binds.gd`, `next/next_input.gd` | `loadouts.cjs` |
| HUD, action bar, orbs, minimap, tips | `ui/hud/`, `next/hud/`, `game_ui/dm_hud_reveal.gd`, `game_ui/dm_hud_tips.gd` | |
| Settings, logout, switch character | `ui/panels/dm_settings_panel.gd`, `game_ui/dm_ui_settings.gd` | |
| Loot drops, item cards, tooltips, dropped gear | `next/rewards/`, `loot_view/`, `ui/widgets/dm_item_card.gd`, `ui/widgets/dm_item_tooltip.gd`, `game_ui/dm_ui_inventory.gd` (Drop); rules and data `rules/loot/`, `data/content/` | `loot.cjs`, `loot-instances.cjs`, `ground.cjs` |
| Enemies, bosses, Grave Surges | the combat core ([native/README.md](../native/README.md)), `next/spawn/`, `next/areas/` (the surges), `next/bosses/`, `game/dm_boss_view.gd`, `crowd/`; data `data/combat/enemies.json`, `sim/` | `kills.cjs`, `boss-key.cjs` |
| Hero body, avatar, death pose | `next/hero/dm_hero_body.gd`, `game/dm_avatar.gd` | |
| Thralls, corpses, affixes | the combat core (native/README.md "Affixes, corpses and thralls"), `core/dm_core_legion.gd`, `core/dm_core_corpses.gd`, `core/dm_affix_roll.gd` | |
| Co-op party, friends, Social window | `session/`, `net/relay/`, `next/party/`, `next/next_net.gd`, `ui/panels/dm_social_window.gd`, `game_ui/dm_ui_social.gd` | `party-sessions.cjs`, `friends.cjs` (and the lobby, `server/death-muffin/lobby/`) |
| Crafting, gathering, garden, labor | `ui/panels_b/`, `next/gathering/`; rules and data `rules/gathering/`, `data/gathering/` | `gathering/`, `garden.cjs`, `labor.cjs` |
| F3 performance overlay | `main/perf_overlay.gd`, `next/perf/` | |
| Play reports (what a session sends when it ends) | `next/perf/dm_play_report.gd`, `next/perf/dm_play_report_queue.gd`, `main/main.gd` | the play-reports route |
| Bug report window, automatic crash reports | `game_ui/dm_bug_report_view.gd`, `main/dm_crash_watch.gd`, `main/main.gd` | `bug-reports.cjs` |
| API calls (one function per route), offline mock | `net/dm_api.gd`, `net/dm_mock_backend.gd` | the route's `.cjs` |

## Set up and test

```
bash tools/check/prep.sh                               # in every new checkout or worktree, and after switching branches: the core for Linux, the import, the crowd's baked models, the lobby's packages (tools/check/README.md)
tools/rebuild/run-client-tests.sh                      # every suite, 8 side by side, one line each (GitHub CI's "Game client tests" jobs run them split over six machines, `--shard 1/6` to `6/6`, 3 at once each)
tools/rebuild/run-client-tests.sh --only surge,value   # just those
node tools/rebuild/affected-suites.mjs                 # the suites a change can affect, plus the smoke set (--explain says why)
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/<suite>.gd   # one suite by hand
bash client/tools/coop_local.sh                        # a local lobby and relay for a trial with two game windows (prints the commands; "Co-op on the core")
```

**Numbers in tests.** A test reads the game's numbers from the data (`DmAbilities`, `DmCombatData`, the content tables) and never types a
total or a tuning value, so adding content or retuning never breaks it (CLAUDE.md, DECISIONS B59). A scenario whose outcome depends on a
number (how many casts fit in a clip, how many hits kill, how much gold a run pays) either computes its expectation from the data or makes
the number its own input: `DmQaTune.apply({"combat/abilities": {"abilities": {"<rite>": {"cooldownMs": 300.0}}}})` before the scene is built,
the old value put back (or `DmDb.reset()`) after. Server tests do the same with the rules' exported tables and constants. Fixed design rules
(loot expires in 3 minutes, a party of 4), protocol constants, the parity fixtures and the CLAUDE.md budgets stay typed.

**Suite names.** A suite is named after the system it protects, in snake_case, as a player or the code would call that system: `<system>` (`hud`, `gathering`, `spells`), `<system>_<part>` when one system has several suites (`boss_mire`, `benchmark_rooms`), `core_<part>` for the combat core's own suites and `rules_<area>` for the shared rules' fixtures. A suite with more than one runner is a folder, and each runner is named after what it runs (`lobby/ui`, `relay/udp`). Names carry no history (no `next_`, `game/` or `perf/`, which came from the first game's folders): a renamed or deleted suite's old name is retired in `tools/hygiene/retired.json`.

A new suite goes into `SUITES` in `tools/rebuild/run-client-tests.sh` (and into `PACED` if it plays game time): `npm run hygiene` fails on a suite file the list does not name, a listed name with no file, and a `PACED`, `LANE` or `WAITING` name that is not a suite; a helper that is not a suite goes in `notSuites` in `tools/hygiene/retired.json`.

A suite passes with exit 0, a `PASS` line and no `SCRIPT ERROR` in its log. The runner gives every suite its own user folders, so suites can run side by side, and runs up to five failures again alone at the end. The paced suites
(`PACED` in the runner) play game time faster than real time: by hand they take `--fixed-fps 60` before `--path` (`game_scene`, `rites` and `boss` run faster that way too). Most suites that draw creatures bake the models they need into a scratch folder.
Run `tools/check/prep.sh` in every new checkout or worktree (it lists the extension before the first import; see the script): a script run in a project that was never imported hangs.

| Suite | What it checks |
|---|---|
| `core_smoke` | the core loads and answers |
| `core_api` | queries in spawn order, synchronous kills, events, seeded stats, the rise and the 4 s body linger, the navmesh regions (added, switched, replaced, emptied) |
| `core_enemies` | the Graves roster: bite timing, cone, dust cloud, slam, hit-and-run, tunnel and eruption, leash, a body's own aggro and leash, stagger, stun, crowd spacing |
| `core_status` | the status set: the 0.1 s step, DoT lumps, stacking and ownership, multipliers, stun, dig-in clear, Withered on death, wire bytes |
| `core_corpses` | kinds, the order in a death, extra corpses, the cap, lifetime, toxic rupture and its pool, the pick and consume rules |
| `core_thralls` | the rise, caps and make_room, formation and leash, the scan and the boss edge rule, the swing and its multipliers, kinds, enemies choosing and hurting thralls, deaths and bursts, statuses on thralls, rally, separation, tick order, the compiled-in defaults against the data |
| `core_affixes` | each affix's timers, the pause while staggered, Vengeful inside a call and inside a DoT tick |
| `core_kinds` | the kinds the other areas add: the Ossuary's golem (slam) and deacon (keep-away, curse, raise, Sanctify, silence), the Drowned Nave's censer (incense), acolyte (curse, Unbind), gargoyle (dive), templar (shield) and wraith (scream), the Sanctum's and Cloister's seraph (curse, ward), plague doctor (flask, pool) and flagellant (frenzy), and the Cinder Pyre's and the Mourning Fen's husk (embers), priest (coal), hound, slag brute (slam pool), hag (hex), leech, wisp (pulse, lure) and sexton (chain); their co-op wire, the rosters, seeded replays |
| `core_boss` | what the bosses call on the core: the Skull Niche (the rise, no blow, no flinch, never moved, no corpse), a body's health, a boss's zones (toxic rot, ember), their wire |
| `core_coop` | two cores: a real fight, 20 Hz snapshots and batches into puppets, loss and reordering, a late guest and a lost batch, refusals, damaged messages, the commands and queries on a puppet, `DmCrowd` on one, the Full Party's size and cost, `snapshot_parts` (`-- --verbose` lists every check) |
| `code_load` | every script, scene, resource, shader and JSON file the export ships loads, and none names a per-creature class |
| `areas` | every converted area scene against what `world.json` says (about 10 s; "Areas") |
| `crowd_bake` | the crowd baker and shader (30 s; "Proof" in client/crowd/README.md) |
| `crowd_view` | the crowd's views, their cost (culling against the engine's frustum, the animation bands, the shadow counters), the alpha path (sinking and shrouded bodies in the fade groups) and a Full Party (about 20 s) |
| `draw_budget` | the 3D draw calls of the Graves' Full Party counted from data: the crowd shows only the groups that hold instances, the world and the whole stay inside their budgets, and 24 bodies sinking with three shrouded elites cost the crowd two draw calls more ("The draw budget"; about a minute) |
| `game_scene` | the game scene on the core: 60 s of an offline run in the Graves |
| `warm_coverage` | the warm-up covers what play uses: every material of the five disciplines' hotbars and kits, a fight, the boss, waves, loot, hurt and healed, worn gear and pets is one the loading screen drew; each gap is printed with its node and rite (about a minute; `next/perf/README.md`) |
| `rites` | every rite of the playable kits (the necromancers' and the Reaper's) on the core, a fight (90 s of game time; "The Gravecaller's rites") |
| `spells` | every spell of every playable class, read from the kits and disciplines in `data/combat/` (a new spell or playable class is covered with no edit): one game per discipline; the rite, ability row, icon, name and description; the cast through the hotbar or the caster pays the row's cost and cooldown and a second cast is refused; the spell card shows them; effect, sound and warm-up; each discipline's mods; zero errors |
| `boss` | the Gravedigger King on the core: his brain replayed against recorded scenarios, his fight, the thralls, the rites, his defeat and a new summon |
| `boss_abbess`, `boss_congregation`, `boss_prelate`, `boss_saint`, `boss_regent`, `boss_mire` | the six other bosses, one suite each on `boss_base.gd`: the recorded scenarios replayed, the summon at its altar, its fight by hand, thralls, rites, wipe, defeat and rewards, the real clock (about 30 s each; "The bosses") |
| `boss_meta` | the Covenant Seal's Empowered call and the boss key prompt on the mock backend, the first-kill trophies, a bound summon |
| `front` | boot, login, character select and the game scene with the chosen character on the mock; the API rule |
| `hud` | the HUD on the core: target frame, minimap dots, hotbar and cooldowns, thrall pips, floating number caps, pools, pieces, z layers, the draw-call model |
| `auto_combat` | Easy auto combat's decisions: golden cases, seeded Full Party fights for the necromancer's rites and the Reaper's, the movement; INFO: a decision's time |
| `benchmark` | the benchmark on the core, part 1 of 5 (`benchmark_base.gd` is what the five share: their own folder for the models and every file, nothing sent anywhere): the setup and its refusals, the team app's flags as parsed, the fight held as the setup says, Easy auto combat, the frame split, the Full Party report and its budget section, the render breakdown, the setup window |
| `benchmark_rooms` | the benchmark, every combat room's short Full Party run: its own area, roster, boss held awake (or none), report |
| `benchmark_classes` | the benchmark, every class's short run, the screen's run sent to a mock, Esc cancels, nothing leaves the process |
| `benchmark_launch` | the benchmark, real `--benchmark` launches (the Graves in Full Party, the Fen with the Reaper) that print the report and quit by themselves |
| `benchmark_flags` | the benchmark, the launch line's flags: `--bench-crowd=`, a room, class or preset it does not list refused with exit code 2, `--bench-preset=` and `--bench-quit` |
| `play_report` | the play reports ("Play reports" in next/perf/README.md): the numbers on known frame sequences, the contract's shape, a real offline game scene, the autosave and the crash, the queue's cap, sending through the mock, nothing leaving a script run, and `DmMain`'s wiring on the mock (about 20 s) |
| `coop` | 2-player co-op: a host and a guest in one process over a real local lobby and relay (needs `cd server/death-muffin/lobby && npm ci`; about a minute; "Co-op on the core") |
| `coop_bosses` | the six other bosses fight a party of two, summoned by the guest, in the whole world over the same lobby and relay: state, telegraphs, events, zones, adds, blows and effects on the guest's hero (and its hurt on its window), the phases, the defeat by the guest and both accounts paid, a wipe (about 70 s) |
| `dressing` | the world dressing on the area scenes: its pieces in the loaded areas, the stand-ins gone from the scenes, the area by event, the brazier fire's closed form against a frame-by-frame step, the mist's rate, the earth beyond the walls, the Binbun shaders' colour (about 15 s; "World dressing") |
| `presets` | the graphics presets on a running game: lights, environment, viewport, crowd shadows, the governor, the lift of each area and its blend (about 30 s) |
| `rewards` | the rewards node on the core, on the mock: sessions, batches, lost replies, refusals, the end, per-member loot |
| `value` | value on the server in the game scene: kills, accepted XP, the purse, a claimed drop, brews and lifesteal, the meta, the belt, saving ("Value on the server") |
| `fx_motes` | the effects' particle ring in C++ (`DmMotes`: the bursts' random starts and the per-frame loop): every float of the ring's buffer, bursts in every colour form; INFO: its update time |
| `fx_decals` | the ground decals in C++ (`DmDecals`): every drawn float, the counts and the handles over two seeded runs and the cap of 160; INFO: its update time |
| `panels` | every panel opens, the Reliquary (equip, sell, sort) on the server's bag, the loadout, Settings live, chat |
| `gathering` | gathering and the Acre: all 68 nodes hovered and clicked, a node worked through the server (cycles, batches, finds, XP, spent and back), the stops, AFK and its report, the Grave Laborers, a collection, the garden, a contract, the Sexton ("Gathering and the Acre"; about 25 s) |
| `world` | the whole world: every area, seals and gates, into the Warren, waystones, the recall, the core's navmesh against the server's, the Ossuary's deacon and golem, the Nave's five, the Sanctum's, Coliseum's and Cloister's rosters and the Pyre's and the Fen's eight in the game scene, the waves following the hero from area to area |
| `surge` | Grave Surges on the core: the clock, the crypt, three waves, the deaths by id, the offering and the failures, by hand and through the director ("Grave Surges"; about 25 s) |
| `counsel` | the counsel and the first hour on the core: the fight facts read two ways, every fact the creatures give the counsel once, the tips each makes once, the state-driven tips, the welcome and the Next-step box, the Prior, Show tips again ("Tips and onboarding"; about 30 s) |
| `sound` | sound on the core's events: a scripted fight's cues by name and count, thralls, the hero's footsteps, the area beds and scores, the gate, the boss score ("Sound"; about 30 s) |
| `depths` | the Catacomb Depths on the core: the rules, the Warren's stair, floors baked at run time and the core's copy of each, the dead on a floor, the quota, the chest, leaving, death, 14 floors (about 40 s) |
| `threads` | the work off the main thread: the list of what starts a thread, the audio bus layout edited only under the mixer's lock, the Depths' floor generator and the Atlas' verdicts on a worker against the main thread's, the guard (about 6 s; "Threads") |
| `crash_note` | the core's crash note: the format, a real crash inside the core in a child process, Godot's handler still running after it, the report carrying it |
| `qa_shots` | the screenshot tool of proposals without a renderer: the plan, a plan's set-up on the game scene, the fight, the clips and tune (plan, frame writer, a recorded clip, every refusal), the release checks, real launches, `client/tools/qa_shots.sh` against a stand-in for godot (about 110 s; "Screenshots for proposals", "Release checks") |

Rendered, not headless (software GL, one run at a time; the header of each has its command): `crowd_smoke` (the crowd material beside skinned robbers), `crowd_view_smoke` (`CrowdView` on a small core),
`crowd_look_smoke` (the crowd's thralls beside the same thralls skinned as nodes, in the Graves' lighting, with the mean colour of each: Forward+ and Compatibility) and `crowd_fade_smoke` (the alpha path: a solid robber beside one under the Shrouded ward and one sinking away, measured by pixels;
client/crowd/README.md "The alpha path").

`tools/rebuild/run-client-tests.sh` sets `DM_SYNC_NAV=1` for every suite it runs under `--fixed-fps`; a suite that asks for paths in a region enabled moments before (a seal broken, a floor baked) also sets it itself (`OS.set_environment("DM_SYNC_NAV", "1")` in `_initialize`, as `tests/world.gd` does), so it holds when run by hand:
the navigation server merges a new region on a worker thread of its own and a game under `--fixed-fps` outruns it on a loaded machine, so a path asked before the merge ends on the nearest ground
that is merged and a body walks away from where it was sent. The variable makes the merges synchronous, in step with game time (never set in the game).

## How the project is organised

The game owns all its files. `client/` is one Godot project: a script, scene, data file or asset is changed here and committed here, and nothing is copied or synced into it from another folder. The old game's source is only the tag
`archive/old-game`. Class names are `Dm*`, and the game's content has one source of truth, in `data/` and `rules/`. The system guides above say how each system works; this is where things live:

| Folder | What lives there |
|---|---|
| `main/` | the boot (`main.tscn`, `DmMain`): launch arguments, the hand-over from the front flow to the game, the `Packs` autoload, the camera rig, the F3 overlay, the crash watch and the QA driver |
| `front/` | login, register, the online gate, character select |
| `net/`, `net/relay/` | the API client (`DmApi`, one function per route), `DmConfig` (the endpoints), the HTTP transport and the offline mock backend; the lobby client, the relay peer and the UDP lane |
| `session/` | `DmSession` and `DmSessionBody`: host or join, the hero bodies, move intents |
| `core/`, `crowd/` | the combat core's host (`DmCoreHost`) and the adapters the rites call; the crowd that draws the core's creatures ([crowd/README.md](crowd/README.md)) |
| `next/` | the game scene (`next_game.tscn`, `DmNextGame`) and its systems, one folder and README each ([next/README.md](next/README.md)) |
| `rules/`, `data/`, `sim/` | the game's rules in GDScript (the server's rules and these are held together by parity fixtures: `server/rules/README.md`), its content as JSON read through `DmDb` ([data/README.md](data/README.md)), and the shared simulation classes: the boss brains, the Depths' floors ([sim/README.md](sim/README.md)) |
| `game/`, `game_ui/`, `ui/`, `loot_view/` | the shared in-world classes (creature and avatar views, the gear look, settings, the graphics preset), the UI host `DmGameUi` with its panels' glue, the HUD, panels, widgets and theme, and the personal loot view |
| `world/`, `world_fx/`, `areas/` | the lights-only world builder, models and animator; the world dressing; the converted area scenes with their lighting bakes |
| `fx/`, `audio/` | the `Vfx` and `AudioDirector` autoloads |
| `assets/` | art, models, audio and effect data ("Assets") |
| `dev/`, `tools/`, `addons/`, `tests/`, `bin/` | the dev entry; scripts for bakes, probes and measurements; the lighting-bake editor plugin; the suites; the combat core's built libraries (`bin/dmcore.gdextension` is committed, the libraries are not) |

**No per-creature code.** Enemies, thralls, corpses and affixes run in the combat core and are drawn by the crowd ([native/README.md](../native/README.md), [crowd/README.md](crowd/README.md)); an enemy is an id everywhere, and `tests/code_load.gd` fails when a file names a class or path of the
old per-creature systems. Only heroes and bosses are nodes with skeletons; their statuses are `DmStatusSet`'s (`next/status/`), an enemy's or a thrall's are the core's.

**`project.godot`** holds the autoloads (`Packs`, which loads the assets pack, `AudioDirector` and `Vfx`; the QA tools are started by the boot and have no autoload, "Screenshots for proposals"), the display and theme settings the UI layout assumes (a 1600x900 viewport,
`canvas_items` stretch, `dm_theme.tres`), 60 Hz physics (at most 3 steps per frame, physics interpolation), the renderer (Forward+, Mobile for phones, desktop and phone texture formats), the main scene (the boot, `main/main.tscn`), the physics layer names (world, player, enemy, thrall), the
import default that gives models lightmap UV2 and the global shader parameter `dm_lift_inv` ("The look on Forward+"). It is an input of the art pack's fingerprint (`tools/godot/assets-fp.sh`): a change there, even a comment, makes every player download the art again. Input actions are registered at run time
(`DmNextInput.ensure_actions()`), and the only `ProjectSettings` read, `application/config/version`, has a default.

## The game scene and the dev entry

`next/next_game.tscn` (`DmNextGame`) is the game on the combat core: **the whole world** (every area but the Depths, whose floors are made when a run starts, "The Depths"; the hero starts and gets up in the Chapterhouse),
with the character the front flow chose on the live server (below) or, from `dev/dm_dev_entry.tscn`, a dev character on the local mock backend in the Hollow Graves alone (a quick fight; `-- --dev-offline --class=2` on the normal boot enters the whole world instead). **The dev entry reaches
no server**: the backend is `DmOffline.make_mock` (accounts in this project's own `user://dm_dev_offline_db.json`) and has no base url. `DmNextGame.start` refuses any api whose base url is not the live API's or empty (the mock): "The API rule".

```
bash tools/check/prep.sh                               # once per checkout: the core, the import, the crowd's baked models (without them nothing is drawn)
/home/ubuntu/tools/godot/godot --path client            # the boot: login and character select on the live server, then the game (below)
/home/ubuntu/tools/godot/godot --path client -- --dev-offline --class=1             # the same boot with the local mock backend and no network at all: straight into the whole world as `tester` (--seed=N --no-waves --baked=<dir> too)
/home/ubuntu/tools/godot/godot --path client res://dev/dm_dev_entry.tscn           # the dev entry: the Graves alone, the Gravecaller at level 10, the HUD, waves. He fights with the rites (controls below)
/home/ubuntu/tools/godot/godot --path client res://dev/dm_dev_entry.tscn -- --class=1 --seed=7 --crowd=70      # options after `--`: --class=N --level=N (default 10) --seed=N --no-waves --crowd=N (a first wave of N bodies 6 to 12 m around the hero) --boss (the hero starts at the King's grave and wakes him) --baked=<dir> --shot=<png> [--shot-after=<game s>] (rendered runs only)
```

**Controls of the dev entry**: **LMB** on the ground walks there, on an enemy walks into range and casts the primary (Bone Needle; hold to repeat, Shift+LMB casts in place);
**1-4** are the kit's default loadout (Marrow Spear, Exhume, Miasma, Black Litany; hold a key to repeat), **RMB** is Corpse Explosion, **R** the signature from level 10 (Command: Rend), **WASD** walks, the wheel
zooms. The Grimoire puts the other rites on the keys; tests cast through `DmNextInput.cast_at(slot, aim, enemy_id, true)` or the caster's `request_cast(rite, aim)`. `--level=N` sets the level the mock
character is made at (R needs 10, Bone Mantle 12, Bone Storm 14; all rites unlock by 14). `--class=11` is the Reaper: **LMB** Scythe Sweep, **1-4** Scythe Throw, Reap, Wraith Walk and Soul Burst,
**RMB** Harvest Spin, **R** Unleash Souls; every rite but the swings pays souls from her bag (10 to start, 30 at most), and every kill credited to her banks one.

**`DmCoreHost`** (`core/dm_core_host.gd`, the scene's `Core` node) is the one owner of the `DmCore` and the `CrowdView`. It loads the data (`DmCoreData.load_all`: this project's `data/` and the numeric constants of `sim/sim_consts.gd`; the
corpse field's and the thralls' constants are compiled into the core, and `core_thralls` checks them), seeds the core and
gives it the area's navigation map and bounds, and registers each hero body as an external (position and alive flag written before every step). Its tick runs at
`process_physics_priority` 100: after the session (which moves the hero bodies) and the director (which spawns), before the crowd's own 1000. A tick is `core.step`, `CrowdView.sync()`, then
`core.take_events()` once, decoded in order into one typed signal per event kind (`enemy_spawned`, `enemy_state`, `enemy_damaged`, `enemy_died`, `enemy_attack`, `telegraph`,
`target_hit`, `target_effect`, `zone*`, `corpse_*`, `thrall_*`, `status_*`, `affix_moment`; `core/dm_core_events.gd` has the numbers). Systems connect to the signals; nothing polls per creature, and
**no node and no script exists per creature**: an enemy is an id (an int) everywhere, and `enemies_in_radius`, `enemy_position`, `damage` and `apply_status` are thin queries on the core.
`CrowdView._process` draws the rendered frames with `Engine.get_physics_interpolation_fraction()`.

The pieces around it: the **world** (`next/next_world.gd`) loads the area scenes (`areas/<id>.tscn`; `opts.areas` takes a shorter list, the tests' Graves) with
a small API (`area_at`, the navigation helpers, `spawn_point`, the seals and gates: `set_unlocked`, `set_door_open`, `gates`, `nav_regions`), keeps a
`DmWorldBuilder` for the area's lights only, and gives the core its copy of the navmesh (`bind_core`; DECISIONS B47); the **Chapterhouse** (`next/chapterhouse/dm_chapterhouse.gd`) breaks a seal
when the kills in the area before it reach its count (the banner, the gate rises, the navmesh joins; a party's guest sees the host's seals, "Co-op on the core"), runs waystone travel and the recall home (T),
opens the stations' panels and animates the people; the **director** (`next/spawn/dm_wave_director.gd`) spawns through `core_host.spawn_enemy` with the affix
roll (`core/dm_affix_roll.gd`), counting from the core; the **hero** (`next/hero/dm_hero_body.gd`) takes the enemies' blows from `EV_TARGET_HIT` with the enemy's id as the source, and their chills, roots and drags (the Hag's, the Wisp's, the Sexton's chain) from `EV_TARGET_EFFECT` (`DmNextGame._on_target_effect` hands each to `DmHeroBody.dm_enemy_effect` when the tick's events are dispatched; a hero the blow killed refuses it; a boss's chill or root is the boss host's);
**input** (`next/next_input.gd`) picks the hovered enemy at 10 Hz by asking the core for the bodies within 4.5 m of where the cursor's ray crosses the plane 0.9 m above the ground and taking the one whose chest is nearest the cursor on screen within 46 px; **enemy effects** (`next/enemy_fx/dm_enemy_fx.gd`) play the telegraphs, strikes (timed from the
wind-up), deaths, voices, dust clouds and burning ground and the affixes' bell, meal and burst from the host's signals, through the same router and the `Vfx` and `AudioDirector` autoloads.

Co-op and the Social window ("Co-op on the core"), value on the server ("Value on the server"), the HUD and panels ("The HUD on the core"), the Reaper ("The Gravecaller's rites"), gathering with the Acre ("Gathering and the Acre"), the Depths ("The Depths"), Grave Surges ("Grave Surges")
and the graphics governor ("Graphics presets") are all in the game scene. The waves follow the heroes from area to area: the director moves to the combat area a hero stands in, and the ground left behind is cleared at once (its living bodies sent away through the core, no death or corpse),
as is one nobody has stood in for 15 s. Easy auto combat opens from Settings ("The benchmark"). `tests/world.gd` plays the whole world: seals, gates, walking from the Chapterhouse into the Warren, waystones, the recall, the waves following the hero. How the core behaves is
`native/README.md` "Design".

## Screenshots for proposals

The Discord agent shows a change with pictures taken from the game itself: the client started as the dev-offline hero `tester` on the local mock (no server, no network) with a **shot plan** that opens windows, shows an item's
tooltip, dresses the hero in gear and saves one PNG a shot. The driver is `main/qa_driver.gd` and the plan `main/qa_ui_shots.gd`; `game_ui/shoot.tscn` shows the panels over a mock game (`-- --page=<name> --out=<png>`, pages in `shoot.gd`).

```
bash client/tools/qa_shots.sh <plan.json> <out_dir> [class]                                         # on the VPS: PNGs in <out_dir>/<shot name>.png; class 1-4 or 11, default the plan's `discipline`, else 2
godot --path client -- --dev-offline --class=2 --qa --shot-plan=/abs/plan.json --shots=/abs/dir    # the launch line itself (it needs a screen); --qa alone plays a scripted fight in the Graves (--seconds=N)
godot --path client -- --dev-offline --class=2 --qa --shot-plan=/abs/plan.json --shots=/abs/dir --preset=low    # the same on the Low preset (low, medium, high or ultra), as a team PC takes a proposal's pictures
```

- **Launch:** `DmMain.start_qa` starts the driver (its child `Driver`) for `--qa`, `--shot-plan=` or `--clip-plan=` ("Clips and tune") on a `--dev-offline` start of a debug build only (`DmMain.qa_wanted`; a release export ignores `--dev-offline`). It is loaded by path,
  so no other start compiles it, and the project file lists no autoload for it: `client/project.godot` is an input of the art pack's fingerprint, and an edit there makes every player download the art again. `--shots=<dir>`
  defaults to `shots/` in the repository (ignored by git). Lines start with `QA-SHOTS`; exit code 0 = every picture written, 1 = one was not (a headless run draws nothing), 2 = a refused plan or no game.
- **Preset:** `--preset=<low|medium|high|ultra>` puts the run on that graphics preset from the game's start, as if it had been chosen in Settings (the team app takes a proposal's pictures on Low and on Ultra). It is honoured only where
  the QA tools start (`DmMain.qa_preset`: a debug build on the dev-offline backend with `--qa` or `--shot-plan=`); an online start, a release export or a launch without those flags ignores it, and an unknown value is ignored with a
  `QA-SHOTS warning:` line. The preset is never saved: the game scene takes it from `opts.qa_preset`, and the HUD's `DmSettings` holds it on loan (`session_set`), so the player's settings file keeps what the player stored (only an explicit
  different choice in Settings is saved). The driver prints `QA-SHOTS preset <id>` once the game is up.
- **No keyboard, no mouse:** a QA run never takes either from the person at the PC (a team PC runs it while its owner works): the boot sets the main window to take no focus (`unfocusable`, `WINDOW_FLAG_NO_FOCUS`) and to pass
  mouse events through (`mouse_passthrough`, `WINDOW_FLAG_MOUSE_PASSTHROUGH`) in `DmMain.quiet_window`, only where the QA tools start, and says so in a `QA-SHOTS window:` line. The plan needs no real mouse (it opens windows through the
  HUD's own calls and fakes its hover). A headless run has no window to configure, so the test checks the call path (the flags on a window of its own, the boot's line, no line without the QA flags), not that Windows honours them; that is
  confirmed on a team PC.
- **Bigger than the screen:** the window is the size a QA run asks for with `--qa-window=WxH` (the team app sends it beside the engine's `--resolution`, which Godot keeps out of
  the game's arguments) even when the PC's screen is smaller (`DmMain.full_size_window`: Windows holds a window to the screen unless it names a larger maximum, so its `max_size`
  is set to the asked size), and a `QA-SHOTS window: WxH asked, WxH now` line says what it got.
- **Plan:** the agent's (`server/death-muffin/discord-agent/PROMPT-godot.md` "Screenshots"; the header of `main/qa_ui_shots.gd`). `DmQaUiShots` cuts a run into `prepare` (the bag, the gear worn), `stage` (area, windows, view, tooltip) and
  `capture` (the picture, its crop), so a plan's set-up is tested without a renderer. A plan holds at most 6 shots and a longer one is refused (`QA-SHOTS plan error:`, exit code 2), not trimmed. A shot with `"fight": true` makes its wait (`wait_ms`, 3000 or more) a real fight for a picture of the HUD in
  combat: eight of the Graves' robbers are made in a fan 6 to 9 m ahead of the hero and, every 0.4 s, the hero casts at the nearest with its health and resource topped up, the pack made up again when it thins. Without it a dev-offline start's waves are still climbing out 18 m away after four seconds (measured: twelve enemies
  alive, none on screen, nothing cast or hit); with it at four seconds eight or more enemies are on screen, the nearest 1.4 m away, and the hero has cast eleven times and hit five.
- **Script:** Forward+ on the software Vulkan driver (lavapipe), `xvfb-run`, `nice -n 10`, one renderer at a time (it waits up to 15 minutes for `qa-browser.lock`), 10 minutes at most, a scratch user folder. If Vulkan cannot start, the
  run is repeated on OpenGL 3 and a line says the pictures use the fallback renderer (not the game's look). It needs `tools/check/prep.sh` once per checkout (the baked crowd only for a plan with enemies). Two shots took 4 min 43 s on
  2026-10-18, most of it the world's start. `DM_QA_LOG=<file>` keeps godot's log; `--help` lists the rest.
- **Test:** `tests/qa_shots.gd` (headless, about 110 s): the plan, a plan's set-up on the game scene, the scripted fight, the preset flag (where it counts, the loan that is never saved, a game scene started on it), the clip plan, the frame writer, the tune and a clip recorded on a Reaper's game scene ("Clips and tune"), the release checks' flags and short runs ("Release checks"), real headless launches, and the script against a stand-in for godot (the fallback, the lock, the time limit).

### Clips and tune

A team PC can also record short videos of a rite in use, and run the game with some data numbers changed: the pictures of "which of these three speeds do you like best?". Both are QA runs, honoured where the QA tools start (`DmMain.qa_wanted`: a debug build on the dev-offline
backend with `--qa`, `--shot-plan=` or `--clip-plan=`); a release export, an online start and a launch without a QA flag ignore every flag below. Start the engine with `--fixed-fps N` and the same `--clip-fps=N` (30 by default; the team app records at 60): one frame is then 1/N s of game time, however long drawing and reading it back takes.

```
godot --fixed-fps 30 --path client -- --dev-offline --class=11 --clip-plan=/abs/plan.json --clips=/abs/dir [--tune=/abs/tune.json] [--preset=high]    # a team PC's line, with the window rules of the shot runs
```

- **Clip plan** (`main/qa_clips.gd`, `DmQaClips.parse`): `{"discipline": "reaper", "equip": ["<item id>"], "clips": [{"name": "wraith", "area": "graves", "cast": "haunting_wraith", "at": "pack" | "ahead", "enemies": 6, "seconds": 5, "camera": "follow" | "wide" | "turntable", "equip": ["<item id>"]}]}`.
  At most 4 clips, 1 to 8 s each and 0 to 12 enemies (more or less is clamped, with a printed `QA-CLIPS note:`), a name of letters, digits and hyphens (at most 32; a taken name gets a number; `clip-<n>` when none is given). `cast` is a rite with a module in
  `next/rites/dm_rite_registry.gd` (Grimoire-only rites too); `area` any area of the world (default the Graves); `discipline` is the class the game has to run as: the launch passes `--class=N`, and a game of another class is refused with a line and exit code 2 (a clip of the wrong hero is worse than none).
  `at` places the stand-in enemies: `pack` = bunched round a point 8 m in front of the hero (the rite is aimed at the middle of them: a burst, a cloud, a thrown thing), `ahead` = in a line down the way the hero faces from 4 m away, 2.5 m apart (the rite is aimed down the line: something that travels).
  `camera`: `follow` is the game's own camera, `wide` its widest zoom. The hero always faces up the screen (-Z, the fixed camera's far side).
  **Model previews:** `equip` (at most 12 item ids a hero can wear; an unknown or unwearable id refuses the plan) is what the hero wears: at plan level for every clip, and optionally in a clip, where its own list wins (an empty list is a bare hero). The pieces are put on through the backend's
  equip call like the shot plan's `equip`, and a piece worn that is not in a clip's list is taken off first, so each clip shows exactly its list (a plan that names items anywhere sets what is worn for every clip). `camera: "turntable"` frames the hero in the shot plan's close-up (HUD away) and turns the hero once round,
  slowly and in place, over the clip, standing idle: a turntable clip needs no `cast`, its `area` is the Chapterhouse unless it names another, its `seconds` 6 and its `enemies` 0 (a `cast` or enemies may be added). A clip with no cast has `cast_at_frame` -1.
- **Setup and steps** (`main/qa_clip_steps.json`, `DmQaClips.vocabulary`): a clip may carry `"setup": [{"do": "<word>", ...}]` (how the scene is set before recording) and
  `"steps": [{"at": <seconds>, "do": "<word>", ...}]` (what happens when, run in the order of their times). The words, their arguments, types and ranges are that file's: today
  `hud` (show the HUD), `stand_ins` (their kind, health as a multiple of normal, harmless or not, `fight`: they come at the hero, `distance`: how far ahead they start), `souls` (the Reaper's souls at the start), `top_up` (fill the cost before each cast or not)
  and the step `cast` (a rite at a set time; a busy or cooling rite is tried again each frame, another refusal fails the clip; a clip with cast steps casts nothing by itself and needs no `cast`).
  A new word is an entry in that file, its handler here (`SETUP_WORDS` / `STEP_WORDS` and the code that carries it out) and a check in `tests/qa_shots.gd`, which fails when the file and the
  recorder disagree. The Discord agent's runner checks a request against the branch's own copy of the file, so a word added in a change works in that change's videos at once.
- **What a clip run does:** once the game is up, for each clip: the HUD is hidden, the waves, Grave Surges and idle wandering are off (the stand-ins are the only enemies), the hero stands at the area's waystone, the stand-ins (Graves' robbers with 400 times the health and no damage, standing where they are put, so a tune
  that raises the rite's damage can kill neither them nor the hero, and every variant shows the same scene) rise, the scene stands still for 1.5 s, the rite's cooldowns are cleared (a clip after another starts as the first did), and the viewport is recorded. The rite is cast 6 frames in (the first frames show the scene before it) and again each time it is off cooldown
  (the hero's souls or essence are topped up first, so a cast is never refused for its price). A cast the host refuses for another reason (`souls`, `locked`, ...) fails the clip with a line and no file. No sound is recorded (the runs are silent: `--audio-driver Dummy`); the window rules of the shot runs apply (`DmMain.quiet_window`: no focus, no mouse).
- **Output:** `<dir>/<name>.mjpeg` is the frames' JPEGs one after the other (`DmQaMjpeg`: each starts FF D8 and ends FF D9; quality 85; the viewport's picture scaled down to 960 px wide, never up, both sides even), and `<dir>/<name>.json` is `{"fps": 30, "frames": N, "width": W, "height": H, "cast_at_frame": F}` (the index of the first
  frame that shows the first cast). `ffmpeg -f mjpeg -framerate 30 -i <name>.mjpeg ...` makes the video. Frames are taken from game time (30 for each game second), so a frame step other than 1/30 s only repeats or skips pictures, never changes the clip's speed (a `QA-CLIPS note:` says so).
  **Rate and size:** `--clip-fps=N` (10 to 60, with the engine's `--fixed-fps N`) and `--clip-width=N` (320 to 1920) record N frames a game second and pictures up to N wide (`DmQaClips.options`; a value out of range keeps the default, with a note), and the json's `fps` says the rate.
  The team app (0.4.5) records 1080p at 60 with `--fixed-fps 60 --resolution 1920x1080 -- ... --clip-fps=60 --clip-width=1920 --qa-window=1920x1080` and makes the mp4 on the PC (Helix 2026-10-19); the 0.2 s before the first cast stays 0.2 s at any rate. A clip that fails leaves neither file. Lines start with `QA-CLIPS`;
  exit code 0 = every clip written, 1 = one was not (a run with no renderer: a headless run draws nothing, a refused cast, a picture source that gives none), 2 = a plan or class the run cannot use.
- **Tune** (`main/qa_tune.gd`, `DmQaTune`): `--tune=<abs json>` is `{"<data file>": {<the file's own nested keys>: <value>}}`, e.g. `{"combat/abilities": {"abilities": {"haunting_wraith": {"speed": 5.5}}}}` (the data file is a `DmDb` path: `DmDb.all_files()`). The boot merges it into the registry's cache (`DmDb.raw`) before the game scene is built, so the rules (`DmAbilities`, `DmCombatData`),
  every view and the combat core read the tuned numbers: the core's tables come through the same cache (`DmCoreData.json`), a registry projection (the loot and progression views) is rebuilt from it, and the data files themselves are never written. It prints `QA tune: combat/abilities.abilities.haunting_wraith.speed = 5.5` for each value. Only keys the file has can be set, to a value of the
  type the file has (a number, text or true/false; at most 100 values, a file of at most 64 KB); an unknown file or key, a wrong type, a list, a null, an object where the data has a value or the other way round, and `sim/world` (read fresh on every use) are REFUSED with a `QA tune refused:` line and exit code 2, and nothing from a refused file is applied, so a typo can never silently
  change nothing. An empty tune is fine (the variant that keeps the data). A rite's numbers are the rite's row in `data/combat/abilities.json` (`range`, `radius`, `power`, `cooldownMs`, `soulCost`, and for the Haunting Wraith `speed`): a number a rite keeps in its script is not tunable until it is moved into its row.
- **Variants** are runs of their own: one game start per tune, in a fresh user folder (the team app's `clip` job), each with the same plan, so the clips of one name differ only by the tune.
- **Test:** `tests/qa_shots.gd` checks the plan and its limits, the stand-ins' layouts, the writer's file format on made-up pictures (FFD8 to FFD9 each, the count, the size), every tune refusal (and that none changes the data), a valid tune reaching the rules, a registry projection, the core's table and the rite that runs (and being put back), a whole clip recorded on a
  Reaper's game scene with a made-up picture source (the HUD, camera, stand-ins and cast, the files and their json, a second clip starting fresh, a refused cast failing its clip with no file), the flags honoured only where the QA tools start, and real headless launches (a refused tune exits 2, a clip run with a tune prints it and fails for want of a picture). A headless run draws nothing, so
  the real recording (the viewport's picture, its look, the timing on a real GPU) is confirmed on a team PC; on the VPS one 2 s clip of the Haunting Wraith at two tune values was recorded on the software renderer to see that the frames differ.

### Release checks

The team app's `release` job (a revision's checks before it goes live, when its shipper asks: `server/death-muffin/team-check.sh`, B62; and the publish's 14-second pre-release check) runs these on a team PC; they are the game's side of its steps. Two flags work in every build, and only quit; the rest are QA flags (`DmMain.qa_wanted`: a debug build on the dev-offline backend), which a release build, an online start
and a launch without a QA flag ignore.

- **`--boot-check`** (every build; `install` step): the game boots to its first screen (the login, or the character select of a saved login), prints `BOOT OK <ms>` (ms since the engine started, the art pack's mount included) and `BOOT screen <name>`, and quits with exit code 0. No first screen in 60 s prints
  `BOOT FAIL no first screen in 60 s` and quits with exit code 1; a crash is the engine's own exit code. It ignores `--class` (no quick start) and does nothing the front flow does not (in a fresh user folder there is no saved login, so nothing is sent).
- **`--boot-check --quit-while-loading`** (every build; `quit-loading` step; read only together with `--boot-check`): once on the first screen the game asks the worker threads for the art pack's models (the loads the warm-up makes, `DmWarmup._model_paths`) and quits at once with them in flight, printing
  `QUIT-WHILE-LOADING <n> of <m> loads in flight`, exit code 0. Quitting while the models load is the closest the game has to the case that crashed the old game on 4-core PCs: the pack itself is mounted before the first frame (`main/dm_packs.gd`), so the loads that can still be running are its models. A normal quit
  removes the crash lock (`DmCrashWatch`), so a crash while quitting is a lock left behind: the step checks the exit code and that no `crash_pending.json` appeared. A headless run has no renderer to load for, so it asks for none (`0 of 0`).
- **The `screens` step's plan** has six shots (the bag with a tooltip, the character sheet, the spellbook, the Vault, the map, and the HUD in a fight: `{"name": "hud-fight", "area": "graves", "wait_ms": 4000, "fight": true}`, the last needs `"fight": true`, "Screenshots for proposals").
- **`--ui-scale=<0.8 to 1.25>`** (QA; `screens` step): Settings' Interface size (`ui_scale`; the Settings window offers 80, 90, 100, 110 and 125 %, so the largest is `1.25`) for the run, the way `--preset=` does graphics: on loan, never saved, applied before the game scene starts (`DmMain.qa_ui_scale`,
  `opts.qa_ui_scale`). Another value is ignored with a `QA-SHOTS warning:`. The separate HUD size setting (`hud_scale`) has no flag. The shot plan runs as it does for a proposal (`--shot-plan=` with the window at the step's resolution).
- **`--stutter --stutter-out=<abs dir>`** (QA; `stutter` step; writes `<dir>/stutter.json`, the folder made if it is missing): `DmQaStutter` runs, with no front flow and nothing from the PC's own files, for each playable discipline (1 to 4 and 11) a fresh isolated offline game on High (`DmBenchFight.boot`: the HUD on,
  the warm-up players get, a level 60 hero in the Graves, Easy auto combat switched off), eight stand-in enemies in the combat core (the clips' robbers) in front of the hero, four thralls for a necromancer (raised again before each cast: some rites use the legion up) and a few corpses, then casts each rite of the discipline's primaries, hotbar and grimoire and its signature once
  (`DmQaStutter.rites_of`), with the hero, cooldowns and resource made ready for each, and measures the second after it: the worst frame (real time, ms) and the pipelines the renderer compiled in it. Godot 4.7.2 counts compilations: `RenderingServer.get_rendering_info(RENDERING_INFO_PIPELINE_COMPILATIONS_CANVAS | _MESH | _SURFACE |
  _DRAW | _SPECIALIZATION)`, read per kind by `DmQaPerf.compilations_by_kind` (0 on a run with no renderer): the first four make the frame wait, `specialization` builds an
  optimised copy in the background while the general one draws. A rite the host refuses (it needs a target the stand-ins cannot give) is listed in `refused`, not measured. V-Sync is off and the frame rate uncapped for the run. `stutter.json`: `{"rows": [{"discipline": "reaper", "rite": "scythe_throw",
  "worst_ms": 14.2, "compilations": 3, "kinds": {"canvas": 0, "mesh": 0, "surface": 0, "draw": 1, "specialization": 2}}, ...], "p50_ms", "p99_ms"}` (p50 and p99 over every frame of the cast windows) and beside them `"scenario"`, `"preset"`, `"renderer"`, `"compilations_counted": true`, `"refused": [{"discipline", "rite", "reason"}]`, `"errors": [{"discipline", "error"}]`, `"worst_ms"`, `"frames"`, `"ms"`.
  Exit code 0 = the file is written and every discipline ran, 1 = not. `--preset=` picks another graphics preset than High. About 100 rites: a few minutes.
- **`--soak[=<minutes>] --soak-out=<abs dir>`** (QA; `soak` step; 30 minutes without a number; writes `<dir>/soak.json`; `--class=N` picks the discipline, default the Gravecaller): `DmQaSoak` leaves one fresh isolated offline game on High (as above) to fight in the Graves with the waves and Grave Surges on and Easy auto combat holding the middle
  of the area, for that long. Every minute (real time) a row. `soak.json`: `{"rows": [{"minute", "p50_ms", "p99_ms", "static_mb", "objects", "video_mb"}, ...], "growth": {"static_mb", "objects", "video_mb", "p99_ms"}}`, each growth number the mean of the last five rows minus the mean of the first five (with fewer than ten rows,
  half the rows each, at least one), and beside them in each row `"frames"`, `"worst_ms"`, `"nodes"` and `"kills"`, and `"scenario"`, `"preset"`, `"discipline"`, `"renderer"`, `"minutes"`, `"complete"` and `"growth_detail"` (`{"window_min", and per metric {"first", "last", "delta"}}`). The engine's static memory, object and node counts and
  video memory are `DmQaPerf.memory` (static memory counts in debug builds, which this runs on). The file is written after every row (`"complete": false` until the last), so a PC that stops halfway leaves its rows. Exit code 0 = every row and the file written.
- **The window's size** is the engine's `--resolution WxH`: the game does not override it (the project's 1280x800 is only the default, and the windowed mode of Settings leaves the window as it is), so a run at 3840x2160 or 3440x1440 is that window; the interface lays out to it (stretch `canvas_items`, aspect `expand`).
- **Test:** `tests/qa_shots.gd`: the flags and where they count (the boot check in every build, the rest only in a QA run), the boot check's launches and exit codes, the stutter scenario's rite lists and a short run (3 rites of a Reaper: the file's shape, the rows, the refused ones apart, p50 and p99), the soak's short run (3 rows of 2 s: the rows, the growth, the file), Interface size on loan, `--stutter-out=` and `--soak-out=`. What only a team PC
  can confirm: the compilations a first cast really causes and the frame times on a GPU (a headless run has no renderer: 0 compilations), the soak's memory growth over 30 minutes, `--quit-while-loading` with the models really loading, the Interface size at 3840x2160 and 3440x1440.

## Grave Surges

A Grave Surge is an event of the wave director (`director.surge`, `next/areas/dm_grave_surge.gd`), host only: a crypt cracks open in the hero's combat area, three waves climb out, and
quelling most of them pays an offering. The rules and numbers are `SURGE` in `data/content/enemies.json`; it works on the core's ids.
- **The clock** (`surge_in`) runs only while a living hero stands in the director's combat area (not a hub or the Depths) and no boss is awake and hittable: the first surge opens after 100 s of that
  time, the next 90 to 150 s after one ends (0.6 x that from Wave Speed tier 6, Restless Crypts). It keeps its value while no hero is in a combat area. The director calls `update(dt, heroes)` at the end of
  every physics tick and `reset()` when no hero is in the area or when it follows the heroes to another one, which fails an open surge. Idle it costs a few comparisons a tick (the area's flags are
  worked out when the director moves, the bosses' list is read only while one stands, the crypts are decoded when the director is made).
- **Opening:** one of the area's crypts (`DmDb.sim_world()["crypts"]`: the Graves, the Ossuary, the Nave and the Warren have them) 9 to 30 m from EVERY hero, else a wave's spawn point.
  `surge_event` `surge`; `DmAreaFlow` draws it: the cracked crypt, the banner, the sound, the shake and the counsel's Surge tip (`surge_opened`).
- **Three waves** at 1.5, 7.5 and 13.5 s, each 1.2 x the area's wave size (times the Wave Speed tier's size), at most up to the global cap of 72 bodies (the dying and the queued count). A wave climbs out over a few ticks like an
  ordinary wave: it is queued through the director (`begin_surge_wave`, then `spawn_group`: 0.5 to 2.9 m around the crypt on the navmesh, rising, with the area's roster, elites and affixes as a wave's) and made `SPAWNS_PER_TICK` (3) bodies a tick,
  the surge's own update makes none. Each queued body carries the surge's serial (bumped by every `start`) and the director hands the surge its core id when it is made (`_make_next`, the one step of the tick's drain and of `flush_spawns`):
  the surge keeps it only while it is the open one, so a surge that ends with a wave still queued, and the surge after it, are not credited with those bodies. `spawned` counts a wave when it is decided, so the 80 % rule is measured against the whole wave, queued bodies included.
  The director hears every `DmCoreHost.enemy_died` and passes the id on (`DmWaveDirector._on_enemy_died`), so nothing runs per body in GDScript. A body that leaves alive (its area was left) never dies and counts for nothing, and
  `clear_area` drops the area's queued bodies too: a surge left open without them fails when its 20 s are up (the director fails it at once when it clears the area).
- **Quelled** when 80 % of what came is dead, once the third wave is out: `surgeCleared`, and `DmAreaFlow` calls `rewards.on_surge_cleared`, which gives every living member within 38 m of the crypt an item from its
  drop tape (the "surge" kind, "Value on the server") and bonus gold on the ground at the crypt. **Failed** after 20 s, or when no hero is left in the area (dead, gone to a hub, the Depths or another combat area):
  `surgeFailed`, the crypt seals and nothing is paid.
- **In a party** the host's director runs it and the host pays every member in range (a guest's drops reach it as a kill's do: "Value on the server"). A guest sees the bodies climb out (the core's snapshot) and,
  when the host quells it, its offering; the banner, the cracked crypt, the sounds and the tip are the host's window only (KNOWN-GAPS "Party and online").
- The benchmark's fight sets `director.surge = null`: a surge would add bodies to the counts the fight holds.

`tests/surge.gd` plays it in the whole world on the local mock (about 25 s with `--fixed-fps 60`): the rules by hand (no surge in a hub, an instance, with no hero or while the real Gravedigger King stands;
the first after 100 s, not before; a crypt 9 to 30 m from every one of two heroes, one 3 m from a crypt never getting it, a spawn point when none is fair; three waves at 1.5 / 7.5 / 13.5 s of 11, queued by the update and made three a tick, the Wave Speed tier's size and the
global cap; a death that is not the surge's is not counted; 80 % quells it with gold and a surge item at the crypt; 20 s fails it with nothing paid; the hero leaving, and the director following him to the Ossuary, fail it;
Restless Crypts; a surge that ends with a wave still queued, and the next surge, not credited with it; the Graves cleared under an open surge), then the whole chain through the director's own ticks (the clock, the surge, the waves three
bodies a tick, the core's deaths, the offering). It prints INFO lines: what a wave costs per tick (the surge's update, each tick that makes 3 bodies against an idle tick, the spawn events those ticks dispatch).

## The Gravecaller's rites

The rites (`next/rites/`, DECISIONS B42) are GDScript and call the core synchronously: a rite damages with `core.damage(id, amount, source)` and reads `{dealt, killed}` at once, so Wailing Skull's
extra leap on a kill, Bone Prison skipping the dead and the Litany's loops resolve inside the cast. `next/rites/` has every rite of the necromancer's and the Reaper's kits (her shared helper `DmReaperRites`: the cone and circle pick, the blow with its life steal, the soul bag).
The registry lists all 35; a rite with no module (the five later classes') is refused `unavailable`. `DmNextGame.attach_caster` gives the hero his `Rites` node (a `DmRiteCaster`; the game scene is its `DmRiteWorld`) and `DmRiteHotbar.wire`
connects the input. The numbers (spell power, cooldowns, costs, runes) are `DmAbilities`, `DmSimData` and `abilities.json`; the thralls' stats `DmThralls.raise_stats / colossus_stats`.

What a rite reaches creatures through (all on the caster `c`; the adapters belong to the game scene's `DmCoreHost` and live in `core/`):

| A rite needs | The caster gives |
|---|---|
| creatures near a point, one creature's place, radius and health | `c.foes_in_radius(pos, r)`, `c.foe(id)`: `DmFoe` snapshots (id, x, z, radius, hp, state, def, area), living, spawn order, edge distance (`core/dm_foe.gd`) |
| a blow, and whether it killed | `c.deal(id, amount)` returns `{dealt, killed}` (`c.hit` the bool); the hero is the source |
| a status on a creature | `c.apply_status / has_status / status_stacks / remove_status`; the DoT credit and Withered's hand-on are the core's events, connected once per caster |
| corpses | `c.corpses()` (`DmCoreCorpses`, `core/dm_core_corpses.gd`): `pick_corpse`, `corpses_in_radius`, atomic `consume`, `add_corpse`, `notes(id)`; records are `DmCoreCorpse` snapshots |
| the hero's legion | `c.thralls()` (`DmCoreLegion`, `core/dm_core_legion.gd`): `raise`, `rally`, `command_rend`, `near`, `list`; a thrall is an id and `info(id)` is the core's record; cap, formation, swing and death are the core's |
| lane, cone, circle, `pick_enemy` | the functions of `DmRiteModule`, answering from the core's radius query (edge distance, strict comparisons, spawn order, caps) |
| what a rite remembers of an enemy (contagious, the Chain Plague gap) | kept by enemy id in the rite's memory; the shroud's cover is `core.cover_miasma` |

Timers are the caster's (`c.after(ms, fn)` on the body's clock, a physics tick). Events and fx: `broadcast` -> `play` -> `DmRiteFx` through the `Vfx` and `AudioDirector` autoloads. The hero's own statuses are `DmStatusSet`. The cast flow (owner, cooldown, essence and cast lock through
`DmAbilities.cast_check / apply_cast_cost`, refund on a lost corpse race) is in `next/rites/README.md` "Flow". Where a rite meets the core:
- **Ossuary Wall is a core obstacle** (`DmCore.add_obstacle`, a 7 m by 0.8 m box): the core keeps every enemy on the surface out of it (one standing where it rises is put out through the nearer side) and an enemy's steering does not drive into it, so a body slides along it toward its goal and presses
  there; thralls and the hero pass. The core has no navigation avoidance, so a crowd does not curve around the wall's ends before reaching it.
- **A boss is in the rites' queries** by its id: the fan, the lance, the siphon, the skull, the Scythe's arc and Colossus Mantle's reflect reach it ("The bosses").
- **Withered's kill credit and its hand-on come from the event buffer**, at the end of the tick that killed: the DoT's `hit_resolved`, Contagion's and Plague Choir's spread to the neighbours, and the corpse-consumed beat of Requiem Wraiths' wisp. A rite's own blows are known at once
  (`killed` in the reply of `damage`), so nothing a player sees waits for it.
- **A status on an enemy or thrall is the core's** (`apply_status`): the hero is its source, so the last stacker of a Withered owns the kill; the Miasma's lift of the Shrouded ward is `cover_miasma` (0.35 s of game time, native/README.md "Affixes"), asked for every enemy in a cloud (the core ignores a body
  without the ward).
- **Carrion Seed's fields live in the corpse field's notes** (`DmCoreCorpses.notes`, dropped with the corpse); its arming and expiry run on the caster's clock in ms, and a seed ends with its corpse.
- **Spear rally's mark** is written to each thrall by the rite each tick while the mark lasts (`set_thrall_mark` from `thrall_info`'s target); the thrall does not read it. Legion size bounds the cost (Legion Champion 5 only).
- **Wraith Walk's green flame is the core's status** (`wraithfire`, a damage over time like Hemorrhage, its damage a second set by the cast), so its kill credit comes from the event buffer at the end of the tick, as Withered's does; the Reaper's swings, harvest and wisps strike through `deal` and
  know their kills at once. Her life steal counts the enemies a swing struck.
- Shots follow the simulation's position of their target. A blow of zero or less is refused (`damage`, a boss's too); no rite deals one.

`client/tests/rites.gd` casts every rite (table-driven), the refusals, the synchronous-kill cases, the kit's hotbar and the click-to-attack chase, and plays a fight; then the other three necromancers and the Reaper, each a real
character in a fresh game (her bag, souls paid and refused, every rite's damage with the souls' bonuses, the life steal, the wisps, Soul Harbinger's Raiment, a kill banking a soul, auto combat's pick).

## The bosses

The seven bosses (`next/bosses`, `sim/bosses`, `game/dm_boss_view.gd`): the Gravedigger King (the Hollow Graves), the Bone Abbess (Ossuary), the Drowned Congregation (Nave), the Bell-Sworn Prelate (Sanctum, woken with
the Sundered Bell), the Plague Saint (Cloister), the Cinder Regent (Pyre) and the Mire Mother (Fen) run in the game scene as DECISIONS B42 says: **an external entity of the core (kind 1) whose brain stays GDScript.** The
brains of `sim/bosses` do not know what a core is: they ask their `DmBossWorld` (the Plague Saint's asks for her doctors only: `enemies_of`, below). `DmBossHost` (child `Bosses` of the game scene, `g.bosses`) has the
summon rules, the spawner, event routing, fx and music, and serves all seven areas (`served_areas`); `DmBoss` is the body; `DmBossNodeWorld` is the brain's view of the world, answered from the core.

| | On the core |
|---|---|
| The body | `DmBoss` is a plain `Node3D` (no collider, navigation agent or state machine) that registers with `DmCoreHost.register_boss` (its `core_id` is an **external of kind 1**) and keeps what it needs of an enemy as fields: `hp`, `max_hp`, `radius` 1.6, `damaged`, `died`, `is_hittable()` |
| Thralls | the host writes `set_external(id, place, is_hittable())` before every `core.step`: `alive` is false while it cannot be hurt (the Mire Mother sunk) or is not awake. Thralls scan it after the enemies by the core's boss edge rule; their blows come back as `EV_THRALL_HIT_EXTERNAL` (`thrall_hit_external`) when the tick's events are dispatched, after every thrall and enemy has acted, and `DmBossHost._on_thrall_hit` gives them to `DmBoss.take_damage` with the owner as the credit. A brain runs once a tick before the core, so it sees every blow of tick N when it runs in tick N + 1 |
| Queries | `DmCoreHost.enemies_in_radius / foes_in_radius / foe / enemy_info / enemy_position / enemy_alive / enemy_radius / damage / apply_status / status_stacks / remove_status` answer for a boss id too: the living boss comes after the enemies, measured to its edge, as a `DmFoe` with `boss` true (so the caster's `c.foe`, `c.foes_in_radius`, `c.deal`, `c.apply_status` and the lane, cone and circle helpers of `DmRiteModule` reach it), the hover pick finds it, and a blow on its id is `take_damage` into the brain |
| Statuses | the boss's own GDScript `DmStatusSet` (B42): slow, root and chill show and the brain ignores them; a stun staggers it at most 0.5 s every 8 s. A rite's Withered on a boss is not a `rite_hit` and has no `status_dot` event: the DoT lumps hurt it and the brain's credit is the caster |
| Enemies' support abilities | do not reach a boss (a Censer's aura, a Deacon's sanctify, a Seraph's ward): it is not in the core's table, and a boss ignores what they give. Only the supporter's choice shows it: an Ossuary Deacon never spends its Sanctify on the wounded Abbess, it blesses a wounded add instead |
| The adds | the director's spawn through the core, in the boss's area and at its level (`DmWaveDirector.spawn` returns the core id); a kind the core does not run is skipped (the brain goes on without it); they leave with the boss (defeat or wipe) through `DmCore.remove_enemy`: out of the table at once, no death, no corpse, no credit |
| The Abbess's niches | core bodies of the `niche` kind (`native/src/core/niche.cpp`: they rise, then only stand; nothing staggers, stuns or moves them, they take no part in the crowd's spacing, lay no corpse and pay nothing), given their health by `DmCore.set_enemy_hp` (7 % of hers); a thrall or a rite hits one as an enemy, and its status set runs (Withered burns it); the crowd draws the baked `skull_niche` and hides it the moment it falls |
| Corpses (Bone Communion `devoured`, the Drowned Rite `raised`) | the core's corpse field (`DmCoreCorpses`, atomic consume) |
| The Congregation's pews | `DmDb.sim_world()["cover"]` |
| The Saint's rot pools and the Regent's coals, firebreak and embers | zones of the core with the boss's id as their source (`DmCore.add_zone(kind, ...)`, kinds `toxic` and `ember`): the core pulses them (`dps x 1 s` on every hero and thrall within radius + 0.45, hit kind toxic or burn, after the enemies and before the corpses and thralls), `DmCore.zones(kind)` lists the live ones for the Saint's "am I standing in rot" (a sac's burst corpse counts too), and `DmEnemyFx` draws a pool from its zone event on every peer, so a late joiner sees pools already burning (the baseline lists the zones) |
| The Prelate's echoes (the summoner's vow `prelate_echo`) | `echoes()` is the world's (`DmBossHost.vow_fx`): none, because the game has no vows (B36), whoever rang the bell. The brain's Echoes code replays its three recorded scenarios and is fought by hand in `client/tests/boss_prelate.gd` with the world sworn to them, ready for the redesigned Ascension. The HUD is still told `can_ascend` after a kill that makes the run Ascendable; with no Altar nothing shows it |
| The Congregation's wading water, the hero's root and chill | the host's wade clock (`hb.wade_mult`) and `root_for` / `dm_enemy_effect(&"chill")` on the hero body |
| Its blows | `hero.take_damage(dmg, boss.core_id)` (the id is the source, like any enemy's: the hero's body finds where the blow came from, and Colossus Mantle's reflect finds him by it); `core.damage(thrall id, dmg, boss.core_id)` |
| The Scythe's arc and the needle's range | `DmFoe.boss`: the arc counts it separately with its own reach and one of the arc's hits, the needle's range counts its radius, and the click-to-attack chase does too |

What the host's `DmCoreHost.tick` does with it, in the tick's order: the boss's `_physics_process` (priority 0, with the session and the director) pumps the brain and mirrors its position, then the host writes the external and steps the core; the
core's thralls act on the place it wrote, and their blows on it are given to the brain as the tick's events are dispatched.

**Summoning:** key E within 4 m of the boss's grave, altar, bell or reliquary (or a click on it, or `bosses.request_summon`; the hub shows "Summon X · N shards"), the refusals `far`, `unknown`, `busy`, `dead` and `shards`: the summon takes
the boss's soul shards from the summoner's progression (the Prelate's bell through `spend_shards`, which also owes the run a Prelate summon). **The Covenant Seal** (`DmBossMeta`, child `BossMeta`, made by the game scene's value step): at an altar of a boss that can be Empowered, with a Seal in the bag (or an earlier lost fight's summon bound on the backend), the host's `site_hook` opens the HUD's boss-key prompt (`boss_key_offer`; its two buttons answer
`summon_boss` and `summon_boss_empowered` on the HUD adapter); the Empowered call goes to the backend (`/api/boss-key/summon` takes the Seal and 7,500 x shards^2 gold, a bound summon is free), wakes the boss with `try_summon(..., true)`
(+6 levels +15 %, hp x1.4, a red-gold glow), the kill's report carries the summon id and the Seal's prize is claimed from the backend and dropped at the corpse. The Prelate cannot be Empowered.
**A defeat** is the host's `defeated` signal (a real kill; `reset` for a wipe), the brain's events (`brain_event`), `DmBoss.died` and the boss sounds, and `DmSessionRewards.on_boss_defeated` pays every member in range (gold, shards, items, XP,
the first-kill bonus and trophy once, the entry of the backend's report; the Prelate has no trophy: its kill is the run's tally). The boss score follows the local hero while he is in its area. The dev entry's `--boss` starts the hero at the
King's grave, grants the shards and wakes him.

**Tests.** `client/tests/boss.gd` is the King's proof, on `boss_base.gd` like the other six (the summon rules, the awaken numbers, thralls, rites, wipe, defeat and rewards are the base's; every boss's recorded scenarios are replayed once, by `tests/bosses/run.gd`): the King's own are his attacks and phases stepped
by hand with the data's numbers and timing (sweep, Burial, phases, ghouls on the rim, the elite, the pits, the double sweep, the blows on the hero and on a thrall), the wipe (adds leave silently), thralls (the edge rule,
`thrall_hit_external`, credit, `alive` false while he cannot be hurt), the rites (edge distance, order, lane, cone, circle, the needle's range, the Scythe's arc, the Spear's rally, Fan, Lance, statuses, stun), the defeat events, a second summon, a
fight on the real clock and the net state round trip. The other six have a suite each on `client/tests/boss_base.gd` (`boss_abbess|congregation|prelate|saint|regent|mire.gd`): their recorded scenarios (44 with the King's six, 8 for the Prelate
with her three Echoes), and the generic parts every boss gets on the core: the hub's prompt and the summon rules, the awaken numbers and the registration with the core, thralls (the edge rule, the credit, the
boss's blows on the thrall), the rites, a stun, the wipe, the defeat with its rewards and the first-kill bonus once, the boss score, a fight on the real clock, the net state; then each boss's own fight by hand (the Abbess's niches, Grasp, Lance,
Chorus, a niche's break, Communion over real corpses; the Congregation's Maul, Grasp, Hymn behind a pew, the water; the Prelate's Slam, Toll, Bell Rain, Procession; the Saint's swing, Rot Rain, pools, blessing, link; the Regent's cleave and
firebreak, coals, Conflagration; the Mire Mother's Maul, Hands, Surface, the flood, the Drowned Rite). `boss_meta.gd` is the Covenant Seal on the mock backend (the altar's choice and the prompt, the Empowered call, the report's summon id, the prize, a
bound summon) with the first-kill trophies. `core_boss.gd` is the core's half (the niche, a body's health, the zones, their wire).
Not in them: the boss bar and banners (the full HUD); the two-player fights (the co-op state and events are `DmBossHost`'s own, 20 Hz and reliable: "Co-op on the core";
the King fights both heroes in `coop.gd`, the other six in `coop_bosses.gd`). Easy auto combat takes the awake boss as a target (`bosses.active_boss()`, its telegraphs from the boss fx).

**The adds** are the director's spawn through the core (`DmWaveDirector.spawn`, in the boss's area, at its level, `runs_on_core`): the Abbess's niches, the Congregation's Choir Wraiths and Penitents, the Prelate's Risen and Penitents, the Saint's Plague Doctors,
Flagellants and rats, the Regent's Cinder Husks, Pyre Priests and Cinderhounds, the Mire Mother's Mire Leeches, Bog Hags and Risen. The Saint's doctors' link heals her by the doctors the world finds in the core's table: `DmBossNodeWorld.enemies_of("plague_doctor")` reads `enemy_rows` (seven numbers a body, no dictionary) and fills a row for a doctor only, each body's area the last answer while it stands strictly inside that area's rect (`DmNextWorld.area_interior`), so a tick with 70 bodies in the room costs about 0.09 ms where every body's row cost 0.3 (`enemies()` is the same list of every body, for a brain that wants it).

## The benchmark

The in-game benchmark (`next/perf/README.md`): one held fight in each of the nine combat rooms with the four necromancers or the Reaper, so the Full Party fight can be measured on any PC, room by room. The launch was checked with it against the old game (DECISIONS B50).

```
bash client/tools/bake_crowd.sh                                                                                                    # once: the crowd models the fight draws (with none baked the crowd does no view work: about 0.6 ms a frame cheaper, and the report says so)
nice -n 10 /home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client -- --benchmark --bench-room=graves --bench-size=full_party --bench-class=2   # the VPS processor test; the report is in the log
nice -n 10 /home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client -- --benchmark --bench-room=fen --bench-size=full_party --bench-class=11 --bench-length=quick   # any of the nine rooms (graves warren ossuary nave coliseum sanctum cloister pyre fen), any of the five classes (1 2 3 4 11)
/home/ubuntu/tools/godot/godot --path client -- --benchmark --bench-room=graves --bench-size=full_party                              # on a PC: the fight in the window, then the render breakdown
DeathMuffin.exe --main-pack DeathMuffin.pck --windowed -- --benchmark --bench-room=graves --bench-class=2 --bench-size=full_party --bench-length=full --bench-preset=low --bench-dir=<folder> --bench-quit   # the team app's run of a release build
```

- **Launch:** `-- --benchmark` runs it at once on an isolated offline game (no login) and stays on the results screen with a Quit button; a headless run quits by itself once the report is out (`BENCHMARK` lines in the log and
  `user://benchmarks/bench-<datetime>.txt`). From the character select, the **Benchmark** button opens the setup window; Start runs it and Back returns. `--bench-room=`, `--bench-class=`, `--bench-size=light|standard|heavy|full_party` and
  `--bench-length=quick|full` pick the setup (Quick: 6 s warm-up and 20 s measured; Full: 10 s and 30 s, then the render breakdown), `--bench-warm=<s>` / `--bench-measure=<s>` shorten it, `--baked=<dir>` names the baked crowd models.
  **The rooms** are the nine combat areas (`DmBenchmark.ROOMS`: the Hollow Graves, Catacomb Warren, Marrow Ossuary, Drowned Nave, Bone Coliseum, Bell Sanctum, Plague Cloister, Cinder Pyre and Mourning Fen; the Depths is an instance, not a room) and **the classes** the four
  necromancers and the Reaper (`class_indices`, 1 2 3 4 11, the playable disciplines): anything else (`--bench-room=depths`, a greyed-out `--bench-class=5`) is refused with a message that lists what the benchmark has, and exit code 2 (`DmBenchmark.refusal`).
  The Standard setup is the Bell Sanctum, Gravecaller, Standard size, Full; the Full Party fight the budgets are measured on (CLAUDE.md) is a custom setup in the Graves. Only the picked room's area is loaded (`opts.areas`), so the run measures the room, not the world.
  **The team app's flags** (2026-10-19; the app's `bench` job runs the release build with them, server/death-muffin/README.md "Team jobs"; both work in a release build and only together with `--benchmark`):
  `--bench-preset=<low|medium|high|ultra>` is the graphics preset of the run: it replaces the player's setting for this run as if chosen in Settings and is never saved (`DmBenchmark.graphics_preset`, read through
  `DmBenchmark.user_settings`, which puts it on loan with `DmSettings.session_set`; the report's "Graphics preset" line and the queued run say it). A value that is not a preset is refused like an unknown room, with a message
  that lists the presets, and exit code 2. `--bench-quit` makes a windowed run quit by itself once its run is recorded (a headless run always does): exit code 0 when the run is the last entry of the queue, 1 when it was cancelled (it is
  queued too, flagged `cancelled`, so the caller must not send it) or the queue could not take it (`DmBenchmarkScreen.exit_code`). With `--bench-dir=<folder>` the run is a trial that sends nothing, and the payload the app uploads is the
  last entry of `<folder>/pending.json` (`DmBenchHistory.record`: the body `DmApi.post_benchmark` sends). `tests/benchmark.gd` (the exit codes, the loan) and `tests/benchmark_flags.gd` (a real launch) cover both.
- **Where the files go:** the report, the history, the queue of runs to send and the last setup are in `DmBenchmark.dir` (`user://benchmarks`); `--bench-dir=<dir>` keeps a run's in a folder of its own, and a run that has one is a trial that sends nothing.
- **The fight:** the fixed seed 20261011, a god-mode level 60 hero of the picked class on Easy auto combat holding his ground at the walkable point nearest the room's centre that a path joins to its doorway (the Sanctum's centre is a cut-off dais), no elites, every enemy on the health and damage of the Bell Sanctum
  roster's average (272.9 hp, 10.8 damage: `DmBenchmark.STATS_ROOM`, the same in every room), waves brought in to 6 to 14 m, the count topped up and trimmed every 0.25 s, and for Full Party 72 enemies, 32 thralls and the room's boss held awake
  (the one that sleeps in that room, `DmBenchFight.boss_of`: the Gravedigger King in the Graves, the Bone Abbess in the Ossuary, the Drowned Congregation in the Nave, the Bell-Sworn Prelate in the Sanctum, the Plague Saint in the Cloister, the Cinder Regent in the Pyre
  and the Mire Mother in the Fen; woken through the real summon, again after each defeat; the Warren and the Coliseum have none and run without, and the Setup line says so). The director spawns through `DmCoreHost.spawn_enemy`, `trim` removes the farthest extras with `remove_enemy` (no death, no corpse, no reward), the thralls are raised
  straight into the core without the cap, and every count is read from the core. `DmBenchFight` holds these rules.
- **The report** (the table, the hitch log, the render breakdown) names the combat core in its header and has a **budget section** that sets the budgets (CLAUDE.md "Performance budgets", B39) against this run: the combat core's step, the crowd's sync and the
  event dispatch per 60 Hz tick (`DmCoreHost.measure`, on for the measured window only) against 4 ms; the rest of the main thread per frame (the frame less the core's share, ticks a frame times its tick) against 4 ms; the HUD's main-thread
  share against 0.5 ms (the same fight with the HUD off and on, eight times over, half a second each: a share below the printed spread, twice the standard error of the rounds, is noise) and its draw calls against 150 (from the render breakdown's HUD row, so on a PC with a renderer and a Full-length run).
  Each line says PASS or MISS. The budgets are set for the headless Full Party fight on the VPS; another size, or a rendered run (where the rest includes drawing), prints them as information. The numbers are not asserted by any test.
  The render breakdown's parts are Shadows, Creatures (the crowd's MultiMeshes, in the main pass and in the shadow passes), World, Effects and HUD; they overlap (hiding the world also takes its shadow draws out), and what the rows count is explained in "The draw budget".
- **The crowd's cost** is in the report (client/crowd/README.md "Crowd cost"): a `Crowd:` line under the setup names what was in force (the mesh levels' distances, the instances a group starts with, the animation bands, culling, whether thralls cast, the
  enemies that cast), and `Crowd per frame` under the budgets gives the measured window's averages from `DmCrowd.stats()`, sampled with the fight's other counters (bodies, drawn with their MultiMeshes and triangles, outside the view, the instances that cast
  shadows with the thralls among them and the triangles the shadow pass takes again, poses worked out against the living, the bands). Those counters are deterministic: they read the same on any PC, so a run on Helix's PC and a run on the VPS compare
  by them. `-- --bench-crowd=key=value,...` changes a run to compare A with B on one PC: `cull=off`, `anim=off` (the animation bands), `mid_m`, `mid_hz`, `far_m`, `far_hz` (the bands), `thrall_shadows=off` (over the preset), `lod=32/60` (the mesh levels' distances in
  metres), `reserve=128` (instances a group starts with); a key that is not one is named and ignored. Culling and the bands save GPU work the headless run cannot see: the CPU side of the whole crowd is under 0.3% of a frame (README "Crowd cost").
- **Physics and process, what a frame costs:** Godot's `TIME_PROCESS` and `TIME_PHYSICS_PROCESS` are the slowest single frame and the slowest single tick of each second,
  refreshed once a second, so they read above the average frame whenever one tick in sixty is slow (Helix's PC, 2026-10-17: a 4.12 ms frame with "process" 5.59 ms and "physics" 6.47 ms, the core's tick 0.30 ms; the slow tick was Easy auto combat
  choosing its rite). The report keeps them as the two **Godot peak** rows and puts what a frame costs beside them: `DmFrameSplit` (`next/perf/dm_frame_split.gd`) times the
  physics part (from the first tick's `physics_frame` to `process_frame`: every tick's `_physics_process`, the physics and navigation servers, the physics clock's timers and tweens) and the process part (to the start of the last `_process`) of
  every measured frame: **Process ms (avg)**, **Physics ms (avg)** a frame and the **Slowest tick ms**, and a **Frame** line that splits the frame into physics, process and the rest (drawing, waiting for the GPU, presenting). The F3 overlay's
  logic line is the same split over the last second. `tests/benchmark.gd` pins the split with a tick that holds itself for 3 ms.
- **The headless frame pad:** with no window to draw, Godot waits at least 6.9 ms (`low_processor_usage_mode_sleep_usec`) after every frame, so a plain headless run shows 6.9 ms for any frame that cost less (a median within 3% of it) and hides the
  cost under it: the report warns, and does not judge the rest of the frame. `--fixed-fps 60` before `--path` has no pad and runs one tick with every frame, which is the processor test.
  It runs faster than real time, so a window counts seconds of fight by the engine's frame time (`--bench-warm`, `--bench-measure`; 30 s is 1,800 frames), and Easy auto combat keeps its cadence on the physics clock (`DmNextAutoCombat.clock_ms`),
  where a wall clock would stretch it.
- **Easy auto combat** (`next/feel/dm_next_auto.gd`) runs the decision code (`DmAutoCombat`, `DmAutoDodge`) behind an adapter that reads the core: the enemies by `enemy_ids / enemy_positions / enemy_states` (spawn order),
  the corpses by `corpse_ids / corpse_positions` (within 40 m, at most 256), and what those arrays lack from small tables the host's signals keep (an enemy's radius, elite flag, health, wind-up and area from the spawn, damaged and attack events; a corpse's kind from
  `corpse_added`; the dust clouds and toxic pools from `zone`; a burrowed or erupting body is skipped, `DmFoe.hittable`). It emits the same intents as the keyboard (`DmNextInput.cast_at`, `request_move_dir`). Its gate (`allowed()`) is the Settings gate: the character's `auto_combat_allowed` (the server grants it to the owner's staff account and the accounts the owner named), Easy difficulty and the Auto combat setting on (G or the HUD button flips it); `gate_probe` replaces it in the benchmark and in tests.
  Its choice (`DmAutoCombat`: native sorts, each field read once, the counting rites on packed arrays) takes about 0.6 ms with 62 enemies and 31 corpses in reach on the VPS (the old game's version of the file took 3.0 ms, 7 ms when it ends in
  Corpse Explosion, all inside one physics tick; a step of the walk 0.3 ms against 0.8), always choosing the same rite and the same step for the same inputs: `tests/auto_combat.gd` runs seeded fights against the old game's code and `tests/auto_combat_fixtures/run.gd` replays the golden cases. A hero that holds his ground reads the core's tables only when an action is due.
- **The warm-up** (`DmNextWarmup`, with `DmWarmup`) runs for players (`DmNextGame._wants_warmup`: not headless, not on `--qa` or `--shot-plan=` runs; `--warmup` forces it, `opts.warmup` overrides it, the benchmark forces it): models and effects load on worker threads (not headless: its dummy renderer fails on them), the boss's models, the effects, the gear (the Reaper's scythe too, and a throwaway hero in a legendary set with off-hand, cape and a flying pet), a dropped item, the telegraph shapes, a shot of each kind and a beam (`DmFxPrims.warm_shots`) and the hero see-through (Wraith Walk's
  phantom) are drawn once, every crowd model is drawn at its three levels of detail from rehearsal rows fed to the crowd (`DmCrowd.sync_rows`, with the core's tick held meanwhile so its sync does not forget them; the rows are cleared after), and the camera tours the areas
  the game has loaded, lit, with every point light off, and with the flash light. It runs for players so that no effect compiles the first time it is drawn in a fight (the Reaper's effects stalled on their first cast before 2026-10-17).
- **Sends:** the run's backend is the in-memory mock. A finished run is queued in `pending.json` (`DmBenchmark.dir`) and sent to the **live server's** benchmark history (`DmApi.post_benchmark`; `net/dm_config.gd` allows no other address): from the character select with the logged-in api, from `--benchmark` with a
  release build's saved login; debug builds, `--dev-offline`, a run with its own `--bench-dir=` and tests never send (the run waits in the queue, and goes out the next time a logged-in online session has an api). The one door a run leaves by is
  `DmBenchHistory.flush`, and from a script run (every test is one) it refuses a real transport. `tests/benchmark_classes.gd` pins it: it points `DmBenchmark.dir` at a folder of its own (with its baked models, removed at the end), so another run's history,
  queue or setup can neither change a check nor be sent by it, and its uploads go to a mock that answers as the server's API.
- **In the fight:** rewards, loot drops and the kill ledger run against the run's in-memory mock (the King's soul shards are granted to the throwaway character and charged),
  and the effects (`Vfx`) play; the work that grows with what is on screen is the core's C++, particles and decals ("The effects"), which won back 0.7 ms of a Full Party
  frame on the VPS for the particle ring (5.7 to 5.0 ms; 2026-10-16) and about 0.6 ms for the decals.
- **The world dressing's cost** (2026-10-17, the Graves' Full Party, headless `--fixed-fps 60`, six alternating pairs in ABBA order, `--bench-dressing=off` against the default, on a shared machine whose load swung between 3.7 and 5.9): the average frame 3.86 ms
  without it (runs 3.27 to 4.35; p95 7.68, p99 10.83) and 3.96 ms with it (3.61 to 4.27; p95 8.01, p99 10.95), +0.10 ms, a fifth of the spread of either arm; the rest of the main thread 3.27 against 3.35 ms of its 4 (the combat core 0.59 and 0.60).
  The node alone costs 18 microseconds a frame ("World dressing"); what the dummy renderer cannot say is the GPU's share, which is the water's fragment loop and a dozen transparent draws: Helix's PC.
- **Not in the fight:** the guests' hero bodies.

## The draw budget

The 3D draw calls of the Graves' Full Party fight (72 enemies, 32 thralls, the camera over the middle of the room, Ultra's moon with two cascades), counted from data so a test can hold them
(`tests/draw_budget.gd`: a draw call is what the budget counts and a headless run draws nothing) and checked against a rendered run (`tools/draw_measure.gd`). `DmDrawModel` (`next/perf/dm_draw_model.gd`) is the
count, `DmDrawScene` (`next/perf/dm_draw_scene.gd`) the scene both build: the room's area scene, the game's camera, the Ultra preset's moon, the combat core with four necromancers' thralls and 72 enemies; no hero, HUD or effects.

**What Forward+ draws,** measured with the engine's own counters (`Viewport.get_render_info`, the main pass and the shadow passes; Forward+ on lavapipe, 2026-10-17) and found again in Helix's benchmark runs:
- An instance is an *object* in the main pass when its bounds meet the camera's frustum, and in a shadow pass once for each moon cascade whose volume its bounds meet, when it casts. A *draw call* is one surface of an object.
  The Ultra preset has two cascades (0 to 8 m from the camera, 8 to 80 m: the first holds nothing but air at this camera, and still draws every MultiMesh that casts, whose bounds are the whole area).
- **Identical meshes are instanced by the renderer:** the instances of one mesh, surface and material that a pass meets are ONE draw call. The Graves' 130 props as prefab instances cost 33 draw calls (15 in the main pass, 18 in the shadow
  passes); a mesh that stands once costs its surfaces, and so does a mesh that merges many props.
- **A MultiMesh with no instance costs its draw calls all the same:** one in the main pass and one in each cascade it meets when it casts (+1 draw call in the main pass and +2 in the shadow passes when it casts, whether it holds 0 or 4 instances). A MultiMesh is never merged with another.
- Occlusion culling (the Graves' occluders), the sky and the lights' own work are not counted: the model runs a few draws under the engine (the Graves' world from the camera's middle: 75 against 84 rendered; with the merged cell meshes that were tried and dropped ("Static batching is not in the areas" below) it was 105 against 107), so a budget is set a little over the model's number.

**The benchmark's rows** follow from those rules; they overlap (hiding the world takes its shadow draws too, and the Shadows row is every shadow draw, the crowd's too). With every group drawn, the roster's 202 groups (41 models x levels of detail x with and without shadows)
cost the crowd 396 draw calls of which the Graves' party used 15 groups: 187 were drawn empty, 396 draw calls for 41 that mattered.

**The crowd draws what is in view, not what is registered.** `DmCrowd.set_group_nodes` (dmcore 0.14; `CrowdView` calls it for every model) hands the crowd the `MultiMeshInstance3D` of each group: the nodes start hidden, a group is shown
the frame its first instance is written and hidden once it has held none for half a second (a body crossing a level of detail back and forth does not rebuild the instance every few frames). The party's draws no longer grow with the roster:
the crowd of the Full Party costs 41 draw calls (17 main, 24 shadow) in the rendered run, 396 with every group shown (Helix's PC, the Bell Sanctum's Full Party: 27, 41 and 48 draw calls for the creatures on Low, High and Ultra, client/crowd/README.md "Crowd cost"). A model's first appearance
shows a group the frame it is needed; the models share the crowd's shader, so that costs a material's uniform set and no compile (the warm-up draws every model once all the same).

**Static batching is not in the areas** (measured 2026-10-17): merging a cell's repeated props into one mesh was no saving in draw calls, because the instances it replaced were already one draw call per mesh and a cell mesh is unique.
The Graves' world from the camera's middle and four places round it, rendered (`tools/draw_measure.gd --compare=<another version of the room's scene>`): 107, 112, 112, 93 and 116 draw calls merged, 84, 94, 91, 80 and 99 as prefab
instances (13 to 23 more merged; +30 on Helix's PC); the props alone 56 against 33; the merge saved objects (171 in the main and shadow passes to 129). The lightmap does not change the count (110 with it, 109 with it hidden). What cuts the
world's draws further is fewer distinct meshes and materials, which is a matter of the art.

**A body that is not solid draws through its model's fade group** (client/crowd/README.md "The alpha path"): a sinking body or a shrouded elite is written to a third MultiMesh of its model and level, drawn with the alpha shader in the
main pass only (no shadow pass), so a fight with nothing fading costs what it did and a crowd of bodies sinking together costs one draw call a model and level. The Full Party with 24 of its robbers and hounds sinking and three shrouded elites
standing among them: 27 instances in 2 fade groups, 24 draw calls for the crowd where the standing party's are 22 (`BUDGET_FADE`, 8, is what the budget allows the fade groups on top of the others).

**The test** (`tests/draw_budget.gd`, 50 s, bakes twelve crowd models into a scratch folder) builds the scene, lets the party fight for two seconds and counts: the crowd's groups (a group that holds instances is shown, at most two empty ones are shown, most
groups are idle), the crowd's, the world's and the whole's draw calls against `BUDGET_CROWD` (30), `BUDGET_WORLD` (85) and `BUDGET_TOTAL` (110; the model counts 22, 75 and 97), and that the model sees a crowd with every group shown (120 draws with only
twelve models; 396 with the roster). A change that adds draw calls fails here and not on Helix's PC; raising a budget is a decision. Rows by group are printed.

**The measurement** (`tools/draw_measure.gd`, rendered, about 200 s on the VPS; the command and its options are in the file's header) writes JSON lines: the world from five camera places and each group of its geometry hidden alone, the same for
another version of the scene (`--compare`), a MultiMesh with and without instances, and the crowd as the crowd shows it, with every group shown and hidden, each beside the model's number for the same frame.

## World dressing

`DmWorldDressing` (`client/world_fx/`, data in `client/data/world_fx/fx.json`) is attached by `DmNextWorld.build` to the areas the world holds and draws what moves around the static scenes. `DmNextWorld.dressing` is the node (null in a world built with no lights), `enter_area` tells it the hero's area (the weather and the water follow by event), `DmNextPerf.apply` thins the
weather on Low (`atmosphere.quality_low`), and the graphics preset owns the bloom (`DmGraphicsPreset.apply_environment`, "Graphics presets" below); the dressing no longer touches the environment. The area scenes carry none of what it draws:
the converter leaves out the flame spheres (a sphere floated above each candle and, with the glow, read as a white blob), the water planes and the puddle quads, so nothing is hidden at run time.

| Piece | What it is | How it is drawn and what a frame pays |
|---|---|---|
| Candle flames, 347 in 8 areas | additive billboards at the wicks, flicker and bob, the Sanctum's candle groups | one MultiMesh in each loaded area that has candles (a draw call when in view), the flicker in the vertex shader: nothing per frame |
| Brazier fire (21 braziers) | violet wisps and amber embers 30 x 28 m round the hero | one ring MultiMesh. A particle is written once, when it is emitted (a roll every 0.05 s: 10 wisps and 1.5 embers a second a brazier); its place, size and fade are closed forms of its age in the vertex shader (`DmWfxParticles.pose` is the same function in GDScript, and the test holds it against a frame-by-frame step). The old GDScript stepped every live particle every frame |
| Ground mist, 220 puffs | big soft puffs at knee height drifting over the world | one MultiMesh; the wrap rule is stepped 4 times a second (the old game: 15), 55 microseconds a step |
| Weather, 13 profiles | ash, leaves, bone dust, drips, embers round the hero | one mesh drawn from a clock by its vertex shader; an area's mesh is built the first time it is asked for and kept (4.8 ms in GDScript for the Nave's), the starting area's during loading |
| Windows, 4 | stained glass and a slanted shaft of light | a pane and a shaft under the nearest area's scene (the Nave's three, the Sanctum's one), static |
| Silhouettes, 70 | far spires, dead trees, fallen walls | one merged mesh |
| Water | the Nave's channels, the Fen's bog, the Acre's ponds, the puddles | one mesh, fresnel, the moon's glint, up to 16 ripple rings in the fragment shader; Low (`quality`) keeps a flat glossy sheet |

The brazier fire, the mist, the weather and the water are the only things that move on the CPU, and `DmWorldDressing._process` is a clock, an emission roll every third frame, a mist step every fifteenth and a few shader uniforms:
**18 microseconds a frame** (measured with the dummy renderer, the node alone in a Graves world, 3,000 frames; the weather 0.8, the water 0.4, the roll 16 each time and a mist step 55). The old GDScript mist (14 a frame) and brazier fire (44 with 26 live particles) took 58 between them.
Building an area's weather in GDScript costs 4.8 ms (the Nave's), which an area entry used to pay each time: now every loaded area's is built while the world loads. The six objects (water, weather, brazier fire, silhouettes, mist and the area's flames) are six draw calls
in the Graves' budget scene (`tests/draw_budget.gd`: `BUDGET_DRESSING` 8, none cast shadows) and replace the eight draws the stand-ins cost: the Graves' world, the dressing and the crowd are 96 draw calls with the earth beyond the walls (1), against 97 before.
`DmDrawModel` counts the dressing's pieces apart ("dressing:<piece>"). `--bench-dressing=off` (or `mist,water,...`) switches pieces off for a benchmark run and the report says which were off (`World dressing:`); the A/B is in "The benchmark".
`tests/dressing.gd` is the suite.

Not wired: `add_ripple` and `set_candle_group` are called through `DmEnemyFxHost.dressing`, which the game scene does not set, so the water has no ripples and the Prelate's candles do not gutter (KNOWN-GAPS "Built but never shown").

## The effects

The effects are `Vfx` (`fx/`, `DmFxRuntime`): ground decals, the two particle rings, the Binbun scenes, flashes, beams, projectiles. What grows with the number of them on screen is done in C++; the rest is GDScript.

- **Particles** (`DmMotes`, native/README.md "Files"): a ring's motes, the random start of every mote of a burst and the per-frame loop. `DmFxRing.emit` hands the options over; the numbers come from the global generator in a fixed order, so a seeded run gives the same motes. `tests/fx_motes.gd` holds the ring's buffer float for float (bursts in every colour form).
- **Ground decals** (`DmDecals`): a decal is a record in C++, not two GDScript objects. `DmFxPrims.decal` works out what it is made of (its layer, tint, whether it settles into an outline) and hands it over; C++ ages it, shapes it (growth, spin, pulse, fades, the outline that comes up after 0.6 s and the ring a settling disc brings with it, a flipbook's frame), places it (a decal that follows a body gives its id as `follow_body`, which C++ asks the crowd for; one with a `follow` callable calls it as before) and writes each layer's instance buffer and gives it to the RenderingServer. `DmFxLayer` keeps the MultiMesh and its node (`show_count`, `grow`). The cap of 160 combat transients counts decals and the other kinds together and the oldest leaves first. `tests/fx_decals.gd` holds every drawn float, the counts and the handles over two seeded runs and the cap; `tests/rites.gd` checks a decal that follows a thrall by id.
- **Binbun scenes** (`fx/dm_fx_binbun.gd`): an effect's root is moved only when it moved (every move walks the effect's subtree), a looping effect is tested against the camera every third frame (the test keeps 4 m of margin past the frustum) and 8 idle instances per effect are kept (it was 4), so a salvo of bonfires more often finds instances waiting than builds them from the scene.
- **The enemies' effects** (`DmEnemyFx`): the ambient tick (every 0.2 s) reads the bodies' places from one read of the core's bulk arrays (`enemy_ids`, `enemy_positions`) instead of a record each, and the Pyre's colours are read once. `DmCoreHost.foes_in_radius` (every rite's query) takes one call of the core (`DmCore.foes_in_radius`, ten numbers a body) where it took a record and a snapshot each (19 us a body).

Costs on the VPS (headless, cold: one call in the middle of a Full Party frame): the decals' step with 140 alive 0.04 ms (the GDScript it replaced 0.55), the Pyre's whole effects layer 0.40 ms (1.27), the Graves' 0.16 (0.61), the Pyre's ambient tick 0.86 ms every 12th frame (2.7 ms before), a Plague Saint's look at her doctors 0.09 ms a tick (0.3), a rite's query over 40 foes 0.25 ms (0.45 to 0.9).

## Graphics presets

Low, Medium, High and Ultra on Forward+ (DECISIONS B45; the preset ids are the old game's, so a saved setting carried over): `game/dm_graphics_preset.gd` is the table and `next/perf/dm_next_perf.gd` (`DmNextPerf`, the game scene's `perf`)
applies it. The game scene reads the player's settings file at the start and the
Settings panel applies a change live, `opts.settings` in tests and the benchmark. A preset sets the moon's shadow, reach, splits
and atlas and the soft filter, bloom (`DmWfxBloom`), screen-space ambient occlusion (High and Ultra), MSAA, anisotropy and mesh LOD on the viewport, the effects quality
and the Binbun layer, the crowd's shadow policy (`DmCrowd.set_shadow_policy`: the nearest enemies that cast, and whether thralls cast; a change reaches the
thralls already drawn) and the floor of Auto resolution, whose lower scales are upscaled with FSR 1. Brightness, fps cap, V-Sync, window mode and interface size are
settings of their own. A preset has no prop-light count or prop shadow range (the area's lights are baked into its lightmap), and the brightness lift is Forward+'s own: an exposure multiplier of each area (`DmWorldBuilder.AREA_LIFT`, 0.8 to 2.1,
calibrated so that each area is as bright as the old game's, "The look on Forward+"), eased in over 0.8 s when the hero enters another area (`LIFT_BLEND`; nothing runs per frame outside the blend),
times the preset's own factor (`DmGraphicsPreset` `lift`: 1, and 0.96 on Low, whose moon casts no shadow); the creatures' and the effects' shaders divide the lift out again (the global `dm_lift_inv`, declared in `project.godot`), because they are not in the lightmap it is calibrated on. `tests/presets.gd` (`--fixed-fps 60`, about 30 s) applies
each preset to a running game and checks the lights, the environment (the ACES tonemapper, the exposure from the world's number, the area's easing, the area's lift, the preset's factor and the brightness, the
plain-colour ambient, the depth fog, the moon and the rim light at their energies), viewport, crowd shadows and the governor, the twelve lifts (a number here is a calibration: measure again with the probe before changing it), the blend and what the lift leaves alone (`dm_lift_inv` follows it through a blend, the creature material's, the crowd's and the effects' shaders divide it out and convert their colours as Compatibility does, the hero's ring and shadow strength).

## The look on Forward+

The old game ran the Compatibility renderer; this one runs Forward+. The same scene, lights and numbers look different, and the first test builds looked darker and purpler, with big beige pools under every flame and white blobs of glow, than the old game's blue-lit stone.
The game matches the old look by making Forward+ do what Compatibility did where it shows, so the lights keep their numbers (DECISIONS B48). `client/tools/look_probe.gd` measured the differences (2026-10-17, Ultra, the VPS's software renderers, the same camera in the Chapterhouse, the Hollow Graves and the Ossuary,
plus calibration scenes: a grey plane under one light kind at a time). What it found and what the game does about it:

| What | Compatibility (the old game) | Forward+ | In the game |
|---|---|---|---|
| ambient, moon, rim, prop lights, fog, specular on a plane | the same pixel as Forward+ to within 1 | the same pixel as Compatibility's to within 1 | nothing to change |
| a vertex colour (a light pool's 0.25 / 0.17 / 0.09, a particle's colour, a gear mote) | read as sRGB: the pool's centre (82, 49, 24) | read as linear: (203, 175, 130), 9 times the light | `vertex_color_is_srgb` on the pools (`build_area._light_pools`, `DmWorldBuilder._light_pools`), the gear motes (`DmGearFx`) and the Binbun particles' materials (`DmFxBinbun`): (79, 48, 24) |
| a colour an effect's shader writes to `ALBEDO` (`COLOR.rgb` of the Fx layer, the world mist and particles) | converted from sRGB after the shader multiplied it | taken as linear | the shaders convert it (`dm_srgb` in `DmFxTex`, `DmWfxParticles`, `DmWfxMist`): (191, 155, 114) for Compatibility's (191, 156, 114) |
| a tinted dark texture (every floor, every wall, the gate posts) | tint x texel multiplied in sRGB, the product converted once | each converted, then multiplied: 1.04 to 1.6 times darker | the area converter lifts the tint by the measured ratio (`DmCompatAlbedo`, `client/next/look/`): the Graves' ground tint 0.72 / 0.67 / 0.72 becomes 0.80 / 0.77 / 0.81 |
| the glow of a very bright thing (an HDR quad of albedo 2 and a small emission of energy 6 on a dark plane, the glow part of the probe, 1280x720, red channel every 6 px past the edge) | 247, 189, 103, 41, 15, then the background at 30 px (the quad's edge pixel 62 of 255) | five mips: 255, 255, 251, 232, 213, 191 ... still 88 at 66 px | `DmWfxBloom`: the two finest mips at 0.8 of the web game's strength: 255, 210, 104, 15, nothing at 24 px; threshold 0.85, scale 2 and cap 12 as the web game's |
| a Binbun scene's own shader reading its particle's `COLOR` (`.rgb` as a colour or a mask offset) | the vertex colour converted from sRGB | taken as it is | `DmFxBinbun` reads it through a patched copy of each such shader (`dm_COLOR`: rgb converted, alpha as it is) |
| what a creature's shader writes to `EMISSION` and the tint it multiplies into `ALBEDO` (the hero's accent emissive 0.04 x the accent, the friend rim, the gear tints, a tinted body, the hit flash: all `lin()` of a hex) | `emission = srgb_to_linear(emission)` and the albedo product converted once, in `scene.glsl` (a small glow is a twelfth of itself; the glTF's colour and the texel are read raw) | taken as linear: the accent emissive doubled the hero's robe, the lilac look | `DmCreatureMat` and the crowd's shader multiply in Compatibility's numbers and convert like it (`dm_s2l`, `dm_l2s`): the hero's robe (the Graves, Y of a 24 px box) 59.2 before the fix, 43.2 without the emissive, 33.6 with the lift divided out as well |
| the exposure lift of an area on a thing that is not in the lightmap (a creature, an effect) | none: the plain exposure | the lift multiplies everything the tonemapper sees, 0.8 to 2.1 times | the shaders divide it out (`dm_lift_inv`, a global: 1 / (the lift x the preset's), set with the exposure): the lift is the baked world's calibration, not theirs |
| the beyond the walls | one 420 m field of grave soil under the fog (196 tiles); the background colour past it, (7, 6, 10) | nothing drawn: black, (1, 1, 3) through the tonemapper | the field as one quad (`DmWorldBuilder.build_outside`, the soil's tint lifted by `DmCompatAlbedo`); the background colour past it is never in view (the field reaches 80 m past every area) and stays black |

**The lift of each area** (2026-10-17, on the lighting bake of all twelve areas, e8ce4fd9; Ultra, 1280x720, the mean luminance of the world region, the probe's WSTAT line: x .12 to .78 and y .1 to .72 of the frame, the hero's box left out). One lift for the whole game did not fit: at 1.2 the Chapterhouse was 18 % darker than the old game's,
the Alchemist Wing 29 % darker and the Acre 3 % brighter, because every area's bake carries its own share of the light. So the lift is a number per area (`DmWorldBuilder.AREA_LIFT`, asserted by `tests/presets.gd`), solved from each area's own response: the probe shot every area at lifts of 1.1, 1.5 and 2.0
(`--plan="<area>:lift=1.1,lift=1.5,lift=2.0"`), a curve through the three points in log-log gave the lift that reaches the old game's mean, and a run at the table (`base`, two frames each) measured the result. The response is not one power of the lift: the mean rises as lift^0.75 to lift^0.9 in the dark areas
and lift^0.6 in the bright ones (the Wing and the Coliseum, where the tonemapper presses the highlights).

| area | the old game's mean (the target) | lift | the game's mean at the lift |
|---|---|---|---|
| Chapterhouse | 45.3 | 1.52 | 45.4 (+0.2 %) |
| Acre | 52.0 | 1.11 | 52.1 (+0.2 %) |
| Alchemist Wing | 124.1 | 2.08 | 124.2 (+0.1 %) |
| Graves | 37.4 | 1.35 | 37.6 (+0.5 %) |
| Warren | 34.1 | 1.35 | 34.1 (+0.0 %) |
| Ossuary | 40.5 | 1.38 | 39.0 to 42.2 (-3.7 to +4.2 %, see below) |
| Nave | 36.2 | 1.33 | 36.3 (+0.3 %) |
| Coliseum | 127.8 | 1.80 | 127.6 (-0.2 %) |
| Sanctum | 48.7 | 1.36 | 48.7 (+0.0 %) |
| Cloister | 52.8 | 1.37 | 53.1 (+0.6 %) |
| Pyre | 57.8 | 1.34 | 57.8 (+0.0 %) |
| Fen | 44.5 | 0.80 | 44.7 (+0.4 %) |

Eleven areas are within 0.6 % of the target, inside the noise of the measurement: the old game's own frames repeat to 1.5 % between runs, two frames of one visit differ by 0.3 % at most, and a second visit to the Chapterhouse, the Graves, the
Wing and the Acre (in a different order of visits) repeated the numbers to 0.1 % (the Acre to 1.9 %). The Ossuary is the exception: its ground mist drifts across the frame and is part of the mean, so a visit early in a run read 43.8 at a lift of 1.44 and 37.3 at 1.2, a later one 40.5 at 1.44 (the lift that matches the early visit is 1.33, the late one 1.44); the table's 1.38
centres them (the curve's numbers, not a run at 1.38: 39.0 and 42.2). The numbers are for Ultra on the software renderers; Medium, High and Low share them (`DmGraphicsPreset`'s own factor, 1, Low 0.96, is not measured), and the Depths, which the probe cannot stand in, keep the old 1.2 (`LIFT_DEFAULT`).
A number here is a calibration: measure again with the probe before changing it.

The lift is on top of the exposure (the world's number, the area's easing, the Settings brightness). It is a property of the area, not of the preset: `DmWorldBuilder.set_area` (what the world's `enter_area` calls when the hero crosses into another area) sets the target and eases to it over
0.8 s (`LIFT_BLEND`, smoothstep, together with the area's own exposure easing, so a door is not a pop of brightness; a change of ambient at a door is instant); `_process` runs only during the blend and switches itself off, so a frame outside a blend costs nothing, and the first area is set at once.

**The unbaked things** (the hero, the creatures, the effects) are lit by the real-time lights alone, not by the lightmap, and the first table of the lifts left them 1.3 to 2.5 times the old game's in seven areas and the hero lilac. Two causes, found with the probe's `HSTAT` line (the mean of a 24 x 24 px box on the hero's
robe, the same box on both sides) and its hero variants (`hnoemis`, `noamb`, `nomoon`, `norim`, `noshadow`, `noprops`, `nossao`, `hnolantern`, `hgear`): **the colours** (the table above: Compatibility converts what a shader writes to `EMISSION` and the albedo product once, so the hero's accent emissive,
0.04 of the accent, is a twelfth of itself on Compatibility's side and was most of the robe's brightness here: the Graves' robe 59.2 before the fix, 43.2 with the emissive off, and the lilac gone) and **the lift** (an exposure multiplier calibrated on the baked world is an exposure multiplier on a creature too: the robe falls to 33.6 with the lift divided out of its albedo, specular
and emission; an effect gets the same, `DmFxTex`). The global `dm_lift_inv` is 1 / (the area's lift x the preset's), set by `DmWorldBuilder._apply_exposure`, so it eases with the blend; a shader reads it for nothing per frame. Bloom, ambient occlusion, the moon's shadow and the prop lights were tried and are not the cause (the robe's box without bloom 58.5 against 59.2, without
ambient occlusion 33.8 against 33.6, without the moon's shadow 34.5 against 34.2, with the prop lights off 33.2 against 34.2; the moon is half of the robe's light, the ambient a sixth, the lantern a sixth).

The robe after both changes reads 1.1 to 1.4 times the old game's in the dark areas (the Graves, the Nave, the Warren, the Sanctum; it was 2.0 to 2.5), within 15 % in the Acre and the Fen, and 0.56 to 0.74 of it in the bright ones (the Wing, the Coliseum, the Cloister, the Pyre): the hero is darker there than before and than the old game's. Not explained, and not guessed
at with a table: the box is one pose, the old game's own frames differ by a third between runs (the Graves' box was 23.9, 33.0 and 34.9 in three runs), and the part Compatibility's bloom plays is not here (the old game's box without bloom is 27.3 against 34.9 in the Graves and 58.0 against 85.7 in the Chapterhouse, the game's box without bloom is within 2 %: the glow is calibrated on bright things, `DmWfxBloom`, and not on the halo of a ring and a staff light
on a robe). The crowd is the same material (`crowd_vat.gdshader`) and takes the same two changes; it was not drawn in the probe's frames (a rendered fight on the VPS outran the run's timeout), `tests/crowd_look_smoke.gd` is its check.

**The hero's ring and the contact shadow.** The old game's ring is thin (a half-height width of 4 to 6 px at 1280 x 720) with a peak of 169 to 224 in the dark areas; here it was 8 to 9 px wide and 244 to 255 (white, flat on top) in every area. Not the bloom (the profile without it is the same row for row: 255 against 255, 9 px), not the lift (245 and 8 to 9 px at a
lift of 1.0). `scene.glsl` shows where it comes from: Compatibility writes the exposed scene as `linear_to_srgb(radiance x exposure)` into its buffer before the post effects, so a translucent decal blends in that encoded space (its faint flanks lose most), Forward+ blends in linear light. The decal's own numbers
are unchanged (`tests/fx_decals.gd` holds them float for float), so the hero's decals are drawn at the strength that gives the old peak: the ring decals at `DmHeroLook.RING_K` = 0.4 of their opacity and the contact shadow at `SHADOW_A` = 0.75 (the old 0.5). Measured against the Graves, the Sanctum, the Warren and the Nave in the probe's `ring=K/S` variants (K 0.2 to 0.5, S 0.5 to 0.9): the peak is
195, 190, 203 and 187 against the old game's 195 to 221, 200, 224 and 169, the pool inside the ring (the mean of the 8 to 20 px inside) 44 against 45 to 50 in the Graves; the width stays 7 px against 5 (6 at a fifth of the opacity), which only the blend would change. Every other blended effect keeps its linear blend: wider and whiter than the old game's by the same measure ("Still different" below).

The Fen is the other way round: its baked ground is brighter than the old game's even at a lift of 1.1 (the mean 57.0 against 44.5, the darkest tenth 26 against 15), so the lift that matches the mean is 0.80, which leaves the ground's shadows lighter than the old game's (its hero is 0.87). All of this wants Helix's eye on his PC; what is left is the look pass (KNOWN-GAPS "Look").

**Still different** (the look pass on the ROADMAP's polish list): the Depths' walls keep Forward+'s darker tint (its floor is lifted, `DmWorldBuilder._floor_mat`) and the Depths' lift is 1.2; Low and Medium: the old renderer drew blended effects in sRGB space when bloom is off (an alpha sprite half-way over black: 131, with bloom on 205), Forward+ always blends
in linear light, and at Ultra too the old game's ring is thinner and dimmer than a linear blend of its decal ("The hero's ring and the contact shadow"): only the hero's ring and shadow are scaled to it, every other blended effect (the rites' decals, the telegraphs, the particles) is wider and brighter here than there;
the gear props' emission (`StandardMaterial3D` with an energy: Compatibility converts the colour times the energy, Forward+ the colour) and the Binbun scenes' own shaders that write `EMISSION` are the same class as the creatures' and not converted, and the staff's light sprite takes the lift. The Chapterhouse's floor carries the candles' light in its bake (warm pools by every candle).

The probe starts the real game scene at a fixed spot of each area and shoots variants of its light (`--plan`; `lift=1.5` shoots at that exposure lift in place of the area's, which is how the table above was found; `nodress` takes the world dressing off, `before` is the look of the first test builds: no dressing, a sphere at every light, the five-mip glow;
the hero's box has its own `HSTAT` line and the hero variants are `hnoemis`, `hnogear`, `hnolantern`, `hgear`, `noamb`, `noprops`, `nossao`, `ring=K/S` and `crowd`, see the script's header), the glow part (`--part=glow --glow="name:lv=a/b,int=..;..."`) prints the glow's profile of two bright things under each setting of a list, and the calibration part prints one pixel line per test object. It runs on the VPS
under the renderer lock, one run at a time (the header of the script has the commands; a start takes half a minute). It is not a pass/fail suite: the checked
values are `tests/areas.gd` (the pools' flag, the tint table against its textures) and `tests/presets.gd` (the twelve lifts, the blend, the environment and what the lift leaves alone). `client/tools/compat_albedo.gd` prints the tint
table of `DmCompatAlbedo`.

## The HUD on the core

The HUD and panels run in the game scene (`opts.hud = true`; DECISIONS B46): `DmGameUi` (`game_ui/dm_game_ui.gd`) with every panel, on the
host-contract adapter `DmNextUiHost` (`next/hud/dm_next_ui_host.gd`), whose view-model is `DmNextHudVm` (`next/hud/dm_next_hud_vm.gd`: it reads the core's
arrays). `DmGameUi` applies the view-model every 50 ms (`HUD_INTERVAL_MS`) to `DmHud` (orbs, hotbar with cooldowns and the cast state, target frame, minimap, thrall pips, XP and
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
| notices | `DmAreaFlow` (an area's first entry, a themed wave), a refused cast (an "info" number over the hero), the boss fx's banners and the summon refusals: all `DmNextGame.game_event`, which reaches `DmGameUi` |

**A guest's window.** In a party the HUD hears the same events from what reaches the guest. The numbers of both heroes' rites (crits too) are `hit_number` on every peer, from the rites' events the host broadcasts; an enemy's hit flash is the crowd's, from the
puppet core's `damaged` events (derived from the snapshots' health); a DoT's lumps are `status_dot` (they ride the reliable batches). The guest's own hero's hurt is the fall in the vitals the host sends at 20 Hz: `DmHeroBody.apply_vitals` emits `hurt` for the health a
body that was alive lost while its maximum stayed the same, once per message (blows within 50 ms are one number with the sum; a blow that killed is the health it took, where the host's counts the overkill; a heal, a respawn and a new maximum are none), and the HUD binds it as
it binds the host's own: a number over the hero, the red flash, the hurt sound, the low-health sound under 30 %, the counsel's hurt flag and tip. An enemy's drag of the guest's hero is told by `DmNextNet.hero_effect` ("Dragged!" and the camera shake; a chill and a root are
statuses, which replicate). No work per frame: all of it is events. Not shown on a guest: a thrall's blow number over an enemy except the killing blow (the puppet's `damaged` has no source). `tests/coop.gd` ("the guest's window") counts each of these on both HUDs and `tests/coop_bosses.gd` the guest's hurt in every boss fight.

The upgrades box (Empower, Quicken and the wave dial), the belt (Q, Z, X), the Kill Chain, the Omen, the save chip and the pickup lines come with value ("Value on the server"); the menu row, the
panels and the Social window with `DmGameUi`. Not in the game scene yet, each with its system: the Altar (DECISIONS B36). The hub's prompts (the Chapterhouse node's hover and nearby lines) and the Depths readout, minimap floor and area line are in. The Acre ledger's panels (Skills, Garden, Laborers, Contracts) and the node and laborer cards are in ("Gathering and the Acre"). `tests/hud_feeds.gd` (`HudFeeds.full()`) fills every view-model key for the
tests that draw every piece.

**Pieces (DECISIONS B40).** Every readout group is a Control of its own with its own anchors and offsets, listed in `DmHud.pieces` (`party omen ward chain belt target boss map toasts banner prompt hint chat xp altar
upgrades`). `set_piece(id, offset, scale)` moves one by `offset` logical pixels and scales it (0.5 to 2) around the corner its anchor holds (a piece anchored to the top right grows left and down, the hotbar up and
sideways); `set_layout({id: {offset, scale}})` applies a saved layout (a piece it does not name goes home); `show_piece(id, false)` hides one for good; `set_hud_scale(0.75 to 1.3)` scales them all at once (Settings' HUD size sets it through `DmGameUi`).
Nothing calls `set_piece`, `set_layout` or `show_piece` yet: there is no editor, and this is the structure it will need.

### The HUD's budget

DECISIONS B39: the HUD at most 0.5 ms and 150 draw calls on Helix's PC. The old game's HUD was about 550 draw calls (its benchmark on Compatibility, DECISIONS B50). In Godot 4.7's canvas renderer
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

What the HUD does with that (`ui/hud/dm_hud_kit.gd` has the layers, `next/hud/dm_hud_atlas.gd` the atlases; the layout, colours, fonts and numbers are unchanged by it):
- **Layers.** Panels (9-patches) z 0, rectangles and icons 1, vector art 2, rectangles over the art 3, text from 4 up (one layer for each font and size), toasts, banner and prompt +100, the floating numbers 200.
  A HUD label is put on its layer when it is made; `DmHudKit.layer_tree` does the rest of a subtree.
- **One atlas.** A runtime atlas holds every icon (ability art is kept at 128 px, shown at 62), a white block (any rectangle), the bars' gradients and, on a page of its own, every panel's 9-patch (`DmHudKit.plate`
  makes a `StyleBoxTexture` of the picture of a `StyleBoxFlat`; `style` still gives the StyleBoxFlat the panels ask for). A greyed slot icon is a baked variant, not a shader.
- **One mesh per widget.** The orbs (2 draws), cooldown sweeps (5 triangles at most), thrall pips and gems (one mesh for the row), the level badge, the minimap's frame, disc and edge fade, its marks and arrow, and the
  death veil are triangle bags (`DmHudMesh`); the minimap's dots are one MultiMesh.
- **Floating numbers are a pool** (`DmHudFloats`): 48 entries of two canvas items made once; a frame only moves them; the numbers of a kind are two draw calls.
- **What drawing it this way changes** is a few pixels, where a shape is drawn another way. Panels and borders are pictures of the same fill, border and rounded corners (`DmHudAtlas.nine`, 16 samples a pixel) instead of `StyleBoxFlat` geometry: identical at the design size, and at other UI scales the 1 px borders and the 2 and 3 px corners
  are filtered a little differently (the hotbar's plate keeps its soft shadow, still a `StyleBoxFlat`). Icons are scaled once, to at most twice the size they are shown at (ability art 256 to 128 px for a 62 px slot, portraits 480x640 to 96x128), with a Lanczos filter. The orbs' liquid body has 20 steps along its arc (0.2 px off the circle) and the surface ripple is a 2 px ribbon with a half pixel feather,
  redrawn 15 times a second while it moves. Cooldown sweeps are exact to the slot's square (a fan of at most five triangles). The minimap's dots are 14-point discs; the area fills, edges and doors are drawn first and the hatching of a sealed area after them; a dead enemy is not a dot while the core still holds its body (4 s); loaded areas count as unlocked and the doors between two loaded areas as open.
  Floating numbers have no 1 px shadow under their 3 px outline (the outline covers it), overlapping numbers draw in pool order rather than oldest first, the thrall and DoT numbers come from the core's damage and DoT events at the enemy's position that tick, and the caps (14 hit, 5 dot, 6 thrall, 22 in all) count in real milliseconds. The target frame reads the core's status bytes (a Withered pile past 255 stacks is read from `status_stacks`;
  a status the HUD has no icon for is not listed). "N slain here" counts every enemy that died in the area this run.

*Measuring.* `tools/hud_measure.gd` starts the game scene with the full HUD in a Full Party-like crowd (72 enemies, 32 thralls, numbers kept at their caps), reads
`RenderingServer.get_rendering_info(RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)` and the canvas share of it with the HUD hidden and shown, as the game scene shows it and with every piece on, prints the HUD's CPU cost, and
(`--micro`, `--fidelity`, the breakdown) the cost of each drawing primitive, the pixel difference of each replacement against the original, and each piece alone. It writes one JSON line per measurement as it goes:
```
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 xvfb-run -a -s "-screen 0 1600x900x24" \
  timeout 55 /home/ubuntu/tools/godot/godot --path client --rendering-driver vulkan --resolution 1280x720 --fixed-fps 60 --script res://tools/hud_measure.gd -- --out=<file.jsonl> [--shot=<png>] [--micro] [--fidelity] [--3d]
```
**Status (2026-10-17): measured on Helix's PC** (RTX 4070 SUPER, 2560x1440, the benchmark's render breakdown, the Bell Sanctum's Full Party with the panels in): the HUD row draws 120, 120 and 117 calls on Low, High
and Ultra for 0.03 to 0.05 ms of GPU, and the HUD's share of the main thread is 0.07 ms (eight on/off rounds). The model's 63 to 81 counts the HUD alone; the rendered row also holds the panels' pieces. On this VPS a Forward+ process needs ~21 s to reach its first script line and then ~23 s inside the first main-loop iteration (software
Vulkan pipelines; it does not shrink with drawing switched off), so a 55 s run has about ten seconds left: the table above comes from a bare scene, and the harness runs with a longer limit (`timeout 180 ... --budget=170`) for a look at single widgets.

*The model.* `tests/hud_cost.gd` is a model of the batching rules in the table; `tests/hud.gd` first checks that it reproduces the 18 numbers the rendered run counted for the same trees, then asks it about the HUD in a Full Party fight
(72 enemies, 12 thralls, casts on cooldown, a target with four statuses, toasts, numbers at their caps): 63 draw calls as the game scene shows it (26 text, 10 vector art, 8 floating numbers, 6 toasts and banner, 3 panels, 1 rectangles
and icons, 1 borders) and 81 with every piece on and fed (41 text, 13 art). The test fails above 150, so a control left on the wrong layer or a new polygon per thing shows up in CI. Asked about logged copies of the old game's widgets in the same
fight the model said about 500 for its HUD (the hotbar 188, the minimap column 160, the floating numbers 104, the target frame 18) and 630 with every piece on; the benchmark counted 544 to 564 for it in Compatibility.

*CPU.* The HUD's work on the main thread is of two kinds. **Per frame:** what animates (the orbs' ripple, 15 times a second, the floating numbers, the counsel's card, the cooldown edges and sweeps) and the panel host's clocks
(counsel, guidance, cues). **Per refresh:** the view-model build and its apply, every 50 ms of **wall** time (`DmGameUi.HUD_INTERVAL_MS`, 20 Hz), so a refresh falls on every 12th frame of the VPS's 4 ms headless frame, every 5th
of a 10 ms frame (Helix's 99 fps) and every 3rd at 60 fps. It costs about 1.5 ms in the Full Party fight (the caches cold: 0.4 ms hot in `tests/hud.gd`), which is 0.12 ms a frame on the VPS, 0.3 on a 10 ms frame and 0.5 at 60 fps:
**the VPS's share leaves most of the refresh out**, and Helix's PC pays it in full (measured there on 2026-10-17: 0.07 to 0.08 ms, DECISIONS B50).

The HUD's share on this VPS in the Full Party fight (2026-10-17; `--benchmark --bench-room=graves --bench-size=full_party --bench-class=2`, headless, `--fixed-fps 60`, a new character with its tips):
the benchmark's own HUD readout is eight rounds of half a second (give or take 0.3 to 0.85 on a busy machine), too coarse to tell 0.45 from 0.55: five runs read **0.15 to 0.67 ms (median 0.51)**. The same on/off rounds, seventy of them, in CPU time with the slowest 3 % of frames left out
(give or take 0.1 to 0.15 each) read **0.42 to 0.57 ms** (four runs; 0.37 to 0.63 over every run of the last three versions on a machine with a load of 5 to 15). The rest of the main thread in the same fight is 3.0 to 3.2 ms (5.7 in one busy minute). `tests/hud.gd` hot (three runs): the
refresh's build 0.36 to 0.48 ms, its apply 0.11 to 0.14, and a headless frame with the HUD 0.21 to 0.41 ms over one without.

The rules that keep it there (every `_process`, `_draw` and the refresh's parts timed in a scratch copy of the project, never committed; a call costs two to four times in the game what it costs in a loop,
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

The counsel is `DmCounsel` (the tip queue in `ui/onboarding`: kinds, groups, places, cadence, the card and its glow), owned by `DmGameUi`; it is cheap to wait with ("The HUD's budget", CPU: the clock waits for its earliest timer, a card on screen is compared with the urgent tips alone, the card's line is drawn once). It is fed through `DmNextUiHost.game_event` and polled every
400 ms; `data/onboarding/tips.json` has the 122 tips and `DmCounselEvents` the table from a fact to its tips. What reads creatures is the counsel's host side, `DmNextCounsel`, and the few facts the creatures give it.
Neither has a node or a call per creature: both are the core host's events and one timer.

| fact | where it comes from | tips |
|---|---|---|
| a body spawned within 40 m (`enemy_spawned {def, elite, near, area_safe}`) | the host's `enemy_spawned`, once for each, in `DmNextUiHost._on_enemy_spawned` | the kind's first sight, move, elite, deacon |
| a corpse laid (`corpse_near {area_safe, dist}`) | `corpse_added` | exhume (within 12 m, outside a safe place) |
| a Deacon blessed a body (`sanctify_near {dist}`) | the `sanctify` cue | sanctify (within 18 m) |
| the hero hurt (`hurt_check {hp, max_hp}` each blow, the `hurt` tip below half health) | the hero's `hurt` signal | hurt |
| a cast refused for essence (`essence_short`) | the caster's rejection | essence |
| a fight: three living dead within 9 m of the hero, or the boss awake | `DmNextCounsel`, on the poll | holds calm tips back (`busy.combat`); the Grimoire's rune swap (`in_combat`) |
| corpses within 7 m, a pack of three on a corpse, the thralls he owns | `DmNextCounsel`, on the poll | thrall, litany, burst |
| kills, shards, gold, the bag, a boss site or a closed door near, the unlock set | the progression and the bag, on the poll | codex, wave, prelate, belt, tool, boss sites, gate |

`DmNextCounsel.tick_ctx` (DmGameUi's 400 ms timer) asks the core: one radius query for the fight (the core measures to the edge, which finds everything the centre test finds, so a candidate is confirmed by
its centre: a rising or burrowed body counts, a dead one does not), `corpses_in_radius` for the corpses and, for each, one more query for its pack, `thrall_count` for the legion: 0.18 ms a poll with
72 bodies and 30 corpses around the hero (`tests/counsel.gd`, INFO). The busy flags (`counsel_busy`, 10 Hz) are two time stamps and the hero's `alive`.

**The first hour.** `world_entered {family, level, grimoire_unlocked}` is raised once at the end of `DmNextGame.start` (the welcome tip; from level 10 the signature, with the Grimoire unlocked the Grimoire tip).
The welcome tip is a tip of the Acre (`HERE` in the tips data), so a new hero meets the belt's tip first (the bag's flask) and the welcome when he walks into the Acre. The Next-step box (`DmGuidanceHud`), the
Prior's greeting and advice (`DmCovenantDialogue` over the same `guidance_state`), the HUD's progressive reveal, the NEW cues, Settings' "Show tips again" and "Don't show tips" (kept with the account) are
`DmGameUi`'s; a party joiner whose kills the backend will not credit is told at the end of `start`. The poll says `altar: false` (`DmCounselEvents.tick_calls`),
because the game has no Altar of Ascension (B36), which holds back the vows, altar_unlocks and boons tips; `can_ascend` (the Prelate's fall) stays unraised too. Not raised: the Depths' tips
(`depths_solo`, `depths_floor`, `depths_affix`, `depths_chest`), `omen_told`, `set_bonus_gained`, `necro_weapon_changed` and `loadout_check` (`ui/onboarding/README.md`).

`tests/counsel.gd` plays it on the whole world as a new Gravecaller: the poll against a brute-force reading of the core's tables (24 seeded placements, and the edges by hand: bodies whose edges are within 9 m and
whose centres are not), every fact above through the real scene, each tip queued and shown once, the state-driven tips one fact at a time, the welcome held for the Acre, the
Next-step box, the Prior, the reveal, an area's first entry, no Altar tips, Show tips again and Don't show tips.

## Sound

Sound is the `AudioDirector` autoload (`audio/`: its map, mixer, beds, music and footsteps; `audio/README.md`) and the cues the game plays through it. The cues of creatures come from the core's events, never from
a node per creature, through one router and the ids of the audio map:

| cue | where it plays |
|---|---|
| an elite rising within 40 m (`eliteAggro`), every telegraph (`tellStrike`; `tollSmall` for the cone and the toll; `raise`; `curse`), a swing landing (the attack voice within 18 m; `boneHit` for a slam), the ghoul's eruption (`burst`), a death (`enemyDeath` or `eliteDeath`; the death voice within 26 m) | `DmEnemyFx`, from the host's `enemy_spawned`, `telegraph`, `enemy_attack`, `enemy_state` and `enemy_died`, through `DmEventFx` |
| the affixes: the bell's toll (`toll`), a meal (`raise`), the vengeful's burst (`burst`) | `DmEnemyFx._on_affix_moment` |
| a thrall standing up (`thrallRise`), one killed (`thrallDeath`; not one that crumbled, was sacrificed or decayed) | `DmEnemyFx`, from `thrall_raised` and `thrall_died`; a guest's puppet core raises the same events |
| the hero hurt (`hurt`, `lowHealth` under 30 %), `buy`, the pickups | `DmNextUiHost`, `DmNextLoot` |
| the rites | `DmRiteFx`, through the caster |
| the listener, the area's bed and score, the hero's footsteps (the walk loop's phase, the area's surface, water where he wades), the gate | `DmAudioHooks` (a child of the game scene) |
| the boss score and the boss sounds | `DmBossHost`, `DmBossFx` |
| the panels, the counsel's card | `DmGameUi.sound`, connected to the director by the game scene |

The hooks' gate sound is the world's `door_opened` signal (a door rose: at the door's centre; silent for doors that rise while the world loads, before the hooks' first frame).
`DmEnemyFx` forgets a swing when its body leaves alive (a boss's adds go with him). Everything is gated by `opts.audio` (on in a player's window, off headless).
Every kind on the core has its sounds (the router plays the tells; the Templar's shield glance, `tollSmall`, and the Acolyte's Unbind, `raise`, are cue sounds of `DmEnemyFx._on_cue`). The Depths have no sounds of their own (`gate`, `chestOpen`, `levelUp`, `click` and `error` are existing ones).

`tests/sound.gd` puts a recording stand-in where the director is (every call logged, passed on to the real one where a check needs it) and plays a scripted fight in the Graves, the hero standing still and not able to
fall, and checks the cues played for the events the core raised, by name and count (a swing within two ticks of landing or of what ended it may count either way); then the thralls at their places and only the killed ones' death, and the hero's world on the real director: footsteps, the beds
and scores of four areas, the gate, the boss score with the King.

## Threads

A worker computes data and hands it back; whatever touches the scene tree, a node, a signal or a Godot object that is not thread-safe happens on the main thread, after the worker has finished. The places that take a worker's result call
`DmThreadGuard.assert_main` first (a violation is an error in the log and a count the suites check is 0: `tests/depths.gd`). `tests/threads.gd` lists what starts work off the main thread and fails on anything new until it has been read and added here; the C++ core starts no thread, lock or atomic.

| what | thread | touches | result |
|---|---|---|---|
| the Depths' floor generator (`DmDepths._generate`) | a `WorkerThreadPool` task | content (read only once `DmDbWarm` has run) and its own arrays | polled on the physics frame with `is_task_completed`, joined, the Dictionary returned to the controller |
| the Depths' navmesh bake (`DmDepthsGround.prepare`) | the navigation server's pool task (`bake_from_source_geometry_data_async`) | the source geometry and the `NavigationMesh` handed to it, which the main thread leaves alone until `is_baking_navigation_mesh` is false; the server emits `changed` in its own main-thread `sync` | the mesh goes on the region (`show`) on the main thread; a bake that does not finish in 20 s is made again on the main thread on a fresh mesh |
| the Gear Atlas' verdicts (`DmUiPanelsA._atlas_*`) | a `WorkerThreadPool` task | a deep copy of the stat context, a fresh map of what is owned, and the static tables the first main-thread pass filled (`tests/threads.gd` checks a worker writes none of them) | joined in `_atlas_data` or `tick` before the result is read |
| a legendary body's prefetch (`DmGearModels.prefetch`), the sample bank (`DmSampleBank`, twelve in flight), the warm-up's models (`DmNextWarmup`, not headless), the release check `--boot-check --quit-while-loading` (`DmMain`: asks for the warm-up's models, then quits with them in flight) | `ResourceLoader.load_threaded_request` | resources only, no node | `load_threaded_get`, or `load` from the cache, on the main thread |
| the mixer | the audio driver's thread (the Dummy driver in a headless run) | the bus layout and every playing stream, under the audio lock | n/a |

**Data the workers read.** `DmDbWarm.all()` (`DmNextGame.start`, in loading) reads every dataset and projection of `DmDb` once, so its cache never changes again: a Godot Dictionary is not safe to read on one thread while another inserts, and a first use of a dataset
is an insert. About 100 files, 4.6 MB; +60 ms in loading (3.37 s without, 3.43 s with, three runs each alternating on the shared VPS, spread +-0.25 s). The Depths' floor generator calls `DmDbWarm.all()` (a hundred lookups when warm) and `DmSimData.ensure()` before it starts.

**The mixer.** `AudioServer.add_bus` and `set_bus_send` edit the bus list, the name map and a bus's send without taking the audio lock (Godot 4.7.2 `servers/audio/audio_server.cpp`), while the mixer thread reads all three in every mix step (`bus_map[bus->send]`). An edit that lands
in the middle of a step can crash the mixer thread (the one crash log with frames, 2026-10-07: the Dummy driver's loop, then the step's lookup of a bus's send in the name map). The director makes about 55 buses at start, while the mixer already runs (`AudioDirector` is an autoload), and changes a voice's send as sounds play. Its two helpers `_add_bus` and `_set_bus_send` hold
`AudioServer.lock()` around an edit (the lock is recursive: `set_bus_name` and `add_bus_effect` take it themselves); nothing else in the client edits the layout (`tests/threads.gd`).

**Reading a crash.** A crash on any thread but the main one prints, just before Godot's `handle_crash: Program crashed with signal N` and its C++ frames, `ERROR: /root: The caller thread can't call the function propagate_notification()`. That is not code touching the tree: the crash
handler tells the main loop, the scene tree hands the notification to `/root`, and the call is refused off the main thread. Then the process aborts (exit 134, SIGABRT) whatever the signal was. (`OS.crash()` in a `WorkerThreadPool` task prints exactly this.) The signal and the frames are the
crash: `start_thread` at the bottom is a pool, loader or driver thread, and a GDScript backtrace under the message names the script that thread was running, if any. The official binary has no symbols; the frames can
be told apart by what they call (a function that takes the audio mutex, calls `clock_gettime` before and after, then `delay_usec` is the Dummy driver's loop).

## Value on the server

The backend owns value (DECISIONS D1, B20, B32), and the game scene earns it as follows. On the host (`DmNextGame._start_value`, under the loading cover):
- **Rewards** (`next/rewards/dm_session_rewards.gd`): a kill is the game's `kill_credited` (the core's EV_ENEMY_DIED, credited once, to the hero who struck it or the owner of the thrall
  whose blow it was), not each enemy's `died`; everything after it: who earned it (alive, within 38 m), the Kill Chain for the killer, the loot roll from the member's drop tape,
  the gold pool, and the numbered kill reports of the backend's party session, whose replies decide the XP and kill counts applied. Lifesteal hears `DmCoreHost.struck` (a hero's direct blow
  through `damage`; a DoT tick or a thrall's swing never is one). A boss's defeat pays through `on_boss_defeated` (the boss host calls it).
- **Meta, milestones, Chronicle, progression** (`next/meta/dm_next_meta.gd`, `next/areas/dm_wave_milestones.gd`, the Chronicle and `DmNextProgress`):
  difficulty, the week's Omen, Soul Harvest, the Kill Chain, the level-ups, the upgrade tiers, the belt, and the saves through
  `DmProgressSync`. The host's world (its difficulty) reaches the lobby (`DmNextParty.sync_world`).
- **No Ascension** (DECISIONS B36): a character's saved vows, boons and Ashes stay on the server, untouched, and do nothing here: the world runs without vows (no heat,
  the rewards' rank 0, the base corpse lifetime), a build reads its progression without them (`DmNextGame.without_ascension`), no Covenant Boon acts (the Bonded Dead
  do not rise) and the party's world carries no heat. One switch, `DmAscension.OPEN` (false), hides what is left of it on screen: the
  Chapterhouse's Altar is scenery (not interactable; the `altar` station opens nothing), the guides neither offer it nor name a rank
  (`DmGameUi.guidance_state`), the Prior has no Altar topic, the Codex no Altar page (`DmCodexPanel.shown_tabs`), and party, friends and
  invite rows show the host's difficulty without Heat (`DmNextFriends.world_line`). The redesign turns it back on.
- **The loot node** (`next/rewards/dm_next_loot.gd`: the take, pickup, claim and rune-ownership paths, apart from the
  panels): a click on a drop walks the hero there and takes it on arrival (loot never flies; walking over it takes nothing); a drop rolled from the tape is claimed, and the server puts its
  own roll in the bag; a rune the character owns (learned, bag, Vault) never drops. The bag is the server's rows (`DmInventory`); worn gear feeds the build, and the belt drinks from it.
- **The HUD** reads the member's progression (level, XP, gold, shards, tiers), shows the upgrades box and the wave dial by the veteran-reveal rules (`DmHudReveal.veteran_reveals`), the belt, the Kill
  Chain, the Omen and the save chip, and the toasts, banners, floats and pickup lines of `DmNextGame.game_event`.
- **Saving:** `flush_all` (leave, the window's close) ends the party session with its last batch and flushes the Chronicle, the progression and the bag.

**A party guest earns on its own account** (DECISIONS B22, the handshake in `DmNextParty`): the host makes it a rewards member (its character id, remote, rolling its own
drops), its `DmNextJoiner` (`next/party/dm_next_joiner.gd`) joins the host's backend party session with the guest's own token and holds its progression,
saves and drop tape; the host reads the guest's build from the server (`remote_builds`: gear, sets, boons, vows, runes) once it joined and whenever its worn gear changes; the
host's accepted reports, gold, shards and drop events go to the guest, which rolls its items from its own tape and claims them into its own bag; its belt drinks from its own
bag and the host applies the drink.

**Ground drops between members** (ground.cjs): the Reliquary's Drop (`DmNextUiHost.drop_gear`) puts a piece on the party session's ground; the party draws it for the members the server
lets take it (`DmNextParty.share_ground`), the first pickup wins (`DmNextLoot`'s claim, `api.ground_pickup`) and the other copies go (`share_taken`). A rune's or a legendary's find is a
chat line the party reads (`DmNextParty.announce`).

The Covenant Seal's altar choice and the boss key prompt (`DmBossMeta`) are in ("The bosses").
`tests/rewards.gd` plays the rewards node on the mock backend (sessions, batches, lost replies, refusals, the end, per-member loot; a test double emits `kill_credited`); `tests/value.gd` plays the game scene on the mock: kills through the core, the accepted
XP and counts against the server's counters, the purse, a drop claimed into the bag, brews and lifesteal, the meta, Q's flask, and the save on leave.

## Gathering and the Acre

Gathering (the nodes of the world, the professions, AFK) and the Acre (the Grave Laborers, the garden, the Sexton's contracts) on the game scene (`next/gathering/`; the loop, the rules and the panels are `game/dm_gather_loop.gd`, `rules/gathering/` and `ui/`):

| piece | here |
|---|---|
| the nodes | the 68 of `world.json` are props of the area scenes (group `GatherNodes`, one holder named by the node's id, placed and turned as the data says). `DmNextWorld` hands the lights-only builder their holders (`node_views`) and each area's root (`area_nodes`), the two members the copied `DmNodeViews` reads. It swaps a node between its live look (the scene's prop) and its spent look (the pipeline's spent model, built the first time a node is spent, or the stand-in), draws the hover and selected rings and the progress arc under the hero, and makes a rich node a little bigger with a glow disc |
| the Gather node | `DmNextGather` (child `Gather` of `DmNextGame` on every peer at the same path, made right after the session starts so a guest has it before its relay hold is released). The host runs the loop for its own hero, owns each node's yield (`1.5 x` for a rich node) and respawn clock (half for a rich node) and credits through the backend; every peer holds the spent set, replicated as the host's RPCs (`_rpc_state`, and `_rpc_full` for a joiner) |
| hover, click | `DmNextInput` asks the node 10 times a second (`hover_at`) unless a station or a person is under the cursor; a click that is not on a drop, an enemy, a station or a person walks to the node (`click_at`). Cost: the nodes of the current area within 26 x 22 m of the hero, about 0.1 ms a pick; nothing is built by hovering |
| a cycle | `ticks x 600 ms` (the node's `ticks`; 2.4 s for a first-tier node). The client rolls each cycle for feel (the gesture, the floating XP, the sound); a success takes one off the node's yield; at none the node is spent (its model swaps, the card says "Spent. It will return soon.") and Auto (the Settings toggle, on by default) walks to the next live node of its kind or waits beside it for the respawn; Auto off ends with "The X is spent." |
| the server | the cycles go to `POST /api/gather` in batches (8 s, 40 cycles, or when the work stops), after the bag is saved. The server decides what was found, the XP and the level from its own dice and its time budget (a burst of 3 beyond what the time allows, 1,800 cycles an hour); the client adopts its answer: the bag, the professions (`skills.adopt`), the gold, the Chronicle's `gathered.<skill>` count, a "Found: ..." toast for each extra, the level-up banner and the counsel's `skill_up`, the rare-find banner for a pet charm. A refusal is shown in the server's words and the cycles are dropped; offline or a 5xx keeps them and tries again 10 s later. The client's own rolls never mint a thing: cycles it rolled as failures are paid too |
| stops | walking by hand, a click on the ground, a panel, a rite, death, a full bag ("Your bag is full." before it starts); a level the skill has not reached is refused in the rules' words ("Requires ...") and GM mode opens every tier to the client's gate |
| AFK | from the Skills tab (P), in the Acre only ("Visit the Sexton's Acre for safe AFK gathering."): `begin_afk_gather`, then the loop with no burst; stopping shows the report (`gather_report`) and keeps the best session in the counsel store under the original key |
| the Acre's glue | `DmNextAcre` (child `Acre` of the host, with the real HUD; it reads the world's lights-only builder) is the host object `DmLaborerViews` and `DmGameLabor` talk to: the garden check 4 s after the game is ready and every 60 s ("N plots are ready / still growing in your garden (U)"), the labor check 6 s after and every 5 min ("Your laborers have gathered about N finds (H)" after 30 minutes of work, "A laborer has filled up"), the panels' results (`on_labor_collected`, `on_garden_result`, `on_contract_delivered`: the gold the server paid, the Chronicle, the report hung under the laborer, "Harvested N x ...", "Grave Gardening N", "Order filled"), and the feeds the Sexton and the Next box read (`labor_summary`, `contract_summary`, the skills' levels, the bosses beaten) |
| the panels | the Acre ledger (Skills P, Garden U, Laborers H, Contracts), the AFK report and the node and laborer cards are `DmGameUi` panels, warmed with the others (`DmNextGame.WARM_PANELS`); `DmNextUiHost` forwards their calls to the Gather node and the Acre |

**The Grave Laborers are views, not bodies of the core.** Up to four pooled `DmCreature` models (the legion's art, `skeleton_thrall` and its kin) stand at their posts in the Acre and chop, dig or fish; each is a full skeleton with
a tool in its hand, none is a thrall of anyone's legion, and none exists outside the Acre: they are made on the first visit and hidden, not updated and not fetched anywhere else. A crowd goes in the core's arrays; four
characters are the same kind of thing as the hub's three people, so they stay nodes, and the count is capped by the labor rules (`DmLabor.MAX_SLOTS`, 4). A laborer competes with the nodes for the hover by screen distance
(an 18 px bonus), and a click on one opens the Laborers (H).

*Cost.* An idle frame of the Gather node and the Acre's glue is about 4 us (measured once; the tests no longer print it): the Gather node accumulates a clock, ticks at 10 Hz (the views' pulse, the loop's update), and while a loop runs it ticks every frame for
the progress arc; the respawn check runs at 4 Hz only while a node is spent; the Acre's glue is three timers and, in the Acre only, up to four laborers within 48 m. No node or script exists per creature, and nothing is scanned across all nodes.

*Tests.* `tests/gathering.gd` plays it on the local mock with a game clock the mock follows (the whole world, the HUD and panels, no real server): the nodes in the scenes and their views, all 68 hovered and clicked (a level refused in the
rules' words), a node worked from the click to the server's answer and to spent and back (the walk, the cycle's length, the batch, the bag, the XP, the Chronicle, the respawn), the stops, Auto off, the server's dice
(a level-up, the extras, a charm, the burst, a spent hour), AFK and its report, the laborers (none built outside the Acre, three at their posts, the hover card, a click, three hours of work, a collection with its gold), the garden (plant,
harvest, a level), a contract, the Sexton's greeting, the guidance feeds and the Next box's state, the notices of a full laborer and a ready plot, each skill's find and XP, the Sawpit's plank from gathered logs, every node's stand spot and yield, and a relaunch that keeps the results. `tests/chapterhouse/run.gd` also crafts at every forge station, reforges an affixed piece and sends a bug report. `tests/coop.gd` checks that a node the host spends is spent on the guest.

*Gaps.* A node's live look is the area scene's prop, which the lighting bake lit; its spent model is built at run time, so it is lit by the area's real-time light and ambient, and the bake's light of the live model
stays on the ground around it. Never looked at on a GPU. The laborers' models are first built on the first Acre visit (`DmNextWarmup` does not draw them yet, so the first look at their materials on a GPU is unmeasured). Gathering is the host's: a guest holds the nodes and their views but has no loop (its character has no backend api on the host), so it cannot gather, and it does not see the host's laborers or the tool in
a gatherer's hand. Cycles worked in the last 8 s before the window closes or the player leaves are not sent (`flush_all` does not flush the loop).

## Co-op on the core

Co-op (DECISIONS B22, B26-B28, B38, B40, B42) is the session, relay and lobby with the combat core's messages on top. One player HOSTS: the real game runs on the host's core, as in a solo run, and the
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
- **Snapshot**, host to guest, unreliable ordered, 20 Hz: `core.snapshot_parts(tick, 1300)`. **The split:** the Full Party's snapshot is 1.2 KB on average and reaches 1.7 KB, past the 1,392 bytes of an ENet packet (ENet fragments
  a bigger unreliable packet, and one lost fragment loses all of it), so it is cut **by body ranges**: the live enemies in spawn order, then the thralls, in as many messages as keep each at or under 1,300 bytes (the RPC frame and the relay's
  6-byte header come on top: a packet stays under the 1,364 B or so that ENet sends in one datagram). Every part is a complete snapshot message of its own bodies, with its own tick (the parts of a frame are consecutive numbers, the frame id), and **the guest applies each part as it arrives**:
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
business, later). The guest's core host knows the boss by the id the host's core gave it (`DmCoreHost.adopt_boss`, taken from the state): the hover pick, `enemies_in_radius` and `enemy_info` find it there as they do on the host, and nothing is
written to the puppet core, which has no externals. A wipe is the host's: both heroes fall, the brain resets, its adds leave through `remove_enemy` (no death, no corpse, no credit) and the body is freed on both sides 8 s later.

**Joining** (`next/party/dm_next_party.gd`, node `Party`): hosting turns the running solo session into a hosted one (`host_session(name, closed)`: lobby `create`, `DmRelayPeer.host`, `DmSession.swap_transport`; Open parties are listed, Closed ones
need the code or an invite); `join_by_code` / `join_session` / `join_friend` seat a solo game in a party (`join_ready(lobby, info)`: the shell frees the solo game and starts a guest game on that socket, `opts.lobby`); `invite_friend`,
`ask_to_join`, `answer_request`, `accept_invite` are the friends flows over the lobby's presence of online mutual friends; `view()` is the contract of the Party pane. Errors are the player-readable `ERROR_TEXT` / `CLOSE_TEXT`.
Party chat goes through the host (`DmNextParty.chat`: the host names the speaker, at most 4 lines a second a player, 200 characters a line). The guest's own account and the
ground drops between members are "Value on the server".
A player's world keeps a lobby link (`go_online()`, after loading) so friends see it online and invites and asks arrive. The friends list itself is `DmNextFriends` (the backend's friends routes); a friendship it changes is announced
through the party (`friends_changed`).

**The Social window** is the player's way in (`game_ui/dm_ui_social.gd` in `DmGameUi`, its window and panes `ui/panels/dm_social_window.gd`), opened with O (Friends),
F (Party) or the HUD's Social button and wired through the adapter's party and friends calls (`DmNextUiHost.party_view`, `friends_view`, ...) to `party` and `friends`. The Party tab
hosts an Open or Closed party and lists the Open ones to join; the Friends tab sends and answers friend requests and joins, asks or invites an online friend; the public list is
watched only while the window is open. **`main/main.gd`** does the hand-over: `join_ready` frees the solo game and starts a guest game on the same lobby socket (behind "Entering the host's world..."); `client_ended` and a refused or failed join put the player
back in their own world with the reason as a toast.

Launch arguments, for a trial without the window (any build): `--host-party[=name]` makes a Closed party as soon as the world is up (the code is in the log and in a toast), `--join-party=<code>` takes a seat before the game is built,
`--lobby=<ws url>` points at a lobby on this machine (the token in `DM_LOBBY_TOKEN`).

**The live lobby and relay are the only ones this build uses** ("The API rule"): `DmConfig.LOBBY_URL`, `RELAY_PORT`, `allows_lobby_url`, `allows_relay`. The lobby (`server/death-muffin/lobby/`) offers the relay's address and a ticket when a session is made or joined; without the relay a session
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
more), over a REAL lobby (the node service on a free port, a test signing key) and the real `DmUdpRelay` in the process (offered by the lobby, so the packets travel the UDP lane). It runs the party flow (a Closed party, a join by code; the wrong codes, invites, asks, chat and roster are `tests/lobby`'s), the connection (both on UDP, the puppet, the ids), a still moment and a fight compared **at the snapshot's own tick** (every live body the same, every position within the 1 cm quantization, lost parts excepted), a guest cast resolved by
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
time the HOST asks: a wipe (both heroes fall, the boss resets on both sides with nothing paid, its adds leave with no death, corpse or credit, both get up, the bodies are freed on both sides). `tests/lobby/ui.gd` (about 40 s, a local lobby) drives the Social window: the button, O, F and Esc, hosting an Open party from the Party tab, a guest that is the real boot scene (`DmMain`) joining it from the list and leaving from its tab (main.gd's hand-over both ways), a refused join and a host who closes the party (the guest back home with the reason), a friend request sent and answered from the windows, friends' presence over the lobby, and zero script errors. It prints INFO lines: the Full Party's bandwidth for one guest was about 28 KB/s (23 KB/s snapshots, 0.7 KB/s reliable) in 82 packets/s on the host's connection, 2.7 % and 14 % of the relay's limits (1 MiB/s, 600 packets/s); the largest game
packet was 1,231 B.

## The server: login and character select

`main/main.tscn` (`DmMain`) is the project's main scene: the boot and front flow (login, register, the online gate, character select, the discipline switch,
the saved login `user://dm_jwt.txt` in this project's own user folder), pointed at the **live server**, then the game scene with the chosen character:

```
/home/ubuntu/tools/godot/godot --path client            # login with a live account (never a real one in a test; tests run on the local mock); pick a discipline
```

- A character that already exists skips the select screen (`resume()`); one whose discipline is not playable goes to the discipline switch. The online gate reads the live
  manifest (`https://muffindevelopment.com/death-muffin/client/manifest.json`, its `online` block).
- **One character per account.** A discipline card selects the account's main character and switches its discipline (`DmApi.load_or_create_character`, server `POST /character`); only an account with no character gets a new one. Settings has **Log out** (final save, the token dropped,
  the login screen) and **Switch character** (final save, the party left, the select screen on the same token; the login screen only when the server refuses the token: `DmFrontFlow.switch_character`).
- **The character's build comes from the server**, read-only, before the game starts (`DmMain.load_build`): the bag's rows (worn gear, set bonuses, the weapon line) and the progression (damage and
  legion tier, boons, vows). `DmNextGame.build_for` builds the hero from them, so the hero's health, spell power and loadout follow the worn gear.
  A bag or progression the server fails to give sends the player back to the login screen with the server's words; nothing is written, created or imported.
- Server errors are shown in the player's words ("Cannot reach server — check your connection", the server's own `error`, "Request failed: 502"); a stored login with the server unreachable lands on
  the login screen saying "Online opens soon".
- **Value is the server's** ("Value on the server"): the kill reports, the drops claimed into the bag, the progression's and the bag's saves all go to the live API with the logged-in character.
- **Crash report and update notice:** the automatic crash report (`DmMain._send_crash_report`, DmCrashWatch; with the combat core's crash note since
  2026-10-18: native/README.md "Crash notes") and the update notice (`DmNextGame._start_update_check`,
  DmUpdateCheck). Log out, Switch character and a discipline change (Settings, the class
  panel) save and hand over (`tests/front.gd` "hand-overs"). The four necromancer disciplines and the Reaper play (`tests/rites.gd` "the disciplines", "the Reaper").

### The API rule (DECISIONS B38, B49)

The client plays on the **live server** and **never reaches the test server** (since launch day, 2026-10-18). Where it may talk is set in
**one place**, `net/dm_config.gd`, and enforced twice:
- `DmConfig.API_BASE` is the live API (`https://muffindevelopment.com/death-muffin/api`), `SITE_BASE` the site's root (the launcher's manifest and the patch notes are under it),
  `LOBBY_URL` the live lobby and `RELAY_PORT` the live relay's (5193). A test run and an exported build all read these constants: there is no publish-time swap to miss.
- `DmHttpTransport.send` (the one door to the network) refuses any URL `DmConfig.allows_url` does not accept: under the site's root, never under a test-server path
  (`DmConfig.TEST_PATHS`: the test API, the test channel, the test lobby), nothing with a `/..` that a server would resolve elsewhere. It logs an error and answers like an unreachable server.
  `DmNextGame.start` refuses any api whose base url is not the live API or empty (the local mock). `DmNextParty` connects only to a lobby `DmConfig.allows_lobby_url` accepts (the live
  lobby, or one on this machine for a trial) and keeps a relay the lobby offers only when `DmConfig.allows_relay` does (port 5193, or this machine; never the test relay's 5196).
- A finished benchmark run is sent (`DmApi.post_benchmark`) through the same transport to the live API's benchmark history.
- `client/tests/front.gd` fails if any of it moves: the constants are the live server's, the allow-list refuses the test server's addresses and
  lookalikes, every request the flows made stayed on the live server, and a scan of every shipped file finds no address outside `net/dm_config.gd` and no test-server path anywhere.

Test builds (the launcher's Test build switch) keep the last one published to the test channel before launch day; a new test build needs endpoints of its own first (ROADMAP: the test lane for big changes), never a change to
`net/dm_config.gd`.

## Assets

`client/assets/` holds the art, models, audio and effect data the game loads (`audio/`, `fx/`, `game/`, `slice/` with the models and textures, `ui_art/`), and the game owns them: a new or changed asset is committed here with its `.import` file. How an asset gets here (models, sounds, item icons) is ASSET_PIPELINE.md
"Into the game"; the masters of older art and sound stay in `public/`.

- **Import files.** Commit the `*.import` and `*.uid` files Godot writes next to assets and scripts, and the `*.unwrap_cache` files it writes next to models it gives lightmap UV2 (they keep UV2 identical on every machine). A new 3D texture (under `slice/models/`, `slice/art/textures/`, `fx/art/` and the other 3D folders
  listed as `tex3d` in `tools/hygiene/check.mjs`) gets a seed `.import` first (VRAM compressed, mipmaps, normal maps flagged), so even a headless first import is right; `npm run hygiene` checks them. Models import with lightmap UV2 (`importer_defaults` in `project.godot`); a model that never gets a lightmap
  (creatures, the hero) may set `meshes/light_baking=1` in its `.import`.
- Scenes and resources name assets by path, never by uid (no `.tscn` or `.tres` in the project carries a `uid://`), so a new asset's uid raises no "invalid UID" warning.
- **Generated, not committed: the crowd's baked models.** `bash client/tools/bake_crowd.sh` bakes them into the baked folder under `assets/crowd/`, which the root `.gitignore` keeps out of git (client/crowd/README.md).
- **Licensed flipbook sheets** (the sheets folder under `assets/fx/`) are not in git either (`fx/README.md` "Flipbook sheets"). `bash tools/godot/fx-sheets-sync.sh [<checkout>]` copies them from `$FX_SHEETS` (default `~/death-muffin/private/fx-sheets/`) into the checkout and fails when a listed sheet is missing; run it once in a new worktree. The publish's prepare step
  (`server/death-muffin/test-channel/prepare-rebuild.sh`) runs it too, so a publish never ships without them. A build made without the private folder (CI) has no sheets and draws the plain look.
- **The assets pack.** `res://assets` ships as its own pack, `DeathMuffin.assets.pck`, which is reused while its fingerprint is unchanged: the assets, the crowd baker's inputs, the export settings, the Godot version and the pack tools (`tools/godot/assets-fp.sh`; `server/death-muffin/README.md`).

## The Depths

The Catacomb Depths (area `depths`, an instance below the Warren, solo: DECISIONS D5) are the one area with no scene: a run's floors are generated, drawn and baked when they are entered. The rules and numbers are
the floor generator `sim/depths_floor.gd`, the quota, pacing, rosters and affixes `sim/sim_depths_rules.gd` and the rewards `rules/loot/depths_rewards.gd`; `next/depths` is the game's side:

| file | job |
|---|---|
| `dm_depths_run.gd` (`DmDepthsRun`) | the run as pure rules: seed, depth, quota, kills, stair, peak, summary, `plan_wave` |
| `dm_depths_ground.gd` (`DmDepthsGround`) | one floor as ground: the navmesh baked on a worker thread, the picture, the core's copy |
| `dm_depths.gd` (`DmDepths`; child `Depths` of `DmNextGame`, host only) | the controller: enter / descend / leave, waves, quota and rewards, chest, death, the Chronicle, the HUD's readout and map, the interactables |

**Flow.** The Warren's stair (a `DmStairMesh` the controller puts in the Warren's scene) is an interactable of the hub: `stair_clicked()` offers "start at 1 or resume at the deepest" once a deeper floor is on the Chronicle (`depths_stair_offer`, the card calls
`DmNextUiHost.enter_depths`), else starts a run on depth 1; the floor's stairs and chest join the hub's interactables while the run is on (the hub's hover, walk-and-use and prompts work as everywhere). Quota `9 + depth` (at most 30); the stair opens at the
quota, once, and the floor pays (gold, XP, 65% an item); a chest on every fifth floor; death ends the run and takes nothing (the floor stays up behind the death screen; the Depths close when the hero rises in the Chapterhouse); the exit asks twice;
a recall or waystone out ends the run; a second player joining ends it (the stair refuses a party of two). The floor's gold and XP are reported (`psync.report_floor`) and its items and the chest's come from the server's drop tape (kinds `floor` and `chest`,
DECISIONS B20): the server rolls the same event on the claim and grants its own roll. A run's kills are the ordinary kills of the core (area `depths`, level `max(12, hero) + depth`, the loot ground following the depth: `rewards.loot_area_of`) and count for the
quota; they do not count toward any area's seal.

**On the core.** The dead are bodies of the combat core made by the director (`DmWaveDirector.spawn` with `over = {area: "depths", depth, aggro: 36, leash: 90, affix_list}`; the core gives each body its own notice and chase distances,
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

**The world's side.** `DmNextWorld` keeps the Depths' rect from the start (`area_rect`; the core's bounds and the crowd's cover it when the Warren is in the world) and the builder's API for it: `open_instance("depths", true)` makes `area_at` answer "depths" there while a run stands (so the game's area, the
lighting, the music and the ambience follow the hero, and the director sees no hero in a combat area while he is below), `attach_floor / detach_floor` give the core the floor's region. The HUD reads `vm["depth"]` (depth, kills / quota, stair, chest), the minimap's floor (rooms,
doors, stairs, chest; built once per floor and kept current in place), the area line "Level N dead · elites bear K affixes" and, for the stair, the hub's hover prompt (`vm["prompt"]`).

The floor's tall props follow the moon-shadow range rule: while a run lasts `DmDepths` calls the lights builder's `update_shadow_cells` for the hero (it checks every 0.25 s, a few cells a frame, and drops the cells of freed floors from its list); nothing else calls it.

**Not yet.** The first floor of a session is not in the warm-up (the floor is made at run time, after the warm-up); a floor is not lightmapped (made at run time: the area's ambient, the moon and the real prop lights light it; the look pass decides
what it becomes); the see-through cutout is not applied to it (as in every area). A body that fell within the 4 s before the stair was taken is still dying: `remove_enemy` refuses a dead body, so it sinks on the next floor and its corpse is consumed with that floor's.

`tests/depths.gd` is the proof: the rules without a game (floors per seed, quota, pacing, rosters, the filter, the first wave, the stair opening once, the loot ground by depth); then the game scene as a player gets it, on the local mock: the Warren's seal broken, waystone travel, a click on the stair
(the hero walks to it and the run starts), floor 1 (drawn, the hero at its way in, the interactables, banner, HUD readout, map and prompts, the core's copy of the navmesh equal to the server's at 600 points, a point inside a wall moved out, paths to the stair and breaches), the dead (bodies of the core
at the depth's level, aggro 36, hunting across the rooms, hitting back, an elite's affixes), the quota and the floor's pay and report, descending (the dead and corpses gone from the core, the core's navmesh replaced, thralls recalled, a click on the open stair walking across the floor and taking it),
the chest on depth 5 (a find claimed into the bag on the server), leaving (twice to confirm, everything torn down, the record on the backend, the stair's resume offer and `enter_depths`), a second player joining, a recall, death (nothing taken), and 14 more floors (nodes flat, one floor's
triangles in the core, every bake from the worker); zero script or engine errors.

## Areas

An area is a scene built once, offline, from `client/data/slice/world.json`: the layout `client/world/world_builder.gd` (`DmWorldBuilder`) makes from it. The game loads the converted scenes and keeps the builder for the area's lights.
Twelve areas are converted: the Hollow Graves (`graves`), the three hubs (`chapterhouse`, `acre`, `alchemist_wing`) and `warren`, `ossuary`, `nave`,
`coliseum`, `sanctum`, `cloister`, `pyre`, `fen`.

```
bash tools/rebuild/build-areas.sh [area id ...]                     # import, convert; default graves
godot --headless --path client --script res://tests/areas.gd         # every converted scene equals what world_builder.gd makes from world.json (about 10 s)
```

`client/tools/build_area.gd` is the one converter for every area (`--lenient` skips models that are not in `client/assets` yet, for a smoke run; the Depths' floors are
generated at runtime and are not converted: "The Depths"). Output is deterministic, so regenerating changes nothing unless the data or the converter did:

- `client/areas/<id>.tscn`: groups `Floor` (the ground quad, the paths whose centre lies in the area, the Alchemist Wing's rugs and stains, the Fen's
  hummocks), `Walls`, `Props`, `GatherNodes`, `Decals`, `Doors`, `Lights` (the prop lights and the pool mesh),
  `Occluders`, one static `Colliders` body on the `world` physics layer (walls, prop and node obstacles, deep ponds; 3 m tall), and `Navigation`
  with a **baked** `NavigationRegion3D` for the area, one per door touching it and the two `NavigationLink3D` per door. Settings and obstruction
  rules are `world_builder._nav_mesh` / `_all_obstacles`. A door starts as `world_builder` leaves it after building: a sealed door's gate is closed
  (region and links off) and each `Doors/<id>/gate/bars` rises when it opens, which the runtime does as `set_door_open` does (region and links on,
  `gate/body/collider` off); the doors world.json lists as `open` start open (bars up and hidden, collider off, region and links on), and
  `chapter_graves`, the one hall `world_builder` builds without a gate, has none.
- `client/areas/props/<model>.tscn`: one prefab per prop or gathering-node model: the glTF instanced with the height normalisation of `DmModels.analyze`.
  Props up to 1.5 m (the height `world_builder` stops casting shadows at) also get a 70 m visibility range.
- `client/areas/common/ring.png`, `glow.png`: the two decal textures the area scenes' decals use, generated by the converter.
- `Lightmap`: the area's `LightmapGI`. Walls, gate stone and floors carry UV2, prop meshes get UV2 on import, everything solid is `gi_mode` static
  and the prop lights are `BAKE_STATIC` (positions, colours and ranges from `world.json`), so the bake takes their direct and bounced light; the area's
  ambient is baked in too, since a lightmapped surface ignores the environment's: `DmWorldBuilder.set_area`'s colour (same constants) as linear light (the Environment's ambient colour is sRGB and
  the renderer converts it; the bake takes `environment_custom_color` as it is) at the hemisphere's energy times the area's factor (`DmWorldBuilder.AREA_HEMI_K`: the Acre's 2.0 / 0.95 and the Wing's
  1.12 / 0.95; `set_area` applies them, and the moon's `AREA_MOON_K` 3.4 / 2.4 and 2.65 / 2.4, to the live lights). Every floor quad
  (the ground, the paths, the door floors) is built by hand and carries a lightmap size hint of 0.125 m a texel (`FLOOR_TEXEL`); a quad without a hint gets 64 x 64 texels whatever its size, which was 0.43 m a
  texel in the Chapterhouse, 0.84 x 0.65 m in the Graves and 0.6 m along a 40 m path (`client/addons/dm_bake/README.md` has the sizes). When
  `client/areas/<id>.lmbake` exists (a bake from `client/addons/dm_bake/README.md`) the converter points the node at it; an area without one has a `LightmapGI` with no data and is lit as "Without a bake" below says
  (all twelve areas have their bake since 2026-10-17: Helix's helper, one commit). The props stay instances of their prefab scenes: Forward+ and Mobile draw identical meshes instanced,
  so merging them would add draw calls ("Static batching is not in the areas"). Occluders: tall walls (3 m, 4 m long) and large solid
  box props (the mausoleums), shrunk so they never hide what is visible past them.

**Without a bake** (an area whose `.lmbake` is missing) an area keeps its `LightmapGI` with no data: nothing is lightmapped, so the Environment's plain-colour ambient (the Acre's and the Wing's
brighter ones included), the moon, the rim light and every prop light as a real-time omni light (no shadows; `BAKE_STATIC` lights only skip a mesh that has a lightmap) light the room: the world builder's own lighting,
without baked contact shadows, bounce and the candle light's occlusion by props. The exposure lift of each area (`DmWorldBuilder.AREA_LIFT`) is measured on the baked areas; an unbaked one is brighter or darker than a baked one by whatever the bake changes, and the cost of a room's
lights in real time (the Wing has 21, the Graves 18, the Chapterhouse 14) is not measured on a graphics card.

`client/tests/areas.gd` checks every converted area, one scene at a time (instantiate, check, free), and prints `PASS areas (N checks)` or a `FAIL areas: <id>: ...`
line per failed check. Each expected number is computed from `world.json` the way `world_builder.gd` computes it (its constants, `DmModels.prop_parts`, its
hummock ring mesh), never read from a scene:

- the ground and every path and door floor (theme texture, tint, roughness, glow; UVs anchored to the world; lightmap UV2), walls (position, size, the
  texture and tint `world_builder` shares per texture; the tints are lifted by `DmCompatAlbedo` to the albedo Compatibility makes of them, and the test measures its table against the
  textures again: "The look on Forward+"), props (the same meshes where `DmModels.prop_parts` puts them, shadow and visibility range), gathering
  nodes (models, an ore's three crystals, the herb, pool and tree stand-ins), decals, the Wing's rugs and stains, the Fen's hummocks
  and rims, prop lights (with no flame sphere) and the floor-pool mesh (the Nave's dimmer, smaller pools; its vertex colours read as sRGB, as Compatibility reads them), colliders, occluders, the two decal textures pixel for pixel; and that the scenes hold none of what the world dressing draws (no flame sphere, water plane or puddle quad), whose water rects and puddles are world.json's;
- doors: each door touching the area (and no other) with its corridor floor, and each gate's posts, lintel, bars, rails, seal and body, closed or open;
- navigation: the area's region and each door's region equal a fresh bake with `world_builder`'s settings, stop short of the walls by the agent's radius, and
  the regions and links are enabled exactly when the door is `open`; paths cross the area, join its door mouths and bend round box props; a sealed gate blocks the
  way to its corridor's far end and, once its region and links are enabled, the corridor is walkable to it;
- the lighting bake: the `LightmapGI` bakes the area's ambient as linear light at the hemisphere's energy times the area's factor (and that equals the light the builder's real-time ambient gives the area), every floor quad
  (the ground, the paths, the door floors) has a lightmap size hint of 0.125 m a texel under the 4096 limit, the Acre's and the Wing's factors that `DmGameRewards` holds equal the builder's, `set_area` scales the moon and the
  ambient by them as a ratio (so the Nightfall dimming composes); the `LightmapGI` points at `<id>.lmbake` when one exists, and a bake is stale (the test fails) when a mesh it recorded is no longer at its path in the scene;
  the test prints which areas have no bake yet;
- the whole: one scene per converted area, and every path, wall, prop, node, decal, hummock, wing-floor quad and door of `world.json` is in
  exactly the scenes it belongs to.

A headless Godot (the dummy renderer) keeps no `MultiMesh` instance transforms set one by one, so the converter writes the gate bars' and hummocks' `buffer`
directly and the test reads them from the scene file. Every mesh that is static for the bake carries a lightmap UV2 (the test checks each), or the bake stops on it.

Not the same as the builder's runtime output, on purpose: props are single instances of a prefab (not one MultiMesh per 12 m cell; MultiMesh cannot take
lightmaps); each floor is one quad (not 12 m tiles, which only limited per-object lights on Compatibility); there is no per-area light switching
(the lights stay on; the bake takes over) and no see-through cutout shader yet (`apply_occlusion`). Not in an area scene (a later world scene
owns them; `DmNextWorld`'s lights builder makes them): the dark earth beyond the walls (one quad), the environment, fog, moon and rim lights, and the world dressing ("World dressing"); the people (`npcs`) are the Chapterhouse node's (`DmHubNpcs`). A door
between two areas is in both scenes with the same id and place (nodes carry `door_id`); `DmNextWorld` keeps the first copy it loads.
