# The client's layout and the game scene

How the client project is organised and how the game scene runs on the combat core. The scene's nodes and seams: [README.md](README.md); the client's index: [client/README.md](../README.md).

## The project in brief

- Renderer: Forward+ (`project.godot`), Compatibility only as the automatic fallback, the Mobile renderer for phones (B35). Textures also
  import in phone formats (B40).
- Its `user://` folder is named after `config/name`, "Death Muffin (rebuild)" (KNOWN-GAPS "Leftovers from the web era").
- It plays on the **live server** and never reaches the test server ([The API rule](../net/README.md)).
- The combat core is a C++ GDExtension built from [native/](../../native/README.md) into `bin/` (built files are not committed;
  `bin/dmcore.gdextension` is).
- Crowds are drawn from baked vertex-animation textures, one MultiMesh per creature model and level of detail, driven by the combat core through `CrowdView`:
  [crowd/README.md](../crowd/README.md).

## How the project is organised

The game owns all its files. `client/` is one Godot project: a script, scene, data file or asset is changed here and committed here, and nothing is copied or synced into it from another folder. The old game's source is only the tag
`archive/old-game`. Class names are `Dm*`, and the game's content has one source of truth, in `data/` and `rules/`. The system guides ([client/README.md](../README.md)) say how each system works; this is where things live:

| Folder | What lives there |
|---|---|
| `main/` | the boot (`main.tscn`, `DmMain`): launch arguments, the hand-over from the front flow to the game, the `Packs` autoload, the camera rig, the F3 overlay, the crash watch and the QA driver |
| `front/` | login, register, the online gate, character select |
| `net/`, `net/relay/` | the API client (`DmApi`, one function per route), `DmConfig` (the endpoints), the HTTP transport and the offline mock backend; the lobby client, the relay peer and the UDP lane |
| `session/` | `DmSession` and `DmSessionBody`: host or join, the hero bodies, move intents |
| `core/`, `crowd/` | the combat core's host (`DmCoreHost`) and the adapters the rites call; the crowd that draws the core's creatures ([crowd/README.md](../crowd/README.md)) |
| `next/` | the game scene (`next_game.tscn`, `DmNextGame`) and its systems, one folder and README each ([next/README.md](README.md)) |
| `rules/`, `data/`, `sim/` | the game's rules in GDScript (the server's rules and these are held together by parity fixtures: `server/rules/README.md`), its content as JSON read through `DmDb` ([data/README.md](../data/README.md)), and the shared simulation classes: the boss brains, the Depths' floors ([sim/README.md](../sim/README.md)) |
| `game/`, `game_ui/`, `ui/`, `loot_view/` | the shared in-world classes (creature and avatar views, the gear look, settings, the graphics preset), the UI host `DmGameUi` with its panels' glue, the HUD, panels, widgets and theme, and the personal loot view |
| `world/`, `world_fx/`, `areas/` | the lights-only world builder, models and animator; the world dressing; the converted area scenes with their lighting bakes |
| `fx/`, `audio/` | the `Vfx` and `AudioDirector` autoloads |
| `assets/` | art, models, audio and effect data ([Assets](../tools/ASSETS.md)) |
| `dev/`, `tools/`, `addons/`, `tests/`, `bin/` | the dev entry; scripts for bakes, probes and measurements; the lighting-bake editor plugin; the suites; the combat core's built libraries (`bin/dmcore.gdextension` is committed, the libraries are not) |

**No per-creature code.** Enemies, thralls, corpses and affixes run in the combat core and are drawn by the crowd ([native/README.md](../../native/README.md), [crowd/README.md](../crowd/README.md)); an enemy is an id everywhere, and `tests/code_load.gd` fails when a file names a class or path of the
old per-creature systems. Only heroes and bosses are nodes with skeletons; their statuses are `DmStatusSet`'s (`next/status/`), an enemy's or a thrall's are the core's.

