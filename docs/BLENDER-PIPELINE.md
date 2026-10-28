# Blender animation pipeline

Headless Blender (4.5 LTS, `/home/ubuntu/tools/blender/blender`, glTF addon on) driven by scripts, so animation work is
free (no Tripo credits) and repeatable. It writes the same per-clip `anim_<name>.glb` files that
`tools/build-characters.mjs` already turns into `public/models/<slug>/character.glb`, so glTF extensions, WebP textures
and quantisation are untouched. Hand-keyed signature animation stays a human animator's job; the last section shows
how their files drop into the same flow. Sources and licences: [ANIMATION-SOURCES.md](ANIMATION-SOURCES.md).

```
node tools/blender.mjs procedural <slug> [clip ...] [--install]     author clips from a recipe (quadruped gaits, idles, one-shots, overlays on Tripo clips)
node tools/blender.mjs rigfix     <slug>                            add bones + move vertex weights (cinderhound forelegs, gargoyle wings)
node tools/blender.mjs cleanup    <in.glb> <clip> [--loop] [--drift] [--foot-lock] [--recipe r.json]
node tools/blender.mjs retarget   <source.glb> <target-rig.glb> <clip-map.json> [--only a,b]
node tools/blender.mjs staff      <slug> [clip ...] [--sheets]      staff versions of a hero's clips: the arm re-solved around the held staff
node tools/blender.mjs install    <slug>                            copy art-src/blender/<slug>/anim_*.glb into art-src/tripo/<slug>/
node tools/blender.mjs build      <slug ...>                        build-characters only
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

## Jobs (on the shipped models)

The same tools, run on the models the game ships rather than on `art-src/` (DECISIONS B74): the Discord agent's way to change how a model
moves or looks (`server/death-muffin/discord-agent/blender-job.sh`, guide `guides/blender.md`), and the quickest way for a session too.

```
node tools/blender/jobs.mjs run <job.json> [--shots <dir>]    {"model": "<id>", "steps": [{"kind": ..., params}], "note"?}; 1-8 steps in order
node tools/blender/jobs.mjs replay <id>                       redo the recorded steps on a model rebuilt from its Tripo files
node tools/blender/jobs.mjs kinds                             the kinds and their parameters (tools/blender/kinds.json)
```

- **Clips** (`motion`, `retarget`, `cleanup`, `clips`): Blender gets a copy of the model (for `cleanup`, holding only that clip; for `motion`, the
  rig and every clip an overlay may build on) and its output clip is copied onto the shipped skeleton by joint name (`merge.mjs`
  `transplantClip`), replacing a clip of that name. Nothing else in the file changes. `staff` re-bakes a discipline hero's `<clip>_staff`
  clips from its clips as they are ("`staff`" below), each starting where the clip it re-bakes starts (`pack.mjs` `addClip`); a job that
  changes one of those clips on such a hero ends with a `staff` step for it, or the game keeps playing the old motion with a staff in hand.
  On a model with a cloak ("`cloak`" below) every clip a step made or changed gets the cloak re-keyed from the settings saved in the file.
- **Cloth** (`cloak`, `cloak.mjs`, no Blender): new bones, re-weighted cloth and keys for them in every clip ("`cloak`" below).
- **Geometry** (`rigfix`, `decimate`, `reshape`, `remove`; `edit.py`, `rigfix.py`): Blender writes a static export and only the skinned mesh's
  vertex data, indices and, for new bones, the skin are moved into the shipped file (`transplantGeometry`). Tripo's binds carry a scale that
  Blender's export normalises, so the two binds may differ by one transform for the whole mesh; vertices are moved by it, and a bone whose
  bind does not follow it moved in Blender, which refuses the job (the clips would no longer fit). Attributes Blender drops (tangents; Godot
  makes its own) are dropped; morph targets are refused.
- **Colour** (`recolor`): the base colour texture is shifted with sharp (hue, saturation, brightness, optionally only near one colour) and its
  image renamed, so Godot extracts a new texture file; the job deletes the old extracted `.webp` and its `.import`.
- **After the steps**, before anything is written: the model rules (`tools/assets/check-models.mjs`), stride (body heights per second, as
  `measure-clips.mjs --stride`) for touched `walk`/`run`, timings `[length, blow lands]` for touched `attack*`/`cast*`, and with `--shots` a
  preview sheet (`preview.py`: six moments of each touched clip, or the model before and after from three sides; Cycles on 4 CPU threads;
  for `staff`, up to four of its own sheets).
  Then the GLB is written, the model's rows (`client/game/view_models.json`, `client/data/slice/{enemies,npcs,hero}.json`) get the clip list,
  strides and timings, and the steps are appended to `art-manifest/blender/<id>.json`. A failing step or check writes nothing.
- The library is the shared checkout's `art-src/vendor/quaternius-ual/UAL1_Standard.glb` (`DM_BLENDER_LIBRARY` overrides); scratch files go
  to `DM_BLENDER_SCRATCH` or the system temp dir.
- `tools/build-characters.mjs` rebuilds a model from `art-src/tripo/<id>/` (or a ComfyUI-made one from its record's `game` file, ASSET_PIPELINE.md "Build"), which loses its jobs: `build-art.sh` replays them; by hand, run
  `replay` after it. Tests: `node --test tools/blender/jobs.test.mjs` (no Blender).
- Limits: one skinned mesh per model. `reshape` scales the vertices a bone moves around its head, best at the ends of the body (a head,
  horns, claws); in the middle of the body it bends the seams. `remove` deletes the faces whose vertices those bones move most; the bones stay.

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
| `source` | rig GLB under `art-src/tripo/<slug>/` (default `rig.glb`; the cinderhound uses `rigfixed.glb`); a `motion` job uses the shipped model |
| `forward`, `headBone`, `root` | body forward in Blender armature space (Z up), or derived root-to-head |
| `legs` | `{ FL: { chain: [bones hip..knee], paw: ankle bone, rigidFrom: 1 } ... }`. The paw's *head* is the ankle target. `rigidFrom: 1` treats `chain[1:]` as one stiff lower leg: the solver then has two segments and a unique answer. |
| `clips.<name>.type` | `gait` (feet on a stance line + swing arc), `idle` (feet planted, body breathes), `once` (a one-shot: attack, hurt, death; frame 0 is the start, the last frame the end, no loop) |
| `gait` | `duty` (share of the cycle on the ground), `stride`, `lift`, `phase` per leg, `arc` (swing shape), `legScale`, `center` (m, or per leg: where the stance sits ahead of the rest foot; the fen spider moves its front legs' stance back and its hind legs' forward, so legs that splay along the body do not overreach) |
| `paw` | `stance` / `swing` pitch in degrees (positive = toes down) |
| `mods` | body modulators: `{ bones, kind: lift\|sway\|surge\|pitch\|yaw\|roll, amp (m or deg), cycles, phase, lag, offset }`; `lag` shifts the phase down the bone list, which makes tails and necks wave |
| `mods[].keys` | `once` clips: `[[u, w], ...]` over the clip (u 0..1, w -1..1, smooth between keys) replaces the sine; `lag` delays the curve down the bone list |
| `mods[].body` | `true`: the axis turns with what the bone inherited (a tail or leg of a body that has rolled onto its side bends about the body's own axis, not the world's) |
| `plant` | `once` clips: `false` lets the leg bones take `mods` like any bone (a fall); default `true` keeps the feet on their IK targets |
| `feet` | `once` clips: `{ FL: [{ fwd, up, side (m), in (share), keys }] ... }` moves a planted paw (a pounce lifts and reaches with the front paws); `in` 1 brings it under its leg's top joint (a spider curls its legs as it dies) |
| `floor` | `once` clips: `{ land: u }` lifts the root whenever the skinned body would sink below its rest floor, and from `land` on also lowers it, so a falling body lies on the ground (`floorLift` in the output: the range of that correction) |
| `crouch` | `auto` (default): the smallest root drop that keeps every foot inside 98.5% of its leg's reach, or a number; a `once` clip's default is `idle` (the idle clip's drop) |
| `legs.X.hock` | `true`: a digitigrade hind leg of **three chain bones** (thigh, shin, metatarsus) plus the paw. The first two are solved to the hock, the metatarsus then points at the ankle in a direction that flexes with the stride; the clip's `hock: {stance, swing}` gives degrees (positive folds the foot back; the swing is a sine over the swing phase, `stance` a ramp over the stance). Replaces `rigidFrom` (a stiff lower leg) where the rig has the bones. |
| `legs.X.minReach` | fraction of the leg's reach below which a swinging foot is pushed away from the hip (weight 0 at lift-off and touch-down, 1 in mid-swing). A tightly folded thin forearm becomes a fin that rises past the spine. |
| `clips.<name>.hock` | see `legs.X.hock` |
| `stride` | `{ walk: n }` body heights per second for a rig with no legs to measure (the gargoyle's flap loop). |
| `levelFeet` | `false` for rigs with no legs |
| `overlays.<preset>` | lay procedural motion over a **Tripo clip** (see below) |

A foot in stance moves backwards on a straight line at `stride / (duty * duration)` model units per second; that is the
clip's *ground speed*, printed as `stanceSpeed`. `tools/measure-clips.mjs --stride` measures it back from the finished GLB
(paw bones named by the recipe); the client should play the clip at `groundSpeed / stride` so the feet do not skate. Feet are
levelled first (`levelFeet`): each paw's target is lowered by the difference between its lowest skinned vertex and the
lowest of all, so asymmetric rigs touch one floor.

Authoring rules: stride is limited by leg reach (a 0.3 m hind leg cannot take a 0.7 m stride; the
auto-crouch hides a little but a run needs `crouch` of 8-10% of the body); a three-bone chain solved with FABRIK has a free
middle joint that jumps between frames (visible as a one-frame foot dip), so use `rigidFrom`.

## `rigfix` (new bones and re-weighting)

`recipes/cinderhound.json -> rigfix.legs[]` adds a shoulder/elbow/wrist bone chain per foreleg at the measured leg
positions and moves every old influence in the leg's column (chest, neck, stubs) onto the new bones with a smooth fade
toward the shoulder (`zTop`), a cross-fade at elbow and wrist, then normalises. Output: `art-src/tripo/cinderhound/rigfixed.glb`.

Three selection modes (all in `rigfix.py`, all move *every* old influence in the region onto the new bones, then normalise):

- column (`select.radius` ...): cinderhound forelegs, vertical columns around an axis, as above.
- **capsule** (`select.radii`, `soft`, `zTop`, `rootFade`): each new bone has a radius around its segment; a vertex shares its weight among the segments it is close to and fades over `soft` metres at the surface and over `zTop` in height so the top of a limb stays on the body; for legs and tails (no shipped recipe uses it today). A vertex that an earlier chain already owns (> 0.3) is skipped; `rootFade` keeps the first tail bone joined to the rump.
- **region** (`select.box`, `select.along`): axis constraints with soft edges (`absy`, `x`, `z`, ...) plus a position-along-axis spread over the bones; for thin sheets such as wings. The gargoyle's wings are "behind the body plane (`x < 0.12`), more than 7 cm off the centre line, above 0.4 m".

`node tools/blender/skinview.py` (via `blender -b --python`) renders a rig as coloured skin weights (strongest vertex group per vertex) plus bone lines, optionally at a frame of an animated GLB: that is how the gargoyle's skinning was read. Its bone lines of *old* Tripo bones are drawn about 0.35 m low (the armature object offset), bones added by `rigfix` are correct; the mesh colours are what matters.

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

**Biped to biped** (`retarget` with `from`, `tools/blender/maps/biped-to-biped.json`): every clip of a model in the game onto another body on
the same skeleton with its own rest pose, as a Pixal body rigged by `make.mjs`'s `biped` rig (`build_rig.py`) has. Same bone names both
sides; spine, head, hands and feet carry their change from rest (`delta`), arms and legs `aim` where the source limb points, and the hips keep
their travel (`inPlace: false`), so the clips keep the source's timings. The map's `clips` only says which clips loop. `from:
"hero_gravecaller"` gives a new hero body the heroes' whole move set, the `_staff` clips too (23 clips; on the 2026-10-28 test body the skin's
seam copies stayed together to 0.00 mm in every clip, the knees bent forward, the hips kept the body's own height, the run's stride matched
the hero's and the walk's came 8% shorter). Blender writes each clip with the target's skeleton only (`common.export_glb` exports the
armature it is given and the meshes under it): the source has the same bone names, and a file holding both would give every bone two
channels, which `transplantClip` refuses. The job prints the body's own `STRIDE` and `TIMINGS` for its row. Skinning limit: cloth hanging below the knee (a long robe or skirt) is weighted to the legs and
stretches between them on a stride.

## `cloak`: cloth that stops riding the arms and the bent back

Tripo weights loose cloth to the nearest bones, so the cloth moves as if it were part of them. On the heroes two cases broke the big moves
(Helix, 2026-10-28, the Gravecaller's slam): the side panels hanging below the T-pose arms ride the arm bones, so an arm raised overhead lifts
them into a flat sail; and the Gravecaller's long back cape rides the spine and the thighs, so the slam's deep bow carries it up behind the
hero like a board. `{"kind": "cloak"}` fixes the arms, `"cape": true` the cape:

- **Arms** (default on): each arm gets a copy of its bones (`L_/R_CloakUpperarm` and its twists, `CloakForearm` and its twists, `CloakHand`),
  with the arm's rest pose and bind, under the same clavicle. Cloth more than 3% of the body's height below the arm line (upper arm, forearm,
  hand) starts to move onto the copy, wholly from 9%; the sleeve and the hand keep the arm. In every clip the copy follows the arm, except
  that its upper arm and forearm point at most `top` degrees (default 20) above the chest's level, easing off from level, so a pose with
  the arms down (idle, walk, run) plays the arm's own keys.
- **Cape** (default off): a chain `Cape01`..`Cape04` from `Spine02` down the middle of the back cloth to its hem, each joint at the cloth's
  depth at its height. Cloth more than 8% of the height behind the body's middle line (the spine above the hips, between the legs below)
  starts to move onto it, wholly from 14%, by its height along the chain. In every clip the chest carries each link, swung down to at most
  `lift` degrees (default 10) above its rest hang, easing over 25 more. The cape then hangs from the back in a walk instead of following
  the legs. Only for a cape that hangs free: on a robe the skirt is the back cloth and it flares backward (tried on the Ossuary, Mourner and
  Rotweaver, 2026-10-28). Their arm part alone barely showed in the game's camera, so of the heroes only the Gravecaller has the job.
- The rest pose and the binds are unchanged, so a still model looks the same. The settings ride in the file (`L_CloakUpperarm`'s and
  `Cape01`'s extras): a re-run re-tunes them, and `jobs.mjs` re-keys the cloak in every clip a later step changes.
- The bones are the hero's own: the model check compares the shared skeleton without them (`isCloakBone`), the biped rig for a new body
  (`comfy/build_rig.py`, whose template is hero_gravecaller) drops them, and `DmCreatureMat.REGION_OF_BONE` gives them the gear region of
  the cloth they took (the arm copies match their arm's names; `Cape01` the chest, the lower links the legs). They cost 14 bones (arms) and
  4 (cape) on top of the shared 41, keyed in every clip.
- Limits: the chain has no inertia (it moves with the chest at once, with no follow-through or flutter), so in a deep bow (`flick`, `dig`) the
  cape stands out behind at its limit (rest hang + `lift` + 25 degrees) like cloth in wind rather than falling against the legs; nothing keeps
  cloth out of the legs in a deep crouch.

## `staff`: the arm re-solved around a held staff

The hero clips were made for an empty hand, and `DmCreature.attach_held` bolts the staff rigidly to `R_Hand`, so the staff
goes wherever the wrist goes: it swings from upright to flat twice a stride in `run`, and points its head behind the hero
or at the floor through `flick`, `slam`, `channel`, `summon` and `cast` (the basic attack). Measured on the Gravecaller,
staff angle from upright, original -> re-bake: run 9-121 -> 6-23 deg, flick 15-159 -> 3-73, slam 10-163 -> 0-10 (the foot
lands on the floor), channel 105-123 -> 16-20, summon 59-174 -> 6-10, cast 10-115 -> 5-62.

```
{"model": "hero_gravecaller", "steps": [{"kind": "staff"}]}             a Blender job ("Jobs"): what the game's model gets
BLENDER=<blender> node tools/blender.mjs staff hero_gravecaller --sheets  the same re-bake into art-src/, for tuning the recipe
```

`staff.py` reads `client/assets/slice/models/<slug>/character.glb` (the model the client loads; the `staff` command falls back to `public/models/`), sizes the hero to its `heroModels` height
(`client/data/slice/npcs.json`) and the staff to `necro_gear.json` (`length_m`, `grip_t`), prepares the clips as
`DmCreature.prep_clips` does (Root dropped, combat clips' Hip pinned to idle's first key, other clips' Hip track dropped),
then for every clip in `tools/blender/recipes/staff.json` (or those named) keys `R_Upperarm`, `R_Forearm` and `R_Hand` so the staff sits
where the recipe says. Every other channel is the clip's own: the export swaps the shipped body channels back in. Staff clips the
model already has are dropped on import and made again from their clips. The job puts each new clip on the model in place of the old
one, resampled as `build-characters` does and starting where the clip it re-bakes starts; mesh, skin, textures and the other clips stay
as they are, the step is recorded in `art-manifest/blender/<slug>.json`, and `build-art.sh` replays it after a rebuild. With `--shots`
its preview is up to four sheets (the recipe's `preview`, or the clips named): the clip with the game's grip above, the re-bake
below, the staff model in hand. The `staff` command writes `art-src/blender/<slug>/staff/anim_<clip>_staff.glb` (and every clip's
`sheets/sheet_<clip>.png` with `--sheets`); `--install` copies them into `art-src/tripo/<slug>/` for `build-characters`. Sheets render
with the job previews' Cycles setup (`preview.scene`); one that fails is reported and the clips are still made.
Run so far on Blender 5.2 (Windows, 2026-10-25: a job 13-26 s a hero, 94 s with four sheets; the four heroes' records were made
that way and reproduce their shipped clips exactly); on 4.5 (the VPS) the script falls back to the legacy `action.fcurves`, not yet run there.

The grip is reproduced from the game, not guessed: the prop origin on the palm centre (`DmCreature.palm_of`: the mean of the
vertices skinned > 0.5 to the hand, in its bind space; the skin weights are normalised bytes), its +Y the knuckle line
leaned `lean` toward the fingers, in the hand's glTF node frame (not Blender's bone frame). The recipe:

| key | meaning |
|---|---|
| `heroes` | the bodies that carry the staff clips (`check-models` requires every recipe clip as `<clip>_staff` on them) |
| `gameLean` | `HOLDS.staff` lean (-65): the grip the original clips are read with |
| `lean` | the grip the re-baked clips are made for (-25, a relaxed fist): `HOLDS.staff_fist`, which the game uses while it plays them (client/game/README.md "Held props and gear look"). At -65 the staff lies back along the forearm: fine for a hanging arm, but a raised staff then needs a wrist folded 150+ degrees |
| `wrist` | the range of effective lean (ulnar -, radial +) the solver may bend the wrist to when the relaxed grip cannot reach |
| `rest` | where the hand carries the staff: metres from the right shoulder, `[forward, right, up]` |
| `clips.<c>.type` | `carry` (idle/walk/run: `swing` keeps that share of the original hand's fore-aft swing, `tilt` + `tiltSwing` lean the staff forward with it, `out` tips it outward) or `gesture` |
| `clips.<c>.keys` | gesture keys `[u, pos, [tilt, azimuth]]`: `u` 0..1 through the clip, `pos` `[forward, right, up]` from the shoulder, `"rest"`, or `{"plant": [forward, right]}` (the staff's foot on the floor there, fixed in the world); azimuth 0 forward, 90 out, 180 back |
| `preview` | the clips (at most 4) whose sheets a job's preview shows when it re-bakes every clip |
| `sheets.<c>` | sample times for the sheet |

The solver: with a straight wrist the hand's +Y is the forearm, so a staff direction fixes the forearm on a cone around it
(90 - lean degrees); of the cone directions the upper arm can reach, it keeps the one nearest the previous frame's, bends the
wrist within `wrist` only when that buys reach, and gives 70 % of the hand's twist about the forearm to the forearm.
A target the arm cannot reach lands as near as it can: each clip reports its `miss` (the four discipline heroes: 3 cm or less
for idle/walk/run/channel/summon, up to 7 cm for cast and flick, up to 15 cm for the Ossuary's and Rotweaver's slam, whose foot
then lands 2-3 cm above the floor) and `before`/`after` checks (staff tilt range, wrist bend and twist, the staff foot's lowest
point). The slam's crouch bottoms out after the clip's release frame, so its staff lands 40 ms after the release. hurt and death
have no staff version: the game hides the staff while they play.

## Known limits

- The bone map is hand-written, not inferred. `.fbx` sources go through Blender's FBX importer (untested here; the pack's GLB was used).
- `retarget` copies motion, not intent: proportions differ (UAL legs are longer relative to the hips than Tripo's), so feet float or sink until `cleanup --foot-lock` runs. Fingers and twist bones are not animated.
- Retargeted combat clips lose Tripo's per-clip `release` metadata (impact timing).
- `procedural`: `gait`, `idle` and `once` types (plus overlays), one gait per clip; a `once` clip starts from the idle's crouch, so it blends from the idle. Hock legs need three chain bones; the cinderhound and bone hound have them, the skull rat's hind legs stay `rigidFrom`. A tail cannot be raised by rotating its bones on the skull rat (its hind legs hang off `Tail_0`, and cumulative pitch curls the tail under the body): a `lift` of `Tail_1` is used instead, and its death first rolls `Tail_1` about the body so the tail's sideways curl lies flat when the body tips over. No 'trot vs gallop' blend, no turning clips.
- `rigfix` weights are geometric (capsules, boxes); cloth or hair hanging through a limb column can be shared between the limb and the body and stretch. Check with a posed `skinview.py` and look for vertices under the floor.
- Installing a procedural clip overwrites `art-src/tripo/<slug>/anim_<clip>.glb` in the shared raw-asset folder (originals are in `orig/`).

## Dropping in hand-keyed clips

1. In Blender, import `art-src/tripo/<slug>/rig.glb` (or an existing `anim_*.glb`), keep the armature and mesh, delete other actions, key your animation on the existing bones (do not rename, add, or move bones; add bones only through `rigfix` so the mesh stays skinned).
2. Export glTF Binary with *Animation: active action*, *Always sample*, Y up, to `art-src/tripo/<slug>/anim_<name>.glb`. The name after `anim_` becomes the clip name, except presets listed in `CLIP_NAMES` in `build-characters.mjs` (e.g. `agree` -> `talk`).
3. Optional: `node tools/blender.mjs cleanup art-src/tripo/<slug>/anim_<name>.glb <action> --loop --drift` (writes `.clean.glb` next to it; rename it over the original), and `node tools/blender.mjs retarget ...` for library clips.
4. `node tools/build-characters.mjs <slug>` and check `node tools/measure-clips.mjs public/models/<slug>/character.glb`.
5. Check the clip in the Godot client.

Files: `tools/blender.mjs`, `tools/blender/{common,kin,procedural,rigfix,cleanup,retarget,selftest,skinview,staff,edit,preview}.py`, `tools/blender/pack.mjs`,
`tools/blender/{jobs,merge,cloak}.mjs`, `tools/blender/kinds.json`, `tools/blender/recipes/*.json`, `tools/blender/maps/*.json`, measurement additions in
`tools/measure-clips.mjs`.
