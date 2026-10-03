# Gear on the hero: swapping without clipping or odd motion (plan, 3 Oct 2026)

Goal: every piece of gear a player equips sits on the hero correctly in every animation, the swap itself looks deliberate,
and none of it costs frame time (perf-first rule).

## Where it stands

| Piece | How it is drawn today | Why it clips or looks odd |
|---|---|---|
| Main hand / off hand | Code-built prop (`gearProps.ts`) attached to `R_Hand` / `L_Hand`; `Creature.attach` calibrates the aim over 4 frames and `follow` (0.3–0.6) pulls it back toward upright | The hero clips were authored empty-handed, so a staff or scythe swings through the body and head during casts; `follow < 1` makes the prop drift off the wrist, so swings look floaty; two-handers are held in one hand; the 4-frame calibration shows as a snap on equip |
| Head | Generic dome (`buildHelm`, radius 0.15) on `Head` | One size for nine head shapes: it sinks into hoods or floats above them |
| Chest / legs / hands / feet | Region tint by skin weights (`gearTint.ts`), no geometry | Nothing clips, but armour never changes the silhouette, so plate looks painted on |
| Cape | Rigid open cylinder on `Spine02`, swung by a sine (`Avatars.ts`) | Moves as one board: the hem cuts through the legs on runs and attacks, and through the body on sharp turns |
| New Blood class gear | Authored GLB props per class | Same hand-attach problems as weapons |

What already helps: `prop-clipping.test.ts` measures prop vertices buried in the robe, `tools/blender.mjs` retargets and cleans clips headlessly,
`remoteWarm.ts` / `warmRender.ts` pre-compile gear materials, and `setEquipment` rebuilds only the slots that changed.

## Plan (in order of payoff)

### Phase 0: measure everything (no game change)
Extend the clipping harness to **every hero × every weapon kind × every clip**, sampled every 1/15 s:
- penetration depth of prop vertices into body capsules (torso, head, thighs), hand-to-grip gap, helm-to-head gap, cape-hem-to-leg distance;
- a ranked table plus contact sheets (headless Blender, `tools/clip-sheet.mjs`).

This becomes the CI gate: a change may not raise any pair's worst penetration. **Done when** the worst 20 pairs are known.

### Phase 1: real grip sockets (largest clipping win)
- Bake **socket bones** into each hero GLB with the Blender pipeline: `grip_r`, `grip_l`, `head_socket`, `back_socket` (and later
  `hip_l`/`hip_r` for sheathed weapons). Each is placed and oriented by hand once per rig, so the 4-frame calibration and its snap go away.
- Give every weapon and off-hand model the same origin convention: grip at the origin, `+Y` toward the tip, plus a `support` marker on two-handed shafts.
- With correct sockets, raise `follow` to 1 so weapons ride the wrist. Keep the stabiliser only for the staff idle.

### Phase 2: animation by weapon style, not by class
- An **upper-body layer per weapon style**: staff (two-handed), scythe (two-handed), wand/sickle (one-handed), plus an off-hand pose.
  Each style has idle, walk/run arms, cast, attack, hit and an equip gesture. The lower-body locomotion stays shared, masked at the spine.
  That is 4 styles × about 6 clips instead of a per-class × per-weapon explosion.
- Clips come from **CC0 libraries retargeted onto the Tripo bipeds** with `tools/blender.mjs` (Quaternius and similar), cleaned
  for loop seams and root drift, with impact times written into the strike table. These are not Tripo presets, so they cost no credits.
- **Two-handed support hand:** two-bone IK pulls the left hand onto the shaft's `support` marker, for the local hero and near partners only (about 0.05 ms).
- The weapon is chosen to suit its clips, so the harness from Phase 0 must pass for each style before it ships.

### Phase 3: body armour that changes the silhouette without clipping
- No rigid shells. Add **skinned overlay pieces** (pauldrons, bracers, greaves, belt or tabard) fitted in Blender to each hero's base mesh.
  Each piece gets a shrinkwrap offset of 1–2 cm and **weights copied from the body** (data transfer), so it deforms with the body and cannot separate from it.
- Reduce poke-through: where plate covers skin, the existing region mask (`gearMask`) hides the body underneath (alpha-test discard on that region only).
- To keep it cheap, use one shape family per body type (robed necromancers, plated knights) and colour the tiers by material, as the tint does now.
  Merge a hero's worn pieces into **one skinned mesh per character**, so armour adds at most 1–2 draw calls.
- The tint stays as the fallback for anything without an overlay.

### Phase 4: helms that fit
- Measure each hero's head and hood once (the bounding box at the `head_socket`) and scale or offset each helm per rig from a small table.
- Hide the hood or hair region when a helm is worn, using the same mask trick as Phase 3.
- Add a "Hide helm" option in Settings.

### Phase 5: capes that hang
- Replace the rigid cylinder with a **skinned cape on a 3–4 bone chain** driven by a damped spring (verlet), colliding with two capsules (spine and thighs).
  The local hero and partners within 20 m get the spring; distant partners get a baked sway.
- Budget: ≤ 0.05 ms per cape and no new shader programs. The cloth material stays shared.

### Phase 6: the swap itself
- Equipping plays a short **upper-body equip gesture** (0.4 s). The new piece **dissolves in** over 0.2 s (an alpha dissolve on the prop's material) instead of popping in.
- Sockets make placement exact from the first frame, so there is no snap.
- Gear materials are compiled during the load screen (`warmRender`), so the first time a piece is equipped there is no shader hitch.
- Remote players run the same path, without IK or cape physics beyond 20 m.

## Budgets (checked with `tools/qa/fixed-fight-perf.cjs` before every merge)
- Armour overlay adds no more than 2 draw calls per hero; IK applies to the local hero and near partners only; capes cost no more than 0.05 ms each.
- No new shader programs at equip time, and the main bundle grows no more than 5 kB gzip per phase.
- New GLBs go through `tools/slim-models.mjs`: texture caps, pruned accessors.

## Cost and effort
Phases 0, 1, 2, 5 and 6 are code plus Blender scripting and **need no Tripo credits**. Phase 3 may use about 300–600 Tripo credits for the base
armour shapes if hand-built shapes don't read well. Rough order: 0 → 1 → 2 → 5 → 6 → 4 → 3. Phases 0 and 1 fix most of the visible clipping.

## Owner decisions (answered 3 Oct 2026)
1. Armour: **fitted skinned overlay pieces** (Phase 3 goes ahead).
2. Helms: **hide the hood/hair under a helm, plus a "Hide helm" setting**.
3. Swap moment: **instant, no gesture** (Phase 6 drops the equip gesture and keeps exact socket placement + warmed materials, so nothing snaps or hitches; no dissolve).
4. Scope: **the four necromancers first**, New Blood afterwards on the same pipeline.