**`project.godot`** holds the autoloads (`Packs`, which loads the assets pack, `AudioDirector` and `Vfx`; the QA tools are started by the boot and have no autoload, [Screenshots for proposals](../main/SCREENSHOTS.md)), the display and theme settings the UI layout assumes (a 1600x900 viewport,
`canvas_items` stretch, `dm_theme.tres`), 60 Hz physics (at most 3 steps per frame, physics interpolation), the renderer (Forward+, Mobile for phones, desktop and phone texture formats), the main scene (the boot, `main/main.tscn`), the physics layer names (world, player, enemy, thrall), the
import default that gives models lightmap UV2 and the global shader parameter `dm_lift_inv` ([The look on Forward+](look/README.md)). It is an input of the art pack's fingerprint (`tools/godot/assets-fp.sh`): a change there, even a comment, makes every player download the art again. Input actions are registered at run time
(`DmNextInput.ensure_actions()`), and the only `ProjectSettings` read, `application/config/version`, has a default.

## The game scene and the dev entry

`next/next_game.tscn` (`DmNextGame`) is the game on the combat core: **the whole world** (every area but the Depths, whose floors are made when a run starts, [The Depths](depths/CORE-INTEGRATION.md); the hero starts and gets up in the Chapterhouse),
with the character the front flow chose on the live server ([front/README.md](../front/README.md)) or, from `dev/dm_dev_entry.tscn`, a dev character on the local mock backend in the Hollow Graves alone (a quick fight; `-- --dev-offline --class=2` on the normal boot enters the whole world instead). **The dev entry reaches
no server**: the backend is `DmOffline.make_mock` (accounts in this project's own `user://dm_dev_offline_db.json`) and has no base url. `DmNextGame.start` refuses any api whose base url is not the live API's or empty (the mock): [The API rule](../net/README.md).

```
bash tools/check/prep.sh                               # once per checkout: the core, the import, the crowd's baked models (without them nothing is drawn)
/home/ubuntu/tools/godot/godot --path client            # the boot: login and character select on the live server, then the game (client/front/README.md)
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
when the kills in the area before it reach its count (the banner, the gate rises, the navmesh joins; a party's guest sees the host's seals, [Co-op on the core](party/CORE-NETWORK.md)), runs waystone travel and the recall home (T),
opens the stations' panels and animates the people; the **director** (`next/spawn/dm_wave_director.gd`) spawns through `core_host.spawn_enemy` with the affix
roll (`core/dm_affix_roll.gd`), counting from the core; the **hero** (`next/hero/dm_hero_body.gd`) takes the enemies' blows from `EV_TARGET_HIT` with the enemy's id as the source, and their chills, roots and drags (the Hag's, the Wisp's, the Sexton's chain) from `EV_TARGET_EFFECT` (`DmNextGame._on_target_effect` hands each to `DmHeroBody.dm_enemy_effect` when the tick's events are dispatched; a hero the blow killed refuses it; a boss's chill or root is the boss host's);
**input** (`next/next_input.gd`) picks the hovered enemy at 10 Hz by asking the core for the bodies within 4.5 m of where the cursor's ray crosses the plane 0.9 m above the ground and taking the one whose chest is nearest the cursor on screen within 46 px; **enemy effects** (`next/enemy_fx/dm_enemy_fx.gd`) play the telegraphs, strikes (timed from the
wind-up), deaths, voices, dust clouds and burning ground and the affixes' bell, meal and burst from the host's signals, through the same router and the `Vfx` and `AudioDirector` autoloads.

Co-op and the Social window ([Co-op on the core](party/CORE-NETWORK.md)), value on the server ([Value on the server](rewards/AUTHORITY.md)), the HUD and panels ([The HUD on the core](hud/CORE-INTEGRATION.md)), the Reaper ([The Gravecaller's rites](rites/CORE-INTEGRATION.md)), gathering with the Acre ([Gathering and the Acre](gathering/README.md#gathering-and-the-acre)), the Depths ([The Depths](depths/CORE-INTEGRATION.md)), Grave Surges ([Grave Surges](areas/SURGES.md))
and the graphics governor ([Graphics presets](perf/README.md#graphics-presets)) are all in the game scene. The waves follow the heroes from area to area: the director moves to the combat area a hero stands in, and the ground left behind is cleared at once (its living bodies sent away through the core, no death or corpse),
as is one nobody has stood in for 15 s. In a party apart every combat area a member stands in has waves of its own, around that member, under the one global cap of 72 (`next/spawn/README.md` "Grounds"). Easy auto combat opens from Settings ([The benchmark](perf/BENCHMARK.md)). `tests/world.gd` plays the whole world: seals, gates, walking from the Chapterhouse into the Warren, waystones, the recall, the waves following the hero. How the core behaves is
`native/README.md` "Design".
