# Performance budget

Our written performance contract. It is adapted from the render-budget table in Majid Manzarpour's `threejs-game-skills`
(MIT, `technical-art.md`: "starting contracts, not universal limits") and fitted to what we measured in
[BLENDER-AUDIT.md](BLENDER-AUDIT.md). It is the **finish line for Performance Phase 1** in [ROADMAP.md](../ROADMAP.md)
(prop chunking, decal batching, GLB prune, clip trim, PNG to WebP) and the target list for Phase 2.

Check it with `node tools/qa/perf-budget.cjs` (report only) or `node tools/qa/perf-budget.cjs --strict` (exit 1 on any row over budget).
The `TIERS` constant in that script is the machine-readable copy of the table below; change both together.

## Tiers

| Tier | What it is | How the script builds it |
| --- | --- | --- |
| **Desktop High** | Settings quality `high`: shadows (one 1024 map, moon light), bloom, DPR capped at 1.5 | 1280x800, `quality: high` |
| **Desktop Low** | Quality `low`: no shadows, no bloom, DPR 1 | 1280x800, `quality: low` |
| **Phone** | Low on a phone-sized screen with touch | 844x390, `quality: low`, touch, DPR 1 |

Desktop Low and Phone draw the same scene; they differ in budget because a phone GPU/CPU is several times slower. Quality is chosen in Settings
(`GameRuntime.applyQuality`); there is no automatic detection yet.

## The contract

"Current" is the fixed nave fight (five thralls, the whole nave roster in rings frozen in place, ten corpses, `zoom 0.8`: the same fixture as
`fixed-fight-perf.cjs` and `scene-categories.cjs`), the worst view we measured. Two runs of `perf-budget.cjs` on 2026-10-02, VPS, software GL, box at load 50+ on 24 cores,
before any Phase 1 change. Draw calls and JS time swing with how many spawn-crack decals and live enemies the fixture catches (see Caveats), so
current values are given as a range.

