# Crowd drawing (vertex-animation textures)

Enemies and thralls are drawn in bulk: one MultiMesh per creature model and level of detail, every instance playing a clip baked into
textures (ROADMAP "Now: the rebuild", [native/README.md](../../native/README.md) "Design"). The hero and bosses keep full skeletons.
The combat core writes one buffer per frame; the GPU does the rest in the vertex shader.

## Pieces

- `client/crowd/crowd_baker.gd` (`CrowdBaker`): the baker. Loads a model's GLB straight from the asset folder (`godot/assets/slice/models/` until the
  client has its own `assets/`, then `client/assets/`; it picks whichever exists), poses the skeleton for every frame of every clip the game
  plays, skins every vertex on the CPU, and writes the files below. Headless, a few seconds per model.
- `client/crowd/crowd_vat.gdshader`: the material. `client/crowd/crowd_vat_data.gd` (`CrowdVatData`): what a baked model loads as, plus the helpers that
  build its material and MultiMesh and pack the per-instance data.
- `bash client/tools/bake_crowd.sh [enemy id or model slug ...]` (default: `robber hound` and the thralls the rites raise: `skeleton_thrall thrall_legionnaire thrall_sentinel thrall_plague carrion_sac bone_colossus`, 7 to 20 MB each): runs the baker at low priority.
  Output: `client/assets/crowd/baked/<model slug>/`.
- `client/tests/crowd_bake.gd`: the headless proof (below). `client/tests/crowd_smoke.gd`: the one rendered look (software GL).
- `client/crowd/crowd_view.gd` (`CrowdView`): the node that draws the combat core's creatures, with `client/crowd/crowd_looks.json` (which model each enemy
  def and thrall kind is drawn with) and the C++ `DmCrowd` behind it: "Driving the crowd". Proof: `client/tests/crowd_view.gd`; look: `client/tests/crowd_view_smoke.gd`.

Baked files are **generated, not committed** (`client/assets/crowd/baked/` is ignored): the robber is 11.5 MB, so the baker belongs to the build, not the
repository. Run `bash client/tools/bake_crowd.sh` before a publish; the test bakes into a scratch folder by itself.

## What is baked

