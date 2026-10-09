# Gear status (3 Oct 2026, branch `dm/gear-fit`)

**Round 2 (owner: "most visually functional version" until the character matches the item)** is summarised first; round 1 follows.

## Round 2 changes
1. **Hood-as-helm.** `src/graphics/rigHeads.ts` says per rig whether the head is already covered (hood, cowl, built-in helmet, headdress, and since 4 Oct the bald Bell Monk, tinted at 0.25 strength so the brow stays uncovered) or bare (no rig is bare now; the dome path remains for new rigs). Covered rigs draw **no dome**: the equipped helm tints and glows the rig's own head region (set accent, or the metal colour), via a head-region mask baked next to the existing body-region mask in `gearTint.ts` (`Creature.setHeadTint`; two uniforms, no draw call, no new program per rig). Hollow Knight and Grave Warden tint their built-in helmets instead of stacking a dome. A rig marked bare would keep the dome fitted from `headFit()`. 4 Oct: Bell Monk moved to tint-only, Carrion Witch keeps her tinted headdress (owner-approved); Monk draw calls with a helm drop from 10 to 2 per rig (no dome). The table is per rig, not per item. It is by eye: head radius cannot tell a tight hood (Mourner 0.112 m) from a bald head (Monk 0.117 m).
2. **Cape** fades out in 0.12 s during death and hurt one-shots and back in over 0.25 s; held props hide for the same time. Note the hero's in-game hit reaction is an additive *flinch* on top of the idle (`Creature.flinch`, partial strength, 35% of hits), not the full `hurt` clip the harness measures, so the 12 cm hurt numbers overstate what players see; death is the real case.
3. **Weapons.** `follow` raised from 0.15-0.5 to 0.8 for staff, scythe, wand, sickle and off-hands, and 0.6 for the default skull staff and Bell Monk staff (0.8 broke the 7 cm prop-clipping guard). The prop already rode the wrist; what moved was its angle, so tip drift drops from 2.2 m to 0.76 m worst (summon), 3x. Combat-clip penetration is unchanged (worst 10.7 cm vs 11.2 cm before, same as the budget overshoot that was already there). Two-handed grips (left hand on the shaft) are not done: it needs the support-hand IK of Phase 2.
4. **Float check re-based**: the gear-clip harness now forces a dome on the hooded necromancer rigs (they no longer draw one) and allows 9 cm over the hood-top crown (the dome's crest and crown ornaments), baseline regenerated.
5. Help: Codex (Gear and levels entry) and README (Settings list, first-20-minutes line) cover Hide helms, the set summary and the head look.

6. **Draw calls (measured, `gear-fit-shot.cjs`, Chromium swiftshader, `renderer.info`).** A covered rig wearing a helm now draws 0 extra calls (hooded necromancers 3 per rig with helm kit vs 5 bare-with-default-staff; before, each worn dome added 8 meshes = 8 calls on every rig). (Monk: see 4 Oct note above, no dome now.) Full kit: 13-14 calls per rig, 21 for the Monk. Death frame: 1 call per rig (cape and props hidden), 9 for the Monk (its dome stays). Per-frame CPU: unchanged (head tint is two uniforms).

## Long-term: the character matches the item
What the owner wants eventually: what you wear is what you see, per item, not a tint. See `docs/GEAR-VISUALS-PLAN.md` Phase 3 (fitted overlay pieces) and Phase 4 (helm families). What it would take:
- **Per-item look data.** A `look` record on each armour piece in `server/rules/content/armorSets.ts` (mesh variant id, which body parts it hides, accent colour). The 90 + 20 existing pieces already have colour, accent and part; they would gain a mesh family and a hide mask. Item ids and server rows do not change, so no migration.
- **Modular hero meshes.** Each hero is one skinned mesh today, so hood, hair and cowl cannot be hidden separately. In Blender (`tools/blender.mjs`), split head/hood/shoulders out of each rig (or add a vertex mask per part) so a worn helm can hide the hood or hair instead of tinting it. About a day per rig, 4 necromancers first.
- **Overlay pieces.** Per body type (robed casters, plated knights, light wrappers): helm/hood variants, pauldrons, bracers, greaves and a tabard, shrinkwrapped 1-2 cm off the base mesh with weights copied from it, merged into one skinned mesh per hero (at most 1-2 extra draw calls, budget already in the plan). Roughly 300-600 Tripo credits if hand-built shapes do not read well; the owner's cap is 1,500.
- **Runtime.** Slot-based hide masks (the head mask added here is the first), `setEquipment` swapping meshes and masks, the same path for remote `player:gear`, and a perf check with `fixed-fight-perf`.
- **Order.** One body type end to end (Ossuary robes: hood variant, shoulders, tabard), measure, then the other three necromancers, then New Blood.

---

# Round 1

Owner question: "models overlapping, the hood etc.; gear sets and equipping are becoming more relevant."
Contact sheets: `docs/screenshots/gear-fit/` (`before-*` = start of round 1, `after-*` = end of round 2: full kit front/side/back on all 9 rigs, head close-ups, a death frame, the set summary; made by `tools/qa/gear-fit-shot.cjs`, nine hero rigs,
front/side/back, same `setEquipment` / `setCape` path that remote players use).

## What works
- Weapons / off-hands ride the wrist (grip table in `gearProps.ts`); body slots tint their skin region; remote players run the same
  `NecromancerAvatar.setEquipment` code as the local hero (`player:gear` -> `gearFromIds` -> `setEquipment`), so every fix below applies to them.
- Set pieces: pips, tiers, tooltips and the in-set glow on the paper doll already existed; this branch adds the summary below.

## Audit (before)
| Issue | Where | Severity |
|---|---|---|
| Helm was one 0.15 m dome for nine head shapes: floated on top of hoods, buried the Ossuary skull (5.3 cm), covered the Witch's/Veilwalker's brow, ornament halos hovered | all rigs, front + side | worst, visible every frame |
| Cape was a 1.7 rad, 0.92 m rigid board standing off the back; hem cut 10-14 cm into thighs on hurt2/death2/cast, 5-10 cm on run | all rigs, side + back | high |
| Hood/hair stays under the helm | necromancers, Witch | solved by covering, see below |
| Two-handed weapons held one-handed; staff tip drifts up to 2.2 m from the wrist (grip stabiliser) | all necromancers | high, **not fixed** (Phase 1/2 of GEAR-VISUALS-PLAN) |
| Prop vertices in the body on hurt/hurt2 (12-14 cm) | staff, grimoire, skull focus | medium, not fixed |
| Body armour only tints, no silhouette change; no overlaps because there is no geometry | all | by design until Phase 3 |

## Fixed
1. **Helm fits the rig (data-driven, no per-item table).** `Creature.headFit()` measures each rig's skull plus hood once (vertices owned by the
   `Head` bone, rest pose, cached per rig). `NecromancerAvatar.mountHelm` scales the dome to that reach (x1.08, clamped 0.9-1.6) and seats its apex just over the
   crown. Result: no floating, no hood poking through the dome, Ossuary sink 5.3 -> 2.8 cm, faces stay visible. Cost: one pass over a few thousand head vertices per rig per session, none per frame.
   The helm is mounted via `Creature.afterLoad`, so equipping before the model finishes loading (remote players joining) is fitted too.
