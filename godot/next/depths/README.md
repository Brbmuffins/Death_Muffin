# godot/next/depths: the Catacomb Depths on the rebuild

The procedural descent, solo (DECISIONS.md D5). Enter from the Warren's stair, descend floor by floor, chests every fifth depth, death ends
the run and takes nothing, back to the hub. Rules and numbers: `sim/depths_floor.gd`, `sim/sim_depths_rules.gd`, `rules/loot/depths_rewards.gd`.

| file | job |
|---|---|
| `dm_depths_run.gd` (`DmDepthsRun`, RefCounted) | the run as pure rules: seed, depth, quota, kills, stair, peak, summary, `plan_wave` (the sim's `update_depths` + `spawn_at_breach`: orders, no nodes) |
| `dm_depths_ground.gd` (`DmDepthsGround`) | one floor as ground: the picture (`DmWorldBuilder.build_depths_floor`, the existing look), the floor's navmesh (one `NavigationRegion3D`, mesh swapped per floor, ~6 ms bake), wall / prop colliders |
| `dm_depths.gd` (`DmDepths`, child `Depths` of `DmNextGame`, host) | the controller: enter / descend / leave, the floor's waves, quota + rewards, chest, death, chronicle, HUD / minimap state, interactables |

## Flow
- The hub emits `interacted(it)` for `stair` (Warren), `depths_down`, `depths_up`, `depths_chest`; `DmDepths` listens. A floor's own stair / way up / chest are
  added to `chapterhouse.interactables` (area `depths`) while the run is on, so the hub's hover, click-to-walk and prompts work; its `interact_prompt` asks `depths.prompt(it)`.
- `stair_clicked()`: with a deeper floor on the chronicle (`peak.depth` >= 2) it emits `depths_stair_offer {deepest}` (the existing two-button card; `DmNextUiHost.enter_depths(depth)`
  starts the run), else `enter(1)`. `enter(depth, seed = -1)` is awaitable (returns when the floor stands).
- Floor = `DmDepthsFloor.generate_floor(floor_seed(run seed, depth), depth, 5)`; quota `9 + depth` (<= 30); stair opens at the quota (once) and the floor pays.
- Enemies: `DmWaveDirector.spawn(def, pos, [hero], elite, over)` with `over = {area: "depths", depth, aggro: 36, leash: 90, affixes}`: level `max(12, hero) + depth`
  (`DmEnemyStats.area_level`), hp / damage scaling and Wave Speed at full ramp as the director does; meta `dm_area = "depths"`. Spawned from the floor's breaches
  (not the hero's room, >= 9 m, nearest hops, up to 3 breaches), first wave 8 after 1.4 s, then `depth_wave_size` every `depth_wave_gap_s`, only as many as the quota
  still needs, <= 24 alive. Rosters by band (`depth_roster`: 1 / 5 / 10 / 15, base kinds fade 40% per band, floor 3), elite chance `0.06 + difficulty + 0.5%/depth` (<= +14%).
- Rewards: kills go through `DmSessionRewards` like any kill; `rewards.loot_area_of` (new hook) maps `depths` to the ground matching the depth (ossuary / coliseum / sanctum
  / cloister / pyre / fen at 1 / 5 / 10 / 15 / 20 / 30). A floor clear pays gold + XP (+ 65% an item); a chest pays gold, XP and 3+ drops (gear first, a rune chance) fanned out
  (`rewards.drop_items_for`, `progress.grant_xp`); both are reported on the solo path (`psync.report_floor`: session reports drop floors).
- Death: `hero_died` ends the run (`over`: stairs gone, no more waves) but the floor stays up behind the death screen; on `hero_respawned` the Depths close and the summary
  toast is told ("The descent ends at depth N · K slain · F floors cleared. What you looted is yours."). Gold, bag, gear, XP are untouched.
- Leaving: the way up asks twice (5 s), recall / waystone out ends the run (`recalled`), a second player joining ends it (`party`); the hero returns to the Warren's stair.
- Record: `DmChronicle` (`peak.depth`, `depths.runs/floors/chests`, `kills`, `kills.depths`) loaded from / flushed to the backend (`get_chronicle` / `add_chronicle`) on every end,
  every 30 s while a run is on, and in `DmNextGame.flush_all`.
- HUD: `vm["depth"]` (depth, kills / need, stair, chest), the minimap's `depths` floor (rooms, doors, stairs, chest), the area line "Level N dead · elites bear K affixes".

## Shared-file edits (all backward compatible)
`next_game.gd` (creates `Depths`, `flush_all`), `spawn/dm_wave_director.gd` (`spawn(..., over)`, `clear_area(area)`; the empty-hero clear is now `clear_area(area_id)` so it no longer
sinks another ground's enemies), `rewards/dm_session_rewards.gd` (`loot_area_of`, `drop_items_for`), `progress/dm_next_progress.gd` (`grant_xp`), `chapterhouse/dm_chapterhouse.gd`
(`interact_prompt`), `hud/dm_next_hud_vm.gd`, `hud/dm_next_ui_host.gd` (`enter_depths`), `enemies/states/dm_state_burrow.gd` (a tunnel stopped by a wall for 0.8 s surfaces:
a Barrow Ghoul spawned behind a Depths wall waited underground forever).

## Navigation / builder notes
The builder bakes a sample floor into `area:depths` and keeps its wall / prop colliders in the shared `Colliders` body: `DmDepthsGround.setup` frees those (inside the Depths rect) and the
builder's `depths_open` is never set, so the floor's own region is the only walkable ground there. The builder draws generated walls without colliders: the ground adds boxes / cylinders
from `DmDepthsFloor.floor_obstacles` (the sim's own). `build_depths_floor` names the new root "DepthsFloor" only if the old one is gone (queue_free): ask `builder._depths_floor_root`.

## Measured (this VPS, shared, headless; `tests/next_depths/run.gd` prints a PERF line)
- Floor build on the main thread: ~18 ms mean, ~28 ms worst (generate ~19 ms is inside `DmDepthsRun`; draw ~6 ms, colliders ~1 ms, bake 6-12 ms). The first floor costs the same (kinds are warmed:
  loading warms the base band, every floor warms the next two depths' kinds one per frame). The navigation server then merges the region over ~15 physics frames (the hero waits on the stair).
- Frame with 24 hunters on a floor: median ~8.5 ms headless (vs the rebuilt Graves' 25-chaser ~5-6 ms process+physics).
- 14 floors with no enemies: nodes flat (5630-5670 across floors), orphans constant, memory flat (496 MB). 10 floors of real play: +40-60 nodes, +15 MB (new enemy kinds' models cached as bands
  open, bounded by 24 kinds), no orphans added.

## Tests / known gaps
Suite: `tests/next_depths/run.gd`.

- Elite **affixes** are not enacted: `DmEnemy` has no affix behaviour yet, so an elite is just the elite multipliers; the depth's extra-affix count rides along as meta `dm_affixes`.
- Party play: a run needs a solo session (`can_enter` refuses with 2+ players); party step-out / step-back is not built (DECISIONS.md D5).
- Breach "burrow" and other kinds with their own AI behave as in the Graves on the floor's navmesh; no Depths-specific sight blockers for ranged kinds (walls block movement, not sight).
- The Warren must be open (the areas track) to reach the stair in play; the tests walk to it.
- Minimap / HUD pieces exist, the stair card is the existing `DmDepthsStairPrompt`; no new art or audio was made (`gate`, `chestOpen`, `levelUp`, `click`, `error` are existing sounds).
- Stairs look like stairs: the Warren's stair, a floor's way down and its way up are `DmStairMesh` (`world/dm_stair_mesh.gd`): a stone frame round a well with five steps (down: low and darker with depth; up: rising), built from primitives as one cached vertex-coloured mesh per direction plus a glowing quad that `DmWorldBuilder.set_depths_stair_open` drives. The chest is still a code-built box.
