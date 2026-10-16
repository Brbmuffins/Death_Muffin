# The rebuilt client

The rebuilt Death Muffin client (ROADMAP "Now: the rebuild", DECISIONS B34-B42): its own Godot 4.7.2 project, next to the live game in
`godot/`, which it never changes. The live game keeps shipping from `godot/` until launch day; this project ships only to the launcher's
Test build channel until then.

- Renderer: Forward+ (`project.godot`), Compatibility only as the automatic fallback, the Mobile renderer for phones (B35). Textures also
  import in phone formats (B40).
- Its own user:// folder (`config/name` "Death Muffin (rebuild)"), so it never shares saved logins or settings with the live game.
- The combat core is a C++ GDExtension built from [native/](../native/README.md) into `bin/` (built files are not committed;
  `bin/dmcore.gdextension` is).
- Crowds are drawn from baked vertex-animation textures, one MultiMesh per creature model and level of detail, driven by the combat core through `CrowdView`:
  [crowd/README.md](crowd/README.md).

## Set up and test

```
bash client/setup.sh                                                       # builds the core for Linux, imports, runs the smoke test
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/core_smoke.gd   # the core loads and answers
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/crowd_bake.gd    # the crowd baker and shader (bakes into a scratch folder)
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/code_load.gd      # every copied script, scene and resource loads; no copy names a per-creature class
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/crowd_view.gd    # the crowd's views against today's view code, and a Full Party (bakes into a scratch folder)
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/game_scene.gd     # the game scene on the core: 60 s of an offline run in the Graves (bakes into a scratch folder; add --fixed-fps 60 before --path to run it faster than real time)
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/rites.gd          # the Gravecaller's rites on the core: all 25 necromancer rites against today's rules, a fight (bakes into a scratch folder; 90 s of game time, --fixed-fps 60 makes it faster)
bash client/tools/bake_crowd.sh                                                                # bakes the crowd models (the roster's robber and hound, the thralls) into client/crowd/baked (not committed)
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
  renderer, name, features, main scene (the dev entry), layer names and import defaults stay the client's. Input actions are registered at run time by the copied code, and
  the only `ProjectSettings` read, `application/config/version`, has a default.

### What is left out

`client/code.list` says why, section by section; its comments are the list:
- **Per-creature systems** (`enemies/`, `sim/sim_enemy|thrall|corpse|zone.gd`, `next/thralls|corpses|affixes`, `game/dm_entity_views.gd`): the combat core and the crowd view
  replace them (native/README.md "Design").
- **Seams** (55 files at the start): a file outside those systems that names one of their classes or scenes: the rites, the bosses, the HUD's enemy reads, auto combat input, the benchmark
  fight. Each line names what it uses. They are ported to the core in the later steps of the ROADMAP's client layer, and `--port` then moves them from the list into `code.lock.json`.
  Ported already: the game scene, the director, the hero body and look, the input, the enemy fx, the avatar and the event fx; and the Gravecaller's rites (the caster, the module base, the legends, the
  registry, 24 of the necromancer's 25 rites, the rite fx, the combat input; "The Gravecaller's rites").
- **Left out with a seam**: a file that cannot load without a seam, grouped under the seam it follows. The biggest chains now: `DmReaperRites` (the Reaper's nine rites) and the party
  (`DmNextFriends` reads the game scene's `party`: the friends and party panes, the social window, `game_ui/dm_game_ui.gd` and the front flow's entry `main/`).
  Freed by the game scene's port and copied again: `next/status` (`DmStatusSet`, for the status sets of heroes and bosses only), the HUD shell `next/next_hud.gd`,
  the chronicle, the event fx's telegraph and boss halves, the area flow, gathering and the joiner. Freed by the rites' ports: the hotbar (`dm_rite_hotbar.gd`), Veil Step, the belt and the progress node.

## The game scene and the dev entry

`next/next_game.tscn` (`DmNextGame`, a port of today's) is the game on the combat core: an **offline solo run in the Hollow Graves**. `dev/dm_dev_entry.tscn` is the
project's main scene until the front flow arrives (ROADMAP: login and character select): it starts the scene with a dev character on the local mock backend, the way
today's `--dev-offline --class=2` does. **Nothing here reaches a server**: the backend is `DmOffline.make_mock` (accounts in this project's own `user://dm_dev_offline_db.json`),
and `DmNextGame.start` refuses any api that has a base url. The copied net config still points at the live API; no request is ever made from the dev entry.

