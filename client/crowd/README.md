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
- `bash client/tools/bake_crowd.sh [enemy id or model slug ...]` (default: the Graves roster `robber hound penitent ghoul rat moth bat`, the Ossuary's `deacon bone_golem`, the Drowned Nave's `censer acolyte gargoyle templar wraith` (the wraith, an unrigged prop, is a still pose of a few KB), the Sanctum's and Cloister's `seraph flagellant plague_doctor`, the Cinder Pyre's and the Mourning Fen's `cinder_husk pyre_priest cinderhound slag_brute bog_hag drowned_sexton fen_wisp mire_leech`, the Bone Abbess's `niche` (a still pose too), and the thralls the rites raise: `skeleton_thrall thrall_legionnaire thrall_sentinel thrall_plague carrion_sac bone_colossus`, then the eight hand-prop variants; 6 to 14 MB a body, under 2 MB a variant): runs the baker at low priority.
  Output: `client/assets/crowd/baked/<model slug>/`; the whole roster is about 235 MB (positions 140, normals 70, meshes 23, tracks 0.5; 2026-10-17).
- `client/tests/crowd_bake.gd`: the headless proof (below). `client/tests/crowd_smoke.gd`: the one rendered look (software GL).
- `client/crowd/crowd_view.gd` (`CrowdView`): the node that draws the combat core's creatures, with `client/crowd/crowd_looks.json` (which model each enemy
  def and thrall kind is drawn with) and the C++ `DmCrowd` behind it: "Driving the crowd". Proof: `client/tests/crowd_view.gd`; look: `client/tests/crowd_view_smoke.gd`.

Baked files are **generated, not committed** (`client/assets/crowd/baked/` is ignored): the robber is 7 MB, so the baker belongs to the build, not the
repository. Run `bash client/tools/bake_crowd.sh` before a publish; the test bakes into a scratch folder by itself.

## What is baked

The creature exactly as `godot/game/dm_creature.gd` puts it in the world: the height normalisation of `godot/world/dm_models.gd` (`analyze`), the row's yaw
(`godot/game/view_models.json`), the clip preparation of `_prep_anims` and `_prep_clips` (loops, walk and run drift, Hip pinned). Feet at the origin, +Z
forward, before the enemy's own `scale`. Clips are the ones `DmCreature` can play: idle, walk, run, attack and its variants, cast, hurt, death, dig, ...
(its `FALLBACK` table, stored as `roles`: role -> clips). Per model one `model.tres` (clip table, roles, texture paths, bounds, and what the views play the
clips with: per clip the whole source length, the second the blow lands and, for a death, the second the body comes to rest; the model row's stride),
`pos.res`, `nrm.res` and `mesh_lod<N>.res`. A thrall variant (below) has `track.res` and its meshes instead of the two textures.

**Unrigged models** (props today's creature shader animates: the moth, the bat, the choir wraith; `godot/game/dm_creature_mat.gd` wings) have no
skeleton to pose. They bake one looping clip, `fly`: the shader's wing beat (`crowd_looks.json` `wings`, today's `DmEntityViews.WINGS`) written frame by frame,
`CrowdBaker.FLAP_FRAMES` frames over one beat (2 pi / speed seconds), positions and normals; every role plays it (today the shader keeps beating through a
fall; the body layer does the rest). A model without wings bakes a still pose. The crowd starts each body at its own point of the loop, as today's
per-creature phase did. The Weeping Seraph is a rigged character (idle, cast, hurt, death) that today's shader also gives a wing beat (`wings` in `crowd_looks.json`
lists it): the baker poses its clips and does not add the beat, so it hovers with still wings (native/README.md "Differences").

