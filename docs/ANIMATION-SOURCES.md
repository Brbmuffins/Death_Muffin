# Animation sources

Every animation that did not come from Tripo's presets, with its origin and licence. Only public-domain (CC0)
material or clips written in this repository are used; no Mixamo (needs an Adobe account and is not redistributable
as raw files) and nothing ripped from other games.

## Libraries (CC0 1.0)

| Library | Author | URL | Licence file in repo | Used for |
|---|---|---|---|---|
| Universal Animation Library, Standard (v3.0, 16 Jun 2026; 43 clips, one humanoid rig) | Quaternius | https://quaternius.com/packs/universalanimationlibrary.html, https://quaternius.itch.io/universal-animation-library | `docs/licenses/quaternius-universal-animation-library-CC0.txt` (copied verbatim from the pack's `License.txt`: "CC0 1.0 Universal (CC0 1.0) Public Domain Dedication") | retarget proofs onto `hero_gravecaller` (below) |

The pack page and the itch.io page both say "CC0 License". The free Standard zip was downloaded on 2026-10-02 (itch.io
"name your own price", $0) and unpacked to `art-src/vendor/quaternius-ual/` (`UAL1_Standard.glb`, `UAL1_Standard_RM.glb`,
`License.txt`, `README.txt`; raw assets stay out of git like the rest of `art-src/`). Credit is not required by CC0;
"Quaternius" is given anyway.

SHA-256 of the files used: `UAL1_Standard.glb` 69591853d817488edaa8fd9bf8fc1d821eaeaf789f8627b3cd23b41c4ed67997,
`UAL1_Standard_RM.glb` be684571ed655a1b892c2c07e6e2aeca053b606c442d34004adaf1d944090d01.

## Clips written in this repository

Procedural clips (`node tools/blender.mjs procedural <slug>`, recipes in `tools/blender/recipes/`). They are code, so
there is nothing to license; the recipe is the exact source of every key.

| Model | Clips | Shipped in `public/models/<slug>/character.glb` |
|---|---|---|
| `skull_rat` | `idle`, `walk`, `run` | yes (2026-10-02, branch `dm/blender`) |
| `cinderhound` | `idle`, `walk`, `run` (on a rig with two new foreleg bones: `rigfix`); hock-flex hind legs from 2026-10-02 round 2 | yes (2026-10-02, branches `dm/blender`, `dm/blender-2`) |
| `bone_hound` | `idle`, `walk`, `run` (on a rig with new leg and tail bones: `rigfix`) | yes (2026-10-02, branch `dm/blender-2`) |
| `belfry_gargoyle` | wing motion (bones `L_/R_Wing_A/B` from `rigfix`) laid over Tripo's own `idle`, `dive`, `slash`, `hit_to_*`, `fall`, `defeat_03`, plus a new `walk` that is the Tripo idle with a faster flap. Body motion in these clips is Tripo's, re-exported through Blender. | yes (2026-10-02, branch `dm/blender-2`) |

## Retargeted library clips (proof, not in the game)

`node tools/blender.mjs retarget art-src/vendor/quaternius-ual/UAL1_Standard.glb art-src/tripo/hero_gravecaller/anim_idle.glb tools/blender/maps/ual-to-tripo-biped.json`
writes `art-src/blender/retarget/hero_gravecaller/anim_ual_*.glb`. These are **not** copied into
`art-src/tripo/hero_gravecaller/`, so `build-characters` does not ship them; see docs/BLENDER-PIPELINE.md for the
measurements and the decision that is left open.

| Source clip (UAL) | Written as | Seconds |
|---|---|---|
| `Idle_Loop` | `ual_idle` | 2.50 |
| `Spell_Simple_Idle_Loop` | `ual_spell_idle` | 2.10 |
| `Spell_Simple_Enter` + `Spell_Simple_Shoot` + `Spell_Simple_Exit` | `ual_cast` | 1.47 |
| `Idle_Talking_Loop` | `ual_talk` | 2.93 |
| `Walk_Loop` | `ual_walk` | 1.33 |

Round 2 (2026-10-02) retargeted `Idle_Talking_Loop` and `Interact` onto `npc_prior`, `npc_sexton` and `npc_apothecary`
(`art-src/blender/retarget/<npc>/anim_ual_talk.glb`, `anim_ual_interact.glb`). Judged not better than Tripo's `agree`; not shipped, and the map gained an `Interact` -> `ual_interact` entry.

If any of these is ever shipped, add a row to the first table's "Used for" column and keep this file in step.
