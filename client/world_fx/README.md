# client/world_fx: world dressing

Dressing around the static area scenes: stained-glass windows with light shafts, candle flames, brazier fire, far
silhouettes, ground mist, per-area weather and water. Data in
`client/data/world_fx/fx.json` (read via `DmWfxData`, hand-edited). What each piece is, how it is drawn and what a frame pays (18 microseconds for the whole node), and the suite: "World dressing" below.

## Wiring
`client/next/next_world.gd` calls `DmWorldDressing.attach(world, focus)` after the area scenes are loaded (`world` = the `DmNextWorld`, whose lights-only builder holds the world data; focus = the hero node, so mist, braziers and wading ripples follow) and tells it the
hero's area through `set_area` (the weather cross-fades and the water takes the area's moon and palette). Per-area pieces (flames, windows) are children of the area scenes and leave with them; the rest lives under the node, for the loaded areas only.
`client/next/perf/dm_next_perf.gd` sets the weather's `atmosphere.quality_low` from the graphics preset; the preset also owns the bloom (`DmWfxBloom`, `DmGraphicsPreset.apply_environment`), which the dressing no longer touches.
Other API: `add_ripple(x, z, size)`, `is_wet(x, z)`, `set_candle_group(group, lit)`, `set_enabled(bool)`,
`set_feature("windows|flames|silhouettes|mist|atmosphere|water", bool)` (the benchmark's `--bench-dressing=` uses it), `quality = "low"` (flat water, half the weather), `detach()`.
Occlusion, wing flap and hover/bob are done by `client/world` and the views, not here. The area scenes carry none of what this draws (the converter leaves out the flame spheres, the water planes and the puddle quads), so nothing is hidden at run time.

## What draws what
Which piece each file draws; what each piece is, its count and what a frame pays are in "World dressing" below.
- `dm_wfx_windows.gd`: stained glass and light shafts, under the nearest area node. `dm_wfx_flames.gd`: candle flames, one MultiMesh per area with a billboard shader, and the sanctum's candle groups.
- `dm_wfx_brazier_fire.gd` with `dm_wfx_particles.gd`: the brazier fire (a ring of emission records the vertex shader draws from their age: one draw call). `dm_wfx_silhouettes.gd`: the far spires, trees and ruins as one merged mesh.
- `dm_wfx_mist.gd`: the ground mist (the CPU wrap, stepped 4 times a second). `dm_wfx_atmosphere.gd`: per-area weather, one mesh in a seeded order; an area's mesh is built once, while the world loads.
- `dm_wfx_water.gd`: the nave flood, the bog, the ponds and the puddles, with ripples, fresnel and the moon's glint, up to 16 ripple rings. `dm_wfx_bloom.gd`: the glow, applied by the graphics preset.
- `dm_wfx_data.gd` reads the tables; `dm_wfx_quads.gd` builds one mesh of N camera-facing quads whose per-particle attributes ride in the vertex arrays (the weather's).

## World dressing

`DmWorldDressing` (`client/world_fx/`, data in `client/data/world_fx/fx.json`) is attached by `DmNextWorld.build` to the areas the world holds and draws what moves around the static scenes. `DmNextWorld.dressing` is the node (null in a world built with no lights), `enter_area` tells it the hero's area (the weather and the water follow by event), `DmNextPerf.apply` thins the
weather on Low (`atmosphere.quality_low`), and the graphics preset owns the bloom (`DmGraphicsPreset.apply_environment`, [Graphics presets](../next/perf/README.md#graphics-presets)); the dressing no longer touches the environment. The area scenes carry none of what it draws:
the converter leaves out the flame spheres (a sphere floated above each candle and, with the glow, read as a white blob), the water planes and the puddle quads, so nothing is hidden at run time.

| Piece | What it is | How it is drawn and what a frame pays |
|---|---|---|
| Candle flames, 347 in 8 areas | additive billboards at the wicks, flicker and bob, the Sanctum's candle groups | one MultiMesh in each loaded area that has candles (a draw call when in view), the flicker in the vertex shader: nothing per frame |
| Brazier fire (21 braziers) | violet wisps and amber embers 30 x 28 m round the hero | one ring MultiMesh. A particle is written once, when it is emitted (a roll every 0.05 s: 10 wisps and 1.5 embers a second a brazier); its place, size and fade are closed forms of its age in the vertex shader (`DmWfxParticles.pose` is the same function in GDScript, and the test holds it against a frame-by-frame step). The old GDScript stepped every live particle every frame |
| Ground mist, 220 puffs | big soft puffs at knee height drifting over the world | one MultiMesh; the wrap rule is stepped 4 times a second (the old game: 15), 55 microseconds a step |
| Weather, 13 profiles | ash, leaves, bone dust, drips, embers round the hero | one mesh drawn from a clock by its vertex shader; an area's mesh is built the first time it is asked for and kept (4.8 ms in GDScript for the Nave's), the starting area's during loading |
| Windows, 4 | stained glass and a slanted shaft of light | a pane and a shaft under the nearest area's scene (the Nave's three, the Sanctum's one), static |
| Silhouettes, 70 | far spires, dead trees, fallen walls | one merged mesh |
| Water | the Nave's channels, the Fen's bog, the Acre's ponds, the puddles | one mesh, fresnel, the moon's glint, up to 16 ripple rings in the fragment shader; Low (`quality`) keeps a flat glossy sheet |

The brazier fire, the mist, the weather and the water are the only things that move on the CPU, and `DmWorldDressing._process` is a clock, an emission roll every third frame, a mist step every fifteenth and a few shader uniforms:
**18 microseconds a frame** (measured with the dummy renderer, the node alone in a Graves world, 3,000 frames; the weather 0.8, the water 0.4, the roll 16 each time and a mist step 55). The old GDScript mist (14 a frame) and brazier fire (44 with 26 live particles) took 58 between them.
Building an area's weather in GDScript costs 4.8 ms (the Nave's), which an area entry used to pay each time: now every loaded area's is built while the world loads. The six objects (water, weather, brazier fire, silhouettes, mist and the area's flames) are six draw calls
in the Graves' budget scene (`tests/draw_budget.gd`: `BUDGET_DRESSING` 8, none cast shadows) and replace the eight draws the stand-ins cost: the Graves' world, the dressing and the crowd are 96 draw calls with the earth beyond the walls (1), against 97 before.
`DmDrawModel` counts the dressing's pieces apart ("dressing:<piece>"). `--bench-dressing=off` (or `mist,water,...`) switches pieces off for a benchmark run and the report says which were off (`World dressing:`); the A/B is in [the benchmark's report](../next/perf/BENCHMARK-REPORT.md).
`tests/dressing.gd` is the suite.

