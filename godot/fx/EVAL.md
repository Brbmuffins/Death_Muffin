# Binbun VFX pack evaluation (Godot 4.7.2, gl_compatibility)

Which vendor (Binbun) effects are cheap enough, and rules for swapping effects. Numbers are from llvmpipe (relative only; re-measure on a real GPU).
Vendor sources are private (not in git); the eval tooling is:
`tools/godot/fx-eval-setup.sh` -> `fx-eval-patch.py` -> `fx-eval-run.sh static|perf|perfvar|shots|shaders|synth` -> `fx-eval-report.py`,
harness `godot/fx/eval/eval_fx.gd`. Output goes to gitignored `godot/shots/fx_eval/`. Not re-run; treat as guidance.

## Findings
- 275 effect scenes in 12 packs load; one is broken (`magic_orb_flash_vfx_03_demo`). Never merge packs into one `res://assets`: the packs ship different
  `shared/` shader versions.
- **The heavy tier is geometry, not shading.** Vendor meshes are 32x32-subdivided quads and 4 m+ spheres; beams are 150-560k tris. Removing lights and
  capping Plane/Quad subdivision at 3 moves 59 heavy effects to 4 (`poison_cloud_01-04` stay heavy). Subdivision 32x32 vs 1x1 cost +4.4 ms in a synthetic check.
- Every particle shader with `proximity_fade` declares a depth texture: about +1.5 ms/frame when any is on screen.
- Tiers (x10 playback): cheap <= 30 ms, medium <= 100 ms (<= 4 alive), heavy = one at a time. Budgets: 24 one-shots + 32 loopers live.

## gl_compatibility notes (beyond the limits in `README.md`)
Dither alpha is visibly stippled at 1080p on explosions and impacts (use smooth alpha for hero effects). SmokeVFX needs the colour path in `DmFxBinbun`
or it renders flat white. Cores clip to white without `gain` 0.5. Defaults ship in saturated yellow/magenta/cyan and must be recoloured through the
primary/secondary/tertiary uniforms.

## Do not use as authored
`poison_cloud_01-04`; unmitigated `beam_*` / `laser_*` / `blast_*`; unmitigated `ice_ball_*`, `ice_cloud_*`, `ice_shard_*`; `smoke_big` / `smoke`
loopers; portals as doorways; `vfx_explosion_01`, `vfx_impact_05`; dithered explosions on hero casts; trail-based `fire_*` sparks; `fire_05` for
crowds (8 draw calls). The non-effect shader packs (Card, Hologram, GlassUI, Water, Grass, Toon, Skies) compile but nothing uses them.

## Rules for a swap pass
1. Strip lights from Binbun scenes (the single shared flash light stays) and cap Quad/Plane subdivision at 3.
2. Strip the `proximity_fade` depth branch behind a flag.
3. Per-effect alive caps from the tier; heavy = 1 alive.
4. Hero effects use smooth alpha and keep `gain` 0.5.
5. Re-run `fx-eval-run.sh perf` after the swap.
