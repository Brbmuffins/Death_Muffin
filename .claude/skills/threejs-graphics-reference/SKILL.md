---
name: threejs-graphics-reference
description: "Reference notes for Death Muffin rendering work: render budgets and instancing/LOD rules, shader and onBeforeCompile recipes (dissolve, wind sway, scrolling emissive, fake glass, contact shadow), post-processing and bloom rules, and a visual scorecard for zone-polish audits. Use when reviewing or changing materials, shaders, lighting, post, VFX cost, draw calls, triangles, texture memory or phone performance."
---

# Three.js graphics reference (Death Muffin)

Technique notes adapted from Majid Manzarpour's MIT-licensed `threejs-game-skills` (`threejs-aaa-graphics-builder`). License and attribution: `LICENSE-threejs-game-skills.txt` in this folder. This is **reference reading, not a workflow**: nothing here generates assets, probes credentials, scaffolds code or spends money.

## Our rules win

- Spend (Tripo, Gemini) is approval-gated and every job is recorded in `art-manifest/`; see `ASSET_PIPELINE.md`.
- The performance contract is `docs/PERF-BUDGET.md`, not the generic table in `technical-art.md`. Measure with `tools/qa/perf-budget.cjs`.
- `SPELL_FX` colours (`src/content/abilities.ts`) carry meaning; recipes must not make everything violet or bloom-white.
- Phones and tablets are supported: the Low tier is the phone tier. Anything costly needs a Low-quality skip.
- Dark art is deliberate. The scorecard's brightness/contrast thresholds do not apply; use per-zone baselines (`tools/qa/baselines/pixel-metrics.json`).
- Three.js is 0.166.1; the recipes target r184. Check each API before pasting.
- The shared game tree is edited by parallel agents: stage explicit paths only.

## Files

| File | Read when |
| --- | --- |
| `references/technical-art.md` | render budgets, material roles, instancing/LOD/culling, VFX cost, imported-asset cleanup |
| `references/shader-cookbook.md` | writing an `onBeforeCompile` patch (follow `src/graphics/friendRim.ts`: chained patch plus `customProgramCacheKey`), dissolve, wind, glass, contact shadow, bloom settings |
| `references/visual-scorecard.md` | scoring a zone in an audit; the 10-category rubric and "automatic failures" list |
| `assets/scorecard-anchors/` | three arcade screenshots that calibrate the 1 / 2 / 3 scale |

## Order of work (his rule, kept)

Authored forms first, then materials, then lighting, then effects. When performance drops: cut post and shadow cost first, then cull/LOD/instance, then reduce asset density where it is least visible. If a shape only reads because it glows, the geometry is missing.

Report renderer numbers (calls, tris, textures, shadows, DPR) with any graphics change, and compare them with `docs/PERF-BUDGET.md`.