```
bash client/setup.sh                                   # once per checkout: builds the core, imports
bash client/tools/bake_crowd.sh                        # once: bakes the robber, the hound and the thralls (without them nothing is drawn; the other defs borrow these)
/home/ubuntu/tools/godot/godot --path client            # the dev entry: the Gravecaller at level 10, the minimal HUD, waves. He fights with the rites (controls below)
/home/ubuntu/tools/godot/godot --path client -- --class=1 --seed=7 --crowd=70      # options after `--`: --class=N --level=N (default 10) --seed=N --no-waves --crowd=N (a first wave of N bodies 6 to 12 m around the hero) --baked=<dir> --shot=<png> [--shot-after=<game s>] (rendered runs only)
```

**Controls of the dev entry** (today's input and hotbar code): **LMB** on the ground walks there, on an enemy walks into range and casts the primary (Bone Needle; hold to repeat, Shift+LMB casts in place);
**1-4** are the kit's default loadout (Marrow Spear, Exhume, Miasma, Black Litany; hold a key to repeat), **RMB** is Corpse Explosion, **R** the signature from level 10 (Command: Rend), **WASD** walks, the wheel
zooms. The other rites cast through `DmNextInput.cast_at(slot, aim, enemy_id, true)` or the caster's `request_cast(rite, aim)` until the loadout panel comes with the full HUD. `--level=N` sets the level the mock
character is made at (R needs 10, Bone Mantle 12, Bone Storm 14; all rites unlock by 14).

**`DmCoreHost`** (`core/dm_core_host.gd`, the scene's `Core` node) is the one owner of the `DmCore` and the `CrowdView`. It loads the data (`DmCoreData.load_all`: this project's `data/`; the
three constants files of the creature systems are not here, so the core keeps its compiled-in defaults, which `core_thralls` checks against the live files), seeds the core and
gives it the area's navigation map and bounds, and registers each hero body as an external (position and alive flag written before every step). Its tick runs at
`process_physics_priority` 100: after the session (which moves the hero bodies) and the director (which spawns), before the crowd's own 1000. A tick is `core.step`, `CrowdView.sync()`, then
`core.take_events()` once, decoded in order into one typed signal per event kind (`enemy_spawned`, `enemy_state`, `enemy_damaged`, `enemy_died`, `enemy_attack`, `telegraph`,
`target_hit`, `zone*`, `corpse_*`, `thrall_*`, `status_*`, `affix_moment`; `core/dm_core_events.gd` has the numbers). Systems connect to the signals; nothing polls per creature, and
**no node and no script exists per creature**: an enemy is an id (an int) everywhere, and `enemies_in_radius`, `enemy_position`, `damage` and `apply_status` are thin queries on the core.
`CrowdView._process` draws the rendered frames with `Engine.get_physics_interpolation_fraction()`.

The pieces around it (all ports, `code.list` "Ported"): the **world** (`next/next_world.gd`) loads `areas/graves.tscn` with the same small API as today's world object (`area_at`, the
navigation helpers, `spawn_point`) and keeps a `DmWorldBuilder` for the area's lights only; the **director** (`next/spawn/dm_wave_director.gd`) spawns through `core_host.spawn_enemy` with the affix
roll of today (`core/dm_affix_roll.gd`), counting from the core; the **hero** (`next/hero/dm_hero_body.gd`) takes the enemies' blows from `EV_TARGET_HIT` with the enemy's id as the source;
**input** (`next/next_input.gd`) picks the hovered enemy by asking the core for the bodies near the cursor's ray; **enemy effects** (`next/enemy_fx/dm_enemy_fx.gd`) play the telegraphs, strikes (timed from the
wind-up), deaths, voices, dust clouds and the affixes' bell, meal and burst from the host's signals, through the same router and the `Vfx` and `AudioDirector` autoloads.