2. **"Hide helms" setting** (Settings, `hideHelm`, default off): hides worn helms on every hero (own and remote), hood/hair shows. Applies live.
3. **Cape hangs closer and shorter** (0.92 -> 0.78 m, arc 1.45 rad, radii 0.25/0.37): worst hem 14.5 -> 9.8 cm (only hurt2 stagger now; in game the hero's hit reaction is an additive flinch, and the death clip now hides the cape), cast and run no longer clip.
4. Clip baseline regenerated (`docs/gear-clip/*`).
5. **Set summary in the Reliquary** (below the paper doll): for each worn set (best two): name, five pips (filled = worn), active tiers in green, and the next tier
   in gold with "Need N more (parts) - where it drops". "Set complete" at 5. Tooltips and the in-set glow are unchanged.

## Still clips / open (and why)
- **Helm "float" metric reads 4.8 cm (budget 3)**: the harness measures the apex against the *skull*; the helm now sits on the hood, which stands above the skull. Visually correct; the guard baseline was updated, the metric should be re-based to hood height.
- **Cape is still a rigid panel**: no cloth motion, still 10 cm into the thighs in the hurt2 stagger and in death clips. Real fix is Phase 5 (skinned spring cape). Option now: hide the cape while a death/hurt clip plays.
- **Helm silhouette**: one generic dome per set (ornaments differ); the hood below the dome still shows. Knight/Warden already wear a helm in their mesh, so the dome stacks on it.
- Two-handed grips and hurt-clip prop penetration: see Round 2 (drift reduced 3x; two-handed grips need Phase 2 IK).
- Body armour pieces (pauldrons, tabards) are Phase 3.

## Recommended next
1. Phase 1 sockets + `follow = 1` (largest remaining visual win: the floating staff).
2. Re-base the helm float metric on hood height; add a dome per head-shape family (hooded, bare, helmed) for the New Blood heroes.
3. Phase 5 cape, or at minimum fade/hide the cape in death clips.
4. Phase 3 overlays for the four necromancers.

## Perf
No per-frame work added: helm fit is cached per rig, set summary renders only when the Reliquary re-renders, the Hide helms setting touches `visible` flags only on change. Draw calls unchanged (same helm meshes, one dome per helm as before; a smaller cape quad count).
