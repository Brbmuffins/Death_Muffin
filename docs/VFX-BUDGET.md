# Effect budget (branch `dm/vfx-budget`, 3 Oct 2026)

The owner asked whether spell effects bog the system down. They did, mostly through two things nobody could see: dead
particles that kept costing fill, and one draw call per flash or tether. This pass measures each effect, fixes what the
numbers pointed at, and keeps the look (parity renders below).

## Measure it

`tools/qa/vfx-cost.cjs` casts every rite, rune variant, legendary effect, the world effects (level-up, Grave Surge, loot,
boss telegraph), a partner's rotation replayed as remote events, and a 10 s busy fight, and prints a ranked table. Per effect:
draw calls the effect layer adds, **overdraw** (below), particles alive, Effects/Binbun CPU ms per frame, new materials and
shader programs, and (`DM_QA_BREAKDOWN=1`) which objects burn the fill. `tools/qa/vfx-cost-compare.cjs before.json after.json`
prints the before/after table. Numbers come from software GL on a loaded VPS: compare counts and overdraw, not milliseconds.

**Overdraw** is measured by `src/graphics/fxProbe.ts` (dev only, never imported by the game): the opaque scene is rendered for
depth, then every transparent effect material is patched to write a constant 1 with ONE/ONE blending into a half-float target,
so each pixel counts the effect fragments rasterised on it (alpha-discarded and empty texels included: the GPU shades those
too). "Layers" = total fragment-layers / screen pixels (1.0 = the whole screen covered once). The same module reports what share
of those fragments visibly change a pixel.

## What was wrong

1. **Dead particles were still drawn.** The two particle rings (3500 additive, 900 smoke) keep a particle's last size and
   rasterise it with alpha 0 until it is overwritten; the fragment shader then discards it. After a fight 3 to 10 screens' worth
   of fill was still being paid for nothing (`staleAfter`: 10.5 layers after the busy fight, 2 to 4 after any single rite).
   This was the biggest cost by far. The vertex shader now clips a particle the fragment stage would discard, and a dying
   particle's size and alpha are zeroed.
2. **One draw call (and one material) per flash, orbit shard and beam.** Every `flash`/`orbit` sprite and every `beam` was its
   own pooled Sprite/Mesh with its own material; a Black Litany ring of skulls or a few tethers was a dozen calls.
3. **Square meshes for round sprites.** Every ground decal was a quad, but disc / ring / sigil / cracks / glow are circles:
   a ring texture is empty in its middle and corners, 60 % of what was rasterised.

## What changed

- `Effects.ts`: particle vertex-stage cull and dead-particle zeroing (above); `flash`, `orbit` and `beam` draw through
  instanced layers (`graphics/fxLayers.ts`: `SpriteLayer` one call per texture, `BeamLayer` one call in all, per-instance
  colour and opacity, same additive blend, fog and render order as the objects they replace). Their shader programs compile with
  the first frame, not in the first fight (the glow and beam layers live for the session).
- Round decals and the glow sprite draw on a 16-gon around the inscribed circle; the ring texture on its annulus
  (`footprintGeometry`). The polygon sits inside the square, a flat edge on each axis, so it never samples past the texture.
- `Effects.particleScale`: `WorldScene.handleEvent` plays another player's cast (`by` / `owner` of a connected remote) at half
  the particles: the same effect and colours, fewer motes, because in a party their casts pile on top of ours. Enemy zones are
  never thinned. Graphics: Low also keeps 75 % of every burst (it has no Binbun layer or motifs, so these motes are its look).
- Not changed on purpose: spell colours (`SPELL_FX`), counts and sizes of our own particles on High, decal sizes and opacity,
  Binbun effects.

## Results (High, 1024x700, software GL)

Per effect (ranked by overdraw before; "overdraw" and "draw calls" are the peak while the effect plays, ambient scenery
included; both runs staged the same fight state). Sum over the 42 scenarios: draw calls 984 to 760 (-23 %), overdraw
109.9 to 61.6 screens (-44 %). Top of the table:

| effect | overdraw (screens) | draw calls | particles added |
|---|---|---|---|
| rune:contagion | 7.52 -> 2.73 | 23 -> 19 | 35 -> 26 |
| miasma | 6.10 -> 4.01 | 22 -> 26 | 37 -> 43 |
| rune:choir | 5.70 -> 1.57 | 30 -> 19 | 462 -> 484 |
| rune:creeping_rot | 5.33 -> 2.63 | 21 -> 15 | 16 -> 21 |
| rune:ring | 4.91 -> 0.99 | 30 -> 13 | 54 -> 41 |
| coop:partner_rotation | 4.82 -> 3.15 | 53 -> 35 | 625 -> 266 |
| bloom | 4.32 -> 1.77 | 34 -> 21 | 63 -> 56 |
| rune:volley | 4.05 -> 1.41 | 21 -> 14 | -2 -> -8 |
| frost | 4.02 -> 2.75 | 22 -> 18 | 29 -> 30 |
| prison | 3.91 -> 1.61 | 22 -> 14 | 65 -> 56 |
| veil | 3.59 -> 2.19 | 25 -> 15 | 12 -> 7 |
| dirge | 3.45 -> 2.21 | 26 -> 17 | 58 -> 58 |
| rune:impale | 3.26 -> 0.95 | 29 -> 16 | 96 -> 74 |
| rune:requiem | 3.13 -> 1.61 | 27 -> 19 | 541 -> 425 |
| explosion | 2.93 -> 1.79 | 18 -> 15 | 77 -> 85 |
| rally | 2.86 -> 0.20 | 25 -> 10 | 3 -> 7 |
| hands | 2.67 -> 2.51 | 21 -> 19 | 44 -> 35 |
| storm | 2.62 -> 1.44 | 22 -> 15 | -4 -> -1 |
| skull | 2.61 -> 1.61 | 14 -> 12 | 21 -> 21 |
| cleave | 2.44 -> 1.67 | 26 -> 15 | 73 -> 21 |

Busy fight, cold start, 30 enemies in a ring + a legion + a 20-rite rotation every 0.35 s for 10 s, seeded, two runs each (CPU ms swing 0.3 to 0.7 with the load on this shared box in both builds: the effect code is not a CPU cost either way, no change is claimed):

| | before | after |
|---|---|---|
| FX draw calls, mean (max) | 36.5 / 36.7 (61 / 61) | 30.4 / 31.9 (37 / 45) |
| overdraw, mean (max), screens | 6.54 / 6.72 (7.8 / 8.1) | 1.56 / 1.61 (1.9 / 2.2) |
| screen share touched by effects | 65 % / 64 % | 36 % / 36 % |
| deepest pixel stack | 81 / 82 | 52 / 48 |
| overdraw left after everything expired | 4.60 / 4.72 | 0.74 / 0.63 |
| Effects.update CPU ms, mean (p95) | 0.54 (1.1) / 0.45 (0.8) | 0.74 (1.6) / 0.57 (1.0) |
| Graphics: Low, overdraw mean / draw calls mean | 5.70 / 24.7 | 0.92 / 21.9 |

A partner's five-rite rotation replayed as two remote players: draw calls 53 to 35, particles 625 to 266, overdraw 4.8 to 3.2.

## Do the effects still look the same?

- `tools/qa/vfx-parity.cjs` renders the same hand-placed sprites, beams and decals the old way (Sprite / Mesh / square quad)
  and the new way and diffs the pixels: sprites and beams are identical (<= 2 of 255), decals differ by <= 0.12 / 255 on average
  (one thin-line sigil pixel by 13 counts: sub-texel interpolation). It also caught a real bug during this work (the sprite
  layer rotated the wrong way).
- Before/after captures of the most expensive effects are in `docs/screenshots/vfx-budget/` (3-D canvas only, seeded, left
  before, right after, two moments each). The world around the effect is not pixel-identical between runs (the sim is not
  deterministic), the effects are.

## Findings left alone

- Binbun cloud and mist particles (`miasma_cloud` Clouds, `grave_frost_mist` Mist) rasterise big quads where 97 to 99 % of
  fragments end up discarded or below 1/255. Cropping the quads does not help: over every effect time and seed the visible
  footprint of nearly every part is the full quad (calibrated with a throwaway probe), so the cost is the mask shader, not the
  geometry. They are the most expensive effects left (1.0 to 2.8 screens) and High-only.
- Decals of the zone circles (Miasma, Dirge, Bloom) are the biggest honest fill now: they are the big telegraph discs and
  that is the look.
- Ambient scenery (braziers, waystone portals, persistent glows) is about 0.25 screens and 10 draw calls in the Graves.

Raw reports: `docs/vfx-budget/before.json`, `docs/vfx-budget/after.json`.
