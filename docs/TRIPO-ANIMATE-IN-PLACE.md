# Tripo `animate_in_place` and GLB retargets

Verdict (A/B on the `hero_gravecaller` rig, Tripo task `efac8a46-932e-4a08-9b05-9b38d0f3e4b1`, 30 credits; params and results in
`art-manifest/tripo/ab-animate-in-place-2026-10-02.json`). Two claims from a third-party skill do not hold for our v1.0 biped models:

- `animate_in_place` is a no-op on this path: walk and cast retargeted with `false` are byte-identical to `true`, and the hip still
  travels 1.6 body heights across the walk. `tools/ai/tripo.mjs` sends `spec.animateInPlace ?? true`; leave it.
- GLB retargets are correct. An FBX retarget of the same walk matches the GLB joint for joint (max 0.0037 body heights). Keep GLB; do not switch to FBX.

So an ugly robed caster or odd preset comes from the preset's motion or the model's skin, not from the flag or the export.
Not tested: v2.5 quadruped rigs and `rig_type: avian` (avoid avian, see `ASSET_PIPELINE.md`).

## Validators

Run after each paid batch, before `build-characters`, to catch a lying or over-long preset (hip height under 0.3 and duration over 6 s):

- `node tools/ai/validate-rig.mjs <glb...>`: skin and joint counts, roots, NaN/Inf, scale, bone lengths, weight sums, dead bones.
- `node tools/ai/validate-animation.mjs <glb...> [--json]`: per clip, FK at 30 fps vs bind: duration, channel coverage, NaN, scale tracks, bone-length stretch, root drift, hip height, bbox collapse, hand reach, crossed arms, rotation pops.
- `node tools/ai/compare-clips.mjs a.glb [clip] b.glb [clip]`: joint-by-joint FK diff of one clip in two files.
- `tools/blender/fbx_to_glb.py`, `tools/blender/clip_strip.py`: FBX conversion and frame-strip renders (Cycles CPU, no GL).

Known benign warnings on shipped clips: Tripo `idle` (15.3 s) and `dig` (16.4 s) are long on every biped (check `clips.json` trims them);
the raw `hurt` preset (13.9 s) lies down (shipped heroes use `hurt`/`hurt2` that do not); `death2` has a cosmetic toe flip;
quadruped and procedural hero clips report a low hip height because their hip bone is not the pelvis.

Rig fact: about 47% of a hero's skin weight sits on the `*Twist` bones and the main Thigh/Calf/Upperarm/Forearm bones carry none.
Harmless for Tripo clips; any procedural or Blender clip must drive the twist bones too (`rigfix` does).
