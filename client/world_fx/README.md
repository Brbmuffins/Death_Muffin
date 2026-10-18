# client/world_fx: world dressing

Dressing around the static area scenes: stained-glass windows with light shafts, candle flames, brazier fire, far
silhouettes, ground mist, per-area weather and water. Data in
`client/data/world_fx/fx.json` (read via `DmWfxData`, hand-edited). What each piece is, how it is drawn and what a frame pays (18 microseconds for the whole node), and the suite: client/README.md "World dressing".

## Wiring
`client/next/next_world.gd` calls `DmWorldDressing.attach(world, focus)` after the area scenes are loaded (`world` = the `DmNextWorld`, whose lights-only builder holds the world data; focus = the hero node, so mist, braziers and wading ripples follow) and tells it the
hero's area through `set_area` (the weather cross-fades and the water takes the area's moon and palette). Per-area pieces (flames, windows) are children of the area scenes and leave with them; the rest lives under the node, for the loaded areas only.
`client/next/perf/dm_next_perf.gd` sets the weather's `atmosphere.quality_low` from the graphics preset; the preset also owns the bloom (`DmWfxBloom`, `DmGraphicsPreset.apply_environment`), which the dressing no longer touches.
Other API: `add_ripple(x, z, size)`, `is_wet(x, z)`, `set_candle_group(group, lit)`, `set_enabled(bool)`,
`set_feature("windows|flames|silhouettes|mist|atmosphere|water", bool)` (the benchmark's `--bench-dressing=` uses it), `quality = "low"` (flat water, half the weather), `detach()`.
Occlusion, wing flap and hover/bob are done by `client/world` and the views, not here. The area scenes carry none of what this draws (the converter leaves out the flame spheres, the water planes and the puddle quads), so nothing is hidden at run time.

## What draws what
Which piece each file draws; what each piece is, its count and what a frame pays are client/README.md "World dressing".
- `dm_wfx_windows.gd`: stained glass and light shafts, under the nearest area node. `dm_wfx_flames.gd`: candle flames, one MultiMesh per area with a billboard shader, and the sanctum's candle groups.
- `dm_wfx_brazier_fire.gd` with `dm_wfx_particles.gd`: the brazier fire (a ring of emission records the vertex shader draws from their age: one draw call). `dm_wfx_silhouettes.gd`: the far spires, trees and ruins as one merged mesh.
- `dm_wfx_mist.gd`: the ground mist (the CPU wrap, stepped 4 times a second). `dm_wfx_atmosphere.gd`: per-area weather, one mesh in a seeded order; an area's mesh is built once, while the world loads.
- `dm_wfx_water.gd`: the nave flood, the bog, the ponds and the puddles, with ripples, fresnel and the moon's glint, up to 16 ripple rings. `dm_wfx_bloom.gd`: the glow, applied by the graphics preset.
- `dm_wfx_data.gd` reads the tables; `dm_wfx_quads.gd` builds one mesh of N camera-facing quads whose per-particle attributes ride in the vertex arrays (the weather's).

## Tests
`client/tests/dressing.gd` (the pieces in the loaded areas, the stand-ins gone from the scenes, the area by event, the brazier fire's closed form against the old step, the mist's rate, the Binbun shaders' colour); the draw-call counts are `client/tests/draw_budget.gd`.

## Known gaps
- `add_ripple` / `is_wet` are only called from `client/game/dm_event_fx*.gd` through `DmEnemyFxHost.dressing`, which `DmNextGame` does not set, so enemy wading ripples and the Prelate's candle groups are not wired (KNOWN-GAPS "Built but never shown").