The creature exactly as `godot/game/dm_creature.gd` puts it in the world: the height normalisation of `godot/world/dm_models.gd` (`analyze`), the row's yaw
(`godot/game/view_models.json`), the clip preparation of `_prep_anims` and `_prep_clips` (loops, walk and run drift, Hip pinned). Feet at the origin, +Z
forward, before the enemy's own `scale`. Clips are the ones `DmCreature` can play: idle, walk, run, attack and its variants, cast, hurt, death, dig, ...
(its `FALLBACK` table, stored as `roles`: role -> clips). Per model one `model.tres` (clip table, roles, texture paths, bounds, and what the views play the
clips with: per clip the whole source length, the second the blow lands and, for a death, the second the body comes to rest; the model row's stride),
`pos.res`, `nrm.res` and `mesh_lod<N>.res`.

**Unrigged models** (props today's creature shader animates: the moth, the bat, the choir wraith, the seraph; `godot/game/dm_creature_mat.gd` wings) have no
skeleton to pose. They bake one looping clip, `fly`: the shader's wing beat (`crowd_looks.json` `wings`, today's `DmEntityViews.WINGS`) written frame by frame,
`CrowdBaker.FLAP_FRAMES` frames over one beat (2 pi / speed seconds), positions and normals; every role plays it (today the shader keeps beating through a
fall; the body layer does the rest). A model without wings bakes a still pose. The crowd starts each body at its own point of the loop, as today's
per-creature phase did.

- **Positions** `pos.res`: `ImageTexture`, RGBAH (half floats, xyz in creature space). **Normals** `nrm.res`: RG8, octahedral. Both saved as binary `.res`
  of raw pixels: they sample the same on Forward+ and Mobile, need no import step, and are never VRAM-compressed (that would corrupt the numbers).
  Positions are accurate to about 2 mm, normals to 1 degree.
- **Layout:** one texel per animation id and frame; a frame is `tex_rows` rows of `tex_width` texels (at most 2048 wide, 4096 tall: phones). Vertices that move
  alike (same place, bones, weights and normal: UV seams only) share one id, so the robber's 5,635 vertices are 2,179 columns.
- **Mesh:** rest pose in creature space, UVs for the albedo, the animation id in `CUSTOM0.x` (float), `custom_aabb` = bounds of every baked pose. One mesh per level
  of detail; all levels share the vertex array, so one pair of textures serves them all. A model over 5,000 triangles takes Godot's own simplified level
  (`ImporterMesh.generate_lods`) as level 0, and is reported when none is small enough.
- **Frames:** each clip gets the fewest frames per second (4 to 60, at most 128 frames) whose linear interpolation stays within 25 mm of the true pose
  (measured half-way between frames; the baker prints it). A strike is baked up to the follow-through of its latest impact (`DmAnimator.strike_timing`), a hurt up to the
  flinch (`FLINCH_SECONDS * FLINCH_SPEED`), a death to its end (the shader holds the last frame). Loops include the seam: the last frame blends into the first.

## Drawing

```
var data: CrowdVatData = load("res://assets/crowd/baked/grave_robber/model.tres")
var mm := data.make_multimesh(count, lod)            # use_colors and use_custom_data on
mmi.material_override = data.make_material(albedo, orm)   # res://assets/ + data.albedo_path
```

Per instance (`MultiMesh.buffer`: 20 floats, 12 transform rows, 4 colour, 4 custom data):

| data | meaning |
|---|---|
| `INSTANCE_CUSTOM.x`, `.y` | clip index (`data.clip_index("walk")`), seconds into the clip (a loop wraps, a one-shot holds its last frame) |
| `INSTANCE_CUSTOM.z`, `.w` | previous clip + blend weight below 1 (`pack_custom`), seconds into the previous clip; weight 0 = no blend |
| `COLOR.rgb`, `COLOR.a` | linear tint; glow slot x 2 + hit flash 0..1 (the slot picks the body's glow from the material's `glow_palette`, 0 = the model's own; the flash is the game's emissive lerp, `0xfff0dc`, in eighths: exact in a half float up to slot 63, checked on Compatibility) |

`DmCrowd` picks the clip from the creature's state, advances the time (walk speed matched to the ground speed) and blends over the game's fade times: "Driving the
crowd". Set a `custom_aabb` on the MultiMesh itself so the engine does not re-measure thousands of instances.

## Driving the crowd

In the game scene `DmCoreHost` (`client/core/dm_core_host.gd`) owns the view: `auto_sync` off, `sync()` between the step and the events, one `take_events()` per tick (client/README.md "The game scene and the dev entry").

`CrowdView` (a `Node3D`) draws the combat core's enemies and thralls as MultiMesh crowds: no node and no script per creature, no per-creature call across
the core boundary. The view logic is C++ (`native/src/core/crowd_view.*`, free of Godot types, a port of `godot/game/dm_entity_views.gd`, `dm_creature.gd` and
`dm_animator.gd`), reached through `DmCrowd` (`native/src/dm_crowd.*`), which reads the core and writes the MultiMeshes. It keeps its own state per creature, so nothing
presentational lives in the simulation (the core's tables are read in place, read only).

```
var view := CrowdView.new()
world.add_child(view)
view.setup(core, enemy_defs, Vector2(-60, -60), Vector2(60, 60))   # enemy_defs: ENEMIES of data/content/enemies.json; the area's bounds (the MultiMeshes' custom_aabb)
view.set_owner_legion(hero_core_id, "gravecaller")                  # whose thralls look like which legion
view.focus = hero_xz                                                # every tick (the knock pushes away from it, shadows go to the nearest to it)
```

- **Per tick:** `core.step(dt)`, then `crowd.sync(core)`, then `core.take_events()`. `CrowdView.sync()` does the middle step; with `auto_sync` (the default) its
  `_physics_process` (priority 1000, after the nodes that step the core) syncs whenever the core's clock moved. `sync` reads the core's enemy, thrall and corpse tables and
  the damage in the event buffer **without consuming it**: it remembers how far it read, and starts over once `take_events()` cleared the buffer. Calling `take_events()`
  before `sync` in the same tick loses that tick's hits for the crowd.
- **Per rendered frame:** `crowd.draw(delta, Engine.get_physics_interpolation_fraction(), camera_position)` (`CrowdView._process`): positions are interpolated between the
  last two ticks by `alpha`, every view advances by `delta`, the level of detail comes from the distance to the camera, and each group's buffer is written and
  uploaded with `RenderingServer.multimesh_set_buffer` and `multimesh_set_visible_instances`. `view.hitstop_scale` is the picture clock of a struck enemy
  (`Vfx.hitstop_scale`), written each frame.
- **Groups:** one MultiMesh per model, level of detail and shadow setting: two `MultiMeshInstance3D` nodes per level, one without shadows and one that casts. `DmCrowd`
  owns the instances' memory (`multimesh_allocate_data`); `CrowdView` gives each MultiMesh the area's `custom_aabb`. Every group is sized for 128 instances at loading
  (`reserve`) and doubles when a crowd outgrows it, so a wave of one model does not grow a MultiMesh; a steady crowd never does. `DmCrowd.buffer(model, lod, shadow)` returns
  exactly what was uploaded (count x 20 floats), `stats()` the counters (bodies by kind, instances drawn, capacity, regrows), `view_info(id)` one creature's view state, `take_landings()` where dying bodies came to rest since the last call (x, z, scale each: `DmEnemyFx` raises today's dust there), `shatter(corpse)` a corpse Corpse Explosion blew apart: its body goes at the next frame instead of sinking.

### The rows

What `sync` builds from the core, and what any other source can build instead (`DmCrowd.sync_rows`; `last_feed()` hands back the rows the last sync took, in the same
layout): plain numbers, nothing that points into the simulation. A co-op guest does not need `sync_rows`: its puppet core (native/README.md "Co-op") holds the same tables and the same
damaged events, so `sync(core)` draws it as it draws a host (`client/tests/core_coop.gd` compares the rows of both).

| row | fields |
|---|---|
| body (8 ints, 11 floats) | id (unique over enemies and thralls), kind (0 enemy, 1 thrall), model (the slot `add_model` returned), state (the core's `EnemyState` or `ThrallState`), flags (elite, caster, inert, mist, flyer), swing (a thrall's swing counter), def, glow (a slot of the glow palette of the crowd that made the row; 0 none); x, z, yaw, ground speed, seconds in the state, `action_s` (the seconds the state's one-shot is timed to: the wind-up, the dig, the 0.3 s recovery, a thrall's 0.12 s swing), scale, hover height, linear tint |
| hit (4 floats) | id, damage this tick (summed), hp after, max hp: from the core's damaged events (a puppet core derives them from hp drops, as puppets do today) |
| corpse (4 ints, 7 floats) | id, model, def, glow; x, z, facing, scale, tint |

A death is the body's state becoming `DEAD` (and the corpse row that follows), not a separate list.

### What each creature does

Numbers are today's, from the file named; where the live game and `dm_entity_views.gd` differ, `native/README.md` "Differences from today's game" says which was taken.

- **Facing:** the displayed yaw turns toward the interpolated sim yaw with `turn_toward(rate 10, at most 9 rad/s)` (`ENEMY_TURN_RATE`). **Ground speed:** the core's speed this tick,
  smoothed with `smooth_speed` (tau 0.18); walking starts at the sim's pace.
- **Clips** (`DmCreature`, `DmAnimator`): IDLE, RISING and the like loop `idle` at the body's own rate (0.92 to 1.08, from its id), from its own point of the loop; moving
  (over 0.2 m/s) plays `walk` or `run` by the stride plan (`plan_loco`: the model row's stride x height x scale; run above 2.0 x the walking pace, back below 1.6 x; time scale
  at least 0.4, at most `walk_cap` or 2.4; a walk and a run swap in the same phase of the step cycle). ATTACK and EMERGE play a strike (`attack`, or `cast` for casters) whose
  impact lands when the wind-up ends (`strike_timing`), HURT a flinch (the first 0.5 s of a hurt clip at 1.35x), DIG the dig clip over the dig time, DEAD the death clip held
  on its last frame. A role the model lacks resolves like `DmCreature.FALLBACK` (the baked `roles`); variants (`attack2`, `hurt3`, `death2`) are picked from the body's own dice.
  The hound has no attack, hurt or death clip: it lunges and bites with the body, recoils, and tips over.
- **Blends:** a change of clip blends the old pose out over today's fade times (loop changes 0.28 s, back from a one-shot 0.2 s, a strike 0.3 x the wind-up between 0.06 and 0.14 s,
  a flinch 0.09 s, a death 0.12 s, other one-shots 0.1 s). At most two clips blend; a third started mid-blend drops the oldest.
