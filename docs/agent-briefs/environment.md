# Brief — Environment set pieces → branch `cloud/environment`

Read `CLAUDE.md`, `HANDOFF.md`, then `src/graphics/WorldView.ts`, `src/content/layout.ts`,
`src/content/areas.ts`, `src/graphics/Effects.ts`, `src/graphics/occlusion.ts`,
`src/app/GameRuntime.ts`, `src/app/settings.ts`. Three.js r166, one shared renderer with
UnrealBloom, `settings.quality` 'high' | 'low', desktop target 60 fps.

1. **The Drowned Nave gets water** — new `src/graphics/Water.ts`: a shallow, dark, reflective
   surface over most of the nave floor (z −96…−44) at y≈0.06, leaving raised walkways/islands
   around the pillar rows. ShaderMaterial or onBeforeCompile'd MeshStandardMaterial: two scrolling
   procedural normal maps (canvas-generated, no asset files), fresnel toward deep violet-blue, low
   roughness so candle point lights and stained-glass shafts glint, subtle depth tint, ripple rings
   where entities move (≤16 ripple centres in a uniform array; WorldView exposes `addRipple(x, z)`).
   No THREE.Reflector. 'low' quality → simple glossy material. Water rects live in
   `content/layout.ts` (`water: Rect[]` on WorldLayout; generateLayout stays deterministic).
   NOTE: master no longer uses a roughness map on floors (it caused square highlight blooms) —
   keep it that way.
2. **Per-area atmosphere particles** (WorldView.update, around the focus, capped): ash + leaves in
   the Hollow Graves, bone-dust motes in the Ossuary, drips + faint rain streaks in the Nave, rising
   violet embers in the Sanctum. ≤~600 extra particles total.
3. **Graveyard puddles** that catch moonlight (decals or tiny water planes).
4. **Distant silhouettes** beyond the walls (ruined cathedral spire, dead trees; cheap, fog-tinted,
   never blocking gameplay).
5. Everything created/updated/disposed through WorldView; no per-frame allocations in hot loops.

Do NOT edit `src/scenes/WorldScene.ts`, `src/gameplay/**`, `src/ui/**`, `server/**`, README.md —
if a scene hook is needed, expose a WorldView method and describe the one-line call in your report.
No new binary assets. Verify `npm ci && npx tsc --noEmit && npx vitest run && npm run build`; add
`src/graphics/__tests__/layout-water.test.ts` (water inside the nave, not covering
interactables). Commit on `cloud/environment` and push; no PR, no merge. Report: branch, commit,
files, perf notes (draw calls, particle counts), results, suggested in-browser QA.
