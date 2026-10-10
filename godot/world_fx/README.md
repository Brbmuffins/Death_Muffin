# godot/world_fx: world dressing

Dressing around the static world that `godot/world/` leaves out: stained-glass windows with light shafts, candle flames, brazier fire, far
silhouettes, ground mist, per-area weather, water, bloom, and the login backdrop. Data in
`godot/data/world_fx/fx.json` (read via `DmWfxData`, hand-edited).

## Wiring
`next/next_world.gd` calls `DmWorldDressing.attach(builder, focus)` after the world is built (focus = the hero node, so mist, braziers and wading
ripples follow). `next/perf/dm_next_perf.gd` sets `set_feature("bloom", ...)` and `atmosphere.quality_low` from the graphics preset.
`DmNecroBackdrop.make_layer()` is the backdrop for `front/dm_login_screen.gd` and `dm_char_select_screen.gd`.
Other API: `add_ripple(x, z, size)`, `is_wet(x, z)`, `set_candle_group(group, lit)`, `set_enabled(bool)`,
`set_feature("windows|flames|silhouettes|mist|atmosphere|water|bloom", bool)`, `quality = "low"`, `detach()`.
Occlusion, wing flap and hover/bob are done by `godot/world` and the views, not here.

## What it draws
| Piece | Where |
|---|---|
| Stained glass + light shafts (4 windows: nave 3, sanctum 1) | `dm_wfx_windows.gd`, under the nearest area node |
| Candle flames, 347 in 8 areas, flicker + bob, sanctum candle groups | `dm_wfx_flames.gd`: one MultiMesh per area, billboard shader |
| Brazier fire (violet wisps + embers near the focus) | `dm_wfx_brazier_fire.gd` (same particle maths, one draw call) |
| Far silhouettes: spires, dead trees, ruins (70) | `dm_wfx_silhouettes.gd`: one merged mesh, golden-tested |
| Ground mist, 220 puffs | `dm_wfx_mist.gd` (CPU wrap, stepped every 4th frame) |
| Per-area weather (13 profiles) | `dm_wfx_atmosphere.gd`: one mesh, seeded mulberry32 order |
| Water: nave flood, bog, pond, puddles; ripples, fresnel, moon glint | `dm_wfx_water.gd`: one mesh, 16 ripple rings |
| Login backdrop (matte, parallax, mist, embers, sigil) | `dm_necro_backdrop.gd` |
| Bloom | `dm_wfx_bloom.gd` on Godot glow |

Stock stand-ins the dressing replaces (plain water planes, puddle quads, the one-sphere flame glow) are hidden, not freed, and return on `set_enabled(false)`.

## Tests
`godot --headless --path godot --script res://tests/world_fx/run.gd`. A/B render bench and screenshots: `tests/world_fx/bench.sh`, `backdrop_shot.sh` (take the renderer lock).

## Known gaps
- `add_ripple` / `is_wet` are only called from `game/dm_event_fx*.gd` through `DmEnemyFxHost.dressing`, which `DmNextGame` does not set, so enemy wading ripples are not wired.

`DmWfxParticles` (brazier fire, backdrop mist / embers; caps 160 / 256) writes one packed instance buffer per frame (transform, colour, custom data), not per-instance calls.