**Ripples.** The effects ring the water through `DmEnemyFxHost.dressing` (`DmNextGame` hands the enemy fx's and the boss fx's hosts the world's dressing; null in a world with no lights): the hero's steps (`DmEventFxZones.wade_ripples`, every other 0.15 s while his drawn place moves, `DmEnemyFx` writes
`host.p.moving`), a body's death, the Fen Wisp's pulse and the Mire Mother's rings. `DmWfxWater.add_ripple` rings only on wet ground (the data's rects and puddles; a death outside their box is one rectangle test, 0.5 us; a dry spot inside it 10 us, a ring 4 us, measured headless) and
recycles the oldest of its 16 rings, so a horde cannot flood it; the ring itself is the water shader's, already drawn. **Candle groups.** `DmEventFx.set_candle_group` goes to `DmEnemyFxHost.candles`, which `DmNextGame` sets to the dressing for the boss fx only: the Prelate's second phase puts the west candles of the Sanctum out, its third the east ones, and its awakening and defeat light all three groups
(`DmWorldDressing.set_candle_group` writes the group's flames' light, `DmWfxFlames.set_group_lit`, in the areas that have candles: a few instance writes at a phase change). Nothing runs per frame.

## Tests
`client/tests/dressing.gd` (the pieces in the loaded areas, the stand-ins gone from the scenes, the area by event, the brazier fire's closed form against a frame-by-frame step, the mist's rate, the Binbun shaders' colour); the draw-call counts are `client/tests/draw_budget.gd`.

## Callers outside the node
`add_ripple` / `is_wet` are called from `client/game/dm_event_fx*.gd` through `DmEnemyFxHost.dressing`, which `DmNextGame` sets for the enemy fx and the boss fx (the hero's steps, deaths, the Wisp's pulse, the Mire Mother's rings; "World dressing" above).
`set_candle_group` goes through `DmEnemyFxHost.candles`, which `DmNextGame` sets for the boss fx (the Prelate's phases).