| Metric | Desktop High: current | target | Desktop Low: current | target | Phone: current | target | Phase |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Draw calls (whole frame, shadow pass included) | 286 to 322 | <= 300 | 203 to 212 | <= 220 | 263 to 299 | <= 150 | 1 (High, Low); phone needs 2 |
| Triangles, main pass | 379k to 402k | <= 350k | 378k to 386k | <= 350k | 445k to 457k | <= 300k | 1 |
| Triangles, shadow pass | 323k to 332k | <= 200k | 0 (no shadows) | 0 | 0 (no shadows) | 0 | 1 |
| Texture memory (decoded RGBA8 + mips, every texture the scene's materials reference) | 468 to 472 MB | <= 256 MB | 460 to 467 MB | <= 192 MB | 472 to 480 MB | <= 128 MB | 2 |
| JS update time per frame (sim + views + effects, no render) | 7.7 to 18.9 ms | <= 8 ms | 11 to 28 ms | <= 6 ms | 10.6 to 18.9 ms | <= 4 ms | 2 |
| Assets fetched to reach the fight (cold start, `/models /art /fx /audio`) | 39.2 MB | <= 60 MB | 38.3 MB | <= 50 MB | 38.3 MB | <= 40 MB | 1 |
| `public/` payload on disk (what a full offline copy downloads) | 109.1 MB | <= 85 MB | same | <= 85 MB | same | <= 85 MB | 1 (stretch: <= 50 MB with meshopt) |

"Phase" is when we expect to get there, from the audit's estimates:

- **Phase 1 gate (the finish line).** Triangles (chunked prop batches: about -40% of every frame on High, -38% on Low), draw calls (pooled decal
  layers: about -100 to -150 calls), payload (GLB prune -7.5 MB, clip trim about -3.5 MB, PNG to WebP -15.8 MB: 109 MB to about 82 MB, under 85).
  Phase 1 is done when `perf-budget.cjs` shows these rows `ok` for **Desktop High and Desktop Low** and the payload row for all tiers.
- **Phase 2.** Texture memory needs the texture downscale by class (about -250 to -300 MB) and probably more; JS time needs profiling of the sim
  and corpse handling (static corpse meshes); the Phone draw-call row needs more than pooled decals (skinned enemies cannot batch: LOD or fewer
  simultaneous enemies on Low). Until then these rows are expected to fail `--strict`.
- The JS and Phone numbers are our estimates, not measured on a phone. Frame time and fps on a real phone were never measured (SwiftShader is a
  CPU rasteriser). Treat the Phone column as a ceiling to design toward and re-check it on real hardware (an iPhone and a mid-range Android) before
  calling it met.

### Rules that already hold (keep them)

| Rule (his table) | Ours today |
| --- | --- |
| Shadow-casting lights <= 2 desktop, 1 phone | 1 (the moon), High only |
| Shadow map <= 2048 desktop, 1024 phone | 1024 |
| DPR cap | High 1.5, Low 1 |
| Post passes beyond render + output | High 1 (bloom), Low 0 |

### How to read the order of work (his rule, kept)

When performance drops: cut post and shadow cost first, then cull, LOD and instance, then reduce asset density where it is least visible.
Instancing is not free: different materials or constantly changing transforms erase the win (relevant to decal batching: pool per texture and blend mode).

## How each metric is measured

| Metric | Tool | Notes |
| --- | --- | --- |
| Draw calls, triangles (main, shadow) | `tools/qa/perf-budget.cjs` (`renderer.info` after one direct render, with shadows on and then off; shadow pass = difference) | Same fixture as `fixed-fight-perf.cjs` (medians of CPU reads) and `scene-categories.cjs` (which attributes calls and triangles to categories: use it to find out *what* is over budget) |
| Per-instance culling potential | `tools/qa/scene-culling.cjs` | Shows how many prop instances are really in view and in the shadow frustum; the evidence for chunking |
| Texture memory | `perf-budget.cjs` walks the scene's materials, counts each distinct texture once at width x height x 4 bytes (x 4/3 with mips) | An estimate of *referenced* decoded memory (BLENDER-AUDIT counted the same way: 313 textures, 488 MB). The GPU-resident subset is printed as "on GPU" |
| JS update time | `perf-budget.cjs` runs `__cwDebug.perf(60)` (60 game updates, no render) and takes the median of `DM_QA_READS` (3) | CPU only, so it does not depend on the software rasteriser, but it does depend on how loaded the machine is |
| Assets fetched | `perf-budget.cjs` sums the response sizes of `/models /art /fx /audio` from a cold browser context until the fight is on screen | Dev server, no compression: it is raw file size, an upper bound for what a gzip-serving host transfers for the images and audio |
| Payload on disk | `perf-budget.cjs` sums `public/models`, `art`, `fx`, `audio` | |
| Screenshots and look | `tools/qa/zone-tour.cjs` + `tools/qa/lib/pixel-metrics.cjs` | Perf work must not change the picture: the pixel-metric baselines (`tools/qa/baselines/pixel-metrics.json`) catch a flat or dark regression |

## Caveats

- **Fixture variance.** The fixture spawns the roster at once, so spawn-crack decals and live enemies vary between runs: draw calls moved by up to
  about 40% between runs on the same build, JS time by about 2x. Compare before/after with the median of several runs on an idle machine, and use
  `DM_QA_STATIC=1` style fixed scenes (`fixed-fight-perf.cjs`) when a few percent matters. The audit's 332 calls / 804k tris / 488 MB are inside this range.
- **Load.** Both runs were taken on a heavily loaded shared box, so the JS-time range is wide and inflated; re-measure it on an idle machine before using it.
- **Software GL.** Frame time and fps under SwiftShader are fiction. Only counts, sizes and CPU update time are used here.
- **Not budgeted yet:** geometries (his table: <= 300 / <= 200; ours is about 300), number of textures (<= 60 / <= 40 in his table; ours is about 300:
  not reachable without atlasing or the Phase 2 texture work, so we budget memory instead), shader programs (90 to 94), GPU frame time, load time on
  a mobile network, battery. Add them when there is a measurement behind them.
- Every deliberate overrun gets a line here with its reason and date (his rule: "document every deliberate overrun as a tradeoff").

## Overruns we accept

None recorded.
