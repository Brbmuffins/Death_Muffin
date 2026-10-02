# Blender animation pipeline

Headless Blender (4.5 LTS, `/home/ubuntu/tools/blender/blender`, glTF addon on) driven by scripts, so animation work is
free (no Tripo credits) and repeatable. Roadmap item X2b. It writes the same per-clip `anim_<name>.glb` files that
`tools/build-characters.mjs` already turns into `public/models/<slug>/character.glb`, so glTF extensions, WebP textures
and quantisation are untouched. Hand-keyed signature animation stays a human animator's job; the last section shows
how their files drop into the same flow. Sources and licences: [ANIMATION-SOURCES.md](ANIMATION-SOURCES.md).

```
node tools/blender.mjs procedural <slug> [clip ...] [--install]     author clips from a recipe (quadruped gaits, idles)
node tools/blender.mjs rigfix     <slug>                            add bones + move vertex weights (cinderhound forelegs)
node tools/blender.mjs cleanup    <in.glb> <clip> [--loop] [--drift] [--foot-lock] [--recipe r.json]
node tools/blender.mjs retarget   <source.glb> <target-rig.glb> <clip-map.json> [--only a,b]
node tools/blender.mjs install    <slug>                            copy art-src/blender/<slug>/anim_*.glb into art-src/tripo/<slug>/
node tools/blender.mjs build      <slug ...>                        build-characters, then stride speeds, then clip timings
node tools/blender.mjs selftest                                     kinematics checked against Blender itself
```

Everything reads and writes `art-src/` (gitignored). Generated clips land in `art-src/blender/<slug>/`; `install` copies
them into the Tripo folder after keeping the original under `art-src/tripo/<slug>/orig/` (an existing backup is never
overwritten). The whole loop for a quadruped:

```
node tools/blender.mjs procedural skull_rat --install
node tools/blender.mjs build skull_rat          # public/models/skull_rat/character.glb, strideSpeeds.json, clipTimings.json
node tools/measure-clips.mjs --stride public/models/skull_rat/character.glb walk,run --legs tools/blender/recipes/skull_rat.json
node tools/qa/clip-strip.cjs out.png public/models/skull_rat/character.glb run --facing +z --frames 8 --speed 3.2 --abs
```

## How it works

`tools/blender/kin.py` re-implements Blender's pose maths (`P[b] = P[parent] @ (Rest[parent]^-1 @ Rest[b]) @ Basis[b]`;
`selftest` checks it against `pose_bone.matrix` on random poses) plus a closed-form two-segment IK with a pole, and
FABRIK for longer chains. Scripts compute bone location/rotation per frame at 30 fps and key them as plain FK; there are
no constraints or bakes, so what is exported is exactly what was computed. `pack.mjs` then drops every channel that never
leaves the node's rest pose (Blender samples all bones) and shifts times to start at 0.

Why not Blender's own IK constraints: the Tripo rigs are odd (the skull rat's hind legs hang off its first tail bone; the
cinderhound's forelegs are not bones at all), and a deterministic solver lets a clip be planted *by construction* and
checked by number. Node TRS of a Tripo skeleton round-trips exactly through Blender's glTF import/export (checked on the
skull rat and the biped heroes), which is what makes it safe to copy a Blender-exported clip onto the Tripo skeleton by
joint name.

## `procedural` and recipes

`tools/blender/recipes/<slug>.json`:

| key | meaning |
|---|---|
| `source` | rig GLB under `art-src/tripo/<slug>/` (default `rig.glb`; the cinderhound uses `rigfixed.glb`) |
| `forward`, `headBone`, `root` | body forward in Blender armature space (Z up), or derived root-to-head |
| `legs` | `{ FL: { chain: [bones hip..knee], paw: ankle bone, rigidFrom: 1 } ... }`. The paw's *head* is the ankle target. `rigidFrom: 1` treats `chain[1:]` as one stiff lower leg: the solver then has two segments and a unique answer. |
| `clips.<name>.type` | `gait` (feet on a stance line + swing arc), `idle` (feet planted, body breathes) |
| `gait` | `duty` (share of the cycle on the ground), `stride`, `lift`, `phase` per leg, `arc` (swing shape), `legScale`, `center` |
| `paw` | `stance` / `swing` pitch in degrees (positive = toes down) |
| `mods` | body modulators: `{ bones, kind: lift\|sway\|surge\|pitch\|yaw\|roll, amp (m or deg), cycles, phase, lag, offset }`; `lag` shifts the phase down the bone list, which makes tails and necks wave |
| `crouch` | `auto` (default): the smallest root drop that keeps every foot inside 98.5% of its leg's reach, or a number |

A foot in stance moves backwards on a straight line at `stride / (duty * duration)` model units per second; that is the
clip's *ground speed*, printed as `stanceSpeed`. `build-stride-speeds.mjs` measures it back from the finished GLB
(paw bones named by the recipe) and the game plays the clip at `groundSpeed / stride`, so the feet do not skate. Feet are
levelled first (`levelFeet`): each paw's target is lowered by the difference between its lowest skinned vertex and the
lowest of all, so asymmetric rigs touch one floor.

Authoring rules learned the hard way: stride is limited by leg reach (a 0.3 m hind leg cannot take a 0.7 m stride; the
auto-crouch hides a little but a run needs `crouch` of 8-10% of the body); a three-bone chain solved with FABRIK has a free
middle joint that jumps between frames (visible as a one-frame foot dip), so use `rigidFrom`.

## `rigfix` (cinderhound forelegs)

`recipes/cinderhound.json -> rigfix.legs[]` adds a shoulder/elbow/wrist bone chain per foreleg at the measured leg
positions and moves every old influence in the leg's column (chest, neck, stubs) onto the new bones with a smooth fade
toward the shoulder (`zTop`), a cross-fade at elbow and wrist, then normalises. Output: `art-src/tripo/cinderhound/rigfixed.glb`.
Before this the "legs that work against each other" were two hind legs plus a neck/chest bone dragging both forelegs
rigidly. Checked by looking at frame strips at run speed; a small shoulder-blade poke through the back remains at one phase of the run.

## `cleanup`

