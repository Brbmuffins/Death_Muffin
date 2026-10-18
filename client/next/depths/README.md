# client/next/depths: the Catacomb Depths

The procedural descent, solo (DECISIONS.md D5). Enter from the Warren's stair, descend floor by floor, chests every fifth depth, death ends
the run and takes nothing, back to the hub. Rules and numbers: `client/sim/depths_floor.gd`, `client/sim/sim_depths_rules.gd`, `client/rules/loot/depths_rewards.gd`.
The flow of a run (the stair's offer, the quota, what a floor pays, death, leaving), how a floor is generated on a worker thread, baked, swapped in and handed to the combat core, how its dead are core bodies and what the world and the HUD do with it: client/README.md "The Depths".

| file | job |
|---|---|
| `dm_depths_run.gd` (`DmDepthsRun`, RefCounted) | the run as pure rules: seed, depth, quota, kills, stair, peak, summary, `plan_wave` (the sim's `update_depths` + `spawn_at_breach`: orders, no nodes); a floor can be handed in already generated |
| `dm_depths_ground.gd` (`DmDepthsGround`) | one floor as ground: the picture (`DmWorldBuilder.build_depths_floor`), the floor's navmesh baked on a worker thread and its copy for the core; no physics colliders |
| `dm_depths.gd` (`DmDepths`, child `Depths` of `DmNextGame`, host) | the controller: enter / descend / leave, the floor's waves, quota + rewards, chest, death, chronicle, HUD / minimap state, interactables |

## Details
- The hub emits `interacted(it)` for `stair` (Warren), `depths_down`, `depths_up`, `depths_chest`; `DmDepths` listens. A floor's own stair / way up / chest are
  added to `chapterhouse.interactables` (area `depths`) while the run is on, so the hub's hover, click-to-walk and prompts work; its `interact_prompt` asks `depths.prompt(it)`.
- `stair_clicked()`: with a deeper floor on the chronicle (`peak.depth` >= 2) it emits `depths_stair_offer {deepest}` (the two-button card `DmDepthsStairPrompt`; `DmNextUiHost.enter_depths(depth)`
  starts the run), else `enter(1)`. `enter(depth, seed = -1)` is awaitable (returns when the floor stands).
- Floor = `DmDepthsFloor.generate_floor(floor_seed(run seed, depth), depth, 5)` (a chest on every fifth); the stair opens at the quota, once.
- Waves: first wave 8 after 1.4 s, then `depth_wave_size` every `depth_wave_gap_s`, only as many as the quota still needs, <= 24 alive, from the floor's breaches (not the hero's room, >= 9 m, nearest hops, up to 3 breaches).
  Rosters by band (`depth_roster`: 1 / 5 / 10 / 15, base kinds fade 40% per band, floor 3), elite chance `0.06 + difficulty + 0.5%/depth` (<= +14%);
  an elite bears the omen's affix or its rolled one plus one more every 5 depths, at most 3 extra (`pick_extra_affixes`).
- Loot: `rewards.loot_area_of` maps `depths` to the ground matching the depth (ossuary / coliseum / sanctum
  / cloister / pyre / fen at 1 / 5 / 10 / 15 / 20 / 30). A chest pays gold, XP and 3+ drops (gear first, a rune chance) fanned out in front of it
  (`rewards.drop_items_for`, `progress.grant_xp`); both a floor's and the chest's gold and XP are reported on the solo path (`psync.report_floor`: session reports drop floors).
- Death: on `hero_respawned` the Depths close and the summary toast is told ("The descent ends at depth N · K slain · F floors cleared. What you looted is yours."). Gold, bag, gear, XP are untouched.
- Record: `DmChronicle` (`peak.depth`, `depths.runs/floors/chests`, `kills`, `kills.depths`) loaded from / flushed to the backend (`get_chronicle` / `add_chronicle`) on every end,
  every 30 s while a run is on, and in `DmNextGame.flush_all`.
- HUD: `vm["depth"]` (depth, kills / need, stair, chest), the minimap's `depths` floor (rooms, doors, stairs, chest), the area line "Level N dead · elites bear K affixes".
- Stairs look like stairs: the Warren's stair, a floor's way down and its way up are `DmStairMesh` (`client/world/dm_stair_mesh.gd`): a stone frame round a well with five steps (down: low and darker with depth; up: rising), built from primitives as one cached
  vertex-coloured mesh per direction plus a glowing quad that `DmWorldBuilder.set_depths_stair_open` drives. The chest is still a code-built box.

## Tests
`client/tests/depths.gd` plays the whole run on the local mock (client/README.md "The Depths"). The rules without a game (floors per seed, quota, pacing, rosters) are its first part.

## Known gaps
- Party play: a run needs a solo session (`can_enter` refuses with 2+ players); party step-out / step-back is not built (DECISIONS.md D5).
- No Depths-specific sight blockers for ranged kinds: walls block movement, not sight (the core has no collision world; only the Gargoyle's dive and the Sexton's chain look for a clear line, native/README.md "The kinds of the other areas").
- The Warren must be open to reach the stair in play; the tests walk to it.
- The first floor of a session is not in the warm-up, a floor is not lightmapped and the see-through cutout is not applied to it (client/README.md "The Depths", "Not yet").
- The Depths' counsel tips (`depths_*`) are not raised (client/README.md "Tips and onboarding"). No new art or audio was made for the Depths (`gate`, `chestOpen`, `levelUp`, `click`, `error` are existing sounds).
