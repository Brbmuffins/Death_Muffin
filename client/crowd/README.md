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
- `bash client/tools/bake_crowd.sh [enemy id or model slug ...]` (default `robber hound`): runs the baker at low priority.
  Output: `client/crowd/baked/<model slug>/`.
- `client/tests/crowd_bake.gd`: the headless proof (below). `client/tests/crowd_smoke.gd`: the one rendered look (software GL).

Baked files are **generated, not committed** (`client/crowd/baked/` is ignored): the robber is 11.5 MB, so the baker belongs to the build, not the
repository. Run `bash client/tools/bake_crowd.sh` before a publish; the test bakes into a scratch folder by itself.

## What is baked

The creature exactly as `godot/game/dm_creature.gd` puts it in the world: the height normalisation of `godot/world/dm_models.gd` (`analyze`), the row's yaw
(`godot/game/view_models.json`), the clip preparation of `_prep_anims` and `_prep_clips` (loops, walk and run drift, Hip pinned). Feet at the origin, +Z
forward, before the enemy's own `scale`. Clips are the ones `DmCreature` can play: idle, walk, run, attack and its variants, cast, hurt, death, dig, ...
(its `FALLBACK` table, stored as `roles`: role -> clips). Per model one `model.tres` (clip table, roles, texture paths, bounds), `pos.res`, `nrm.res`
and `mesh_lod<N>.res`.

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
var data: CrowdVatData = load("res://crowd/baked/grave_robber/model.tres")
var mm := data.make_multimesh(count, lod)            # use_colors and use_custom_data on
mmi.material_override = data.make_material(albedo, orm)   # res://assets/ + data.albedo_path
```

Per instance (`MultiMesh.buffer`: 20 floats, 12 transform rows, 4 colour, 4 custom data):

| data | meaning |
|---|---|
| `INSTANCE_CUSTOM.x`, `.y` | clip index (`data.clip_index("walk")`), seconds into the clip (a loop wraps, a one-shot holds its last frame) |
| `INSTANCE_CUSTOM.z`, `.w` | previous clip + blend weight below 1 (`pack_custom`), seconds into the previous clip; weight 0 = no blend |
| `COLOR.rgb`, `COLOR.a` | linear tint, hit flash 0..1 (the game's emissive lerp, `0xfff0dc`) |

The core picks the clip from the entity state, advances the time (playback speed is its business, e.g. walk speed matched to the ground speed), and blends over the
game's fade times. Set a `custom_aabb` on the MultiMesh itself so the engine does not re-measure thousands of instances.

## Proof

`godot --headless --path client --script res://tests/crowd_bake.gd` (12 s): bakes the robber and the hound, then checks, for every clip's first, middle and
last frame and every vertex, the textures against an independent skinning of the model (max position error 2 mm, normals 1 degree); that the rest pose skins back to
the modelled mesh; metadata, texture size and format limits, 5,000-triangle and 1,024-pixel budgets, the over-budget path, mesh levels; the shader's vertex
function (mirrored line by line in the test) against true skeleton poses at random clip times with blends; the instance packing; and that the shader file has no
Forward+-only or screen-dependent built-ins. Headless Godot has no renderer, so GLSL itself compiles only in `crowd_smoke.gd` (Compatibility, llvmpipe);
Forward+ and Mobile run it the first time on a real GPU.

## Differences from the creature material (`godot/game/dm_creature_mat.gd`)

No normal map (the crowd mesh has no tangents), no gear regions, wings, spectral fade or friend rim, no per-instance emissive besides the flash; two-sided like most
of today's models. The procedural body layer (hit recoil, strike lunge, topple, rise from the ground) is not baked: it belongs in the instance transform the core
writes. A loop whose last key differs from its first (the robber's run, by 47 cm at the worst vertex) pops at its seam today; the baked clip blends across it.