`--drift` subtracts the root's net travel as a ramp (the Tripo hero walk drifts 1.61 m and snaps back on loop; seam gap
1.61 -> 0.0). `--loop` spreads the first/last pose difference over the last `--window` (25%) of the clip with a smoothstep.
`--foot-lock` finds contacts (ankle low and moving near the median contact speed), puts the ankle on a straight line at one
speed and floor height during each contact (3-frame blend), re-solves the legs by IK and bakes back to FK. Measured on the
retargeted UAL walk: planted-vertex speed spread 0.11 -> 0.02, forward-moving share 2.5% -> 0%, seam 0. On Tripo's own biped
walk it changes nothing useful (already planted: spread 0.113 -> 0.139 after the round trip, i.e. noise); do not run it
there. It expects one contact per foot per cycle and refuses a leg with more than two (Tripo's quadruped preset shuffles
3-6 times a cycle; the skull rat's old walk is left alone with a warning). Gait quality for quadrupeds comes from
`procedural`, not from fixing the presets.

## `retarget` and the bone map

`tools/blender/maps/ual-to-tripo-biped.json` maps the Quaternius rig onto the Tripo v1 biped (the heroes, necromancer,
skeleton thrall, robber, ... all share it). Source faces -Y, target +X; the map's `source_forward/target_forward` give the
turn. Tripo has no fingers; Pelvis, `*Twist*` bones and `NeckTwist02` keep their rest pose.

| Quaternius | Tripo | mode |
|---|---|---|
| `pelvis` (+ travel x hip-height ratio, 0.589) | `Hip` | delta |
| `spine_01`, `spine_02`, `spine_03` | `Waist`, `Spine01`, `Spine02` | delta |
| `neck_01`, `Head` | `NeckTwist01`, `Head` | delta |
| `clavicle_l/r` | `L_Clavicle`, `R_Clavicle` | delta |
| `upperarm`, `lowerarm` | `Upperarm`, `Forearm` | aim (points where the source bone points; twist from delta) |
| `hand` | `Hand` | delta |
| `thigh`, `calf` | `Thigh`, `Calf` | aim |
| `foot`, `ball` | `Foot`, `ToeBase` | delta |

`delta`: the bone's rotation away from its own rest pose, turned to the target's forward axis, is applied to the target's
rest orientation. That handles different rest poses for bones that rotate about the same axes, but not for arms: the source
stands in a level T, Tripo's arms hang about 22 degrees below level, and a pure delta drives them into the torso. `aim` swings
the bone to the source bone's absolute direction afterwards. `sequence` joins several source actions into one clip
(`Spell_Simple_Enter + _Shoot + _Exit` -> `ual_cast`). Retargeted clips are in place (Hip ground travel dropped) because the
game owns the position; keep `inPlace: false` for something like a roll. Quadruped retargeting is not provided: there is
no CC0 quadruped library in the repo and the Tripo quadruped rigs differ per model.

## Results (2026-10-02)

Foot slip in the browser (`tools/qa/anim-pass-smoke.cjs`, `DM_QA_ONLY=rat,cinderhound DM_QA_ENEMIES_ONLY=1`). **The old
quadruped slip number was not trustworthy:** it counted every vertex near the floor, including the tail and head, and it
read the floor from one stray toe. It now (a) counts only vertices skinned to the legs named in the recipe, (b) takes the
floor from a low percentile of the per-frame lowest vertex, and (c) reports `slipFeet`: per leg, the lowest vertex while it
touches (within 2% of body height, two frames running), horizontal speed over ground speed, 0 = planted. The smoke also
refreshes the skeleton before reading `getVertexPosition` (defensive; it made no difference to the numbers measured here).

| model | clip played | mesh slip (all contact verts) | slipFeet | planted-vertex spread / forward share (offline, walk) |
|---|---|---|---|---|
| skull rat, before | Tripo walk at 4.5x (cap) | 0.72 | 1.04 | 0.83 / 22% |
| skull rat, after | new `run` at 1.9x | 0.06 | 0.06 | 0.003 / 5% |
| cinderhound, before | Tripo walk at 3.0x | 1.27 | 1.53 | 2.98 / 46% |
| cinderhound, after | new `run` at 1.5x | 0.08 | 0.08 | 0.000 / 0% |

Stride speeds (body heights per second, `src/content/strideSpeeds.json`): skull rat walk 1.219 -> 0.623, run 5.362 (new);
cinderhound walk 1.45 -> 0.589, run 3.19 (new). Both models now have `idle`, so they stand instead of shuffling their walk at
0.2x. Frame strips are in `docs/screenshots/blender/` (`*-before.png`, `*-after.png`; feet should sit on the ground ticks while planted).

### CC0 retarget proof (not in the game)

UAL clips on `hero_gravecaller` (`art-src/blender/retarget/hero_gravecaller/anim_ual_*.glb`, strips
`docs/screenshots/blender/retarget-*.png`), measured with `tools/measure-clips.mjs`:

| clip | UAL source | seconds | numbers | verdict |
|---|---|---|---|---|
| `ual_cast` | Spell_Simple Enter+Shoot+Exit | 1.47 | reach 0.33 m, hip min 1.0, hand speed peaks 1.73 m/s at 1.3 s (the retract, not the shot) | Not clearly better than the shipped cast (its first 1.1 s is an arm held out with a twist; the UAL cast adds raise and recovery but is one-armed and stiff). The sim impact would need a manual time (~0.55 s): the peak-hand-speed heuristic picks the retract. |
| `ual_spell_idle` | Spell_Simple_Idle_Loop | 2.10 | reach 0.34 m, still | New content: a spell-ready stance. Needs a code hook to use. |
| `ual_idle` | Idle_Loop | 2.50 | breathing, hands ~0.06 m/s | Shipped hero idle is a 15.4 s loop; a 2.5 s loop would repeat visibly. Keep the shipped one. |
| `ual_talk` | Idle_Talking_Loop | 2.93 | hands up to 0.27 m/s | Candidate for guide NPCs (they use `agree`/`angry_01` today). |
| `ual_walk` | Walk_Loop | 1.33 | after `cleanup --foot-lock`: spread 0.02 | Hero walk is already planted (0.113); no reason to swap. |

Decision left to the orchestrator; nothing under `art-src/tripo/hero_*` or `public/models/hero_*` was touched.

## Known limits

- The bone map is hand-written, not inferred. `.fbx` sources go through Blender's FBX importer (untested here; the pack's GLB was used).
- `retarget` copies motion, not intent: proportions differ (UAL legs are longer relative to the hips than Tripo's), so feet float or sink until `cleanup --foot-lock` runs. Fingers and twist bones are not animated.
- Retargeted combat clips lose Tripo's per-clip `release` metadata; `build-clip-timings` guesses the impact from peak hand speed, which is wrong for clips whose fastest motion is the recovery.
- `procedural` gaits: only `gait` and `idle` types exist, one gait per clip. The cinderhound's stiff lower hind leg keeps the rest pose's hock angle. A shoulder-blade vertex group pokes above the spine for a frame or two in the cinderhound run; the rat's tail drags along the floor in the run. No 'trot vs gallop' blend, no turning clips, no attack/death/hurt clips.
- `rigfix` is data-driven for legs only (the gargoyle's one-boned wing is not done).
- `bone_hound` still uses the Tripo walk plus the in-engine override in `tools/stride-overrides.json`; its recipe has not been written.
- Installing a procedural clip overwrites `art-src/tripo/<slug>/anim_<clip>.glb` in the shared raw-asset folder (originals are in `orig/`).
- Slip numbers are a ~2.5 s browser sample (150 steps) under real scene timing; they move by a few hundredths between runs, so compare before/after on the same machine.

## Dropping in hand-keyed clips

1. In Blender, import `art-src/tripo/<slug>/rig.glb` (or an existing `anim_*.glb`), keep the armature and mesh, delete other actions, key your animation on the existing bones (do not rename, add, or move bones; add bones only through `rigfix` so the mesh stays skinned).
2. Export glTF Binary with *Animation: active action*, *Always sample*, Y up, to `art-src/tripo/<slug>/anim_<name>.glb`. The name after `anim_` becomes the clip name, except presets listed in `CLIP_NAMES` in `build-characters.mjs` (e.g. `agree` -> `talk`).
3. Optional: `node tools/blender.mjs cleanup art-src/tripo/<slug>/anim_<name>.glb <action> --loop --drift` (writes `.clean.glb` next to it; rename it over the original), and `node tools/blender.mjs retarget ...` for library clips.
4. `node tools/blender.mjs build <slug>` and check `node tools/measure-clips.mjs public/models/<slug>/character.glb`, then a frame strip with `tools/qa/clip-strip.cjs`.
5. Run `tools/qa/anim-pass-smoke.cjs` (it reads `tools/blender/recipes/<slug>.json` for leg names if the model has one).

Files: `tools/blender.mjs`, `tools/blender/{common,kin,procedural,rigfix,cleanup,retarget,selftest}.py`, `tools/blender/pack.mjs`,
`tools/blender/recipes/*.json`, `tools/blender/maps/*.json`, `tools/qa/clip-strip.cjs`, measurement additions in
`tools/measure-clips.mjs`. Tests: `src/graphics/__tests__/blender-pipeline.test.ts`.
