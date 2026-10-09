# Blender animation pipeline

Headless Blender (4.5 LTS, `/home/ubuntu/tools/blender/blender`, glTF addon on) driven by scripts, so animation work is
free (no Tripo credits) and repeatable. Roadmap item X2b. It writes the same per-clip `anim_<name>.glb` files that
`tools/build-characters.mjs` already turns into `public/models/<slug>/character.glb`, so glTF extensions, WebP textures
and quantisation are untouched. Hand-keyed signature animation stays a human animator's job; the last section shows
how their files drop into the same flow. Sources and licences: [ANIMATION-SOURCES.md](ANIMATION-SOURCES.md).

```
node tools/blender.mjs procedural <slug> [clip ...] [--install]     author clips from a recipe (quadruped gaits, idles, overlays on Tripo clips)
node tools/blender.mjs rigfix     <slug>                            add bones + move vertex weights (hound legs/tail, gargoyle wings)
node tools/blender.mjs cleanup    <in.glb> <clip> [--loop] [--drift] [--foot-lock] [--recipe r.json]
node tools/blender.mjs retarget   <source.glb> <target-rig.glb> <clip-map.json> [--only a,b]
node tools/blender.mjs install    <slug>                            copy art-src/blender/<slug>/anim_*.glb into art-src/tripo/<slug>/
node tools/blender.mjs build      <slug ...>                        build-characters only (its stride-speed and clip-timing steps call scripts that no longer exist)
node tools/blender.mjs selftest                                     kinematics checked against Blender itself
```

Everything reads and writes `art-src/` (gitignored). Generated clips land in `art-src/blender/<slug>/`; `install` copies
them into the Tripo folder after keeping the original under `art-src/tripo/<slug>/orig/` (an existing backup is never
overwritten). The whole loop for a quadruped:

```
node tools/blender.mjs procedural skull_rat --install
node tools/build-characters.mjs skull_rat       # public/models/skull_rat/character.glb
node tools/measure-clips.mjs --stride public/models/skull_rat/character.glb walk,run --legs tools/blender/recipes/skull_rat.json
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
| `legs.X.hock` | `true`: a digitigrade hind leg of **three chain bones** (thigh, shin, metatarsus) plus the paw. The first two are solved to the hock, the metatarsus then points at the ankle in a direction that flexes with the stride; the clip's `hock: {stance, swing}` gives degrees (positive folds the foot back; the swing is a sine over the swing phase, `stance` a ramp over the stance). Replaces `rigidFrom` (a stiff lower leg) where the rig has the bones. |
| `legs.X.minReach` | fraction of the leg's reach below which a swinging foot is pushed away from the hip (weight 0 at lift-off and touch-down, 1 in mid-swing). A tightly folded thin forearm becomes a fin that rises past the spine. |
| `clips.<name>.hock` | see `legs.X.hock` |
| `stride` | `{ walk: n }` body heights per second for a rig with no legs to measure (the gargoyle's flap loop); `build-stride-speeds` uses it as is. |
| `levelFeet` | `false` for rigs with no legs |
| `overlays.<preset>` | lay procedural motion over a **Tripo clip** (see below) |

A foot in stance moves backwards on a straight line at `stride / (duty * duration)` model units per second; that is the
clip's *ground speed*, printed as `stanceSpeed`. `tools/measure-clips.mjs --stride` measures it back from the finished GLB
(paw bones named by the recipe); the client should play the clip at `groundSpeed / stride` so the feet do not skate. Feet are
levelled first (`levelFeet`): each paw's target is lowered by the difference between its lowest skinned vertex and the
lowest of all, so asymmetric rigs touch one floor.

Authoring rules learned the hard way: stride is limited by leg reach (a 0.3 m hind leg cannot take a 0.7 m stride; the
auto-crouch hides a little but a run needs `crouch` of 8-10% of the body); a three-bone chain solved with FABRIK has a free
middle joint that jumps between frames (visible as a one-frame foot dip), so use `rigidFrom`.

## `rigfix` (new bones and re-weighting)

`recipes/cinderhound.json -> rigfix.legs[]` adds a shoulder/elbow/wrist bone chain per foreleg at the measured leg
positions and moves every old influence in the leg's column (chest, neck, stubs) onto the new bones with a smooth fade
toward the shoulder (`zTop`), a cross-fade at elbow and wrist, then normalises. Output: `art-src/tripo/cinderhound/rigfixed.glb`.
Before this the "legs that work against each other" were two hind legs plus a neck/chest bone dragging both forelegs
rigidly. Checked by looking at frame strips at run speed.

Three selection modes (all in `rigfix.py`, all move *every* old influence in the region onto the new bones, then normalise):

- column (`select.radius` ...): cinderhound forelegs, vertical columns around an axis, as above.
- **capsule** (`select.radii`, `soft`, `zTop`, `rootFade`): each new bone has a radius around its segment; a vertex shares its weight among the segments it is close to and fades over `soft` metres at the surface and over `zTop` in height so the top of a limb stays on the body. Used for the bone hound's four legs (`Upper/Lower/Paw`, `Thigh/Shin/Meta/Paw`) and its tail. A vertex that an earlier chain already owns (> 0.3) is skipped; `rootFade` keeps the first tail bone joined to the rump.
- **region** (`select.box`, `select.along`): axis constraints with soft edges (`absy`, `x`, `z`, ...) plus a position-along-axis spread over the bones; for thin sheets such as wings. The gargoyle's wings are "behind the body plane (`x < 0.12`), more than 7 cm off the centre line, above 0.4 m".

`node tools/blender/skinview.py` (via `blender -b --python`) renders a rig as coloured skin weights (strongest vertex group per vertex) plus bone lines, optionally at a frame of an animated GLB: that is how the hound's and gargoyle's skinning was read. Its bone lines of *old* Tripo bones are drawn about 0.35 m low (the armature object offset), bones added by `rigfix` are correct; the mesh colours are what matters.

## Overlays: new bones on top of Tripo's own clips

`rigfix` adds bones the Tripo presets know nothing about, so a preset leaves them at the rest pose. A recipe's `overlays.<preset>` takes the **original** Tripo clip (`art-src/tripo/<slug>/orig/anim_<preset>.glb` if present, so an overlay is never stacked on an installed overlay), keeps all of its channels and keys the named bones on top: `{ base, bones: {bone: {sign, fold, tip, lag}}, roll: [[u, deg]...] (mean angle over the clip's normalised time), flap: {cycles, amp, env: [[u, 0..1]...]} }`. The roll is about the body's forward axis, applied in each bone's own rest frame so it follows the parent's motion. Output is `anim_<preset>.glb`, so `install` / `build` need nothing new. A Blender 4.4+ gotcha lives in the code: a copied action's channels sit in the slot of the armature it came from, so the target armature must use `action.slots[0]` or the base motion silently disappears (the exported clip then has only the new bones' channels: check `tools/measure-clips.mjs` shows hand/hip motion).


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

## Known limits

- The bone map is hand-written, not inferred. `.fbx` sources go through Blender's FBX importer (untested here; the pack's GLB was used).
- `retarget` copies motion, not intent: proportions differ (UAL legs are longer relative to the hips than Tripo's), so feet float or sink until `cleanup --foot-lock` runs. Fingers and twist bones are not animated.
- Retargeted combat clips lose Tripo's per-clip `release` metadata; `build-clip-timings` guesses the impact from peak hand speed, which is wrong for clips whose fastest motion is the recovery.
- `procedural` gaits: only `gait` and `idle` types (plus overlays), one gait per clip. Hock legs need three chain bones; the cinderhound and bone hound have them, the skull rat's hind legs stay `rigidFrom`. A tail cannot be raised by rotating its bones on the skull rat (its hind legs hang off `Tail_0`, and cumulative pitch curls the tail under the body): a `lift` of `Tail_1` is used instead. No 'trot vs gallop' blend, no turning clips, no attack/death/hurt clips for quadrupeds.
- `rigfix` weights are geometric (capsules, boxes); cloth or hair hanging through a limb column can be shared between the limb and the body and stretch. Check with a posed `skinview.py` and look for vertices under the floor.
- Installing a procedural clip overwrites `art-src/tripo/<slug>/anim_<clip>.glb` in the shared raw-asset folder (originals are in `orig/`).

## Dropping in hand-keyed clips

1. In Blender, import `art-src/tripo/<slug>/rig.glb` (or an existing `anim_*.glb`), keep the armature and mesh, delete other actions, key your animation on the existing bones (do not rename, add, or move bones; add bones only through `rigfix` so the mesh stays skinned).
2. Export glTF Binary with *Animation: active action*, *Always sample*, Y up, to `art-src/tripo/<slug>/anim_<name>.glb`. The name after `anim_` becomes the clip name, except presets listed in `CLIP_NAMES` in `build-characters.mjs` (e.g. `agree` -> `talk`).
3. Optional: `node tools/blender.mjs cleanup art-src/tripo/<slug>/anim_<name>.glb <action> --loop --drift` (writes `.clean.glb` next to it; rename it over the original), and `node tools/blender.mjs retarget ...` for library clips.
4. `node tools/build-characters.mjs <slug>` and check `node tools/measure-clips.mjs public/models/<slug>/character.glb`.
5. Check the clip in the Godot client.

Files: `tools/blender.mjs`, `tools/blender/{common,kin,procedural,rigfix,cleanup,retarget,selftest,skinview}.py`, `tools/blender/pack.mjs`,
`tools/blender/recipes/*.json`, `tools/blender/maps/*.json`, measurement additions in
`tools/measure-clips.mjs`.