- **Body layer** (`DmCreature._fx_step`, in the instance transform): a hit recoil (kick back, squash, roll, 0.3 s; smaller for taller bodies, once per flash), a strike's lunge
  (rock back, drive forward on the impact, settle) and the lean of the climb out of the ground.
- **Hit flash:** 1 on a hit, then down by 6 per second (enemies) or 5 (thralls); drawn in eighths, as the game's emissive lerp. **Knock** (enemies only): `knock_impulse` away from the
  hero for a hit near the hero (24 x 20 m), a spring (`step_knock`) on the drawn position only.
- **Rise:** RISING climbs from 0.9 x the model's height (thralls 1.8 m) below the ground over 1.1 s (thralls 0.9 s), leaning in. **Hover:** a def's `flying` height (or the
  wraith's 0.45, a floating thrall's 0.25) with the bob of `DmEntityViews.sync`. BURROW and ERUPT are underground: not drawn.
- **Death:** the body keeps where it fell. A corpse of the same def within 1.2 m takes the dying body over (`CORPSE_ANIM_S` 6 s, `CORPSE_REST_S` 0.35 s: the clip stops 0.35 s
  after it has landed); with none, the body crumbles after 1.4 s. After the fall (the baked landing second, or the tip-over reaching 0.8 for a model with no death clip) it eases
  `SETTLE_DEPTH` 0.06 m into the ground (`settle_depth`). A corpse the core has no dying body for (the extra risen ones) is laid down at the end of its death clip. A body that
  leaves the tables, or a consumed corpse, sinks 1.3 m/s for 0.9 s. A mist body (the wraith) sinks at once.