- **Positions** `pos.res`: `ImageTexture`, RGBA8, one 32-bit texel per animation id and frame holding three integer codes over the bounds of every baked pose
  (`pos_lo`, `pos_step`, `pos_radix` of the model): `n = x + rx * (y + ry * z)`, position = `pos_lo` + code x `pos_step`. The baker picks the radices (`CrowdBaker.position_radix`)
  for the finest step the 32 bits allow: `rx` a power of two (the shader splits the 32 bits in two 16-bit halves and divides with plain ints, no shifts or unsigned types),
  `ry` and `rz` the rest. **Normals** `nrm.res`: RG8, octahedral. Both saved as binary `.res` of raw pixels: they sample the same on Forward+, Mobile and Compatibility
  (an 8-bit texel is exact through a float: `byte / 255 * 255 + 0.5` floors back to the byte), need no import step, and are never VRAM-compressed (that would corrupt the numbers).
  A position is within half a code step per axis of the baked one: under 1.5 mm for most models; the widest boxes (a colossus's or golem's death takes its box to 6.7 x 4.5 x 5.3 m) reach
  2.9 mm (half floats would have a worst case of 2.4 mm in the same box); the baker prints the worst of each model. Normals are accurate to 1 degree.
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
- **Per rendered frame:** `crowd.draw(delta, Engine.get_physics_interpolation_fraction(), camera_position, view_projection)` (`CrowdView._process`): positions are interpolated between the
  last two ticks by `alpha`, every view advances by `delta` (at its band's rate: "Crowd cost"), the level of detail comes from the distance to the camera, a body outside the camera's view
  is not written, and each group's buffer is written and uploaded with `RenderingServer.multimesh_set_buffer` and `multimesh_set_visible_instances`. `view.hitstop_scale` is the picture clock of
  a struck enemy (`Vfx.hitstop_scale`), written each frame.
- **Groups:** one MultiMesh per model, level of detail and shadow setting: two `MultiMeshInstance3D` nodes per level, one without shadows and one that casts. `DmCrowd`
  owns the instances' memory (`multimesh_allocate_data`); `CrowdView` gives each MultiMesh the area's `custom_aabb`. Every group is sized for 128 instances at loading
  (`reserve`) and doubles when a crowd outgrows it, so a wave of one model does not grow a MultiMesh; a steady crowd never does. `DmCrowd.buffer(model, lod, shadow)` returns
  exactly what was uploaded (count x 20 floats), `stats()` the counters (bodies by kind, instances drawn, capacity, regrows), `view_info(id)` one creature's view state, `take_landings()` where dying bodies came to rest since the last call (x, z, scale each: `DmEnemyFx` raises today's dust there), `shatter(corpse)` a corpse Corpse Explosion blew apart: its body goes at the next frame instead of sinking, `ground_at(id)` where a living body is drawn (`Vector3.INF` otherwise): the cheap read every frame for the rings and marks that follow a body.

### The rows

What `sync` builds from the core, and what any other source can build instead (`DmCrowd.sync_rows`; `last_feed()` hands back the rows the last sync took, in the same
layout): plain numbers, nothing that points into the simulation. A co-op guest does not need `sync_rows`: its puppet core (native/README.md "Co-op") holds the same tables and the same
damaged events, so `sync(core)` draws it as it draws a host (`client/tests/core_coop.gd` compares the rows of both).

| row | fields |
|---|---|
| body (8 ints, 11 floats) | id (unique over enemies and thralls), kind (0 enemy, 1 thrall), model (the slot `add_model` returned), state (the core's `EnemyState` or `ThrallState`), flags (elite, caster, inert, mist, flyer, diving, grounded), swing (a thrall's swing counter), def, glow (a slot of the glow palette of the crowd that made the row; 0 none); x, z, yaw, ground speed, seconds in the state, `action_s` (the seconds the state's one-shot is timed to: the wind-up, the dig, the 0.3 s recovery, a thrall's 0.12 s swing), scale, hover height, linear tint |
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
  on its last frame. A Gargoyle's dive (flag `diving`, set while the swing winds up) plays the `dive` clip over the wind-up and a fifth more, with no lunge. A role the model lacks resolves like `DmCreature.FALLBACK` (the baked `roles`); variants (`attack2`, `hurt3`, `death2`) are picked from the body's own dice.
  The hound has no attack, hurt or death clip: it lunges and bites with the body, recoils, and tips over.
- **Blends:** a change of clip blends the old pose out over today's fade times (loop changes 0.28 s, back from a one-shot 0.2 s, a strike 0.3 x the wind-up between 0.06 and 0.14 s,
  a flinch 0.09 s, a death 0.12 s, other one-shots 0.1 s). At most two clips blend; a third started mid-blend drops the oldest.
