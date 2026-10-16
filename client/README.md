# The rebuilt client

The rebuilt Death Muffin client (ROADMAP "Now: the rebuild", DECISIONS B34-B42): its own Godot 4.7.2 project, next to the live game in
`godot/`, which it never changes. The live game keeps shipping from `godot/` until launch day; this project ships only to the launcher's
Test build channel until then.

- Renderer: Forward+ (`project.godot`), Compatibility only as the automatic fallback, the Mobile renderer for phones (B35). Textures also
  import in phone formats (B40).
- Its own user:// folder (`config/name` "Death Muffin (rebuild)"), so it never shares saved logins or settings with the live game.
- The combat core is a C++ GDExtension built from [native/](../native/README.md) into `bin/` (built files are not committed;
  `bin/dmcore.gdextension` is).
- Crowds are drawn from baked vertex-animation textures, one MultiMesh per creature model: [crowd/README.md](crowd/README.md).

## Set up and test

```
bash client/setup.sh                                                       # builds the core for Linux, imports, runs the smoke test
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/core_smoke.gd   # the core loads and answers
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/crowd_bake.gd    # the crowd baker and shader (bakes into a scratch folder)
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/code_load.gd      # every copied script, scene and resource loads; no copy names a per-creature class
bash client/tools/bake_crowd.sh                                                                # bakes the crowd models into client/crowd/baked (not committed)
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
  renderer, name, features, layer names and import defaults stay the client's. Input actions are registered at run time by the copied code, and
  the only `ProjectSettings` read, `application/config/version`, has a default.

### What is left out

`client/code.list` says why, section by section; its comments are the list:
- **Per-creature systems** (`enemies/`, `sim/sim_enemy|thrall|corpse|zone.gd`, `next/thralls|corpses|status|affixes|enemy_fx`,
  `game/dm_entity_views.gd`): the combat core and the crowd view replace them (native/README.md "Design").
- **Seams** (63 files today): a file outside those systems that names one of their classes or scenes: the rites, the wave director, the bosses, the
  hero body and look, the HUD's enemy reads, the event fx, auto combat input, the benchmark fight, the game scene itself. Each line names what it uses.
  They are ported to the core in the later steps of the ROADMAP's client layer, and `--port` then moves them from the list into `code.lock.json`.
- **Left out with a seam** (40 files): a file that cannot load without a seam, grouped under the seam it follows. The biggest chains: everything
  that hangs on `DmNextGame` (the front flow's entry `main/`, the area flow, gathering, party and friends, progress, and through the social window
  `game_ui/dm_game_ui.gd`), on `DmHeroBody` (the HUD shell `next/next_hud.gd`, belt, chronicle), and on `DmRiteModule`.

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
- Lightmaps are prepared, not baked: walls, gate stone and floors carry UV2, prop meshes get UV2 on import, everything solid is `gi_mode` static
  and the prop lights are `BAKE_STATIC` placeholders (positions, colours and ranges as today). Occluders: tall walls (3 m, 4 m long) and large solid
  box props (the mausoleums), shrunk so they never hide what is visible past them.

Not the same as today's runtime, on purpose: props are single instances of a prefab (not one MultiMesh per 12 m cell; MultiMesh cannot take
lightmaps); each floor is one quad (not 12 m tiles, which only limited per-object lights on Compatibility); there is no per-area light switching
(the lights stay on; the bake takes over) and no see-through cutout shader yet (`apply_occlusion`). Not in an area scene (a later world scene
owns them): the dark ground beyond the walls, the environment, fog, moon and rim lights, streaming. A door between two areas is in both scenes
with the same id and place (nodes carry `door_id`); the area loader keeps one copy.

