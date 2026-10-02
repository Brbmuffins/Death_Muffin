# Necromancer spell feel (ROADMAP P1)

Branch `dm/spell-feel`, 2 Oct 2026. Visuals only: no damage, cooldown, cost, radius or duration changed.
Capture and measure with `tools/qa/spell-feel-smoke.cjs` (casts every rite, screenshots, perf) and
`tools/qa/spell-feel-sheet.cjs` (before/after contact sheets). Screenshots are in
`docs/screenshots/spell-feel/`: `sheet-<rite>.jpg` (left half before, right half after, one or two moments each; the
single frames were folded into the sheets to keep the repo small, `tools/qa/spell-feel-smoke.cjs` regenerates them). They are cropped around the caster, High quality,
software GL, Gravecaller with devAccess so every rite is unlocked.

## What the audit found

The shipped effects are good *magic* and weak *necromancy*. Hue family is right everywhere (the
`SPELL_FX` meanings hold) and the shapes read, but almost every impact is the same recipe: additive glow
sprites in the spell colour, a ring decal, a light flash. Only Bone Mantle (real bone fragments), Grave Hands
(real hands), Marrow Spear / Bone Prison / Ossuary Wall (real spikes) and the Wailing Skull sprite looked like
death. Everything else could be a fire mage in another colour. Nothing was *noisy* in a 5-enemy pack; the
busiest frames were Black Litany (very bright ring plus pentagram plus bloom) and Corpse Explosion's ember cloud.

## Per-rite audit and what was added

"Verdict before" is from the `before-*` frames; "added" is the motif layer in `src/graphics/necroFx.ts`.
Every motif is capped, thinned on Low (skipped), thinned again under reduced motion, and quieter for thralls;
see "Guardrails".

| Rite | Verdict before | Added (hue kept) |
| --- | --- | --- |
| Bone Needle | Generic: a cream bolt and a soft flash. Readable, calm. | 3 ivory bone splinters off the target on every hit (7 on a crit). |
| Scythe Reap arc | Generic: a gold crescent decal, a little dust. Readable. | Splinters off each body hit; grave dirt kicked up along the arc's edge. |
| Staff pierce | Generic: a thin beam to the second target. | Splinters at the pierced body. |
| Marrow Spear | Necro already: bone spikes and cracks. Slightly clean. | Grave dirt thrown up where the bone breaks the ground, a splinter spray at the tip. |
| Exhume | Magic circle plus teal sparks: the *hole* is missing. Readable. | Thrown soil, up to three spectral hands clawing out, soul-light motes and a wisp lifting away. |
| Miasma | Good colour, but a flat green puff. | Rot spores drift up and hang (count scales with radius, max 16 per cast). |
| Black Litany | Very bright violet ring plus pentagram: generic arcane, the loudest rite. | A ring of ghostly skulls stands on the circle, soul-light motes lift off every consumed body. Nothing added to the flash. |
| Corpse Explosion | Ember cloud: a generic fireball. | Thrown earth, a spray of bone, and the body's last breath leaving as a skull. |
| Wailing Skull | Necro already (skull sprite, jade). The trail was only glow. | Soul-light motes hang in its trail; bone splinters on impact. |
| Grave Step | Blood-mist blink, necro colour, but the arrival left a red blob (the converted smoke looped for 10 s+). | Dirt scuffed where you left and tore up where you land, bone chips, red soul-motes. The leaking smoke now plays once (`duration`). |
| Grave Frost | Cold fan decal plus ice shards: elemental. | Hoarfrost cracks along the breath, a whisper of grave mist, splinters on shattered bodies. |
| Soul Siphon | Jade tether, readable. | A faint skull lifts off the target on every other drain pull. |
| Bone Prison | Necro already (spike cage). | Soil at the foot of each bar; splinters off the bars. |
| Grave Hands | Necro already (hands). The ground was flat. | The ground heaves where the hands break through; spirit motes seep up between them while it lasts. |
| Bone Storm | Real shards in a funnel, readable. | Splinters shed off the funnel, dirt sucked up with it. |
| Ossuary Wall | Necro already (rib spikes). | Dirt along its foot, splinters off the ribs, a crack in the ground beneath it. |
| Command: Rend | Jade beams and a ring. | A spectral claw-mark on each target, bone chips at the bite. |
| Dirge | Cold-blue rings and a binbun bell area: generic sound magic. | Grave mist and soul-light wisps rise in the field. |
| Plague Bloom | Chartreuse pentagram plus petals: generic nature. | Rot spores drift off the bloom and off its bursts. |
| Bone Mantle | Good (real bone fragments). | Dirt where the cast starts; bone chips fly from each corpse tether. |
| Thrall rise | Teal sigil and sparks. | Soil breaks and settles; the caster's Exhume carries the hands and soul-light. |
| Thrall death | Pale puff. | A few bone chips and a pale soul-light that lets go (thrall tier: very quiet). |
| Soul Harvest release | Jade burst plus pillar: a flash. | Soul-light motes spiral out and two jade skull faces rise. |

## Guardrails (what keeps it from getting noisy)

- **Low:** every motif is skipped (`motifScale()` returns 0). The rite still plays exactly as before.
- **Reduced motion:** particle motifs are drawn at 40%, and the rising skull/wisp billboards and the spectral
  hands are dropped.