- **Body layer** (`DmCreature._fx_step`, in the instance transform): a hit recoil (kick back, squash, roll, 0.3 s; smaller for taller bodies, once per flash), a strike's lunge
  (rock back, drive forward on the impact, settle) and the lean of the climb out of the ground.
- **Hit flash:** 1 on a hit, then down by 6 per second (enemies) or 5 (thralls); drawn in eighths, as the game's emissive lerp. **Knock** (enemies only): `knock_impulse` away from the
  hero for a hit near the hero (24 x 20 m), a spring (`step_knock`) on the drawn position only.
- **Rise:** RISING climbs from 0.9 x the model's height (thralls 1.8 m) below the ground over 1.1 s (thralls 0.9 s), leaning in. **Hover:** a def's `flying` height (or the
  wraith's 0.45, a floating thrall's 0.25) with the bob of `DmEntityViews.sync`. A diving body (the Gargoyle; `DmEnemyGargoyle._process`) climbs over the mark for the first half of the
  wind-up (hover + 3 m x progress), drops onto it ((hover + 1.5) x (1 - 2 x (progress - 0.5))^2) and sits at 0.05 m (flag `grounded`) while it recovers. BURROW and ERUPT are underground: not drawn.
- **Death:** the body keeps where it fell. A corpse of the same def within 1.2 m takes the dying body over (`CORPSE_ANIM_S` 6 s, `CORPSE_REST_S` 0.35 s: the clip stops 0.35 s
  after it has landed); with none, the body crumbles after 1.4 s. After the fall (the baked landing second, or the tip-over reaching 0.8 for a model with no death clip) it eases
  `SETTLE_DEPTH` 0.06 m into the ground (`settle_depth`). A corpse the core has no dying body for (the extra risen ones) is laid down at the end of its death clip. A body that
  leaves the tables, or a consumed corpse, sinks 1.3 m/s for 0.9 s. A mist body (the wraith) sinks at once.
