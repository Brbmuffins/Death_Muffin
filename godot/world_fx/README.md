# godot/world_fx: world dressing

Dressing around the static world that `godot/world/` leaves out: stained-glass windows with light shafts, candle flames, brazier fire, far
silhouettes, ground mist, per-area weather, water, bloom, and the login backdrop. Ported from the retired web renderer; data in
`godot/data/world_fx/fx.json` (read via `DmWfxData`, hand-edited now that the exporter is gone).

## Wiring
`next/next_world.gd` calls `DmWorldDressing.attach(builder, focus)` after the world is built (focus = the hero node, so mist, braziers and wading
ripples follow). `next/perf/dm_next_perf.gd` sets `set_feature("bloom", ...)` and `atmosphere.quality_low` from the graphics preset.
`DmNecroBackdrop.make_layer()` is the backdrop for `front/dm_login_screen.gd` and `dm_char_select_screen.gd`.
Other API: `add_ripple(x, z, size)`, `is_wet(x, z)`, `set_candle_group(group, lit)`, `set_enabled(bool)`,
`set_feature("windows|flames|silhouettes|mist|atmosphere|water|bloom", bool)`, `quality = "low"`, `detach()`.
Occlusion, wing flap and hover/bob are done by `godot/world` and the views, not here.

## What it draws
| Piece | Original source (web) | Godot |
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

Stock stand-ins the dressing replaces (plain water planes, puddle quads, the one-sphere flame glow) are hidden, not freed, and return on `set_enabled(false)`.

## Tests
`godot --headless --path godot --script res://tests/world_fx/run.gd`. A/B render bench and screenshots: `tests/world_fx/bench.sh`, `backdrop_shot.sh` (take the renderer lock).

## Known gaps
- `add_ripple` / `is_wet` are only called from `game/dm_event_fx*.gd` through `DmEnemyFxHost.dressing`, which `DmNextGame` does not set, so enemy wading ripples are not wired.