- **Shadows** (`DmCasterBudget`, `DmEntityViews._shadow_lod`): every 10th frame the nearest 12 living enemies to the hero (8 once 32 are in the field) go into the shadow groups;
  thralls always cast, corpses and spectral bodies never. `set_shadow_policy(casters, crowded casters, thralls cast)` changes the numbers (the graphics preset's; a change reaches the thralls already drawn).
- **Level of detail:** from the distance to the camera, `lod_distances` per model (the CrowdView default is 32 m and 60 m, a first guess for the test build). Beyond the baked
  levels the last one is drawn.
- **Interpolation:** a body that moves more than 3 m in one tick (a teleport, a burrower surfacing) is drawn at its new place, not slid there.

### Models and looks

`crowd_looks.json` is today's `dm_entity_views.gd` tables as data: the model of each enemy def (`ENEMY_SLUG`) and thrall kind (`THRALL_SLUG`), the legions' models and tints, the
thralls' own looks, the casters, the hover heights. `CrowdView.setup` turns them into `DmCrowd.set_enemy_look` and `set_thrall_look` (per kind and legion), loads each baked model it
needs from `res://assets/crowd/baked/<slug>/` (the `baked_dir` option) and builds its nodes. A def whose model is not baked is drawn with the nearest one that is: the rig fallback of today's
game, else a baked model of the same rig (`enemies.json` `rig`), else the skeleton, else any baked model; each substitution is listed once in `CrowdView.warnings` (and `push_warning`).
A model with no colour texture is drawn white and listed too.

### Test of the views

`godot --headless --path client --script res://tests/crowd_view.gd` (20 s, bakes the robber, the hound and the skeleton into a scratch folder): the pure helpers against mirrors of
today's code on random inputs; the yaw, the speed, the clip of every state, the walk and run switch with its hysteresis and phase, the blends, the packing against
`CrowdVatData`'s packers, the flash, the recoil and lunge poses, the knock spring, the rise, the hover, the death into a corpse (landing, settle, mixer stop, sinking), the hound's
body-only moves, the shadow group and the level-of-detail split, interpolation; then a Full Party (72 enemies, 32 thralls) in a real `DmCore` through `CrowdView`: the events are
left for `take_events`, a crowd fed only the rows draws the same buffers, the buffers do not grow in a steady crowd, and `draw()` and `sync()` times are printed. The first rendered check
of the whole path is `client/tests/crowd_view_smoke.gd` (Compatibility, llvmpipe; Forward+ and Mobile run it the first time on a real GPU).

## Proof

`godot --headless --path client --script res://tests/crowd_bake.gd` (12 s): bakes the robber and the hound, then checks, for every clip's first, middle and
last frame and every vertex, the textures against an independent skinning of the model (max position error 2 mm, normals 1 degree); that the rest pose skins back to
the modelled mesh; metadata, texture size and format limits, 5,000-triangle and 1,024-pixel budgets, the over-budget path, mesh levels; the shader's vertex
function (mirrored line by line in the test) against true skeleton poses at random clip times with blends; the instance packing; and that the shader file has no
Forward+-only or screen-dependent built-ins. Headless Godot has no renderer, so GLSL itself compiles only in `crowd_smoke.gd` (Compatibility, llvmpipe);
Forward+ and Mobile run it the first time on a real GPU.

## Differences from the creature material (`godot/game/dm_creature_mat.gd`)

No normal map (the crowd mesh has no tangents), no gear regions, spectral fade or friend rim; the per-body glow comes from a palette (`DmCrowd.glow_palette`, today's emissive colours and strengths from `crowd_looks.json`: an elite's purple, the risen's, a legion's thralls' with the empowered and champion boosts) that CrowdView pushes to every material when a new glow comes into play; two-sided like most
of today's models. The procedural body layer (hit recoil, strike lunge, topple, rise from the ground) is not baked: `DmCrowd` writes it into the instance transform. A loop whose last key differs from its first (the robber's run, by 47 cm at the worst vertex) pops at its seam today; the baked clip blends across it.
