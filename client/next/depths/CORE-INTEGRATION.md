# The Depths

How a Depths run plays on the combat core: the floors, their dead, the quota and the chest. The node and its rules: [README.md](README.md).

The Catacomb Depths (area `depths`, an instance below the Warren, solo: DECISIONS D5) are the one area with no scene: a run's floors are generated, drawn and baked when they are entered. The rules and numbers are
the floor generator `sim/depths_floor.gd`, the quota, pacing, rosters and affixes `sim/sim_depths_rules.gd` and the rewards `rules/loot/depths_rewards.gd`; `next/depths` is the game's side,
in three files (the run's rules, a floor as ground, the controller): [README.md](README.md).

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

**A floor, in order** (`DmDepths._load_floor`; measured on the VPS, headless, one run of `tests/depths.gd`): the floor is generated on a worker thread (`WorkerThreadPool`; `DmDepthsRun.generate` is pure and reads only data `DmDbWarm` loaded in loading ([Threads](../../core/THREADING.md)), about 16 ms there, off the main thread);
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
