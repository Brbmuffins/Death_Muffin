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
| `legs.X.hock` | `true`: a digitigrade hind leg of **three chain bones** (thigh, shin, metatarsus) plus the paw. The first two are solved to the hock, the metatarsus then points at the ankle in a direction that flexes with the stride; the clip's `hock: {stance, swing}` gives degrees (positive folds the foot back; the swing is a sine over the swing phase, `stance` a ramp over the stance). Replaces `rigidFrom` (a stiff lower leg) where the rig has the bones. |
| `legs.X.minReach` | fraction of the leg's reach below which a swinging foot is pushed away from the hip (weight 0 at lift-off and touch-down, 1 in mid-swing). A tightly folded thin forearm becomes a fin that rises past the spine. |
| `clips.<name>.hock` | see `legs.X.hock` |
| `stride` | `{ walk: n }` body heights per second for a rig with no legs to measure (the gargoyle's flap loop); `build-stride-speeds` uses it as is. |
| `levelFeet` | `false` for rigs with no legs |
| `overlays.<preset>` | lay procedural motion over a **Tripo clip** (see below) |

A foot in stance moves backwards on a straight line at `stride / (duty * duration)` model units per second; that is the
clip's *ground speed*, printed as `stanceSpeed`. `build-stride-speeds.mjs` measures it back from the finished GLB
(paw bones named by the recipe) and the game plays the clip at `groundSpeed / stride`, so the feet do not skate. Feet are
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

`tools/qa/clip-strip.cjs --yaw -90` views a +x-nosed model from the front (wing flaps); `tools/qa/enemy-shot.cjs <def> <out.png>` takes in-game close-ups of an enemy in the offline game.

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

## Results, round 2 (2026-10-02, `dm/blender-2`)

Same browser measure (`anim-pass-smoke`, `DM_QA_ENEMIES_ONLY=1`; a few hundredths of run-to-run noise). `bone_hound` "before" uses its old leg bones as the leg mask (`DM_QA_RECIPE_DIR` points the smoke at an alternative recipe folder).

| model | before | after |
|---|---|---|
| bone_hound | Tripo walk at 3.7x with a hand-made stride override: mesh slip 0.85, slipFeet 0.69. **In the game the walk also mangled the mesh into a vertical sliver** (`docs/screenshots/blender-2/bone_hound-ingame-before.png`, `-walk-before.png`: the rig's torso/cloth weights are stretched 3x by the preset). | procedural idle/walk/run on a rigfixed skeleton: slip 0.06, slipFeet 0.06 (Blender-side per-leg check: 0.00 on all four legs, walk and run). Stride 0.466 / 2.36 bh/s measured from the GLB; `stride-overrides.json` is empty. |
| cinderhound | run slip 0.08; stiff hind lower leg; shoulder fin | run slip 0.07-0.11 (same within noise); hock flexes (3-bone legs), forelegs stay open in swing (`minReach 0.6`), fin gone |
| skull_rat | run: tail ends 0.10-0.14 m **below** the lowest foot vertex (idle rest: 0.035) | tail lifted 0.1 m (`lift` on `Tail_1`, constant): 0.04 below the feet, i.e. its rest value; slip 0.06-0.09 |
| belfry_gargoyle | both wings skinned to arms/clavicles, flapped in a vertex shader; hover/idle was Tripo's 15 s idle | bones `L_/R_Wing_A/B`; idle, new `walk` (flap loop), dive, attack, hurt x2, death x2 all carry wing motion; shader flap switched off for the gargoyle (moth, bat, seraph keep it) |

Bone hound rig: the skeleton Tripo gave it is a chain of limb bones laid out from the tail tip to the chest (`0_Left_Limb_0` sits at the tail tip), the torso *and* the cloth are one bone (`0_Left_Limb_5`), and two foreleg chains overlap. `rigfix` adds `FL/FR_Upper/Lower/Paw`, `HL/HR_Thigh/Shin/Meta/Paw` and `Tail_A..D` from measured joint positions (recipe `rigfix.legs`). Cloth strands hanging in the leg columns stay on the old bones (they follow the body, two vertices dip a few cm under the floor in the run); the large pale plates that show when the hind legs fold are the model's own thigh/shin shapes.

Gargoyle decision: **switched to bone wings.** Evidence: `gargoyle-idle-after-front.png` (wings beat symmetrically, the membrane follows), `gargoyle-dive-after-front.png` / `-side.png` (the Tripo dive tumble is unchanged, wings sweep up in the second half of the clip), `gargoyle-hover-*.png` and `gargoyle-ingame-*.png` (game camera sees the gargoyle from the side/back, so the flap is hard to see there; the model is intact in both). Cost: the idle/dive/... GLB clips are now re-exports through Blender (durations differ by one frame, e.g. attack 6.6 -> 6.57 s, impact 2.1 -> 2.07 s in `clipTimings.json`). Not done: the wings are not folded by the sim state (a wing fold for the grounded stun after a dive); the hover bob still comes from `EntityViews`.

### CC0 retarget: guide NPC talk gesture (not swapped)

`ual_talk` (Idle_Talking_Loop) and `ual_interact` (Interact) were retargeted onto `npc_prior`, `npc_sexton`, `npc_apothecary` (`art-src/blender/retarget/<npc>/`; strips `docs/screenshots/blender-2/npc_*-talk-{current,ual}.png`). Measured on the prior: current `talk` (Tripo `agree`) 4.0 s, peak hand 0.93 m/s, root travel 0.03 m; `ual_talk` 2.9 s, peak 0.32 m/s, travel 0. Looking at them: the UAL loop is calmer but it is a hands-clasped-at-the-chest fidget that barely changes over 2.9 s, with both forearms crossing the torso (the prior's wide sleeves interpenetrate his robe; the sexton and apothecary hold their hands in front of the apron/chest the same way); it reads as waiting, not explaining. Tripo's `agree` opens the palms and raises one arm. `ual_interact` is a one-armed reach, not a talk. Not clearly better, so **nothing was swapped and the NPC GLBs are unchanged.** `talk2` (Prior's `angry_01`) has no CC0 candidate in this pack.

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
- `procedural` gaits: only `gait` and `idle` types (plus overlays), one gait per clip. Hock legs need three chain bones; the cinderhound and bone hound have them, the skull rat's hind legs stay `rigidFrom`. A tail cannot be raised by rotating its bones on the skull rat (its hind legs hang off `Tail_0`, and cumulative pitch curls the tail under the body): a `lift` of `Tail_1` is used instead. No 'trot vs gallop' blend, no turning clips, no attack/death/hurt clips for quadrupeds.
- `rigfix` weights are geometric (capsules, boxes); cloth or hair hanging through a limb column can be shared between the limb and the body and stretch. Check with a posed `skinview.py` and look for vertices under the floor.
- Installing a procedural clip overwrites `art-src/tripo/<slug>/anim_<clip>.glb` in the shared raw-asset folder (originals are in `orig/`).
- Slip numbers are a ~2.5 s browser sample (150 steps) under real scene timing; they move by a few hundredths between runs, so compare before/after on the same machine.

## Dropping in hand-keyed clips

1. In Blender, import `art-src/tripo/<slug>/rig.glb` (or an existing `anim_*.glb`), keep the armature and mesh, delete other actions, key your animation on the existing bones (do not rename, add, or move bones; add bones only through `rigfix` so the mesh stays skinned).
2. Export glTF Binary with *Animation: active action*, *Always sample*, Y up, to `art-src/tripo/<slug>/anim_<name>.glb`. The name after `anim_` becomes the clip name, except presets listed in `CLIP_NAMES` in `build-characters.mjs` (e.g. `agree` -> `talk`).
3. Optional: `node tools/blender.mjs cleanup art-src/tripo/<slug>/anim_<name>.glb <action> --loop --drift` (writes `.clean.glb` next to it; rename it over the original), and `node tools/blender.mjs retarget ...` for library clips.
4. `node tools/blender.mjs build <slug>` and check `node tools/measure-clips.mjs public/models/<slug>/character.glb`, then a frame strip with `tools/qa/clip-strip.cjs`.
5. Run `tools/qa/anim-pass-smoke.cjs` (it reads `tools/blender/recipes/<slug>.json` for leg names if the model has one).

Files: `tools/blender.mjs`, `tools/blender/{common,kin,procedural,rigfix,cleanup,retarget,selftest,skinview}.py`, `tools/blender/pack.mjs`,
`tools/blender/recipes/*.json`, `tools/blender/maps/*.json`, `tools/qa/clip-strip.cjs`, measurement additions in
`tools/measure-clips.mjs`. Tests: `src/graphics/__tests__/blender-pipeline.test.ts`.