- **Shadows** (`DmCasterBudget`, `DmEntityViews._shadow_lod`): every 10th frame the nearest 12 living enemies to the hero (8 once 32 are in the field) go into the shadow groups;
  thralls always cast, corpses and spectral bodies never. `set_shadow_policy(casters, crowded casters, thralls cast)` changes the numbers (the graphics preset's; a change reaches the thralls already drawn).
  The Full Party's 8 enemies and 32 thralls cast: the thralls are 4 of 5 casting instances (`stats().casting_thralls`); "Crowd cost" has what that costs the shadow pass and how the benchmark switches it.
- **Level of detail:** from the distance to the camera, `lod_distances` per model (the CrowdView default is 32 m and 60 m, a first guess for the test build). Beyond the baked
  levels the last one is drawn. The animation bands ("Crowd cost") start at the same two distances.
- **Interpolation:** a body that moves more than 3 m in one tick (a teleport, a burrower surfacing) is drawn at its new place, not slid there.

### Crowd cost

What the crowd costs a frame, and the four settings that cut it. All four are `CrowdView.setup` options (the game scene and the benchmark pass them through `DmCoreHost.setup`), `DmCrowd.settings()` says what is
in force, and the benchmark's report records them (client/README.md "The benchmark"). The defaults are today's look: nothing near the hero changes (`client/tests/crowd_view.gd` writes the same bytes with the bands on or off).

- **What was measured (the VPS, headless, the debug build the tests load, 2026-10-17):** a Full Party frame costs the crowd 30 to 50 us of CPU in `DmCrowd.draw` (104 bodies: 22 to 30 us in the views, 16 us in the buffer
  copies and the RenderingServer calls), under 0.3% of a 16.7 ms frame. The per-body work is the view logic (turn, legs, clip time, flash, knock, hover) and the 3 x 3 matrices of the instance row, about 0.2 us a body;
  the clip time itself is not CPU work (the shader samples the baked frames from the time in each instance's data). So the CPU side has little to give, and the value of the settings is on the GPU: bodies the
  camera cannot see no longer reach the vertex shader (each vertex fetches its baked position and normal, twice while blending), and the shadow pass takes fewer triangles. What the GPU saves is for Helix's PC to say.
  The headless Full Party benchmark cannot see it either: its held pack stands inside the view and inside 32 m of the camera (1 or 2 of 150 bodies are outside it), and five alternating pairs of runs with the defaults
  and with culling and the bands off (`--bench-crowd=cull=off,anim=off`) gave frames of 4.54 ms (4.20 to 5.09) and 4.50 ms (3.94 to 5.24), no difference: two identical runs differ by 0.3 to 0.7 ms.
- **Animation bands** (`cost.anim_lod`, `CrowdView.ANIM_LOD`): a body works its pose out (turn, ground speed, clip choice and time, blend, flash, knock, hover, the instance row) every frame within 32 m of the camera,
  24 times a second from 32 m, 10 times a second from 60 m (the first two mesh levels' distances: a body that small on the screen is also drawn with a simpler mesh). Between its updates a body is **placed every frame**
  (the interpolation between ticks, so it glides) and its last row is written again with the new place in it; the clip time in that row steps at the band's rate, never ahead of the true time and behind it by about 1/24 s or 1/10 s at most (0.03 s and 0.09 s in the test).
  Time is never lost: a pose update advances every second since the last one. Rates are time-based with a per-body phase (from its id, no dice), so the updates spread over the frames, not all on one. A body in a swing, a
  flinch, a recoil or the climb out of the ground (today's `DmCreature.busy`) is every frame whatever its band, a tick that changes a body's state, swing, hit or look catches its pose up to the present first and updates it on the next
  frame, a hit stop puts every body back to every frame meanwhile, and a body coming back into view is brought up to date before it is drawn. Today's game throttles the same way (`animLod.ts`: 24 and 10 Hz; there from a box
  around the hero, here from the camera, like the mesh levels). `stats()`: `band_near/mid/far` (living bodies per band), `pose_updates` (this frame), `pose_updates_total`; `view_info(id)`: `band`, `pose_updates`.
- **Culling** (`CrowdView.cull`, on): `draw` takes the camera's view-projection matrix (`Camera3D.get_camera_projection() * Projection(get_camera_transform().affine_inverse())`: one argument, no call per creature) and a body
  whose bounding sphere is outside any of the six frustum planes is not written, so the groups' drawn range stays contiguous and the GPU never sees it. The sphere is about the feet and holds every baked pose
  (`CrowdVatData.bounding_radius()`: the farthest corner of the baked bounds, 3.4 m for the robber) at the body's scale, plus 0.75 m for the lunge and the squash. A body outside the view still animates, at the far rate,
  and is brought up to date the frame it is back. **Shadows:** a casting body just outside the view can still cast into it. With the light's direction known (`set_light_direction`, from the moon, set by `DmNextPerf.apply`) the caster
  is kept while the sphere swept along the light to the ground (at most 40 m on) touches the view, and goes only when that whole run is outside one plane; unknown, it is kept within 12 m of the edge (`cost.shadow_reach`).
  A kept caster is drawn in the main pass too (one MultiMesh does both), a few bodies. `stats()`: `culled` (bodies not written this frame).
- **Thrall shadows:** the counters are `stats().casting` (instances in the shadow groups), `casting_thralls`, `groups_casting` (MultiMeshes drawn into the shadow map), `casting_triangles` (triangles drawn a second time into it)
  and `triangles` (all drawn), `groups_used`: the same numbers on any machine. In the Full Party at the Graves' camera 40 instances cast (8 enemies, 32 thralls), 80% of them thralls. `CrowdView.thrall_shadows` (-1 the graphics
  preset's, 0 never, 1 always; the setup option `thrall_shadows`, the benchmark's `--bench-crowd=thrall_shadows=off`) overrides the preset's `thralls_cast` so a run can compare on and off. The default is unchanged: thralls cast.
- **Reserve and levels of detail:** `reserve` (instances every group starts with, 128) and `lod_distances` (32 and 60 m) are setup options too and are recorded in every benchmark report. They stay as they were: they can only be set
  from a run on a real GPU. A bigger reserve hands more bytes over a frame for a small crowd (`multimesh_set_buffer` takes the whole buffer, the reserve long) and a smaller one regrows a MultiMesh when a wave of one model outgrows
  it (a `multimesh_allocate_data`, the hitch the reserve exists to avoid); nearer level distances draw fewer triangles and show the simpler mesh sooner.

### Models and looks

`crowd_looks.json` is today's `dm_entity_views.gd` tables as data: the model of each enemy def (`ENEMY_SLUG`) and thrall kind (`THRALL_SLUG`), the legions' models and tints, the
thralls' own looks, the casters, the hover heights. `CrowdView.setup` turns them into `DmCrowd.set_enemy_look` and `set_thrall_look` (per kind and legion), loads each baked model it
needs from `res://assets/crowd/baked/<slug>/` (the `baked_dir` option) and builds its nodes. A def whose model is not baked is drawn with the nearest one that is: the rig fallback of today's
game, else a baked model of the same rig (`enemies.json` `rig`), else the skeleton, else any baked model; each substitution is listed once in `CrowdView.warnings` (and `push_warning`).
A model with no colour texture is drawn white, and one baked by another version of the baker (`CrowdVatData.format`) is listed too (bake again).

### Test of the views

`godot --headless --path client --script res://tests/crowd_view.gd` (20 s, bakes the robber, the hound and the skeleton into a scratch folder): the pure helpers against mirrors of
today's code on random inputs; the yaw, the speed, the clip of every state, the walk and run switch with its hysteresis and phase, the blends, the packing against
`CrowdVatData`'s packers, the flash, the recoil and lunge poses, the knock spring, the rise, the hover, the death into a corpse (landing, settle, mixer stop, sinking), the hound's
body-only moves, the shadow group and the level-of-detail split, interpolation; then a Full Party (72 enemies, 32 thralls) in a real `DmCore` through `CrowdView`: the events are
left for `take_events`, a crowd fed only the rows draws the same buffers, the buffers do not grow in a steady crowd, and `draw()` and `sync()` times are printed. The crowd's cost: against the engine's own frustum planes
on 240 random bodies (a body in view is always drawn, one beyond its sphere never, the drawn range packed, the counters adding up), a caster kept while its shadow falls in and culled when it does not, the thrall shadow
counters, the bands' update rates on 120 frames (120, 48 and 21 pose updates; 30 bodies spread, at most 13 in a frame), the written time never ahead of the full-rate body's, a swing or a hit shown on the frame its
tick says so, the same bytes near the hero with the bands on or off, and a body outside the view kept at the far rate and up to date on its way back. The first rendered check
of the whole path is `client/tests/crowd_view_smoke.gd` (Compatibility, llvmpipe; Forward+ and Mobile run it the first time on a real GPU).

## Proof

`godot --headless --path client --script res://tests/crowd_bake.gd` (30 s): bakes the robber and the hound, then checks, for every clip's first, middle and
last frame and every vertex, the textures against an independent skinning of the model (positions within 2 mm and within half a code step, normals 1 degree); the position codes (radices
for boxes of every size, 32 bits, a power-of-two x, a round trip within half a step); that the rest pose skins back to
the modelled mesh; metadata, texture size and format limits, 5,000-triangle and 1,024-pixel budgets, the over-budget path, mesh levels; the shader's vertex
function (mirrored line by line in the test, the code decoding and the hand-prop branch included) against true skeleton poses at random clip times with blends; the instance packing; and that the shader file has no
Forward+-only or screen-dependent built-ins, no unsigned types or shifts. Headless Godot has no renderer, so GLSL itself compiles only in `crowd_smoke.gd` (Compatibility, llvmpipe);
Forward+ and Mobile run it the first time on a real GPU.

### Hand props

A thrall that holds a weapon today (DmEntityViews._make_thrall: a warrior or shieldbearer under an armed legion or none, every archer and bone mage) is drawn with a
variant of its body, `<model>+<kind>` (`thrall_legionnaire+warrior`, `skeleton_thrall+archer` ...), baked by `bake_crowd.sh` after the plain bodies. The variant does not copy its
body's animation: it **shares the plain body's `pos.res` and `nrm.res`** (its `model.tres` points at `baked/<model>/`; the baker bakes the plain body first when it is not there or is
of another `format`, so one GPU texture serves the body and its variants) and adds only its props, a few hundred triangles and a transform track:

- **Props are rigid meshes.** The baker builds today's props (`DmGearProps.bone_sword`, `round_shield`, `bone_bow`, `bone_staff`, from `crowd_looks.json` `thrall_props`: builder, bone, `dir`,
  `follow`) and adds their triangles to the body's mesh in their own space (`VERTEX`, `NORMAL`), with `CUSTOM0.x` = which prop of the variant and `CUSTOM0.y` = their material part
  (0 the body); the material reads the part's flat colour, metallic, roughness and emission from `part_albedo` / `part_pbr` / `part_emission` (`CrowdVatData`; no tint, flash or glow, as
  today's props). One MultiMesh, one surface, one draw call a group, as the plain body: a variant is its own model as before, so the draw calls are today's.
- **The track** `track.res`: `ImageTexture`, RGBAF (a few KB), one row per frame and three texels per prop: the rows of the prop's 3x4 matrix, translation in `w`. The baker places each prop every frame
  the way `DmCreature.attach` holds it: calibrated on the idle pose where today's calibration runs (the body settled 0.25 s, then 4 frames: `PROP_CALIBRATE_S`), then the hand's rotation
  times the calibrated one, its up pulled toward `dir` by 1 - `follow` (`CrowdBaker._prop_xforms`, the one formula the track and the test's reference share). The vertex shader blends the
  matrices of the two frames around the time, and of the two clips of a blend, with the same weights as the body's positions: linear in the matrix, so a prop vertex lands exactly where the
  straight line between its two placed positions does.
- **Frames.** `track_table` is the clip table of the track: the plain body's frames or finer (`CrowdBaker._sample_track`: the fewest frames per second, from the body's, that keep the blend of
  two frames within 25 mm of the true pose of the worst prop vertex, or 128 frames). The swing of a blade reaches further than any vertex of the body, so some clips take more track rows
  than body frames (a warrior's attack: 128 against 114).
- **Bounds** (`aabb`, the meshes' `custom_aabb`) hold the body and the props in every frame.

CrowdView picks the variant when it is baked and says once when it is not (the plain body then). A variant never stands in for another model. Not today's: the props cast shadows with the body
(today's never did), today recalibrates a prop that drifts 25 degrees and each thrall calibrates on its own moment (a shield can sit 20 to 40 degrees differently), the kit weapon's tier colour is
not applied, and on Compatibility the props' metal reads darker than today's material (the look pass).
`client/tests/crowd_bake.gd` bakes `thrall_legionnaire+warrior` (and the plain body it shares, from nothing) and checks the files and the sharing, the parts, the calibration (each prop's up along its `dir`, held at the
hand), and the shader's prop branch (mirrored line by line) against the fully placed props (`CrowdBaker._place_props`, today's formula on the true pose): at the first, middle and last frame of every clip (0.001 mm),
at random times against the straight line between the two frames' placed props (0.000 mm, 0.2 mm allowed), against the true pose (the interpolation tolerance), and blended; `client/tests/crowd_view.gd` checks which thralls get a variant.

## Differences from the creature material (`godot/game/dm_creature_mat.gd`)

No normal map (the crowd mesh has no tangents), no gear regions or friend rim; a spectral model (`crowd_looks.json` `spectral_models`: the wraiths) gets the same shader
with SPECTRAL defined (`CrowdVatData.spectral_shader`: 0.55 opacity, no depth write, as DmCreature's fade variant) and casts no shadow; the per-body glow comes from a palette (`DmCrowd.glow_palette`, today's emissive colours and strengths from `crowd_looks.json`: an elite's purple, the risen's, a legion's thralls' with the empowered and champion boosts) that CrowdView pushes to every material when a new glow comes into play; two-sided like most
of today's models. The procedural body layer (hit recoil, strike lunge, topple, rise from the ground) is not baked: `DmCrowd` writes it into the instance transform. A loop whose last key differs from its first (the robber's run, by 47 cm at the worst vertex) pops at its seam today; the baked clip blends across it.