Off in this step, each until its ROADMAP item: the front flow and `main/`, bosses, party and co-op, gathering, the Chapterhouse
(the hero starts and gets up at the Graves' door), the Depths, rewards and progression (no XP, loot or saves; `DmNextGame.rite_hit` carries every blow of a rite for them), the full HUD (only the orbs, area name and death veil;
so no loadout panel, no floating damage numbers), Easy auto combat, the Reaper's rites, the graphics governor, Grave Surges. `native/README.md` "Differences from today's game" lists what behaves differently from today.

## The Gravecaller's rites

Today's rites (`godot/next/rites`, DECISIONS B42) run in this project as GDScript and call the core synchronously: a rite damages with `core.damage(id, amount, source)` and reads `{dealt, killed}` at once, so Wailing Skull's
extra leap on a kill, Bone Prison skipping the dead, and the Litany's loops work as they do today. `next/rites/` has the necromancer's 25 rites (the Reaper's nine wait for the Reaper: the registry does not list them
and a cast of one is refused `unavailable`); 24 are ports, Veil Step is a copy. `DmNextGame.attach_caster` gives the hero his `Rites` node (a `DmRiteCaster`, the game scene is its `DmRiteWorld`) and `DmRiteHotbar.wire`
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
(table-driven against the copied rules code), the refusals, the synchronous-kill cases, the kit's hotbar and the click-to-attack chase, and plays a fight; `native/README.md` "Differences from today's game" lists what differs.

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

```
bash tools/rebuild/build-areas.sh [area id ...]                     # sync assets, import, convert; default graves
godot --headless --path client --script res://tests/area_graves.gd   # the Graves scene equals what world_builder.gd makes from world.json
```

`client/tools/build_area.gd` is the one converter for every area (`--lenient` skips models not synced yet, for a smoke run; the Depths' floors are
generated at runtime and are not converted). Output is deterministic, so regenerating changes nothing unless the data or the converter did:

- `client/areas/<id>.tscn`: groups `Floor`, `Walls`, `Props`, `GatherNodes`, `Decals`, `Water`, `Doors`, `Lights`, `Occluders`, one static `Colliders` body
  on the `world` physics layer (walls, prop and node obstacles, deep ponds; 3 m tall as today), and `Navigation` with a **baked** `NavigationRegion3D`
  for the area, one per door touching it (starts enabled only for the always-open door) and the two `NavigationLink3D` per door. Settings and obstruction
  rules are `world_builder._nav_mesh` / `_all_obstacles`. Gates start closed: each `Doors/<id>/gate/bars` rises when the door opens, and the
  runtime enables the door's region and links and disables `gate/body/collider`, as `set_door_open` does.
- `client/areas/props/<model>.tscn`: one prefab per prop or gathering-node model: the glTF instanced with the height normalisation of `DmModels.analyze`.
  Props up to 1.5 m (the height `world_builder` stops casting shadows at) also get a 70 m visibility range.
- `client/areas/common/ring.png`, `glow.png`: the two decal textures the live game paints at start-up.
- `Lightmap`: the area's `LightmapGI`. Walls, gate stone and floors carry UV2, prop meshes get UV2 on import, everything solid is `gi_mode` static
  and the prop lights are `BAKE_STATIC` (positions, colours and ranges as today), so the bake takes their direct and bounced light; the area's
  ambient (`DmWorldBuilder.set_area`'s colour, same constants) is baked in too, since a lightmapped surface ignores the environment's. When
  `client/areas/<id>.lmbake` exists (a bake from `client/addons/dm_bake/README.md`) the converter points the node at it. Occluders: tall walls (3 m, 4 m long) and large solid
  box props (the mausoleums), shrunk so they never hide what is visible past them.

Not the same as today's runtime, on purpose: props are single instances of a prefab (not one MultiMesh per 12 m cell; MultiMesh cannot take
lightmaps); each floor is one quad (not 12 m tiles, which only limited per-object lights on Compatibility); there is no per-area light switching
(the lights stay on; the bake takes over) and no see-through cutout shader yet (`apply_occlusion`). Not in an area scene (a later world scene
owns them): the dark ground beyond the walls, the environment, fog, moon and rim lights, streaming. A door between two areas is in both scenes
with the same id and place (nodes carry `door_id`); the area loader keeps one copy.

