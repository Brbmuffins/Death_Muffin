# Tripo `animate_in_place` and GLB retargets: A/B (2026-10-02)

Question: a third-party skill (`threejs-3d-generator`, Majid Manzarpour) says (1) `animate_in_place` corrupts Tripo
v1.0 retargets (mirrored/crossed limbs) and (2) v1.0 retargets exported as GLB collapse the limbs into the torso, so
use FBX. `tools/ai/tripo.mjs` sends `animate_in_place: true` with `out_format: glb`, so we tested it.

## Verdict

**Neither claim holds for our v1.0 biped models.** On the `hero_gravecaller` rig (task `efac8a46-932e-4a08-9b05-9b38d0f3e4b1`):

- `animate_in_place` is a **no-op** on this path. Walk and cast retargeted with `false` came back **byte-identical**
  to the clips we already had from `true` (walk sha256 `022b2f08...`, cast identical by `cmp`). The hip still travels 1.6
  body heights across the walk with the flag on, so it does not even do what its name says.
- The GLB bake is **correct**. An FBX retarget of the same walk (no flag) matches the GLB joint for joint: max 0.0037 body
  heights of difference (hip-relative, all 41 joints, 72 frames), at the noise floor. No collapse, no crossed limbs.
- So the ugly robed casters and odd presets are not caused by this flag or by GLB export. They come from the preset
  motion itself and from the model/skin (below).

Not tested (no spend): v2.5 quadruped/creature rigs (his "exploded skinning" claim), and `rig_type: avian`.

## Spend

30 Tripo credits (3 retargets at 10; balance 3940 to 3910), cap was 40. Every task, its params and credits:
`art-manifest/tripo/ab-animate-in-place-2026-10-02.json`. Variant A (flag on) reused the existing paid clips.

| Variant | Params | Result |
|---|---|---|
| A walk, cast | glb, `animate_in_place:true` (our pipeline) | existing files |
| B walk, cast | glb, `animate_in_place:false` | byte-identical to A |
| C walk | fbx, `animate_in_place:false` | converted with `tools/blender/fbx_to_glb.py`; matches A within 0.0037 h |

Images (frame strips, rows are variants, columns are 8 times across the clip, camera follows the hip):
`docs/tripo-ab/walk-strip.jpg` (A, B, C; C looks dark only because the FBX import has no textures),
`docs/tripo-ab/cast-strip.jpg` (A, B), `docs/tripo-ab/shipped-gravecaller.jpg` (shipped slam, summon, channel, hurt, death2).
All poses match across variants; no limb collapse in any.

## Tools added (our own implementation)

- `tools/ai/validate-rig.mjs <glb...>`: skin count, joint count, skeleton roots, NaN/Inf, scale, bone lengths, weight sums, dead bones.
- `tools/ai/validate-animation.mjs <glb...> [--json]`: per clip, FK at 30 fps vs bind: duration, channel coverage, NaN,
  scale tracks, bone-length drift (stretch), root drift, hip height, skinned-bbox collapse/explosion, hand reach,
  crossed-arms fingerprint, rotation pops.
- `tools/ai/compare-clips.mjs a.glb [clip] b.glb [clip]`: joint-by-joint FK diff of the same clip in two files.
- `tools/ai/ab-retarget.mjs`: capped (40 credit) retarget logger used for this test; `tools/blender/fbx_to_glb.py`, `tools/blender/clip_strip.py` (Cycles CPU, no GL needed).

## Validators on shipped clips

All 46 `public/models/*/character.glb` (384 clips): **0 errors, 0 NaN, 0 bone-length stretch, 0 crossed-limb fingerprints,
no rig errors**; 247 clips fully clean. Warnings, all benign or already known:

- 96 "long clip": Tripo `idle` is 15.3 s, `dig` 16.4 s on every biped (and the raw `hurt` preset is 13.9 s with the hip at
  5% of height, i.e. lying down: the known "lying clip"; shipped heroes use `hurt`/`hurt2` that no longer lie, only the raw
  `anim_hurt.glb` does). Check `clips.json` timings are trimming these; the validator cannot see that.
- 40 "rotation pop 96 deg/frame on L_ToeBase": `death2` on every biped, a toe flip as the body drops. Cosmetic.
- 2 "body collapses" (largest dimension 54% of bind): `hero_bell_monk` and `hero_grave_warden` `dig`, a deep crouch. Not broken.
- 1 tail-bone length drift on a quadruped.
- Quadrupeds and the Blender-procedural hero clips (`slam sweep flick channel summon`) report hip height near or below the
  sole line because their hip bone is not the pelvis; the strips show those poses are fine.

Rig facts worth knowing: ~47% of a hero's skin weight sits on the `*Twist` bones and the main `Thigh/Calf/Upperarm/Forearm`
bones carry none (11 of 41 joints dead). That is his stated root cause, but it is harmless here because our twist transforms
are correct (FBX match above). It does mean any procedural/Blender clip must drive twist bones too (`rigfix` already does).

## Recommended pipeline change

1. **No behavioural change needed.** Keep GLB retargets; do not switch to FBX (costs a Blender conversion, no quality gain).
2. `tools/ai/tripo.mjs`: `animate_in_place` is now `spec.animateInPlace ?? true`, so a spec can send `false` to be
   honest with the API. Default stays `true`: the flag has no effect, and changing the default would alter the request for
   no benefit. Root travel is stripped at runtime by `graphics/inPlaceAnimation.ts` either way.
3. Run `node tools/ai/validate-animation.mjs art-src/tripo/<id>/anim_*.glb` after each paid batch, before the build,
   to catch a lying or over-long preset (hip height under 0.3 and duration over 6 s) before it ships.
4. If a robed model still looks bad, look at the skin and the preset's pose, not the export path.