- **Thrall-originated** (thrall death/rise, a Litany or Mantle another player cast): 40% of the particles, never
  billboards or hands, and decals at 60% opacity.
- **Budget:** one shared token bucket for all motif particles (burst of 240, refills 260/s) and one for billboards
  (burst of 14, refills 9/s). A full legion plus a rite rotation cannot flood the 3,500 / 900 particle rings.
- **Transient pool:** the garnish decals/billboards back off once 100 of the 160 combat transients are live, so
  enemy telegraphs (boss rings, hooks, coal circles) are never the ones evicted.
- **Hands:** at most 3 spectral-hand fields at once.
- **Nothing added to the flash.** No new lights, no extra bloom; the motifs are small, low-contrast and
  hue-matched (bone, soil, the spell's own colour).
- Unit tests: `src/graphics/__tests__/necro-fx.test.ts`.

## Performance

**Honest caveat first.** This VPS was at load average ~40 from other agents while these ran, and Chromium renders
through software GL (swiftshader), so a single render took 0.6-1.9 s. Frame-time numbers from this box cannot show
a 5% change and are not evidence either way; they are listed only so nobody thinks they were skipped. The
load-independent numbers (what the layer draws, caps, draw calls) are the ones to trust. A frame-time check on a
real GPU is still open.

Method (`tools/qa/spell-feel-smoke.cjs`, `DM_QA_NOSHOTS=1`): Graves, a legion of thralls (the cap, 2-5 alive) plus
a ring of 40 high-HP robbers, then 14 busy rites cast back to back (Needle, Spear, Miasma, Litany, Explosion,
Skull, Frost, Prison, Hands, Storm, Mantle, Dirge, Bloom, Exhume), each cast twice in a row with the motif layer on
and off (`__cwDebug.necroMotifs(false)`; alternating which goes first so fight drift lands on both). "Off" is the
shipped behaviour with the motif calls skipped, i.e. the *before*.

| Quality | Layer | Render ms/frame (swiftshader, load 40, **not reliable**) | Cast call ms (mean) | Particles requested per cast+0.15 s (mean / max) | Binbun effects added per cast |
| --- | --- | --- | --- | --- | --- |
| High | off (before) | 1546 | 0.44 | 210 / 1130 | 1.2 |
| High | on (after) | 1509 | 0.50 | 166 / 405 | 0.7 |
| Low | off | 1148 | 0.75 | 212 / 1158 | 0 |
| Low | on | 1311 | 0.75 | 140 / 322 | 0 |
| High + reduced motion | off | 609 | 0.46 | 227 / 1195 | 1.5 |
| High + reduced motion | on | 612 | 0.54 | 176 / 461 | 0.6 |

(The per-cast particle means differ between the sides by fight noise, not by the layer: the other emitters
dominate. The max column is a single huge cast, not the layer.)

What the layer itself drew across those 14 casts (counters in `necroFx.motifStats`):

| Setting | motif particles | skull/wisp billboards | cracked-ground/slash decals | hand fields | budget-skipped calls |
| --- | --- | --- | --- | --- | --- |
| High | 300 (about 21 per cast, against about 3,500 + 900 ring capacity) | 14 (the burst cap) | 1 | 1 | 0 |
| Low | 0 | 0 | 0 | 0 | 0 |
| High + reduced motion | 105 | 0 | 1 | 0 | 1 |

Draw calls (one `renderer.info` reading at the end of each run, motifs on: 261 High, 180 Low, 273 High+reduced) are not
compared per side; by construction the motifs add none: they only feed the existing additive and smoke point
rings, and the billboards reuse the pooled sprites. Peak concurrent combat transients in the run was 44-51 (the
pool cap is 160; the garnish stops asking at 100). CPU cost of the new calls is below the noise of `performance.now()`
under that load (the cast call mean is 0.4-0.75 ms on both sides). Grave Step also no longer leaves a looping smoke
effect behind (one fewer Binbun looper alive per cast).


## After: what reads and what does not (from the `sheet-*.jpg` frames)

- Reads clearly: Black Litany's skull ring, Soul Harvest's skulls and motes, Exhume's soil and soul-light, Bone Mantle's
  chips, Dirge's wisps, the Corpse Explosion skull. These are the ones that now say "necromancer" at a glance.
- Reads only up close: bone splinters (Needle, Reap, Prison, Storm), dirt at the foot of the Prison and Hands, the
  Frost cracks, the Rend claw-marks. They are meant to be felt more than seen; if the owner wants them louder the knobs
  are the `size`/`n` defaults in `necroFx.ts`.
- Not changed: Marrow Spear, Bone Prison, Grave Hands and the Wall were already necro and only got ground detail.
- Telegraphs: nothing here draws on the ground at telegraph size or brightness; the largest garnish decal is the
  Ossuary Wall crack (opacity 0.6, 0.22 wide) and the Frost crack (opacity 0.4).

## Known limits / for the owner to look at

- The screenshots come from software GL at 1024x700; the motifs are deliberately small, so judge them on a real
  GPU at the real zoom. Stray beige haze and orange bits in some `after-*` frames are random wave spawns (Shroud
  Moth dust, leaves), not the motif layer: the waves keep running between casts.
- Skull faces use the existing `skull.png` sprite; wisps use `wisp.png`. No new art was generated.
- Audio was not touched (there is a separate audio branch).
