# world_fx: the world dressing the web draws around the static world

Self-contained port of what `WorldView.ts`, `Water.ts`, `Atmosphere.ts`, `occlusion.ts`, `wingFlap.ts` and the enemy hover code draw that
`godot/world/` leaves out. Nothing here edits `godot/world`, `godot/main` or `godot/game`. Data: `godot/data/world_fx/fx.json`
(`npx vite-node tools/godot/export-world-fx.ts`; constants that are private in the TS are read from the source text and drift fails the export).

## Hook lines (the whole integration)
```gdscript
# dm_game.gd / main.gd, after builder.build(world) and the hero exists:
dressing = DmWorldDressing.attach(builder, hero_node)   # hero_node = Node3D to follow (optional; else the camera's ground point)
# dm_event_fx.gd add_ripple()/is_wet() currently probe the builder (has_method): point them at the dressing instead:
dressing.add_ripple(x, z, size)      /      dressing.is_wet(x, z)
# optional, sanctum candle phases (WorldView.setCandleGroup):
dressing.set_candle_group(group, lit)
# optional login/discipline backdrop (front track): replace DmFrontUi.backdrop() with  DmNecroBackdrop.make_layer()
```
Occlusion, wing flap, hover/bob and wade ripples are already done by godot/world + godot/game, so they are NOT here.
Other API: `set_enabled(bool)`, `set_feature("windows|flames|silhouettes|mist|atmosphere|water|bloom", bool)`, `quality = "low"`, `detach()`.

## What it draws
| Piece | Web source | Godot |
| --- | --- | --- |
| Stained glass + light shafts (4 windows: nave 3, sanctum 1) | `buildWindows` | `dm_wfx_windows.gd`, under the nearest area node |
| Candle flames, 347 in 8 areas, flicker + bob, sanctum candle groups | `buildFlameData/FLAME_VS` | `dm_wfx_flames.gd`: one MultiMesh per area, billboard shader |
| Brazier fire (violet wisps + embers near the focus) | `WorldView.update` + `Effects.ParticleSystem` | `dm_wfx_brazier_fire.gd` (same particle maths, one draw call) |
| Far silhouettes: spires, dead trees, ruins (70) | `buildSilhouettes` | `dm_wfx_silhouettes.gd`: one merged mesh, three.js tessellation, golden-tested |
| Ground mist, 220 puffs | `buildMist` | `dm_wfx_mist.gd` (the web's CPU wrap rule, stepped every 4th frame) |
| Per-area weather (13 profiles) | `Atmosphere.ts` | `dm_wfx_atmosphere.gd`: one mesh, seeds replay the web's mulberry32 order |
| Water: nave flood, bog, pond, puddles; ripples, fresnel, moon glint | `Water.ts` | `dm_wfx_water.gd`: one mesh, 16 ripple rings |
| Login backdrop (matte, parallax, mist, embers, sigil) | `NecroBackdrop.ts` | `dm_necro_backdrop.gd` |
| Bloom | `GameRuntime` UnrealBloomPass (0.75 / 0.55 / 0.85) | `dm_wfx_bloom.gd` on Godot glow |

Stock stand-ins the dressing replaces are hidden, not freed (plain water planes/puddle quads, the one-sphere flame glow) and return on `set_enabled(false)`.
Tests: `godot --headless --path godot --script res://tests/world_fx/run.gd`. Rendered A/B + screenshots: `tests/world_fx/bench.sh` (renderer lock).
